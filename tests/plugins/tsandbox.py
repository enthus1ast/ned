#!/usr/bin/env python3
"""Plugins in ned's sandbox (Linux's Landlock, plugins.sandbox), with the real editor and its plugin host: a plugin
that needs no permission at all tries, when ned starts, to read a file outside the project and the system's folders
(a stand-in for ~/.ssh) — with the sandbox the kernel refuses (in NimScript that ends the plugin's process), without
it the plugin reads it. Also `ned --sandbox` from the command line: a shell that writes outside the current folder is
refused, and the environment's secrets do not reach it. And what could take a plugin out of the sandbox (6.32.1):
ned's remote-control socket and a kept terminal's socket refuse a program in the sandbox (it cannot read their
keys), and a plugin you allowed to run programs runs in a process of its own — the others stay in the sandbox.

Usage: tsandbox.py path/to/ned     (Linux with Landlock, tmux, nim; elsewhere it says why and passes)"""
import json, os, shutil, subprocess, sys, tempfile, time

NED = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else sys.exit(__doc__)
fails = []
def check(what, cond, out=''):
    print(('ok    ' if cond else 'FAIL  ') + what)
    if not cond:
        fails.append(what)
        if out: print('      ' + str(out).strip().replace('\n', '\n      '))

def landlock():
    import ctypes
    r = ctypes.CDLL(None, use_errno=True).syscall(444, None, 0, 1)
    return max(0, r)

if sys.platform != 'linux' or not landlock():
    print('no Landlock here: nothing to test (plugins run as before)')
    sys.exit(0)
for tool in ['tmux', 'nim']:
    if not shutil.which(tool):
        print('no %s: skipped' % tool)
        sys.exit(0)

root = tempfile.mkdtemp(prefix='ned-tsandbox-')
outside = os.path.join(root, 'outside')
os.makedirs(outside)
open(os.path.join(outside, 'secret.txt'), 'w').write('the secret')

# ── ned --sandbox from the command line ──
proj = os.path.join(root, 'proj')
os.makedirs(proj)
r = subprocess.run([NED, '--sandbox', 'sh', '-c', 'echo in > here.txt; echo out 2>/dev/null > %s/w.txt; '
                    'cat %s/secret.txt 2>/dev/null; env' % (outside, outside)],
                   cwd=proj, capture_output=True, text=True, env=dict(os.environ, GITHUB_TOKEN='ghp_' + 'a1' * 18))
check('ned --sandbox: writes in the folder', os.path.exists(os.path.join(proj, 'here.txt')), r.stderr)
check('ned --sandbox: not outside it', not os.path.exists(os.path.join(outside, 'w.txt')), r.stderr)
check('ned --sandbox: reads nothing outside it', 'the secret' not in r.stdout, r.stdout)
check('ned --sandbox: no secrets in its environment', 'GITHUB_TOKEN' not in r.stdout and 'PATH=' in r.stdout, r.stdout)
r = subprocess.run([NED, '--sandbox', '--write', outside, 'sh', '-c', 'echo ok > %s/w2.txt' % outside],
                   cwd=proj, capture_output=True, text=True)
check('ned --sandbox --write DIR: writes there', os.path.exists(os.path.join(outside, 'w2.txt')), r.stderr)
r = subprocess.run([NED, '--sandbox', '--help'], capture_output=True, text=True)
check('ned --sandbox --help', r.returncode == 0 and '--write PATH' in r.stdout, r.stdout + r.stderr)

# ── a plugin ──
PLUGIN = '''## probe — reads a file outside the project when ned starts (the sandbox test)
import nedplugin

onStartup do (ev: Event):
  writeData("start.txt", "started")
  writeData("project.txt", readFile(projectRoot() / "main.nim"))
  writeData("again.txt", readData("start.txt"))
  let s = readFile(%s)
  writeData("read.txt", s)
''' % json.dumps(os.path.join(outside, 'secret.txt'))

RUNNER = '''## runner — runs a program itself (you allowed it to: "shell")
import nedplugin

onStartup do (ev: Event):
  writeData("start.txt", shell("echo ran").output)
'''

SANDBOXED_CLIENT = r'''
import glob, json, socket, struct, sys
priv = sys.argv[1]
out = {}
for sock in glob.glob(priv + "/remote-*.sock"):
    try:
        open(sock[:-5] + ".key").read()
        out["key"] = "read"
    except OSError as e:
        out["key"] = "refused"
    c = socket.socket(socket.AF_UNIX)
    c.connect(sock)
    c.sendall(b'{"cmd": "message", "text": "from-the-sandbox"}\n')
    out["answer"] = c.recv(4096).decode()
out["terms"] = len(glob.glob(priv + "/term-*.sock"))
for sock in glob.glob(priv + "/term-*.sock"):
    c = socket.socket(socket.AF_UNIX)
    c.connect(sock)
    pay = b"\nforce"
    c.sendall(b"a" + struct.pack(">I", len(pay)) + pay)
    c.settimeout(3)
    try: out["term"] = repr(c.recv(16))
    except socket.timeout: out["term"] = "timeout"
print(json.dumps(out))
'''

