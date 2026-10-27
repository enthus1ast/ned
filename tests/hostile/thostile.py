#!/usr/bin/env python3
"""Input that makes no sense, or means harm, from everything outside ned that talks to it — ned stays up, says what
was wrong, and goes on answering:

  a plugin        every request of the plugin API with arguments of the wrong kinds, out of range, huge or missing,
                  and protocol lines that are broken, nested a hundred thousand deep or megabytes long
  the remote      ned's remote-control socket: requests that are not JSON, not objects, of the wrong types, nested
                  deep, long — with the right key (the key itself: tests/plugins/tsandbox.py)
  nedls           JSON-RPC that is broken: no header, a length that lies (short, negative, two gigabytes), bodies
                  that are not JSON or nested deep, parameters of the wrong types for each method, positions out of
                  range — then a sound request still gets its answer
  the screen      control characters in a file's text and name (ESC, BEL, C1's 8-bit CSI): drawn as pictures, never
                  sent to the terminal as controls

Usage: thostile.py path/to/ned [path/to/nedls]   (Linux or macOS; tmux and nim for the plugin part)"""
import glob, json, os, pty, re, select, shutil, signal, socket, struct, subprocess, sys, tempfile, time
import fcntl, termios

NED = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else sys.exit(__doc__)
NEDLS = os.path.abspath(sys.argv[2]) if len(sys.argv) > 2 else os.path.join(os.path.dirname(NED), 'nedls')
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
fails = []
def check(what, cond, out=''):
    print(('ok    ' if cond else 'FAIL  ') + what, flush=True)
    if not cond:
        fails.append(what)
        if out: print('      ' + str(out).strip()[-3000:].replace('\n', '\n      '))

root = tempfile.mkdtemp(prefix='ned-hostile-')
DEEP = '[' * 100000 + ']' * 100000

# ── the API's requests, as ned's plugin host knows them ──
host = open(os.path.join(REPO, 'src', 'ned', 'plugins', 'host.nim'), encoding='utf-8').read()
body = host[host.index('proc plugApi(h: PlugHost, j: JsonNode) ='):]
body = body[:re.search(r'\nproc ', body[10:]).start() + 10]
fns = sorted(set(re.findall(r'"([a-zA-Z]+)"', ' '.join(re.findall(r'\bof ([^:\n]+):', body)))))

