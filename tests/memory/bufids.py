#!/usr/bin/env python3
"""Every table that keeps something per open file (by its buffer id) lets it go when the tab closes: each global
`Table[int, …]` / `HashSet[int]` that ned indexes with a buffer's id (`x[b.id]`, `b.id in x`, `x.del bid` …) must be
in src/ned/editor/bufforget.nim — or in KEPT below, with the reason. A closed buffer's id is never used again, so an
entry left behind stays for good: 6.32.2 found sixty of them (ned grew by a megabyte or two at each file closed).

Usage: bufids.py        exit status 1 when one is missing"""
import glob, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(os.path.dirname(os.path.dirname(HERE)), 'src')

# (tables keyed by a buffer id that need not be forgotten: why)
KEPT = {
    'embDocs': 'embClose, called when the tab closes, tells the language servers and lets it go',
    'emitShadow': 'emitClose, called when the tab closes (the hidden C document of its emits)',
    'shadowChange': 'emitClose',
    'shadowSrv': 'emitClose',
    'lxCheckedAt': 'nedls only: let go on didClose (nedls/server.nim), with bufForget',
    'lsWarmed': 'nedls only: let go on didClose (nedls/server.nim)',
}

def main():
    files = {f: open(f, encoding='utf-8', errors='replace').read()
             for f in glob.glob(SRC + '/**/*.nim', recursive=True) if '/plugins/lib/' not in f}
    forget = open(os.path.join(SRC, 'ned', 'editor', 'bufforget.nim'), encoding='utf-8').read()
    forgot = set(re.findall(r"^\s+([A-Za-z_]\w*)\.(?:del|excl) id", forget, re.M))
    allsrc = '\n'.join(files.values())
    missing = []
    for f, s in files.items():
        invar = False
        for i, l in enumerate(s.split('\n')):
            if re.match(r'^var\b', l): invar = True
            elif l and not l[0].isspace() and not l.startswith('#'): invar = False
            if not invar: continue
            m = re.match(r'^(?:var\s+|  )([A-Za-z_]\w*)\*?\s*:\s*(Table\[int,|HashSet\[int\])', l)
            if not m: continue
            name = m.group(1)
            n = re.escape(name)
            byBuf = re.search(n + r'(\[(b|cb|buf|bb|cur|x|ab|tb|d\.b)\.id\]|\.(del|excl|incl|getOrDefault|mgetOrPut|hasKey|contains)\((b|cb|buf|bb|x|d\.b)\.id\b)|'
                              r'\b(b|cb|buf|bb|d\.b)\.id (notin|in) ' + n + r'\b', allsrc)
            if byBuf and name not in forgot and name not in KEPT:
                missing.append('%s:%d %s' % (os.path.relpath(f, SRC), i + 1, name))
    if missing:
        print('kept per buffer, never let go when its tab closes (add to src/ned/editor/bufforget.nim):')
        for m in missing: print('  ' + m)
        sys.exit(1)
    print('every table kept per buffer is let go when its tab closes (%d of them)' % len(forgot))

main()
