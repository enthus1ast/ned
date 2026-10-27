#!/usr/bin/env python3
"""Compare ned's built-in Nim engine with nimsuggest on one file.
usage: compare.py FILE [--n N] [--seed S] [--no-hints] [--show K] [--json OUT]

  NED_DRIVER  the engine driver (build.sh makes it; default: ./ned-engine next to this script)
  NED_PKGS    the nimble packages folder (default: ~/.nimble/pkgs2), given to both
  NED_NS_CACHE  a folder for nimsuggest's answers: a file asked again (unchanged, same nimsuggest) needs no
              nimsuggest at all — comparing a new build of the engine takes seconds instead of minutes
  nimsuggest comes from PATH (the one installed with Nim).

What it measures, over the file:
  1. type hints: every `let`/`var`/`const` without a type, ned's hint against nimsuggest's `inlayHints`
  2. go to definition at --n random identifiers, against nimsuggest's `def`
  3. the types of the variables among them, against the type `def` reports
  4. member completion at --n random `x.member` places: is the member written there offered right after the dot?
  5. references: at a third of the places, the file's uses of what the name is, against nimsuggest's `use`
"""
import sys, re, random, subprocess, json, os, time, argparse
ap = argparse.ArgumentParser()
ap.add_argument('file'); ap.add_argument('--n', type=int, default=150); ap.add_argument('--seed', type=int, default=1)
ap.add_argument('--show', type=int, default=8); ap.add_argument('--no-hints', action='store_true')
ap.add_argument('--json', default='')
a = ap.parse_args()
path = os.path.abspath(a.file)
PKGS = os.environ.get('NED_PKGS', os.path.expanduser('~/.nimble/pkgs2'))
env = dict(os.environ)
KW = set("""addr and as asm bind block break case cast concept const continue converter defer discard distinct div do
elif else end enum except export finally for from func if import in include interface is isnot iterator let macro
method mixin mod nil not notin object of or out proc ptr raise ref return shl shr static template try tuple type
using var when while xor yield true false""".split())
lines = open(path, encoding='utf-8', errors='replace').read().split('\n')

def scan():
    """identifier positions outside strings and comments: (line1, bytecol, word, is_member)"""
    pos = []; in_triple = False; block = 0
    for li, s in enumerate(lines):
        i = 0; n = len(s)
        while i < n:
            if in_triple:
                e = s.find('"""', i)
                if e < 0: i = n; break
                i = e + 3; in_triple = False; continue
            if block:
                if s.startswith('#[', i): block += 1; i += 2
                elif s.startswith(']#', i): block -= 1; i += 2
                else: i += 1
                continue
            c = s[i]
            if c == '#':
                if s.startswith('#[', i) or s.startswith('##[', i): block = 1; i += 2; continue
                break
            if s.startswith('"""', i):
                e = s.find('"""', i + 3)
                if e < 0: in_triple = True; break
                i = e + 3; continue
            if c == '"':
                j = i + 1
                while j < n and s[j] != '"':
                    if s[j] == '\\': j += 1
                    j += 1
                i = j + 1; continue
            if c == "'" and not (i > 0 and (s[i-1].isalnum() or s[i-1] == '_')):
                j = i + 1
                if j < n and s[j] == '\\': j += 2
                else: j += 1
                while j < n and s[j] != "'" and j - i < 12: j += 1
                i = j + 1; continue
            if c.isalpha() or c == '_':
                j = i
                while j < n and (s[j].isalnum() or s[j] == '_'): j += 1
                w = s[i:j]
                member = i > 0 and s[i-1] == '.' and not (i > 1 and s[i-2] == '.')
                if w not in KW and len(w) > 1: pos.append((li + 1, len(s[:i].encode()), w, member))
                i = j; continue
            if c.isdigit():
                while i < n and (s[i].isalnum() or s[i] in '._'): i += 1
                continue
            i += 1
    return pos

pos = scan()
random.seed(a.seed)
sample = random.sample(pos, min(a.n, len(pos)))
members = [p for p in pos if p[3]]
msample = random.sample(members, min(a.n, len(members)))

