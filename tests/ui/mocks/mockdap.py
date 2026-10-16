#!/usr/bin/env python3
# a tiny Debug Adapter Protocol server over TCP for ned's tests: python3 mockdap.py PORT
import sys, json, socket
port = int(sys.argv[1])
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('127.0.0.1', port)); srv.listen(1)
print('DAP server listening at: 127.0.0.1:%d' % port, flush=True)
c, _ = srv.accept()
f = c.makefile('rb')
seq = [0]
def send(m):
    seq[0] += 1; m['seq'] = seq[0]
    b = json.dumps(m).encode()
    c.sendall(b'Content-Length: %d\r\n\r\n' % len(b) + b)
def resp(req, body=None, ok=True, msg=''):
    send({'type': 'response', 'request_seq': req['seq'], 'success': ok, 'command': req['command'], 'body': body or {}, 'message': msg})
prog = ''; bpline = 1; databps = []; fired = [False]
while True:
    hdr = {}
    while True:
        line = f.readline()
        if not line: sys.exit(0)
        line = line.decode().strip()
        if not line: break
        k, v = line.split(':', 1); hdr[k.lower()] = v.strip()
    req = json.loads(f.read(int(hdr['content-length'])))
    cmd, a = req['command'], req.get('arguments') or {}
    if cmd == 'initialize': resp(req, {'supportsConfigurationDoneRequest': True, 'supportsDataBreakpoints': True})
    elif cmd == 'launch':
        prog = a.get('program', ''); resp(req); send({'type': 'event', 'event': 'initialized'})
    elif cmd == 'setBreakpoints':
        bps = a.get('breakpoints', [])
        if bps: bpline = bps[0]['line']; prog = a['source']['path']
        resp(req, {'breakpoints': [{'verified': True, 'line': b['line']} for b in bps]})
    elif cmd == 'configurationDone':
        resp(req)
        send({'type': 'event', 'event': 'output', 'body': {'category': 'stdout', 'output': 'hello from the debuggee\n'}})
        send({'type': 'event', 'event': 'stopped', 'body': {'reason': 'breakpoint', 'threadId': 1}})
    elif cmd == 'stackTrace':
        resp(req, {'stackFrames': [{'id': 7, 'name': 'main.compute', 'line': bpline, 'column': 1, 'source': {'path': prog}}]})
    elif cmd == 'scopes': resp(req, {'scopes': [{'name': 'Locals', 'variablesReference': 1, 'expensive': False}]})
    elif cmd == 'variables':
        if a['variablesReference'] == 1:
            resp(req, {'variables': [{'name': 'answer', 'value': '42', 'type': 'int', 'variablesReference': 0},
                                     {'name': 'obj', 'value': 'Point{…}', 'type': 'Point', 'variablesReference': 2}]})
        else: resp(req, {'variables': [{'name': 'x', 'value': '1', 'variablesReference': 0}, {'name': 'y', 'value': '2', 'variablesReference': 0}]})
    elif cmd == 'evaluate': resp(req, {'result': '84', 'variablesReference': 0})
    elif cmd == 'dataBreakpointInfo':
        resp(req, {'dataId': 'var:' + a.get('name', ''), 'description': a.get('name', ''), 'accessTypes': ['write']})
    elif cmd == 'setDataBreakpoints':
        databps[:] = a.get('breakpoints', [])
        resp(req, {'breakpoints': [{'verified': True} for _ in databps]})
    elif cmd == 'continue' and databps and not fired[0]:
        fired[0] = True
        resp(req, {'allThreadsContinued': True})
        send({'type': 'event', 'event': 'continued', 'body': {'threadId': 1}})
        send({'type': 'event', 'event': 'stopped', 'body': {'reason': 'data breakpoint', 'description': 'answer changed', 'threadId': 1}})
    elif cmd in ('continue', 'next', 'stepIn', 'stepOut'):
        resp(req, {'allThreadsContinued': True})
        send({'type': 'event', 'event': 'exited', 'body': {'exitCode': 3}})
        send({'type': 'event', 'event': 'terminated'})
    elif cmd == 'disconnect': resp(req); sys.exit(0)
    else: resp(req)
