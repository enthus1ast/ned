#!/usr/bin/env python3
"""How long ned keeps you waiting while it works on a big program: ned's own source, opened as a project.

ned runs in a pseudo-terminal with NED_PERF_TRACE on (every round of its main loop over 4 ms, with what it did),
while this script opens a file, scrolls, types, asks for completions, adds an import and opens another program.
For each step it prints the longest round (a moment ned did not read a key), and the completion times; the
memory of the editor and its engine worker at the end. Each number is checked against tests/perf/budget.json.

Usage: rounds.py path/to/ned [--runs N] [--steps K] [--keep] [--one-core]
  a first session with nothing in the index's disk cache, then N sessions (1) with what it kept: their median.
  The program worked on is a copy of this repository's src/ and ned.nimble. Linux (memory is read from /proc).
  --one-core: everything on one core (a phone's slow cores as a stand-in).
Exit status 1 when a number is over its budget. NED_PERF_NO_BUDGET=1: print only."""
import json, os, pty, re, select, shutil, signal, statistics, struct, subprocess, sys, tempfile, time
import fcntl, termios

ARGS = [a for a in sys.argv[1:] if not a.startswith('--')]
NED = os.path.abspath(ARGS[0] if ARGS else './ned')
RUNS = 1
if '--runs' in sys.argv: RUNS = int(sys.argv[sys.argv.index('--runs') + 1])
KEEP = '--keep' in sys.argv
if '--one-core' in sys.argv:
    # (a phone's slow cores as a stand-in: ned, its engine worker and what they run share one core with this script)
    os.sched_setaffinity(0, {sorted(os.sched_getaffinity(0))[0]})
STEPS = int(sys.argv[sys.argv.index('--steps') + 1]) if '--steps' in sys.argv else 99
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
BUDGET = json.load(open(os.path.join(HERE, 'budget.json')))
W, H = 140, 45

KEY = {'Enter': b'\r', 'Escape': b'\x1b', 'BSpace': b'\x7f', 'C-Space': b'\x00', 'C-g': b'\x07', 'C-p': b'\x10',
       'End': b'\x1b[F', 'Home': b'\x1b[H', 'PageDown': b'\x1b[6~', 'PageUp': b'\x1b[5~', 'Down': b'\x1b[B',
       'Up': b'\x1b[A', 'C-Home': b'\x1b[1;5H', 'C-End': b'\x1b[1;5F'}