drv = subprocess.Popen([os.environ.get('NED_DRIVER', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'ned-engine')), PKGS], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                       stderr=subprocess.DEVNULL, text=True, env=env, bufsize=1)
def eng(cmd, line=0, col=0):
    drv.stdin.write(json.dumps({'cmd': cmd, 'path': path, 'line': line, 'col': col}) + '\n'); drv.stdin.flush()
    return json.loads(drv.stdout.readline())

ns = None
ns_crashes = 0
def ns_start():
    global ns
    ns = subprocess.Popen(['nimsuggest', '--stdin', '--v4', '--maxresults:3000', '--nimblePath:' + PKGS, path],
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=env,
                          cwd=os.path.dirname(path), bufsize=1)

# nimsuggest's answers, kept by file (its text and the nimsuggest that answered)
CACHE_DIR = os.environ.get('NED_NS_CACHE', '')
cache, cache_file, cache_dirty = {}, '', False
if CACHE_DIR:
    import hashlib
    ver = subprocess.run(['nimsuggest', '--version'], capture_output=True, text=True).stdout.strip()
    key = hashlib.sha1((path + '\0' + open(path, 'rb').read().decode('utf-8', 'replace') + '\0' + ver + '\0' + PKGS)
                       .encode()).hexdigest()
    os.makedirs(CACHE_DIR, exist_ok=True)
    cache_file = os.path.join(CACHE_DIR, key + '.json')
    try: cache = json.load(open(cache_file))
    except Exception: cache = {}

NS_T = 0.0          # seconds nimsuggest took for the answers (as it took them, when they come from the cache)
def ask(cmd):
    """one nimsuggest answer (or the one kept for it); when it has crashed: started again, and this question
    has no answer"""
    global ns_crashes, cache_dirty, NS_T
    if cmd in cache:
        out, secs = cache[cmd]
        NS_T += secs
        return out
    if ns is None: ns_start()
    t0 = time.time()
    out = ask_ns(cmd)
    secs = time.time() - t0
    NS_T += secs
    if CACHE_DIR:
        cache[cmd] = [out, secs]
        cache_dirty = True
    return out

def ask_ns(cmd):
    global ns_crashes
    try:
        ns.stdin.write(cmd + '\n'); ns.stdin.flush()
        out = []
        while True:
            l = ns.stdout.readline()
            if l == '':
                raise BrokenPipeError()
            if l.rstrip('\n') == '': break
            out.append(l.rstrip('\n'))
        return out
    except (BrokenPipeError, OSError):
        ns_crashes += 1
        try: ns.kill()
        except Exception: pass
        ns_start()
        return []

def split_top(s, sep=','):
    # s split at `sep` outside () [] {}
    out = []; depth = 0; cur = ''
    for ch in s:
        if ch in '([{': depth += 1
        elif ch in ')]}': depth -= 1
        if ch == sep and depth == 0: out.append(cur); cur = ''
        else: cur += ch
    out.append(cur)
    return out