def session(sandbox, runner=False, sockets=False):
    run = os.path.join(root, 'run-%s-%s-%s' % (sandbox, runner, sockets))
    cfg, state, data, cache, tmp = [os.path.join(run, x) for x in ('cfg', 'state', 'data', 'cache', 'tmp')]
    os.makedirs(cfg + '/ned/plugins/probe')
    os.makedirs(tmp)
    open(cfg + '/ned/plugins/probe/plugin.nims', 'w').write(PLUGIN)
    if runner:
        os.makedirs(cfg + '/ned/plugins/runner')
        open(cfg + '/ned/plugins/runner/plugin.nims', 'w').write(RUNNER)
        os.makedirs(state + '/ned', exist_ok=True)
        json.dump({'version': 1, 'granted': {'runner': ['shell']}}, open(state + '/ned/plugin-permissions.json', 'w'))
    json.dump({'security.folderTrust': 'off', 'ai.provider': 'off', 'plugins.native': 'off', 'plugins.sandbox': sandbox,
               'terminal.keepRunning': sockets},
              open(cfg + '/ned/config.json', 'w'))
    open(os.path.join(proj, 'main.nim'), 'w').write('echo "hello"\n')
    sock = 'ned-tsandbox-%d-%s-%s-%s' % (os.getpid(), sandbox, runner, sockets)   # (a tmux server of its own)
    env = ('XDG_CONFIG_HOME=%s XDG_STATE_HOME=%s XDG_DATA_HOME=%s XDG_CACHE_HOME=%s TMPDIR=%s TERM=xterm-256color '
           'NED_SOCKET=' % (cfg, state, data, cache, tmp))
    subprocess.run(['tmux', '-L', sock, 'new-session', '-d', '-s', 's', '-x', '120', '-y', '40',
                    'cd %s && env %s %s main.nim; sleep 600' % (proj, env, NED)])
    d = os.path.join(data, 'ned', 'plugins', 'probe')
    end = time.time() + 60
    while time.time() < end and not os.path.exists(os.path.join(d, 'start.txt')): time.sleep(0.5)
    time.sleep(4)
    started = os.path.exists(os.path.join(d, 'start.txt'))
    read = open(os.path.join(d, 'read.txt')).read() if os.path.exists(os.path.join(d, 'read.txt')) else None
    proj_read = os.path.exists(os.path.join(d, 'project.txt')) and 'hello' in open(os.path.join(d, 'project.txt')).read()
    data_read = os.path.exists(os.path.join(d, 'again.txt')) and open(os.path.join(d, 'again.txt')).read() == 'started'
    rs = os.path.join(data, 'ned', 'plugins', 'runner', 'start.txt')
    ran = os.path.exists(rs) and 'ran' in open(rs).read()
    got = None
    if sockets:
        subprocess.run(['tmux', '-L', sock, 'send-keys', '-t', 's', 'C-\\'])        # (a terminal, kept running)
        time.sleep(2)
        priv = os.path.join(tmp, 'ned-%d' % os.getuid())
        env2 = dict(os.environ, TMPDIR=tmp)
        outside_ok = subprocess.run([NED, '--remote-message', 'hello-from-outside'], env=env2, capture_output=True,
                                    text=True, timeout=30)
        r = subprocess.run([NED, '--sandbox', '--', sys.executable, '-I', '-c', SANDBOXED_CLIENT, priv], cwd=proj,
                           env=env2, capture_output=True, text=True, timeout=60)
        r2 = subprocess.run([NED, '--sandbox', '--', NED, '--remote-message', 'from-the-sandbox-2'], cwd=proj,
                            env=env2, capture_output=True, text=True, timeout=60)
        time.sleep(1)
        screen = subprocess.run(['tmux', '-L', sock, 'capture-pane', '-t', 's', '-p'], capture_output=True,
                                text=True).stdout
        try: answers = json.loads(r.stdout.strip().splitlines()[-1])
        except (ValueError, IndexError): answers = {'raw': r.stdout + r.stderr}
        got = (outside_ok, answers, r2, screen)
    subprocess.run(['tmux', '-L', sock, 'send-keys', '-t', 's', 'C-q'])
    time.sleep(1)
    subprocess.run(['tmux', '-L', sock, 'kill-server'])
    if sockets:
        # (the kept terminal outlives ned, as it should: stopped here, or it would run on after the test)
        for p in os.listdir('/proc'):
            try: cmd = open('/proc/%s/cmdline' % p, 'rb').read().decode(errors='replace')
            except (OSError, ValueError): continue
            if p.isdigit() and '--term-host' in cmd and root in cmd: os.kill(int(p), 15)
    if runner: return started and proj_read and data_read, read, ran
    if sockets: return started and proj_read and data_read, read, got
    return started and proj_read and data_read, read

started, read = session(True)
check('a plugin in the sandbox: runs, reads the project and its own data', started)
check('a plugin in the sandbox: cannot read a file outside the project', read is None, read)
started, read = session(False)
check('plugins.sandbox off: it runs as before (and reads the file)', started and read == 'the secret', read)

# a plugin allowed to run programs itself: a process of its own — the others stay in the sandbox
started, read, ran = session(True, runner=True)
check('a plugin allowed to run programs: it runs them', ran)
check('… and the other plugins stay in the sandbox (a process of its own for it)', started and read is None, read)

# the sockets: ned's remote control and a kept terminal's, from inside the sandbox and from outside
started, read, got = session(True, sockets=True)
outside_ok, answers, r2, screen = got
check('the remote control from outside the sandbox: it works', outside_ok.returncode == 0 and
      'hello-from-outside' in screen, outside_ok.stdout + outside_ok.stderr + screen)
check('… from inside: the key beside the socket cannot be read', answers.get('key') == 'refused', answers)
check('… a request without it is refused', 'refused' in answers.get('answer', ''), answers)
check('… `ned --remote-message` in the sandbox does nothing', r2.returncode != 0 and 'from-the-sandbox' not in screen,
      r2.stdout + r2.stderr + screen)
check('a kept terminal\'s socket from inside the sandbox: refused (no key)', answers.get('terms', 0) >= 1 and
      answers.get('term') == "b''", answers)
shutil.rmtree(root, ignore_errors=True)
if fails:
    print('%d failed' % len(fails))
    sys.exit(1)
print('all passed')
