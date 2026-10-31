#!/usr/bin/env python3
"""ned's Go to definition graded by the compiler: Nim 2.4's `nim nif` writes what it made of each module, every name
resolved to its declaration — the answer for every use of a module's routine, type, constant, global or field in a
project. Each is asked of ned's engine (the driver build.sh makes) at the same place; they should agree.

Usage: nifgrade.py MAIN.nim [--nim PATH/TO/nim-2.4] [--driver ned-engine] [--max N] [--min PERCENT] [--show N]
Only the project's own files are graded (not the Nim library), and only a name written once on its line and not on
the lines beside it (the NIF's places are coarse: a node can have the line of the one before it). Exit 1 when the engine agrees less often than --min (default 0: report only)."""
import json, os, re, subprocess, sys, tempfile, collections

args = sys.argv[1:]
def opt(name, default):
    if name in args:
        i = args.index(name); v = args[i + 1]; del args[i:i + 2]; return v
    return default
NIM = opt('--nim', 'nim')
DRIVER = opt('--driver', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'ned-engine'))
MAX = int(opt('--max', '4000'))
MIN = float(opt('--min', '0'))
SHOW = int(opt('--show', '25'))
if not args: sys.exit(__doc__)
MAIN = os.path.abspath(args[0])
MAINDIR = os.path.dirname(MAIN)

B62 = {c: i for i, c in enumerate('0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz')}

def read_info(s, i):
    """the line information at s[i] (`@col,line,file`, `~` negative), or None — and where it ends"""
    if i >= len(s) or s[i] not in '@~': return None, i
    if s[i] == '@': i += 1
    nums = [0, 0]
    for k in range(2):
        neg = i < len(s) and s[i] == '~'
        if neg: i += 1
        v = 0
        while i < len(s) and s[i] in B62:
            v = v * 62 + B62[s[i]]; i += 1
        nums[k] = -v if neg else v
        if k == 0 and i < len(s) and s[i] == ',': i += 1
        elif k == 0: break
    f = ''
    if i < len(s) and s[i] == ',':
        i += 1; a = i
        while i < len(s) and s[i] not in ' \t\n()[]"\'#': i += 1
        f = s[a:i]
    return (nums[0], nums[1], f), i

def parse(text):
    """Nim 2.4's NIF: each token's place is written after the token before it. Gives (atom, is_def, tag of the node
    holding it, file, line from 0, col, exact) for every symbol atom — exact: its place written for it (or relative
    to a parent's that was), not one it took from the node around it (the NIF leaves out a place that is its
    parent's: most are not exact, so the grading does not ask for it)"""
    out = []
    stack = []          # (tag, file, line, col, exact)
    pending = None
    i, n = 0, len(text)
    def place(parent):
        """the next token's place: its own (relative to its parent's), else its parent's — and whether it is exact"""
        pf, pl, pc, pe = (parent[1], parent[2], parent[3], parent[4]) if parent else ('', -1, -1, False)
        if pending is None: return pf, pl, pc, False
        c, l, f = pending
        if f: return f, l - 1, c, True
        if pl >= 0: return pf, pl + l, pc + c, pe
        return '', l - 1, c, False
    while i < n:
        ch = text[i]
        if ch in ' \t\r\n': i += 1; continue
        if ch == '#':
            j = text.find('#', i + 1); i = j + 1 if j >= 0 else n; continue
        parent = stack[-1] if stack else None
        if ch == '(':
            j = i + 1
            while j < n and text[j] not in ' \t\n()@~#"\'': j += 1
            tag = text[i + 1:j]
            f, l, c, e = place(parent)
            stack.append((tag, f, l, c, e))
            pending, i = read_info(text, j)
            continue
        if ch == ')':
            if stack: stack.pop()
            pending, i = read_info(text, i + 1)
            continue
        if ch in '"\'':
            j = i + 1
            while j < n and text[j] != ch: j += 1
            pending, i = read_info(text, j + 1)
            continue
        j = i
        is_def = ch == ':'
        if is_def: j += 1
        while j < n and text[j] not in ' \t\n()@~#"': j += 1
        if j == i: i += 1; continue
        atom = text[i + 1 if is_def else i:j]
        f, l, c, e = place(parent)
        out.append((atom, is_def, parent[0] if parent else '', f, l, c, e))
        pending, i = read_info(text, j)
    return out

