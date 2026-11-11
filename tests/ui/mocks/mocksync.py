#!/usr/bin/env python3
# a language server for ned's tests that takes a file's changes (textDocumentSync 2), not its whole text: it applies
# each change to its copy and writes the copy to OUT after every message, with a line in OUT.log saying what came.
# Usage: mocksync.py OUT [utf-8]   (utf-8: it agrees to count columns in bytes when ned offers it; else UTF-16)
import sys, json
OUT = sys.argv[1]
UTF8 = len(sys.argv) > 2 and sys.argv[2] == 'utf-8'

def read():
    """one message from ned (its Content-Length header, then the JSON)"""
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
    """one message to ned"""
    b = json.dumps(msg).encode()
    sys.stdout.buffer.write(b'Content-Length: %d\r\n\r\n' % len(b) + b)
    sys.stdout.buffer.flush()

def index(line, col):
    """the place in a line (a Python string) that is `col` columns in, as the server counts them"""
    if UTF8:
        return len(line.encode('utf-8')[:col].decode('utf-8', 'ignore'))
    n = 0
    for i, ch in enumerate(line):
        if n >= col: return i
        n += 2 if ord(ch) > 0xFFFF else 1
    return len(line)

def offset(text, pos):
    """the place in the whole text of a position {line, character}"""
    lines = text.split('\n')
    at = sum(len(l) + 1 for l in lines[:pos['line']])
    if pos['line'] >= len(lines): return len(text)
    return at + index(lines[pos['line']], pos['character'])

doc = ''
def log(what):
    """the copy written to OUT, and what came to OUT.log"""
    open(OUT, 'w', encoding='utf-8').write(doc)
    with open(OUT + '.log', 'a') as f: f.write(what + '\n')

while True:
    m = read()
    meth, mid, p = m.get('method'), m.get('id'), m.get('params') or {}
    if meth == 'textDocument/didOpen':
        doc = p['textDocument']['text']
        log('open')
    elif meth == 'textDocument/didChange':
        for c in p['contentChanges']:
            if 'range' in c:
                a, b = offset(doc, c['range']['start']), offset(doc, c['range']['end'])
                doc = doc[:a] + c['text'] + doc[b:]
                log('change')
            else:
                doc = c['text']
                log('whole')
    elif meth == 'textDocument/didSave':
        log('save' + (' with text' if 'text' in p else ''))
    if mid is None: continue
    r = None
    if meth == 'initialize':
        offered = p.get('capabilities', {}).get('general', {}).get('positionEncodings', [])
        r = {"capabilities": {"textDocumentSync": {"openClose": True, "change": 2, "save": {"includeText": False}}}}
        if UTF8 and 'utf-8' in offered: r["capabilities"]["positionEncoding"] = "utf-8"
        elif UTF8: UTF8 = False
    send({"jsonrpc": "2.0", "id": mid, "result": r})
