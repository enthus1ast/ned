#!/usr/bin/env python3
# a tiny linter's language server for ned's tests: every line with TODO_LINT is a problem, its fix writes DONE
import sys, json
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
def publish(uri, text):
    ds = []
    for i, l in enumerate(text.split('\n')):
        k = l.find('TODO_LINT')
        if k >= 0:
            ds.append({"range": rng(i, k, i, k + 9), "severity": 2, "source": "mocklint", "code": "L1",
                       "message": "TODO_LINT left in"})
    send({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": {"uri": uri, "diagnostics": ds}})
while True:
    m = read()
    meth, mid, p = m.get('method'), m.get('id'), m.get('params') or {}
    if meth == 'textDocument/didOpen': publish(p['textDocument']['uri'], p['textDocument']['text'])
    if meth == 'textDocument/didChange': publish(p['textDocument']['uri'], p['contentChanges'][-1]['text'])
    if mid is None: continue
    r = None
    if meth == 'initialize':
        r = {"capabilities": {"textDocumentSync": 1, "codeActionProvider": True}}
    elif meth == 'textDocument/codeAction':
        r = []
        for d in p['context']['diagnostics']:
            if d.get('code') == 'L1':
                r.append({"title": "Replace TODO_LINT with DONE", "kind": "quickfix", "diagnostics": [d],
                          "edit": {"changes": {p['textDocument']['uri']: [{"range": d['range'], "newText": "DONE"}]}}})
    send({"jsonrpc": "2.0", "id": mid, "result": r})
