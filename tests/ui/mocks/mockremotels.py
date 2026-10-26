#!/usr/bin/env python3
# a language server for t_629_remote_servers, run on the "server" of a remote folder: it writes what it is told to
# a log (argv[1]) — the paths must be the server's — reports one problem naming the file's path, and answers F12
# with a file of the server's outside the folder (argv[2])
import sys, json
LOG, OUTSIDE = sys.argv[1], sys.argv[2]
def log(s):
    with open(LOG, 'a') as f: f.write(s + '\n')
def read():
    hdr = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line: sys.exit(0)
        line = line.decode().strip()
        if not line: break
        k, v = line.split(':', 1)
        hdr[k.lower()] = v.strip()
    return json.loads(sys.stdin.buffer.read(int(hdr['content-length'])))
def send(msg):
    b = json.dumps(msg).encode()
    sys.stdout.buffer.write(b'Content-Length: %d\r\n\r\n' % len(b) + b)
    sys.stdout.buffer.flush()
def rng(l1, c1, l2, c2): return {"start": {"line": l1, "character": c1}, "end": {"line": l2, "character": c2}}
while True:
    m = read()
    meth, mid, p = m.get('method'), m.get('id'), m.get('params') or {}
    if meth == 'initialize':
        log('initialize processId=%s rootUri=%s' % (json.dumps(p.get('processId')), p.get('rootUri')))
    if meth == 'textDocument/didOpen':
        u = p['textDocument']['uri']
        log('didOpen ' + u)
        path = u[len('file://'):]
        send({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": {"uri": u, "diagnostics": [
            {"range": rng(0, 0, 0, 6), "severity": 1, "source": "remotels", "message": "seen at " + path}]}})
    if mid is None: continue
    r = None
    if meth == 'initialize':
        r = {"capabilities": {"textDocumentSync": 1, "definitionProvider": True, "hoverProvider": True}}
    elif meth == 'textDocument/definition':
        log('definition ' + p['textDocument']['uri'])
        r = {"uri": "file://" + OUTSIDE, "range": rng(0, 4, 0, 10)}
    elif meth == 'textDocument/hover':
        r = {"contents": {"kind": "plaintext", "value": "hover from the server, at " + p['textDocument']['uri']}}
    send({"jsonrpc": "2.0", "id": mid, "result": r})
