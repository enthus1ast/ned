#!/usr/bin/env python3
# a tiny language server for ned's tests: answers with fixed, predictable results
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
uri = None
def rng(l1, c1, l2, c2): return {"start": {"line": l1, "character": c1}, "end": {"line": l2, "character": c2}}
while True:
    m = read()
    meth, mid, p = m.get('method'), m.get('id'), m.get('params') or {}
    if meth == 'textDocument/didOpen': uri = p['textDocument']['uri']
    if mid is None: continue
    r = None
    if meth == 'initialize':
        r = {"capabilities": {"textDocumentSync": 1, "typeDefinitionProvider": True, "implementationProvider": True,
             "documentHighlightProvider": True, "foldingRangeProvider": True, "documentRangeFormattingProvider": True,
             "typeHierarchyProvider": True}}
    elif meth == 'textDocument/typeDefinition': r = {"uri": p['textDocument']['uri'], "range": rng(0, 6, 0, 11)}
    elif meth == 'textDocument/implementation':
        r = [{"uri": p['textDocument']['uri'], "range": rng(3, 4, 3, 9)}, {"uri": p['textDocument']['uri'], "range": rng(6, 4, 6, 9)}]
    elif meth == 'textDocument/documentHighlight':
        r = [{"range": rng(9, 0, 9, 1)}, {"range": rng(10, 6, 10, 7)}]
    elif meth == 'textDocument/foldingRange': r = [{"startLine": 12, "endLine": 15}]
    elif meth == 'textDocument/rangeFormatting':
        s = p['range']['start']['line']
        r = [{"range": rng(s, 0, s, 0), "newText": "# formatted\n"}]
    elif meth == 'textDocument/prepareTypeHierarchy':
        r = [{"name": "Shape", "kind": 5, "uri": p['textDocument']['uri'], "range": rng(0, 0, 0, 5), "selectionRange": rng(0, 6, 0, 11)}]
    elif meth == 'typeHierarchy/supertypes':
        r = [{"name": "Base", "kind": 5, "uri": p['item']['uri'], "range": rng(0, 0, 0, 5), "selectionRange": rng(0, 6, 0, 11)}]
    elif meth == 'typeHierarchy/subtypes':
        r = [{"name": "Circle", "kind": 5, "uri": p['item']['uri'], "range": rng(3, 0, 3, 5), "selectionRange": rng(3, 6, 3, 12)}]
    elif meth == 'shutdown': r = None
    send({"jsonrpc": "2.0", "id": mid, "result": r})
