#!/usr/bin/env python3
"""ned's C engine against clangd: the same questions about the same C files, and where they agree.

  go to definition  at random identifiers — the same file and line as clangd's first answer
  member completion right after `->` or `.` — is the member written there offered?

  python3 tests/engine/ccompare.py DRIVER OUTDIR FILE.c … [--n 60] [--clangd PATH] [--bg-index]

DRIVER is tests/engine/cdriver.nim built (nim c -d:release -o:ned-cengine tests/engine/cdriver.nim). clangd comes
from PATH (or --clangd). Each file is opened in clangd, which is asked once it has read it."""
import json, os, random, re, subprocess, sys, time

def lsp_send(p, obj):
    b = json.dumps(obj).encode()
    p.stdin.write(b'Content-Length: %d\r\n\r\n' % len(b) + b)
    p.stdin.flush()

def lsp_read(p):
    headers = {}
    while True:
        line = p.stdout.readline()
        if not line: return None
        line = line.decode().strip()
        if not line: break
        k, v = line.split(':', 1)
        headers[k.lower()] = v.strip()
    n = int(headers.get('content-length', 0))
    return json.loads(p.stdout.read(n))

class Clangd:
    def __init__(self, exe, root, bg=False):
        self.p = subprocess.Popen([exe, '--log=error', '--background-index=%s' % ('true' if bg else 'false'), '-j=2'],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.id = 0
        self.inactive = {}           # uri → the lines the configuration leaves out (#if branches not taken)
        self.indexing = None         # the background index: None not started, True running, False done
        self.req('initialize', {'processId': os.getpid(), 'rootUri': 'file://' + root, 'capabilities': {
            'window': {'workDoneProgress': True},
            'textDocument': {'inactiveRegionsCapabilities': {'inactiveRegions': True}}}})
        lsp_send(self.p, {'jsonrpc': '2.0', 'method': 'initialized', 'params': {}})
    def req(self, method, params, timeout=60):
        self.id += 1
        rid = self.id
        lsp_send(self.p, {'jsonrpc': '2.0', 'id': rid, 'method': method, 'params': params})
        t0 = time.time()
        while time.time() - t0 < timeout:
            m = lsp_read(self.p)
            if m is None: return None
            self.note(m)
            if m.get('id') == rid and 'method' not in m: return m.get('result')
        return None
    def note(self, m):
        if 'method' in m and 'id' in m:                  # a request from clangd (progress tokens): yes
            lsp_send(self.p, {'jsonrpc': '2.0', 'id': m['id'], 'result': None})
            return
        if m.get('method') == '$/progress':
            v = m['params'].get('value', {})
            if 'index' in str(m['params'].get('token', '')).lower() or 'index' in v.get('title', '').lower():
                if v.get('kind') == 'begin': self.indexing = True
                elif v.get('kind') == 'end': self.indexing = False
        if m.get('method') == 'textDocument/inactiveRegions':
            p = m['params']
            self.inactive[p['textDocument']['uri']] = [(r['start']['line'], r['end']['line']) for r in p['regions']]
    def wait_index(self, uri, timeout=1200):
        """until the background index of the whole project is done"""
        t0 = time.time()
        while time.time() - t0 < timeout and self.indexing is not False:
            self.req('textDocument/documentSymbol', {'textDocument': {'uri': uri}})
            time.sleep(1)
        return time.time() - t0
    def wait_inactive(self, uri, timeout=10):
        t0 = time.time()
        while uri not in self.inactive and time.time() - t0 < timeout:
            self.req('textDocument/documentSymbol', {'textDocument': {'uri': uri}})
            if uri not in self.inactive: time.sleep(0.1)
        return self.inactive.get(uri, [])
    def open(self, path):
        lsp_send(self.p, {'jsonrpc': '2.0', 'method': 'textDocument/didOpen', 'params': {'textDocument': {
            'uri': 'file://' + path, 'languageId': 'c', 'version': 1, 'text': open(path, errors='replace').read()}}})
    def close(self, path):
        lsp_send(self.p, {'jsonrpc': '2.0', 'method': 'textDocument/didClose', 'params': {'textDocument': {'uri': 'file://' + path}}})

def code_positions(lines):
    """identifiers outside comments, strings and preprocessor lines (a #define's continuation lines too):
    (line, col, word, what is before it)"""
    out = []
    in_block = False
    in_pp = False
    for l, t in enumerate(lines):
        if in_pp or t.lstrip().startswith('#'):
            in_pp = t.rstrip().endswith('\\')
            continue
        i = 0
        while i < len(t):
            if in_block:
                e = t.find('*/', i)
                if e < 0: break
                in_block = False; i = e + 2; continue
            if t.startswith('//', i): break
            if t.startswith('/*', i): in_block = True; i += 2; continue
            c = t[i]
            if c in '"\'':
                j = i + 1
                while j < len(t) and t[j] != c:
                    if t[j] == '\\': j += 1
                    j += 1
                i = j + 1; continue
            m = re.match(r'[A-Za-z_]\w*', t[i:])
            if m and (i == 0 or not (t[i - 1].isalnum() or t[i - 1] == '_')):
                out.append((l, i, m.group(0), t[:i]))
                i += len(m.group(0)); continue
            i += 1
    return out

KEYWORDS = set('auto break case char const continue default do double else enum extern float for goto if inline int '
               'long register restrict return short signed sizeof static struct switch typedef union unsigned void '
               'volatile while bool true false NULL'.split())

def main():
    args = sys.argv[1:]
    n = 60
    exe = 'clangd'
    if '--n' in args:
        k = args.index('--n'); n = int(args[k + 1]); del args[k:k + 2]
    if '--clangd' in args:
        k = args.index('--clangd'); exe = args[k + 1]; del args[k:k + 2]
    bg = '--bg-index' in args       # clangd with its background index of the whole project (it then knows the
    if bg: args.remove('--bg-index')  # bodies in the other .c files, as ned looks them up) — waited for first
    driver, outdir, files = args[0], args[1], [os.path.abspath(f) for f in args[2:]]
    os.makedirs(outdir, exist_ok=True)
    random.seed(7)
    drv = subprocess.Popen([driver], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    def ask(q):
        drv.stdin.write(json.dumps(q) + '\n'); drv.stdin.flush()
        return json.loads(drv.stdout.readline())
    # the include folders: the C compiler's own, and each file's folder (as clangd's fallback does)
    cc = subprocess.run('echo | cc -E -Wp,-v -x c - 2>&1', shell=True, capture_output=True, text=True).stdout
    sysdirs = [l.strip() for l in cc.split('\n') if l.startswith(' /')]
    predef = {}
    for l in subprocess.run('cc -dM -E -x c /dev/null', shell=True, capture_output=True, text=True).stdout.split('\n'):
        p = l.split(None, 2)
        if len(p) >= 2 and p[0] == '#define': predef[p[1]] = p[2] if len(p) > 2 else ''
    ask({'predef': predef})
    ask({'root': os.path.commonpath([os.path.dirname(f) for f in files])})
    root = os.path.commonpath([os.path.dirname(f) for f in files])
    # a compile_commands.json beside the files: clangd reads it (its best answers), and ned gets its -I folders, as
    # the editor gives them
    incdirs = []
    cc_json = os.path.join(root, 'compile_commands.json')
    if os.path.exists(cc_json):
        for e in json.load(open(cc_json)):
            parts = e.get('command', '').split() or e.get('arguments', [])
            for k, a in enumerate(parts):
                d = a[2:] if a.startswith('-I') and len(a) > 2 else (parts[k + 1] if a == '-I' and k + 1 < len(parts) else '')
                if d:
                    d = os.path.normpath(os.path.join(e.get('directory', root), d))
                    if d not in incdirs: incdirs.append(d)
    cd = Clangd(exe, root, bg)
    if bg:
        cd.open(files[0])
        print('clangd indexed the project in %.0f s' % cd.wait_index('file://' + files[0]), flush=True)
        cd.close(files[0])
    tot = {'skipped_inactive': 0, 'def_agree': 0, 'def_clangd_only': 0, 'def_differ': 0, 'def_ned_only': 0, 'def_listed': 0, 'def_system': 0,
           'mem_n': 0, 'mem_ned': 0, 'mem_clangd': 0, 'ned_ms': 0.0, 'ned_q': 0, 'clangd_ms': 0.0, 'clangd_q': 0}
    report = []
    for path in files:
        lines = open(path, errors='replace').read().split('\n')
        ask({'dirs': [os.path.dirname(path)] + incdirs + sysdirs})
        cd.open(path)
        t0 = time.time()
        cd.req('textDocument/documentSymbol', {'textDocument': {'uri': 'file://' + path}}, timeout=120)  # (it has read it)
        first = time.time() - t0
        # code the configuration leaves out (#if branches not taken) is not asked about: clangd has no answers there,
        # only guesses by name
        gone = cd.wait_inactive('file://' + path)
        def live(l):
            return not any(a <= l <= b for (a, b) in gone)
        allpos = [p for p in code_positions(lines) if p[2] not in KEYWORDS]
        pos = [p for p in allpos if live(p[0])]
        tot['skipped_inactive'] += len(allpos) - len(pos)
        random.shuffle(pos)
        bad = []
        if pos:
            # the first question about a file: ned reads it and every header it includes (the ones read before for
            # another file are kept)
            a = ask({'file': path, 'line': pos[0][0], 'col': pos[0][1], 'kind': 'def'})
            tot.setdefault('ned_first_ms', []).append(a['ms'])
        for (l, c, w, before) in pos[:n]:
            t1 = time.time()
            r = cd.req('textDocument/definition', {'textDocument': {'uri': 'file://' + path},
                                                   'position': {'line': l, 'character': c}})
            tot['clangd_ms'] += (time.time() - t1) * 1000; tot['clangd_q'] += 1
            cl = None
            if r:
                x = r[0] if isinstance(r, list) and r else r
                if isinstance(x, dict) and 'uri' in x:
                    cl = (x['uri'][7:], x['range']['start']['line'])
            a = ask({'file': path, 'line': l, 'col': c, 'kind': 'def'})
            tot['ned_ms'] += a['ms']; tot['ned_q'] += 1
            nd = [(os.path.realpath(d[0]), d[1]) for d in a['defs']]
            if cl: cl = (os.path.realpath(cl[0]), cl[1])
            if cl and nd:
                if nd[0] == cl: tot['def_agree'] += 1
                else:
                    tot['def_differ'] += 1
                    if cl in nd: tot['def_listed'] += 1
                    # both outside the project: a system header's declaration — often the same one in another copy
                    # of the header (clang's own stddef.h against the C compiler's)
                    elif not cl[0].startswith(root + '/') and not nd[0][0].startswith(root + '/'): tot['def_system'] += 1
                    bad.append(['DIFF', l, c, w, cl, nd[:2]])
            elif cl:
                tot['def_clangd_only'] += 1
                bad.append(['MISS', l, c, w, cl, []])
            elif nd: tot['def_ned_only'] += 1
        # member completion: after -> and .
        mems = []
        for (l, c, w, before) in code_positions(lines):
            if not live(l): continue
            if before.endswith('->') or (before.endswith('.') and not before.endswith('..') and len(before) > 1 and
                                         (before[-2].isalnum() or before[-2] in '_)]')):
                mems.append((l, c, w))
        random.shuffle(mems)
        for (l, c, w) in mems[:max(10, n // 3)]:
            tot['mem_n'] += 1
            a = ask({'file': path, 'line': l, 'col': c, 'kind': 'comp'})
            if w in a['items']: tot['mem_ned'] += 1
            else: bad.append(['MEMBER', l, c, w, a.get('type', ''), a['items'][:5]])
            r = cd.req('textDocument/completion', {'textDocument': {'uri': 'file://' + path},
                                                   'position': {'line': l, 'character': c}})
            items = r.get('items', []) if isinstance(r, dict) else (r or [])
            if any((it.get('filterText') or it.get('label', '')).strip() == w or it.get('label', '').strip().startswith(w + '(') or
                   it.get('label', '').strip() == w for it in items): tot['mem_clangd'] += 1
        cd.close(path)
        report.append({'file': path, 'clangd_first_s': first, 'ned_first_ms': tot['ned_first_ms'][-1] if pos else 0,
                       'bad': bad})
        print('%-28s clangd read it in %.2fs · ned in %.0f ms · %d differences' % (os.path.basename(path), first,
              tot['ned_first_ms'][-1] if pos else 0, len(bad)), flush=True)
        tot.setdefault('clangd_first_s', []).append(first)
    json.dump(report, open(os.path.join(outdir, 'report.json'), 'w'), indent=1)
    asked = tot['def_agree'] + tot['def_differ']
    print('\nfiles %d (identifiers in code the configuration leaves out, not asked about: %d)' % (
        len(files), tot['skipped_inactive']))
    print('definition   : agrees %.1f%% where both answer (agree %d, differ %d — of which clangd\'s is among ned\'s %d),'
          ' clangd only %d, ned only %d' % (100.0 * tot['def_agree'] / max(1, asked), tot['def_agree'], tot['def_differ'],
          tot['def_listed'], tot['def_clangd_only'], tot['def_ned_only']))
    print('               differences where both answers are system headers: %d' % tot['def_system'])
    print('member compl.: ned %.1f%% · clangd %.1f%%  (of %d)' % (100.0 * tot['mem_ned'] / max(1, tot['mem_n']),
          100.0 * tot['mem_clangd'] / max(1, tot['mem_n']), tot['mem_n']))
    print('time         : ned %.2f ms a question · clangd %.1f ms (after it has read the file)' % (
          tot['ned_ms'] / max(1, tot['ned_q']), tot['clangd_ms'] / max(1, tot['clangd_q'])))
    tot['ned_rss_kb'] = ask({'mem': 1})['rss_kb']
    try:
        for l in open('/proc/%d/status' % cd.p.pid):
            if l.startswith('VmRSS:'): tot['clangd_rss_kb'] = int(l.split()[1])
    except OSError: pass
    print('first read   : ned %.0f ms a file (median) · clangd %.2f s' % (
          sorted(tot.get('ned_first_ms', [0]))[len(tot.get('ned_first_ms', [0])) // 2],
          sorted(tot.get('clangd_first_s', [0]))[len(tot.get('clangd_first_s', [0])) // 2]))
    print('memory       : ned %.0f MB · clangd %.0f MB (resident, at the end)' % (
          tot['ned_rss_kb'] / 1024.0, tot.get('clangd_rss_kb', 0) / 1024.0))
    json.dump(tot, open(os.path.join(outdir, 'totals.json'), 'w'), indent=1)

if __name__ == '__main__':
    main()
