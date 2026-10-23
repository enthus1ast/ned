#!/usr/bin/env python3
"""What ned's Nim engine answers in a .nim, a .nims, a .nimble and a plugin — against nimsuggest where it answers
too, against what the file's own API says where it does not (NimScript files: nimsuggest reads them as programs).

usage: parity.py [--nedls PATH] [--n N] [--seed S] [--show K] [--json OUT] [--min-hover P] FILE ...

ned's answers come from nedls (the engine as a language server: what ned's editor answers too), nimsuggest's
from `nimsuggest --stdin` on PATH.

A .nim file (compared with nimsuggest, at --n random places each):
  hover       nimsuggest's `def` knows the name: ned's hover is there, names the same declaration (its file and
              line), and shows its doc comment when it has one
  completion  at the end of a name nimsuggest's `sug` offers: ned offers it too
  signature   just inside `name(`: ned's signature help is name's (nimsuggest's `con`)
A .nims, a .nimble, a plugin (plugin.nims / plugin.nim, anything importing nedplugin):
  every name of system's NimScript part, nimble's API or ned's plugin API used in it has a hover with its doc
  comment and is offered by completion; and the share of all its names with a hover

Exit status 1 when a share is under --min-hover (default 0: report only).
"""
import sys, os, re, json, random, subprocess, argparse, time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO, 'tests', 'lsp'))
from tnedls import Client                                     # (the LSP client of nedls' own tests)

ap = argparse.ArgumentParser()
ap.add_argument('files', nargs='+')
ap.add_argument('--nedls', default=os.path.join(REPO, 'nedls'))
ap.add_argument('--n', type=int, default=40)
ap.add_argument('--seed', type=int, default=1)
ap.add_argument('--show', type=int, default=6)
ap.add_argument('--json', default='')
ap.add_argument('--min-hover', type=float, default=0.0)
a = ap.parse_args()

KW = set("""addr and as asm bind block break case cast concept const continue converter defer discard distinct div do
elif else end enum except export finally for from func if import in include interface is isnot iterator let macro
method mixin mod nil not notin object of or out proc ptr raise ref return shl shr static template try tuple type
using var when while xor yield true false result""".split())

def norm(s):
    """Nim's style insensitivity: the first letter as it is, then no case, no underscores"""
    return s[:1] + s[1:].replace('_', '').lower() if s else s

def scan(lines):
    """identifier positions outside strings and comments: (line0, col0, word, member)"""
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
            if c == "'" and not (i > 0 and (s[i - 1].isalnum() or s[i - 1] == '_')):
                j = i + 1
                if j < n and s[j] == '\\': j += 2
                else: j += 1
                while j < n and s[j] != "'" and j - i < 12: j += 1
                i = j + 1; continue
            if c.isalpha() or c == '_':
                j = i
                while j < n and (s[j].isalnum() or s[j] == '_'): j += 1
                w = s[i:j]
                member = i > 0 and s[i - 1] == '.' and not (i > 1 and s[i - 2] == '.')
                if w not in KW and len(w) > 1: pos.append((li, i, w, member))
                i = j; continue
            if c.isdigit():
                while i < n and (s[i].isalnum() or s[i] in '._'): i += 1
                continue
            i += 1
    return pos

def exported_names(path, block=None):
    """the names a module exports (name* in a declaration), and whether each has a doc comment"""
    try: text = open(path, encoding='utf-8', errors='replace').read()
    except OSError: return {}
    if block:
        k = text.find(block[0]); e = text.find(block[1], k + 1)
        text = text[k:e] if k >= 0 and e > k else ''
    out = {}
    L = text.split('\n')
    for i, l in enumerate(L):
        for m in re.finditer(r'(?:^|\b(?:proc|func|template|macro|iterator|converter|var|let|const)\s+|^\s+|,\s*)'
                             r'`?([A-Za-z_]\w*)`?\*', l):
            name = m.group(1)
            if name in KW: continue
            doc = '##' in l or any(L[k].strip().startswith('##') for k in range(i + 1, min(i + 4, len(L))))
            out[name] = out.get(name, False) or doc
    return out

def project_root(path):
    d = os.path.dirname(path)
    while True:
        try: names = os.listdir(d)
        except OSError: names = []
        if any(n.endswith('.nimble') for n in names) or 'nim.cfg' in names or 'config.nims' in names:
            return d
        up = os.path.dirname(d)
        if up == d: return os.path.dirname(path)
        d = up