PLUGIN = r'''## hostile — calls every request of ned's plugin API with arguments that make no sense (thostile.py)
import nedplugin, std/[json, strutils]

onStartup do (ev: Event):
  let fns = parseJson(readData("fns.json"))
  let cur = current().id
  # (NimScript's VM stops a plugin's callback after some millions of rounds of its loops — writing a request out
  # is one per character: long strings in every request would stop the plugin itself, so one size for all, and a
  # few long ones at the end)
  let big = repeat('x', 20_000)
  let huge = repeat('y', 400_000)
  var variants = @[newJObject(), newJNull(), %*[1, 2, 3], %*{"buf": "x"}, %*{"buf": -1}, %*{"buf": 1 shl 40},
                   %*{"buf": cur, "line": -5, "col": -7, "start": {"line": -1, "col": 1 shl 40},
                      "stop": {"line": 1 shl 40, "col": -3}},
                   %*{"buf": cur, "line": "a", "col": [], "text": 5, "name": {}, "key": nil},
                   %*{"buf": cur, "line": 1 shl 62, "text": big, "name": big, "title": big},
                   %*{"buf": cur, "text": "\x00\x1b]0;x\x07\u009b31m", "name": "\x00", "items": "x", "keys": "ctrl+ctrl+"},
                   %*{"buf": cur, "pattern": "([", "regex": "(?<", "with": "\\9", "ms": -5, "count": -1},
                   %*{"buf": cur, "items": [nil, 1, "x", {"label": 5}], "lines": [nil, 7], "ranges": [[1], {}]},
                   %*{"buf": cur, "pane": -3, "dir": "sideways", "size": -100, "cmd": "", "path": "", "file": ""}]
  var n = 0
  for f in fns:
    let fn = f.getStr
    # (not these: they would take ned or the test away — quitting is a command, not a request; the terminal and
    # programs run with arguments that make no sense would only fail)
    writeData("at.txt", fn)                     # (where it got to: the test says it when it stops there)
    for a in variants:
      try: discard api(fn, a)
      except CatchableError: discard
      inc n
  try: discard api("noSuchRequest", %*{"x": 1})
  except CatchableError: discard
  for (fn, a) in [("toast", %*{"text": huge}), ("message", %*{"text": huge}), ("status", %*{"text": huge}),
                  ("setTitle", %*{"title": huge}), ("output", %*{"text": huge})]:
    try: discard api(fn, a)
    except CatchableError: discard
  # (lines of the protocol itself that make no sense)
  for raw in ["{\"t\":\"reg\",\"kind\":\"command\"}", "{\"t\":\"reg\",\"kind\":\"timer\",\"ms\":-5,\"cb\":\"x\"}",
              "{\"t\":\"reg\",\"kind\":\"command\",\"title\":\"\",\"keys\":\"ctrl+ctrl+alt+\",\"cb\":1}",
              "{\"t\":\"reg\",\"kind\":\"event\",\"event\":\"save\",\"pattern\":\"[[\",\"cb\":2}",
              "{\"t\":\"reg\",\"kind\":\"vimMap\",\"mode\":\"q\",\"keys\":\"\",\"cb\":3}",
              "{\"t\":\"ret\",\"rid\":999999,\"value\":[]}", "{\"t\":\"api\",\"fn\":7,\"args\":\"x\"}",
              "{\"t\":", "[]", "null", "{\"t\":\"reg\",\"kind\":\"command\",\"title\":\"" & big & "\",\"cb\":4}"]:
    echo "\x1e" & raw
  writeData("done.txt", $n)

command "Hostile: deep":
  echo "\x1e" & repeat('[', 100000) & repeat(']', 100000)
'''

