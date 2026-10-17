#!/usr/bin/env python3
# a language server for ned's tests that only answers when asked: pull diagnostics (lines with BAD), document
# links (LINK:name → name.lua beside the file) and on-type formatting (after `}`: the line's runs of spaces made one)
import sys, json, os
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
docs = {}
rid = 0
while True:
    m = read()
    meth, mid, p = m.get('method'), m.get('id'), m.get('params') or {}
    if meth == 'textDocument/didOpen': docs[p['textDocument']['uri']] = p['textDocument']['text']
    if meth == 'textDocument/didChange': docs[p['textDocument']['uri']] = p['contentChanges'][-1]['text']
    if mid is None: continue
    r = None
    if meth == 'initialize':
        r = {"capabilities": {"textDocumentSync": 1,
             "diagnosticProvider": {"interFileDependencies": False, "workspaceDiagnostics": False},
             "documentLinkProvider": {"resolveProvider": False},
             "documentOnTypeFormattingProvider": {"firstTriggerCharacter": "}"}}}
    elif meth == 'textDocument/diagnostic':
        rid += 1
        uri = p['textDocument']['uri']
        items = []
        for i, l in enumerate(docs.get(uri, '').split('\n')):
            k = l.find('BAD')
            if k >= 0: items.append({"range": rng(i, k, i, k + 3), "severity": 1, "source": "mockl2", "message": "BAD is pulled"})
        r = {"kind": "full", "resultId": str(rid), "items": items}
    elif meth == 'textDocument/documentLink':
        uri = p['textDocument']['uri']
        d = os.path.dirname(uri[len('file://'):])
        r = []
        for i, l in enumerate(docs.get(uri, '').split('\n')):
            k = l.find('LINK:')
            if k >= 0:
                name = l[k + 5:].split()[0]
                r.append({"range": rng(i, k + 5, i, k + 5 + len(name)), "target": "file://" + d + "/" + name + ".lua#L2"})
    elif meth == 'textDocument/onTypeFormatting':
        uri = p['textDocument']['uri']
        ln = p['position']['line']
        lines = docs.get(uri, '').split('\n')
        if ln < len(lines) and p['ch'] == '}':
            old = lines[ln]
            new = ' '.join(old.split())
            ind = old[:len(old) - len(old.lstrip())]
            if ind + new != old: r = [{"range": rng(ln, 0, ln, len(old)), "newText": ind + new}]
            else: r = []
    send({"jsonrpc": "2.0", "id": mid, "result": r})