def normT(t):
    t = t.strip().lstrip(':').strip()
    if t == 'Error Type': return ''
    if t == 'iterator': t = 'proc'                             # (a parameter typed `iterator`: nimsuggest says proc)
    t = re.sub(r'\bvarargs\[([^,\[\]]+),[^\[\]]*\]', r'varargs[\1]', t)   # varargs[string, `$`]: its converter aside
    t = re.sub(r'\bint literal\(\d+\)', 'int', t)
    t = re.sub(r'\b(float|string|bool|char) literal\([^)]*\)', r'\1', t)
    t = re.sub(r'(\b[A-Z]\w*): \w+$', r'\1', t)                # T: SomeFloat, var T: distinct
    t = t.replace(' or ', '|')
    t = re.sub(r'^owned[ (]', '', t).rstrip(')') if t.startswith('owned') else t
    if 'proc' in t or 'iterator' in t:
        t = re.sub(r'\s*\{\.[^{}]*\}', '', t)                 # (pragmas, also of a proc type inside another: closure, gcsafe …)
    if t.startswith('proc') or t.startswith('iterator'):
        t = t.replace('proc(', 'proc (')
        # proc (a, b: T) → proc (a: T, b: T)   (a comma inside brackets — (A, B) — is not between parameters)
        m = re.match(r'^(proc|iterator) \((.*)\)(.*)$', t)
        if m:
            out = []; names = []
            for part in split_top(m.group(2)):
                part = part.strip()
                if ':' in part:
                    n, ty = part.split(':', 1)
                    for x in names + [n]: out.append(x.strip() + ':' + ty.strip())
                    names = []
                elif part: names.append(part)
            t = '%s (%s)%s' % (m.group(1), ','.join(out + names), m.group(3))
    t = re.sub(r'\b[A-Za-z_][A-Za-z0-9_]*\.', '', t)          # module qualifiers: system.int → int
    t = re.sub(r'^(lent|var|sink) ', '', t)                     # lent string is a string to read
    t = re.sub(r'\bfloat64\b', 'float', t)
    t = t.replace(' ', '')
    # array[0..1, T] → array[2,T]
    t = re.sub(r'array\[0\.\.(\d+),', lambda m: 'array[%d,' % (int(m.group(1)) + 1), t)
    # tuple[a,b:T] → tuple[a:T,b:T]
    def tup(m):
        out = []; names = []
        for part in m.group(1).split(','):
            if ':' in part:
                n, ty = part.split(':', 1)
                for x in names + [n]: out.append(x + ':' + ty)
                names = []
            else: names.append(part)
        return 'tuple[' + ','.join(out + names) + ']'
    t = re.sub(r'tuple\[([^\[\]]*)\]', tup, t)
    for a, b in (('cint', 'int32'), ('cuint', 'uint32'), ('clong', 'int'), ('culong', 'uint'), ('csize_t', 'uint'),
                 ('cchar', 'char'), ('cfloat', 'float32'), ('cdouble', 'float'), ('clonglong', 'int64'), ('cshort', 'int16')):
        t = re.sub(r'\b%s\b' % a, b, t)
    t = re.sub(r'^owned\((.*)\)$', r'\1', t)
    return t.lower().replace('_', '')

report = {'file': os.path.basename(path)}
t0 = NS_T; ask('def %s:1:0' % path); t_first = NS_T - t0

# 1. type hints over the whole file
if not a.no_hints:
    e = eng('hints')
    eh = {}
    for l, c, lab in e.get('hints', []): eh[(l, c)] = lab
    nh = {}
    t0 = NS_T
    rows = ask('inlayHints %s:1:0:%d:0' % (path, len(lines) + 1))
    t_hint = NS_T - t0
    for r in rows:
        f = r.split('\t')
        if len(f) >= 4 and f[0] == 'Type':
            try: nh[(int(f[1]) - 1, int(f[2]))] = f[3]
            except ValueError: pass
    # match by line + column (the column nimsuggest gives is after the name, as ned's)
    agree = diff = ns_only = ned_only = 0
    bad = []
    keys = set(eh) | set(nh)
    for k in sorted(keys):
        x, y = eh.get(k), nh.get(k)
        if y is not None and normT(y) == '': y = None      # (nimsuggest without an answer: ':')
        if x is None and y is None: continue
        if x is not None and y is not None:
            if normT(x) == normT(y) or (x.endswith('…') and normT(y).startswith(normT(x[:-1]))): agree += 1
            else: diff += 1; bad.append(('DIFF', k[0] + 1, k[1], x.strip(), y.strip(), lines[k[0]].strip()[:70]))
        elif y is not None:
            ns_only += 1; bad.append(('MISS', k[0] + 1, k[1], '', y.strip(), lines[k[0]].strip()[:70]))
        else: ned_only += 1
    report['hints'] = dict(agree=agree, differ=diff, nimsuggest_only=ns_only, ned_only=ned_only, ns_ms=int(t_hint * 1000))
    report['hint_bad'] = bad

