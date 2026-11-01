#!/usr/bin/env python3
"""Every command of the palette, one at a time, each in a ned of its own on a copy of the UI tests' demo project
(src/demo.nim open, the cursor on a name): the command runs, Esc closes what it opened, and then

  ned is still running                 (a command that quits or restarts ned is expected to)
  no internal error                    (on the screen, or in errors.log)
  ned still answers                    (the palette opens and shows what is typed in it, within 10 s)

The AI commands talk to the UI tests' mock AI server (tests/ui/mocks/mockai.py), git to the project's own
repository (no remote), and every ned has its own settings, state and home folder — nothing of yours is read or
changed. A few commands are not run, each with its reason (SKIP below): they reach the network, or wait for a
program that never answers here.

With --plugins, every one of ned's own plugins is on (all of them together, in NimScript): first ned starts with
them all and must show none failed and no internal error; then every command the plugins register (by a fixed
name) is run the same way, once the plugins have registered it.

With --menus, every item of every menu of the menu bar and its submenus instead, picked as a person would: F10, Right
to its menu, Down to the item (Right into a submenu), Enter — the same three checks after. The items come from ned
itself (NED_MENU_DUMP: what each menu holds, as it is drawn in that folder).

Usage: commands.py path/to/ned [--jobs N (3)] [--only TEXT] [--plugins] [--menus] [--keep]
Exit status 1 when a command broke one of the three (or, with --plugins, a plugin did not start)."""
import glob, json, os, re, shutil, socket, subprocess, sys, tempfile, threading, time
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
ARGS = sys.argv[1:]
if not ARGS or ARGS[0].startswith('-'): sys.exit(__doc__)
NED = os.path.abspath(ARGS[0])
JOBS = int(ARGS[ARGS.index('--jobs') + 1]) if '--jobs' in ARGS else 3
ONLY = ARGS[ARGS.index('--only') + 1] if '--only' in ARGS else ''
KEEP = '--keep' in ARGS
PLUGINS = '--plugins' in ARGS
MENUS = '--menus' in ARGS
MENU_PATHS = {}       # (--menus) an item's label path → (its menu's place in the bar, its place in each menu down to it, cmd)

# (not run: what for, and why)
SKIP = {
    'Help: update ned…': 'downloads a release',
    'Settings sync: push (save to your settings repository)': 'a remote repository',
    'Settings sync: pull (load from your settings repository)': 'a remote repository',
    'Settings sync: sync now (both ways)': 'a remote repository',
    'GitHub: sign in…': 'github.com',
    'Nimble: refresh the package list': 'the package list from the network',
}

def free_port():
    s = socket.socket(); s.bind(('127.0.0.1', 0)); p = s.getsockname()[1]; s.close(); return p

def bundled_names():
    host = open(os.path.join(REPO, 'src', 'ned', 'plugins', 'host.nim'), encoding='utf-8').read()
    block = host[host.index('PlugBundledNames = ['):]
    return re.findall(r'"([a-z0-9-]+)"', block[:block.index(']')])

def plugin_commands():
    names = []
    for f in sorted(glob.glob(os.path.join(REPO, 'plugins', '*', 'plugin.nims'))):
        # (a command registered at the start of a line — not the word "command" inside a string or a setting's name)
        for m in re.finditer(r'(?m)^[ \t]*command\s*\(?\s*"([^"\n]+)"(\s*&)?', open(f, encoding='utf-8').read()):
            if not m.group(2) and m.group(1) not in names: names.append(m.group(1))
    return names

def command_names():
    env = dict(os.environ, XDG_CONFIG_HOME=tempfile.mkdtemp(prefix='ned-cmds-cfg-'))
    out = subprocess.run([NED, '--doc-commands'], capture_output=True, text=True, env=env).stdout
    names = []
    for line in out.splitlines():
        if not line.startswith('| ') or line.startswith('| Command') or line.startswith('|---'): continue
        cells = re.split(r'(?<!\\) \| ', line[2:])
        names.append(cells[0].replace('\\|', '|').strip())
    return names

