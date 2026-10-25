#!/usr/bin/env python3
"""ned's Nim engine checks as you type (before the compiler runs) against `nim check`: the same files, clean and
with mistakes made in them on purpose.

  python3 tests/engine/diagcompare.py ENGINE OUT.json FILE.nim … [--n 6] [--seed 1]

ENGINE is the engine driver (tests/engine/build.sh). Each file is copied into a folder of its own (`nim check` is
given --path: to the file's folder, so its imports resolve as they do for it), then:

  clean     the file as it is (it compiles): every error the engine reports there is a wrong one
  mistakes  --n copies, each with one mistake the compiler must report — a name misspelled where it is used (two letters swapped), a
            `discard` taken off a call whose value is not used, a string given to a proc's int parameter — and the
            question: does the engine report an error (or warning) on that line, as `nim check` does?

The totals: the share of the compiler's errors the engine finds as you type, and the share of clean files with no
wrong error from it."""
import json, os, random, re, shutil, subprocess, sys, tempfile

if len(sys.argv) < 4:
    print(__doc__)
    sys.exit(2)
eng_path, out_path = sys.argv[1], sys.argv[2]
args = sys.argv[3:]
n = 6
seed = 1
files = []
i = 0
while i < len(args):
    if args[i] == '--n': n = int(args[i + 1]); i += 2
    elif args[i] == '--seed': seed = int(args[i + 1]); i += 2
    else: files.append(args[i]); i += 1
random.seed(seed)

drv = subprocess.Popen([eng_path], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)


def eng(cmd, path, text=None, line=0, col=0):
    q = {'cmd': cmd, 'path': path, 'line': line, 'col': col}
    if text is not None: q['text'] = text
    drv.stdin.write(json.dumps(q) + '\n')
    drv.stdin.flush()
    return json.loads(drv.stdout.readline())


ERR = re.compile(r'^(.*?)\((\d+), (\d+)\) (Error|Warning): (.*)$')


def nim_check(path, incdir):
    """the compiler's errors in the file: {line (0-based): message}"""
    r = subprocess.run(['nim', 'check', '--hints:off', '--warnings:off', '--colors:off', '--listFullPaths:on',
                        '--path:' + incdir, path], capture_output=True, text=True, timeout=300, cwd=os.path.dirname(path))
    errs = {}
    for l in (r.stdout + r.stderr).splitlines():
        m = ERR.match(l.strip())
        if m and m.group(4) == 'Error' and os.path.abspath(m.group(1)) == os.path.abspath(path):
            errs.setdefault(int(m.group(2)) - 1, m.group(5))
    return errs


KW = set("""addr and as asm bind block break case cast concept const continue converter defer discard distinct div do
elif else end enum except export finally for from func if import in include interface is isnot iterator let macro
method mixin mod nil not notin object of or out proc ptr raise ref return shl shr static template try tuple type
using var when while xor yield true false result""".split())


def code_lines(lines):
    """the lines that are code (not in a string over lines, not a comment), with their indentation"""
    res = []
    triple = False
    for i, s in enumerate(lines):
        t = s.strip()
        if triple:
            if t.count('"""') % 2 == 1: triple = False
            continue
        if t.count('"""') % 2 == 1:
            triple = True
            continue
        if not t or t.startswith('#'): continue
        res.append(i)
    return res