def session():
    run = os.path.join(root, 'plugin')
    cfg, state, data, cache, home, proj, tmp = [os.path.join(run, x) for x in
                                                ('cfg', 'state', 'data', 'cache', 'home', 'proj', 'tmp')]
    for d in (cfg + '/ned/plugins/hostile', state + '/ned', home, tmp): os.makedirs(d, exist_ok=True)
    shutil.copytree(os.path.join(REPO, 'tests', 'ui', 'fixtures', 'demo'), proj)
    open(cfg + '/ned/plugins/hostile/plugin.nims', 'w').write(PLUGIN)
    os.makedirs(data + '/ned/plugins/hostile', exist_ok=True)
    json.dump(fns, open(data + '/ned/plugins/hostile/fns.json', 'w'))
    json.dump({'version': 1, 'granted': {'hostile': ['shell', 'network', 'files', 'clipboard']}},
              open(state + '/ned/plugin-permissions.json', 'w'))
    json.dump({'security.folderTrust': 'off', 'ai.provider': 'off', 'plugins.native': 'off', 'nim.nimsuggest': False,
               'files.hotExit': False, 'terminal.keepRunning': False}, open(cfg + '/ned/config.json', 'w'))
    sock = 'ned-hostile-%d' % os.getpid()
    env = ('HOME=%s XDG_CONFIG_HOME=%s XDG_STATE_HOME=%s XDG_DATA_HOME=%s XDG_CACHE_HOME=%s TMPDIR=%s '
           'TERM=xterm-256color NED_SOCKET=' % (home, cfg, state, data, cache, tmp))
    def tm(*a): return subprocess.run(['tmux', '-L', sock] + list(a), capture_output=True, text=True)
    tm('new-session', '-d', '-s', 's', '-x', '130', '-y', '40',
       'cd %s && env %s %s src/demo.nim; echo NED-EXITED $?; sleep 600' % (proj, env, NED))
    done = os.path.join(data, 'ned', 'plugins', 'hostile', 'done.txt')
    end = time.time() + 240
    while time.time() < end and not os.path.exists(done):
        if 'NED-EXITED' in tm('capture-pane', '-t', 's', '-p').stdout: break
        tm('send-keys', '-t', 's', 'Escape')          # (what asks you — ask, confirm, pick — answered "no")
        time.sleep(0.5)
    time.sleep(2)
    s = tm('capture-pane', '-t', 's', '-p').stdout
    errlog = os.path.join(state, 'ned', 'errors.log')
    seen = [0]
    def new_errors():
        # (what errors.log says since the last look)
        t = open(errlog, errors='replace').read() if os.path.exists(errlog) else ''
        new, seen[0] = t[seen[0]:], len(t)
        return new
    errs = new_errors()
    n = open(done).read() if os.path.exists(done) else ''
    at = os.path.join(data, 'ned', 'plugins', 'hostile', 'at.txt')
    if not n and os.path.exists(at): s = 'stopped at the request "%s"\n' % open(at).read() + s
    check('a plugin: every API request with arguments that make no sense — ned stays up (%s calls of %d requests)' %
          (n or '?', len(fns)), n and 'NED-EXITED' not in s, s)
    check('… no internal error', not errs and 'Internal error' not in s, errs + s)
    # a line of the protocol nested a hundred thousand deep
    tm('send-keys', '-t', 's', 'Escape'); tm('send-keys', '-t', 's', 'C-p'); time.sleep(0.3)
    tm('send-keys', '-t', 's', '-l', '>Hostile: deep'); time.sleep(0.6); tm('send-keys', '-t', 's', 'Enter')
    time.sleep(4)
    s = tm('capture-pane', '-t', 's', '-p').stdout
    errs = new_errors()
    check('… a protocol line nested 100 000 deep: ned stays up', 'NED-EXITED' not in s and not errs, errs + s)
    # the remote control (this ned's socket, its key read as you can)
    priv = os.path.join(tmp, 'ned-%d' % os.getuid())
    socks = glob.glob(priv + '/remote-*.sock')
    if socks:
        key = open(socks[0][:-5] + '.key').read().strip()
        def ask(line, wait=3.0):
            c = socket.socket(socket.AF_UNIX)
            c.connect(socks[0])
            c.settimeout(wait)
            try:
                c.sendall(line if isinstance(line, bytes) else line.encode())
                return c.recv(65536).decode('utf-8', 'replace')
            except (socket.timeout, OSError) as e: return 'no answer: %r' % e
            finally: c.close()
        k = '"key": %s' % json.dumps(key)
        answers = []
        for line in ['not json\n', '[1, 2]\n', 'null\n', '{%s}\n' % k, '{%s, "cmd": 5}\n' % k,
                     '{%s, "cmd": "open", "files": "x"}\n' % k, '{%s, "cmd": "open", "files": [{"path": 5, "line": "a"}]}\n' % k,
                     '{%s, "cmd": "open", "files": [{"path": "/", "line": -99999999999}]}\n' % k,
                     '{%s, "cmd": "get", "what": []}\n' % k, '{%s, "cmd": "problems", "text": 7, "cwd": null}\n' % k,
                     '{%s, "cmd": "message", "text": "%s", "level": 3}\n' % (k, 'x' * 2_000_000),
                     '{%s, "cmd": "command", "name": ""}\n' % k, DEEP + '\n', '{"key": ' + DEEP + '}\n']:
            answers.append(ask(line))
        a = ask('{%s, "cmd": "info"}\n' % k, 10.0)
        s = tm('capture-pane', '-t', 's', '-p').stdout
        errs = new_errors()
        check('the remote control: requests that make no sense — ned stays up and answers the next one',
              '"ok":true' in a and 'NED-EXITED' not in s, a + '\n' + '\n'.join(x[:200] for x in answers) + s)
        check('… no internal error', not errs and 'Internal error' not in s, errs + s)
    else:
        check('the remote control: its socket', False, 'no socket in ' + priv)
    tm('kill-server')