ROOT = tempfile.mkdtemp(prefix='ned-cmds-')
TEMPLATE = os.path.join(ROOT, 'demo')
shutil.copytree(os.path.join(REPO, 'tests', 'ui', 'fixtures', 'demo'), TEMPLATE)
subprocess.run('git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm demo', shell=True,
               cwd=TEMPLATE, check=True)
AI_PORT = free_port()
mock = subprocess.Popen([sys.executable, '-I', os.path.join(REPO, 'tests', 'ui', 'mocks', 'mockai.py'), str(AI_PORT)],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=ROOT)
lock = threading.Lock()
results = []          # (name, verdict, detail)

def run_one(slot, name):
    sock = 'ned-cmds-%d-%d' % (os.getpid(), slot)
    work = os.path.join(ROOT, 'w%d' % slot)
    shutil.rmtree(work, ignore_errors=True)
    shutil.copytree(TEMPLATE, os.path.join(work, 'proj'), symlinks=True)
    cfg, state, home = [os.path.join(work, x) for x in ('cfg', 'state', 'home')]
    for d in (cfg + '/ned', state, home): os.makedirs(d, exist_ok=True)
    conf = {'security.folderTrust': 'off', 'ai.provider': 'openai', 'ai.apiKey': 'sk-test', 'ai.model': 'gpt-6',
            'ai.baseUrl': 'http://127.0.0.1:%d/v1' % AI_PORT, 'ui.cursorAnimation': 'off', 'files.hotExit': False,
            'terminal.keepRunning': False, 'nim.nimsuggest': False}
    if PLUGINS: conf.update({'plugins.bundled': bundled_names(), 'plugins.native': 'off'})
    json.dump(conf, open(cfg + '/ned/config.json', 'w'))
    def tm(*a): return subprocess.run(['tmux', '-L', sock] + list(a), capture_output=True, text=True)
    def screen(): return tm('capture-pane', '-t', 's', '-p').stdout
    env = ('HOME=%s XDG_CONFIG_HOME=%s XDG_STATE_HOME=%s XDG_CACHE_HOME=%s/cache TMPDIR=%s TERM=xterm-256color '
           'COLORTERM=truecolor NED_SOCKET= PATH=%s' % (home, cfg, state, work, work, os.environ['PATH']))
    tm('kill-server')
    tm('-f', os.path.join(REPO, 'tests', 'ui', 'tmux.conf'), 'new-session', '-d', '-s', 's', '-x', '130', '-y', '36',
       'cd %s/proj && env %s %s src/demo.nim; echo NED-EXITED $?; sleep 600' % (work, env, NED))
    end = time.time() + 20
    while time.time() < end and not re.search(r'Ln \d+, Col', screen()): time.sleep(0.2)
    time.sleep(0.5)
    tm('send-keys', '-t', 's', 'Escape')
    tm('send-keys', '-t', 's', 'C-g'); tm('send-keys', '-t', 's', '-l', '4:8'); tm('send-keys', '-t', 's', 'Enter')
    time.sleep(0.3)
    if name == '(start)':
        return start_check(tm, screen, state, work)
    if MENUS:
        # the menu item, by the keys: F10 opens the bar's first menu, Right the next ones, Down steps over what cannot
        # be chosen, Right opens a submenu
        bar, picks, _ = MENU_PATHS[name]
        tm('send-keys', '-t', 's', 'F10'); time.sleep(0.4)
        for _ in range(bar): tm('send-keys', '-t', 's', 'Right'); time.sleep(0.15)
        for depth, k in enumerate(picks):
            for _ in range(k): tm('send-keys', '-t', 's', 'Down'); time.sleep(0.05)
            if depth < len(picks) - 1:
                tm('send-keys', '-t', 's', 'Right'); time.sleep(0.3)
        shown = screen()
    end = time.time() + (60 if PLUGINS else 0)
    while not MENUS:
        tm('send-keys', '-t', 's', 'C-p'); time.sleep(0.25)
        tm('send-keys', '-t', 's', '-l', '>' + name); time.sleep(0.5)
        shown = screen()
        if not PLUGINS or name[:40] in shown or time.time() > end: break
        tm('send-keys', '-t', 's', 'Escape'); time.sleep(1.0)
    if PLUGINS and name[:40] not in shown:
        tm('kill-server')
        with lock:
            results.append((name, 'NOT REGISTERED', shown[-1500:]))
            print('NOT REGISTERED  %s\n%s' % (name, '\n'.join('      ' + l for l in shown.splitlines()[-20:])), flush=True)
        return
    tm('send-keys', '-t', 's', 'Enter'); time.sleep(2.0)
    after = screen()
    for _ in range(3):
        tm('send-keys', '-t', 's', 'Escape'); time.sleep(0.2)
    s = screen()
    verdict, detail = 'ok', ''
    errlog = os.path.join(state, 'ned', 'errors.log')
    if 'NED-EXITED' in s:
        code = re.search(r'NED-EXITED (\d+)', s)
        what = name + ' ' + (MENU_PATHS[name][2] if MENUS else '')
        if re.search(r'\bQuit\b|quit|Restart|restart|Close the window|Exit', what) and code and code.group(1) == '0':
            verdict = 'quit'
        else:
            verdict, detail = 'EXITED', s[-1500:]
    elif 'Internal error' in after or 'Internal error' in s or (os.path.exists(errlog) and os.path.getsize(errlog) > 0):
        verdict = 'INTERNAL ERROR'
        detail = (open(errlog).read()[-1500:] if os.path.exists(errlog) else '') + '\n' + after[-1500:]
    else:
        # still answering: the palette opens and shows what is typed
        tm('send-keys', '-t', 's', 'C-p'); time.sleep(0.2)
        tm('send-keys', '-t', 's', '-l', 'zqzqprobe')
        end = time.time() + 10
        alive = False
        while time.time() < end:
            if 'zqzqprobe' in screen():
                alive = True
                break
            time.sleep(0.25)
        if not alive:
            # (a dialog or a prompt of the command's own may hold the keys: Esc, and once more)
            for _ in range(4):
                tm('send-keys', '-t', 's', 'Escape'); time.sleep(0.2)
            tm('send-keys', '-t', 's', 'C-p'); time.sleep(0.3)
            tm('send-keys', '-t', 's', '-l', 'zqzqprobe'); time.sleep(1.5)
            alive = 'zqzqprobe' in screen()
        if not alive: verdict, detail = 'NOT ANSWERING', screen()[-1500:]
    if not MENUS and not PLUGINS and '▍' + name[:20] not in shown and verdict == 'ok':   # (the palette's first row: the one run)
        detail = '(the palette may have picked another command)'
    if MENUS and verdict == 'ok' and name.split(' › ')[-1][:24] not in shown:
        detail = '(the menu item was not on the screen when picked)'
    tm('kill-server')
    if not KEEP: shutil.rmtree(work, ignore_errors=True)
    with lock:
        results.append((name, verdict, detail))
        bad = verdict not in ('ok', 'quit')
        print(('%-15s %s' % (verdict, name)) + (('\n' + '\n'.join('      ' + l for l in detail.splitlines()[-25:])) if bad else
                                                (' ' + detail if detail.startswith('(') else '')), flush=True)

