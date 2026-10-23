#!/usr/bin/env python3
"""ned's built-in C formatter against clang-format: the same C files in the same style, and how much agrees.

usage: cfmtcompare.py NEDFMT FILE.c … [--style LLVM] [--col N] [--opt Key=Value …] [--show K] [--keep DIR]

Each file is formatted by clang-format (--style={BasedOnStyle: STYLE, ColumnLimit: N, SortIncludes: false, …})
and by nedfmt with the same style (c.format.style, c.format.options); the share of lines that come out the same
(difflib's matching lines over the longer result) is printed per file and in all, with the K most frequent kinds
of difference. clang-format comes from PATH. Exit status 1 when a file does not format with ned at all."""
import sys, os, json, subprocess, tempfile, difflib, re, collections, shutil

args = sys.argv[1:]
def opt(name, default=None):
    if name in args:
        i = args.index(name); v = args[i + 1]; del args[i:i + 2]; return v
    return default
style = opt('--style', 'LLVM')
col = opt('--col')
show = int(opt('--show', '8'))
keep = opt('--keep')
extra = []
while '--opt' in args:
    i = args.index('--opt'); extra.append(args[i + 1]); del args[i:i + 2]
nedfmt, files = args[0], args[1:]

def val(v):
    if v.lower() in ('true', 'false'): return v.lower() == 'true'
    try: return int(v)
    except ValueError: return v
clang_style = {'BasedOnStyle': style, 'SortIncludes': False}
ned_opts = {}
if col is not None:
    clang_style['ColumnLimit'] = int(col); ned_opts['ColumnLimit'] = int(col)
for e in extra:
    k, v = e.split('=', 1)
    clang_style[k] = val(v); ned_opts[k] = val(v)
cfg = tempfile.mkdtemp(prefix='cfmtcmp-')
os.makedirs(cfg + '/ned')
json.dump({'c.format.style': style, 'c.format.options': ned_opts, 'c.formatter': 'builtin'},
          open(cfg + '/ned/config.json', 'w'))
env = dict(os.environ, XDG_CONFIG_HOME=cfg)
kinds = collections.Counter()
examples = {}
tot_same = tot_lines = 0
failed = 0

def kind_of(a, b):
    """what differs between clang-format's line a and ned's b"""
    if a.strip() == b.strip(): return 'indentation'
    if re.sub(r'\s+', '', a) == re.sub(r'\s+', '', b):
        sa, sb = a.strip(), b.strip()
        if ('//' in sa or '/*' in sa) and sa.split('/')[0].rstrip() == sb.split('/')[0].rstrip(): return 'comment column'
        return 'spaces inside a line'
    return 'line breaks'

for f in files:
    src = open(f, encoding='utf-8', errors='replace').read()
    c = subprocess.run(['clang-format', '--style=' + json.dumps(clang_style), '--assume-filename=' + f],
                       input=src, capture_output=True, text=True).stdout
    n = subprocess.run([nedfmt, '-', '--stdin-name:' + os.path.abspath(f)], input=src, capture_output=True,
                       text=True, env=env)
    nout = n.stdout
    if n.returncode != 0 or (nout == src and c != src and 'left alone' in n.stderr):
        failed += 1
        print('%-40s  ned left it alone: %s' % (f, n.stderr.strip().splitlines()[-1:] or ''))
    if keep:
        os.makedirs(keep, exist_ok=True)
        b = os.path.basename(f)
        open(os.path.join(keep, b + '.clang'), 'w').write(c)
        open(os.path.join(keep, b + '.ned'), 'w').write(nout)
    a, b = c.split('\n'), nout.split('\n')
    sm = difflib.SequenceMatcher(None, a, b, autojunk=False)
    same = sum(bl.size for bl in sm.get_matching_blocks())
    total = max(len(a), len(b))
    tot_same += same; tot_lines += total
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == 'equal': continue
        if tag == 'replace' and i2 - i1 == j2 - j1:
            for x, y in zip(a[i1:i2], b[j1:j2]):
                k = kind_of(x, y); kinds[k] += 1
                examples.setdefault(k, []).append((f, x, y))
        else:
            kinds['line breaks'] += max(i2 - i1, j2 - j1)
            examples.setdefault('line breaks', []).append((f, '\n'.join(a[i1:i2][:3]), '\n'.join(b[j1:j2][:3])))
    print('%-40s %6d lines  %5.1f%% the same' % (f[-40:], total, 100.0 * same / max(1, total)))
print('\nall: %d of %d lines the same (%.1f%%) — style %s%s' % (tot_same, tot_lines, 100.0 * tot_same / max(1, tot_lines),
      style, (', ColumnLimit ' + col) if col else ''))
for k, cnt in kinds.most_common():
    print('  %-24s %d' % (k, cnt))
    for (f, x, y) in examples[k][:show]:
        print('      clang: %s\n      ned:   %s' % (x.replace('\n', ' ⏎ ')[:150], y.replace('\n', ' ⏎ ')[:150]))
shutil.rmtree(cfg, ignore_errors=True)
sys.exit(1 if failed else 0)
