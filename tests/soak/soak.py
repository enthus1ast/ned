#!/usr/bin/env python3
"""A long editing session, for the leaks and the faults that only show after hours. ned edits a copy of its own
source (src/ and ned.nimble) in a private tmux server: it opens files, types code, asks for completions, undoes and
redoes, finds, formats, saves, selects, copies and pastes, scrolls and closes tabs — picked at random, a few a
second; now and then it closes all the tabs but one, as a person would, and goes to a second project (the UI tests'
demo, with a C file) and back. Meanwhile this script watches:

  memory    ned's resident memory and its engine worker's (Linux: /proc), sampled every --sample seconds
  errors    "Internal error" on the screen, and ned's errors.log (its state folder is the run's own)
  ned       still running, and still drawing (its screen changes when a key goes in)

At the end it prints how memory went (the first stretch of the run against the last) and what went wrong.
Exit status 1 when ned ended or stopped answering, made an internal error, or its memory grew by more than
--grow-mb between the run's first quarter and its last (after a warm-up).

Usage: soak.py path/to/ned [--minutes N (180)] [--seed S] [--sample SECONDS (30)] [--grow-mb MB (60)] [--keep]
Needs tmux. A short run to try it: soak.py ./ned --minutes 3"""
import json, os, random, re, shutil, statistics, subprocess, sys, tempfile, time

ARGS = sys.argv[1:]
if not ARGS or ARGS[0].startswith('-'): sys.exit(__doc__)
def opt(name, default, conv=float):
    return conv(ARGS[ARGS.index(name) + 1]) if name in ARGS else default
NED = os.path.abspath(ARGS[0])
MINUTES = opt('--minutes', 180.0)
SEED = opt('--seed', int(time.time()) % 100000, int)
SAMPLE = opt('--sample', 30.0)
GROW_MB = opt('--grow-mb', 60.0)
KEEP = '--keep' in ARGS
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SOCK = 'ned-soak-%d' % os.getpid()
W, H = 140, 45
if not shutil.which('tmux'): sys.exit('soak.py needs tmux')
rnd = random.Random(SEED)

def tm(*a):
    return subprocess.run(['tmux', '-L', SOCK] + list(a), capture_output=True, text=True)
def keys(*k, gap=0.08):
    for x in k:
        tm('send-keys', '-t', 's', x)
        time.sleep(gap)
def text(s, gap=0.0):
    if gap:
        for ch in s:
            tm('send-keys', '-t', 's', '-l', ch)
            time.sleep(gap)
    else:
        tm('send-keys', '-t', 's', '-l', s)
    time.sleep(0.1)
def screen():
    return tm('capture-pane', '-t', 's', '-p').stdout

# ── the project, the settings, ned ──

root = tempfile.mkdtemp(prefix='ned-soak-')
proj = os.path.join(root, 'proj')
shutil.copytree(os.path.join(REPO, 'src'), os.path.join(proj, 'src'))
shutil.copy(os.path.join(REPO, 'ned.nimble'), proj)
subprocess.run(['git', 'init', '-q', proj], capture_output=True)
subprocess.run(['git', '-C', proj, 'add', '.'], capture_output=True)
subprocess.run(['git', '-C', proj, '-c', 'user.email=soak@ned', '-c', 'user.name=soak', 'commit', '-qm', 'start'],
               capture_output=True)
# a second project — the UI tests' demo, with a C file — that the session goes to and back from now and then (what ned
# keeps about a project must go when another is opened: 6.32.4)
proj2 = os.path.join(root, 'proj2')
shutil.copytree(os.path.join(REPO, 'tests', 'ui', 'fixtures', 'demo'), proj2)
open(os.path.join(proj2, 'src', 'calc.c'), 'w').write(
    '#include <stdio.h>\n#include <string.h>\n\nstatic int twice(int x) { return 2 * x; }\n\n'
    'int main(void) {\n  printf("%d %zu\\n", twice(21), strlen("soak"));\n  return 0;\n}\n')
for d in (proj2,):
    subprocess.run(['git', 'init', '-q', d], capture_output=True)
    subprocess.run(['git', '-C', d, 'add', '.'], capture_output=True)
    subprocess.run(['git', '-C', d, '-c', 'user.email=soak@ned', '-c', 'user.name=soak', 'commit', '-qm', 'start'],
                   capture_output=True)
FILES2 = sorted(os.path.relpath(os.path.join(d, f), proj2) for d, _, fs in os.walk(os.path.join(proj2, 'src'))
                for f in fs if f.endswith(('.nim', '.c')))
here = [proj]                       # (the project open now)
FILES = sorted(os.path.relpath(os.path.join(d, f), proj) for d, _, fs in os.walk(os.path.join(proj, 'src'))
               for f in fs if f.endswith('.nim'))