# 2. go to definition and 3. the types of variables
st = dict(agree=0, ns_only=0, ned_only=0, disagree=0, neither=0)
tt = dict(agree=0, differ=0, ned_none=0)
bad = []; tbad = []
t_ns = t_ned = 0.0
for (l, c, w, m) in sample:
    t0 = NS_T; rows = [x.split('\t') for x in ask('def %s:%d:%d' % (path, l, c)) if x.startswith('def\t')]; t_ns += NS_T - t0
    if rows and (rows[0][1] == 'skUnknown' or '`gensym' in rows[0][2] or ':anonymous' in rows[0][2]): rows = []
    t0 = time.time(); ed = eng('def', l - 1, len(lines[l-1].encode()[:c].decode('utf-8', 'replace'))).get('defs', []); t_ned += time.time() - t0
    nsd = [(f[4], int(f[5])) for f in rows]
    ids = [(d[0], d[1] + 1) for d in ed]
    if not nsd and not ids: st['neither'] += 1
    elif nsd and not ids: st['ns_only'] += 1; bad.append(('MISS', l, c, w, nsd[:1], []))
    elif ids and not nsd: st['ned_only'] += 1
    elif any(x in ids for x in nsd): st['agree'] += 1
    else: st['disagree'] += 1; bad.append(('DIFF', l, c, w, nsd[:1], ids[:2]))
    if rows and rows[0][1] in ('skLet', 'skVar', 'skForVar', 'skParam', 'skResult', 'skConst', 'skField') and \
            not (rows[0][1] == 'skResult' and w != 'result'):    # (nimsuggest answers `result` at a routine's name)
        nt = rows[0][3]
        if not normT(nt): continue
        et = eng('type', l - 1, len(lines[l-1].encode()[:c].decode('utf-8', 'replace'))).get('type', '')
        if not et: tt['ned_none'] += 1; tbad.append(('NONE', l, w, '', nt))
        elif normT(et) == normT(nt): tt['agree'] += 1
        else: tt['differ'] += 1; tbad.append(('DIFF', l, w, et, nt))
report['def'] = st
report['def_ms'] = dict(nimsuggest=int(t_ns * 1000 / max(1, len(sample))), ned=round(t_ned * 1000 / max(1, len(sample)), 2))
report['def_bad'] = bad
report['types'] = tt
report['type_bad'] = tbad

# 4. member completion: is the member written there offered right after the dot?
found_ned = found_ns = 0
mbad = []
for (l, c, w, m) in msample:
    col_chars = len(lines[l-1].encode()[:c].decode('utf-8', 'replace'))
    items = eng('sug', l - 1, col_chars).get('items', [])
    norm = lambda s: (s[0] + s[1:].replace('_', '').lower()) if s else s
    if norm(w) in set(norm(x) for x in items): found_ned += 1
    else: mbad.append((l, w, lines[l-1].strip()[:80]))
    rows = [x.split('\t') for x in ask('sug %s:%d:%d' % (path, l, c)) if x.startswith('sug\t')]
    if norm(w) in set(norm(r[2].split('.')[-1]) for r in rows): found_ns += 1
report['sug'] = dict(n=len(msample), ned=found_ned, nimsuggest=found_ns)
report['sug_bad'] = mbad

# 5. references: at a third of the places, the file's uses of what the name is — ned's against nimsuggest's `use`.
# (Compared where nimsuggest resolves every name: not in runnableExamples, which it does not check, nor in a
# `when` branch not taken here, nor in the body of a template or a generic routine, where a name is bound when it
# is used. ned finds the uses there too — a rename changes them — and they are counted apart. So are the fields
# named in an object constructor — JsonNode(kind: JInt) —, which nimsuggest's `use` never lists. A place where
# nimsuggest answers about another name than the one written — the `items` a for loop calls, `defined` for the
# symbol inside defined(…) — is not a question about that name, and is left out, as is the code `quote do:` makes.
# The names in an export statement are left out on both sides (nimsuggest puts them where the statement starts),
# and for a routine those in import and from … import too: nimsuggest gives such a name to one overload of its
# choosing, ned to every overload of the name. And the name of a {.borrow.} routine, which nimsuggest lists as a use of the routine it
# borrows from — an implicit use, as the `items` of a for loop — is counted apart, as are the uses nimsuggest lists
# where another name is written)
rs = dict(same=0, n=0, ned_hidden=0, ned_ctor=0, import_lines=0, ns_borrow=0, ns_implicit=0)
def word_at(l1, bc):
    """the identifier at line l1 (1-based), byte column bc"""
    s = lines[l1 - 1] if l1 - 1 < len(lines) else ''
    ci = len(s.encode()[:bc].decode('utf-8', 'replace'))
    j = ci
    while j < len(s) and (s[j].isalnum() or s[j] == '_'): j += 1
    return s[ci:j]
