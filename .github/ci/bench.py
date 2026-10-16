#!/usr/bin/env python3
"""ned's performance check: how fast it starts, how much memory it uses, how long a frame takes.
   Each startup case runs ned --startup-time in a real pseudo-terminal (fresh settings and state), a few times;
   the median is compared with the budget in bench-budget.json. ned --bench gives the time per frame.
Usage: bench.py path/to/ned [runs]          (run it from the repository's folder: it opens its source as one big file)
Prints a table (and adds it to the GitHub job summary); exits 1 when a number is over its budget."""
import json, os, pty, re, select, shutil, statistics, struct, subprocess, sys, tempfile, time
import fcntl, termios

NED = os.path.abspath(sys.argv[1])
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 5
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.getcwd()
BUDGET = json.load(open(os.path.join(HERE, 'bench-budget.json')))

def startup(cwd, args):
    """one ned --startup-time run: the numbers of its STARTUP line"""
    tmp = tempfile.mkdtemp(prefix='ned-bench-')
    err = os.path.join(tmp, 'err')
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(cwd)
        e = os.open(err, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.dup2(e, 2)
        os.environ.update(TERM='xterm-256color', COLORTERM='truecolor',
                          XDG_CONFIG_HOME=tmp + '/cfg', XDG_STATE_HOME=tmp + '/state', HOME=tmp)
        os.execv(NED, [NED, '--startup-time'] + args)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 140, 0, 0))
    t0 = time.time()
    status = None
    while status is None:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                data = os.read(fd, 65536)
                if b'\x1b[6n' in data: os.write(fd, b'\x1b[40;140R')   # (a terminal answers where its cursor is)
            except OSError: pass
        p, st = os.waitpid(pid, os.WNOHANG)
        if p: status = st
        elif time.time() - t0 > 60:
            os.kill(pid, 9); os.waitpid(pid, 0); status = -1
    text = open(err).read()
    shutil.rmtree(tmp, ignore_errors=True)
    m = re.search(r'^STARTUP (.*)$', text, re.M)
    if not m: raise SystemExit('ned --startup-time printed no STARTUP line:\n' + text)
    return {k: float(v) for k, v in (x.split('=') for x in m.group(1).split())}

def big_file():
    """ned's own source (src/**.nim) as one file: 53 000 lines of real code"""
    p = os.path.join(tempfile.gettempdir(), 'ned-bench-source-%d.nim' % os.getpid())
    parts = []
    for root, _, files in sorted(os.walk(os.path.join(REPO, 'src'))):
        for f in sorted(files):
            if f.endswith('.nim'): parts.append(open(os.path.join(root, f)).read())
    open(p, 'w').write('\n'.join(parts))
    return p

BIG = big_file()

def frames():
    r = subprocess.run([NED, '--bench', BIG], cwd=REPO, capture_output=True, text=True, timeout=300)
    out = {}
    for l in r.stderr.splitlines():
        m = re.match(r'(\S.*?)\s{2,}([\d.]+) ms', l)
        if m: out[m.group(1)] = float(m.group(2))
    return out

empty = tempfile.mkdtemp(prefix='ned-bench-empty-')
cases = [('empty folder', empty, []), ('this repository', REPO, []), ('a big file (ned in one)', REPO, [BIG])]
rows, over = [], []
for name, cwd, args in cases:
    runs = [startup(cwd, args) for _ in range(RUNS)]
    med = {k: statistics.median(r[k] for r in runs) for k in runs[0]}
    b = BUDGET['startup'].get(name, {})
    for k, v in sorted(med.items()):
        lim = b.get(k)
        bad = lim is not None and v > lim
        if bad: over.append('%s: %s = %.1f (budget %s)' % (name, k, v, lim))
        rows.append((name, k, v, lim, bad))
for k, v in frames().items():
    lim = BUDGET['frame_ms'].get(k)
    bad = lim is not None and v > lim
    if bad: over.append('frame: %s = %.3f ms (budget %s)' % (k, v, lim))
    rows.append(('ned --bench (big file)', k + ' ms/frame', v, lim, bad))
shutil.rmtree(empty, ignore_errors=True)
os.remove(BIG)

w = max(len(r[0]) for r in rows) + 2
print('%s%-28s %10s %10s' % ('case'.ljust(w), 'measure', 'median', 'budget'))
for c, k, v, lim, bad in rows:
    print('%s%-28s %10.2f %10s%s' % (c.ljust(w), k, v, '-' if lim is None else lim, '   OVER' if bad else ''))
summary = os.environ.get('GITHUB_STEP_SUMMARY')
if summary:
    with open(summary, 'a') as f:
        f.write('### ned performance (median of %d runs)\n\n| case | measure | median | budget |\n|---|---|---|---|\n' % RUNS)
        for c, k, v, lim, bad in rows:
            f.write('| %s | %s | %.2f | %s%s |\n' % (c, k, v, '-' if lim is None else lim, ' ⚠ over' if bad else ''))
if over:
    print('\nover budget:\n  ' + '\n  '.join(over))
    sys.exit(1)
print('\nall within budget')
