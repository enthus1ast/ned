#!/usr/bin/env python3
"""Where ned's vim mode and a real vim differ: the score, and every case that differs, both answers side by side.

    python3 tests/ui/vimdiff.py              # print the score and the differences
    python3 tests/ui/vimdiff.py --json OUT   # ... and write the answers as JSON

The run is the same comparison `t_65_vim_oracle` makes: every case of vimcases.py asked of vim (headless, and cached
while vim is unchanged) and of ned (headless too, `ned -es`: one process, the file put back between cases — a case in a
millisecond, not the two seconds a tmux editor and a screen read cost). A movement is compared by where the cursor and
the mode end up; an edit by the text it left as well. The cases that agree are only counted.
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

def compare(o, vimcases, ned):
    """every case asked of vim (once, cached) and of ned (headless, `ned -es`): both answers, and the cases vim itself
    cannot finish"""
    total = len(vimcases.CASES)
    print("oracle: %d cases to compare" % total)
    asked = [(vimcases.vim_keys(k), l, c) for (k, l, c, _) in vimcases.CASES]
    answers = o.answers(asked, vimcases.FIXTURE, cache=os.path.join(HERE, '..', '..', '.vim-answers.json'))
    print("oracle done, asking ned")
    out = []
    for i, ((case, line, col, edit), want) in enumerate(zip(vimcases.CASES, answers), 1):
        if i % 50 == 0 or i == total: print("case %d / %d" % (i, total))
        if want['err'] or want['pending']:
            out.append({'case': case, 'start': [line, col], 'edit': edit, 'skip': want['err'] or 'pending'})
            continue
        # (the headless editor answers in vim's own words: a line and a character column, both from 1)
        got = ned.case(case, line, col, edit)
        out.append({
            'case': case, 'start': [line, col], 'edit': edit,
            'ned': {'line': got['line'], 'col': got['col'], 'shown': got['shown'], 'visual': got['visual'],
                    'text': got['text']},
            'vim': {'line': want['line'], 'col': want['col'], 'visual': want['visual'],
                    'text': want['text'] if edit else None},
        })
    print("ned done, %d cases processed" % len(out))
    return out


def differs(a):
    """what is not the same between the two answers — what the test fails a case on"""
    if 'skip' in a: return []
    n, v = a['ned'], a['vim']
    d = []
    if n['line'] != v['line'] or n['col'] != v['col']:
        # (the second count is the column ned's own status bar shows, which is what was actually read)
        d.append(('cursor', '%s,%s (shown %s,%s)' % (n['line'], n['col'], n['line'], n['shown']),
                  '%s,%s' % (v['line'], v['col'])))
    if a['edit'] and n['text'] != v['text']:
        g, w = n['text'] or [], v['text'] or []
        i = next((k for k in range(max(len(g), len(w))) if k >= len(g) or k >= len(w) or g[k] != w[k]), 0)
        d.append(('text', 'line %d: %r' % (i + 1, (g[i:i + 1] or ['<none>'])[0]),
                  'line %d: %r' % (i + 1, (w[i:i + 1] or ['<none>'])[0])))
    return d


def text_snip(a):
    """the lines where the two texts part, side by side (two either side, for the context)"""
    g, w = a['ned']['text'] or [], a['vim']['text'] or []
    i = next((k for k in range(max(len(g), len(w))) if k >= len(g) or k >= len(w) or g[k] != w[k]), 0)
    rows = ['ned  |  vim']
    for x, y in zip(g[max(0, i - 2):i + 3], w[max(0, i - 2):i + 3]):
        rows.append('%s  |  %s' % (x, y))
    return '\n'.join(rows)


def report(answers):
    """print the score, what the differences are made of, and every case that differs with both answers; gives
    back (agree, compared, differ, skipped)"""
    live = [a for a in answers if 'skip' not in a]
    bad = [(a, differs(a)) for a in live]
    bad = [(a, d) for (a, d) in bad if d]
    kinds = {}
    for _, d in bad:
        for kind, _, _ in d: kinds[kind] = kinds.get(kind, 0) + 1
    skipped = [a for a in answers if 'skip' in a]
    score = len(live) - len(bad)
    pct = (100.0 * score / len(live)) if live else 0.0
    made = ', '.join('%s %d' % (k, n) for k, n in sorted(kinds.items()))
    print('%d of %d agree (%.0f%%), %d differ%s%s' % (
        score, len(live), pct, len(bad), (' — ' + made) if made else '',
        ', %d vim cannot finish' % len(skipped) if skipped else ''))
    for a, d in sorted(bad, key=lambda x: (x[0]['edit'], x[0]['case'], x[0]['start'])):
        print('  %-20r from %d,%d' % (a['case'], a['start'][0], a['start'][1]))
        for kind, ned, vim in d:
            print('    %-6s ned %s   vim %s' % (kind, ned, vim))
        if a['edit'] and any(k == 'text' for k, _, _ in d):
            for row in text_snip(a).split('\n'):
                print('    | ' + row)
    for a in skipped:
        print('  %-20r vim cannot finish: %s' % (a['case'], a['skip']))
    return score, len(live), len(bad), len(skipped)


def main(argv):
    """asks vim and ned every case, and prints the score and the differences (`--json OUT` writes the answers too)"""
    sys.path.insert(0, HERE)
    bin = os.environ.get('NEDBIN') or os.path.abspath(os.path.join(HERE, '..', '..', 'ned'))
    import vimoracle, vimcases, nedheadless
    if not nedheadless.available(bin):
        print('ned -es is not in %s: build it first (nim c -d:release --opt:speed -d:strip -o:ned src/ned.nim) — '
              'it is the headless vim mode the cases are asked of' % bin, file=sys.stderr)
        return 2
    o = vimoracle.Oracle()
    try:
        o.need()
    except Exception as e:
        print('the vim oracle is not available: %s' % e, file=sys.stderr)
        return 2
    print('asking ned headless (ned -es)')
    n = nedheadless.Headless(bin, vimcases.FIXTURE)
    try:
        n.start()
        answers = compare(o, vimcases, n)
    finally:
        n.stop()
    if '--json' in argv and argv.index('--json') + 1 < len(argv):
        out = argv[argv.index('--json') + 1]
        nedv = subprocess.run([bin, '--version'], capture_output=True, text=True).stdout.strip()
        json.dump({'vim': vimoracle.vim_version(o.editor), 'ned': nedv, 'answers': answers},
                  open(out, 'w', encoding='utf-8'), indent=1)
        print('the answers are in ' + out)
    report(answers)
    return 0

if __name__ == '__main__':
    sys.exit(main(sys.argv))