ROUTINES = ('skProc', 'skFunc', 'skMethod', 'skIterator', 'skConverter', 'skTemplate', 'skMacro')
def stmt_word(l1):
    """the first word of the statement line l1 (1-based) is in, a list going on over the lines below followed up"""
    k = l1 - 1
    while k > 0 and lines[k][:1] in (' ', '\t'):
        prev = lines[k - 1].split('#')[0].rstrip()
        if not (prev.endswith((',', '[', '(')) or prev.strip() in ('import', 'export') or prev.endswith(' import')): break
        k -= 1
    t = lines[k].strip()
    return t.split(' ', 1)[0] if t else ''
def borrow_decl(l1, bc):
    """is the name at line l1, byte column bc, the name of a {.borrow.} routine where it is declared"""
    s = lines[l1 - 1]
    head = s[:len(s.encode()[:bc].decode('utf-8', 'replace'))].strip()
    if head.split(' ')[-1] not in ('proc', 'func', 'method', 'iterator', 'converter', 'template'): return False
    return any('borrow' in x for x in lines[l1 - 1:l1 + 3] if '{.' in x or '.}' in x)
rbad = []
hidden = eng('hidden', 0, 0).get('hidden', [])
def visible(l1):
    return not any(a <= l1 - 1 <= e for a, e in hidden)
def ctor_label(l1, bc):
    """is the name at line l1 (1-based), byte column bc, a field given in an object constructor: `T(name: v`,
    `T[A](⏎  name: v,` — the name followed by `:`, after `(` or `,`, inside an unclosed `(` written right after a
    type's name"""
    s = lines[l1 - 1]
    ci = len(s.encode()[:bc].decode('utf-8', 'replace'))
    j = ci
    while j < len(s) and (s[j].isalnum() or s[j] == '_'): j += 1
    while j < len(s) and s[j] == ' ': j += 1
    if j >= len(s) or s[j] != ':' or s[j + 1:j + 2] in (':', '='): return False
    li, k, depth, first = l1 - 1, ci - 1, 0, True
    while li >= 0 and l1 - 1 - li <= 30:
        t = lines[li]
        k = min(k, len(t) - 1)
        while k >= 0:
            ch = t[k]
            if first and ch != ' ':
                if ch not in '(,': return False
                first = False
            if ch in ')]}': depth += 1
            elif ch in '([{':
                if depth == 0:
                    if ch != '(' or k == 0: return False
                    b = t[k - 1]
                    return b.isalnum() or b in '_]'
                depth -= 1
            elif ch == '"':
                k -= 1
                while k >= 0 and t[k] != '"': k -= 1
            k -= 1
        li -= 1
        if li >= 0:
            k = len(lines[li]) - 1
            if first and lines[li].strip() and lines[li].rstrip()[-1] not in '(,': return False
    return False