def mistakes(lines, k):
    """k copies of the text, each with one mistake: (the text, the line, what)"""
    out = []
    code = code_lines(lines)
    procs = set()
    for i in code:
        m = re.match(r'\s*(proc|func)\s+(\w+)\*?\s*(\[.*?\])?\s*\(([^)]*)\)', lines[i])
        if m: procs.add(m.group(2))
    # the lines each kind of mistake can be made on
    cand = {'name': [], 'discard': [], 'type': []}
    for i in code:
        s = lines[i]
        if re.search(r'\b([A-Za-z]\w*)\(', s) and not re.match(r'\s*(proc|func|template|macro|iterator|method)\b', s):
            cand['name'].append(i)
        if re.match(r'\s*discard \w[\w.]*\(.*\)\s*$', s): cand['discard'].append(i)
        if re.match(r'\s*(proc|func|iterator|method)\b.*\)[^=]*=\s*$', s): cand['type'].append(i)
    kinds = [x for x in ['name', 'name', 'discard', 'type', 'type'] if cand[x]]
    done = set()
    tries = 0
    while kinds and len(out) < k and tries < 400:
        tries += 1
        kind = random.choice(kinds)
        i = random.choice(cand[kind])
        if (kind, i) in done: continue
        done.add((kind, i))
        s = lines[i]
        if kind == 'name':
            # a call of one of the file's procs, the name misspelled
            ws = [m for m in re.finditer(r'\b([A-Za-z]\w*)\(', s) if m.group(1) in procs and m.group(1) not in KW]
            if not ws or re.match(r'\s*(proc|func|template|macro|iterator|method)\b', s): continue
            m = random.choice(ws)
            w = m.group(1)
            if len(w) < 4: continue
            # (two letters swapped in the middle, as a typing slip makes them)
            k = len(w) // 2
            bad = w[:k - 1] + w[k] + w[k - 1] + w[k + 1:]
            if bad == w or bad in procs: continue
            t = s[:m.start(1)] + bad + s[m.end(1):]
            out.append((lines[:i] + [t] + lines[i + 1:], i, 'misspelled ' + w + ' as ' + bad))
        elif kind == 'discard':
            m = re.match(r'(\s*)discard (\w[\w.]*\(.*\))\s*$', s)
            if not m: continue
            t = m.group(1) + m.group(2)
            out.append((lines[:i] + [t] + lines[i + 1:], i, 'no discard'))
        else:
            # a string where an int is wanted: a new first line in a routine's body (where a statement surely goes)
            if not re.match(r'\s*(proc|func|iterator|method)\b.*\)[^=]*=\s*$', s) or s.rstrip().endswith('=='):
                continue
            j = i + 1
            while j < len(lines) and not lines[j].strip(): j += 1
            if j >= len(lines): continue
            ind = len(lines[j]) - len(lines[j].lstrip())
            if ind <= len(s) - len(s.lstrip()): continue
            t = ' ' * ind + 'let qzxWrong: int = "not a number"'
            out.append((lines[:j] + [t] + lines[j:], j, 'string for int'))
    return out


report = {'files': [], 'clean_files': 0, 'clean_ok': 0, 'mistakes': 0, 'compiler_found': 0, 'engine_found': 0}
tmp = tempfile.mkdtemp(prefix='ned-diag-')
try:
    for f in files:
        name = os.path.basename(f)
        d = os.path.join(tmp, os.path.splitext(name)[0])
        os.makedirs(d, exist_ok=True)
        p = os.path.join(d, name)
        text = open(f, encoding='utf-8', errors='replace').read()
        lines = text.split('\n')
        open(p, 'w').write(text)
        inc = os.path.dirname(os.path.abspath(f))
        base_errs = nim_check(p, inc)
        fr = {'file': f, 'wrong': [], 'missed': [], 'found': 0, 'n': 0}
        if not base_errs:
            report['clean_files'] += 1
            ds = eng('checks', p, text).get('checks', [])
            wrong = [x for x in ds if x[2] == 1]
            fr['wrong'] = wrong[:8]
            if not wrong: report['clean_ok'] += 1
        for (ls, line, what) in mistakes(lines, n):
            t = '\n'.join(ls)
            open(p, 'w').write(t)
            errs = nim_check(p, inc)
            if line not in errs: continue          # (the compiler did not see a mistake there: not asked)
            report['mistakes'] += 1
            report['compiler_found'] += 1
            fr['n'] += 1
            ds = eng('checks', p, t).get('checks', [])
            if any(x[0] == line and x[2] <= 2 for x in ds):
                report['engine_found'] += 1
                fr['found'] += 1
            else: fr['missed'].append((line + 1, what, errs[line][:90]))
        open(p, 'w').write(text)
        report['files'].append(fr)
        print('%-24s mistakes the compiler reports: %d, the engine as you type: %d · wrong errors in the clean file: %s'
              % (name, fr['n'], fr['found'], len(fr['wrong']) if not base_errs else '(it does not compile here)'),
              flush=True)
        for m in fr['missed'][:4]: print('    missed', m)
        for w in fr['wrong'][:4]: print('    wrong', w)
finally:
    shutil.rmtree(tmp, ignore_errors=True)
    try: drv.stdin.close()
    except Exception: pass
json.dump(report, open(out_path, 'w'), indent=1)
print('engine checks: %d of %d of the compiler\'s errors found as you type; %d of %d clean files with no wrong error' %
      (report['engine_found'], report['compiler_found'], report['clean_ok'], report['clean_files']))
