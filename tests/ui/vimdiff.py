#!/usr/bin/env python3
"""The report of where ned's vim mode and a real vim differ, as a page you can open in a browser.

    python3 tests/ui/vimdiff.py --html OUT.html          # ask both, and write the page (plus OUT.html.json)

The run is the same comparison `t_65_vim_oracle` makes: every case of vimcases.py asked of vim (headless, and cached
while vim is unchanged) and of ned (headless too, `ned -es`: one process, the file put back between cases — a case in a
millisecond, not the two seconds a tmux editor and a screen read cost). A movement is compared by where the cursor and
the mode end up; an edit by the text it left as well. The page says the score, what the differences are made of, and
lists every one with both answers side by side; the cases that agree are folded away below, so a difference can be read
against its neighbours.
"""
import html
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>ned's vim mode against vim — --score-- of --total--</title>
<style>
  :root { color-scheme: dark; }
  body { background:#0e0f12; color:#d6d8e0; font:15px/1.55 ui-sans-serif,system-ui,sans-serif; margin:0; padding:2.5rem; }
  h1 { font-size:1.5rem; margin:0 0 .3rem; font-weight:600; }
  h2 { font-size:1.1rem; margin:2.2rem 0 .6rem; font-weight:600; }
  .sub { color:#7f8187; margin:0 0 2rem; }
  .sub code, td code { color:#cfd3db; font-family:ui-monospace,SFMono-Regular,monospace; }
  .score { display:flex; align-items:baseline; gap:.8rem; }
  .score b { font-size:3.2rem; line-height:1; color:#9bd07a; font-variant-numeric:tabular-nums; }
  .score span { color:#7f8187; }
  .bar { height:10px; border-radius:5px; background:#22242b; overflow:hidden; margin:.9rem 0 .4rem; max-width:640px; }
  .bar i { display:block; height:100%; background:linear-gradient(90deg,#9bd07a,#6fb0ff); }
  ul { margin:.4rem 0 1rem; padding-left:1.2rem; color:#b6bac4; }
  table { border-collapse:collapse; width:100%; max-width:1200px; margin-top:.4rem; }
  th { text-align:left; color:#7f8187; font-weight:500; padding:.4rem .75rem; border-bottom:1px solid #22242b; }
  td { padding:.6rem .75rem; border-bottom:1px solid #1a1c22; vertical-align:top; }
  .diff { margin:.15rem 0; }
  .kind { color:#ffb454; font-size:.75rem; text-transform:uppercase; letter-spacing:.05em; margin-right:.5rem; }
  .vs { color:#7f8187; margin-left:.7rem; font-size:.85rem; }
  .start { color:#6b6e76; font-size:.8rem; }
  .why { color:#8b8f99; font-size:.85rem; }
  tr.cursor td:first-child { border-left:3px solid #ffb454; }
  tr.text td:first-child { border-left:3px solid #ff6b6b; }
  tr.both td:first-child { border-left:3px solid #b58cff; }
  pre.text { background:#15171d; padding:.55rem .75rem; border-radius:6px; margin:.45rem 0 0; color:#b6bac4;
             font-family:ui-monospace,monospace; font-size:.85rem; white-space:pre-wrap; }
  details { margin:2rem 0; } summary { cursor:pointer; color:#8b8f99; }
  .note { color:#6b6e76; font-size:.85rem; margin-top:2.5rem; border-top:1px solid #1a1c22; padding-top:1rem;
          max-width:900px; }
</style></head><body>
<h1>ned&rsquo;s vim mode, against vim</h1>
<p class="sub">every case of <code>tests/ui/vimcases.py</code> given to both &mdash; the same file, the same place, the
same keys &mdash; answered by <code>--vim--</code> and by <code>--ned--</code></p>
<div class="score"><b>--score--</b><span>of --total-- cases agree (--pct--%) &middot; --differ-- differ &middot;
--skipped-- vim cannot finish</span></div>
<div class="bar"><i style="width:--width--%"></i></div>
<h2>What the differences are made of</h2>
--kinds--
<h2>The --differ-- that differ</h2>
<table><tr><th style="width:22%">case</th><th>what differs</th><th style="width:10%"></th></tr>--rows--</table>
<details><summary>the --okcount-- that agree</summary><table>--okrows--</table></details>
--skipblock--
<p class="note">a movement is compared by where the cursor and the mode end up; an edit by the text it left as well.
ned&rsquo;s <code>Col</code> in the status bar is a display column (a tab takes the columns it is drawn over) and
vim&rsquo;s <code>col('.')</code> counts characters: both are compared in vim&rsquo;s, on vim&rsquo;s line, so a tab
line is not a difference of its own. made by <code>tests/ui/vimdiff.py</code>.</p>
</body></html>
"""


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
        rows.append('%s  |  %s' % (html.escape(x), html.escape(y)))
    return '\n'.join(rows)


def page(answers, vim_version='', ned_version=''):
    """the HTML page, from the answers: the score, the kinds of difference, every case"""
    live = [a for a in answers if 'skip' not in a]
    bad = [(a, differs(a)) for a in live]
    bad = [(a, d) for (a, d) in bad if d]
    kinds = {}
    for _, d in bad:
        for kind, _, _ in d: kinds[kind] = kinds.get(kind, 0) + 1
    score = len(live) - len(bad)
    pct = (100.0 * score / len(live)) if live else 0.0

    rows = []
    for a, d in sorted(bad, key=lambda x: (x[0]['edit'], x[0]['case'], x[0]['start'])):
        klass = 'both' if len(d) > 1 else d[0][0]
        cells = ''.join('<div class="diff"><span class="kind">%s</span><code>%s</code><span class="vs">vim</span> '
                        '<code>%s</code></div>' % (kind, html.escape(ned), html.escape(vim))
                        for kind, ned, vim in d)
        if a['edit'] and any(k == 'text' for k, _, _ in d):
            cells += '<pre class="text">%s</pre>' % text_snip(a)
        rows.append('<tr class="%s"><td><code>%s</code><br><span class="start">from %d,%d</span></td><td>%s</td>'
                    '<td><span class="why">%s</span></td></tr>' % (
                        klass, html.escape(a['case']), a['start'][0], a['start'][1], cells,
                        ' + '.join(k for k, _, _ in d)))
    ok = [a for a in live if not differs(a)]
    okrows = ''.join('<tr><td><code>%s</code></td><td>from %d,%d</td><td class="why">%s</td></tr>' % (
        html.escape(a['case']), a['start'][0], a['start'][1], 'edit' if a['edit'] else 'move')
        for a in sorted(ok, key=lambda x: (x['edit'], x['case'], x['start'])))
    skipped = [a for a in answers if 'skip' in a]
    skipblock = ('<h2>Not comparable</h2><table><tr><th>case</th><th>why</th></tr>%s</table>' % ''.join(
        '<tr><td><code>%s</code></td><td class="why">%s</td></tr>' % (html.escape(a['case']), html.escape(str(a['skip'])))
        for a in skipped)) if skipped else ''
    kindlist = ('<ul>%s</ul>' % ''.join('<li><b>%s</b>: %d</li>' % (k, v) for k, v in sorted(kinds.items()))
                if kinds else '<ul><li>nothing &mdash; every case agrees</li></ul>')
    out = PAGE
    for k, v in (('--score--', str(score)), ('--total--', str(len(live))), ('--pct--', '%.0f' % pct),
                 ('--width--', '%.1f' % pct), ('--differ--', str(len(bad))), ('--skipped--', str(len(skipped))),
                 ('--vim--', html.escape(vim_version)), ('--ned--', html.escape(ned_version)),
                 ('--kinds--', kindlist), ('--rows--', ''.join(rows) if rows else
                                           '<tr><td colspan="3" class="why">nothing differs</td></tr>'),
                 ('--okcount--', str(len(ok))), ('--okrows--', okrows), ('--skipblock--', skipblock)):
        out = out.replace(k, v)
    return out


def main(argv):
    """`--html OUT` writes the page (and OUT.json, its data) — the only mode: it asks ned and vim itself"""
    sys.path.insert(0, HERE)
    out = argv[argv.index('--html') + 1] if '--html' in argv else os.path.join(HERE, 'vimdiff.html')
    bin = os.environ.get('NEDBIN') or os.path.abspath(os.path.join(HERE, '..', '..', 'ned'))
    import vimoracle, vimcases, nedheadless
    if not nedheadless.available(bin):
        print('ned -es is not in %s: build it first (nim c -d:release --opt:speed -d:strip -o:ned src/ned.nim) — '
              'it is the headless vim mode the cases are asked of' % bin, file=sys.stderr)
        return 2
    o = vimoracle.Oracle()
    o.need()
    print("asking ned headless (ned -es)")
    n = nedheadless.Headless(bin, vimcases.FIXTURE)
    try:
        n.start()
        answers = compare(o, vimcases, n)
    finally:
        n.stop()
    nedv = subprocess.run([bin, '--version'], capture_output=True, text=True).stdout.strip()
    vimv = vimoracle.vim_version(o.editor)
    json.dump({'vim': vimv, 'ned': nedv, 'answers': answers}, open(out + '.json', 'w', encoding='utf-8'), indent=1)
    open(out, 'w', encoding='utf-8').write(page(answers, vimv, nedv))
    live = [a for a in answers if 'skip' not in a]
    print('%d of %d agree -> %s' % (len(live) - len([a for a in live if differs(a)]), len(live), out))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
