#!/usr/bin/env python3
"""Plugins in ned's sandbox (Linux's Landlock, plugins.sandbox), with the real editor and its plugin host: a plugin
that needs no permission at all tries, when ned starts, to read a file outside the project and the system's folders
(a stand-in for ~/.ssh) — with the sandbox the kernel refuses (in NimScript that ends the plugin's process), without
it the plugin reads it. Also `ned --sandbox` from the command line: a shell that writes outside the current folder is
refused, and the environment's secrets do not reach it.

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

def session(sandbox):
    run = os.path.join(root, 'run-%s' % sandbox)
    cfg, state, data, cache = [os.path.join(run, x) for x in ('cfg', 'state', 'data', 'cache')]
    os.makedirs(cfg + '/ned/plugins/probe')
    open(cfg + '/ned/plugins/probe/plugin.nims', 'w').write(PLUGIN)
    json.dump({'security.folderTrust': 'off', 'ai.provider': 'off', 'plugins.native': 'off', 'plugins.sandbox': sandbox},
              open(cfg + '/ned/config.json', 'w'))
    open(os.path.join(proj, 'main.nim'), 'w').write('echo "hello"\n')
    sock = 'ned-tsandbox-%d' % os.getpid()
    env = ('XDG_CONFIG_HOME=%s XDG_STATE_HOME=%s XDG_DATA_HOME=%s XDG_CACHE_HOME=%s TERM=xterm-256color NED_SOCKET=' %
           (cfg, state, data, cache))
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
    subprocess.run(['tmux', '-L', sock, 'send-keys', '-t', 's', 'C-q'])
    time.sleep(1)
    subprocess.run(['tmux', '-L', sock, 'kill-server'])
    return started and proj_read and data_read, read

started, read = session(True)
check('a plugin in the sandbox: runs, reads the project and its own data', started)
check('a plugin in the sandbox: cannot read a file outside the project', read is None, read)
started, read = session(False)
check('plugins.sandbox off: it runs as before (and reads the file)', started and read == 'the secret', read)

shutil.rmtree(root, ignore_errors=True)
if fails:
    print('%d failed' % len(fails))
    sys.exit(1)
print('all passed')