cfg, state = os.path.join(root, 'cfg'), os.path.join(root, 'state')
os.makedirs(cfg + '/ned')
json.dump({'security.folderTrust': 'off', 'ai.provider': 'off', 'ui.cursorAnimation': 'off', 'files.hotExit': False},
          open(cfg + '/ned/config.json', 'w'))
pidfile, exitfile = os.path.join(root, 'pid'), os.path.join(root, 'exit')
env = 'XDG_CONFIG_HOME=%s XDG_STATE_HOME=%s TERM=xterm-256color COLORTERM=truecolor NED_SOCKET=' % (cfg, state)
tm('new-session', '-d', '-s', 's', '-x', str(W), '-y', str(H),
   "cd %s && sh -c 'echo $$ > %s; exec env %s %s %s'; echo $? > %s; sleep 100000" %
   (proj, pidfile, env, NED, 'src/ned.nim', exitfile))
time.sleep(2)

def ned_pid():
    try: return int(open(pidfile).read().strip())
    except (OSError, ValueError): return 0

def alive():
    return not os.path.exists(exitfile) and ned_pid() > 0 and os.path.exists('/proc/%d' % ned_pid())

def rss_mb(pid):
    try:
        for l in open('/proc/%d/status' % pid):
            if l.startswith('VmRSS:'): return int(l.split()[1]) / 1024
    except OSError: pass
    return 0.0

def memory():
    """(ned, its engine worker) resident memory in MB"""
    pid = ned_pid()
    worker = 0.0
    for p in os.listdir('/proc'):
        if not p.isdigit(): continue
        try:
            st = open('/proc/%s/stat' % p).read()
            if int(st[st.rindex(')') + 2:].split()[1]) != pid: continue
            if b'--engine-worker' in open('/proc/%s/cmdline' % p, 'rb').read(): worker += rss_mb(int(p))
        except (OSError, ValueError): pass
    return rss_mb(pid), worker

# ── what a person does ──

WORDS = ['let total = 0', 'echo "soak"', 'var items: seq[string]', 'proc soakHelper(x: int): int = x * 2',
         'if total > 3: inc total', 'discard items.len', 'for i in 0 ..< 3: echo i', '# a comment about nothing']
def esc(): keys('Escape', 'Escape')
def open_file():
    f = rnd.choice(FILES if here[0] == proj else FILES2)
    keys('C-p'); time.sleep(0.3)
    text(os.path.basename(f)[:-4]); time.sleep(0.5)
    keys('Enter'); time.sleep(0.6)
def go_line():
    keys('C-g'); text(str(rnd.randint(1, 400))); keys('Enter')
def type_code():
    go_line(); keys('End', 'Enter')
    text(rnd.choice(WORDS), gap=0.02)
def complete():
    go_line(); keys('End', 'Enter')
    text(rnd.choice(['b.', 'result.', 'cfg', 'getE', 'str.']), gap=0.05)
    keys('C-Space'); time.sleep(0.6); esc()
def undo_redo():
    n = rnd.randint(1, 6)
    keys(*(['C-z'] * n)); keys(*(['C-y'] * rnd.randint(0, n)))
def save(): keys('C-s'); time.sleep(0.3); esc()
def find():
    keys('C-f'); text(rnd.choice(['proc ', 'result', 'let ', 'buf', 'line'])); keys('Enter', 'Enter'); esc()
def scroll():
    k = rnd.choice(['PageDown', 'PageUp', 'C-End', 'C-Home', 'Down', 'Up'])
    keys(*([k] * rnd.randint(1, 8)), gap=0.04)
def select_copy_paste():
    keys(*(['S-Down'] * rnd.randint(1, 4)), gap=0.04); keys('C-c', 'Down', 'C-v')
def palette():
    keys('C-e'); time.sleep(0.3)
    text(rnd.choice(['Format document', 'Toggle word wrap', 'Fold all', 'Unfold all', 'Go to symbol']))
    time.sleep(0.4); keys('Enter'); time.sleep(0.5); esc()
def close_tab():
    keys('C-s'); time.sleep(0.2); keys('C-w'); time.sleep(0.3); esc()
def close_others():
    # (a person keeps a handful of tabs open, not every file opened in an hour: tabs piling up make ned grow for a
    # good reason, and that hid the growth that was a leak)
    for cmd in ('Save all', 'Close other tabs'):
        keys('C-e'); time.sleep(0.3); text(cmd); time.sleep(0.4); keys('Enter'); time.sleep(0.5)
    esc()
def revert_all():
    # (now and then the project goes back to how it started: the files do not grow for hours)
    save()
    for d in (proj, proj2): subprocess.run(['git', '-C', d, 'checkout', '-q', '--', '.'], capture_output=True)
    time.sleep(1)
