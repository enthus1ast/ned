#!/usr/bin/env python3
"""ned's speed budgets, measured on this machine against a given ned — a script to run by hand before a release:

  startup              the first frame of ned started in an empty folder (ned --startup-time)
  open a big file      the first frame of ned started with a 50 000-line file: ned's own source as one file
  typing               a key typed in that file: from the key to the end of the frame it brings (in a
                       pseudo-terminal, as a terminal sees it: what you wait for) — its median and the slowest one
                       in twenty (a key that came while ned was busy with something else waits for it)
  cursor down          the same for the Down arrow
  typing in C, in Markdown, in JSON   a key typed in a 50 000-line file of each (made up here: C functions with
                       #ifdef blocks, ned's docs over and over, an array of objects) — their medians and slowest in 20

Each is the median of a few runs, checked against its limit (below, or --limit NAME=MS). ned runs with settings
and state of its own (nothing of yours is read or changed) and without the remote-control socket.

Usage: budgets.py path/to/ned [--runs N] [--keys N] [--limit NAME=MS]… [--json]
Exit status 1 when one is over its limit. Linux and macOS (a pseudo-terminal)."""
import json, os, pty, re, select, shutil, signal, statistics, struct, sys, tempfile, time
import fcntl, termios

LIMITS = {                                   # milliseconds
    'startup: first frame': 150,
    'open a big file: first frame': 300,
    'typing: frame, median': 16,
    'typing: frame, 1 in 20': 50,
    'cursor down: frame, median': 16,
    'cursor down: frame, 1 in 20': 50,
    'typing in C: frame, median': 16,
    'typing in C: frame, 1 in 20': 50,
    'typing in Markdown: frame, median': 16,
    'typing in Markdown: frame, 1 in 20': 50,
    'typing in JSON: frame, median': 16,
    'typing in JSON: frame, 1 in 20': 50,
}
W, H = 140, 45
ARGS = sys.argv[1:]
if not ARGS or ARGS[0].startswith('-'):
    sys.exit(__doc__)
NED = os.path.abspath(ARGS[0])
RUNS = int(ARGS[ARGS.index('--runs') + 1]) if '--runs' in ARGS else 3
NKEYS = int(ARGS[ARGS.index('--keys') + 1]) if '--keys' in ARGS else 60
for i, a in enumerate(ARGS):
    if a == '--limit':
        k, v = ARGS[i + 1].rsplit('=', 1)
        if k not in LIMITS: sys.exit('no budget named %r — the names: %s' % (k, ', '.join(LIMITS)))
        LIMITS[k] = float(v)
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

class Ned:
    """ned in a pseudo-terminal of its own, with settings and state of its own"""
    def __init__(self, cwd, args):
        self.tmp = tempfile.mkdtemp(prefix='ned-budgets-')
        os.makedirs(self.tmp + '/cfg/ned')
        json.dump({'security.folderTrust': 'off', 'ai.provider': 'off', 'ui.cursorAnimation': 'off'},
                  open(self.tmp + '/cfg/ned/config.json', 'w'))
        self.err = os.path.join(self.tmp, 'stderr')
        env = dict(os.environ, TERM='xterm-256color', COLORTERM='truecolor', XDG_CONFIG_HOME=self.tmp + '/cfg',
                   XDG_STATE_HOME=self.tmp + '/state', HOME=self.tmp, NED_SOCKET='')
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(cwd)
            e = os.open(self.err, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            os.dup2(e, 2)
            os.execve(NED, [NED] + args, env)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack('HHHH', H, W, 0, 0))

    def read(self, timeout):
        """what ned drew within `timeout` seconds (None: it ended)"""
        r, _, _ = select.select([self.fd], [], [], timeout)
        if not r: return b''
        try: data = os.read(self.fd, 1 << 16)
        except OSError: return None
        if b'\x1b[6n' in data: os.write(self.fd, b'\x1b[%d;%dR' % (H, W))    # (where the cursor is: a terminal says)
        return data

    def settle(self, quiet=1.0, most=30):
        """read until ned has drawn nothing for `quiet` seconds"""
        end = time.monotonic() + most
        last = time.monotonic()
        while time.monotonic() < end:
            d = self.read(0.05)
            if d is None: return
            if d: last = time.monotonic()
            elif time.monotonic() - last > quiet: return

    def frame_ms(self, key, shows=None, quiet=0.003):
        """a key in, the frame it brings out: ms from the key to the last byte of the frame that shows `shows` (a
        typed character: what is drawn at once may be only the cursor) — or, without `shows`, of the first frame"""
        t0 = time.monotonic()
        os.write(self.fd, key)
        seen = ''
        while True:
            d = self.read(1.0)
            if not d: return None
            seen += re.sub(r'\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07', '', d.decode('utf-8', 'replace'))
            if shows is None or shows in seen: break
        last = time.monotonic()
        while True:
            d = self.read(quiet)
            if not d: break
            last = time.monotonic()
        return (last - t0) * 1000

    def wait(self, secs=60):
        end = time.monotonic() + secs
        while time.monotonic() < end:
            if self.read(0.1) is None: break
            p, _ = os.waitpid(self.pid, os.WNOHANG)
            if p: return
        os.kill(self.pid, signal.SIGKILL)
        os.waitpid(self.pid, 0)

    def stop(self):
        try: os.kill(self.pid, signal.SIGTERM)
        except ProcessLookupError: pass
        self.wait(20)
        shutil.rmtree(self.tmp, ignore_errors=True)

