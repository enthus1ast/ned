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
if sys.platform == 'darwin':
    # (macOS: the limits of its own section replace the others — GitHub's shared macOS machines vary the most)
    mac = BUDGET.get('macos', {})
    for case, lims in mac.get('startup', {}).items(): BUDGET['startup'].setdefault(case, {}).update(lims)
    for k in ('terminal_ms_per_100k_lines',):
        if k in mac: BUDGET[k] = mac[k]

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
    """ned's own source (src/**.nim) as one file, its first 150 000 lines: real code, the same amount however much
       the source grows"""
    p = os.path.join(tempfile.gettempdir(), 'ned-bench-source-%d.nim' % os.getpid())
    parts = []
    for root, _, files in sorted(os.walk(os.path.join(REPO, 'src'))):
        for f in sorted(files):
            if f.endswith('.nim'): parts.append(open(os.path.join(root, f)).read())
    open(p, 'w').write('\n'.join('\n'.join(parts).split('\n')[:150000]))
    return p

BIG = big_file()

def long_line():
    """a minified JSON file: one line of 5 MB"""
    p = os.path.join(tempfile.gettempdir(), 'ned-bench-line-%d.json' % os.getpid())
    items = ['{"id":%d,"name":"item %d","tags":["a","b","c"],"price":%.1f,"ok":%s}' % (i, i, i * 1.5, 'true' if i % 2 == 0 else 'false')
             for i in range(62000)]
    open(p, 'w').write('[' + ','.join(items) + ']')
    return p

def huge_log():
    """a log of 80 MB: a million lines"""
    p = os.path.join(tempfile.gettempdir(), 'ned-bench-log-%d.log' % os.getpid())
    with open(p, 'w') as f:
        for i in range(1000000):
            f.write('2026-10-19 12:%02d:%02d INFO request id=%d path=/api/v1/items/%d took=%dms\n' %
                    (i // 60 % 60, i % 60, i, (i * 7919) % 1000003, (i * 31) % 900))
    return p

LINE = long_line()
LOG = huge_log()

def frames(path):
    r = subprocess.run([NED, '--bench', path], cwd=REPO, capture_output=True, text=True, timeout=300)
    out, sizes = {}, {}
    for l in r.stderr.splitlines():
        m = re.match(r'(\S.*?)\s{2,}([\d.]+) ms', l)
        if m: out[m.group(1)] = float(m.group(2))
        m = re.search(r'(\S.*?)\s{2,}[\d.]+ ms/frame\s+(\d+) bytes/frame', l)
        if m: sizes[m.group(1)] = int(m.group(2))
    return out, sizes

empty = tempfile.mkdtemp(prefix='ned-bench-empty-')
cases = [('empty folder', empty, []), ('this repository', REPO, []), ('a big file (ned in one)', REPO, [BIG]),
         ('an 80 MB log', REPO, [LOG])]
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
for case, path in [('ned --bench (big file)', BIG), ('ned --bench (5 MB line)', LINE)]:
    times, sizes = frames(path)
    for k, v in times.items():
        if k == 'terminal flood':
            if path != BIG: continue
            lim = BUDGET.get('terminal_ms_per_100k_lines')
            bad = lim is not None and v > lim
            if bad: over.append('terminal flood = %.1f ms per 100 000 lines (budget %s)' % (v, lim))
            rows.append(('built-in terminal', 'flood ms/100k lines', v, lim, bad))
            continue
        lim = BUDGET['frame_ms'].get(k)
        bad = lim is not None and v > lim
        if bad: over.append('%s: %s = %.3f ms (budget %s)' % (case, k, v, lim))
        rows.append((case, k + ' ms/frame', v, lim, bad))
    for k, v in sizes.items():
        # (what a frame sends to the terminal: what a phone's terminal has to draw)
        lim = BUDGET.get('frame_bytes', {}).get(k)
        bad = lim is not None and v > lim
        if bad: over.append('%s: %s = %d bytes (budget %s)' % (case, k, v, lim))
        rows.append((case, k + ' bytes/frame', v, lim, bad))
shutil.rmtree(empty, ignore_errors=True)
for p in (BIG, LINE, LOG): os.remove(p)

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
