#!/usr/bin/env python3
# a tiny MCP server (stdio) for ned's tests: tools "echo" and "add"
import sys, json, os
def send(m):
    sys.stdout.write(json.dumps(m) + "\n"); sys.stdout.flush()
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    m = json.loads(line)
    mid, meth, p = m.get('id'), m.get('method'), m.get('params') or {}
    if meth == 'initialize':
        caps = {"tools": {}}
        if os.environ.get('MOCK_MCP_FULL'): caps.update({"resources": {}, "prompts": {}})
        send({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": "2025-06-18", "capabilities": caps,
              "serverInfo": {"name": "demo", "version": "1"}}})
    elif meth == 'tools/list':
        send({"jsonrpc": "2.0", "id": mid, "result": {"tools": [
            {"name": "echo", "description": "Echo the text back", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}},
            {"name": "add", "description": "Add two numbers", "inputSchema": {"type": "object", "properties": {"a": {"type": "number"}, "b": {"type": "number"}}}}]}})
    elif meth == 'tools/call':
        a = p.get('arguments') or {}
        if p['name'] == 'echo':
            txt = 'echo: ' + str(a.get('text')) + ' token=' + os.environ.get('DEMO_TOKEN', 'none')
        else:
            txt = str((a.get('a') or 0) + (a.get('b') or 0))
        send({"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": txt}]}})
    elif meth == 'resources/list':
        send({"jsonrpc": "2.0", "id": mid, "result": {"resources": [
            {"uri": "note://greeting", "name": "Greeting", "description": "a short note", "mimeType": "text/plain"}]}})
    elif meth == 'resources/read':
        txt = 'The secret word is PELICAN.' if p.get('uri') == 'note://greeting' else 'unknown'
        send({"jsonrpc": "2.0", "id": mid, "result": {"contents": [{"uri": p.get('uri'), "mimeType": "text/plain", "text": txt}]}})
    elif meth == 'prompts/list':
        send({"jsonrpc": "2.0", "id": mid, "result": {"prompts": [
            {"name": "summarize", "description": "Summarize a topic in one line", "arguments": [{"name": "topic", "required": True}]}]}})
    elif meth == 'prompts/get':
        t = (p.get('arguments') or {}).get('topic', '?')
        send({"jsonrpc": "2.0", "id": mid, "result": {"messages": [{"role": "user", "content": {"type": "text", "text": "Please summarize " + t + " in one line."}}]}})
    elif mid is not None:
        send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "nope"}})