def start_check(tm, screen, state, work):
    # every plugin on: give them a minute, then the Plugins panel must show none failed, and no internal error
    time.sleep(45)
    tm('resize-window', '-t', 's', '-x', '260', '-y', '70'); time.sleep(0.5)
    tm('send-keys', '-t', 's', 'Escape'); tm('send-keys', '-t', 's', 'C-p'); time.sleep(0.3)
    tm('send-keys', '-t', 's', '-l', '>Plugins panel'); time.sleep(0.6); tm('send-keys', '-t', 's', 'Enter')
    time.sleep(2)
    s = screen()
    errlog = os.path.join(state, 'ned', 'errors.log')
    errs = open(errlog).read() if os.path.exists(errlog) else ''
    failed = re.findall(r'failed:.*|has an error.*|could not start.*|left out:.*', s)
    verdict = 'ok' if not failed and not errs and 'NED-EXITED' not in s else 'PLUGINS FAILED'
    tm('kill-server')
    with lock:
        results.append(('(every plugin on, together)', verdict, errs + '\n'.join(failed) + s[-3000:]))
        print('%-15s every plugin on, together' % verdict + ('' if verdict == 'ok' else '\n' + errs + s[-3000:]), flush=True)

def menu_items():
    # (--menus) every item the menu bar's menus hold, from a ned in the demo project that writes them down
    dump = os.path.join(ROOT, 'menus.json')
    sock = 'ned-menus-%d' % os.getpid()
    work = os.path.join(ROOT, 'wm')
    shutil.copytree(TEMPLATE, os.path.join(work, 'proj'), symlinks=True)
    cfg, state, home = [os.path.join(work, x) for x in ('cfg', 'state', 'home')]
    for d in (cfg + '/ned', state, home): os.makedirs(d, exist_ok=True)
    json.dump({'security.folderTrust': 'off', 'ai.provider': 'openai', 'ai.apiKey': 'sk-test', 'ai.model': 'gpt-6',
               'ai.baseUrl': 'http://127.0.0.1:%d/v1' % AI_PORT, 'ui.cursorAnimation': 'off', 'files.hotExit': False,
               'terminal.keepRunning': False, 'nim.nimsuggest': False}, open(cfg + '/ned/config.json', 'w'))
    env = ('HOME=%s XDG_CONFIG_HOME=%s XDG_STATE_HOME=%s XDG_CACHE_HOME=%s/cache TMPDIR=%s TERM=xterm-256color '
           'COLORTERM=truecolor NED_SOCKET= NED_MENU_DUMP=%s PATH=%s' % (home, cfg, state, work, work, dump,
                                                                        os.environ['PATH']))
    tm = lambda *a: subprocess.run(['tmux', '-L', sock] + list(a), capture_output=True, text=True)
    tm('-f', os.path.join(REPO, 'tests', 'ui', 'tmux.conf'), 'new-session', '-d', '-s', 's', '-x', '130', '-y', '36',
       'cd %s/proj && env %s %s src/demo.nim; sleep 600' % (work, env, NED))
    end = time.time() + 20
    while time.time() < end and not os.path.exists(dump): time.sleep(0.2)
    time.sleep(0.5)
    tm('kill-server')
    if not os.path.exists(dump): sys.exit('ned wrote no menus (NED_MENU_DUMP)')
    names = []
    def walk(items, bar, path, picks):
        for it in items:
            if it.get('disabled') or 'pick' not in it: continue
            label = path + ' › ' + it['label']
            if it.get('sub'): walk(it['sub'], bar, label, picks + [it['pick']])
            elif it.get('act'):
                MENU_PATHS[label] = (bar, picks + [it['pick']], it.get('cmd', ''))
                names.append(label)
    for m in json.load(open(dump)): walk(m['items'], m['menu'], m['name'], [])
    return names