def startup(cwd, args):
    """ned --startup-time: the first frame, in ms (its STARTUP line)"""
    n = Ned(cwd, ['--startup-time'] + args)
    n.wait(60)
    text = open(n.err).read()
    shutil.rmtree(n.tmp, ignore_errors=True)
    m = re.search(r'^STARTUP (.*)$', text, re.M)
    if not m: sys.exit('ned --startup-time printed no STARTUP line:\n' + text)
    return {k: float(v) for k, v in (x.split('=') for x in m.group(1).split())}['first_frame_ms']

def big_file(dirname):
    """ned's own source (src/**.nim) as one file, cut to 50 000 lines"""
    p = os.path.join(dirname, 'big.nim')
    lines = []
    for root, _, files in sorted(os.walk(os.path.join(REPO, 'src'))):
        for f in sorted(files):
            if f.endswith('.nim'): lines += open(os.path.join(root, f), encoding='utf-8', errors='replace').read().splitlines()
    open(p, 'w').write('\n'.join(lines[:50000]) + '\n')
    return p

def other_files(dirname):
    """50 000-line files of C, Markdown and JSON (the C one with a warning every ten lines — printf's "%%d" with an
    argument: 5 000 problems, which each frame once looked through for every line it drew)"""
    c, i = [], 0
    while len(c) < 50000:
        c += ['#include <stdio.h>' if i == 0 else '', '/* function %d */' % i, 'static int f%d(int a, int b) {' % i,
              '  int x = a * %d + b;' % i, '  if (x > 10) { printf("%%d\\n", x); }', '#ifdef DEBUG', '  x += 1;', '#endif',
              '  return x;', '}']
        i += 1
    md = []
    docs = sorted(os.path.join(r, f) for r, _, fs in os.walk(os.path.join(REPO, 'docs')) for f in fs if f.endswith('.md'))
    for f in docs: md += open(f, encoding='utf-8').read().splitlines()
    while len(md) < 50000: md += md
    js = ['['] + ['  {"id": %d, "name": "item %d", "tags": ["a", "b"], "value": %d.5},' % (k, k, k) for k in range(49998)] + \
         ['  {"id": -1}', ']']
    out = {}
    for name, lines in (('C', c), ('Markdown', md), ('JSON', js)):
        p = os.path.join(dirname, 'big.' + {'C': 'c', 'Markdown': 'md', 'JSON': 'json'}[name])
        open(p, 'w').write('\n'.join(lines[:50000]) + '\n')
        out[name] = p
    return out

def keys(work, big):
    """typing and Down in the big file: each key's frame, in ms"""
    n = Ned(work, [big])
    n.settle(1.5)
    os.write(n.fd, b'\x07'); n.settle(0.3)                  # Ctrl+G: go to line
    os.write(n.fd, b'25000\r'); n.settle(0.5)
    os.write(n.fd, b'\x1b[F\r'); n.settle(0.5)              # End, Enter: a line of its own
    typing, down = [], []
    os.write(n.fd, b'#'); n.settle(0.5)
    word = 'xzqw'                     # (letters ned's escape sequences never use: found in what it draws)
    for i in range(NKEYS):
        ms = n.frame_ms(word[i % len(word)].encode(), shows=word[i % len(word)])
        if ms is not None: typing.append(ms)
        time.sleep(0.04)
    n.settle(0.5)
    os.write(n.fd, b'\x1b'); n.settle(0.3)
    for i in range(NKEYS):
        ms = n.frame_ms(b'\x1b[B')
        if ms is not None: down.append(ms)
        time.sleep(0.04)
    n.stop()
    return typing, down

def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(p * (len(xs) - 1))))] if xs else float('nan')

def main():
    work = tempfile.mkdtemp(prefix='ned-budgets-work-')
    empty = os.path.join(work, 'empty')
    os.makedirs(empty)
    big = big_file(work)
    got = {}
    got['startup: first frame'] = statistics.median(startup(empty, []) for _ in range(RUNS))
    got['open a big file: first frame'] = statistics.median(startup(work, [big]) for _ in range(RUNS))
    t, d = [], []
    for _ in range(RUNS):
        a, b = keys(work, big)
        t += a; d += b
    got['typing: frame, median'] = statistics.median(t) if t else float('nan')
    got['typing: frame, 1 in 20'] = pct(t, 0.95)
    got['cursor down: frame, median'] = statistics.median(d) if d else float('nan')
    got['cursor down: frame, 1 in 20'] = pct(d, 0.95)
    for name, path in other_files(work).items():
        t = []
        for _ in range(RUNS): t += keys(work, path)[0]
        got['typing in %s: frame, median' % name] = statistics.median(t) if t else float('nan')
        got['typing in %s: frame, 1 in 20' % name] = pct(t, 0.95)
    shutil.rmtree(work, ignore_errors=True)
    over = [k for k, v in got.items() if not v <= LIMITS[k]]
    if '--json' in ARGS:
        print(json.dumps({'ms': got, 'limits': LIMITS, 'over': over}, indent=1))
    else:
        print('%-36s %10s %10s' % ('budget', 'measured', 'limit'))
        for k, v in got.items():
            print('%-36s %7.1f ms %7.0f ms%s' % (k, v, LIMITS[k], '   OVER' if k in over else ''))
        print('\nover budget: ' + ', '.join(over) if over else '\nall within budget')
    sys.exit(1 if over else 0)

if __name__ == '__main__':
    main()