if shutil.which('tmux') and shutil.which('nim'):
    session()
else:
    print('no tmux or nim: the plugin and remote parts skipped')

# ── nedls ──
def frame(b): return b'Content-Length: %d\r\n\r\n' % len(b) + b
def nedls_part():
    if not os.path.exists(NEDLS):
        print('no nedls at %s: skipped' % NEDLS)
        return
    proj = os.path.join(root, 'ls')
    shutil.copytree(os.path.join(REPO, 'tests', 'ui', 'fixtures', 'demo'), proj)
    env = dict(os.environ, HOME=os.path.join(root, 'lshome'), XDG_CACHE_HOME=os.path.join(root, 'lscache'))
    p = subprocess.Popen([NEDLS], cwd=proj, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         env=env)
    fcntl.fcntl(p.stdout, fcntl.F_SETFL, os.O_NONBLOCK)
    out = b''
    def send(b):
        try: p.stdin.write(b); p.stdin.flush()
        except BrokenPipeError: pass
    def read_for(secs):
        nonlocal out
        end = time.time() + secs
        while time.time() < end:
            r, _, _ = select.select([p.stdout], [], [], 0.1)
            if r:
                try:
                    d = p.stdout.read()
                    if d: out += d
                except (BlockingIOError, TypeError): pass
    def req(i, method, params): return frame(json.dumps({'jsonrpc': '2.0', 'id': i, 'method': method, 'params': params}).encode())
    def note(method, params): return frame(json.dumps({'jsonrpc': '2.0', 'method': method, 'params': params}).encode())
    uri = 'file://' + proj + '/src/demo.nim'
    text = open(proj + '/src/demo.nim').read()
    send(req(1, 'initialize', {'processId': None, 'rootUri': 'file://' + proj, 'capabilities': {}}))
    send(note('initialized', {}))
    send(note('textDocument/didOpen', {'textDocument': {'uri': uri, 'languageId': 'nim', 'version': 1, 'text': text}}))
    read_for(3)
    bad = [b'garbage without a header\r\n\r\n', b'Content-Length: -5\r\n\r\n', b'Content-Length: abc\r\n\r\n',
           frame(b'not json'), frame(b'[1,2,3]'), frame(b'null'), frame(DEEP.encode()),
           frame(json.dumps({'jsonrpc': '2.0', 'id': 'x', 'method': 5}).encode()),
           frame(json.dumps({'jsonrpc': '2.0', 'id': 99, 'method': 'textDocument/hover', 'params': [1]}).encode())]
    methods = ['textDocument/hover', 'textDocument/definition', 'textDocument/completion', 'textDocument/references',
               'textDocument/rename', 'textDocument/documentSymbol', 'textDocument/semanticTokens/full',
               'textDocument/semanticTokens/full/delta', 'textDocument/inlayHint', 'textDocument/codeAction',
               'textDocument/formatting', 'textDocument/rangeFormatting', 'textDocument/signatureHelp',
               'textDocument/diagnostic', 'workspace/diagnostic', 'workspace/symbol', 'textDocument/foldingRange',
               'textDocument/documentHighlight', 'textDocument/prepareRename', 'textDocument/codeLens',
               'textDocument/prepareCallHierarchy', 'textDocument/selectionRange', 'textDocument/typeDefinition']
    i = 100
    for m in methods:
        for params in [{}, None, {'textDocument': 5}, {'textDocument': {'uri': uri}, 'position': 'x'},
                       {'textDocument': {'uri': uri}, 'position': {'line': -1, 'character': -9}},
                       {'textDocument': {'uri': uri}, 'position': {'line': 10**12, 'character': 10**12},
                        'range': {'start': {'line': 5, 'character': 0}, 'end': {'line': 1, 'character': 0}},
                        'newName': '', 'query': 7, 'previousResultId': [], 'context': 'x'},
                       {'textDocument': {'uri': 'file:///no/such/file.nim'}, 'position': {'line': 0, 'character': 0}}]:
            i += 1
            bad.append(req(i, m, params))
    for ch in [{'textDocument': {'uri': uri, 'version': 2}, 'contentChanges': 'x'},
               {'textDocument': {'uri': uri, 'version': 3}, 'contentChanges': [{'range': {'start': {'line': 999, 'character': 0},
                'end': {'line': 0, 'character': 0}}, 'text': 'x'}]},
               {'textDocument': {'uri': uri, 'version': 4}, 'contentChanges': [{'text': 5}]}]:
        bad.append(note('textDocument/didChange', ch))
    bad.append(note('textDocument/didOpen', {'textDocument': {'uri': uri + '2', 'text': None}}))
    for b in bad:
        send(b)
        if p.poll() is not None: break
    read_for(8)
    # a lying length: two gigabytes said, a few bytes sent — then the stream is closed (nothing that follows can be
    # read as messages any more); first, a sound request after everything above
    send(req(9001, 'textDocument/hover', {'textDocument': {'uri': uri}, 'position': {'line': 3, 'character': 6}}))
    read_for(5)
    alive = p.poll() is None
    answered = b'"id":9001' in out.replace(b' ', b'')
    errs = p.stderr.read1(65536).decode('utf-8', 'replace') if not alive else ''
    check('nedls: broken JSON-RPC and parameters of the wrong types — still up, and the next request answered',
          alive and answered, errs + out[-1500:].decode('utf-8', 'replace'))
    send(b'Content-Length: 2147483647\r\n\r\n{}')
    read_for(2)
    check('nedls: a length of two gigabytes that never comes — no crash (it waits, or ends cleanly)',
          p.poll() is None or p.returncode == 0, p.stderr.read1(65536).decode('utf-8', 'replace') if p.poll() is not None else '')
    try: p.kill()
    except ProcessLookupError: pass