class Ned:
    def __init__(self, tmp, cwd, args, env_extra, cache):
        self.trace = os.path.join(tmp, 'trace.txt')
        self.report = os.path.join(tmp, 'report.txt')
        env = dict(os.environ, TERM='xterm-256color', COLORTERM='truecolor', XDG_CONFIG_HOME=tmp + '/cfg',
                   XDG_STATE_HOME=tmp + '/state', XDG_CACHE_HOME=cache, NED_PERF_TRACE=self.trace,
                   NED_PERF_LOG=self.report, NED_SOCKET='', **env_extra)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(cwd)
            err = os.open(os.path.join(tmp, 'stderr'), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            os.dup2(err, 2)
            os.execve(NED, [NED] + args, env)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack('HHHH', H, W, 0, 0))
        self.t0 = time.monotonic()

    def ms(self):
        return (time.monotonic() - self.t0) * 1000

    def pump(self, secs):
        """read (and drop) what ned draws for a while, answering the cursor-position question"""
        end = time.monotonic() + secs
        while True:
            left = end - time.monotonic()
            if left <= 0: return
            r, _, _ = select.select([self.fd], [], [], min(left, 0.05))
            if r:
                try: data = os.read(self.fd, 1 << 16)
                except OSError: return
                if b'\x1b[6n' in data: os.write(self.fd, b'\x1b[%d;%dR' % (H, W))

    def send(self, *keys, gap=0.05):
        for k in keys:
            os.write(self.fd, KEY.get(k, k.encode() if isinstance(k, str) else k))
            self.pump(gap)

    def type(self, text, gap=0.035):
        for ch in text:
            self.send('Enter' if ch == '\n' else ch, gap=gap)

    def mem_mb(self):
        """resident memory of ned and of its children (the engine worker), in MB"""
        def rss(pid):
            try:
                for l in open('/proc/%d/status' % pid):
                    if l.startswith('VmRSS:'): return int(l.split()[1]) / 1024
            except OSError: pass
            return 0.0
        kids = []
        for p in os.listdir('/proc'):
            if not p.isdigit(): continue
            try:
                st = open('/proc/%s/stat' % p).read()
                if int(st[st.rindex(')') + 2:].split()[1]) == self.pid: kids.append(int(p))
            except (OSError, ValueError): pass
        worker = 0.0
        for k in kids:
            try: cmd = open('/proc/%d/cmdline' % k, 'rb').read()
            except OSError: continue
            if b'--engine-worker' in cmd: worker += rss(k)
        return rss(self.pid), worker

    def stop(self):
        os.kill(self.pid, signal.SIGTERM)
        end = time.monotonic() + 20
        while time.monotonic() < end:
            self.pump(0.1)
            p, _ = os.waitpid(self.pid, os.WNOHANG)
            if p: break
        else:
            os.kill(self.pid, signal.SIGKILL)
            os.waitpid(self.pid, 0)
        rounds = []
        try:
            for l in open(self.trace):
                parts = l.rstrip('\n').split('\t')
                if not parts[0]: continue
                at, us, cpu = (parts[0].split() + ['0'])[:3]      # (cpu: the processor time ned's thread had)
                items = [(x.rsplit('=', 1)[0], int(x.rsplit('=', 1)[1])) for x in parts[1:]]
                rounds.append((int(at), int(us), items, int(cpu)))
        except OSError: pass
        return rounds

def project(root):
    """a copy of ned's own source as a project (its .nimble and src/)"""
    proj = os.path.join(root, 'proj')
    shutil.copytree(os.path.join(REPO, 'src'), os.path.join(proj, 'src'))
    shutil.copy(os.path.join(REPO, 'ned.nimble'), proj)
    return proj

def one_run(root, proj, n, env_extra):
    """one session: fresh settings and state; the index's disk cache is the runs' own (empty for the first)"""
    tmp = os.path.join(root, 'run%d' % n)
    os.makedirs(tmp + '/cfg/ned')
    json.dump({"security.folderTrust": "off", "ai.provider": "off"}, open(tmp + '/cfg/ned/config.json', 'w'))
    ned = Ned(tmp, proj, ['src/ned/ui/editorview.nim'], env_extra, os.path.join(root, 'cache'))
    marks = []                                     # (step, from ms, to ms)
    def step(name, fn, settle):
        if len(marks) >= STEPS: return
        a = ned.ms()
        fn()
        ned.pump(settle)
        marks.append((name, a, ned.ms()))
    step('open a file of a big program', lambda: ned.pump(0.5), 11)
    def scroll():
        for _ in range(12): ned.send('PageDown', gap=0.12)
        for _ in range(12): ned.send('PageUp', gap=0.12)
    step('scroll with hints and counts', scroll, 3)
    def typing():
        ned.send('C-g'); ned.type('385'); ned.send('Enter'); ned.pump(0.5)
        ned.send('End', 'Enter')
        ned.type('let total = b.lines.len + b.topLine * 2\necho total, b.')
        ned.pump(0.6); ned.send('Escape')
    step('type, completion popping up', typing, 3)
    comp = []
    def completions():
        for word in ['b.', 'b.lines.', 'cfg', 'nx', 'b.primary.head.', 're']:
            ned.send('End', 'Enter'); ned.type(word, gap=0.06)
            ned.send('C-Space', gap=0.5); ned.send('Escape', gap=0.2)
    step('ask for completions', completions, 2)
    def new_import():
        ned.send('C-p'); ned.pump(0.3); ned.type('src/ned.nim', gap=0.03); ned.pump(0.4); ned.send('Enter')
        ned.pump(9)
        ned.send('C-Home'); ned.type('import std/sha1\n', gap=0.05)
        ned.type('sha', gap=0.06); ned.send('C-Space', gap=0.6); ned.send('Escape')
    step('a module: an import added, then completion', new_import, 3)
    def other_program():
        ned.send('C-p'); ned.pump(0.3); ned.type('src/nedls.nim', gap=0.03); ned.pump(0.4); ned.send('Enter')
    step('another program opened', other_program, 9)
    ned_mb, worker_mb = ned.mem_mb()
    rounds = ned.stop()
    res = {}
    for name, a, e in marks:
        rs = [r for r in rounds if a - 30 <= r[0] - r[1] / 1000 <= e]
        longest = max(rs, key=lambda r: r[1]) if rs else (0, 0, [])
        cs = [us for r in rs for (n, us) in r[2] if n.replace('› ', '') == 'completion']
        res[name] = {'longest_ms': longest[1] / 1000, 'what': longest[2],
                     'over_16ms': sum(1 for r in rs if r[1] > 16000), 'completions_ms': [c / 1000 for c in cs]}
    allc = [c for v in res.values() for c in v['completions_ms']]
    res['_'] = {'editor_mb': ned_mb, 'worker_mb': worker_mb, 'completions_ms': allc}
    return res

