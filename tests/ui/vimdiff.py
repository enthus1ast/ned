#!/usr/bin/env python3
"""The report of where ned's vim mode and a real vim differ — the score of `tests/ui/vimcases.py`, worked down.

    python3 tests/ui/vimdiff.py            # every case, asked of both, and tests/ui/vimdiff.md written
    python3 tests/ui/vimdiff.py --check    # exit 1 when a difference is not in vimcases.KNOWN_DIFFERS

It runs the same comparison the UI test does (`t_65_vim_oracle`) but stands on its own: the vim answers come from the
oracle's cache, ned's from a ned the UI harness starts. The report is one line a difference: the keys, where the case
starts, both answers, the field that differs, and who is right from `KNOWN_DIFFERS`.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'vimdiff.md')


def compare(o, vimcases, ned, steps=None):
    """every case asked of vim (once, cached) and of ned: a list of the answers both gave, and the cases neither could
    finish"""
    asked = [(vimcases.vim_keys(k), l, c) for (k, l, c, _) in vimcases.CASES]
    answers = o.answers(asked, vimcases.FIXTURE, cache=os.path.join(HERE, '..', '..', '.vim-answers.json'))
    lines = vimcases.read_lines(vimcases.FIXTURE)
    out = []
    for i, ((case, line, col, edit), want) in enumerate(zip(vimcases.CASES, answers)):
        if want['err'] or want['pending']: continue
        got = ned.case(vimcases.keys_of(case), line, col, edit)
        vcol = vimcases.ned_to_vim(lines[got['line'] - 1] if got['line'] and got['line'] <= len(lines) else '',
                                   got['col'] or 0)
        out.append({
            'case': case, 'start': [line, col], 'edit': edit,
            'ned': {'line': got['line'], 'col': vcol, 'visual': got['visual'], 'text': got['text']},
            'vim': {'line': want['line'], 'col': want['col'], 'visual': want['visual'],
                    'text': want['text'] if edit else None},
        })
    return out


def differs(a):
    """the fields where the two answers are not the same — what a case fails on"""
    n, v = a['ned'], a['vim']
    d = []
    if n['line'] != v['line'] or n['col'] != v['col']:
        d.append('cursor: ned %s,%s vim %s,%s' % (n['line'], n['col'], v['line'], v['col']))
    if a['edit'] and n['text'] != v['text']:
        g, w = n['text'] or [], v['text'] or []
        i = next((k for k in range(max(len(g), len(w))) if k >= len(g) or k >= len(w) or g[k] != w[k]), 0)
        d.append('text: line %d ned %r vim %r' % (i + 1, (g[i:i + 1] or ['<none>'])[0], (w[i:i + 1] or ['<none>'])[0]))
    return d


def report(answers):
    """the Markdown report of a run: how many agree, what a case fails on, and the lines themselves"""
    bad = [(a, differs(a)) for a in answers]
    bad = [(a, d) for (a, d) in bad if d]
    byfield = {}
    for a, d in bad:
        for x in d: byfield[x.split(':')[0]] = byfield.get(x.split(':')[0], 0) + 1
    lines = ["# Where ned's vim mode and vim differ", '',
             'Written by `tests/ui/vimdiff.py`: the cases of `tests/ui/vimcases.py`, ned against a real vim. The count is',
             'the score, and it only goes down — each case that is a bug in ned is fixed, or goes under `KNOWN_DIFFERS`',
             'in `vimcases.py` with the reason it may differ.', '',
             '**%d of %d cases agree with vim; %d differ.**' % (len(answers) - len(bad), len(answers), len(bad)), '']
    if bad:
        lines += ['| what differs | cases |', '|---|---|'] + ['| %s | %d |' % (k, v) for k, v in sorted(byfield.items())]
        lines += ['', '| keys | start | what ned does | what vim does |', '|---|---|---|---|']
        for a, d in bad:
            lines.append('| `%s` | %d,%d | %s | %s |' % (
                a['case'].replace('|', '\\|'), a['start'][0], a['start'][1],
                '; '.join(d).replace('|', '\\|'), ''))
    return '\n'.join(lines) + '\n', len(answers), len(bad)


def main(argv):
    """the report: asked of vim and of ned, written to vimdiff.md (and checked against KNOWN_DIFFERS with --check)"""
    sys.path.insert(0, HERE)
    import vimoracle, vimcases
    for env, val in (('NED_TEST_TMP', '/tmp/ned-vimdiff'), ('NEDBIN', os.path.abspath(os.path.join(HERE, '..', '..', 'ned')))):
        os.environ.setdefault(env, val)
    os.makedirs(os.environ['NED_TEST_TMP'], exist_ok=True)
    src = open(os.path.join(HERE, 'harness.py')).read()
    h = {'__name__': 'harness', '__file__': os.path.join(HERE, 'harness.py')}
    exec(compile(src, 'harness.py', 'exec'), h)
    import nedvim
    o = vimoracle.Oracle()
    o.need()
    n = nedvim.Ned(h['setup'], h['start'], h['keys'], h['text'], h['screen'], h['tm'], h['W'])
    try:
        n.start(vimcases.FIXTURE)
        answers = compare(o, vimcases, n)
    finally:
        n.stop()
    text, total, differ = report(answers)
    open(OUT, 'w', encoding='utf-8').write(text)
    print('%d of %d cases agree with vim; %d differ -> %s' % (total - differ, total, differ, OUT))
    if '--check' in argv:
        unknown = [a['case'] for a in answers if differs(a) and a['case'] not in vimcases.KNOWN_DIFFERS]
        if unknown:
            print('not in KNOWN_DIFFERS: %r' % (unknown[:25],))
            return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