nedls_part()

# ── the screen: control characters never reach the terminal as controls ──
def screen_part():
    d = os.path.join(root, 'screen')
    os.makedirs(d + '/proj')
    open(d + '/proj/evil.txt', 'w').write('a \x1b]0;PWNED-TITLE\x07 b\n\x1b]52;c;UFdORUQ=\x07\nc1: \u009b31mRED \u0085 \u0090q\n')
    open(d + '/proj/\x1b]0;PWNED-NAME\x07.txt', 'w').write('x\n')
    os.makedirs(d + '/cfg/ned')
    json.dump({'security.folderTrust': 'off', 'ai.provider': 'off'}, open(d + '/cfg/ned/config.json', 'w'))
    env = dict(os.environ, TERM='xterm-256color', COLORTERM='truecolor', XDG_CONFIG_HOME=d + '/cfg',
               XDG_STATE_HOME=d + '/st', HOME=d, NED_SOCKET='')
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(d + '/proj')
        os.execve(NED, [NED, 'evil.txt'], env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 140, 0, 0))
    out = b''
    end = time.time() + 6
    sent = False
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try: data = os.read(fd, 65536)
            except OSError: break
            out += data
            if b'\x1b[6n' in data: os.write(fd, b'\x1b[40;140R')
        if not sent and time.time() > end - 4:
            os.write(fd, b'\x1b' + b'e')            # (Alt+E: the files, with the name that holds an escape)
            sent = True
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
    leaked = [p for p in [b'\x1b]0;PWNED', b'\x1b]52;c;', b'\xc2\x9b', b'\xc2\x85', b'\xc2\x90'] if p in out]
    check('the screen: ESC, BEL and C1 controls in a file and a file name drawn as pictures, not sent as controls',
          not leaked and b'PWNED-TITLE' in out, repr(leaked))
screen_part()

shutil.rmtree(root, ignore_errors=True)
if fails:
    print('%d failed' % len(fails))
    sys.exit(1)
print('all passed')