def switch_project():
    # File › open folder by path: the other project (the prompt starts with this one's folder and a `/`)
    other = proj2 if here[0] == proj else proj
    close_others()
    keys('C-e'); time.sleep(0.3); text('File: open folder by path'); time.sleep(0.4); keys('Enter'); time.sleep(0.4)
    text('../' + os.path.basename(other)); keys('Enter'); time.sleep(2); esc()
    here[0] = other

ACTIONS = [(open_file, 8), (type_code, 20), (complete, 10), (undo_redo, 10), (save, 8), (find, 8), (scroll, 15),
           (select_copy_paste, 6), (palette, 5), (close_tab, 4)]
POOL = [f for f, w in ACTIONS for _ in range(w)]

# ── the session ──

errors, samples, problems = [], [], []
errlog = os.path.join(state, 'ned', 'errors.log')
def errlog_lines():
    try: return [l for l in open(errlog, errors='replace').read().splitlines() if l.strip() and l[:1].isdigit()]
    except OSError: return []

t0 = time.monotonic()
end = t0 + MINUTES * 60
next_sample = t0
actions = 0
seen_errs = 0
print('soak: ned %s, %.0f minutes, seed %d, project %s' % (NED, MINUTES, SEED, proj), flush=True)
print('%8s %8s %10s %10s %8s' % ('minutes', 'actions', 'ned MB', 'worker MB', 'errors'), flush=True)
last_revert = t0
while time.monotonic() < end:
    if not alive():
        problems.append('ned ended (exit status %s)' % (open(exitfile).read().strip() if os.path.exists(exitfile) else '?'))
        break
    rnd.choice(POOL)()
    actions += 1
    if actions % 25 == 0: esc()
    if actions % 60 == 0: close_others()
    if actions % 150 == 0: switch_project()
    if time.monotonic() - last_revert > 600:
        revert_all(); last_revert = time.monotonic()
    s = screen()
    if 'Internal error' in s:
        m = re.search(r'Internal error[^\n]*', s)
        errors.append((round((time.monotonic() - t0) / 60, 1), m.group(0).strip() if m else 'Internal error'))
    if time.monotonic() >= next_sample:
        ned_mb, wk_mb = memory()
        el = errlog_lines()
        if len(el) > seen_errs:
            for l in el[seen_errs:]: errors.append((round((time.monotonic() - t0) / 60, 1), l))
            seen_errs = len(el)
        samples.append((time.monotonic() - t0, ned_mb, wk_mb))
        print('%8.1f %8d %10.1f %10.1f %8d' % ((time.monotonic() - t0) / 60, actions, ned_mb, wk_mb, len(errors)),
              flush=True)
        next_sample += SAMPLE

# (what ned says it holds: its heap and its index, from the Performance report — the index grows up to its budget,
# nim.indexMemory, as the session reaches more files: growth that stops there is not a leak)
report = []
if alive():
    esc(); keys('C-e'); time.sleep(0.3); text('Performance report'); time.sleep(0.5); keys('Enter'); time.sleep(1.5)
    report = [l.strip(' │') for l in screen().splitlines() if re.search(r'Memory:|index:|engine worker:|it holds', l)]
    esc(); keys('C-w'); time.sleep(0.3)
# (still answering? a key must change the screen)
if alive():
    esc(); before = screen()
    keys('C-g'); time.sleep(1.0)
    if screen() == before: problems.append('ned stopped answering: Ctrl+G changed nothing on the screen')
    esc()
    keys('C-q'); time.sleep(1.5)
    if alive(): keys('n'); time.sleep(1.0)          # (a question about unsaved files: do not save)
tm('kill-server')

# ── what happened ──
dur = (samples[-1][0] if samples else 0) / 60
print('\n%d actions in %.1f minutes' % (actions, (time.monotonic() - t0) / 60))
if len(samples) >= 4:
    warm = [s for s in samples if s[0] >= min(60, samples[-1][0] / 8)]
    q = max(1, len(warm) // 4)
    first = statistics.median(s[1] + s[2] for s in warm[:q])
    last = statistics.median(s[1] + s[2] for s in warm[-q:])
    peak = max(s[1] + s[2] for s in samples)
    print('memory (ned and its worker): %.0f MB early on, %.0f MB at the end, %.0f MB at most' % (first, last, peak))
    for l in report: print('  ' + re.sub(r'\s+', ' ', l).strip())
    if last - first > GROW_MB:
        problems.append('memory grew by %.0f MB (more than %.0f): a leak?' % (last - first, GROW_MB))
else:
    print('(too few samples to say how memory went: a longer run, or a shorter --sample)')
seen = set()
for at, e in errors:
    if e in seen: continue
    seen.add(e)
    problems.append('at %.1f min: %s' % (at, e))
if KEEP: print('(kept: %s)' % root)
else: shutil.rmtree(root, ignore_errors=True)
if problems:
    print('\nproblems:\n  ' + '\n  '.join(problems))
    sys.exit(1)
print('no problems')
