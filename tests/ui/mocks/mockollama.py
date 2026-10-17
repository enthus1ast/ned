#!/usr/bin/env python3
# Ollama's API for ned's tests: /api/tags, /api/pull (streamed progress), and an OpenAI-style chat that says "ready"
import sys, json, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
models = []
class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *a): pass
    def send_json(self, obj):
        b = json.dumps(obj).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if self.path.startswith('/api/tags'): return self.send_json({"models": models})
        self.send_response(404); self.send_header('Content-Length', '0'); self.end_headers()
    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        body = json.loads(self.rfile.read(n) or b'{}')
        if self.path.startswith('/api/pull'):
            self.send_response(200); self.send_header('Content-Type', 'application/x-ndjson')
            self.send_header('Connection', 'close'); self.end_headers()
            for line in [{"status": "pulling manifest"}, {"status": "downloading", "completed": 40, "total": 100},
                         {"status": "downloading", "completed": 100, "total": 100}, {"status": "success"}]:
                self.wfile.write((json.dumps(line) + '\n').encode()); self.wfile.flush(); time.sleep(0.3)
            models.append({"name": body.get("model", "x"), "size": 1000000000})
            self.close_connection = True
            return
        if self.path.endswith('/chat/completions'):
            if body.get('stream'):
                self.send_response(200); self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Connection', 'close'); self.end_headers()
                for ev in [{'choices': [{'index': 0, 'delta': {'role': 'assistant', 'content': 'ready'}}]},
                           {'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'stop'}]}]:
                    self.wfile.write(('data: ' + json.dumps(ev) + '\n\n').encode())
                self.wfile.write(b'data: [DONE]\n\n'); self.wfile.flush()
                self.close_connection = True
                return
            return self.send_json({'choices': [{'index': 0, 'message': {'role': 'assistant', 'content': 'ready'}, 'finish_reason': 'stop'}]})
        self.send_response(404); self.send_header('Content-Length', '0'); self.end_headers()
ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