def skipped(n):
    # the reason a command or a menu item is not run, '' none (a menu item: the command it runs)
    if n in SKIP: return SKIP[n]
    if MENUS and MENU_PATHS[n][2] in SKIP: return SKIP[MENU_PATHS[n][2]]
    return ''

names = [n for n in (plugin_commands() if PLUGINS else menu_items() if MENUS else command_names())
         if ONLY.lower() in n.lower()]
if PLUGINS: names = ['(start)'] + names
todo = [n for n in names if not skipped(n)]
for n in names:
    if skipped(n): print('SKIP            %s  (%s)' % (n, skipped(n)))
t0 = time.time()
slots = list(range(JOBS))
free = list(slots)
slot_lock = threading.Lock()
def job(name):
    with slot_lock: s = free.pop()
    try: run_one(s, name)
    finally:
        with slot_lock: free.append(s)
try:
    with ThreadPoolExecutor(max_workers=JOBS) as ex:
        list(ex.map(job, todo))
finally:
    mock.terminate()
bad = [r for r in results if r[1] not in ('ok', 'quit')]
print('\n%d %s run, %d skipped, %d broke something, in %d min' % (len(results), 'menu items' if MENUS else 'commands',
                                                                 len(names) - len(todo), len(bad),
                                                                       (time.time() - t0) / 60))
for n, v, _ in bad: print('  %-15s %s' % (v, n))
if not KEEP: shutil.rmtree(ROOT, ignore_errors=True)
sys.exit(1 if bad else 0)