def nimlib():
    try:
        o = subprocess.run(['nim', 'dump', '--dump.format:json', '-'], input='', capture_output=True, text=True,
                           timeout=60).stdout
        return json.loads(o[o.find('{'):])['libpath']
    except Exception:
        nim = subprocess.run(['sh', '-c', 'command -v nim'], capture_output=True, text=True).stdout.strip()
        return os.path.join(os.path.dirname(os.path.dirname(os.path.realpath(nim))), 'lib')

LIB = nimlib()
API = {'nimscript': exported_names(os.path.join(LIB, 'system', 'nimscript.nim')),
       'nimble': exported_names(os.path.join(REPO, 'src/ned/nim/index/nimscript.nim'),
                                ('NxNimbleApi = """', '"""\n')),
       'plugin': {**exported_names(os.path.join(REPO, 'src/ned/plugins/lib/nedplugin.nim')),
                  **exported_names(os.path.join(REPO, 'src/ned/plugins/lib/nedlsp.nim'))}}

class Ned:
    def __init__(self, root):
        self.c = Client([a.nedls], root)
        self.c.request('initialize', {'processId': None, 'rootUri': 'file://' + root, 'capabilities': {
            'textDocument': {'hover': {'contentFormat': ['markdown']}}}})
        self.c.notify('initialized', {})
    def open(self, path, text):
        self.uri = 'file://' + path
        lang = 'nim'
        self.c.notify('textDocument/didOpen', {'textDocument': {'uri': self.uri, 'languageId': lang, 'version': 1,
                                                                 'text': text}})
    def hover(self, l, c):
        r = self.c.request('textDocument/hover', {'textDocument': {'uri': self.uri},
                                                  'position': {'line': l, 'character': c}}, 30)
        v = (r or {}).get('result') or {}
        cont = v.get('contents', '')
        if isinstance(cont, dict): return cont.get('value', '')
        if isinstance(cont, list): return '\n'.join(x if isinstance(x, str) else x.get('value', '') for x in cont)
        return cont or ''
    def complete(self, l, c):
        r = self.c.request('textDocument/completion', {'textDocument': {'uri': self.uri},
                                                       'position': {'line': l, 'character': c}}, 30)
        res = (r or {}).get('result')
        items = res.get('items', []) if isinstance(res, dict) else (res or [])
        return [it.get('filterText') or it.get('label', '') for it in items]
    def signature(self, l, c):
        r = self.c.request('textDocument/signatureHelp', {'textDocument': {'uri': self.uri},
                                                          'position': {'line': l, 'character': c}}, 30)
        v = (r or {}).get('result') or {}
        return [s.get('label', '') for s in v.get('signatures', [])]
    def definition(self, l, c):
        r = self.c.request('textDocument/definition', {'textDocument': {'uri': self.uri},
                                                       'position': {'line': l, 'character': c}}, 30)
        v = (r or {}).get('result') or []
        if isinstance(v, dict): v = [v]
        return [(x.get('uri') or x.get('targetUri', '')).replace('file://', '') for x in v]
    def symbols(self):
        r = self.c.request('textDocument/documentSymbol', {'textDocument': {'uri': self.uri}}, 30)
        out = []
        def walk(xs):
            for x in xs or []:
                out.append(x.get('name', ''))
                walk(x.get('children'))
        walk((r or {}).get('result'))
        return out
    def close(self):
        try: self.c.p.kill()
        except Exception: pass

class NimSuggest:
    def __init__(self, path, root):
        self.path = path
        self.p = subprocess.Popen(['nimsuggest', '--stdin', '--v4', '--maxresults:3000', path], cwd=root,
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                                  bufsize=1)
        self.ask('chk %s:1:0' % path)
    def ask(self, cmd):
        try:
            self.p.stdin.write(cmd + '\n'); self.p.stdin.flush()
            out = []
            while True:
                l = self.p.stdout.readline()
                if not l: return out
                l = l.rstrip('\n')
                if l == '': return out
                if l.startswith(('usage:', "type '")): continue
                out.append(l.split('\t'))
        except (BrokenPipeError, OSError):
            return []
    def at(self, cmd, l, c): return self.ask('%s %s:%d:%d' % (cmd, self.path, l + 1, c))
    def close(self):
        try: self.p.kill()
        except Exception: pass

def unquote_doc(s):
    s = s.strip()
    if s.startswith('"') and s.endswith('"'):
        s = s[1:-1]
    s = re.sub(r'\\x([0-9A-Fa-f]{2})', lambda m: chr(int(m.group(1), 16)), s)     # (nimsuggest's escapes)
    return s.replace('\\\\', '\\').replace('\\"', '"')

