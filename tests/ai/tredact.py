#!/usr/bin/env python3
"""Secrets kept from the AI (ai.redactSecrets), with the real editor and a fake AI provider on this machine (an
OpenAI-compatible server that writes down every request): ned in tmux, a project whose main.nim has an API key in it
and whose .env has a password.

  the chat, with the file and @.env    the key is a placeholder in what is sent; .env is not sent at all
  an inline edit of the key's line     the model answers with the placeholder: the file gets the key back
  ai.redactSecrets off                 the key goes as it is (the setting does what it says)

Usage: tredact.py path/to/ned     (needs tmux and curl)"""
import json, os, shutil, socket, subprocess, sys, tempfile, threading, time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

NED = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else sys.exit(__doc__)
for tool in ['tmux', 'curl']:
    if not shutil.which(tool): print('no %s: skipped' % tool); sys.exit(0)
# (in two parts, so that GitHub's secret scanning does not take this made-up key for a real one)
KEY = 'sk-' + 'proj-Ab3dEf6hIj9kLm2nOp5qRs8tUv1wXy4zAb7cDe0f'
PASSWORD = 'hunter22secret'
requests = []
fails = []

def check(what, cond, out=''):
    print(('ok    ' if cond else 'FAIL  ') + what)
    if not cond:
        fails.append(what)
        if out: print('      ' + str(out)[:1500].replace('\n', '\n      '))

class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *a): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
        requests.append(body)
        text = json.dumps(body)
        # (an inline edit: the selected line back, its name in capitals, the placeholder as the model got it)
        reply = 'Noted.'
        if 'Reply with ONLY the replacement' in text or 'replacement' in text.lower():
            i = text.find('[REDACTED:')
            ph = text[i:text.find(']', i) + 1] if i >= 0 else 'NOTHING'
            reply = 'let API_KEY = "%s"' % ph
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream'); self.send_header('Connection', 'close')
        self.end_headers()
        for chunk in [reply[:7], reply[7:]]:
            self.wfile.write(('data: ' + json.dumps({'choices': [{'delta': {'content': chunk}}]}) + '\n\n').encode())
        self.wfile.write(b'data: {"choices": [{"delta": {}, "finish_reason": "stop"}]}\n\ndata: [DONE]\n\n')
        self.wfile.flush()
        self.close_connection = True

srv = ThreadingHTTPServer(('127.0.0.1', 0), H)
port = srv.server_address[1]
threading.Thread(target=srv.serve_forever, daemon=True).start()

root = tempfile.mkdtemp(prefix='ned-tredact-')
SOCK = 'ned-tredact-%d' % os.getpid()
def tm(*a): return subprocess.run(['tmux', '-L', SOCK] + list(a), capture_output=True, text=True)
def keys(*k):
    for x in k:
        tm('send-keys', '-t', 's', x); time.sleep(0.25)
def text(s): tm('send-keys', '-t', 's', '-l', s); time.sleep(0.3)
def paste(s):
    # (pasted, not typed: a typed @ opens the picker of files to attach)
    tm('set-buffer', '-b', 'p', s); tm('paste-buffer', '-p', '-b', 'p', '-t', 's'); time.sleep(0.4)
def wait_requests(n, secs=20):
    end = time.time() + secs
    while time.time() < end and len(requests) < n: time.sleep(0.2)
    return len(requests) >= n

def session(redact):
    proj = os.path.join(root, 'proj-%s' % redact)
    os.makedirs(proj)
    open(os.path.join(proj, 'main.nim'), 'w').write('let apiKey = "%s"\necho apiKey.len\n' % KEY)
    open(os.path.join(proj, '.env'), 'w').write('DB_PASSWORD=%s\n' % PASSWORD)
    cfg = os.path.join(root, 'cfg-%s' % redact)
    os.makedirs(cfg + '/ned')
    json.dump({'security.folderTrust': 'off', 'ai.provider': 'custom', 'ai.baseUrl': 'http://127.0.0.1:%d' % port,
               'ai.model': 'fake', 'ai.agent': False, 'ai.warnTokens': 0, 'ai.redactSecrets': redact,
               'files.hotExit': False, 'ui.cursorAnimation': 'off'}, open(cfg + '/ned/config.json', 'w'))
    env = 'XDG_CONFIG_HOME=%s XDG_STATE_HOME=%s/state TERM=xterm-256color NED_SOCKET= http_proxy= HTTP_PROXY=' % (cfg, cfg)
    tm('new-session', '-d', '-s', 's', '-x', '140', '-y', '40', 'cd %s && env %s %s main.nim; sleep 600' % (proj, env, NED))
    time.sleep(2.5)
    keys('Escape')
    n0 = len(requests)
    keys('M-c')                                   # the assistant
    time.sleep(0.8)
    paste('what is in @.env')
    keys('Enter')
    got_chat = wait_requests(n0 + 1)
    chat = json.dumps(requests[n0]) if got_chat else ''
    time.sleep(1)
    keys('Escape', 'Escape')
    result = {'chat': chat}
    if redact:
        keys('C-g'); text('1'); keys('Enter', 'Home', 'S-End')
        keys('M-C')                               # edit the selection with AI
        time.sleep(0.6)
        text('name in capitals')
        keys('Enter')
        got = wait_requests(n0 + 2)
        result['inline'] = json.dumps(requests[n0 + 1]) if got else ''
        time.sleep(1.5)
        keys('C-s')
        time.sleep(1)
        result['file'] = open(os.path.join(proj, 'main.nim')).read()
    keys('C-q'); time.sleep(0.5)
    tm('kill-server')
    return result

r = session(True)
check('the chat request was sent', r['chat'] != '')
check('… the key in the file is a placeholder there', KEY not in r['chat'] and '[REDACTED:api-key#1]' in r['chat'],
      r['chat'][:600])
check('… .env is not sent (its password nowhere), and the model is told why',
      PASSWORD not in r['chat'] and 'holds secrets' in r['chat'], r['chat'][:800])
check('… the model is told what the placeholders are', 'placeholder exactly as it is' in r['chat'])
check('the inline edit: sent with the placeholder', r['inline'] != '' and KEY not in r['inline'], r['inline'][:400])
check('… the answer\'s placeholder back to the key in the file', 'let API_KEY = "%s"' % KEY in r['file'], r['file'])
r = session(False)
check('ai.redactSecrets off: the key is sent as it is', KEY in r['chat'], r['chat'][:400])

srv.shutdown()
shutil.rmtree(root, ignore_errors=True)
if fails:
    print('%d failed' % len(fails)); sys.exit(1)
print('all passed')