nnorm = lambda s: (s[0] + s[1:].replace('_', '').lower()) if s else s
for (l, c, w, m) in sample[:max(1, len(sample) // 3)]:
    if not visible(l): continue          # (a place in code nimsuggest does not resolve: no question to compare)
    rows = [x.split('\t') for x in ask('def %s:%d:%d' % (path, l, c)) if x.startswith('def\t')]
    if not rows or rows[0][1] in ('skUnknown', 'skModule', 'skParam', 'skResult', 'skForVar', 'skTemp') or \
            '`gensym' in rows[0][2] or nnorm(rows[0][2].split('.')[-1].strip('`')) != nnorm(w) or \
            stmt_word(l) == 'export' or (rows[0][1] in ROUTINES and stmt_word(l) in ('import', 'from')):
        continue
    uses = [x.split('\t') for x in ask('use %s:%d:%d' % (path, l, c)) if x.startswith('use\t') or x.startswith('def\t')]
    ns_set = set((int(u[5]), int(u[6])) for u in uses if len(u) > 6 and u[4] == path and visible(int(u[5])))
    # (a qualified name — Event.Read —: nimsuggest puts it at its dot, ned at the name)
    ns_set = set((x[0], x[1] + 1) if lines[x[0] - 1].encode()[x[1]:x[1] + 1] == b'.' else x for x in ns_set)
    if not ns_set: continue
    col_bytes = c
    er = eng('refs', l - 1, len(lines[l-1].encode()[:col_bytes].decode('utf-8', 'replace'))).get('refs', [])
    ned_all = set((r[0] + 1, len(lines[r[0]][:r[1]].encode())) if r[0] < len(lines) else (r[0] + 1, r[1]) for r in er)
    ned_set = set(x for x in ned_all if visible(x[0]))
    rs['ned_hidden'] += len(ned_all) - len(ned_set)
    if rows[0][1] == 'skField':
        ctor = set(x for x in ned_set - ns_set if ctor_label(x[0], x[1]))
        rs['ned_ctor'] += len(ctor)
        ned_set -= ctor
    # (a use nimsuggest lists where another name is written — the variable of a fieldPairs loop, which stands for
    # each field in turn —: nothing there names it)
    implicit = set(x for x in ns_set - ned_set if nnorm(word_at(x[0], x[1])) != nnorm(w))
    rs['ns_implicit'] += len(implicit)
    ns_set -= implicit
    imp = set(x for x in ns_set | ned_set
              if stmt_word(x[0]) == 'export' or (rows[0][1] in ROUTINES and stmt_word(x[0]) in ('import', 'from')))
    rs['import_lines'] += len(imp)
    ns_set -= imp
    ned_set -= imp
    if rows[0][1] in ROUTINES:
        bor = set(x for x in ns_set - ned_set if borrow_decl(x[0], x[1]))
        rs['ns_borrow'] += len(bor)
        ns_set -= bor
    rs['n'] += 1
    if ned_set == ns_set: rs['same'] += 1
    else: rbad.append((l, w, sorted(ns_set - ned_set)[:3], sorted(ned_set - ns_set)[:3]))
report['refs'] = rs
report['refs_bad'] = rbad
report['ns_first_s'] = round(t_first, 1)
if CACHE_DIR:
    if ns is None: ns_crashes = cache.get('__crashes__', [0, 0])[0]     # (every answer came from the cache)
    else: cache['__crashes__'] = [ns_crashes, 0]
    if cache_dirty or ns is not None: json.dump(cache, open(cache_file, 'w'))
report['ns_crashes'] = ns_crashes
try:
    ns.stdin.write('quit\n'); ns.stdin.flush()
except Exception: pass
drv.stdin.close()
if a.json: json.dump(report, open(a.json, 'w'), indent=1)
print('== %s  (nimsuggest first answer %.1f s, crashed %d times)' % (report['file'], t_first, ns_crashes))
if 'hints' in report:
    h = report['hints']; tot = h['agree'] + h['differ'] + h['nimsuggest_only']
    print('  type hints: same %d · different %d · only nimsuggest %d · only ned %d  → %.1f%% of nimsuggest\'s' %
          (h['agree'], h['differ'], h['nimsuggest_only'], h['ned_only'], 100.0 * h['agree'] / max(1, tot)))
    for b in report['hint_bad'][:a.show]: print('    ', b)
d = report['def']; tot = d['agree'] + d['ns_only'] + d['disagree']
print('  definition: %.1f%% agree where nimsuggest answers (%s) · ned %s ms, nimsuggest %s ms per query' %
      (100.0 * d['agree'] / max(1, tot), d, report['def_ms']['ned'], report['def_ms']['nimsuggest']))
for b in report['def_bad'][:a.show]: print('    ', b)
t = report['types']; tot = t['agree'] + t['differ'] + t['ned_none']
print('  variable types: %.1f%% same as nimsuggest (%s)' % (100.0 * t['agree'] / max(1, tot), t))
for b in report['type_bad'][:a.show]: print('    ', b)
s = report['sug']
print('  member completion: ned %d/%d · nimsuggest %d/%d' % (s['ned'], s['n'], s['nimsuggest'], s['n']))
for b in report['sug_bad'][:a.show]: print('    ', b)
r = report['refs']
print('  references in the file: the same as nimsuggest\'s at %d of %d (and %d more in code nimsuggest does not read, '
      '%d fields named in object constructors, which its `use` leaves out; %d names in import/export statements and '
      '%d {.borrow.} routines and %d uses where another name is written left out)' %
      (r['same'], r['n'], r.get('ned_hidden', 0), r.get('ned_ctor', 0), r.get('import_lines', 0), r.get('ns_borrow', 0),
       r.get('ns_implicit', 0)))
for b in report['refs_bad'][:a.show]: print('    ', b)