def main():
    root = tempfile.mkdtemp(prefix='ned-perf-')
    proj = project(root)
    # the first session finds nothing in the index's disk cache (ned's first time with this program and this Nim);
    # the others find what it kept
    cold = one_run(root, proj, 0, {})
    runs = [one_run(root, proj, i + 1, {}) for i in range(RUNS)]
    if KEEP: print('(kept: %s)' % root)
    else: shutil.rmtree(root, ignore_errors=True)
    over = []
    first = 'open a file of a big program'
    v = cold[first]['longest_ms']
    b = BUDGET['longest_round_ms'].get('first time', BUDGET['longest_round_ms']['default'])
    what = ', '.join('%s %.1f' % (n, us / 1000) for n, us in sorted(cold[first]['what'], key=lambda x: -x[1])[:3])
    flag = '' if v <= b else '  OVER %d' % b
    if flag: over.append('first time')
    print('%-46s %10s %8s   %s' % ('step', 'longest', '>16 ms', 'what the longest round did'))
    print('%-46s %7.1f ms %8d   %s%s' % (first + ' (nothing cached)', v, cold[first]['over_16ms'], what, flag))
    steps = [k for k in runs[0] if k != '_']
    lim = BUDGET['longest_round_ms']
    for s in steps:
        vals = sorted(r[s]['longest_ms'] for r in runs)
        med = vals[len(vals) // 2]
        best = min(runs, key=lambda r: abs(r[s]['longest_ms'] - med))[s]
        what = ', '.join('%s %.1f' % (n, us / 1000) for n, us in sorted(best['what'], key=lambda x: -x[1])[:3])
        b = lim.get(s, lim['default'])
        flag = '' if med <= b else '  OVER %d' % b
        if flag: over.append(s)
        print('%-46s %7.1f ms %8d   %s%s' % (s, med, best['over_16ms'], what, flag))
    cs = sorted(c for r in runs for c in r['_']['completions_ms'])
    if cs:
        med, mx = statistics.median(cs), cs[-1]
        b = BUDGET['completion_ms']
        flag = '' if mx <= b['max'] and med <= b['median'] else '  OVER %s' % b
        if flag: over.append('completion')
        print('completion: %d asked, median %.1f ms, longest %.1f ms%s' % (len(cs), med, mx, flag))
    em = statistics.median(r['_']['editor_mb'] for r in runs)
    wm = statistics.median(r['_']['worker_mb'] for r in runs)
    b = BUDGET['memory_mb']
    flag = '' if em + wm <= b['editor_and_worker'] else '  OVER %d' % b['editor_and_worker']
    if flag: over.append('memory')
    print('memory: editor %.0f MB, engine worker %.0f MB, together %.0f MB%s' % (em, wm, em + wm, flag))
    if over and not os.environ.get('NED_PERF_NO_BUDGET'):
        print('over budget: ' + ', '.join(over))
        sys.exit(1)

if __name__ == '__main__':
    main()