def words(s):
    s = re.sub(r'\s*<[^<>\s]*>`_', '`', s)                       # (RST links: their text)
    s = re.sub(r'`_\b', '`', s)
    return re.sub(r'[^a-z0-9]+', ' ', s.lower()).split()

def doc_shown(doc, hover):
    """the doc comment's first words are in the hover (markup, line breaks and escapes aside)"""
    w = words(doc)[:6]
    if not w: return True
    h = ' '.join(words(hover))
    return ' '.join(w) in h

totals = {}
def add(kind, ok):
    t = totals.setdefault(kind, [0, 0]); t[0] += 1; t[1] += 1 if ok else 0

report = {}
for f in a.files:
    path = os.path.abspath(f)
    try: text = open(path, encoding='utf-8', errors='replace').read()
    except OSError as e:
        print('%-60s  skipped: %s' % (f, e.strerror)); continue
    lines = text.split('\n')
    root = project_root(path)
    script = path.endswith('.nims') or path.endswith('.nimble')
    plugin = re.search(r'^\s*import\s+.*\bned(plugin|lsp)\b', text, re.M) is not None
    ned = Ned(root); ned.open(path, text)
    time.sleep(1.0)
    pos = scan(lines)
    random.seed(a.seed)
    misses = {}
    def miss(kind, what):
        misses.setdefault(kind, []).append(what)
    t0 = time.time()
    if script or plugin:
        apis = {}
        if script: apis.update(API['nimscript'])
        if path.endswith('.nimble'): apis.update(API['nimble'])
        if plugin: apis.update(API['plugin'])
        napi = {norm(k): (k, d) for k, d in apis.items()}
        seen = set()
        anyhover = 0
        sample = pos if len(pos) <= 4 * a.n else random.sample(pos, 4 * a.n)
        for (l, c, w, member) in sample:
            if len(w) < 3: continue
            h = ned.hover(l, c + 1)
            anyhover += 1 if h.strip() else 0
            add('names with a hover (scripts, plugins)', bool(h.strip()))
            if not h.strip(): miss('names with a hover (scripts, plugins)', '%d:%d %s' % (l + 1, c + 1, w))
            k = norm(w)
            if k in napi and (w, l) not in seen:
                seen.add((w, l))
                # (the API's declaration this hover is about — its file and line in the footer: does it have a
                # doc comment? Then the hover shows it)
                at = re.findall(r'([\w.-]+\.nims?):(\d+)', h)
                api_file = {'nedplugin.nim': os.path.join(REPO, 'src/ned/plugins/lib/nedplugin.nim'),
                            'nedlsp.nim': os.path.join(REPO, 'src/ned/plugins/lib/nedlsp.nim'),
                            'nimscript.nim': os.path.join(LIB, 'system', 'nimscript.nim')}
                hasdoc = None
                for fn, ln in at:
                    if fn in api_file:
                        L = open(api_file[fn], encoding='utf-8', errors='replace').read().split('\n')
                        n0 = int(ln) - 1
                        routine = re.match(r'\s*```nim\s*\n\s*(proc|func|template|macro|iterator|converter)\b', h)
                        # (a routine: its doc comment under it; a field or a variable: on its own line)
                        hasdoc = any('##' in L[q] for q in range(n0, min(n0 + (4 if routine else 1), len(L))))
                if 'nimble · what a .nimble file has' in h: hasdoc = True
                if not h.strip():
                    ok = False
                elif hasdoc is None:
                    continue                                  # (a local or a field of the same name)
                else:
                    prose = re.sub(r'```.*?```', '', h, flags=re.S)
                    ok = not hasdoc or len([x for x in prose.split('\n') if x.strip()]) >= 2
                add('API names: hover with its doc', ok)
                if not ok: miss('API names: hover with its doc', '%d:%d %s' % (l + 1, c + 1, w))
                labels = ned.complete(l, c + len(w) - 1)          # (the name typed but its last letter)
                ok = any(norm(x) == k for x in labels)
                add('API names: offered by completion', ok)
                if not ok: miss('API names: offered by completion', '%d:%d %s' % (l + 1, c + 1, w))
                if hasdoc is not None and 'nimble · ' not in h:
                    ds = ned.definition(l, c + 1)
                    ok = any(os.path.basename(d) in ('nedplugin.nim', 'nedlsp.nim', 'nimscript.nim') for d in ds)
                    add('API names: go to definition', ok)
                    if not ok: miss('API names: go to definition', '%d:%d %s → %s' % (l + 1, c + 1, w, ds[:1]))
        # a script's tasks in its outline (Go to symbol, the breadcrumbs)
        tasks = re.findall(r'^task\s+(\w+)', text, re.M)
        if tasks:
            syms = ned.symbols()
            for t in tasks:
                ok = any(t == x or x.endswith(' ' + t) or x.startswith(t + ' ') for x in syms)
                add('tasks in the outline', ok)
                if not ok: miss('tasks in the outline', t)
    else:
        ns = NimSuggest(path, root)
        for (l, c, w, member) in random.sample(pos, min(a.n, len(pos))):
            d = ns.at('def', l, c)
            d = [x for x in d if x and x[0] == 'def' and len(x) > 7]
            if not d: continue
            nsfile, nsline, nsdoc = d[0][4], int(d[0][5]), unquote_doc(d[0][7])
            h = ned.hover(l, c + 1)
            add('hover: there', bool(h.strip()))
            if not h.strip():
                miss('hover: there', '%d:%d %s' % (l + 1, c + 1, w)); continue
            at = re.findall(r'([\w.-]+\.nims?):(\d+)', h)
            mod = re.search(r'^module (\S+)', h.replace('```nim\n', ''), re.M)
            over = re.search(r'\d+ overloads · (?:std/)?(\S+)(.*)', h)
            if mod:                                       # a module: its file
                same = os.path.splitext(os.path.basename(nsfile))[0] == mod.group(1).split('/')[-1]
            elif over:                                    # overloads (each shown): the module they are in
                base = os.path.splitext(os.path.basename(nsfile))[0]
                same = base == over.group(1) or (over.group(1) == 'system' and (
                    base == 'system' or '/system/' in nsfile or ('NimScript' in over.group(2) and base == 'nimscript')))
            elif at:
                same = (os.path.basename(nsfile), str(nsline)) in at
            else:
                same = os.path.realpath(nsfile) == os.path.realpath(path)      # (a local: no place given)
            add('hover: the same declaration', same)
            if not same: miss('hover: the same declaration', '%d:%d %s → nimsuggest %s:%d, ned %s' % (
                l + 1, c + 1, w, os.path.basename(nsfile), nsline, ', '.join(':'.join(x) for x in at[:2]) or '-'))
            if nsdoc.strip():
                ok = doc_shown(nsdoc, h)
                add('hover: its doc comment', ok)
                if not ok: miss('hover: its doc comment', '%d:%d %s' % (l + 1, c + 1, w))
        for (l, c, w, member) in random.sample(pos, min(a.n, len(pos))):
            if len(w) < 3: continue
            s = ns.at('sug', l, c + len(w) - 1)                    # (the name typed but its last letter)
            offered = {norm(x[2].split('.')[-1]) for x in s if len(x) > 2 and x[0] == 'sug'}
            if norm(w) not in offered: continue
            labels = ned.complete(l, c + len(w) - 1)
            ok = any(norm(x) == norm(w) for x in labels)
            add('completion: the name offered', ok)
            if not ok: miss('completion: the name offered', '%d:%d %s' % (l + 1, c + 1, w))
        calls = [(l, c, w) for (l, c, w, m) in pos if c + len(w) < len(lines[l]) and lines[l][c + len(w)] == '(']
        for (l, c, w) in random.sample(calls, min(a.n // 2, len(calls))):
            con = ns.at('con', l, c + len(w) + 1)
            names = {norm(x[2].split('.')[-1]) for x in con if len(x) > 2 and x[0] == 'con'}
            if norm(w) not in names: continue
            sigs = ned.signature(l, c + len(w) + 1)
            ok = any(norm(w) in [norm(t) for t in re.findall(r'[A-Za-z_]\w*', s)[:3]] for s in sigs)
            add('signature help: the routine', ok)
            if not ok: miss('signature help: the routine', '%d:%d %s(' % (l + 1, c + 1, w))
        ns.close()
    ned.close()
    report[path] = {k: v[:20] for k, v in misses.items()}
    print('%-60s %4.1fs  %s' % (os.path.relpath(path)[-60:], time.time() - t0,
                                '  '.join('%s: %d missed' % (k.split(':')[0], len(v)) for k, v in misses.items()) or 'all as expected'),
          flush=True)
    for k, v in misses.items():
        for x in v[:a.show]: print('      %-40s %s' % (k, x))

print()
bad = False
for k, (n, ok) in sorted(totals.items()):
    share = 100.0 * ok / n if n else 100.0
    print('%-45s %5d / %5d   %5.1f %%' % (k, ok, n, share))
    if share < a.min_hover: bad = True
if a.json:
    json.dump({'totals': totals, 'misses': report}, open(a.json, 'w'), indent=1)
sys.exit(1 if bad else 0)