def norm(s):
    return s[:1] + s[1:].replace('_', '').lower() if s else s

def main():
    cache = tempfile.mkdtemp(prefix='ned-nifgrade-')
    r = subprocess.run([NIM, 'nif', '--hints:off', '--warnings:off', '--nimcache:' + cache, MAIN], cwd=MAINDIR,
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit('nim nif failed:\n' + (r.stdout + r.stderr)[-2000:])
    defs = {}                     # module symbol → (file, line, col)
    uses = []                     # (file, line, symbol)
    for f in os.listdir(cache):
        if not f.endswith('.nim2.nif'): continue
        for atom, is_def, tag, src, line, col, exact in parse(open(os.path.join(cache, f), encoding='utf-8', errors='replace').read()):
            if atom.count('.') < 2 or '`' in atom or not re.match(r'[A-Za-z_\x80-\xff]', atom): continue
            path = os.path.normpath(src if os.path.isabs(src) else os.path.join(MAINDIR, src)) if src else ''
            if not path or line < 0: continue
            if is_def:
                if tag in ('proc', 'func', 'iterator', 'converter', 'method', 'template', 'macro', 'type', 'const',
                           'let', 'var', 'fld', 'efld'):
                    defs.setdefault(atom, (path, line, col))
            elif path.startswith(MAINDIR + os.sep):
                uses.append((path, line, atom, exact))
    # (each place once: a name written once on its line, one symbol of that name there in the NIF — a template's or
    # a generic's open choice names several — its declaration known)
    per_line = collections.defaultdict(set)
    for path, line, sym, _ in uses: per_line[(path, line, norm(sym.split('.')[0]))].add(sym)
    seen = set(); asks = []
    lines_of = {}
    for path, line, sym, exact in uses:
        if sym not in defs or (path, line, sym) in seen or len(per_line[(path, line, norm(sym.split('.')[0]))]) > 1:
            continue
        seen.add((path, line, sym))
        if path not in lines_of:
            try: lines_of[path] = open(path, encoding='utf-8', errors='replace').read().split('\n')
            except OSError: lines_of[path] = []
        ls = lines_of[path]
        if line >= len(ls): continue
        name = sym.split('.')[0]
        code = re.sub(r'"(\\.|[^"\\])*"', lambda m: ' ' * len(m.group()), ls[line])   # (strings blanked: a # in one)
        code = code[:code.index('#')] if '#' in code else code                      # (not in a comment)
        hits = [m.start() for m in re.finditer(r'[A-Za-z_\x80-\xff][\w\x80-\xff]*', code) if norm(m.group()) == norm(name)]
        if len(hits) != 1: continue
        # (the NIF can give a node of the next line — or the one before — this line's place: a name written on a
        # line beside this one too is not asked, its answer may be that line's)
        def near(k):
            if not 0 <= k < len(ls): return False
            c = re.sub(r'"(\\.|[^"\\])*"', '', ls[k])
            c = c[:c.index('#')] if '#' in c else c
            return any(norm(m.group()) == norm(name) for m in re.finditer(r'[A-Za-z_\x80-\xff][\w\x80-\xff]*', c))
        if near(line - 1) or near(line + 1): continue
        # (`for x in items:` names a variable; the NIF has the `items` iterator the compiler called on it)
        if name in ('items', 'pairs', 'mitems', 'mpairs') and re.search(r'\bin\s+' + name + r'\s*:', code): continue
        if defs[sym][0] == path and defs[sym][1] == line: continue          # (the declaration itself)
        # (the engine's columns are bytes, as Nim's: a — or an é before the name counts for more than one)
        asks.append((path, line, len(ls[line][:hits[0]].encode('utf-8')), sym))
    asks = asks[:MAX]
    drv = subprocess.Popen([DRIVER], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                           bufsize=1)
    agree = 0; wrong = []; none = 0; tmpl = 0
    kinds = collections.Counter()
    for path, line, col, sym in asks:
        drv.stdin.write(json.dumps({'cmd': 'def', 'path': path, 'line': line, 'col': col}) + '\n'); drv.stdin.flush()
        got = json.loads(drv.stdout.readline()).get('defs', [])
        want = defs[sym]
        name = sym.split('.')[0]
        def same(g):
            # (the same place — or, of a routine declared ahead (`proc p*(…)` then its body further on), its body)
            gp = os.path.normpath(g[0])
            if gp != want[0]: return False
            if g[1] == want[1]: return True
            ls = lines_of.get(gp)
            if ls is None:
                try: ls = lines_of[gp] = open(gp, encoding='utf-8', errors='replace').read().split('\n')
                except OSError: return False
            return 0 <= g[1] < len(ls) and re.match(r'\s*(proc|func|method|iterator|converter|template|macro)\s+`?' +
                                                  re.escape(name) + r'\b', ls[g[1]]) is not None
        def sig(path, line):
            # (a declaration's first line without its pragmas, `;` as `,`: the same routine declared twice for two
            # configurations — system.nim's `add` and seqs_v2's — is one answer; `nim nif` does not define nimSeqsV2)
            ls = lines_of.get(path)
            if ls is None:
                try: ls = lines_of[path] = open(path, encoding='utf-8', errors='replace').read().split('\n')
                except OSError: return None
            if not 0 <= line < len(ls): return None
            t = re.sub(r'\{\..*', '', ls[line]).replace(';', ',')
            return ' '.join(t.split()) if re.match(r'\s*(proc|func|template|macro|iterator|converter|method)\b', t) else None
        ws = sig(want[0], want[1])
        def src_line(path, line):
            # (a line of a file, read once)
            if path not in lines_of:
                try: lines_of[path] = open(path, encoding='utf-8', errors='replace').read().split('\n')
                except OSError: lines_of[path] = []
            ls = lines_of[path]
            return ls[line] if 0 <= line < len(ls) else ''
        # (the engine says a template: the NIF has what the template made — `w.lines` as `w.lr.lines` —, not the call)
        if not any(same(g) for g in got) and \
           any(re.match(r'\s*template\s+`?' + re.escape(name) + r'\b', src_line(os.path.normpath(g[0]), g[1])) for g in got):
            tmpl += 1
            continue
        if any(same(g) for g in got) or (ws and any(sig(os.path.normpath(g[0]), g[1]) == ws for g in got)): agree += 1
        else:
            if not got: none += 1
            wrong.append((path, line, col, sym, want, got))
    drv.stdin.close(); drv.wait()
    total = len(asks) - tmpl
    pct = 100.0 * agree / total if total else 100.0
    print(f'{total} uses asked: the engine agrees with the compiler on {agree} ({pct:.1f}%), '
          f'goes elsewhere on {len(wrong) - none}, has no answer on {none}' +
          (f' ({tmpl} template calls not graded: the NIF has what they made)' if tmpl else ''))
    for path, line, col, sym, want, got in wrong[:SHOW]:
        text = lines_of[path][line].strip()[:90]
        where = (os.path.relpath(got[0][0], MAINDIR) + ':' + str(got[0][1] + 1)) if got else 'nothing'
        print(f'  {os.path.relpath(path, MAINDIR)}:{line + 1}:{col + 1} {sym.split(".")[0]}: compiler '
              f'{os.path.relpath(want[0], MAINDIR)}:{want[1] + 1}, engine {where}   | {text}')
    subprocess.run(['rm', '-rf', cache])
    if pct < MIN: sys.exit(1)

main()
