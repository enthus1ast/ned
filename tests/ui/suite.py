"""ned's UI tests: every feature driven through tmux, the screen read back. Run them with run.py."""
import shlex, subprocess, time, os, shutil, json, sys, re
# the helpers live in this module's namespace (a test can point W elsewhere for a while)
exec(compile(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'harness.py')).read(), 'harness.py', 'exec'))

# ── tests ──
def t_edit_save_undo():
    setup(); start('src/demo/utils.nim')
    mode0 = os.stat(os.path.join(W, 'src/demo/utils.nim')).st_mode & 0o777
    keys('C-End'); keys('Enter'); text('proc thrice*(x: int): int = x * 3'); keys('C-s'); time.sleep(0.5)
    check('save writes the file', 'thrice' in ftext('src/demo/utils.nim'), ftext('src/demo/utils.nim'))
    for _ in range(25): keys('C-z')
    keys('C-s'); time.sleep(0.5)
    check('undo + save removes it', 'thrice' not in ftext('src/demo/utils.nim'))
    for _ in range(25): keys('C-y')
    keys('C-s'); time.sleep(0.5)
    check('redo restores', 'thrice' in ftext('src/demo/utils.nim'))
    st = os.stat(os.path.join(W, 'src/demo/utils.nim'))
    check('mode kept (%s)' % oct(mode0), st.st_mode & 0o777 == mode0, oct(st.st_mode))

def t_find_replace():
    setup(); start('src/demo.nim')
    keys('C-r'); text('greet'); keys('Enter'); time.sleep(0.3); text('hello'); keys('Enter'); time.sleep(0.4)
    keys('a'); time.sleep(0.4); keys('C-s'); time.sleep(0.5)
    t = ftext('src/demo.nim')
    check('replace all', 'greet' not in t and t.count('hello') >= 2, t)

def t_multicursor():
    setup(); start('src/demo/utils.nim')
    keys('C-g'); text('3:6'); keys('Enter')       # on "shout"
    keys('M-a'); time.sleep(0.2); text('yell'); keys('C-s'); time.sleep(0.5)
    t = ftext('src/demo/utils.nim')
    check('select all occurrences + type', 'yell*' in t and 'shout' not in t, t)

def t_project_search():
    setup(); start('src/demo.nim')
    keys('M-s'); time.sleep(0.3); keys('C-u'); text('toUpperAscii'); keys('Enter')
    check('project search finds match', wait_for(r'utils\.nim', 6), screen())

def t_terminal():
    setup({"terminal.shell": "/bin/bash"}); start('src/demo.nim')
    keys('C-\\'); time.sleep(1.2); text('echo ned-$((40+2))'); keys('Enter')
    check('terminal runs a command', wait_for('ned-42', 5), screen())
    keys('C-d')

def t_run_file():
    setup(); start('src/demo.nim')
    keys('M-r')
    check('run current file shows output', wait_for('Hello, Ann!', 60), screen())

def t_lsp():
    need('nimlangserver')
    setup({"nim.ide": "nimlangserver"}); start('src/demo.nim')
    ok = wait_for('nimlangserver', 10)
    keys('C-g'); text('10:9'); keys('Enter'); time.sleep(4)
    check('hover from nimlangserver', 'utils.shout' in screen(), screen())
    keys('Escape'); keys('F12'); time.sleep(3)
    check('go to definition across modules', re.search(r'utils\.nim', screen().split('\n')[2] if len(screen().split('\n')) > 2 else ''), screen()[:600])

def t_lsp_diag():
    need('nimlangserver')
    setup({"nim.ide": "nimlangserver"}); start('src/demo/utils.nim')
    wait_for('nimlangserver', 10)
    keys('C-End'); keys('Enter'); text('let bad: int = "s"'); time.sleep(6)
    check('live diagnostics', re.search(r'type mismatch|cannot be converted|but expected', screen()), screen())

def t_ai_chat():
    setup({"ai.model": "o4-mini-2025-04-16"}); start('src/demo.nim')
    keys('M-c'); text('Explain this file'); keys('Enter')
    check('AI chat answers (OpenAI reasoning model)', wait_for('package entry point', 8), screen())

def click(x, y):
    tm('send-keys', '-t', 'f', '-l', '\x1b[<0;%d;%dM' % (x, y)); time.sleep(0.05)
    tm('send-keys', '-t', 'f', '-l', '\x1b[<0;%d;%dm' % (x, y)); time.sleep(0.3)

def find_on_screen(word):
    for i, l in enumerate(screen().split('\n')):
        k = l.find(word)
        if k >= 0: return (k + 2, i + 1)
    return None

def status_pos():
    m = re.search(r'Ln (\d+), Col (\d+)', screen())
    return (int(m.group(1)), int(m.group(2))) if m else None

# ── ned 5: the built-in Nim engine ──
def t_engine_member_completion():
    setup(); start('src/demo.nim')
    keys('C-g'); text('9'); keys('Enter'); keys('End'); keys('Enter'); text('echo p.')
    ok = wait_for(r'name\s+string', 3) and re.search(r'age\s+Natural', screen())
    check('engine: member completion knows Person (nimble project, other module)', ok, screen())
    check('engine: documentation beside the list', re.search(r'demo/types|types\.nim:\d', screen()), screen())
    keys('C-space'); time.sleep(0.4)
    check('engine: Ctrl+Space hides the docs while the list is open', not re.search(r'types\.nim:\d', screen()), screen())
    keys('C-space'); time.sleep(0.3)
    keys('Escape'); keys('BSpace', 'BSpace'); text('"x".addEsc')
    check('engine: string procs after a literal', wait_for('addEscapedChar', 3), screen())

def t_engine_hover_def_sig():
    setup(); start('src/demo.nim')
    keys('C-g'); text('10:9'); keys('Enter'); keys('M-h')
    check('engine: hover shows the signature', wait_for(r'proc shout\(s: string\): string', 3), screen())
    keys('Escape'); keys('M-.')
    check('engine: go to definition in another module', wait_for(r'utils\.nim', 3) and status_pos() and status_pos()[0] == 3, screen()[:400])
    keys('M-,'); time.sleep(0.3)
    keys('C-g'); text('10'); keys('Enter'); keys('End'); keys('Enter'); text('echo greet(')
    check('engine: signature help', wait_for(r'greet\(who: string\): string', 3), screen())

def t_engine_refs_rename():
    setup(); start('src/demo.nim')
    keys('C-g'); text('4:6'); keys('Enter'); keys('M-q')
    check('engine: references across the project', wait_for(r'REFERENCES greet · 4', 4), screen())
    keys('Escape'); keys('F6'); keys('Escape'); time.sleep(0.2)
    keys('C-g'); text('4:6'); keys('Enter'); keys('F2'); time.sleep(0.3)
    keys('C-u'); text('salute'); keys('Enter'); time.sleep(0.6)
    check('rename shows a preview first', 'Rename greet → salute' in screen(), screen()[:800])
    keys('Enter'); time.sleep(0.6)
    palette('Save all'); time.sleep(0.6)
    t = ftext('src/demo.nim') + ftext('tests/test_demo.nim') + ftext('examples/ex1.nim')
    check('engine: rename in every file (not inside strings)', 'greet(' not in t and t.count('salute') == 4 and 'test "greet"' in t, t)

def t_engine_imports():
    setup(); start('src/demo.nim')
    keys('C-g'); text('2'); keys('Enter'); keys('End'); keys('Enter'); text('import std/strut')
    check('engine: module names after import', wait_for('strutils', 3), screen())

def t_engine_without_nimsuggest():
    setup({"nim.nimsuggest": False}); start('src/demo.nim')
    keys('C-g'); text('9'); keys('Enter'); keys('End'); keys('Enter'); text('echo p.na')
    check('engine works without nimsuggest', wait_for(r'name\s+string', 3), screen())
    ps = sh('pgrep -af nimsuggest').stdout
    check('no nimsuggest started when turned off', W not in ps, ps)

def t_engine_outline_symbols():
    setup(); start('src/demo.nim')
    keys('C-t'); text('gre'); time.sleep(0.4)
    check('engine: symbols in file', 'greet' in screen(), screen())
    keys('Escape'); keys('C-p'); text('#Pers'); time.sleep(0.8)
    check('engine: project symbols', re.search(r'Person.*types\.nim', screen()), screen())

def t_format_keeps_cursor():
    setup(); start('src/demo/utils.nim')
    keys('C-End'); keys('Enter')
    for i in range(30): text('proc f%d(a:int,b:int):int=a+b\n' % i); 
    keys('C-g'); text('20:12'); keys('Enter'); time.sleep(0.2)
    before = status_pos()
    row = lambda n: [l for l in screen().split('\n') if re.match(r'^\s*%d\D' % n, l)]
    m = re.search(r'proc (f\d+)\(', (row(before[0]) or [''])[0]) if before else None
    keys('M-f'); time.sleep(1.5)
    after = status_pos()
    r = row(after[0]) if after else []
    on_code = m is not None and bool(r) and ('proc %s(a: int' % m.group(1)) in r[0]
    check('format keeps the cursor on its code (the line moved)', on_code, str(before) + ' ' + str(after) + ' ' + str(r[:1]))
    check('format keeps the cursor on the same character', after and after[1] == 12, str(after))

def t_zen_vim():
    setup({"editor.vimMode": True}); start('src/demo.nim')
    keys('M-z'); time.sleep(0.3); keys('i'); text('x'); keys('Escape'); time.sleep(0.1); keys('Escape'); time.sleep(0.4)
    check('vim + zen: Esc Esc stays in zen', 'File' not in screen().split('\n')[0] and 'NORMAL' in screen(), screen()[:300])
    text(':zen'); keys('Enter'); time.sleep(0.4)
    check('vim + zen: :zen leaves', 'File' in screen().split('\n')[0], screen()[:200])

def t_ai_insert():
    setup({"ai.model": "gpt-4.1"}); start('src/demo.nim')
    keys('C-g'); text('9:3'); keys('Enter')
    keys('M-c'); text('Write a proc'); keys('Enter')
    wait_for('Insert', 6); time.sleep(0.3)
    p = find_on_screen('Insert')
    if p: click(*p)
    time.sleep(0.5); keys('C-s'); time.sleep(0.5)
    t = ftext('src/demo.nim')
    ok = t.rstrip().endswith('proc triple*(x: int): int =\n  ## three times x\n  x * 3') and '\n\nproc triple' in t
    check('AI insert: a proc goes after the block, spaced', ok, t)
    keys('C-z'); keys('C-s'); time.sleep(0.4)
    check('AI insert: one undo step', 'triple' not in ftext('src/demo.nim'), ftext('src/demo.nim'))

def t_split_zen_theme():
    setup(); start('src/demo.nim', 'src/demo/utils.nim')
    keys('M-\\'); time.sleep(0.5)
    s = screen()
    check('split editor shows two panes', s.count('│') > 30, s[:300])
    keys('M-z'); time.sleep(0.5); keys('Escape'); keys('Escape'); time.sleep(0.4)
    check('zen mode toggles back', 'File' in screen().split('\n')[0], screen()[:200])

def t_vim():
    setup({"editor.vimMode": True}); start('src/demo/utils.nim')
    keys('g'); keys('g'); keys('d'); keys('d'); text(':w'); keys('Enter'); time.sleep(0.6)
    t = ftext('src/demo/utils.nim')
    check('vim dd + :w', not t.startswith('import std/strutils'), t[:80])

def t_recovery():
    setup(); start('src/demo.nim')
    keys('C-End'); text('# unsaved-marker'); time.sleep(2.5)
    r = sh("pgrep -f '^%s src/demo.nim'" % BIN).stdout.split()
    for pid in r: os.kill(int(pid), 9)
    time.sleep(0.5)
    tm('kill-server'); time.sleep(0.3)
    start('src/demo.nim')
    check('recovery offered after kill -9', wait_for('unsaved edits|Restore|Recover', 6), screen())

def t_quit_dirty():
    setup(); start('src/demo.nim')
    text('x'); keys('C-q')
    check('quit asks about unsaved', wait_for('[Uu]nsaved|Save|Discard', 4), screen())

def t_bench():
    r = sh(('%s --bench ' + big_file() + ' 2>&1 | tail -3') % BIN)
    check('bench runs', r.returncode == 0, r.stdout + r.stderr)

def t_mixed_folder():
    need('nimlangserver')
    setup({"nim.ide": "nimlangserver"})
    global W
    saved = W
    W = TMP + '/home'
    shutil.rmtree(W, ignore_errors=True); os.makedirs(W)
    shutil.copy(FIX + '/mac/m.nim', W + '/m.nim')
    shutil.copytree(demo_template(), W + '/proj1')
    shutil.rmtree(W + '/proj1/.git', ignore_errors=True)
    start('m.nim')
    wait_for('nimlangserver', 10); time.sleep(3)
    keys('C-p'); text('proj1/src/demo.nim'); time.sleep(0.6); keys('Enter'); time.sleep(7)
    keys('C-g'); text('10:9'); keys('Enter'); time.sleep(4)
    check('package file in a mixed folder gets its own nimsuggest (hover)', 'utils.shout' in screen(), screen())
    ps = sh('pgrep -af "nimsuggest .*(m.nim|proj1/src/demo.nim)"').stdout
    check('two nimsuggests: loose + package', 'm.nim' in ps and 'proj1/src/demo.nim' in ps, ps)
    W = saved

def t_builtin_nimsuggest():
    setup({"nim.ide": "nimsuggest"}); start('src/demo.nim')
    time.sleep(4)
    keys('C-g'); text('10:9'); keys('Enter'); time.sleep(5)
    check('built-in nimsuggest client hover', 'shout' in screen() and ('proc' in screen()), screen())

def t_server_crash_restart():
    need('nimlangserver')
    setup({"nim.ide": "nimlangserver"}); start('src/demo.nim')
    wait_for('nimlangserver', 10); time.sleep(3)
    def nls(): return [p for p in sh("pgrep -x nimlangserver").stdout.split()]
    pids = nls()
    for p in pids: os.kill(int(p), 9)
    seen = False
    for _ in range(25):
        if re.search('exited', screen()): seen = True; break
        time.sleep(0.1)
    check('crash is reported', seen, screen()[-300:])
    time.sleep(4)
    pids2 = nls()
    check('server restarted', len(pids2) > 0 and set(pids2) != set(pids), str(pids) + ' ' + str(pids2))
    kills = 0
    for _ in range(12):
        ps = nls()
        if ps:
            for p in ps: os.kill(int(p), 9)
            kills += 1
            if kills >= 3: break
        time.sleep(0.5)
    time.sleep(1.5)
    palette('Nim: language server status'); time.sleep(1)
    check('falls back to the built-in engine after repeated crashes', "built-in Nim index" in screen(), screen()[:900])
    keys('C-w'); time.sleep(0.5); keys('C-g'); text('10:9'); keys('Enter'); time.sleep(5)
    check('built-in client answers after the fallback', 'shout' in screen() and 'proc' in screen(), screen()[:900])

MESSY = 'proc   g(a:int,b :int):int=\n    a+b\nlet x=[1,2,\n  3]\n'

def t_format_builtin():
    setup()
    open(W + '/src/messy.nim', 'w').write(MESSY)
    start('src/messy.nim')
    keys('M-f'); seen = wait_for(r'Formatted \(built-in', 4)
    keys('C-s'); time.sleep(0.5)
    t = ftext('src/messy.nim')
    check('built-in formatter: says it formatted', seen, screen()[-400:])
    check('built-in formatter: nph style', t == 'proc g(a: int, b: int): int =\n  a + b\n\nlet x = [1, 2, 3]\n', repr(t))
    keys('M-f'); check('built-in formatter: idempotent', wait_for('Already formatted', 3), screen()[-300:])

def t_format_choice():
    setup({"nim.formatter": "nph"})
    open(W + '/src/messy.nim', 'w').write(MESSY)
    start('src/messy.nim')
    keys('M-f')
    check('nph chosen but not installed: says so', wait_for('nph is not installed', 3), screen()[-400:])
    palette('Nim: format with nimpretty'); time.sleep(0.6)
    c = open(CFG + '/ned/config.json').read()
    check('formatter choice is saved', '"nim.formatter": "nimpretty"' in c, c[-300:])
    keys('M-f'); time.sleep(2); keys('C-s'); time.sleep(0.5)
    t = ftext('src/messy.nim')
    check('nimpretty formats when chosen', t.startswith('proc g(a: int, b: int): int =\n    a+b'), repr(t))
    palette("Nim: format with ned's built-in formatter"); time.sleep(0.6)
    keys('M-f'); time.sleep(1); keys('C-s'); time.sleep(0.5)
    check('back to the built-in formatter', ftext('src/messy.nim').startswith('proc g(a: int, b: int): int =\n  a + b'),
          repr(ftext('src/messy.nim')))

def t_reset_settings():
    setup({"theme": "dracula", "editor.tabSize": 8})
    for f in os.listdir(CFG + '/ned'):
        if f.startswith('config.json.bak-'): os.remove(CFG + '/ned/' + f)
    start('src/demo.nim')
    palette('Settings: reset to defaults'); time.sleep(0.4)
    check('reset asks first', 'Reset ALL settings' in screen(), screen()[-400:])
    keys('y'); time.sleep(0.8)
    c = open(CFG + '/ned/config.json').read()
    baks = [f for f in os.listdir(CFG + '/ned') if f.startswith('config.json.bak-')]
    check('reset writes the defaults (nim-crown theme)', '"theme": "nim-crown"' in c and '"theme": "dracula"' not in c, c[:300])
    check('reset keeps a backup', len(baks) == 1 and 'dracula' in open(CFG + '/ned/' + baks[0]).read(), str(baks))
    check('reset says so', 'Settings reset to defaults' in screen(), screen()[-300:])
    r = sh(BIN + ' --default-settings')
    check('default theme is nim-crown', '"theme": "nim-crown"' in r.stdout, r.stdout[:200])


# ── ned 5.2 ──
def press(x, y): tm('send-keys', '-t', 'f', '-l', '\x1b[<0;%d;%dM' % (x, y)); time.sleep(0.08)
def drag(x, y): tm('send-keys', '-t', 'f', '-l', '\x1b[<32;%d;%dM' % (x, y)); time.sleep(0.08)
def release(x, y): tm('send-keys', '-t', 'f', '-l', '\x1b[<0;%d;%dm' % (x, y)); time.sleep(0.3)

def t_52_refactors():
    setup()
    open(W + '/src/r.nim', 'w').write('import strutils\nimport os, ./demo\nimport std/tables\n\nproc twice(x: int): int =\n  x * 2\n')
    start('src/r.nim')
    palette('Nim: sort imports'); time.sleep(0.3)
    keys('C-End'); time.sleep(0.2)
    palette('Nim: toggle proc'); time.sleep(0.3)
    keys('C-s'); time.sleep(0.5)
    t = ftext('src/r.nim')
    check('sort imports: std first, then local', t.startswith('import std/[os, strutils, tables]\nimport ./demo\n'), repr(t))
    check('toggle proc -> func', 'func twice(x: int): int =' in t, repr(t))

def t_52_format_selection():
    setup()
    open(W + '/src/s.nim', 'w').write('proc a() =\n  let x=[1,2,\n    3]\n  echo  x\n')
    start('src/s.nim')
    keys('Down', 'S-Down', 'S-Down', 'M-f'); time.sleep(0.4)
    keys('Escape', 'C-s'); time.sleep(0.5)
    t = ftext('src/s.nim')
    check('format selection: only the selected lines', t == 'proc a() =\n  let x = [1, 2, 3]\n  echo  x\n', repr(t))

def t_52_conflict():
    setup()
    open(W + '/src/c.nim', 'w').write('let a = 1\n<<<<<<< HEAD\nlet b = 2\n=======\nlet b = 3\n>>>>>>> other\necho a\n')
    start('src/c.nim')
    check('conflict: accept buttons shown', 'Accept ours' in screen(), screen()[:600])
    palette('Git: next merge conflict'); time.sleep(0.3)
    palette('Git: accept theirs'); time.sleep(0.3)
    keys('C-s'); time.sleep(0.5)
    t = ftext('src/c.nim')
    check('conflict: theirs kept', t == 'let a = 1\nlet b = 3\necho a\n', repr(t))

def t_52_settings_search():
    setup()
    start('src/demo.nim')
    palette('Settings'); time.sleep(0.4)
    text('nph formatter'); time.sleep(0.5)
    s = screen()
    check('settings: found by words of the description', re.search(r'(?i)formatter', s.split('\n', 3)[-1] if s else '') is not None and 'nimpretty' in s.lower() or 'builtin' in s, s[:900])
    keys('Escape')

def t_52_mouse():
    setup()
    open(W + '/src/a1.nim', 'w').write('echo "one"\n' * 5)
    open(W + '/src/b2.nim', 'w').write('echo "two"\n' * 5)
    start('src/a1.nim', 'src/b2.nim')
    pa, pb = find_on_screen('a1.nim'), find_on_screen('b2.nim')
    check('tabs: both shown', pa and pb and pa[0] < pb[0], screen()[:300])
    if pa and pb:
        press(pb[0], pb[1]); drag(pb[0] - 3, pb[1]); drag(pa[0], pa[1]); release(pa[0], pa[1]); time.sleep(0.3)
        qa, qb = find_on_screen('a1.nim'), find_on_screen('b2.nim')
        check('tabs: drag reorders', qa and qb and qb[0] < qa[0], screen()[:300])
    # press and hold = context menu
    p = find_on_screen('"two"') or find_on_screen('"one"')
    press(p[0], p[1]); time.sleep(0.7); release(p[0], p[1]); time.sleep(0.3)
    check('long press opens the context menu', re.search(r'Copy|Paste', screen()) is not None, screen()[-900:])
    keys('Escape')
    # split divider drag
    palette('View: split editor right'); time.sleep(0.5)
    rows = screen().split('\n')
    def divcol():
        r = screen().split('\n')[10]
        return [i for i, ch in enumerate(r) if ch in '│┃▕▏|']
    before = divcol()
    if before:
        c = before[-1] + 1
        press(c, 11); drag(c - 10, 11); drag(c - 20, 11); release(c - 20, 11); time.sleep(0.3)
        after = divcol()
        check('split divider drag moves it', after and after[-1] < before[-1] - 10, str(before) + ' ' + str(after))
    else:
        check('split divider found', False, screen()[:800])

# ── ned 5.2.1 ──
DBG = 'proc main() =\n  var total = 0\n  for i in 1 .. 5:\n    let sq = i * i\n    total += sq\n    total -= sq - i\n  echo total\n\nmain()\n'

def t_521_debugger():
    setup()
    open(W + '/src/dbg.nim', 'w').write(DBG)
    start('src/dbg.nim', w=110, h=36)
    keys('C-g'); text('5'); keys('Enter')
    palette('Debug: conditional breakpoint'); text('i == 3'); keys('Enter'); time.sleep(0.3)
    check('conditional breakpoint marked ◆', '◆' in screen(), screen()[:900])
    keys('F5')
    ok = wait_for(r'stopped \(breakpoint hit\) at dbg\.nim:5', 60)
    wait_for('sq: int = 9', 15)                       # the variables come a moment after the stop
    s = screen()
    check('debugger stops at the breakpoint', ok, s[-1500:])
    check('condition respected (i == 3)', 'i: int = 3' in s, s[-1500:])
    check('C names hidden, Nim types shown', 'T1_' not in s and 'sq: int = 9' in s, s[-1500:])
    keys('Home'); keys('M-h'); time.sleep(0.5)
    check('hover shows the value while stopped', re.search(r'total: int = 3', screen()) is not None, screen()[:1500])
    keys('Escape', 'S-F5'); time.sleep(0.5)
    keys('F9'); time.sleep(0.2)                       # remove it, then run to cursor
    keys('C-g'); text('7'); keys('Enter'); keys('C-F10')
    ok = wait_for(r'stopped .*at dbg\.nim:7', 60) and wait_for('total: int = 15', 15)   # the variables come a moment later
    check('run to cursor', ok, screen()[-1200:])
    keys('S-F5'); time.sleep(0.5)
    keys('C-g'); text('5'); keys('Enter', 'F9'); time.sleep(0.2)
    keys('C-q'); time.sleep(1)
    tm('kill-server'); time.sleep(0.3)
    start('src/dbg.nim', w=110, h=36)
    rows = [l for l in screen().split('\n') if '●' in l and 'total += sq' in l]
    check('breakpoints come back with the session', len(rows) == 1, screen()[:900])

def t_521_touchbar():
    setup({"ui.touchBarKeys": ["esc", "Run=Run file", "ctrl+p"]})
    start('src/demo.nim')
    check('touch bar is off by default', 'ctrl+p' not in screen(), screen()[-300:])
    palette('Toggle touch bar'); time.sleep(0.5)
    line = [l for l in screen().split('\n') if 'ctrl+p' in l]
    check('touch bar toggles on, with the chosen keys', line and 'Esc' in line[0] and 'Run' in line[0], screen()[-500:])
    c = open(CFG + '/ned/config.json').read()
    check('touch bar choice saved', '"ui.touchBar": "on"' in c, c[-300:])
    palette('Toggle touch bar'); time.sleep(0.5)
    check('touch bar toggles off', 'ctrl+p' not in screen(), screen()[-300:])

def t_521_bp_follow_edits():
    setup()
    open(W + '/src/dbg.nim', 'w').write(DBG)
    start('src/dbg.nim', w=110, h=36)
    keys('C-g'); text('5'); keys('Enter', 'F9', 'C-Home', 'Enter', 'Enter'); time.sleep(0.3)
    rows = [l for l in screen().split('\n') if l.startswith('●')]
    check('breakpoint follows inserted lines', len(rows) == 1 and 'total += sq' in rows[0] and ' 7 ' in rows[0], str(rows))

# ── ned 5.2.2 ──
def mouse(code, x, y, up=False):
    tm('send-keys', '-t', 'f', '-l', '\x1b[<%d;%d;%d%s' % (code, x, y, 'm' if up else 'M')); time.sleep(0.12)

def t_522_navigation():
    setup()
    open(W + '/src/box.nim', 'w').write('aaaa\nbbbb\ncccc\n')
    start('src/demo.nim', 'src/box.nim')
    # box selection with Alt+drag
    p = find_on_screen('aaaa')
    mouse(8, p[0], p[1]); mouse(40, p[0] + 1, p[1] + 1); mouse(40, p[0] + 2, p[1] + 2); mouse(8, p[0] + 2, p[1] + 2, up=True)
    text('Z'); keys('Escape', 'C-s'); time.sleep(0.4)
    t = ftext('src/box.nim')
    check('Alt+drag box selection', t == 'aZa\nbZb\ncZc\n', repr(t))
    # go back / forward
    keys('Escape', 'C-Home'); time.sleep(0.2)
    keys('C-g'); text('3'); keys('Enter'); time.sleep(0.2)
    keys('M-,'); time.sleep(0.3)
    a = status_pos()
    keys('M-<'); time.sleep(0.3)
    b = status_pos()
    check('jump back then go forward', a and b and a[0] == 1 and b[0] == 3, str((a, b)))
    # reopen closed tab
    keys('C-w'); time.sleep(0.3)
    gone = 'box.nim' not in screen().split('\n')[1]
    keys('M-T'); time.sleep(0.5)
    check('reopen closed tab', gone and 'box.nim' in screen().split('\n')[1], screen()[:300])

def t_522_peek_hierarchy_stage():
    setup()
    start('src/demo.nim')
    keys('C-g'); text('9:9'); keys('Enter'); time.sleep(0.2)
    keys('M-F12'); time.sleep(0.6)
    s = screen()
    check('peek definition popup', 'demo.nim:4' in s and 'proc greet' in s, s[:1500])
    keys('Escape')
    keys('C-g'); text('4:7'); keys('Enter'); time.sleep(0.2)
    palette('Call hierarchy'); time.sleep(0.8)
    check('call hierarchy lists callers', '←' in screen(), screen()[:1500])
    keys('Escape')
    keys('C-g'); text('5'); keys('Enter', 'End'); text('  # changed'); keys('C-s'); time.sleep(1.5)
    palette('Git: stage this change'); time.sleep(1.5)
    d = sh('cd %s && git diff --cached' % W).stdout
    check('stage one change from the editor', '# changed' in d, d[:500] + screen()[-300:])

def t_522_rename_imports():
    setup()
    open(W + '/src/demo/extra.nim', 'w').write('proc ex*(): int = 1\n')
    open(W + '/src/usex.nim', 'w').write('import demo/extra\necho ex()\n')
    start('src/demo/extra.nim')
    palette('File: rename or move this file'); time.sleep(0.3)
    for _ in range(30): keys('BSpace')
    text('src/demo/extra2.nim'); keys('Enter'); time.sleep(0.8)
    keys('y'); time.sleep(0.6)
    t = ftext('src/usex.nim')
    check('renaming a module updates its imports', os.path.exists(W + '/src/demo/extra2.nim') and 'import demo/extra2' in t, repr(t) + screen()[-300:])

def t_522_shortcuts_markdown():
    setup()
    open(W + '/doc.md', 'w').write('# Big Title\n\nSome **bold** text.\n\n- one\n- two\n')
    start('doc.md')
    palette('Keyboard shortcuts'); time.sleep(0.4)
    text('Toggle soft wrap'); time.sleep(0.4); keys('Enter'); time.sleep(0.3)
    keys('M-z'); time.sleep(0.5)
    c = open(CFG + '/ned/config.json').read()
    check('shortcuts editor binds a key', re.search(r'"alt\+z":\s*"Toggle soft wrap"', c) is not None, c[-400:])
    palette('Markdown: open preview'); time.sleep(0.8)
    s = screen()
    rendered = [l for l in s.split('\n') if 'Big Title' in l and '# Big' not in l.split('│')[-1]]
    check('markdown preview renders beside the file', rendered and 'Some bold text' in s, s[:1500])

def t_522_multibuffer():
    setup()
    start('src/demo.nim')
    keys('M-s'); time.sleep(0.3)
    for _ in range(20): keys('BSpace')
    text('shout'); keys('Enter'); time.sleep(1.5)
    palette('Open results in a multibuffer'); time.sleep(0.6)
    check('multibuffer opens', 'click: open' in screen() or '§' in screen(), screen()[:1200])
    keys('C-g'); text('2'); keys('Enter', 'End'); text(' # mb'); keys('C-s'); time.sleep(0.8)
    hits = sh("grep -rl '# mb' %s/src" % W).stdout.strip()
    check('multibuffer saves edits back to the files', hits != '', screen()[-400:])

def t_522_nim_codegen():
    setup()
    open(W + '/src/cs.nim', 'w').write('type\n  Color = enum\n    red, green, blue\n\nproc f(c: Color): int =\n  case c\n  of red: result = 1\n\necho f(red)\n')
    open(W + '/src/gen.nim', 'w').write('type\n  Pt* = object\n    x*, y*: int\n    name*: string\n\necho 1\n')
    open(W + '/src/run.nim', 'w').write('echo 40 + 2\nlet s = "a" & "b"\n')
    start('src/cs.nim')
    keys('C-g'); text('7'); keys('Enter'); time.sleep(0.2)
    palette('Nim: add the missing case branches'); time.sleep(0.4)
    keys('C-s'); time.sleep(0.4)
    t = ftext('src/cs.nim')
    check('missing case branches added', 'of green:' in t and 'of blue:' in t and t.count('of red') == 1, repr(t))
    tm('kill-server'); time.sleep(0.3)
    start('src/gen.nim')
    keys('C-g'); text('2'); keys('Enter'); time.sleep(0.2)
    palette('Nim: generate $'); time.sleep(0.5)
    keys('C-s'); time.sleep(0.4)
    t = ftext('src/gen.nim')
    check('generate $ == hash constructor', 'proc `$`*(x: Pt): string' in t and 'proc `==`*(a, b: Pt): bool' in t and
          'proc hash*(x: Pt): Hash' in t and 'initPt*(' in t and 'hashes' in t, t)
    r = sh(('cd %s && PATH=' + NIMBIN + ':$PATH nim check --hints:off src/gen.nim 2>&1') % W)
    check('generated code compiles', 'Error' not in r.stdout, r.stdout[-600:])
    tm('kill-server'); time.sleep(0.3)
    start('src/run.nim')
    keys('C-l', 'C-p'); text('>Nim: run the selection'); time.sleep(0.4); keys('Enter')
    check('run the selection shows its output', wait_for(r'\b42\b', 40), screen()[:1200])
    keys('Escape')
    keys('C-g'); text('2:9'); keys('Enter', 'S-End', 'M-h'); time.sleep(0.6)
    check('type of the selection', re.search(r'"a" & "b": string', screen()) is not None, screen()[:1200])

def t_522_nim_tools():
    setup()
    open(W + '/src/cov.nim', 'w').write('proc a(x: int): int =\n  if x > 5:\n    result = 1\n  else:\n    result = 2\necho a(3)\n')
    start('src/cov.nim')
    palette('Nim: test coverage')
    check('coverage runs and reports', wait_for(r'Coverage: \d+%', 90), screen()[-500:])
    palette('Nim: profile'); 
    check('profile panel', wait_for(r'PROFILE', 120), screen()[-800:])
    palette('Nim: standard library docs'); time.sleep(1.5)
    text('toUpperAscii'); time.sleep(0.8); keys('Enter'); time.sleep(1.5)
    check('docs browser shows documentation', re.search(r'(?i)converts', screen()) is not None, screen()[:1500])
    keys('Escape')
    palette('Nimble: dependencies and updates'); 
    check('nimble view', wait_for('Refresh the package list', 30), screen()[:1200])

# ── ned 5.3 ──
LONGVAR = 'var\n  skipDirs*, skipFiles*, skipExt*, installDirs*, installFiles*, installExt*, bin*: seq[string] = @[] ## Nimble metadata.\n  b* = 1\n'

def t_53_alerts_and_formatter():
    setup()
    open(W + '/src/lv.nim', 'w').write(LONGVAR)
    start('src/lv.nim')
    palette('Nim: switch compiler version'); time.sleep(0.8)
    s = screen()
    status = s.rstrip('\n').split('\n')[-1]
    check('messages show in a popup, whole', 'Install choosenim or grabnim' in s and 'Install choosenim' not in status and '╭' in s, s[-900:])
    palette('Show recent messages'); time.sleep(0.5)
    check('recent messages are listed', 'Install choosenim' in screen(), screen()[:900])
    keys('C-w'); time.sleep(0.3)
    keys('M-f'); time.sleep(0.6); keys('C-s'); time.sleep(0.4)
    t = ftext('src/lv.nim')
    check('formatter: long declaration like nph', 'installExt*, bin*:\n    seq[string] = @[] ## Nimble metadata.\n' in t, repr(t))

def t_53_diff_view():
    setup()
    t0 = ftext('src/demo.nim')
    open(W + '/src/demo.nim', 'w').write(t0.replace('"Hello, "', '"Hi, "') + 'echo "extra"\n')
    start('src/demo.nim')
    time.sleep(1)
    palette('Git: compare with last commit'); time.sleep(1.2)
    s = screen()
    check('diff view: side by side', 'HEAD: demo.nim' in s and '⟲' in s and '2 changes' in s, s[:1500])
    keys('r'); time.sleep(0.4)            # cursor starts on the first change
    keys('F7'); time.sleep(0.2); keys('r'); time.sleep(0.4)
    s = screen()
    check('diff view: reverting both changes leaves none', '0 changes' in s, s[:800])
    keys('C-w'); time.sleep(0.3)
    keys('C-s'); time.sleep(0.4)
    check('diff view: the file is back to the commit', ftext('src/demo.nim') == t0, repr(ftext('src/demo.nim')))

def t_53_rename_preview():
    setup(); start('src/demo.nim')
    keys('C-g'); text('4:6'); keys('Enter', 'F2'); time.sleep(0.3)
    keys('C-u'); text('salute'); keys('Enter'); time.sleep(0.8)
    check('rename preview lists every change', screen().count('[x]') == 4, screen()[:1200])
    keys(' '); time.sleep(0.3)            # untick the first one (the declaration)
    check('Space unticks one', screen().count('[x]') == 3 and screen().count('[ ]') == 1, screen()[:1200])
    keys('Enter'); time.sleep(0.6)
    palette('Save all'); time.sleep(0.6)
    t = ftext('src/demo.nim') + ftext('tests/test_demo.nim') + ftext('examples/ex1.nim')
    check('only the ticked changes are made', t.count('salute') == 3 and 'proc greet*' in t, t)

def t_53_debugger_watch_test():
    setup()
    open(W + '/src/dbg.nim', 'w').write(DBG)
    start('src/dbg.nim', w=110, h=40)
    keys('C-g'); text('7'); keys('Enter', 'F9', 'F5')
    ok = wait_for(r'stopped .*at dbg\.nim:7', 60)
    palette('Debug: add a watch'); keys('C-u'); text('total * 2'); keys('Enter'); time.sleep(1.2)
    check('watch expression evaluated', ok and 'total * 2 = 30' in screen(), screen()[-1500:])
    keys('S-F5'); time.sleep(0.5); keys('F9'); time.sleep(0.2)
    tm('kill-server'); time.sleep(0.3)
    start('tests/test_demo.nim', w=110, h=40)
    keys('C-g'); text('5'); keys('Enter'); time.sleep(0.2)
    palette('Debug: debug the test at the cursor')
    check('debug this test: stops inside it', wait_for(r'stopped .*at test_demo\.nim:5', 90), screen()[-1500:])
    keys('S-F5'); time.sleep(0.5)

def t_53_user_commands():
    setup({"commands": {"Upper": {"run": "tr a-z A-Z", "output": "replace"},
                        "Where": {"run": "echo line $line of $name", "output": "popup"}}})
    open(W + '/src/u.nim', 'w').write('echo "abc"\n')
    start('src/u.nim')
    time.sleep(0.5); keys('C-l', 'C-p'); text('>Upper'); time.sleep(0.6); keys('Enter'); time.sleep(1.5)
    keys('Escape', 'C-s'); time.sleep(0.4)
    check('your command replaces the selection', ftext('src/u.nim') == 'ECHO "ABC"\n', repr(ftext('src/u.nim')))
    palette('Where'); time.sleep(1.0)
    check('your command shows its output', 'line 1 of u' in screen(), screen()[:900])

def t_531_help_menus():
    setup(); start('src/demo.nim', w=130, h=44)
    keys('F1'); time.sleep(0.4)
    s = ''
    for _ in range(10):
        s += screen(); keys('PPage' if False else 'NPage'); time.sleep(0.2)
    check('F1 lists the 5.2/5.3 keys', all(k in s for k in ['Alt+Shift+T', 'Alt+F12', 'Ctrl+F10', 'Alt+drag', 'F9 ']), s[-1500:])
    keys('Escape'); time.sleep(0.2)
    keys('F10'); time.sleep(0.3); keys('Right', 'Right', 'Right', 'Right'); time.sleep(0.4)
    check('Run menu has the Debug submenu', 'Debug' in screen() and 'Test coverage' in screen(), screen()[:1500])
    keys('Escape', 'Escape')

# ── ned 5.3.2 (polish) ──
NAMES = 'proc main() =\n  let names = @["Ann", "Bo", "Cy"]\n  var count = 0\n  for n in names:\n    count += n.len\n  echo count\n\nmain()\n'

def t_532_polish():
    setup()
    open(W + '/src/nm.nim', 'w').write(NAMES)
    open(W + '/src/pu.nim', 'w').write('let a = 1\n')
    # persistent undo: edit, save, close, open again, Ctrl+Z
    start('src/pu.nim')
    keys('End'); text(' + 2'); keys('C-s'); time.sleep(0.4)
    keys('C-w'); time.sleep(0.3); keys('M-T'); time.sleep(0.5)
    keys('C-z', 'C-z', 'C-z', 'C-z'); time.sleep(0.3); keys('C-s'); time.sleep(0.4)
    check('undo history survives closing the file', ftext('src/pu.nim') == 'let a = 1\n', repr(ftext('src/pu.nim')))
    tm('kill-server'); time.sleep(0.3)
    # a string condition, Nim's pretty printers, the C frames hidden
    start('src/nm.nim', w=110, h=56)
    keys('C-g'); text('5'); keys('Enter'); time.sleep(0.2)
    palette('Debug: conditional breakpoint'); keys('C-u'); text('n == "Bo"'); keys('Enter'); time.sleep(0.3)
    keys('F5')
    ok = wait_for(r'stopped .*at nm\.nim:5', 60)
    time.sleep(1)
    s = screen()
    check('string condition stops at the right item', ok and 'count: int = 3' in s, s[-1600:])
    check('C runtime frames hidden', 'NimMainInner' not in s and 'frames of the C runtime hidden' in s, s[-1600:])
    keys('S-F5'); time.sleep(0.5)
    tm('kill-server'); time.sleep(0.3)
    # multibuffer header opens its file; the commands editor
    start('src/demo.nim')
    keys('M-s'); time.sleep(0.3)
    for _ in range(20): keys('BSpace')
    text('shout'); keys('Enter'); time.sleep(1.5)
    palette('Open results in a multibuffer'); time.sleep(0.6)
    keys('C-Home', 'Enter'); time.sleep(0.5)
    check('Enter on a multibuffer header opens the file', 'Multibuffer' not in screen().split('\n')[1].split('×')[0] or re.search(r'Ln \d+, Col 1', screen()) is not None, screen()[:600])
    palette('Your commands'); time.sleep(0.4); keys('Enter'); time.sleep(0.3)
    text('Say hi'); keys('Enter'); time.sleep(0.3)
    text('echo hi from $name'); keys('Enter'); time.sleep(0.4)
    text('popup'); time.sleep(0.3); keys('Enter'); time.sleep(0.5)
    c = open(CFG + '/ned/config.json').read()
    check('commands editor writes the setting', '"Say hi"' in c and 'echo hi from $name' in c and '"popup"' in c, c[-500:])
    palette('Say hi'); time.sleep(1.0)
    check('the new command runs', 'hi from' in screen(), screen()[:900])

# ── ned 5.4: git ──
def git(cmd): return sh('cd %s && git %s' % (W, cmd))

def t_54_git():
    setup()
    shutil.rmtree(TMP + '/remote.git', ignore_errors=True)
    sh('git init -q --bare ' + TMP + '/remote.git')
    git('remote remove origin'); git('remote add origin ' + TMP + '/remote.git')
    git('-c user.email=a@b -c user.name=t commit -qam base --allow-empty')
    git('config user.email a@b'); git('config user.name tester')
    start('src/demo.nim', w=130, h=40)
    # a new branch from the branch picker
    palette('Git: branches'); time.sleep(0.8); keys('Enter'); time.sleep(0.3)
    text('feature-x'); keys('Enter'); time.sleep(1.0)
    check('new branch created and checked out', git('rev-parse --abbrev-ref HEAD').stdout.strip() == 'feature-x', git('branch').stdout)
    # edit two places, stage only the first line's change with "stage selected lines"
    keys('C-g'); text('1'); keys('Enter', 'End'); text(' (edited)')
    keys('C-g'); text('5'); keys('Enter', 'End'); text(' # second')
    keys('C-s'); time.sleep(1.2)
    keys('C-g'); text('1'); keys('Enter'); time.sleep(0.2)
    palette('Git: stage selected lines'); time.sleep(1.2)
    d = git('diff --cached').stdout
    check('stage selected lines: only that line', '(edited)' in d and '# second' not in d, d)
    # commit box: Ctrl+S commits
    palette('Git: commit (message box)'); time.sleep(0.6)
    text('First line of the change'); keys('C-s'); time.sleep(1.2)
    log = git('log -1 --format=%s').stdout.strip()
    check('commit box commits', log == 'First line of the change', log + screen()[-400:])
    # push: the first push of a new branch sets its upstream by itself
    palette('Git: push'); time.sleep(2.5)
    up = git('rev-parse --abbrev-ref feature-x@{upstream}').stdout.strip()
    check('first push sets the upstream', up == 'origin/feature-x', up + screen()[-600:])
    # stash the remaining change
    palette('Git: stash'); time.sleep(0.8); keys('Enter'); time.sleep(0.3); text('wip'); keys('Enter'); time.sleep(1.2)
    check('stash puts the change aside', 'wip' in git('stash list').stdout and '# second' not in ftext('src/demo.nim'),
          git('stash list').stdout)
    # history and blame open
    palette('Git: history'); time.sleep(1.0)
    check('history lists commits', 'First line of the change' in screen(), screen()[:1200])
    keys('Escape')
    palette('Git: blame this file'); time.sleep(1.0)
    check('blame shows authors', 'tester' in screen() and '│' in screen(), screen()[:1200])

def t_55_publish():
    # piped input, --, settings typos, Check setup, bug-report info
    setup()
    env = 'XDG_CONFIG_HOME=%s XDG_STATE_HOME=%s COLORTERM=truecolor TERM=xterm-256color' % (CFG, STATE)
    tm('-f', HERE + '/tmux.conf', 'new-session', '-d', '-s', 'f', '-x', '120', '-y', '30',
       "cd %s && printf 'diff --git a/x b/x\\n+\\033[32mnew\\033[0m\\n' | env %s %s; sleep 600" % (W, env, BIN))
    time.sleep(1.5)
    s = screen()
    check('55 pipe content', '+new' in s and '[32m' not in s, s)
    keys('C-End'); text('typed'); time.sleep(0.3)
    check('55 pipe keys', 'typed' in screen(), screen())
    setup({"editor.tabsize": 4})
    open(W + '/-odd.txt', 'w').write('odd file\n')
    start('--', '-odd.txt')
    check('55 -- file', wait_for('odd file', 4), screen())
    palette('Show recent messages'); time.sleep(0.6)
    check('55 settings typo', '"editor.tabSize"?' in screen(), screen())
    palette('Check setup'); time.sleep(1.5)
    check('55 check setup', 'setup check' in screen(), screen())
    palette('Copy info for bug report'); time.sleep(1.5)
    check('55 bug info', 'Copied for a bug report' in screen(), screen())

def t_56_todos():
    # TODO/FIXME/BUG/HACK/NOTE: colours, the TODOs dock (chips, scope, counts), Alt+V, insert, live update, done
    setup()
    os.system('python3 ' + FIX + '/todos_mk.py ' + W)
    start('src/app.nim', w=130, h=34)
    check('56 status urgent count', wait_for('⚑ 2', 6), screen())
    palette('TODOs panel'); time.sleep(1.5)
    s = screen()
    dock = '\n'.join(l.split('│')[-1] for l in s.splitlines() if '│' in l)
    check('56 dock chips', all(x in s for x in ['FIXME 1', 'BUG 1', 'TODO 3', 'NOTE 2', 'HACK 1', 'XXX 1']), s)
    check('56 dock files', '9 in 3 files' in s and 'src/x.c' in s and 'src/util.py' in s, s)
    check('56 strings and prose ignored', 'not a tag' not in dock and 'in this sentence' not in dock, dock)
    check('56 who shown', 'FIXME(foxoman)' in dock, dock)
    keys('1'); time.sleep(0.4)
    check('56 chip filter', '8 in 3 files' in screen(), screen())
    keys('1'); keys('f'); time.sleep(0.4)
    s = screen()
    check('56 file scope', '◉ This file' in s and 'src/x.c' not in s, s)
    keys('f'); keys('Escape'); time.sleep(0.3)
    keys('M-v'); time.sleep(0.4)
    check('56 alt+v next', 'TODO 1 of 5' in screen(), screen())
    keys('M-v'); time.sleep(0.4)
    check('56 alt+v again', 'FIXME 2 of 5' in screen(), screen())
    keys('M-V'); time.sleep(0.4)
    check('56 alt+shift+v back', 'TODO 1 of 5' in screen(), screen())
    keys('C-End'); time.sleep(0.2)
    palette('TODO: insert a tag comment'); time.sleep(0.5)
    keys('Down', 'Down', 'Down', 'Down', 'Enter'); time.sleep(0.3)
    text('live one'); time.sleep(1.5)
    s = screen()
    check('56 insert tag comment', '# TODO: live one' in s, s)
    check('56 live update', 'TODO 4' in s, s)
    palette('TODOs panel'); time.sleep(0.6)
    keys('Down'); keys('x'); time.sleep(1.2)
    s = screen()
    check('56 done deletes the comment', 'handle CRLF' not in s and 'TODO 3' in s, s)
    keys('c'); time.sleep(0.5)
    check('56 copy markdown', 'Copied the TODO list' in screen(), screen())

def t_561_review_fixes():
    # TODO delete in block comments + undo + modified mark, Files-tree counts, GitHub issue without a remote
    setup()
    os.system('python3 ' + FIX + '/todos_mk.py ' + W)
    open(W + '/src/blk.c', 'w').write('int a;\n/* TODO: first\n   more text */\nint b; /* FIXME: inline */ int c;\n')
    open(W + '/root.nim', 'w').write('# TODO: a\n# BUG: b\necho 1\n')
    start('src/blk.c', w=130, h=34)
    palette('TODOs panel'); time.sleep(1.5)
    keys('f'); time.sleep(0.4)
    keys('Home', 'x'); time.sleep(0.8)
    keys('Home', 'x'); time.sleep(0.8)
    s = screen()
    check('561 opener kept', re.search(r'^\s+2\D{0,4}/\*\s+│', s, re.M) is not None and 'TODO: first' not in s, s)
    check('561 inline block removed', 'int b; int c;' in s, s)
    check('561 marked modified', '●' in s, s)
    keys('Escape'); keys('C-z'); time.sleep(0.5)
    check('561 undo restores', '/* FIXME: inline */' in screen(), screen())
    keys('C-z'); time.sleep(0.5)
    check('561 undo again', 'TODO: first' in screen(), screen())
    keys('C-b'); time.sleep(0.8)
    s = screen()
    check('561 files tree count', '⚑2' in s, s)
    palette('TODOs panel'); time.sleep(0.8)
    keys('Home', 'i'); time.sleep(0.6)
    check('561 issue asks first', 'Create a GitHub issue' in screen(), screen())
    keys('y'); time.sleep(4)
    check('561 issue error shown', 'gh issue create failed' in screen() or 'needs the GitHub CLI' in screen(), screen())

def t_562_format_cursor():
    # format on save removes blank lines under the cursor: the cursor goes to the end of the line above
    def pos():
        m = re.search(r'Ln (\d+), Col (\d+)', screen())
        return m.groups() if m else None
    for name, content, ks, want in [
            ('blank last line', 'proc foo() =\n  echo 1\n\n', ['C-End'], ('2', '9')),
            ('enter after the last line', 'proc foo() =\n  echo 1\n', ['C-End', 'Enter', 'Enter'], ('2', '9')),
            ('blank lines between', 'proc foo() =\n  echo 1\n\n\n\nproc bar() = discard\n',
             ['C-Home', 'Down', 'Down', 'Down', 'Down'], ('3', '1'))]:
        setup({"editor.formatOnSave": True})
        open(W + '/f.nim', 'w').write(content)
        start('f.nim', w=100, h=20)
        time.sleep(0.8)
        keys(*ks); time.sleep(0.3)
        keys('C-s'); time.sleep(1.0)
        check('562 format cursor: ' + name, pos() == want, str(pos()) + ' ' + screen()[:300])

def t_512_refs_big():
    # Find references on a name used everywhere in a 30,000-line file: ned stays responsive and answers in time
    setup()
    with open(W + '/big.nim', 'w') as f:
        for i in range(30000): f.write('proc p%d*(x: int): int = x + %d  # line\n' % (i, i))
    start('big.nim', w=120, h=30); time.sleep(2)
    keys('C-g'); text('1:13'); keys('Enter'); time.sleep(0.3)
    t0 = time.time(); keys('M-q')
    ok = wait_for(r'REFERENCES int', 16)
    took = time.time() - t0
    check('512 references to a name used 60,000 times come back within 15 s (took %.1f s)' % took, ok and took < 15, screen()[-800:])
    keys('Escape'); keys('C-End'); text('zq'); time.sleep(0.5)
    check('512 and ned is responsive afterwards', 'zq' in screen(), screen()[-600:])
    # the same with the big file closed: its lines are read from disk, once, not once per use
    keys('C-q'); time.sleep(0.5); keys('n'); time.sleep(0.5)
    tm('kill-server'); time.sleep(0.5)
    open(W + '/small.nim', 'w').write('proc q*(x: int): int = x + 1\n')
    start('small.nim', w=120, h=30); time.sleep(2)
    keys('C-g'); text('1:13'); keys('Enter'); time.sleep(0.3)
    t0 = time.time(); keys('M-q')
    ok = wait_for(r'REFERENCES int', 16)
    took = time.time() - t0
    check('512 references in a closed 30,000-line file come back within 15 s (took %.1f s)' % took, ok and took < 15, screen()[-800:])
    keys('Escape'); keys('C-End'); text('zq'); time.sleep(0.5)
    check('512 and ned is responsive after that too', 'zq' in screen(), screen()[-600:])

def t_512_comp_stale():
    # keys and a click read together: the list gets shorter, then the click lands where a row used to be
    setup(); start('src/demo.nim', w=100, h=30); time.sleep(3)
    keys('C-End'); keys('Enter'); text('  to'); time.sleep(1.5)
    lines = screen().split('\n')
    row = next((i for i, l in enumerate(lines) if 'ƒ toInt ' in l), -1)
    check('512 completion list shown', row >= 0, screen())
    if row < 0: return
    x, y = lines[row].index('toInt') + 2, row + 1 + 7
    burst = 'BiggestI' + '\x1b[<0;%d;%dM\x1b[<0;%d;%dm' % (x, y, x, y)
    tm('send-keys', '-t', 'f', '-H', *['%02x' % b for b in burst.encode()]); time.sleep(1)
    keys('Enter'); time.sleep(1)
    errs = ''
    try: errs = open(STATE + '/ned/errors.log').read()
    except Exception: pass
    check('512 a click below a list that just got shorter: no internal error', 'IndexDefect' not in errs, errs[-600:])
    text('zq'); time.sleep(0.4)
    check('512 and ned still edits', 'zq' in screen(), screen()[-500:])

def hx(t):
    tm('send-keys', '-t', 'f', '-H', *['%02x' % b for b in t.encode()]); time.sleep(0.25)

def t_513_emit_edit():
    # C inside {.emit.} edits as C: indentation, a typed } moves back, Ctrl+/ uses //; the Nim around stays Nim
    setup({"editor.autoClosePairs": False})
    open(W + '/e.nim', 'w').write('{.emit: """\n\n""".}\n\nproc twice(x: cint): cint {.importc, nodecl.}\n')
    start('e.nim', w=100, h=30); time.sleep(2.5)
    keys('C-g'); text('2'); keys('Enter'); time.sleep(0.3)
    for part in ['static int twice(int x) {', '\r', 'if (x > 100) {', '\r', 'return x;', '\r', '}', '\r',
                 'return x * 2;', '\r', '}']:
        hx(part)
    keys('C-s'); time.sleep(0.5)
    t = ftext('e.nim')
    want = 'static int twice(int x) {\n  if (x > 100) {\n    return x;\n  }\n  return x * 2;\n}\n'
    check('513 emit: C indents after {, and a typed } moves back', want in t, t)
    keys('C-g'); text('6'); keys('Enter'); keys('C-_'); time.sleep(0.3); keys('C-s'); time.sleep(0.4)
    check('513 emit: Ctrl+/ comments C with //', ftext('e.nim').split('\n')[5] == '  // return x * 2;', ftext('e.nim'))
    keys('C-g'); text('10'); keys('Enter'); keys('C-_'); time.sleep(0.3); keys('C-s'); time.sleep(0.4)
    check('513 emit: the Nim line after it still gets #', ftext('e.nim').split('\n')[9].startswith('# proc twice'), ftext('e.nim'))
    tm('kill-server')
    # HTML and SQL in strings, a Markdown code block
    setup()
    open(W + '/h.nim', 'w').write('let page = """\n<div>\n  <p>hi</p>\n</div>\n"""\nlet q = """\nSELECT a\nFROM t\n"""\n')
    open(W + '/n.md', 'w').write('# T\n\n```nim\necho 1\n```\n\n```python\n- x = 1\n```\n')
    start('h.nim', w=100, h=30); time.sleep(2)
    keys('C-g'); text('3'); keys('Enter'); keys('C-_'); time.sleep(0.3)
    keys('C-g'); text('8'); keys('Enter'); keys('C-_'); time.sleep(0.3); keys('C-s'); time.sleep(0.4)
    ls = ftext('h.nim').split('\n')
    check('513 HTML in a string: Ctrl+/ gives <!-- -->', ls[2] == '  <!-- <p>hi</p> -->', ls)
    check('513 SQL in a string: Ctrl+/ gives --', ls[7] == '-- FROM t', ls)
    keys('C-o'); time.sleep(0.4); text('n.md'); keys('Enter'); time.sleep(1)
    keys('C-g'); text('4'); keys('Enter'); keys('C-_'); time.sleep(0.3)
    keys('C-g'); text('8'); keys('Enter'); keys('End'); hx('\r'); hx('y'); keys('C-s'); time.sleep(0.4)
    t = ftext('n.md')
    check('513 Markdown: Ctrl+/ in a ```nim block gives #', '\n# echo 1\n' in t, t)
    check('513 Markdown: Enter in a code block does not continue a list', '- x = 1\ny\n' in t, t)

def t_513_emit_errors():
    # a C compiler error inside an emit shows on the .nim line it comes from (ned's own C checks: clangd, when
    # installed, would take over the emitted C — t_514_emit_clangd tests that)
    setup({"nim.emitClangd": False})
    open(W + '/e.nim', 'w').write('echo "start"\n{.emit: """\nstatic int twice(int x) {\n  return x * 2 +;\n}\n""".}\n'
                                  'proc twice(x: cint): cint {.importc, nodecl.}\necho twice(2)\n')
    start('e.nim', w=120, h=34); time.sleep(2.5)
    keys('M-r')
    ok = wait_for('C: expected expression', 60)
    check('513 C error in an emit: shown on the Nim line, with the C file named', ok and re.search(r'4 .*return x \* 2 \+;.*C: expected expression.*@me\.nim\.c:44', screen()), screen())
    keys('Escape'); time.sleep(0.3); keys('C-Home'); keys('F8'); time.sleep(0.6)
    check('513 F8 goes to it', 'Ln 4, Col 17' in screen(), screen()[-300:])
    # on save too, with no build: the C compiler checks the emitted C (built-in engine and nimlangserver)
    for cfg, name in (({"nim.emitClangd": False}, 'built-in engine'),
                      ({"nim.ide": "nimlangserver", "nim.emitClangd": False}, 'nimlangserver')):
        tm('kill-server'); time.sleep(0.3)
        setup(cfg)
        open(W + '/e.nim', 'w').write('{.emit: """\nstatic int twice(int x) {\n  return x * 2;\n}\n""".}\n'
                                      'proc twice(x: cint): cint {.importc, nodecl.}\necho twice(2)\n')
        start('e.nim', w=110, h=30); time.sleep(3)
        keys('C-g'); text('3'); keys('Enter'); keys('End'); keys('BSpace'); text(' +'); keys('C-s')
        check('513 %s: a C error in the emit shows on save' % name, wait_for('C: expected', 30), screen())
        time.sleep(4)
        check('513 %s: and stays while the Nim checks run' % name, 'C: expected' in screen(), screen())
        keys('BSpace', 'BSpace'); hx(';'); keys('C-s')
        end = time.time() + 30
        while time.time() < end and 'C: expected' in screen(): time.sleep(0.5)
        check('513 %s: fixed and saved: it goes' % name, not 'C: expected' in screen(), screen())

def t_513_emit_c():
    # C in an emit: completion (its own names, its #includes, nimbase.h, keywords), hover, F12 both ways,
    # and the wrapper check against the emitted definition — ned's own (clangd, when installed, takes over)
    setup({"nim.emitClangd": False})
    open(W + '/e.nim', 'w').write('''{.emit: """
#include <stdio.h>
static int twice(int x) {
  return x * 2;
}
static void hello(void) {

}
""".}

proc twice(x: int): int {.importc, nodecl.}
proc hello() {.importc, nodecl.}
echo twice(2)
''')
    start('e.nim', w=110, h=34); time.sleep(3)
    check('513 emit C: the wrapper is checked against the emitted definition',
          re.search(r'11 .*proc twice.*parameter x: C has int', screen()) and '▲ 2' in screen(), screen())
    keys('C-g'); text('7'); keys('Enter'); keys('End'); text('  pri'); time.sleep(1.2)
    check('513 emit C: completion from its #include <stdio.h>', re.search(r'printf +function · <stdio\.h>', screen()), screen())
    keys('Escape'); keys('Home'); keys('S-End'); text('  tw'); time.sleep(1.2)
    check('513 emit C: completion of the emit\'s own functions', re.search(r'twice +function · this file', screen()), screen())
    keys('Escape'); keys('Home'); keys('S-End'); text('  NIM_T'); time.sleep(1.2)
    check('513 emit C: completion from nimbase.h', re.search(r'NIM_TRUE +macro · nimbase\.h', screen()), screen())
    keys('Escape'); keys('Home'); keys('S-End'); text('  printf'); keys('Escape'); keys('Left'); keys('Left')
    keys('M-h'); time.sleep(1.5)
    check('513 emit C: hover shows the C declaration', re.search(r'printf — C function, stdio\.h:\d+', screen()), screen())
    keys('Escape')
    # F12: Nim declaration → the emitted definition, and back
    keys('C-g'); text('11:7'); keys('Enter'); time.sleep(0.3); keys('F12'); time.sleep(0.8)
    check('513 F12 on the Nim declaration goes to the C definition in the emit', 'Ln 3, Col 12' in screen(), screen()[-300:])
    keys('F12'); time.sleep(0.8)
    check('513 F12 on the C definition goes back to the Nim declaration', 'Ln 11, Col 6' in screen(), screen()[-300:])
    keys('M-h'); time.sleep(1.5)
    check('513 hover on the Nim declaration shows the emitted C', re.search(r'\{\.emit\.\} in e\.nim:3', screen()) and 'static int twice(int x)' in screen(), screen())
    keys('Escape')
    # a use inside the emit → its definition
    keys('C-g'); text('7'); keys('Enter'); keys('Home'); keys('S-End'); text('  hello'); keys('Escape'); keys('Left')
    keys('F12'); time.sleep(0.8)
    check('513 F12 on a use in the emit goes to its C definition', 'Ln 6, Col 13' in screen(), screen()[-300:])
    # the fix: Alt+Enter on the warning changes int to cint
    keys('C-g'); text('11:13'); keys('Enter'); time.sleep(0.3); keys('M-Enter'); time.sleep(0.8)
    if 'cint' in screen(): keys('Enter'); time.sleep(0.5)
    keys('C-s'); time.sleep(0.5)
    check('513 Alt+Enter fixes the wrapper', 'proc twice(x: cint)' in ftext('e.nim'), ftext('e.nim'))

def t_514_emit_clangd():
    need('clangd')
    # with clangd installed, C in an emit gets clangd's completion, errors while typing, fixes, parameter
    # hints, F12 and hover — on the .nim's own lines
    PATHC = TOOLS + ':/usr/bin:/bin'
    setup()
    open(W + '/e.nim', 'w').write('''proc puts(s: cstring): cint {.importc, header: "<stdio.h>".}
proc nimSide(x: cint): cint {.exportc.} = x + 1

{.emit: """
typedef struct { int x; int y; } Point;

static NI area(Point p) {
  int scale = 2;
  printf("%d", nimSide(p.x));
  return p.x * p.y * scale;
}
""".}
''')
    start('e.nim', w=120, h=34, path=PATHC)
    wait_for('clangd ready', 20); time.sleep(4)
    check('514 clangd: no false errors (NI from nimbase.h, printf through a header: pragma, an exportc proc)',
          'C:' not in screen() and '✓ 0' in screen(), screen())
    keys('C-g'); text('8'); keys('Enter'); keys('End'); hx('\r'); hx('Point q; q.')
    check('514 clangd: member completion after .', wait_for(r'x +int', 10), screen())
    keys('Escape'); hx('x = undefined_thing;')
    check('514 clangd: an error while typing, on the Nim line', wait_for(r"9.*C: Use of undeclared identifier 'undefined_thing'", 12), screen())
    keys('Home'); keys('S-End'); hx('  Point q; q.x = 1')
    ok = wait_for(r"C: Expected ';' after expression", 12)
    check('514 clangd: a fixable error', ok, screen())
    keys('M-Enter'); time.sleep(1.5)
    s = screen()
    check('514 clangd: Alt+Enter offers its fix', re.search(r"insert ';'", s, re.I), s)
    keys('Enter'); time.sleep(0.5); keys('C-s'); time.sleep(0.5)
    check('514 clangd: the fix is applied to the .nim', '  Point q; q.x = 1;' in ftext('e.nim'), ftext('e.nim'))
    keys('C-g'); text('9'); keys('Enter'); keys('End'); hx('\r'); hx('printf(')
    check('514 clangd: parameter hints', wait_for(r'printf\(const char', 10), screen())
    keys('Escape'); keys('C-g'); text('10:1'); keys('Enter'); keys('S-Down'); keys('BSpace'); time.sleep(1.5)
    keys('C-g'); text('11:22'); keys('Enter'); time.sleep(0.3); keys('F12')
    check('514 clangd: F12 on a local goes to its declaration', wait_for(r'Ln 8, Col 7', 8), screen()[-300:])
    keys('C-g'); text('10:4'); keys('Enter'); keys('M-h')
    check('514 clangd: hover', wait_for(r'function `?printf', 10), screen())
    # "nim.emitClangd": false — ned's own completion from the headers, no clangd
    tm('kill-server'); time.sleep(0.3)
    setup({"nim.emitClangd": False})
    open(W + '/e.nim', 'w').write('{.emit: """\n#include <stdio.h>\nstatic void f(void) {\n\n}\n""".}\n')
    start('e.nim', w=120, h=30, path=PATHC); time.sleep(4)
    keys('C-g'); text('4'); keys('Enter'); hx('  pri'); time.sleep(1.5)
    check('514 nim.emitClangd off: ned\'s own completion, and no clangd started',
          re.search(r'printf +function · <stdio\.h>', screen()) and 'clangd' not in screen(), screen())

def t_515_emit_more():
    need('clangd')
    # clangd sees the -D defines (the file's {.passC.}, config.nims) and the one-line and array-form emits
    PATHC = TOOLS + ':/usr/bin:/bin'
    setup()
    open(W + '/config.nims', 'w').write('switch("passC", "-DFROM_CONFIG=3")\n')
    open(W + '/e.nim', 'w').write('''{.passC: "-DFEATURE_X".}
{.emit: "static int counter = 0;".}
{.emit: ["static int seven(void) { return 7; }"].}
{.emit: """
#ifndef FEATURE_X
#error FEATURE_X is not defined
#endif
static int bump(void) {
  counter += FROM_CONFIG + seven();
  return counter;
}
""".}
''')
    start('e.nim', w=120, h=30, path=PATHC)
    wait_for('clangd ready', 20); time.sleep(5)
    check('515 clangd: defines from {.passC.} and config.nims, one-line and array-form emits known',
          '● C: ' not in screen() and '✓ 0' in screen(), screen())
    keys('C-g'); text('10'); keys('Enter'); keys('End'); hx('\r'); hx('cou')
    check('515 clangd: a one-line emit\'s name in the completion', wait_for(r'counter +int', 10), screen())

def t_515_strings():
    need('node', 'vscode-css-language-server', 'vscode-html-language-server', 'vscode-json-language-server', 'sql-language-server')
    # HTML, CSS, SQL and JSON in Nim strings go through their language servers
    PATHL = NODE_DIR + ':' + TOOLS + ':/usr/bin:/bin'
    setup()
    open(W + '/p.nim', 'w').write('''import std/[strformat, json]
template sql(s: string): string = s
let title = "Shop"
let page = fmt"""
<!DOCTYPE html>
<html>
<head>
  <style>
    body {{ colr: red; margin: {title.len}px; }}
  </style>
</head>
<body>
  <h1>{title}</h1>

</body>
</html>
"""
let q = sql"SELEC name FROM items"
let rows = """
SELECT id,
       name
  FROM users
 WHERE id = 1
"""
let j = parseJson("""{"a": 1, "b": }""")
let style = #[css]# """
p { font-weigth: bold; }
"""
''')
    start('p.nim', w=120, h=34, path=PATHL); time.sleep(3)
    ok = wait_for(r"9 .*HTML: Unknown property: 'colr'", 20)
    check('515 CSS in an HTML string: the HTML server\'s warning on the Nim line ({title.len} is not an error)', ok, screen())
    check('515 SQL in a sql"…" string: its syntax error', re.search(r'18 .*SQL: Expected', screen()), screen())
    check('515 the multi-line SQL string is fine', not re.search(r'2[0-3] .*SQL:', screen()), screen())
    check('515 JSON in parseJson: its error', re.search(r'25 .*JSON: Value expected', screen()), screen())
    check('515 a #[css]# string: the CSS server\'s warning', re.search(r"27 .*CSS: Unknown property: 'font-weigth'", screen()), screen())
    keys('C-g'); text('14'); keys('Enter'); keys('End'); hx('  <di')
    check('515 HTML completion in a string', wait_for(r'div +The div element', 10), screen())
    keys('Escape'); keys('C-g'); text('13:5'); keys('Enter'); keys('M-h')
    check('515 HTML hover in a string', wait_for(r'The h1 element|h1', 10) and 'heading' in screen().lower(), screen())
    keys('Escape'); keys('C-g'); text('18'); keys('Enter'); keys('End'); hx('\r'); hx('let r = sql"SEL')
    check('515 SQL completion in a string', wait_for(r'SELECT +keyword', 10), screen())
    # the CSS server's fix, on Alt+Enter
    tm('kill-server'); time.sleep(0.3)
    setup()
    open(W + '/c.nim', 'w').write('let style = #[css]# """\np { font-weigth: bold; }\n"""\n')
    start('c.nim', w=120, h=30, path=PATHL)
    wait_for("CSS: Unknown property", 20)
    keys('C-g'); text('2:8'); keys('Enter'); keys('M-Enter')
    check('515 Alt+Enter: the CSS server\'s fixes', wait_for(r"Rename to 'font-weight'", 8), screen())
    keys('Enter'); time.sleep(1); keys('C-s'); time.sleep(0.5)
    check('515 the fix is applied to the .nim', 'p { font-weight: bold; }' in ftext('c.nim'), ftext('c.nim'))

QF_SRC = '''import std/[strutils, sequtils]
import other

type Color = enum red, green, blue
type P = object
  name: string
  age: int

proc twice(x: int): int = x * 2
proc area(w, h: float): float = w * h
proc risky() {.raises: [].} =
  discard parseInt("1")

let k = 3
k = 4
twice(2)
let i = 2
echo area(i, 3.0)
let n: int = "7"
echo twise(2)
echo hidden(1)
echo undefinedProc(1, "a")
var p = P(name: "a")
echo p.nmae
let c = red
case c
of red: echo "r"
let msg = "n=" & i
twice(3)
'''

def qf_fix(line, col, pick, wait=8):
    # Alt+Enter on a line, pick the fix whose title has `pick`, save; the file's text
    keys('Escape'); keys('C-g'); text('%d:%d' % (line, col)); keys('Enter'); time.sleep(0.3)
    keys('M-Enter'); ok = wait_for(re.escape(pick), wait)
    if not ok: return None, screen()
    text(pick); time.sleep(0.4); keys('Enter'); time.sleep(0.6); keys('C-s'); time.sleep(0.8)
    return ftext('a.nim'), screen()

def t_516_quickfixes():
    setup()
    open(W + '/other.nim', 'w').write('proc secret*(x: int): int = x\nproc hidden(x: int): int = x + 1\n')
    open(W + '/a.nim', 'w').write(QF_SRC)
    open(W + '/dep.nim', 'w').write('proc old(x: int): int {.deprecated: "use twice instead".} = x * 2\n'
                                  'proc twice(x: int): int = x * 2\necho old(1)\necho old(2)\n')
    start('a.nim', w=130, h=40); time.sleep(2)
    keys('C-s'); wait_for('cannot be assigned', 30); time.sleep(1)
    t, sc = qf_fix(15, 1, 'Make k a var')
    check('516 let → var for "cannot be assigned to"', t and '\nvar k = 3\n' in t, sc)
    t, sc = qf_fix(16, 1, 'Discard the result')
    check('516 discard for "has to be used"', t and '\ndiscard twice(2)\n' in t, sc)
    t, sc = qf_fix(18, 11, 'Convert argument 1')
    check('516 a conversion for the argument that does not fit', t and 'echo area(float(i), 3.0)' in t, sc)
    t, sc = qf_fix(19, 14, 'Convert: parseInt')
    check('516 a conversion for a let (and the import it needs)', t and 'let n: int = parseInt("7")' in t, sc)
    t, sc = qf_fix(20, 6, 'Change to twice')
    check('516 did-you-mean for an undeclared name', t and 'echo twice(2)' in t, sc)
    t, sc = qf_fix(21, 6, 'Export hidden from other.nim')
    keys('C-Tab'); time.sleep(0.3)
    check('516 export a name another module of the project does not export: it opens there', 'other.nim' in screen(), screen())
    keys('C-p'); text('other.nim'); time.sleep(0.5); keys('Enter'); time.sleep(0.5); keys('C-s'); time.sleep(0.5)
    check('516 … the * is added in other.nim', 'proc hidden*(x: int)' in open(W + '/other.nim').read(), open(W + '/other.nim').read())
    keys('C-p'); text('a.nim'); time.sleep(0.5); keys('Enter'); time.sleep(0.5)
    keys('C-s'); wait_for('undeclared routine|undefinedProc', 30); time.sleep(1)
    t, sc = qf_fix(22, 6, 'Create proc undefinedProc')
    check('516 create the proc a call needs', t and 'proc undefinedProc(a: int, b: string): string =' in t, sc)
    keys('C-s'); time.sleep(4)
    ln = [i for i, l in enumerate(ftext('a.nim').split('\n')) if 'echo p.nmae' in l][0] + 1
    t, sc = qf_fix(ln, 8, 'Change to name')
    check('516 the field the name was meant to be', t and 'echo p.name' in t, sc)
    ln = [i for i, l in enumerate(ftext('a.nim').split('\n')) if l.startswith('case c')][0] + 1
    t, sc = qf_fix(ln, 1, 'Add the missing branches')
    check('516 the missing case branches', t and 'of green:' in t and 'of blue:' in t, sc)
    ln = [i for i, l in enumerate(ftext('a.nim').split('\n')) if 'let msg = "n=" & i' in l][0] + 1
    t, sc = qf_fix(ln, 16, 'Convert argument 2')
    check('516 $ for an int where & wants a string', t and 'let msg = "n=" & $i' in t, sc)
    ln = [i for i, l in enumerate(ftext('a.nim').split('\n')) if 'discard parseInt("1")' in l][0] + 1
    t, sc = qf_fix(ln, 19, 'Add ValueError to the raises list')
    check('516 add the exception to raises', t and 'proc risky() {.raises: [ValueError].} =' in t, sc)
    keys('C-s'); time.sleep(4)
    # an ambiguous name: say which module's; a deprecated proc: what it says to use
    open(W + '/m1.nim', 'w').write('var counter* = 1\n')
    open(W + '/m2.nim', 'w').write('var counter* = 2\n')
    open(W + '/ambig.nim', 'w').write('import m1, m2\nproc old(x: int): int {.deprecated: "use twice instead".} = x * 2\n'
                                  'proc twice(x: int): int = x * 2\nlet x = counter + 1\necho old(x)\n')
    keys('C-o'); time.sleep(0.4); text('ambig.nim'); keys('Enter'); time.sleep(1); keys('C-s'); wait_for('ambiguous|mismatch', 30); time.sleep(1)
    keys('Escape'); keys('C-g'); text('4:9'); keys('Enter'); keys('M-Enter')
    ok = wait_for(r'Use m2\.counter', 8)
    check('516 an ambiguous name: say which module\'s', ok and 'Use m1.counter' in screen(), screen())
    if ok:
        text('m2.counter'); time.sleep(0.3); keys('Enter'); time.sleep(0.5); keys('C-s'); time.sleep(0.5)
        check('516 … qualified', 'let x = m2.counter + 1' in open(W + '/ambig.nim').read(), open(W + '/ambig.nim').read())
    time.sleep(3)
    keys('Escape'); keys('C-g'); text('5:6'); keys('Enter'); keys('M-Enter')
    ok = wait_for(r'Use twice instead of old', 8)
    check('516 a deprecated proc: use what it says', ok, screen())
    if ok:
        text('Use twice'); time.sleep(0.3); keys('Enter'); time.sleep(0.5); keys('C-s'); time.sleep(0.5)
        check('516 … replaced', 'echo twice(x)' in open(W + '/ambig.nim').read(), open(W + '/ambig.nim').read())
    # two unused results left: fix all of them at once
    open(W + '/b.nim', 'w').write('proc one(): int = 1\none()\none()\none()\n')
    keys('C-o'); time.sleep(0.4); text('b.nim'); keys('Enter'); time.sleep(1); keys('C-s'); wait_for('has to be used', 30)
    keys('C-g'); text('2'); keys('Enter'); keys('M-Enter')
    ok = wait_for('Fix all 3 like this', 8)
    check('516 "fix all like this in the file"', ok, screen())
    if ok:
        text('Fix all'); time.sleep(0.3); keys('Enter'); time.sleep(0.5); keys('C-s'); time.sleep(0.5)
        check('516 … every one fixed', open(W + '/b.nim').read().count('discard one()') == 3, open(W + '/b.nim').read())
    # a deprecated name used twice: both changed at once
    keys('C-o'); time.sleep(0.4); text('dep.nim'); keys('Enter'); time.sleep(1); keys('C-s'); wait_for('deprecated', 30); time.sleep(1)
    keys('C-g'); text('3:6'); keys('Enter'); keys('M-Enter')
    ok = wait_for('Fix all 2 like this', 8)
    check('516 "fix all" for a deprecated name', ok, screen())
    if ok:
        text('Fix all'); time.sleep(0.3); keys('Enter'); time.sleep(0.5); keys('C-s'); time.sleep(0.5)
        c = open(W + '/dep.nim').read()
        check('516 … both uses changed', 'echo twice(1)' in c and 'echo twice(2)' in c, c)

def t_516_ai_fix():
    # Fix with AI: the model's change is checked with nim check first; a change that does not compile is sent
    # back once with the error, and only the one that compiles is applied
    setup()
    open(W + '/t.nim', 'w').write('proc total(xs: seq[int]): int =\n  let sum = 0\n  for x in xs:\n    sum += x\n  sum\n\necho total(@[1, 2])\n')
    start('t.nim', w=120, h=30); time.sleep(2)
    keys('C-s'); wait_for('cannot be assigned', 30); time.sleep(1)
    keys('C-g'); text('4:5'); keys('Enter'); keys('M-Enter')
    ok = wait_for('Fix with AI', 8)
    check('516 AI fix offered', ok, screen())
    text('Fix with AI'); time.sleep(0.3); keys('Enter')
    ok = wait_for('AI fix applied — nim check passes', 40)
    check('516 AI fix: the broken first answer was sent back, the second one compiles and is applied', ok, screen())
    keys('C-s'); time.sleep(0.5)
    t = ftext('t.nim')
    check('516 AI fix: the file has the working fix', '  var sum = 0' in t and 'sum += x +' not in t, t)
    check('516 AI fix: no check file left behind', not [f for f in os.listdir(W) if f.startswith('ned_fixcheck')], str(os.listdir(W)))

def t_563_open_folder():
    # File › Open folder…: a folder browser — starts beside the project, filters, goes in, opens with Alt+Enter
    setup()
    other = os.path.dirname(W) + '/zz_other'
    shutil.rmtree(other, ignore_errors=True)
    os.makedirs(other + '/proj2/.git'); os.makedirs(other + '/plain')
    open(other + '/proj2/a.nim', 'w').write('echo 1\n')
    start(w=120, h=30)
    keys('d'); time.sleep(0.8)
    s = screen()
    check('563 browser opens beside the project', 'Open folder · ' + os.path.dirname(W) in s and 'work/' in s, s)
    check('563 current project marked', 'open now' in s, s)
    text('zz'); time.sleep(0.4)
    check('563 typing filters the folders', 'zz_other/' in screen() and 'work2/' not in screen(), screen())
    keys('Enter'); time.sleep(0.6)
    s = screen()
    check('563 goes into a folder', '◆ proj2/' in s and '▸ plain/' in s and 'git' in s, s)
    keys('BSpace'); time.sleep(0.6)
    check('563 backspace goes up', 'work/' in screen(), screen())
    text('zz'); keys('Enter'); time.sleep(0.6)
    text('proj'); time.sleep(0.3); keys('M-Enter'); time.sleep(1.2)
    s = screen()
    check('563 alt+enter opens it as the project', 'proj2' in s.splitlines()[0], s)
    shutil.rmtree(other, ignore_errors=True)

def t_564_tiny_screens():
    # every dock, panel, menu and picker at phone sizes, with resizes in between: ned must keep running and log no errors
    setup()
    os.system('python3 ' + FIX + '/todos_mk.py ' + W)
    start('src/app.nim', w=40, h=12)
    sizes = [(40, 12), (30, 8), (20, 6), (12, 4), (100, 30), (36, 10)]
    steps = [['C-b'], ['M-s'], ['M-g'], ['M-e'], ['M-i'], ['>TODOs panel'], ['>Open folder'], ['M-c'], ['F10'],
             ['C-e'], ['F1'], ['>Settings'], ['>Check setup'], ['C-\\'], ['>Git: branches'], ['>Keyboard shortcuts']]
    for i, st in enumerate(steps):
        for k in st:
            if k.startswith('>'): palette(k[1:])
            else: keys(k)
        time.sleep(0.4)
        w, h = sizes[i % len(sizes)]
        tm('resize-window', '-t', 'f', '-x', str(w), '-y', str(h)); time.sleep(0.4)
        keys('Escape'); time.sleep(0.2)
    tm('resize-window', '-t', 'f', '-x', '100', '-y', '30'); time.sleep(0.6)
    alive = not os.path.exists(W + '/exit')
    errs = STATE + '/ned/errors.log'
    log = open(errs).read() if os.path.exists(errs) else ''
    check('564 alive after tiny screens and resizes', alive and 'Ln ' in screen(), screen())
    check('564 no internal errors', log.strip() == '', log[-800:])

def t_564_save_safety():
    # saving changes only what you changed: odd files round-trip byte for byte; read-only files ask first
    corpus = {'crlf.txt': b'alpha\r\nbeta\r\n', 'noeol.txt': b'alpha\nbeta', 'bom.txt': '\ufeffhi\nyo\n'.encode(),
              'bad.txt': b'ok \xff\xfe bad\nnext\n', 'nl.txt': b'\n', 'empty.txt': b'',
              'trail.nim': b'let a = 1   \nlet b = 2\t\nlet c = 3\n', 'cr.txt': b'a\rb\rc\n'}
    for name, data in corpus.items():
        setup()
        open(W + '/' + name, 'wb').write(data)
        start(name, w=100, h=20); time.sleep(0.5)
        keys('C-End'); text('x'); keys('BSpace'); time.sleep(0.2)
        keys('C-s'); time.sleep(0.7)
        got = open(W + '/' + name, 'rb').read()
        check('564 round trip ' + name, got == data, repr(got[:80]))
    setup()
    ro = W + '/ro.txt'; open(ro, 'w').write('locked\n'); os.chmod(ro, 0o444)
    start('ro.txt', w=100, h=20); time.sleep(0.5)
    keys('C-End'); text('!'); keys('C-s'); time.sleep(0.6)
    check('564 read-only asks', 'read-only on disk' in screen(), screen())
    keys('c'); time.sleep(0.4)
    check('564 cancel keeps it', open(ro).read() == 'locked\n')
    os.chmod(ro, 0o644)

def t_57_themes():
    # theme.colors overrides, new themes, import a VS Code theme (JSONC) and a base16 one, auto (OSC 11 answer)
    setup({"theme.colors": {"bg": "#101010"}})
    start('src/demo.nim', w=100, h=24); time.sleep(0.5)
    a = tm('capture-pane', '-t', 'f', '-e', '-p').stdout
    check('57 theme.colors changes the background', '48;2;16;16;16' in a)
    keys('M-t'); time.sleep(0.6); text('modus'); time.sleep(0.4)
    s = screen()
    check('57 new themes in the picker', 'modus-operandi' in s and 'modus-vivendi' in s, s)
    keys('Escape'); time.sleep(0.3)
    setup({"theme.colors": {"[my-test-theme]": {"bg": "#fdf6e4"}}})     # applies only to the imported theme
    start('src/demo.nim', w=100, h=24); time.sleep(0.5)
    open(W + '/my-theme.json', 'w').write('{\n  // a comment\n  "name": "My Test Theme", "type": "light",\n  "colors": {"editor.background": "#fdf6e3", "editor.foreground": "#333333",},\n  "tokenColors": [{"scope": ["comment"], "settings": {"foreground": "#93a1a1"}}, {"scope": "keyword", "settings": {"foreground": "#859900"}},],\n}\n')
    palette('Theme: import a VS Code'); time.sleep(0.4)
    keys('C-u'); text(W + '/my-theme.json'); keys('Enter'); time.sleep(1.0)
    a = tm('capture-pane', '-t', 'f', '-e', '-p').stdout
    check('57 VS Code theme imported and applied', os.path.exists(CFG + '/ned/themes/my-test-theme.json') and '48;2;253;246;228' in a,
          str(os.listdir(CFG + '/ned')) + screen())
    open(W + '/b16.yaml', 'w').write('scheme: "Test Sixteen"\n' + ''.join('base0%X: "%02x%02x%02x"\n' % (i, 16 + i, 32 + i, 48 + i) for i in range(16)))
    palette('Theme: import a VS Code'); time.sleep(0.4)
    keys('C-u'); text(W + '/b16.yaml'); keys('Enter'); time.sleep(1.0)
    check('57 base16 theme imported', os.path.exists(CFG + '/ned/themes/test-sixteen.json'), str(os.listdir(CFG + '/ned/themes')))
    open(W + '/evil.json', 'w').write('{"name": "../../Evil Theme", "colors": {"editor.background": "#000001"}}')
    palette('Theme: import a VS Code'); time.sleep(0.4)
    keys('C-u'); text(W + '/evil.json'); keys('Enter'); time.sleep(1.0)
    check('57 theme names cannot leave the themes folder', os.path.exists(CFG + '/ned/themes/evil-theme.json') and
          not os.path.exists(CFG + '/Evil Theme.json') and not os.path.exists(CFG + '/../Evil Theme.json'), str(os.listdir(CFG + '/ned/themes')))
    palette('Theme: make my own copy'); time.sleep(0.8)
    keys('C-s'); time.sleep(0.3)
    first = open(CFG + '/ned/themes/evil-theme-mine.json').read()
    open(CFG + '/ned/themes/evil-theme-mine.json', 'w').write(first.replace('"#000001"', '"#000002"'))
    palette('Theme: make my own copy'); time.sleep(0.8)
    check('57 a second copy keeps your changes', '"#000002"' in open(CFG + '/ned/themes/evil-theme-mine.json').read())
    setup({"theme": "auto", "theme.light": "github-light", "theme.dark": "nim-crown"})
    start('src/demo.nim', w=100, h=24); time.sleep(0.5)
    tm('send-keys', '-t', 'f', '-l', '\x1b]11;rgb:ffff/ffff/ffff\x07'); time.sleep(0.8)
    a = tm('capture-pane', '-t', 'f', '-e', '-p').stdout
    check('57 auto picks the light theme on a light terminal', '48;2;255;255;255' in a)

def t_57_ai():
    # undo the assistant's changes, big-request question, cost, fast model, review into Problems, Nim definitions
    setup({"ai.autoApprove": "all", "ai.price": {"input": 3, "output": 15}, "ai.fastModel": "gpt-6-mini"})
    utils = W + '/src/demo/utils.nim'
    before = open(utils).read()
    start('src/demo/utils.nim', w=130, h=34)
    keys('M-c'); time.sleep(0.4); text('add a doc comment to shout'); keys('Enter')
    wait_for('Tool said', 30); time.sleep(0.5)
    changed = open(utils).read() != before
    check('57 agent edited the file', changed, screen())
    check('57 cost shown with ai.price', wait_for(r'\$0\.\d', 20), screen())     # at the panel's foot, once the toasts go
    palette("AI: undo the assistant"); time.sleep(0.6); keys('Enter'); time.sleep(0.4); keys('y'); time.sleep(1.0)
    check('57 undo puts the file back', open(utils).read() == before, open(utils).read()[:300])
    check('57 fast/smart button', 'smart' in screen(), screen())
    palette('AI: fast / smart model'); time.sleep(0.4)
    check('57 fast model chosen', 'gpt-6-mini' in screen(), screen())
    # the request carries the Nim definitions the code uses
    setup()
    start('src/demo.nim', w=130, h=34)
    keys('C-g'); text('10'); keys('Enter'); time.sleep(0.5)
    keys('M-c'); time.sleep(0.4); text('what does this print'); keys('Enter'); time.sleep(2.0)
    log = open(MOCK_LOG).read()
    check('57 Nim definitions sent along', '<definitions' in log[-20000:] and 'shout' in log[-20000:], log[-1500:])
    # big requests ask first
    setup({"ai.warnTokens": 10})
    start('src/demo.nim', w=130, h=34)
    keys('M-c'); time.sleep(0.4); text('hello'); keys('Enter'); time.sleep(0.8)
    check('57 big request asks first', 'tokens' in screen() and 'send it?' in screen(), screen())
    keys('n'); time.sleep(0.4)
    # review staged changes → Problems
    setup()
    open(W + '/src/demo.nim', 'a').write('\necho greet("")\n')
    git('add -A')
    start('src/demo.nim', w=130, h=34)
    palette('AI: review staged'); time.sleep(3.0)
    s = screen()
    check('57 review findings in Problems', 'greet ignores empty names' in s, s)

def t_57_nim():
    # run configurations, run with arguments, what can this proc raise, benchmark, nimble release
    setup()
    open(W + '/src/eff.nim', 'w').write('import std/strutils\nproc load(p: string): int =\n  let s = readFile(p)\n  result = parseInt(s.strip)\n\nproc fib(n: int): int =\n  if n < 2: n else: fib(n - 1) + fib(n - 2)\n\necho fib(10)\n')
    start('src/eff.nim', w=130, h=34)
    keys('C-g'); text('3'); keys('Enter'); time.sleep(0.3)
    palette('Nim: what can this proc raise'); time.sleep(0.3)
    check('57 raises dialog', wait_for('IOError', 25) and 'ValueError' in screen(), screen())
    keys('Escape'); time.sleep(0.3)
    palette('Nim: benchmark a call'); time.sleep(0.4)
    keys('C-u'); text('fib(15)'); keys('Enter')
    check('57 benchmark result', wait_for('per call', 60), screen())
    keys('Escape'); time.sleep(0.3)
    palette('Run: configurations'); time.sleep(0.5)
    text('Add a configuration'); keys('Enter'); time.sleep(0.4)
    keys('C-u'); text('fast'); keys('Enter'); time.sleep(0.3)
    text('7 8 9'); keys('Enter'); time.sleep(1.0)
    check('57 run configuration saved', 'run.configs' in open(W + '/.ned/settings.json').read(), screen())
    check('57 status bar shows it', '▶ fast' in screen(), screen())
    keys('M-r'); time.sleep(0.6)
    check('57 Alt+R runs the configuration with its arguments', wait_for(r'eff\.nim.? 7 8 9|7 8 9', 20), screen())
    # nimble release: version, commit, tag (the push fails without a remote: fine)
    setup()
    start('src/demo.nim', w=130, h=34)
    palette('Nimble: release a new version'); time.sleep(0.8)
    keys('Enter'); time.sleep(0.4); keys('y'); time.sleep(3)
    check('57 nimble version bumped', '0.1.1' in open(W + '/demo.nimble').read(), screen())
    check('57 tag created', 'v0.1.1' in subprocess.run(['git', '-C', W, 'tag'], capture_output=True, text=True).stdout)
    # quitting while the compiler is still working leaves no helper file in the project
    start('src/demo.nim', w=130, h=34)
    keys('C-g'); text('5'); keys('Enter'); time.sleep(0.3)
    palette('Nim: what can this proc raise'); time.sleep(0.15)
    keys('C-q'); time.sleep(1.5)
    check('57 no helper files left after quitting', not [f for f in os.listdir(W + '/src') if f.startswith('ned_')], str(os.listdir(W + '/src')))

def t_57_git():
    # interactive rebase (drop one), cherry-pick from a branch, compare with a branch, branch graph
    setup()
    for i in range(1, 4):
        open(W + '/f%d.txt' % i, 'w').write('x%d\n' % i)
        git('add -A'); git('commit -qm "commit %d"' % i)
    start('src/demo.nim', w=130, h=34)
    palette('Git: interactive rebase'); time.sleep(0.8)
    text('init'); keys('Enter'); time.sleep(0.8)
    s = screen()
    check('57 rebase plan opens', 'pick' in s and 'commit 2' in s, s)
    keys('C-g'); text('7'); keys('Enter'); keys('Home')
    for _ in range(4): keys('Delete')
    text('drop'); keys('C-s'); time.sleep(0.5); keys('y'); time.sleep(2.0)
    log = subprocess.run(['git', '-C', W, 'log', '--format=%s'], capture_output=True, text=True).stdout
    check('57 rebase dropped commit 2', 'commit 2' not in log and 'commit 3' in log, log + screen())
    git('checkout -qb other'); open(W + '/o.txt', 'w').write('o\n'); git('add -A'); git('commit -qm "only on other"')
    git('checkout -q master')
    palette('Git: branches'); time.sleep(0.6); keys('Escape')       # refresh the branch name
    palette('Git: cherry-pick from a branch'); time.sleep(0.8)
    text('other'); keys('Enter'); time.sleep(0.8); keys('Enter'); time.sleep(0.4); keys('y'); time.sleep(1.5)
    log = subprocess.run(['git', '-C', W, 'log', '--format=%s'], capture_output=True, text=True).stdout
    check('57 cherry-picked', 'only on other' in log, log)
    git('checkout -qb third'); open(W + '/t.txt', 'w').write('t\n'); git('add -A'); git('commit -qm "third commit"')
    palette('Git: branches'); time.sleep(0.6); keys('Escape')
    palette('Git: compare with a branch'); time.sleep(0.8)
    text('master'); keys('Enter'); time.sleep(1.0)
    s = screen()
    check('57 compare lists the files', 't.txt' in s, s)
    keys('Enter'); time.sleep(1.0)
    check('57 compare opens a diff', 'Diff:' in screen() or 'vs master' in screen(), screen())
    palette('Git: branch graph'); time.sleep(1.0)
    s = screen()
    check('57 branch graph', 'Branch graph' in s and '*' in s and 'third commit' in s, s)

def t_571_rulers():
    # off by default · View › Rulers: 80 · hide/show · columns 40, 60 · long lines tinted · colour override
    setup()
    open(W + '/src/long.nim', 'w').write('proc a() =\n  echo "short"\n  echo "this line is long enough to go past both rulers, quite a lot past them"\n')
    start('src/long.nim', w=120, h=16); time.sleep(0.5)
    check('571 no rulers by default', '\u258f' not in screen(), screen())
    palette('View: toggle rulers'); time.sleep(0.5)
    s = screen()
    check('571 View › Rulers puts one at column 80', s.splitlines()[3].find('\u258f') == 86 and '"editor.rulers"' in open(CFG + '/ned/config.json').read(), s)
    palette('View: toggle rulers'); time.sleep(0.4)
    check('571 toggling hides them', '\u258f' not in screen(), screen())
    palette('View: toggle rulers'); time.sleep(0.4)
    check('571 and shows them again', '\u258f' in screen(), screen())
    palette('View: set ruler columns'); time.sleep(0.4)
    keys('C-u'); text('40, 60'); keys('Enter'); time.sleep(0.5)
    s = screen()
    check('571 two rulers', s.splitlines()[3].count('\u258f') == 2, s)
    a = tm('capture-pane', '-t', 'f', '-e', '-p').stdout
    check('571 the long line is tinted past the last ruler', '48;2;47;42;32' in a.splitlines()[5], a.splitlines()[5][-400:])
    check('571 short lines are not tinted', '48;2;47;42;32' not in a.splitlines()[4])
    setup({"editor.rulers": [50], "theme.colors": {"ruler": "#ff0000"}})
    start('src/demo.nim', w=120, h=16); time.sleep(0.5)
    a = tm('capture-pane', '-t', 'f', '-e', '-p').stdout
    check('571 theme.colors ruler', '38;2;255;0;0m\u258f' in a, a[-500:])

def t_572_editorconfig():
    setup()
    open(W + '/.editorconfig', 'w').write('root = true\n\n[*]\nindent_style = space\nindent_size = 4\ntrim_trailing_whitespace = true\ninsert_final_newline = true\n\n[*.nim]\nindent_size = 3\n\n[{Makefile,*.mk}]\nindent_style = tab\ntab_width = 8\n\n[*.md]\ntrim_trailing_whitespace = false\n')
    open(W + '/notes.md', 'w').write('a  \nb')
    open(W + '/Makefile', 'w').write('all:\n\techo hi\n')
    open(W + '/src/ws.nim', 'w').write('let a = 1   \nlet b = 2\nlet c = 3')
    start('src/ws.nim', w=130, h=30); time.sleep(0.5)
    check('572 .editorconfig indent in the status bar', 'Spaces: 3 (EditorConfig)' in screen(), screen())
    keys('C-g'); text('3'); keys('Enter', 'End'); text(' # x'); keys('C-s'); time.sleep(0.5)
    check('572 trailing whitespace trimmed on every line, final newline added',
          open(W + '/src/ws.nim').read() == 'let a = 1\nlet b = 2\nlet c = 3 # x\n', repr(open(W + '/src/ws.nim').read()))
    palette('File: EditorConfig for this file'); time.sleep(0.5)
    s = screen()
    check('572 EditorConfig dialog lists the rules', 'indent_size' in s and '3' in s and '.editorconfig' in s, s)
    keys('Escape'); time.sleep(0.2)
    keys('C-p'); text('notes.md'); time.sleep(0.4); keys('Enter'); time.sleep(0.5)
    keys('C-g'); text('2'); keys('Enter', 'End'); text('c'); keys('C-s'); time.sleep(0.4)
    check('572 [*.md] keeps trailing spaces', open(W + '/notes.md').read() == 'a  \nbc\n', repr(open(W + '/notes.md').read()))
    keys('C-p'); text('Makefile'); time.sleep(0.4); keys('Enter'); time.sleep(0.5)
    check('572 Makefile: tabs, 8 wide', 'Tab Size: 8 (EditorConfig)' in screen(), screen())

def t_572_tasks():
    setup()
    open(W + '/Makefile', 'w').write('.PHONY: hello clean\nhello: ## say hello\n\techo made-it-$$((40+2))\nclean:\n\trm -f nothing\nVAR := 1\n%.o: %.c\n\tcc $<\n')
    open(W + '/package.json', 'w').write('{"name": "x", "scripts": {"greet": "echo npm-greets"}}')
    open(W + '/justfile', 'w').write('# build it\nbuild:\n    echo b\n_private:\n    echo p\n')
    start('src/demo.nim', w=130, h=34); time.sleep(0.4)
    keys('F4'); time.sleep(0.6)
    s = screen()
    check('572 tasks found', 'make: hello' in s and 'say hello' in s and 'npm: greet' in s and 'just: build' in s and
          'nimble: build' in s and '%.o' not in s and 'VAR' not in s and '_private' not in s, s)
    text('make: hello'); keys('Enter')
    check('572 a task runs in the output panel', wait_for('made-it-42', 10), screen())
    keys('Escape'); time.sleep(0.3)
    open(W + '/Makefile', 'a').write('')
    keys('F4'); time.sleep(0.3)
    check('572 F4 runs the last task again', wait_for('made-it-42', 10) and 'make hello' in screen(), screen())
    keys('S-F4'); time.sleep(0.6)
    s = screen()
    check('572 the last task comes first', s.find('make: hello') < s.find('npm: greet'), s)
    keys('Escape')

def t_572_errors():
    setup()
    open(W + '/src/bad.nim', 'w').write('proc foo(a: int, b: int): int = a + b\nproc foo(a: string, b: string): string = a & b\nlet x = foo(1, "a")\necho x\n')
    start('src/bad.nim', w=140, h=34); time.sleep(0.5)
    keys('C-s')
    ok = wait_for(r'"a" is string, foo wants b: int', 25)
    check('572 one-line explanation at the end of the line', ok, screen())
    palette('Show problems'); time.sleep(0.6)
    s = screen()
    check('572 follow-on errors are hidden', 'has no type' not in s and 'requires an initialization' not in s, s)
    keys('Escape'); time.sleep(0.2)
    keys('C-g'); text('3'); keys('Enter'); time.sleep(0.2)
    keys('M-h'); time.sleep(1.5)
    s = screen()
    check('572 hover shows the argument table', 'you gave' in s and 'foo wants' in s and '✗' in s, s)

def t_572_swatches():
    setup()
    open(W + '/src/colors.nim', 'w').write('const red = 0xFF0000\nlet css = "#00ff00"\nlet notColour = 0x12345\n')
    open(W + '/site.css', 'w').write('a { color: rgb(0, 0, 255); background: #fff; }\n')
    start('src/colors.nim', w=120, h=24); time.sleep(0.6)
    a = tm('capture-pane', '-t', 'f', '-e', '-p').stdout
    check('572 swatch before 0xFF0000', '38;2;255;0;0m■' in a, a[:600])
    check('572 swatch before "#00ff00"', '38;2;0;255;0m■' in a)
    check('572 no swatch for other numbers', screen().splitlines()[5].count('■') == 0, screen())
    line = [l for l in screen().splitlines() if 'const red' in l][0]
    y = screen().splitlines().index(line) + 1
    x = line.index('■') + 1
    click(x, y); time.sleep(0.5)
    s = screen()
    check('572 clicking a swatch offers notations', 'Copy #ff0000' in s and 'rgb(255, 0, 0)' in s and 'Lighter' in s, s)
    text('Lighter'); keys('Enter'); time.sleep(0.4)
    check('572 lighter rewrites the literal', '0xFF2929' in screen(), screen())
    keys('C-p'); text('site.css'); time.sleep(0.4); keys('Enter'); time.sleep(0.6)
    a = tm('capture-pane', '-t', 'f', '-e', '-p').stdout
    check('572 css rgb() and #fff swatches', '38;2;0;0;255m■' in a and '38;2;255;255;255m■' in a, a[:800])

def t_572_examples():
    setup()
    open(W + '/src/ex.nim', 'w').write('import std/strutils\n\nproc shout*(s: string): string =\n  ## shouts\n  runnableExamples:\n    assert shout("hi") == "HI!"\n  s & "!"\n\nproc whisper*(s: string): string =\n  runnableExamples:\n    import std/strutils\n    doAssert whisper("A").startsWith("a")\n  s.toLowerAscii\n')
    start('src/ex.nim', w=140, h=34); time.sleep(0.5)
    palette('Nim: run all examples in this file')
    ok = wait_for(r'example failed|failed', 60)
    s = screen()
    check('572 a failing example is reported on its own line', ok and 'ex.nim(6' in s, s)
    keys('C-g'); text('7'); keys('Enter', 'Home'); text('s.toUpperAscii & "!"'); keys('S-End', 'Delete')
    time.sleep(0.2)
    keys('C-g'); text('6'); keys('Enter')
    palette('Nim: run the examples at the cursor')
    check('572 fixed: the examples pass', wait_for('pass', 60), screen())
    check('572 no helper files left', not [f for f in os.listdir(W + '/src') if f.startswith('ned_')], str(os.listdir(W + '/src')))

def t_59_small():
    setup()
    open(W + '/src/guides.nim', 'w').write('proc a() =\n  if true:\n    echo 1\n    echo 2\n  echo 3\n')
    start('src/guides.nim', w=110, h=24); time.sleep(0.4)
    keys('C-g'); text('3'); keys('Enter'); time.sleep(0.3)
    a = tm('capture-pane', '-t', 'f', '-e', '-p').stdout
    cols = set(re.findall(r'38;2;(\d+;\d+;\d+)m[^\x1b]*│', a))
    check('59 the active indent guide is brighter', len(cols) >= 2, str(cols))
    open(W + '/src/m.go', 'w').write('package main\n\nfunc main() {}\n')
    keys('C-p'); text('m.go'); time.sleep(0.4); keys('Enter')
    check('59 a missing language server is named, with its install command', wait_for('gopls', 6), screen())
    open(W + '/src/cv.nim', 'w').write('import std/strutils\nconst N = 1 shl 10\nconst Names = ["a", "b"].join("-")\nlet price = 3\necho len("hello") * 2\nlet k = 40 + 2\necho k\necho k * 2\nlet name = "Ann"\necho "Hello, " & name & "!"\n')
    tm('kill-server'); time.sleep(0.3)
    start('src/cv.nim', w=110, h=24); time.sleep(0.4)
    keys('C-g'); text('2:7'); keys('Enter'); time.sleep(0.2)
    palette('Nim: evaluate at compile time')
    check('59 evaluate a const', wait_for(r'= 1024[\s\S]*Copy[\s▌▐]+OK', 30), screen())   # (the dialog, not the hover)
    keys('Escape'); time.sleep(0.2)
    keys('C-g'); text('5:6'); keys('Enter'); time.sleep(0.2)
    for _ in range(12): keys('S-Right')
    keys('C-p'); text('>Refactor: extract into a variable'); time.sleep(0.4); keys('Enter'); time.sleep(0.4)   # (Esc would drop the selection)
    keys('Enter'); time.sleep(0.4)
    keys('C-s'); time.sleep(0.4)
    src = open(W + '/src/cv.nim').read()
    check('59 extract variable', 'let lenResult = len("hello")\necho lenResult * 2' in src, src)
    keys('C-g'); text('7:5'); keys('Enter'); time.sleep(0.2)
    palette('Nim: inline variable'); time.sleep(0.4); keys('C-s'); time.sleep(0.4)
    src = open(W + '/src/cv.nim').read()
    check('59 inline variable', 'echo (40 + 2)\necho (40 + 2) * 2' in src and 'let k' not in src, src)
    keys('C-g'); text('10:8'); keys('Enter'); time.sleep(0.2)
    palette('Nim: use fmt for this string'); time.sleep(0.4); keys('C-s'); time.sleep(0.4)
    src = open(W + '/src/cv.nim').read()
    check('59 "a" & x becomes fmt', 'echo fmt"Hello, {name}!"' in src and 'strformat' in src, src)

def t_59_html():
    setup()
    open(W + '/page.html', 'w').write('<div class="a">\n  <p>hi</p>\n</div>\n<b>x</b>\n')
    start('page.html', w=110, h=24); time.sleep(0.4)
    keys('C-g'); text('1:5'); keys('Enter'); time.sleep(0.2)
    keys('BSpace', 'BSpace', 'BSpace'); text('section'); time.sleep(0.2)
    keys('C-s'); time.sleep(0.3)
    src = open(W + '/page.html').read()
    check('59 renaming an opening tag renames its closing tag', src.startswith('<section class="a">') and '</section>' in src, src)
    keys('C-g'); text('4:8'); keys('Enter'); time.sleep(0.2)
    keys('BSpace'); text('strong'); keys('C-s'); time.sleep(0.3)
    src = open(W + '/page.html').read()
    check('59 and a closing tag its opening one', '<strong>x</strong>' in src, src)
    keys('C-z'); time.sleep(0.2)
    mid = buf_text = tm('capture-pane', '-t', 'f', '-p').stdout
    keys('C-z'); keys('C-s'); time.sleep(0.3)
    check('59 undo puts both back (the typing, then the deleting)', '<b>x</b>' in open(W + '/page.html').read(), open(W + '/page.html').read())
    keys('C-g'); text('5'); keys('Enter'); text('ul>li.item$*3'); keys('Tab'); text('one'); keys('C-s'); time.sleep(0.3)
    src = open(W + '/page.html').read()
    check('59 Emmet expands with Tab', '<ul>\n  <li class="item1">one</li>\n  <li class="item2"></li>\n  <li class="item3"></li>\n</ul>' in src, src)
    keys('End', 'Enter'); time.sleep(0.1)
    keys('C-a'); keys('Delete'); text('!'); keys('Tab'); keys('C-s'); time.sleep(0.3)
    src = open(W + '/page.html').read()
    check('59 ! makes a whole page', src.startswith('<!DOCTYPE html>') and '<title>Document</title>' in src, src)

def t_59_problems_mb():
    setup()
    open(W + '/src/bad.nim', 'w').write('proc foo(a: int, b: int): int = a + b\nlet x = foo(1, "a")\necho x\n')
    start('src/bad.nim', w=120, h=30); time.sleep(0.4)
    keys('C-s')
    wait_for('foo wants', 25)
    palette('Problems: all of them with their code'); time.sleep(0.8)
    s = screen()
    check('59 problems in a multibuffer with their messages', 'Multibuffer: Problems' in s and 'foo wants b: int' in s, s)

def t_59_lsp_more():
    setup({"lsp": {"python": ["python3", MOCKS + "/mocklsp.py"]}})
    open(W + '/shapes.py', 'w').write('class Shape:\n    pass\n\nclass Circle(Shape):\n    pass\n\nclass Square(Shape):\n    pass\n\nx = 1\nprint(x)\n\ndef f():\n    a = 1\n    b = 2\n    return a + b\n')
    start('shapes.py', w=110, h=26); time.sleep(1.5)
    keys('C-g'); text('11:7'); keys('Enter'); time.sleep(0.2)
    palette('Go to type definition'); time.sleep(0.6)
    check('59 go to type definition', status_pos() == (1, 7), screen())
    palette('Go to implementation'); time.sleep(0.6)
    s = screen()
    check('59 implementations listed', 'Implementation (2)' in s and 'shapes.py:4' in s and 'shapes.py:7' in s, s)
    keys('Escape')
    palette('Type hierarchy'); time.sleep(0.8)
    s = screen()
    check('59 type hierarchy', '↑ Base' in s and '↓ Circle' in s, s)
    keys('Escape')
    keys('C-g'); text('10:1'); keys('Enter'); time.sleep(0.8)
    a = tm('capture-pane', '-t', 'f', '-e', '-p').stdout.splitlines()
    pl = [l for l in a if 'print' in l][0]
    check('59 the server marks the uses of the symbol', len(set(re.findall(r'48;2;\d+;\d+;\d+', pl))) >= 2, pl)
    keys('C-g'); text('13'); keys('Enter'); time.sleep(0.3)
    palette('Fold'); time.sleep(0.4)
    s = screen()
    check('59 folding from the server', '⋯ 3 lines' in s and 'b = 2' not in s, s)
    palette('Unfold'); time.sleep(0.3)
    keys('C-g'); text('14'); keys('Enter'); keys('S-Down'); time.sleep(0.2)
    keys('M-f'); time.sleep(0.8)
    check('59 format selection through the server', '# formatted' in screen(), screen())

def t_59_langs_tests():
    need('pytest', 'go')
    setup({"languages": {"zig": {"name": "Zig", "extensions": ["zig"], "lineComment": "//", "keywords": "fn const pub return",
                                 "types": "u8 i32", "functionWords": "fn"}}})
    open(W + '/a.zig', 'w').write('// hi\npub fn main() void {\n    const x: i32 = 1;\n    return;\n}\n')
    os.makedirs(W + '/tests', exist_ok=True)
    open(W + '/tests/test_calc.py', 'w').write('def add(a, b):\n    return a + b\n\ndef test_add():\n    assert add(1, 2) == 3\n\ndef test_bad():\n    assert add(1, 1) == 3\n\nclass TestMore:\n    def test_zero(self):\n        assert add(0, 0) == 0\n')
    os.makedirs(W + '/gop', exist_ok=True)
    open(W + '/gop/go.mod', 'w').write('module x\n\ngo 1.20\n')
    open(W + '/gop/x_test.go', 'w').write('package x\n\nimport "testing"\n\nfunc TestOk(t *testing.T) {}\n\nfunc TestFail(t *testing.T) { t.Fatal("no") }\n')
    start('a.zig', w=120, h=30); time.sleep(0.5)
    s = screen()
    check('59 a language from settings', ' Zig ' in s, s)
    a = tm('capture-pane', '-t', 'f', '-e', '-p').stdout
    check('59 its keywords are coloured', re.search(r'38;2;\d+;\d+;\d+m(\x1b\[[0-9;]*m)*pub', a) is not None and '//' in s, a[:400])
    keys('C-p'); text('test_calc.py'); time.sleep(0.4); keys('Enter'); time.sleep(0.5)
    s = screen()
    check('59 ▶ beside Python tests', s.count('▶') >= 3, s)
    palette('Run tests in file')
    wait_for('failed in test_calc', 40)
    time.sleep(0.5)
    s = screen()
    lines = s.splitlines()
    ok = any('✓' in l and 'def test_add' in l for l in lines) and any('✗' in l and 'def test_bad' in l for l in lines) and \
         any('✓' in l and 'def test_zero' in l for l in lines)
    check('59 pytest results in the gutter', ok, s)
    keys('Escape'); keys('C-p'); text('x_test.go'); time.sleep(0.4); keys('Enter'); time.sleep(0.5)
    palette('Run tests in file')
    wait_for('failed in x_test', 60)
    time.sleep(0.5)
    s = screen()
    lines = s.splitlines()
    check('59 go test results in the gutter', any('✓' in l and 'TestOk' in l for l in lines) and
          any(('✗' in l or '●' in l) and 'TestFail' in l for l in lines), s)   # ● the failure's line

def t_59_ai_more():
    setup({"ai.autoApprove": "all", "ai.mcpServers": {"demo": {"command": "python3", "args": [MOCKS + "/mockmcp.py"],
                                                                "env": {"DEMO_TOKEN": "s3cret"}}}})
    start('src/demo.nim', w=130, h=34); time.sleep(0.5)
    keys('M-c'); time.sleep(0.4); text('use the echo tool'); keys('Enter')
    check('59 the agent uses an MCP server tool', wait_for('echo: pong token=s3cret', 20), screen())
    leaked = ''
    for d in os.listdir('/proc'):
        if d.isdigit():
            try:
                if b's3cret' in open('/proc/%s/cmdline' % d, 'rb').read(): leaked += d + ' '
            except Exception: pass
    check('59 the server token is not on any command line', leaked == '', leaked)
    palette('AI: MCP servers')
    ok = wait_for('2 tool.s.', 10)
    s = screen()
    check('59 MCP servers listed with their tools', ok and 'demo' in s, s)
    keys('Escape')
    setup({"ai.autoApprove": "all"})
    start('src/demo/utils.nim', w=130, h=34); time.sleep(0.5)
    keys('M-c'); time.sleep(0.4); text('add a doc comment to shout'); keys('Enter')
    wait_for('Tool said', 30); time.sleep(0.5)
    palette("AI: review the assistant's changes"); time.sleep(0.8)
    s = screen()
    check("59 review the assistant's changes as a diff", "the assistant's change" in s and 'before the assistant' in s, s)

def t_59_dap():
    need('gdb', 'debugpy')
    # a TCP adapter (like delve), configured in settings
    setup({"debug.adapters": {"go": {"command": ["python3", MOCKS + "/mockdap.py", "$port"], "connect": True,
                                     "launch": {"program": "$file"}}}})
    os.makedirs(W + '/gop', exist_ok=True)
    open(W + '/gop/main.go', 'w').write('package main\n\nfunc main() {\n\tanswer := 42\n\tprintln(answer)\n}\n')
    start('gop/main.go', w=130, h=50); time.sleep(0.5)
    keys('C-g'); text('5'); keys('Enter'); keys('F9'); time.sleep(0.2)
    keys('F5')
    ok = wait_for('stopped', 15)
    time.sleep(0.8)
    s = screen()
    check('59 DAP: stopped at the breakpoint', ok and 'main.compute' in s and 'answer: int = 42' in s, s)
    check('59 DAP: the program output', 'hello from the debuggee' in s, s)
    check('59 inline values at the end of the line', 'answer = 42' in [l for l in s.splitlines() if 'println(answer)' in l][0], s)
    keys('F10'); time.sleep(1.0)
    check('59 DAP: the program ends', 'exited with code 3' in screen(), screen())
    # Python with debugpy
    setup()
    open(W + '/prog.py', 'w').write('def total(items):\n    s = 0\n    for x in items:\n        s += x\n    return s\n\nnums = [1, 2, 3]\nprint(total(nums))\n')
    start('prog.py', w=130, h=34); time.sleep(0.5)
    keys('C-g'); text('4'); keys('Enter'); keys('F9'); time.sleep(0.2)
    keys('F5')
    ok = wait_for(r'stopped', 25)
    time.sleep(1.5)
    s = screen()
    check('59 debugpy: stopped in total() with its variables', ok and 'total' in s and 'items' in s and 's: int = 0' in s, s)
    keys('F5'); time.sleep(1.2)
    check('59 debugpy: continue stops again with the new value', 's: int = 1' in screen(), screen())
    keys('S-F5'); time.sleep(1.0)
    # C with gdb's DAP mode
    setup()
    open(W + '/m.c', 'w').write('#include <stdio.h>\nint main(void) {\n    int a = 2;\n    int b = a * 21;\n    printf("%d\\n", b);\n    return 0;\n}\n')
    start('m.c', w=130, h=34); time.sleep(0.5)
    keys('C-g'); text('5'); keys('Enter'); keys('F9'); time.sleep(0.2)
    keys('F5')
    ok = wait_for('stopped', 30)
    time.sleep(1.5)
    s = screen()
    check('59 gdb -i dap: C stopped with its variables', ok and 'b: int = 42' in s, s)
    keys('S-F5'); time.sleep(0.5)

def shift_enter(): tm('send-keys', '-t', 'f', '-l', '\x1b[13;2u'); time.sleep(0.3)

def t_510_large():
    setup({"editor.largeFileSize": 1})
    with open(W + '/big.log', 'w') as f:
        for i in range(30000): f.write('2026-10-12 INFO request %06d path=/api/items/%d status=200\n' % (i, i))
    start('big.log', w=130, h=34); time.sleep(0.8)
    check('510 a big file opens in large-file mode', 'Large file' in screen(), screen())
    keys('M-w'); time.sleep(0.4)
    check('510 soft wrap stays off in a large file', 'No soft wrap in this file' in screen(), screen())
    palette('Large file mode: on/off'); time.sleep(0.4)
    check('510 large-file mode can be turned off for the file', 'Large file ' not in screen().splitlines()[-1], screen())
    setup()
    open(W + '/min.json', 'w').write('[' + ','.join('{"id":%d,"v":"x%d"}' % (i, i) for i in range(2000)) + ']\n')
    start('min.json', w=130, h=34); time.sleep(0.8)
    check('510 a very long line: large-file mode', 'Large file' in screen(), screen())
    keys('C-End'); keys('Left'); text('ZZ'); keys('C-s'); time.sleep(0.5)
    t = ftext('min.json')
    check('510 typing at the end of a long line', t.endswith('}ZZ]\n') and t.count('"id"') == 2000, t[-60:])

def t_510_debug_tools():
    need('gdb', 'lldb')
    setup()
    open(W + '/app.js', 'w').write('function total(items) {\n  let s = 0;\n  for (const x of items) {\n    s += x;\n  }\n  return s;\n}\nconst nums = [1, 2, 3];\nconsole.log("sum", total(nums));\n')
    open(W + '/m.c', 'w').write('int main(void) { return 0; }\n')
    os.makedirs(W + '/gop', exist_ok=True)
    open(W + '/gop/main.go', 'w').write('package main\n\nfunc main() {}\n')
    start('gop/main.go', w=130, h=40); time.sleep(0.5)
    palette('Debug: check the debugger for this file'); time.sleep(1.0)
    s = screen()
    check('510 debugger check: delve is missing, with how to install it', 'delve' in s and 'not installed' in s and 'go install github.com/go-delve/delve/cmd/dlv@latest' in s, s)
    keys('C-o'); time.sleep(0.3); text('m.c'); keys('Enter'); time.sleep(0.6)
    palette('Debug: check the debugger for this file'); wait_for('F5 uses: gdb', 6.0)
    s = screen()
    check('510 debugger check: gdb 14+ speaks DAP', 'F5 uses: gdb (DAP mode)' in s and '✓ gdb (DAP mode)' in s, s)
    keys('C-o'); time.sleep(0.3); text('m.c'); keys('Enter'); time.sleep(0.6)
    palette('Debug: choose the debugger for this language'); time.sleep(0.6)
    text('lldb-dap'); time.sleep(0.3); keys('Enter'); time.sleep(0.5)
    c = json.load(open(CFG + '/ned/config.json'))
    check('510 choose the debugger: saved in settings', c.get('debug.adapters', {}).get('c', {}).get('name') == 'lldb-dap', json.dumps(c)[:300])
    open(W + '/m.c', 'w').write('#include <stdio.h>\nint main(void) {\n    int a = 2;\n    int b = a * 21;\n    printf("%d\\n", b);\n    return 0;\n}\n')
    keys('Escape'); palette('Reload from disk'); time.sleep(0.4)
    keys('C-g'); text('5'); keys('Enter'); keys('F9'); time.sleep(0.2)
    keys('F5')
    ok = wait_for('stopped', 30) and wait_for('b: int = 42', 10)
    check('510 lldb-dap: a C program stops with its variables', ok, screen())
    keys('S-F5'); time.sleep(2)
    z = [l for l in sh('ps ax -o stat=,comm=').stdout.splitlines() if l.startswith('Z') and 'lldb-dap' in l]
    check('510 the debug adapter is not left as a zombie', not z, str(z))
    # JavaScript and TypeScript with vscode-js-debug
    setup()
    open(W + '/app.js', 'w').write('function total(items) {\n  let s = 0;\n  for (const x of items) {\n    s += x;\n  }\n  return s;\n}\nconst nums = [1, 2, 3];\nconsole.log("sum", total(nums));\n')
    start('app.js', w=130, h=40); time.sleep(0.5)
    keys('C-g'); text('4'); keys('Enter'); keys('F9'); time.sleep(0.2)
    keys('F5')
    ok = wait_for('stopped', 30); time.sleep(1.5)
    s = screen()
    check('510 js-debug: stopped in total() with its variables', ok and 's: number = 0' in s and 'items: Array' in s, s)
    keys('F5'); time.sleep(1.5)
    check('510 js-debug: continue stops again', 's: number = 1' in screen(), screen())
    keys('S-F5'); time.sleep(1.5)
    check('510 js-debug: no adapter left running', 'dapDebugServer' not in sh('ps ax -o args').stdout)
    setup()
    open(W + '/app.ts', 'w').write('function total(items: number[]): number {\n  let s: number = 0;\n  for (const x of items) {\n    s += x;\n  }\n  return s;\n}\nconsole.log("sum", total([1, 2, 3]));\n')
    start('app.ts', w=130, h=40); time.sleep(0.5)
    keys('C-g'); text('4'); keys('Enter'); keys('F9'); time.sleep(0.2)
    keys('F5')
    ok = wait_for('stopped', 30); time.sleep(1.5)
    check('510 js-debug: TypeScript too', ok and 's: number = 0' in screen(), screen())
    keys('S-F9'); time.sleep(0.2); keys('F5'); time.sleep(2.5)
    check('510 js-debug: the program runs to its end', 'sum 6' in screen() and 'exited' in screen(), screen())

def t_510_testament():
    def mk():
        os.makedirs(W + '/tests/cat', exist_ok=True)
        open(W + '/tests/cat/tgood.nim', 'w').write('discard """\n  output: \'\'\'\nhello\n42\n\'\'\'\n"""\necho "hello"\necho 6 * 7\n')
        open(W + '/tests/cat/tbad.nim', 'w').write('discard """\n  output: "yes"\n"""\necho "no"\n')
        open(W + '/tests/cat/treject.nim', 'w').write('discard """\n  action: "reject"\n  errormsg: "type mismatch"\n  line: 6\n"""\nlet x: int = "s"\n')
    setup(); mk()
    start('tests/cat/tgood.nim', w=130, h=40); time.sleep(0.6)
    check('510 testament: ▶ on the spec line', '▶' in [l for l in screen().splitlines() if 'discard' in l and '›' not in l][0], screen())
    palette('Nim: testament'); time.sleep(0.3)
    ok = wait_for('1 testament test.s. failed', 90)
    s = screen()
    check('510 testament (installed): runs and reports', ok, s)
    check('510 testament: the file shows its result on the spec line', '✓' in [l for l in screen().splitlines() if 'discard' in l and '›' not in l][0], screen())
    setup(); mk()
    start('tests/cat/tgood.nim', w=130, h=40, path=no_nim_dir() + ':/usr/bin:/bin'); time.sleep(0.6)
    palette('Nim: testament'); time.sleep(0.3)
    ok = wait_for('passed, [0-9]+ failed', 90)
    s = screen()
    check("510 testament (ned's runner): judges output and reject specs",
          ok and 'PASS: tests/cat/tgood.nim' in s and 'FAIL: tests/cat/tbad.nim' in s and 'PASS: tests/cat/treject.nim' in s and
          'the output differs' in s and '2 passed, 1 failed' in s, s)

def t_510_repl():
    setup()
    open(W + '/a.py', 'w').write('import math\n\ndef area(r):\n    a = math.pi * r * r\n\n    return round(a, 2)\n\nprint(area(2))\nx = [i * i for i in range(5)]\nx\n')
    start('a.py', w=130, h=44); time.sleep(0.6)
    palette('REPL: send the whole file'); time.sleep(3)
    s = screen()
    check('510 REPL: a Python file runs (bracketed paste, Python 3.13)', '12.57' in s and '[0, 1, 4, 9, 16]' in s, s)
    check('510 REPL: the keyboard stays in the editor', 'Ln 1,' in s.splitlines()[-1], s)
    keys('C-g'); text('3'); keys('Enter'); shift_enter(); time.sleep(1)
    check('510 Shift+Enter sends the def and moves past it', 'Ln 8,' in screen().splitlines()[-1], screen())
    shift_enter(); time.sleep(1.2)
    check('510 Shift+Enter: the next statement runs', screen().count('12.57') >= 2, screen())
    # an older Python (no bracketed paste): blank lines inside a block are dropped, a blank line ends it
    setup({"repl.commands": {"python": "python3.11 -q"}})
    open(W + '/a.py', 'w').write('import math\n\ndef area(r):\n    a = math.pi * r * r\n\n    return round(a, 2)\nprint(area(3))\nfor i in range(2):\n    print("row", i)\nprint("done")\n')
    start('a.py', w=130, h=44); time.sleep(0.6)
    palette('REPL: send the whole file'); time.sleep(3)
    s = screen()
    if which('python3.11'): check('510 REPL: line by line for a REPL without bracketed paste', '28.27' in s and 'row 1' in s and 'done' in s and 'Error' not in s, s)
    # cells
    setup()
    open(W + '/c.py', 'w').write('# %% setup\nv = 20\n# %% use\nprint(v + 1)\n# %% other\nprint("other")\n')
    start('c.py', w=130, h=44); time.sleep(0.6)
    check('510 REPL: ▶ on each # %% cell', sum(1 for l in screen().splitlines() if '# %%' in l and '▶' in l) == 3, screen())
    shift_enter(); time.sleep(2.5)
    check('510 Shift+Enter in a cell file runs the cell and moves to the next', 'Ln 4,' in screen().splitlines()[-1], screen())
    shift_enter(); time.sleep(1.5)
    s = screen()
    check('510 REPL: the second cell sees the first', '21' in s and 'other' not in s.split('TERMINAL')[-1], s)
    # Nim: inim, else nim secret
    setup()
    open(W + '/r.nim', 'w').write('proc twice(x: int): int =\n  x * 2\n\necho twice(21)\n')
    start('r.nim', w=130, h=44, path=TOOLS + ':/usr/bin:/bin'); time.sleep(0.6)
    palette('REPL: send the whole file'); time.sleep(6)
    s = screen()
    if which('inim'): check('510 REPL: inim runs a Nim file', '42' in s.split('TERMINAL')[-1] and 'INim' in s, s)
    setup()
    open(W + '/r.nim', 'w').write('proc twice(x: int): int =\n  x * 2\n\necho twice(21)\n')
    start('r.nim', w=130, h=44, path=no_nim_dir() + ':/usr/bin:/bin'); time.sleep(0.6)
    palette('REPL: send the whole file'); time.sleep(8)
    s = screen()
    check('510 REPL: nim secret when inim is not installed', '42' in s.split('TERMINAL')[-1], s)
    # JavaScript: node
    setup()
    open(W + '/n.js', 'w').write('function f(a) {\n  return a * 3;\n}\nconsole.log("js", f(5));\n')
    start('n.js', w=130, h=44); time.sleep(0.6)
    palette('REPL: send the whole file'); time.sleep(3)
    check('510 REPL: node', 'js 15' in screen(), screen())

def t_510_nimble_outdated():
    setup()
    open(W + '/demo.nimble', 'a').write('requires "jsony >= 1.0.0", "other >= 2.0.0"\nrequires "jsonyAlias#head"\n')
    start('demo.nimble', w=130, h=40, env_extra='NIMBLE_DIR=' + fake_nimble_dir()); time.sleep(0.5)
    palette('Nimble: newer versions of the dependencies')
    ok = wait_for('with a newer version', 20)
    s = screen()
    check('510 nimble: newer versions from the git tags', ok and '1.2.0 available' in s and 'installed 1.1.0' in s, s)
    check('510 nimble: up to date and pinned ones listed too', 'up to date (latest 2.0.0)' in s and 'pinned to #head' in s, s)
    text('jsony >='); time.sleep(0.3); keys('Enter'); time.sleep(0.8)
    t = ftext('demo.nimble')
    check('510 nimble: choosing one moves its requirement up', '"jsony >= 1.2.0", "other >= 2.0.0"' in t, t)
    check('510 nimble: then offers to install', 'Install now' in screen(), screen())

def t_510_merge_editor():
    setup()
    open(W + '/src/c.nim', 'w').write('let a = 1\n<<<<<<< HEAD\nlet b = 2\n=======\nlet b = 3\n>>>>>>> feature\necho a\n<<<<<<< HEAD\necho "ours"\n=======\necho "theirs"\necho "more"\n>>>>>>> feature\necho b\n')
    start('src/c.nim', w=140, h=44); time.sleep(0.5)
    check('510 merge: opening a file with conflicts offers the merge editor', '2 merge conflicts' in screen() and 'Merge editor' in screen(), screen())
    palette('Git: merge editor'); time.sleep(0.5)
    s = screen()
    check('510 merge: ours | theirs | result', 'Ours' in s and 'Theirs' in s and 'Result' in s and '2 conflicts left' in s and 'feature' in s, s)
    p = find_on_screen('Accept theirs ')
    if p: click(p[0] + 2, p[1]); time.sleep(0.5)
    check('510 merge: accept theirs from its pane', '1 conflict left' in screen(), screen())
    p = find_on_screen('Accept ours ')
    if p: click(p[0] + 2, p[1]); time.sleep(0.5)
    s = screen()
    check('510 merge: all resolved', 'no conflicts left' in s and 'Save and stage' in s, s)
    p = find_on_screen('Save and stage')
    if p: click(p[0] + 2, p[1]); time.sleep(1.0)
    t = ftext('src/c.nim')
    check('510 merge: the result saved', t == 'let a = 1\nlet b = 3\necho a\necho "ours"\necho b\n', repr(t))
    check('510 merge: and staged', 'src/c.nim' in git('diff --cached --name-only').stdout, git('status --short').stdout)

def t_510_spell():
    need('dictionary')
    setup({"editor.spellDictionary": spell_dict()})
    if os.path.exists(CFG + '/ned/words.txt'): os.remove(CFG + '/ned/words.txt')
    open(W + '/notes.md', 'w').write('# Notes\n\nThis paragraph has a mispelled word and teh other one.\nChecking colors, `badwordd` in code, and https://example.com/recieve stay quiet.\nWell-known words are fine.\n')
    start('notes.md', w=130, h=34); time.sleep(0.8)
    tm('capture-pane', '-t', 'f', '-e', '-p')
    raw = tm('capture-pane', '-t', 'f', '-e', '-p').stdout
    line = [l for l in raw.splitlines() if 'mispelled' in l][0]
    check('510 spell: a misspelled word in Markdown is underlined', re.search(r'\x1b\[4m(\x1b\[[0-9;]*m)*mispelled', line) and not re.search(r'\x1b\[4m(\x1b\[[0-9;]*m)*paragraph', line), repr(line))
    l2 = [l for l in raw.splitlines() if 'badwordd' in l][0]
    # (the URL is underlined as a whole, as a link — not its misspelled part)
    check('510 spell: code spans and URLs are left alone', not re.search(r'\x1b\[4m(\x1b\[[0-9;]*m)*`?badwordd', l2) and
          not re.search(r'\x1b\[4m(\x1b\[[0-9;]*m)*recieve', l2) and
          not re.search(r'\x1b\[4m(\x1b\[[0-9;]*m)*(Checking|colors|code|stay)', l2), repr(l2))
    palette('Spell check: next misspelled word'); time.sleep(0.4)
    check('510 spell: next misspelled word', '“mispelled”' in screen(), screen())
    keys('M-Enter'); time.sleep(0.6)
    s = screen()
    check('510 spell: Alt+Enter suggests the spelling', 'Change to “misspelled”' in s and 'Add “mispelled”' in s, s)
    text('Change to “misspelled”'[:12]); keys('Enter'); time.sleep(0.4)
    palette('Spell check: next misspelled word'); time.sleep(0.4)
    check('510 spell: then the next one', '“teh”' in screen(), screen())
    keys('M-Enter'); time.sleep(0.5); text('Add'); keys('Enter'); time.sleep(0.4)
    check('510 spell: add to your dictionary', 'teh' in open(CFG + '/ned/words.txt').read(), '')
    keys('C-s'); time.sleep(0.4)
    check('510 spell: the fix is in the file', 'a misspelled word' in ftext('notes.md'), ftext('notes.md'))
    # code: comments and strings only with "on"; names used in the code are not misspelled
    setup({"editor.spellDictionary": spell_dict()})
    open(W + '/src/sp.nim', 'w').write('proc frobnicate(x: int): int =\n  ## doubles the vaule; see frobnicate\n  let mesage = "a strng"\n  x * 2\n')
    start('src/sp.nim', w=130, h=34); time.sleep(0.8)
    palette('Spell check: next misspelled word'); time.sleep(0.4)
    check('510 spell: off for code by default', 'Spell check is off' in screen(), screen())
    palette('Spell check: where'); time.sleep(0.4); text('comments'); keys('Enter'); time.sleep(0.4)
    keys('C-Home'); palette('Spell check: next misspelled word'); time.sleep(0.4)
    check('510 spell: comments in code ("on")', '“vaule”' in screen(), screen())
    palette('Spell check: next misspelled word'); time.sleep(0.4)
    check('510 spell: strings too, but not the names in the code', '“strng”' in screen(), screen())

def t_510_coverage():
    def numcol(raw, n):
        for l in raw.splitlines():
            m = re.search(r'\x1b\[38;2;([0-9;]+)m\s*' + str(n) + r'\x1b', l)
            if m: return m.group(1)
        return None
    setup()
    open(W + '/calc.py', 'w').write('def f(a):\n    if a > 1:\n        return a * 2\n    return 0\n\nprint(f(5))\n')
    start('calc.py', w=130, h=34); time.sleep(0.6)
    palette('Test coverage: run'); ok = wait_for(r'Coverage \(coverage.py\): \d+% of', 30)
    raw = tm('capture-pane', '-t', 'f', '-e', '-p').stdout
    check('510 coverage: Python (coverage.py)', ok and numcol(raw, 3) and numcol(raw, 4) and numcol(raw, 3) != numcol(raw, 4), screen())
    setup()
    os.makedirs(W + '/gm', exist_ok=True)
    open(W + '/gm/go.mod', 'w').write('module example.com/gm\n\ngo 1.21\n')
    open(W + '/gm/calc.go', 'w').write('package gm\n\nfunc F(a int) int {\n\tif a > 1 {\n\t\treturn a * 2\n\t}\n\treturn 0\n}\n')
    open(W + '/gm/calc_test.go', 'w').write('package gm\n\nimport "testing"\n\nfunc TestF(t *testing.T) {\n\tif F(5) != 10 {\n\t\tt.Fatal("bad")\n\t}\n}\n')
    start('gm/calc.go', w=130, h=34); time.sleep(0.6)
    palette('Test coverage: run'); ok = wait_for(r'Coverage \(go test\): \d+% of', 60)
    raw = tm('capture-pane', '-t', 'f', '-e', '-p').stdout
    check('510 coverage: Go (go test -coverprofile)', ok and numcol(raw, 5) != numcol(raw, 7), screen())
    setup()
    open(W + '/app.js', 'w').write('function f(a) {\n  if (a > 1) {\n    return a * 2;\n  }\n  return 0;\n}\nconsole.log(f(5));\n')
    start('app.js', w=130, h=34); time.sleep(0.6)
    palette('Test coverage: run'); ok = wait_for(r'Coverage \(node\): \d+% of', 30)
    raw = tm('capture-pane', '-t', 'f', '-e', '-p').stdout
    check("510 coverage: JavaScript (Node's own)", ok and numcol(raw, 3) != numcol(raw, 5), screen())
    setup()
    os.makedirs(W + '/coverage', exist_ok=True)
    open(W + '/coverage/lcov.info', 'w').write('TN:\nSF:src/demo.nim\nDA:1,1\nDA:2,0\nend_of_record\n')
    start('src/demo.nim', w=130, h=34); time.sleep(0.6)
    palette('Test coverage: load an lcov file'); time.sleep(0.5)
    check('510 coverage: an lcov file from any tool', '50% of 2 lines' in screen(), screen())

def t_510_langs():
    FB = FIX + '/fakebin:' + TOOLS + ':/usr/bin:/bin:' + NODE_DIR
    setup()
    open(W + '/calc.php', 'w').write('<?php\n// adds\nfunction add(int $a, int $b): int {\n    return $a + $b;\n}\necho add(40, 2), "\\n";\n')
    open(W + '/q.sql', 'w').write('SELECT name FROM users WHERE id = 1;\n')
    open(W + '/m.kt', 'w').write('fun main() {\n    val x = listOf(1, 2)\n    println(x)\n}\n')
    open(W + '/P.cs', 'w').write('class P { static void Main() { System.Console.WriteLine(1); } }\n')
    start('calc.php', w=130, h=34, path=FB); time.sleep(0.5)
    check('510 PHP is recognised', 'PHP' in screen().splitlines()[-1], screen())
    palette('Run file'); ok = wait_for('Finished', 20)
    check('510 PHP: run the file', ok and '42' in screen(), screen())
    for f, name in [('q.sql', 'SQL'), ('m.kt', 'Kotlin'), ('P.cs', 'C#')]:
        keys('C-o'); time.sleep(0.3); text(f); keys('Enter'); time.sleep(0.5)
        check('510 %s is recognised' % name, (' ' + name + ' ') in screen().splitlines()[-1], screen().splitlines()[-1])
    keys('C-o'); time.sleep(0.3); text('q.sql'); keys('Enter'); time.sleep(0.4)
    keys('C-Home'); keys('C-_'); keys('C-s'); time.sleep(0.4)
    check('510 SQL: toggle comment uses --', ftext('q.sql').startswith('-- SELECT'), ftext('q.sql'))
    # test runners: PHPUnit, dotnet test, Gradle (stand-ins that write the real report formats)
    setup()
    os.makedirs(W + '/tests', exist_ok=True)
    open(W + '/composer.json', 'w').write('{}\n')
    open(W + '/tests/CalcTest.php', 'w').write('<?php\nuse PHPUnit\\Framework\\TestCase;\n\nfinal class CalcTest extends TestCase\n{\n    public function testAdds(): void\n    {\n        $this->assertSame(3, 1 + 2);\n    }\n\n    public function testFails(): void\n    {\n        $this->assertSame(4, 1 + 2);\n    }\n}\n')
    start('tests/CalcTest.php', w=130, h=34, path=FB); time.sleep(0.6)
    check('510 PHPUnit: ▶ on each test', sum(1 for l in screen().splitlines() if 'function test' in l and '▶' in l) == 2, screen())
    palette('Run tests in file'); wait_for('test.s. failed', 20); time.sleep(0.5)
    s = screen()
    ln = lambda w: [l for l in s.splitlines() if w in l][0]
    check('510 PHPUnit: results from its JUnit report', '✓' in ln('testAdds') and '✗' in ln('testFails'), s)
    setup()
    os.makedirs(W + '/Calc.Tests', exist_ok=True)
    open(W + '/Calc.Tests/Calc.Tests.csproj', 'w').write('<Project Sdk="Microsoft.NET.Sdk"></Project>\n')
    open(W + '/Calc.Tests/CalcTests.cs', 'w').write('using Xunit;\n\npublic class CalcTests\n{\n    [Fact]\n    public void Adds()\n    {\n        Assert.Equal(3, 1 + 2);\n    }\n\n    [Fact]\n    public void FailsOnPurpose()\n    {\n        Assert.Equal(4, 1 + 2);\n    }\n}\n')
    start('Calc.Tests/CalcTests.cs', w=130, h=34, path=FB); time.sleep(0.6)
    palette('Run tests in file'); wait_for('test.s. failed', 20); time.sleep(0.5)
    s = screen()
    ln = lambda w: [l for l in s.splitlines() if w in l and 'void' in l][0]
    check('510 dotnet test: results per [Fact]', '✓' in ln('Adds') and '✗' in ln('FailsOnPurpose'), s)
    setup()
    os.makedirs(W + '/src/test/kotlin', exist_ok=True)
    open(W + '/settings.gradle.kts', 'w').write('rootProject.name = "calc"\n')
    open(W + '/src/test/kotlin/CalcTest.kt', 'w').write('import kotlin.test.Test\nimport kotlin.test.assertEquals\n\nclass CalcTest {\n    @Test\n    fun `adds numbers`() {\n        assertEquals(3, 1 + 2)\n    }\n\n    @Test\n    fun failsOnPurpose() {\n        assertEquals(4, 1 + 2)\n    }\n}\n')
    start('src/test/kotlin/CalcTest.kt', w=130, h=34, path=FB); time.sleep(0.6)
    palette('Run tests in file'); wait_for('test.s. failed', 20); time.sleep(0.5)
    s = screen()
    ln = lambda w: [l for l in s.splitlines() if w in l and 'fun' in l][0]
    check('510 Gradle: results from build/test-results', '✓' in ln('adds numbers') and '✗' in ln('failsOnPurpose'), s)

def t_510_mcp_more():
    setup({"ai.autoApprove": "all", "ai.mcpServers": {"demo": {"command": "python3", "args": [MOCKS + "/mockmcp.py"],
                                                                "env": {"MOCK_MCP_FULL": "1"}}}})
    start('src/demo.nim', w=130, h=40); time.sleep(0.5)
    keys('M-c'); time.sleep(0.5); text('hello'); keys('Enter'); wait_for('You said', 15)
    text('/demo:summarize ned'); keys('Enter')
    check('510 MCP prompt as a /command', wait_for('summarize ned in one line', 20), screen())
    text('what does '); text('@'); time.sleep(0.6)
    check('510 @ lists the MCP resources with the context mentions', '@demo:note://greeting' in screen() and '@problems' in screen(), screen())
    text('greeting'); time.sleep(0.3); keys('Enter'); time.sleep(0.3); text('say?'); keys('Enter')
    check('510 MCP resource as an @mention', wait_for('The attached resource says PELICAN', 20), screen())
    text('read the greeting resource'); keys('Enter')
    check('510 MCP resources: the agent reads one with read_resource', wait_for('Tool said: The secret word is', 20), screen())
    palette('AI: MCP servers')
    ok = wait_for('1 resource.s.', 10)
    check('510 MCP servers list resources and prompts', ok and '1 prompt(s)' in screen(), screen())

def t_510_emmet_css():
    setup()
    cases = [('m10-20', 'margin: 10px 20px;'), ('w100p', 'width: 100%;'), ('df', 'display: flex;'), ('posr', 'position: relative;'),
             ('jcsb', 'justify-content: space-between;'), ('c#333', 'color: #333;'), ('bd1-s-#ccc', 'border: 1px solid #ccc;'),
             ('lh1.5', 'line-height: 1.5;'), ('fz14!', 'font-size: 14px !important;'), ('m0-a', 'margin: 0 auto;'),
             ('m-10', 'margin: -10px;'), ('bxz', 'box-sizing: border-box;'), ('zi10', 'z-index: 10;')]
    open(W + '/s.css', 'w').write('.box {\n' + ''.join('  %s\n' % a for a, _ in cases) + '}\n')
    start('s.css', w=130, h=40); time.sleep(0.5)
    for i in range(len(cases)):
        keys('C-g'); text(str(i + 2)); keys('Enter'); keys('End'); keys('Tab'); time.sleep(0.1)
    keys('C-g'); text('1'); keys('Enter'); keys('End'); keys('Tab')
    keys('C-s'); time.sleep(0.4)
    t = ftext('s.css')
    bad = [want for _, want in cases if ('  ' + want + '\n') not in t]
    check('510 Emmet for CSS: Tab expands abbreviations in a rule', not bad, t)
    check('510 Emmet for CSS: not outside a rule', t.startswith('.box {'), t[:40])
    open(W + '/t.css', 'w').write('.a {\n  c\n}\n')
    keys('C-o'); time.sleep(0.3); text('t.css'); keys('Enter'); time.sleep(0.4)
    keys('C-g'); text('2'); keys('Enter'); keys('End'); keys('Tab'); text('red'); keys('C-s'); time.sleep(0.4)
    check('510 Emmet for CSS: a property alone puts the cursor in its value', ftext('t.css') == '.a {\n  color: red;\n}\n', ftext('t.css'))

def t_510_sync():
    repo = TMP + '/syncrepo.git'
    shutil.rmtree(repo, ignore_errors=True)
    sh('git init -q --bare %s' % repo)
    setup({"ai.apiKey": "sk-SECRET-123", "editor.tabSize": 3, "keys": {"ctrl+j": "Go to line…"},
           "ai.mcpServers": {"demo": {"command": "nothing-here", "env": {"GITHUB_TOKEN": "ghp_SECRET"}}}})
    os.makedirs(CFG + '/ned/themes', exist_ok=True)
    open(CFG + '/ned/themes/mine.json', 'w').write('{"name": "mine", "base": "nim-crown"}\n')
    open(CFG + '/ned/words.txt', 'w').write('frobnicate\n')
    start('src/demo.nim', w=130, h=34); time.sleep(0.5)
    palette('Settings sync: export to a file'); time.sleep(0.3); keys('C-u'); text(W + '/export.json'); keys('Enter'); time.sleep(0.5)
    t = open(W + '/export.json').read() if os.path.exists(W + '/export.json') else ''
    check('510 sync: export has the settings, theme and words', '"editor.tabSize": 3' in t and 'mine.json' in t and 'frobnicate' in t, t[:300])
    check('510 sync: no API key or token in the export', 'SECRET' not in t and '"GITHUB_TOKEN": ""' in t, t)
    check('510 sync: the export is private (600)', oct(os.stat(W + '/export.json').st_mode & 0o777) == '0o600', '')
    palette('Settings sync: set the repository'); time.sleep(0.3); keys('C-u'); text('https://me:tok123@example.com/x.git'); keys('Enter'); time.sleep(0.3)
    check('510 sync: a token in the URL is refused', 'Keep the token out of the URL' in screen(), screen())
    palette('Settings sync: set the repository'); time.sleep(0.3); keys('C-u'); text('file://' + repo); keys('Enter'); time.sleep(0.3)
    palette('Settings sync: push')
    check('510 sync: push to a git repository', wait_for('Settings saved', 20), screen())
    pushed = sh('git --git-dir=%s show HEAD:ned-settings.json' % repo).stdout
    check('510 sync: the repository has them, without secrets', '"editor.tabSize": 3' in pushed and 'SECRET' not in pushed, pushed[:300])
    # another device: other settings and its own key, same repository
    setup({"ai.apiKey": "sk-LOCAL-9", "editor.tabSize": 8, "sync.repository": "file://" + repo,
           "ai.mcpServers": {"demo": {"command": "nothing-here", "env": {"GITHUB_TOKEN": "ghp_LOCAL"}}}})
    shutil.rmtree(CFG + '/ned/themes', ignore_errors=True)
    open(CFG + '/ned/words.txt', 'w').write('quux\n')
    start('src/demo.nim', w=130, h=34); time.sleep(0.5)
    palette('Settings sync: pull')
    ok = wait_for('Settings loaded', 20); time.sleep(0.3)
    c = open(CFG + '/ned/config.json').read()
    check('510 sync: pull brings the settings over', ok and re.search(r'"editor.tabSize":\s*3', c) and 'ctrl+j' in c, c)
    check("510 sync: this device's key and token stay", 'sk-LOCAL-9' in c and 'ghp_LOCAL' in c, c)
    check('510 sync: themes and words too', os.path.exists(CFG + '/ned/themes/mine.json') and
          set(open(CFG + '/ned/words.txt').read().split()) == {'quux', 'frobnicate'}, '')

def t_510_keymaps():
    setup({"editor.keymap": "emacs"})
    open(W + '/e.txt', 'w').write('alpha beta\ngamma\n')
    start('e.txt', w=120, h=30); time.sleep(0.5)
    keys('C-e'); text('!'); keys('C-n', 'C-a', 'C-k'); keys('C-p', 'C-a', 'M-f'); text('X')
    keys('C-n', 'C-a', 'C-y'); keys('C-x', 'C-s'); time.sleep(0.4)
    check('510 emacs: C-e C-n C-a C-k M-f C-y C-x C-s', ftext('e.txt') == 'alphaX beta!\ngamma\n', repr(ftext('e.txt')))
    keys('C-p', 'C-a', 'C-Space', 'C-e', 'M-w', 'C-g'); keys('C-n', 'C-e', 'Enter', 'C-y'); keys('C-x', 'C-s'); time.sleep(0.4)
    check('510 emacs: C-SPC marks, M-w copies, C-y yanks', ftext('e.txt') == 'alphaX beta!\ngamma\nalphaX beta!\n', repr(ftext('e.txt')))
    keys('M-x'); time.sleep(0.4)
    check('510 emacs: M-x opens the command palette', 'Command palette' in screen() or '›' in screen().split('\n')[2], screen()[:500])
    keys('Escape'); keys('C-x', 'b'); time.sleep(0.4)
    check('510 emacs: C-x b switches buffer', 'Switch buffer' in screen(), screen()[:600])
    keys('Escape')
    setup({"editor.keymap": "helix"})
    open(W + '/h.txt', 'w').write('one two three\nfour five\n')
    start('h.txt', w=120, h=30); time.sleep(0.5)
    check('510 helix: starts in NOR', ' NOR ' in screen().splitlines()[-1] or 'NOR' in screen().splitlines()[-1], screen().splitlines()[-1])
    text('wd'); time.sleep(0.2)
    text('xyp'); time.sleep(0.2)
    text('ge'); text('i'); time.sleep(0.2)
    check('510 helix: i enters INS', 'INS' in screen().splitlines()[-1], screen().splitlines()[-1])
    text('end'); keys('Escape'); text(':w'); keys('Enter'); time.sleep(0.4)
    check('510 helix: w selects a word, d deletes, x y p copies a line, ge, i, :w',
          ftext('h.txt') == 'two three\ntwo three\nendfour five\n', repr(ftext('h.txt')))
    text('gg'); text(' f'); time.sleep(0.4)
    check('510 helix: space f opens the file picker', 'h.txt' in screen().split('\n')[3] or 'Open file' in screen(), screen()[:600])
    keys('Escape')

def t_510_accessible():
    setup()
    open(W + '/src/bad.nim', 'w').write('let x: int = "s"\necho x\n')
    start('src/bad.nim', w=120, h=32); time.sleep(0.5)
    palette('Accessibility mode'); time.sleep(0.6)
    keys('C-s'); time.sleep(0.3)
    ok = wait_for(r'(?m)^E +1 ', 30)
    s = screen()
    fancy = [ch for ch in s if 0x2500 <= ord(ch) <= 0x259F or 0x2800 <= ord(ch) <= 0x28FF or ch in '●◆✓✗▶▸▾']
    check('510 accessible: no box-drawing or symbol glyphs on screen', not fancy, ''.join(sorted(set(fancy))) + '\n' + s)
    check('510 accessible: E in the gutter, not only a red dot', ok, s)
    c = open(CFG + '/ned/config.json').read()
    check('510 accessible: a high-contrast theme', '"modus-vivendi"' in c or '"modus-operandi"' in c, c)
    palette('Accessibility mode'); time.sleep(0.6)
    c = open(CFG + '/ned/config.json').read()
    check('510 accessible: off again, the old theme back', '"ui.accessible": false' in c and '"theme": "nim-crown"' in c, c)

def t_510_workspace():
    other = TMP + '/work2'
    shutil.rmtree(other, ignore_errors=True)
    os.makedirs(other + '/lib')
    open(other + '/lib/helper.nim', 'w').write('proc helperProc*(): int = 42\n')
    setup()
    start('src/demo.nim', w=130, h=36); time.sleep(0.5)
    palette('Workspace: add a folder'); time.sleep(0.3); keys('C-u'); text(other); keys('Enter'); time.sleep(0.6)
    s = screen()
    check('510 workspace: the tree shows both folders', 'work2' in s and 'work ' in s.split('\n')[2] or ('work2' in s and 'src' in s), s)
    keys('C-p'); time.sleep(0.3); text('helper'); wait_for('helper.nim work2/lib', 6)
    s = screen()
    check('510 workspace: quick open finds the other folder\'s files', 'helper.nim work2/lib' in s, s)
    keys('Enter'); time.sleep(0.5)
    check('510 workspace: and opens them', 'helper.nim' in screen().split('\n')[1] and 'helperProc' in screen(), screen())
    keys('M-s'); time.sleep(0.3); keys('C-u'); text('helperProc'); keys('Enter'); time.sleep(1.5)
    check('510 workspace: project search covers every folder', 'helper.nim' in screen() and '1 result' in screen() or 'helperProc*' in screen(), screen())
    keys('Escape')
    palette('Workspace: save as'); time.sleep(0.3); keys('Enter'); time.sleep(0.5)
    wf = W + '/work.ned-workspace'
    ok = os.path.exists(wf) and len(json.load(open(wf))['folders']) == 2
    check('510 workspace: saved as a .ned-workspace file', ok, open(wf).read() if os.path.exists(wf) else 'none')
    tm('kill-server'); time.sleep(0.3)
    start('work.ned-workspace', w=130, h=36); time.sleep(0.8)
    keys('C-p'); time.sleep(0.3); text('helper')
    check('510 workspace: opening the file brings both folders back', wait_for('helper.nim work2/lib', 6), screen())
    keys('Escape')

def t_510_remote():
    need('ssh-server')
    srv = TMP + '/remote-srv/proj'
    shutil.rmtree(TMP + '/remote-srv', ignore_errors=True)
    os.makedirs(srv + '/node_modules/big')
    open(srv + '/hello.py', 'w').write('import os\nprint("cwd", os.getcwd())\n')
    open(srv + '/node_modules/big/x.js', 'w').write('// skipped\n')
    SP = SSH_DIR + ':' + TOOLS + ':/usr/bin:/bin'
    def ssh_reset():                   # no shared connection left from an earlier run
        sh('for c in ' + SSH_CTL + '/*; do ' + SSH_DIR + '/ssh -o ControlPath=$c -O exit x 2>/dev/null; done; rm -f ' + SSH_CTL + '/*')
    ssh_reset()
    setup()
    start('src/demo.nim', w=130, h=40, path=SP); time.sleep(0.5)
    palette('Remote: open a folder over SSH'); time.sleep(0.3); text('devbox:' + srv); keys('Enter')
    ok = wait_for('every save goes', 30)
    s = screen()
    check('510 remote: the folder is copied and opened', ok and 'hello.py' in s and 'devbox' in s.splitlines()[-1] and 'proj' in s.splitlines()[0], s)
    mirror = [l for l in sh('ls -d %s/ned/remote/devbox/*/*' % STATE).stdout.split()]
    check('510 remote: big generated folders stay on the server', mirror and not os.path.exists(mirror[0] + '/node_modules'), str(mirror))
    keys('C-p'); time.sleep(0.3); text('hello.py'); time.sleep(0.4); keys('Enter'); time.sleep(0.4)
    keys('C-End'); keys('Enter'); text('print("edited")'); keys('C-s')
    ok = wait_for('Saved on devbox', 15)
    check('510 remote: a save goes to the server', ok and 'print("edited")' in open(srv + '/hello.py').read(), open(srv + '/hello.py').read())
    palette('Run file'); ok = wait_for('Finished', 20)
    check('510 remote: Run runs on the server, in its folder', ok and ('cwd ' + srv) in screen() and 'edited' in screen(), screen())
    keys('C-\\'); time.sleep(1.5); text('pwd'); keys('Enter'); time.sleep(1.0)
    check('510 remote: the terminal is a shell on the server', srv in screen().split('TERMINAL')[-1], screen())
    keys('C-\\'); time.sleep(0.3)
    open(srv + '/hello.py', 'a').write('print("from the server")\n')
    palette('Remote: pull the latest files'); ok = wait_for('every save goes', 20); time.sleep(0.5)
    check('510 remote: pull brings the server\'s changes into the open file', ok and 'from the server' in screen(), screen())
    # a key with a passphrase: ssh asks in the terminal, ned goes on once it is answered
    ssh_reset()
    setup()
    start('src/demo.nim', w=130, h=40, path=SP); time.sleep(0.5)
    palette('Remote: open a folder over SSH'); time.sleep(0.3); text('devboxpw:' + srv); keys('Enter')
    ok = wait_for('passphrase', 20)
    check('510 remote: ssh asks for the passphrase in the terminal', ok, screen())
    text('s3cretpass'); keys('Enter')
    ok = wait_for('every save goes', 30)
    check('510 remote: and ned goes on once it is answered', ok and 'hello.py' in screen(), screen())
    leaked = ''
    for d in os.listdir('/proc'):
        if d.isdigit():
            try:
                cl = open('/proc/%s/cmdline' % d, 'rb').read()
                if b's3cretpass' in cl and int(d) != os.getpid() and b'shell-snapshots' not in cl: leaked += d + ' ' + cl.replace(b'\0', b' ').decode(errors='replace')[:200] + ' | '
            except Exception: pass
    check('510 remote: the passphrase is on no command line', leaked == '', leaked)

def t_517_remote_git():
    need('ssh-server')
    # a remote folder: deletes and renames go to the server; git runs there (status, stage, commit, switch a branch:
    # the files it changes come back, the ones it deletes go away); a pull removes files deleted on the server
    base = TMP + '/remote-srv2'
    srv = base + '/proj'
    shutil.rmtree(base, ignore_errors=True)
    os.makedirs(srv + '/sub')
    for n, t in [('a.txt', 'alpha\n'), ('b.txt', 'beta\n'), ('sub/c.txt', 'gamma\n'), ('old.txt', 'old\n'), ('ren.txt', 'ren\n')]:
        open(srv + '/' + n, 'w').write(t)
    G = 'git -C %s -c user.name=srv -c user.email=s@s ' % srv
    sh('git init -q -b main ' + srv); sh(G + 'add -A'); sh(G + 'commit -qm base')
    sh(G + 'checkout -qb feature'); os.remove(srv + '/b.txt'); open(srv + '/d.txt', 'w').write('delta\n')
    sh(G + 'add -A'); sh(G + 'commit -qm feature'); sh(G + 'checkout -q main')
    sh(G + 'config user.name srv'); sh(G + 'config user.email s@s')
    SP = SSH_DIR + ':' + TOOLS + ':/usr/bin:/bin'
    sh('for c in ' + SSH_CTL + '/*; do ' + SSH_DIR + '/ssh -o ControlPath=$c -O exit x 2>/dev/null; done; rm -f ' + SSH_CTL + '/*')
    setup()
    start('src/demo.nim', w=130, h=40, path=SP); time.sleep(0.5)
    palette('Remote: open a folder over SSH'); time.sleep(0.3); text('devbox:' + srv); keys('Enter')
    ok = wait_for('and git', 30)
    check('517 remote: a git repository on the server — git works on it there', ok, screen())
    mirror = (sh('ls -d %s/ned/remote/devbox/*/proj' % STATE).stdout.split() or ['?'])[0]
    check('517 remote: no .git copied over', not os.path.exists(mirror + '/.git'), mirror)
    # an edit, seen by git on the server
    keys('C-p'); time.sleep(0.3); text('a.txt'); time.sleep(0.4); keys('Enter'); time.sleep(0.4)
    keys('C-End'); text('edited'); keys('C-s'); wait_for('Saved on devbox', 15); time.sleep(0.5)
    keys('M-g'); ok = wait_for('git on devbox', 15); time.sleep(1.5)
    s = screen()
    check('517 remote git: the Git dock shows the server\'s branch and changes', ok and 'main' in s and 'a.txt' in s, s)
    # commit (the message goes along to the server)
    palette('Git: commit (message box)'); time.sleep(0.8)
    text('commit made on the server'); keys('C-s'); time.sleep(0.6); keys('y'); time.sleep(3)
    log = sh(G + 'log -1 --format=%s').stdout.strip()
    check('517 remote git: commit on the server', log == 'commit made on the server', log + screen()[-600:])
    check('517 remote git: no temp files left on the server', not [f for f in os.listdir('/tmp') if f.startswith('ned-') and 'commit-msg' in f], str(os.listdir('/tmp'))[:300])
    # delete and rename in the Files tree: on the server too
    keys('C-p'); time.sleep(0.3); text('old.txt'); time.sleep(0.4); keys('Enter'); time.sleep(0.4)
    palette('Reveal file in tree'); time.sleep(0.5); keys('d'); ok = wait_for('here and on devbox', 5); keys('y')
    time.sleep(2.5)
    check('517 remote: deleting a file deletes it on the server', ok and not os.path.exists(srv + '/old.txt'), screen())
    keys('Escape')
    keys('C-p'); time.sleep(0.3); text('ren.txt'); time.sleep(0.4); keys('Enter'); time.sleep(0.4)
    palette('Reveal file in tree'); time.sleep(0.5); keys('r'); time.sleep(0.4); keys('C-u'); text('sub/renamed.txt'); keys('Enter')
    time.sleep(2.5)
    check('517 remote: renaming a file renames it on the server', not os.path.exists(srv + '/ren.txt') and
          os.path.exists(srv + '/sub/renamed.txt'), str(os.listdir(srv)) + screen())
    keys('Escape')
    # switch to a branch that deletes b.txt and adds d.txt: the local copy follows
    sh(G + 'add -A'); sh(G + 'commit -qm tidy')
    palette('Git: branches'); time.sleep(1.0); text('feature'); time.sleep(0.5); keys('Enter'); time.sleep(0.6)
    keys('Enter'); time.sleep(4)
    br = sh(G + 'rev-parse --abbrev-ref HEAD').stdout.strip()
    check('517 remote git: switched branch on the server', br == 'feature', br + screen())
    check('517 remote git: files the switch added come here, deleted ones go', os.path.exists(mirror + '/d.txt') and
          not os.path.exists(mirror + '/b.txt'), str(sorted(os.listdir(mirror))))
    s = screen()
    check('517 remote git: the title bar shows the server\'s branch', 'feature' in s.splitlines()[0], s.splitlines()[0])
    # the change marks come from the server's repository; one change staged there (the patch goes along)
    keys('C-p'); time.sleep(0.3); text('a.txt'); time.sleep(0.4); keys('Enter'); time.sleep(0.4)
    keys('C-Home'); keys('End'); text(' staged part'); keys('C-s'); wait_for('Saved on devbox', 15); time.sleep(3)
    keys('C-Home'); palette('Git: stage this change'); time.sleep(3)
    d = sh(G + 'diff --cached').stdout
    check('517 remote git: a change staged on the server from the gutter', 'staged part' in d, d + screen())
    sh(G + 'reset -q'); sh(G + 'checkout -q -- a.txt')
    palette('Remote: pull the latest files'); wait_for('every save goes', 20); time.sleep(1)
    # a stash on the server: the local copy goes back to the committed text
    keys('C-p'); time.sleep(0.3); text('d.txt'); time.sleep(0.4); keys('Enter'); time.sleep(0.4)
    keys('C-End'); text('unsaved idea'); keys('C-s'); wait_for('Saved on devbox', 15); time.sleep(0.5)
    palette('Git: stash'); time.sleep(1.0); keys('Enter'); time.sleep(0.4); text('idea'); keys('Enter'); time.sleep(4)
    check('517 remote git: a stash on the server puts the local file back', 'idea' in sh(G + 'stash list').stdout and
          'unsaved idea' not in open(mirror + '/d.txt').read() and 'unsaved idea' not in screen(), open(mirror + '/d.txt').read() + screen())
    # a file deleted on the server by other means: gone here after a pull
    os.remove(srv + '/sub/c.txt')
    palette('Remote: pull the latest files'); ok = wait_for('deleted there removed here', 20)
    check('517 remote: a pull removes files deleted on the server', ok and not os.path.exists(mirror + '/sub/c.txt'), screen())
    check('517 remote: … and keeps the others', os.path.exists(mirror + '/ren.txt') and os.path.exists(mirror + '/d.txt'),
          str(os.listdir(mirror)))
    # (feature has old.txt and ren.txt where main moved them: the switch brought them back and took sub/renamed.txt away)
    check('517 remote git: a switch also takes away what the other branch moved', os.path.exists(mirror + '/old.txt') and
          not os.path.exists(mirror + '/sub/renamed.txt'), str(os.listdir(mirror)))

def t_517_workspace_git():
    # a workspace whose folders are separate repositories: the Git dock lists them, follows the open file's,
    # and stages and commits in the right one
    other = TMP + '/work3'
    shutil.rmtree(other, ignore_errors=True)
    os.makedirs(other)
    open(other + '/lib.nim', 'w').write('proc libProc*(): int = 1\n')
    sh('git init -q -b trunk ' + other)
    GO = 'git -C %s -c user.name=o -c user.email=o@o ' % other
    sh(GO + 'add -A'); sh(GO + 'commit -qm "lib base"')
    sh(GO + 'config user.name o'); sh(GO + 'config user.email o@o')
    open(other + '/lib.nim', 'a').write('proc more*(): int = 2\n')
    setup()
    start('src/demo.nim', w=130, h=40); time.sleep(0.5)
    palette('Workspace: add a folder'); time.sleep(0.3); keys('C-u'); text(other); keys('Enter'); time.sleep(0.8)
    keys('M-g'); ok = wait_for('REPOSITORIES', 10); time.sleep(1.5)
    s = screen()
    check('517 workspace git: the Git dock lists every folder\'s repository', ok and 'work3' in s and '⎇ trunk' in s, s)
    keys('C-p'); time.sleep(0.3); text('lib.nim'); time.sleep(0.5); keys('Enter'); time.sleep(1.5)
    s = screen()
    check('517 workspace git: the dock follows the open file to its repository', '● work3' in s and 'lib.nim' in s.split('REPOSITORIES')[-1], s)
    check('517 workspace git: the title bar names that folder\'s branch', 'work3: trunk' in s.splitlines()[0], s.splitlines()[0])
    palette('Git: stage all'); time.sleep(1.5)
    palette('Git: commit (message box)'); time.sleep(0.8)
    check('517 workspace git: the commit box names the repository', 'work3' in screen().splitlines()[1], screen().splitlines()[1])
    text('commit in the second folder'); keys('C-s'); time.sleep(2.5)
    log = sh(GO + 'log -1 --format=%s').stdout.strip()
    check('517 workspace git: committed in that folder\'s repository', log == 'commit in the second folder', log + screen()[-500:])
    mine = git('log -1 --format=%s').stdout.strip()
    check('517 workspace git: … not in the project\'s', mine != 'commit in the second folder', mine)
    shutil.rmtree(other, ignore_errors=True)

def t_518_macros():
    # keyboard macros: record, play, N times (one undo step), each selected line, saved by name; keys of the
    # palette that stopped it are not part of it
    setup()
    open(W + '/m.txt', 'w').write('a1\na2\na3\na4\na5\nb1\nb2\nb3\n')
    start('m.txt', w=120, h=30); time.sleep(0.5)
    keys('M-R'); time.sleep(0.3)
    check('518 recording shows in the status bar', '● REC' in screen().splitlines()[-1], screen().splitlines()[-1])
    keys('End'); hx(';'); keys('Down'); keys('M-R'); time.sleep(0.3)
    check('518 the recording stops', 'REC' not in screen().splitlines()[-1] and 'Macro recorded: 3 key(s)' in screen(), screen())
    keys('M-M'); time.sleep(0.3)
    palette('Macro: play the last one N times'); time.sleep(0.3); keys('C-u'); text('2'); keys('Enter'); time.sleep(0.5)
    keys('C-s'); time.sleep(0.3)
    check('518 Alt+Shift+M plays it, and N times', ftext('m.txt').startswith('a1;\na2;\na3;\na4;\na5\n'), repr(ftext('m.txt')))
    keys('C-z'); keys('C-s'); time.sleep(0.3)
    check('518 playing N times undoes as one step', ftext('m.txt').startswith('a1;\na2;\na3\na4\n'), repr(ftext('m.txt')))
    # stopped from the palette: the palette's keys are left out
    keys('C-g'); text('6'); keys('Enter'); time.sleep(0.2)
    keys('M-R'); keys('Home'); hx('- '); time.sleep(0.2)
    palette('Macro: start or stop recording'); time.sleep(0.4)
    keys('Down', 'S-Down', 'S-Down'); time.sleep(0.2)
    keys('C-p'); text('>Macro: play on each'); time.sleep(0.4); keys('Enter'); time.sleep(0.6); keys('C-s'); time.sleep(0.3)
    check('518 stopped from the palette, played on each selected line', ftext('m.txt').endswith('- b1\n- b2\n- b3\n'), repr(ftext('m.txt')))
    # save it by name: a command of its own, kept in macros.json
    palette('Macro: save the last one'); time.sleep(0.4); text('bullet'); keys('Enter'); time.sleep(0.4)
    mj = open(CFG + '/ned/macros.json').read() if os.path.exists(CFG + '/ned/macros.json') else ''
    check('518 saved in macros.json, readable', '"bullet"' in mj and '"- "' in mj and '"home"' in mj, mj)
    keys('C-g'); text('1'); keys('Enter'); time.sleep(0.2)
    palette('Macro: bullet'); time.sleep(0.4); keys('C-s'); time.sleep(0.3)
    check('518 a saved macro runs as "Macro: <name>"', ftext('m.txt').startswith('- a1;'), repr(ftext('m.txt')))
    tm('kill-server'); time.sleep(0.3)
    start('m.txt', w=120, h=30); time.sleep(0.5)
    keys('C-g'); text('2'); keys('Enter'); time.sleep(0.2)
    palette('Macro: bullet'); time.sleep(0.4); keys('C-s'); time.sleep(0.3)
    check('518 saved macros come back after a restart', ftext('m.txt').startswith('- a1;\n- a2;'), repr(ftext('m.txt')))
    # to the end of the file: again and again while it goes down and changes something
    keys('C-g'); text('3'); keys('Enter'); time.sleep(0.2)
    keys('M-R'); keys('Home'); hx('>'); keys('Down'); keys('M-R'); time.sleep(0.2)
    palette('Macro: play to the end of the file'); time.sleep(0.6); keys('C-s'); time.sleep(0.3)
    t = ftext('m.txt').split('\n')
    check('518 played to the end of the file', all(l.startswith('>') for l in t[2:8]) and not t[1].startswith('>'), repr(t))
    # vim: qa … q, @a with a count, @@
    setup({"editor.vimMode": True})
    open(W + '/v.txt', 'w').write('x\nx\nx\nx\nx\n')
    start('v.txt', w=120, h=30); time.sleep(0.5)
    text('qa'); time.sleep(0.2)
    check('518 vim: q records into a register', '@a' in screen().splitlines()[-1], screen().splitlines()[-1])
    text('A!'); keys('Escape'); text('j'); text('q'); time.sleep(0.2)
    text('2@a'); time.sleep(0.3); text('@@'); time.sleep(0.3)
    text(':w'); keys('Enter'); time.sleep(0.4)
    check('518 vim: qa … q, 2@a, @@', ftext('v.txt') == 'x!\nx!\nx!\nx!\nx\n', repr(ftext('v.txt')))
    # emacs: C-x ( … C-x ), C-x e
    setup({"editor.keymap": "emacs"})
    open(W + '/e.txt', 'w').write('p\np\np\n')
    start('e.txt', w=120, h=30); time.sleep(0.5)
    keys('C-x'); text('('); keys('C-e'); text('?'); keys('C-n'); keys('C-x'); text(')'); time.sleep(0.2)
    keys('C-x'); text('e'); time.sleep(0.2); keys('C-x', 'C-s'); time.sleep(0.4)
    check('518 emacs: C-x ( C-x ) C-x e', ftext('e.txt') == 'p?\np?\np\n', repr(ftext('e.txt')))
    # helix: Q … Q, q
    setup({"editor.keymap": "helix"})
    open(W + '/h.txt', 'w').write('k\nk\nk\n')
    start('h.txt', w=120, h=30); time.sleep(0.5)
    text('Q'); text('A'); text('#'); keys('Escape'); text('j'); text('Q'); time.sleep(0.2)
    text('q'); time.sleep(0.2); text(':w'); keys('Enter'); time.sleep(0.4)
    check('518 helix: Q … Q, q', ftext('h.txt') == 'k#\nk#\nk\n', repr(ftext('h.txt')))

def t_518_terminal():
    # shell integration: bash and zsh mark each command (their own startup files still read); Ctrl+↑ goes to a
    # command, Alt+Enter: its menu (output in a tab); the header shows the last result; run again; split terminals
    home = TMP + '/fakehome518'
    shutil.rmtree(home, ignore_errors=True); os.makedirs(home + '/zd')
    open(home + '/.bashrc', 'w').write("alias hi='echo hello-from-bashrc'\nPS1='bash$ '\n")
    open(home + '/zd/.zshrc', 'w').write("alias hi='echo hello-from-zshrc'\nPS1='zsh%% '\n")
    open(home + '/zd/.zshenv', 'w').write("export FROM_ZSHENV=yes\n")
    os.makedirs(home + '/.config/fish')
    open(home + '/.config/fish/config.fish', 'w').write("alias hi='echo hello-from-fishrc'\n")
    for sh_, extra in [x for x in [('/bin/bash', 'HOME=' + home), ((which('zsh') or 'zsh'), 'HOME=' + home + ' ZDOTDIR=' + home + '/zd'),
                       ((which('fish') or 'fish'), 'HOME=' + home)] if x[0].startswith('/')]:
        nm = os.path.basename(sh_)
        setup({"terminal.shell": sh_})
        if nm == 'fish':          # (the tests' XDG_CONFIG_HOME is where fish looks)
            os.makedirs(CFG + '/fish', exist_ok=True)
            shutil.copy(home + '/.config/fish/config.fish', CFG + '/fish/config.fish')
        start('src/demo.nim', w=120, h=34, env_extra=extra); time.sleep(0.5)
        keys('C-\\'); time.sleep(1.5)
        text('hi'); keys('Enter'); time.sleep(0.4)
        if nm == 'zsh':
            text('echo env-$FROM_ZSHENV'); keys('Enter'); time.sleep(0.4)
        text('false'); keys('Enter'); time.sleep(0.6)
        s = screen()
        check('518 %s: its own startup file is read' % nm, 'hello-from-' + nm + 'rc' in s and (nm != 'zsh' or 'env-yes' in s), s)
        check('518 %s: the header shows a failed command' % nm, 'exit 1' in s.split('TERMINAL')[1].splitlines()[0], s)
        text('printf "a\\nb\\nc\\n"'); keys('Enter'); time.sleep(0.6)
        s = screen()
        marks = [l for l in s.split('TERMINAL')[1].splitlines() if l.startswith('● ')]
        check('518 %s: each command is marked in the gutter' % nm, len(marks) >= 3, s)
        keys('C-Up'); time.sleep(0.4)
        check('518 %s: Ctrl+↑ goes to the last command' % nm, '$ printf' in screen() and 'Alt+Enter' in screen(), screen())
        keys('C-Up'); time.sleep(0.3)
        check('518 %s: … and the one before it' % nm, '$ false' in screen(), screen())
        keys('C-Down'); time.sleep(0.3); keys('M-Enter'); time.sleep(0.5)
        check('518 %s: Alt+Enter: the command\'s menu' % nm, 'Copy its output' in screen() and 'Run it again' in screen(), screen())
        text('Open its output'); keys('Enter'); time.sleep(0.6)
        s = screen()
        check('518 %s: its output in a tab' % nm, '$ printf' in s.splitlines()[1] and ' a' in s and ' c' in s, s)
        palette('Terminal: run the last command again'); time.sleep(0.8)
        t = screen().split('TERMINAL')[1]
        check('518 %s: run the last command again' % nm, t.count('printf') >= 2, t)
    # two terminals side by side; Ctrl+PgDn goes to the other one
    keys('C-\\'); time.sleep(0.3)
    palette('Terminal: split'); time.sleep(1.5)
    text('echo right-side'); keys('Enter'); time.sleep(0.5)
    t = screen().split('TERMINAL')[1]
    check('518 split: two terminals side by side', all('│' in l for l in t.splitlines()[2:6]) and 'right-side' in t, t)
    keys('C-PgDn'); time.sleep(0.3); text('echo left-again'); keys('Enter'); time.sleep(0.5)
    t = screen().split('TERMINAL')[1]
    rows = [l for l in t.splitlines() if 'left-again' in l]
    check('518 split: Ctrl+PgDn goes to the other one', rows and rows[0].find('left-again') < rows[0].find('│') if rows and '│' in rows[0] else False, t)
    shutil.rmtree(home, ignore_errors=True)
    try: os.remove(CFG + '/fish/config.fish')
    except OSError: pass

def t_519_refactor():
    # reference counts beside declarations; exports nothing uses; change signature, inline, move to a module —
    # and the project still compiles and prints the same
    setup()
    open(W + '/src/demo/utils.nim', 'a').write('\nproc scale*(x: int, factor = 2): int = x * factor\n'
                                               'proc helper(x: int): int = x + 1\nproc bump*(x: int): int = helper(x)\n')
    open(W + '/src/demo.nim', 'a').write('  let n = 5\n  echo scale(3)\n  echo n.scale(factor = 3)\n  let s = scale(x = 1)\n'
                                         '  echo s, twice(4), n.twice, bump(1)\n')
    def run():
        r = subprocess.run(('cd %s && ' + NIMBIN + '/nim c --hints:off -r src/demo.nim 2>&1 | tail -6') % W,
                           shell=True, capture_output=True, text=True)
        return r.stdout
    before = run()
    start('src/demo/utils.nim', w=124, h=34); time.sleep(1)
    ok = wait_for('1 reference', 15)
    s = screen()
    check('519 reference counts beside declarations', ok and re.search(r'proc shout\*.*1 reference', s) and
          re.search(r'proc scale\*.*3 references', s), s)
    palette('Nim: exports nothing uses'); wait_for('Exported, used nowhere|Every export is used', 15)
    check('519 exports nothing uses: none here', 'Every export is used' in screen(), screen())
    keys('Escape')
    open(W + '/src/demo/utils.nim', 'a').write('\nproc lonely*(): int = 1\n')
    palette('Reload from disk'); time.sleep(0.5)
    palette('Nim: exports nothing uses'); ok = wait_for('Exported, used nowhere', 15)
    check('519 exports nothing uses: lonely', ok and 'lonely' in screen(), screen())
    keys('Escape')
    ok = wait_for(r'proc lonely\*.*no references', 10)
    check('519 "no references" beside an export nothing uses', ok, screen())
    # change signature: a new parameter between the two, every call passes 0 for it
    keys('C-g'); text('9:7'); keys('Enter'); time.sleep(0.3)
    palette('Nim: change signature'); time.sleep(1)
    check('519 change signature: the plan', 'factor = 2  ← factor' in screen() and 'x: int  ← x' in screen(), screen())
    keys('C-g'); text('5'); keys('Enter'); keys('End'); keys('Enter'); text('offset: int '); hx('::'); text(' 0')
    # …and factor renamed k: the body follows
    keys('C-g'); text('7'); keys('Enter'); keys('Home'); keys(*(['S-Right'] * 6)); text('k')
    keys('C-s'); ok = wait_for(r'Changed scale and 3 call', 10)
    check('519 change signature: the declaration and every call', ok, screen())
    palette('Save all'); time.sleep(0.8)
    u = ftext('src/demo/utils.nim'); d = ftext('src/demo.nim')
    check('519 change signature: rewritten, the renamed parameter in the body too',
          'proc scale*(x: int, offset: int, k = 2): int = x * k' in u and 'scale(3, 0)' in d and
          'n.scale(0, 3)' in d and 'scale(1, 0)' in d, u + d)
    check('519 change signature: it compiles and prints the same', run() == before, run() + ' vs ' + before)
    # inline twice: every call becomes x * 2, then the declaration goes
    keys('M-1'); time.sleep(0.4)          # the utils.nim tab
    keys('C-g'); text('7:7'); keys('Enter'); time.sleep(0.3)
    palette('Nim: inline this proc'); ok = wait_for('remove its declaration', 10)
    check('519 inline: every call, then the offer to remove it', ok, screen())
    keys('y'); time.sleep(0.5); palette('Save all'); time.sleep(0.8)
    u = ftext('src/demo/utils.nim'); d = ftext('src/demo.nim')
    check('519 inline: calls become the body', 'proc twice' not in u and '(4 * 2)' in d and '(n * 2)' in d, u + d)
    check('519 inline: it compiles and prints the same', run() == before, run() + ' vs ' + before)
    # inline shout into demo.nim: its body needs std/strutils, which demo.nim then imports
    keys('M-1'); time.sleep(0.4)
    keys('C-g'); text('3:7'); keys('Enter'); time.sleep(0.3)
    palette('Nim: inline this proc'); ok = wait_for('remove its declaration', 10)
    keys('n'); time.sleep(0.3); palette('Save all'); time.sleep(0.8)
    d = ftext('src/demo.nim')
    check('519 inline: the imports the body needs come along', ok and 'import std/strutils' in d and
          '"done".toUpperAscii' in d, d)
    check('519 inline: still compiles and prints the same', run() == before, run() + ' vs ' + before)
    # bump's body calls a private proc: the call in another module is left, with the reason
    keys('M-1'); time.sleep(0.4)
    ln = [i for i, l in enumerate(ftext('src/demo/utils.nim').split('\n')) if 'proc bump' in l][0] + 1
    keys('C-g'); text('%d:7' % ln); keys('Enter'); time.sleep(0.3)
    palette('Nim: inline this proc'); ok = wait_for('private to utils.nim', 10)
    check('519 inline: a body using a private proc stays out of other modules', ok and 'bump(1)' in ftext('src/demo.nim'), screen())
    keys('Escape'); time.sleep(0.3)
    # move scale to a new module: the files that use it import it
    keys('M-1'); time.sleep(0.4)          # the utils.nim tab
    ln = [i for i, l in enumerate(ftext('src/demo/utils.nim').split('\n')) if 'proc scale' in l][0] + 1
    keys('C-g'); text('%d:7' % ln); keys('Enter'); time.sleep(0.3)
    palette('Nim: move to another module'); time.sleep(0.8)
    keys('Enter'); time.sleep(0.4); keys('C-u'); text('src/demo/math2.nim'); keys('Enter'); ok = wait_for('Moved scale to', 10)
    palette('Save all'); time.sleep(0.8)
    u = ftext('src/demo/utils.nim'); d = ftext('src/demo.nim')
    m = ftext('src/demo/math2.nim') if os.path.exists(W + '/src/demo/math2.nim') else ''
    check('519 move: into the new module, imported where it is used', ok and 'proc scale' not in u and 'proc scale*' in m and
          'import demo/math2' in d, u + d + m)
    check('519 move: it compiles and prints the same', run() == before, run() + ' vs ' + before)

def t_519_lists():
    # lists of things built in a loop: each item acts on its own thing (not all on the last one)
    setup()
    json.dump({"one": ["AAA"], "two": ["BBB"]}, open(CFG + '/ned/macros.json', 'w'))
    open(W + '/src/demo/utils.nim', 'a').write('\nproc lonely1*(): int = 1\nproc lonely2*(): int = 2\n'
                                               'proc helper(x: int): int = x + 1\nproc bump*(x: int): int = helper(x)\n')
    open(W + '/src/demo.nim', 'a').write('  echo bump(1)\n  echo bump(2)\n')
    os.makedirs(TMP + '/fakehome519', exist_ok=True)
    start('src/demo/utils.nim', w=130, h=36, env_extra='HOME=' + TMP + '/fakehome519 SHELL=/bin/bash'); time.sleep(1)
    palette('Macro: saved macros'); time.sleep(0.6); text('one'); time.sleep(0.3); keys('Enter'); time.sleep(0.4)
    s = screen()
    check('519 lists: a saved macro\'s menu is its own', 'Macro: one' in s, s)
    keys('Enter'); time.sleep(0.6)
    check('519 lists: … and plays it', 'AAA' in screen() and 'BBB' not in screen(), screen())
    keys('C-z'); time.sleep(0.3)
    palette('Nim: exports nothing uses'); ok = wait_for('Exported, used nowhere', 15); time.sleep(0.3)
    text('lonely1'); time.sleep(0.3); keys('Enter'); time.sleep(0.5)
    ln = [i for i, l in enumerate(ftext('src/demo/utils.nim').split('\n')) if 'proc lonely1' in l][0] + 1
    check('519 lists: an unused export goes to its own line', ok and ('Ln %d,' % ln) in screen(), screen()[-300:])
    keys('C-g'); text('%d:7' % (ln + 3)); keys('Enter'); time.sleep(0.3)
    palette('Nim: inline this proc'); ok = wait_for('by hand', 10); time.sleep(0.3)
    d = ftext('src/demo.nim').split('\n')
    first = [i for i, l in enumerate(d) if 'bump(1)' in l][0] + 1
    text(':%d' % first); time.sleep(0.3); keys('Enter'); time.sleep(0.5)
    check('519 lists: "change by hand" goes to the place picked', ok and ('Ln %d,' % first) in screen(), screen()[-300:])
    # terminal commands: the older one picked
    keys('C-\\'); time.sleep(1.5)
    text('echo first'); keys('Enter'); time.sleep(0.4); text('echo second'); keys('Enter'); time.sleep(0.6)
    keys('C-\\'); time.sleep(0.3)          # (back to the editor: Ctrl+P in the terminal is the shell's)
    palette('Terminal: commands'); time.sleep(0.6); text('second'); time.sleep(0.3); keys('Enter'); time.sleep(0.5)
    s = screen()
    check('519 lists: a terminal command\'s menu is its own', '$ echo second' in s and 'Copy its output' in s, s)
    keys('Escape')

MOCKURL = 'http://127.0.0.1:%d/v1' % AI_PORT

def t_520_agent_check():
    # the assistant's edit is checked with nim check: the error goes back with the result, and it fixes it
    setup({"ai.autoApprove": "edits", "ai.baseUrl": MOCKURL})
    start('src/demo/utils.nim', w=130, h=36); time.sleep(1)
    keys('M-c'); time.sleep(0.4); text('add a cube proc'); keys('Enter')
    ok = wait_for('cube.? is added', 60)
    u = ftext('src/demo/utils.nim')
    check('520 the agent fixed what nim check found, and it then checked clean', ok and 'and the check is' in screen() and
          'proc cube*(x: int): int = x * x * x' in u, screen() + u)
    log = open(MOCK_LOG).read()[-40000:]
    check('520 the error went back with the edit', "undeclared identifier: 'y'" in log and
          '[ned checked src/demo/utils.nim' in log, log[-2000:])
    s = screen()
    check('520 the chat shows each check', re.search(r'· . \d+ errors?', s) and re.search(r'· checked', s), s)
    # ai.checkEdits off: the error stays, the model is not told
    setup({"ai.autoApprove": "edits", "ai.baseUrl": MOCKURL, "ai.checkEdits": False})
    start('src/demo/utils.nim', w=130, h=36); time.sleep(1)
    keys('M-c'); time.sleep(0.4); text('add a cube proc'); keys('Enter')
    ok = wait_for('cube.? is added', 60)
    check('520 ai.checkEdits off: nothing checked', ok and 'and the check is' not in screen() and 'x * x * y' in ftext('src/demo/utils.nim'),
          screen())

def t_520_ai_tests():
    # AI: write tests — a file that does not compile goes back once; a failing test is dropped (and shown); the
    # rest is kept, and passes
    setup({"ai.baseUrl": MOCKURL})
    start('src/demo/utils.nim', w=130, h=36); time.sleep(1)
    palette('AI: write tests')
    ok = wait_for('Kept \\d+ AI-written test|none kept|no test file', 120)
    s = screen()
    p = W + '/tests/test_utils.nim'
    t = open(p).read() if os.path.exists(p) else ''
    check('520 AI tests: kept the ones that pass', ok and 'Kept 2 AI-written tests in tests/test_utils.nim' in s and
          'twice doubles' in t and 'shout adds a bang' in t and 'twice of a negative' not in t, s + t)
    log = open(MOCK_LOG).read()[-60000:]
    check('520 AI tests: the compile error went back to the model', 'Your previous file does not compile' in log and
          'twicee' in log, log[-1500:])
    keys('M-1'); time.sleep(0.4)
    s = screen()
    check('520 AI tests: the failing one is shown with why', 'Dropped AI tests' in s, s)
    r = subprocess.run(('cd %s/tests && ' + NIMBIN + '/nim c -r --hints:off test_utils.nim 2>&1 | tail -4') % W,
                       shell=True, capture_output=True, text=True)
    check('520 AI tests: the kept file passes', '[OK] twice doubles' in r.stdout and 'FAILED' not in r.stdout, r.stdout)
    keys('C-p'); time.sleep(0.4); text('Dropped'); time.sleep(0.5)
    keys('Escape'); time.sleep(0.3)
    check('520 AI tests: no file left behind for the dropped ones', sorted(os.listdir(W + '/tests')) ==
          ['config.nims', 'test_demo.nim', 'test_utils', 'test_utils.nim'] or
          sorted(os.listdir(W + '/tests')) == ['config.nims', 'test_demo.nim', 'test_utils.nim'], str(os.listdir(W + '/tests')))

def t_521_remote():
    need('ssh-server', 'fish')
    # a server whose login shell is fish: everything still runs there (with sh); git; Run on the server with its
    # changes copied back; changes made on the server by other means arrive by themselves; the assistant's
    # commands run on the server too
    base = TMP + '/remote-srv3'
    srv = base + '/proj'
    shutil.rmtree(base, ignore_errors=True)
    os.makedirs(srv)
    for n, t in [('a.txt', 'alpha\n'), ('notes.txt', 'first\n')]:
        open(srv + '/' + n, 'w').write(t)
    G = 'git -C %s -c user.name=srv -c user.email=s@s ' % srv
    sh('git init -q -b main ' + srv); sh(G + 'add -A'); sh(G + 'commit -qm base')
    sh(G + 'config user.name srv'); sh(G + 'config user.email s@s')
    SP = SSH_DIR + ':' + TOOLS + ':/usr/bin:/bin'
    sh('for c in ' + SSH_CTL + '/*; do ' + SSH_DIR + '/ssh -o ControlPath=$c -O exit x 2>/dev/null; done; rm -f ' + SSH_CTL + '/*')
    setup({"remote.autoSync": 2, "ai.autoApprove": "all", "ai.baseUrl": MOCKURL})
    start('src/demo.nim', w=130, h=40, path=SP); time.sleep(0.5)
    palette('Remote: open a folder over SSH'); time.sleep(0.3); text('fishbox:' + srv); keys('Enter')
    ok = wait_for('and git', 30)
    check('521 fish login shell: the folder opens, git found', ok, screen())
    mirror = (sh('ls -d %s/ned/remote/fishbox/*/proj' % STATE).stdout.split() or ['?'])[0]
    keys('C-p'); time.sleep(0.3); text('a.txt'); time.sleep(0.4); keys('Enter'); time.sleep(0.4)
    keys('C-End'); keys('Enter'); text("it's \\ fine!"); keys('C-s'); ok = wait_for('Saved on fishbox', 15); time.sleep(0.5)
    check('521 fish: a save reaches the server, quotes and backslashes intact', ok and
          open(srv + '/a.txt').read() == "alpha\nit's \\ fine!\n", repr(open(srv + '/a.txt').read()))
    palette('Git: commit (message box)'); time.sleep(0.8)
    text("don't stop"); keys('C-s'); time.sleep(0.6); keys('y'); time.sleep(3)
    log = sh(G + 'log -1 --format=%s').stdout.strip()
    check('521 fish: git commits on the server (the message goes along)', log == "don't stop", log + screen()[-500:])
    # changed on the server by something else: here within a few seconds, the open tab too
    keys('C-p'); time.sleep(0.3); text('notes.txt'); time.sleep(0.4); keys('Enter'); time.sleep(0.4)
    time.sleep(2.5)
    open(srv + '/notes.txt', 'w').write('first\nadded on the server\n')
    ok = wait_for('added on the server', 15)
    check('521 a change on the server comes over by itself (open tab reloaded)', ok and
          'added on the server' in open(mirror + '/notes.txt').read(), screen())
    # Run on the server; what it writes there comes back
    palette('Run command'); time.sleep(0.5); keys('C-u'); text('echo made > gen.txt && echo ran'); keys('Enter')
    ok = wait_for('Finished in', 20); time.sleep(2)
    s = screen()
    check('521 Run: on the server, shown as typed', ok and 'echo made > gen.txt && echo ran  (on fishbox)' in s, s)
    check('521 Run: the file it made is copied back', os.path.exists(mirror + '/gen.txt') and
          os.path.exists(srv + '/gen.txt'), str(os.listdir(mirror)))
    # the assistant's commands run on the server
    keys('M-c'); time.sleep(0.4); text('run the generator'); keys('Enter')
    ok = wait_for('Tool said', 30); time.sleep(1)
    check('521 the assistant\'s command ran on the server', ok and os.path.exists(srv + '/fromagent.txt') and
          'on fishbox' in screen(), screen())
    check('521 … and its file is here before it reads on', os.path.exists(mirror + '/fromagent.txt'), str(os.listdir(mirror)))
    tm('kill-server')

def t_521_git():
    # the history of a proc's lines; bisect by hand and with a command; worktrees; submodules
    setup()
    G = 'git -C %s -c user.name=t -c user.email=t@t ' % W
    def commit(msg, path, txt, mode='w'):
        open(W + '/' + path, mode).write(txt)
        sh(G + 'add -A'); sh(G + 'commit -qm ' + shlex.quote(msg))
    u = ftext('src/demo/utils.nim')
    commit('shout louder', 'src/demo/utils.nim', u.replace('s.toUpperAscii & "!"', 's.toUpperAscii & "!!"'))
    commit('twice docs', 'src/demo/utils.nim', ftext('src/demo/utils.nim').replace('proc twice*(x: int): int = x * 2',
                                                                                   'proc twice*(x: int): int = x * 2  # doubled'))
    commit('shout doc', 'src/demo/utils.nim', ftext('src/demo/utils.nim').replace('## upper-case and add a bang', '## louder'))
    for i in range(1, 8):
        commit('c%d' % i, 'bug.txt', ('broken\n' if i >= 4 else 'fine\n') + 'step %d\n' % i)
    start('src/demo/utils.nim', w=130, h=40); time.sleep(1)
    keys('C-g'); text('4'); keys('Enter'); time.sleep(0.3)
    palette('Git: history of these lines'); ok = wait_for('changed shout', 15); time.sleep(0.3)
    s = screen()
    check('521 line history: the commits that changed the proc, not the others', ok and 'shout louder' in s and
          'shout doc' in s and 'twice docs' not in s and 'History of shout' in s, s)
    keys('C-Home'); keys('Enter'); time.sleep(0.6)
    s = screen()
    m = re.search(r'@@ ([0-9a-f]{8})', s)
    check('521 line history: Enter opens the commit', m and ('╭─ ' + m.group(1)) in s, s)
    keys('Escape'); time.sleep(0.3); keys('M-1'); time.sleep(0.3)
    # bisect by hand: say good or bad until it names the commit
    def bisect_start(how):
        palette('Git: find the commit that broke it'); time.sleep(0.8)
        text('c1'); time.sleep(0.3); keys('Enter'); time.sleep(0.4)
        text(how); time.sleep(0.3); keys('Enter'); time.sleep(0.4)
    bisect_start("I'll say")
    ok = wait_for('BISECTING|testing', 10)
    check('521 bisect: it starts, the Git dock says so', ok and 'BISECTING' in screen(), screen())
    steps = 0
    while steps < 6 and 'first bad commit' not in screen():
        bad = 'broken' in open(W + '/bug.txt').read()
        palette('Git: bisect — ' + ('bad' if bad else 'good')); time.sleep(1.2)
        steps += 1
    s = screen()
    check('521 bisect by hand: it finds the commit', 'first bad commit' in s and ' c4' in s, s)
    keys('y'); time.sleep(1.5)
    head = sh(G + 'rev-parse --abbrev-ref HEAD').stdout.strip()
    check('521 bisect: stopped, back on the branch', head == 'master' and 'BISECTING' not in screen(), head + screen())
    # bisect with a command
    keys('Escape'); time.sleep(0.3)
    bisect_start('A command')
    keys('C-u'); text('! grep -q broken bug.txt'); keys('Enter')
    ok = wait_for('first bad commit is', 60)
    check('521 bisect with a command: it finds the commit', ok and ' c4' in screen(), screen())
    keys('y'); time.sleep(1.5)
    head = sh(G + 'rev-parse --abbrev-ref HEAD').stdout.strip()
    check('521 bisect with a command: back on the branch', head == 'master', head)
    # worktrees: a new one on a new branch, listed, then removed
    keys('Escape'); time.sleep(0.3)
    wt = os.path.dirname(W) + '/work-feat-x'
    shutil.rmtree(wt, ignore_errors=True)
    palette('Git: worktrees'); time.sleep(0.8); text('New worktree'); keys('Enter'); time.sleep(0.6)
    text('A new branch'); keys('Enter'); time.sleep(0.4); text('feat-x'); keys('Enter'); time.sleep(0.4)
    keys('Enter'); ok = wait_for('Open .* now', 10); keys('n'); time.sleep(0.4)
    lst = sh(G + 'worktree list').stdout
    check('521 worktrees: a new one, on its own branch', ok and wt in lst and '[feat-x]' in lst, lst + screen())
    palette('Git: worktrees'); time.sleep(0.8)
    check('521 worktrees: listed', 'work-feat-x' in screen() and 'feat-x' in screen(), screen())
    text('work-feat-x'); keys('Enter'); time.sleep(0.4); text('Remove'); keys('Enter'); time.sleep(0.4); keys('y'); time.sleep(2)
    check('521 worktrees: removed', wt not in sh(G + 'worktree list').stdout and not os.path.exists(wt), sh(G + 'worktree list').stdout)
    # submodules: add one; it shows in the Git dock as a repository of its own
    sub = os.path.dirname(W) + '/libsub-src'
    shutil.rmtree(sub, ignore_errors=True); os.makedirs(sub)
    open(sub + '/lib.nim', 'w').write('proc lib*(): int = 1\n')
    sh('git init -q -b main %s && git -C %s -c user.name=t -c user.email=t@t add -A && git -C %s -c user.name=t -c user.email=t@t commit -qm lib' % (sub, sub, sub))
    sh('git config --global protocol.file.allow always')
    keys('Escape'); time.sleep(0.3)
    palette('Git: submodules'); time.sleep(0.8); text('Add a submodule'); keys('Enter'); time.sleep(0.4)
    text(sub); keys('Enter'); time.sleep(0.4); keys('C-u'); text('vendor/libsub'); keys('Enter')
    ok = wait_for('Submodule added', 20)
    check('521 submodules: added', ok and os.path.exists(W + '/vendor/libsub/lib.nim') and
          'vendor/libsub' in open(W + '/.gitmodules').read(), screen())
    palette('Git: submodules'); time.sleep(1)
    check('521 submodules: listed with their state', 'vendor/libsub' in screen() and 'up to date' in screen(), screen())
    keys('Escape'); time.sleep(0.3)
    keys('M-g'); time.sleep(2)
    s = screen()
    check('521 submodules: the Git dock shows it as a repository', 'REPOSITORIES' in s and 'libsub' in s, s)
    tm('kill-server')

def t_522_perf():
    # ned --startup-time: the steps, the first frame, the memory, then it quits by itself; a forward declaration
    # gets no reference count (its callers may be in files it includes); the counts still come in a project
    setup()
    start('--startup-time', 'src/demo.nim', w=120, h=34)
    ok = wait_for('STARTUP first_frame_ms=', 20)
    s = screen()
    check('522 --startup-time: the report, then it quits', ok and 'settings' in s and 'first frame' in s and
          'memory settled' in s and re.search(r'rss_settled_mb=\d', s) and 'EXITED 0' in open(W + '/exit').read(), s)
    setup()
    open(W + '/src/demo/utils.nim', 'a').write('\nproc fwd*(x: int): int\nproc user*(): int = fwd(1)\nproc fwd*(x: int): int = x\n')
    open(W + '/src/demo.nim', 'a').write('  echo user()\n')
    start('src/demo/utils.nim', w=120, h=34); time.sleep(1)
    ok = wait_for('proc user.*1 reference', 15); time.sleep(0.5)
    lines = screen().split('\n')
    fwd = [l for l in lines if 'proc fwd*(x: int): int' in l]
    check('522 reference counts: on the implementation, not on its forward declaration', ok and len(fwd) == 2 and
          'reference' not in fwd[0] and '1 reference' in fwd[1], '\n'.join(lines))
    # ned --format from the shell: --check lists, then it formats in place
    open(W + '/messy.nim', 'w').write('proc g(a:int,b:int):int=\n    a+b\n')
    r1 = subprocess.run([BIN, '--format', '--check', W + '/messy.nim'], capture_output=True, text=True)
    r2 = subprocess.run([BIN, '--format', W + '/messy.nim'], capture_output=True, text=True)
    r3 = subprocess.run([BIN, '--format', '--check', W + '/messy.nim'], capture_output=True, text=True)
    check('522 ned --format: check, format in place, then nothing to do', r1.returncode == 1 and 'would change' in r1.stdout and
          r2.returncode == 0 and ftext('messy.nim') == 'proc g(a: int, b: int): int =\n  a + b\n' and r3.returncode == 0,
          repr((r1.returncode, r1.stdout, r2.returncode, r2.stdout, ftext('messy.nim'), r3.returncode)))

def t_521_format_self():
    # the built-in formatter on ned.nim itself (it once refused: "would change the block structure") — and on
    # a field list with a long comment, and long fields of a one-line `type X = object`
    setup()
    shutil.copy(ned_single_file(), W + '/big.nim')
    open(W + '/fields.nim', 'w').write('type Remote = object\n  host, path, absPath, mirror, ctl: string    # path: as typed (~ allowed)'
                                       ' · absPath: the real folder\n  hostName, pathName, absolutePathName, mirrorFolder, '
                                       'controlPath: Table[string, seq[string]]\n')
    start('fields.nim', w=130, h=30); time.sleep(0.8)
    keys('M-f'); ok = wait_for(r'Formatted \(built-in', 6); keys('C-s'); time.sleep(0.5)
    t = ftext('fields.nim')
    check('521 format: a long comment goes under the fields, long fields wrap like nph', ok and t ==
          'type Remote = object\n  host, path, absPath, mirror, ctl: string\n    # path: as typed (~ allowed) · absPath: the real folder\n'
          '  hostName, pathName, absolutePathName, mirrorFolder, controlPath:\n    Table[string, seq[string]]\n', repr(t) + screen())
    keys('C-p'); time.sleep(0.4); text('big.nim'); time.sleep(0.5); keys('Enter'); time.sleep(1.5)
    keys('M-f'); ok = wait_for(r'Formatted \(built-in|block structure|change the code', 30)
    s = screen()
    check('521 format: ned.nim itself formats', ok and 'Formatted (built-in' in s and 'block structure' not in s, s)
    keys('C-s'); time.sleep(1.5)
    r = subprocess.run(('cd %s && ' + NIMBIN + '/nim check --hints:off big.nim 2>&1 | grep -c Error') % W,
                       shell=True, capture_output=True, text=True)
    check('521 format: … and still compiles', r.stdout.strip() == '0' and ftext('big.nim').count('\n') > 50000, r.stdout)
    keys('M-f'); check('521 format: … and formatting it again changes nothing', wait_for('Already formatted', 30), screen()[-300:])

def t_523_include():
    # files pulled in with `include` see what their includer sees: its imports, its other include files —
    # references, counts, go to definition, completion
    setup({"nim.nimsuggest": False})
    d = W + '/inc'
    os.makedirs(d, exist_ok=True)
    open(d + '/main.nim', 'w').write('import std/strutils\ntype Conf = object\n  title: string\nproc fwd(x: int): int\ninclude partA, partB\n\n'
                                     'when isMainModule:\n  echo fwd(1), helperB("x")\n')
    open(d + '/partA.nim', 'w').write('proc fwd(x: int): int = x + helperB2()\n\n'
                                      'proc helperA*(s: string): string = s.toUpperAscii\n')
    open(d + '/partB.nim', 'w').write('proc helperB*(s: string): string = helperA(s) & "!"\n\nproc helperB2(): int = 1\n')
    start('inc/partA.nim', w=130, h=34); time.sleep(1)
    ok = wait_for('proc helperA.*1 reference', 15)
    check('523 include: a proc used in a sibling include file is counted', ok, screen())
    keys('C-p'); time.sleep(0.4); text('partB.nim'); time.sleep(0.5); keys('Enter'); time.sleep(1)
    ok = wait_for('proc helperB2.*1 reference', 15)
    check('523 include: … and the other way round', ok, screen())
    keys('C-g'); text('1:37'); keys('Enter'); time.sleep(0.3); keys('F12'); time.sleep(1.2)
    s = screen()
    check('523 include: go to definition into the sibling file', 'partA.nim' in s.split('\n')[1] and 'Ln 3,' in s, s)
    keys('C-End'); keys('Enter'); text('proc t2(s: string): string = s.toUpperA'); time.sleep(0.3); keys('C-Space'); time.sleep(1)
    check('523 include: completion knows what the includer imports', 'toUpperAscii' in screen(), screen())
    keys('Escape'); keys('End'); keys('Enter'); text('proc t3(c: Conf): string = c.ti'); time.sleep(0.3); keys('C-Space'); time.sleep(1)
    check('523 include: the includer\'s private fields complete', 'title' in screen().split('proc t3')[-1], screen())
    keys('Escape')

def t_523_typehints():
    # the types of lets and vars, from ned's own engine — nimsuggest off
    setup({"nim.nimsuggest": False})
    open(W + '/th.nim', 'w').write('import std/tables\nlet a = 5\nproc f() =\n  let t = initTable[string, int]()\n'
                                   '  var s = @[1, 2]\n  for x in s:\n    let y = x * 2\n    echo y\n  var\n    p = "a" & "b"\n'
                                   '  let (u, v) = (1, "x")\n  echo t, p, u, v\nf()\n')
    start('th.nim', w=120, h=30); time.sleep(1)
    ok = wait_for('let t: Table', 10)
    s = screen()
    check('523 type hints: from the built-in engine, without nimsuggest', ok and 'let a: int = 5' in s and
          'let t: Table[string, int] = initTable' in s and 'var s: seq[int] = @[1, 2]' in s and 'let y: int = x * 2' in s and
          'p: string = "a" & "b"' in s and 'let (u: int, v: string)' in s, s)
    keys('C-g'); text('2'); keys('Enter'); keys('End'); text('.0'); time.sleep(1.5)
    check('523 type hints: follow an edit', 'let a: float = 5.0' in screen(), screen())
    open(W + '/e.nim', 'w').write('import std/[os, strutils]\nproc f(n: int, fl: float32) =\n  let a = readFile("x")\n'
        '  let b = n / 2\n  let c = 0 ..< n\n  let d = n and 0xFF\n  let e = n > 2 and n < 9\n  let g = fl / 2\n'
        '  let h = getAppDir() / "x"\n  let k = "a,b".split(\',\')\n  let m = stdin.readLine()\n  echo a, b, c, d, e, g, h, k, m\n')
    keys('C-o'); time.sleep(0.4); keys('C-u'); text(W + '/e.nim'); keys('Enter'); time.sleep(1)
    ok = wait_for('let b: float', 10)
    s = screen()
    check('523 type hints: system\'s readFile, / of integers, slices, bits, a literal\'s methods, the overload by its arguments',
          ok and 'let a: string = readFile' in s and 'let c: HSlice[int, int] = 0 ..< n' in s and 'let d: int = n and' in s and
          'let e: bool = n > 2' in s and 'let g: float32 = fl / 2' in s and 'let h: string = getAppDir' in s and
          'let k: seq[string] = "a,b"' in s and 'let m: string = stdin.readLine' in s, s)

def t_523_charlit():
    # Nim character literals: '"' does not start a string (it used to colour the rest of the file as one)
    setup({"nim.nimsuggest": False})
    open(W + '/cl.nim', 'w').write('proc a(s: string): int =\n  var i = 0\n  if s[i] == \'"\': inc i  # """" a quote\n'
                                   '  let n = 5\n  n + i\nproc b() = discard\n')
    start('cl.nim', w=100, h=20); time.sleep(1)
    ok = wait_for('let n: int', 10)
    import re as _re
    a = tm('capture-pane', '-t', 'f', '-e', '-p').stdout.splitlines()
    def sgr_before(word, nth):
        rows = [l for l in a if word in _re.sub(r'\x1b\[[0-9;]*m', '', l)]
        if len(rows) <= nth: return None
        l = rows[nth]
        k = l.find(word)
        return _re.findall(r'\x1b\[[0-9;]*m', l[:k])[-1:]
    check('523 a char literal with a quote ends where it should', ok and sgr_before('proc', 0) == sgr_before('proc', 1) and
          sgr_before('proc', 0) is not None, screen())

def t_524_debug():
    need('gdb')
    # logpoints (print, do not stop) and "stop when it changes" — gdb for Nim, DAP for the others
    setup({"nim.nimsuggest": False})
    open(W + '/g.nim', 'w').write('var counter = 0\nproc bump(n: int) =\n  var local = n * 2\n  counter += local\n  echo n\n'
                                  'for i in 1 .. 3:\n  bump(i)\necho counter\n')
    start('g.nim', w=120, h=44); time.sleep(1)
    keys('C-g'); text('4'); keys('Enter'); time.sleep(0.3)
    palette('Debug: logpoint on this line'); time.sleep(0.4)
    text('n = {n}, local = {local}, counter = {counter}'); keys('Enter'); time.sleep(0.4)
    s = screen()
    check('524 logpoint: ◇ in the gutter', [l for l in s.splitlines() if 'counter += local' in l][0].lstrip().startswith('◇'), s)
    keys('F5')
    ok = wait_for('program exited', 60) and wait_for('n = 3, local = 6, counter = 6', 15)
    s = screen()
    check('524 logpoint (gdb): printed each time with the values (a global too), without stopping',
          ok and 'n = 1, local = 2, counter = 0' in s and 'n = 3, local = 6, counter = 6' in s, s)
    keys('C-g'); text('4'); keys('Enter'); keys('F9'); time.sleep(0.3)
    check('524 F9 removes a logpoint', '◇' not in [l for l in screen().splitlines() if 'counter += local' in l][0], screen())
    keys('C-g'); text('1:5'); keys('Enter'); time.sleep(0.3)
    palette('Debug: stop when this changes'); time.sleep(0.4); keys('Enter'); time.sleep(0.4)
    keys('F5')
    ok = wait_for(r'counter changed \(0 → 2\)', 60)
    check('524 stop when it changes (gdb): stopped where counter changed, old → new', ok and 'STOP WHEN IT CHANGES' in screen(), screen())
    keys('F5')
    ok = wait_for(r'counter changed \(2 → 6\)', 20)
    check('524 … and at the next change', ok, screen())
    keys('S-F5'); time.sleep(0.5)
    tm('kill-server')
    # an adapter without logpoints: ned prints them itself; data breakpoints
    setup({"debug.adapters": {"go": {"command": ["python3", MOCKS + "/mockdap.py", "$port"], "connect": True,
                                     "launch": {"program": "$file"}}}})
    os.makedirs(W + '/gop', exist_ok=True)
    open(W + '/gop/main.go', 'w').write('package main\n\nfunc main() {\n\tanswer := 42\n\tprintln(answer)\n}\n')
    start('gop/main.go', w=130, h=50); time.sleep(0.5)
    keys('C-g'); text('5'); keys('Enter')
    palette('Debug: logpoint on this line'); time.sleep(0.4); text('answer is {answer}'); keys('Enter'); time.sleep(0.3)
    keys('F5')
    ok = wait_for('exited with code 3', 15)
    check('524 logpoint through DAP (the adapter has none): ned prints it and goes on', ok and 'answer is 84' in screen(), screen())
    keys('C-g'); text('5'); keys('Enter'); keys('F9'); time.sleep(0.2); keys('F9'); time.sleep(0.2)
    keys('F5')
    ok = wait_for('stopped', 15); time.sleep(0.8)
    palette('Debug: stop when this changes'); time.sleep(0.4); keys('C-u'); text('answer'); keys('Enter'); time.sleep(0.6)
    keys('F5'); time.sleep(1)
    palette('Debug: show the debug panel'); time.sleep(0.5)
    ok = wait_for('answer changed', 10)
    check('524 stop when it changes through DAP (a data breakpoint)', ok and 'data breakpoint' in screen(), screen())
    keys('S-F5'); time.sleep(0.5)

def t_524_format():
    # ned's own JSON, Markdown and CSS formatters (no prettier on the PATH), format on save for chosen languages,
    # every file of the project at once (reviewed, undone), the code in a Nim string, and the shell
    setup({"nim.nimsuggest": False, "editor.formatOnSave": True, "editor.formatOnSaveLanguages": ["json"]})
    nop = NIMBIN + ':/usr/bin:/bin'
    open(W + '/a.json', 'w').write('{"name":"ned", "big": 123456789012345678901234567890, "f": 1e5,\n// keep me\n"tags":["x","y"]}\n')
    open(W + '/t.md', 'w').write('# T\n\n| a | bb |\n|---|:-:|\n| longer cell | 1 |\n')
    open(W + '/s.css', 'w').write('body{margin:0;color:red}\na,b{x:url(data:a;b,c)}\n')
    open(W + '/e.nim', 'w').write('import std/json\nlet j = parseJson("""\n  {"a":1,"b":[1,2]}\n  """)\necho j\n')
    start('t.md', w=130, h=40, path=nop); time.sleep(1)
    keys('M-f'); time.sleep(0.6); keys('C-s'); time.sleep(0.5)
    check('524 Markdown: Alt+F lines up the tables (built in)',
          '| a           | bb  |\n| ----------- | :-: |\n| longer cell |  1  |' in ftext('t.md'), ftext('t.md'))
    keys('C-p'); text('s.css'); time.sleep(0.5); keys('Enter'); time.sleep(0.6)
    keys('M-f'); time.sleep(0.6); keys('C-s'); time.sleep(0.5)
    check('524 CSS: one declaration per line, a url() left as it is (built in)',
          ftext('s.css') == 'body {\n  margin: 0;\n  color: red;\n}\na,\nb {\n  x: url(data:a;b,c);\n}\n', ftext('s.css'))
    keys('C-p'); text('a.json'); time.sleep(0.5); keys('Enter'); time.sleep(0.6)
    keys('End'); text(' '); keys('C-s'); time.sleep(0.6)
    t = ftext('a.json')
    check('524 JSON: formatted on save (in the languages chosen), numbers and comments kept as written',
          '  "big": 123456789012345678901234567890,\n  "f": 1e5,\n  // keep me\n  "tags": ["x", "y"]\n' in t, t)
    open(W + '/u.md', 'w').write('| a | b |\n|-|-|\n| c | d |\n')
    keys('C-o'); time.sleep(0.4); keys('C-u'); text(W + '/u.md'); keys('Enter'); time.sleep(0.6)
    keys('End'); text(' '); keys('C-s'); time.sleep(0.6)
    check('524 … and not in the others', ftext('u.md').startswith('| a | b |'), ftext('u.md'))
    # the string's JSON
    keys('C-p'); text('e.nim'); time.sleep(0.5); keys('Enter'); time.sleep(0.8)
    keys('C-g'); text('3:5'); keys('Enter'); keys('M-Enter')
    ok = wait_for('Format the JSON in this string', 8)
    if ok:
        text('Format the JSON'); time.sleep(0.3); keys('Enter'); time.sleep(0.6); keys('C-s'); time.sleep(0.5)
    check('524 the JSON in a Nim string, at its indentation (Alt+Enter)',
          ok and '"""\n  {\n    "a": 1,\n    "b": [1, 2]\n  }\n  """' in ftext('e.nim'), ftext('e.nim') + screen())
    # every file of the project
    open(W + '/v.json', 'w').write('{"z":[ 1,2 ]}\n')
    os.makedirs(W + '/node_modules/x', exist_ok=True)
    open(W + '/node_modules/x/p.json', 'w').write('{"keep":1}\n')
    palette('Format: every file in the project'); time.sleep(0.5)
    ok = wait_for('would change', 30)
    s = screen()
    check('524 the project: the files that would change, listed before anything is written',
          ok and 'v.json' in s and 'u.md' in s and 'node_modules' not in s and ftext('v.json') == '{"z":[ 1,2 ]}\n', s)
    keys('Enter'); time.sleep(1)
    palette('Save all'); time.sleep(0.5)
    check('524 … formatted (the open ones in the editor)', ftext('v.json') == '{\n  "z": [1, 2]\n}\n' and ftext('u.md').startswith('| a   | b   |'),
          ftext('v.json') + ftext('u.md'))
    ok = wait_for('Undo', 5)
    pos = find_on_screen('Undo')
    if pos: click(pos[0], pos[1]); time.sleep(0.8)
    s = screen()
    check('524 … and Undo puts them back', ftext('v.json') == '{"z":[ 1,2 ]}\n', ftext('v.json') + s)
    # the shell
    r = subprocess.run([BIN, '--format', '--check', W], capture_output=True, text=True)
    check('524 ned --format --check FOLDER: lists the files, exit 1', r.returncode == 1 and 'v.json: would change' in r.stdout and
          'node_modules' not in r.stdout, r.stdout + r.stderr)

def t_524_deps():
    # the dependency tree: what requires what, the versions installed, what is missing or too old
    setup({"nim.nimsuggest": False})
    nd = TMP + '/fakenimble'
    shutil.rmtree(nd, ignore_errors=True)
    def pkg(name, ver, reqs):
        d = nd + '/pkgs2/%s-%s-%s' % (name, ver, 'a' * 40)
        os.makedirs(d, exist_ok=True)
        open(d + '/%s.nimble' % name, 'w').write('version = "%s"\nrequires %s\n' % (ver, ', '.join('"%s"' % r for r in reqs)))
    pkg('jsony', '1.1.5', ['nim >= 1.4'])
    pkg('chronos', '4.0.3', ['nim >= 1.6', 'results', 'stew >= 0.1.0', 'bearssl >= 0.2.5', 'httputils'])
    pkg('results', '0.4.0', ['nim >= 1.2'])
    pkg('stew', '0.2.0', ['results'])
    pkg('httputils', '0.3.0', ['stew >= 0.3.0'])
    for f in os.listdir(W):
        if f.endswith('.nimble'): os.remove(W + '/' + f)
    open(W + '/app.nimble', 'w').write('version = "0.3.1"\nauthor = "Ann"\ndescription = "x"\nlicense = "MIT"\n'
        'requires "nim >= 2.0.0",\n  "jsony >= 1.1.0",\n  "chronos ^= 4.0"\nrequires "https://github.com/foo/missingpkg.git"\n')
    start('app.nimble', w=130, h=44, env_extra='NIMBLE_DIR=' + nd); time.sleep(1.5)
    palette('Nimble: dependency tree'); time.sleep(1)
    s = screen()
    rows = {r.split('──')[-1].split()[0]: r for r in s.splitlines() if '──' in r}
    check('524 deps: the tree with the versions installed', 'jsony' in rows and '1.1.5 ✓' in rows['jsony'] and
          '4.0.3 ✓' in rows.get('chronos', '') and '│   ├── results' in s and '2.2.12 ✓' in rows.get('nim', ''), s)
    check('524 deps: what is missing, what is too old for what wants it', '✗ not installed' in rows.get('bearssl', '') and
          '0.2.0 ✗ does not meet >= 0.3.0' in s and '✗ not installed' in rows.get('missingpkg', '') and
          '2 not installed · 1 too old' in s, s)
    keys('Down'); keys('Enter'); time.sleep(0.8)
    check('524 deps: Enter opens the package', 'jsony.nimble' in screen().split('\n')[1], screen())

def t_511_stale_errors():
    need('nimlangserver')
    # an error from a run goes away once it is fixed and saved — with nimlangserver too, and when the fix is in
    # another file — and stays while it is not fixed
    def run_with_error(cfg):
        setup(cfg); start('src/demo.nim'); time.sleep(2)
        if cfg: wait_for('nimlangserver', 10); time.sleep(3)
        keys('C-g'); time.sleep(0.5); text('10'); keys('Enter'); time.sleep(0.3); keys('End'); keys('Enter')
        text('let n: int = "x"'); keys('Enter'); text('echo n'); keys('C-s'); time.sleep(0.5)
        keys('M-r')
        return wait_for('mismatch', 60)
    def gone_within(t):
        end = time.time() + t
        while time.time() < end:
            if 'mismatch' not in screen(): return True
            time.sleep(0.5)
        return False
    for cfg, name in (({"nim.ide": "nimlangserver"}, 'nimlangserver'), ({}, 'built-in engine')):
        check('511 %s: the run shows the error' % name, run_with_error(cfg), screen())
        keys('Escape'); time.sleep(0.3)
        keys('C-g'); time.sleep(0.5); text('1'); keys('Enter'); keys('End'); text(' # still broken'); keys('C-s')
        time.sleep(8)
        check('511 %s: saved but not fixed: the error stays' % name, 'mismatch' in screen(), screen())
        if cfg: check('511 nimlangserver: shown once, not once per source', re.search(r'● 1 ', screen()), screen()[-300:])
        keys('C-g'); time.sleep(0.5); text('11'); keys('Enter'); time.sleep(0.3); keys('End')
        keys('BSpace', 'BSpace', 'BSpace'); text('1'); keys('C-s')
        check('511 %s: fixed and saved: the error goes' % name, gone_within(15), screen())
    # the cause is in another file
    setup()
    u = open(W + '/src/demo/utils.nim').read().replace('proc twice*(x: int): int = x * 2', 'proc twice*(x: string): string = x & x')
    open(W + '/src/demo/utils.nim', 'w').write(u)
    open(W + '/src/demo.nim', 'a').write('  echo twice(2)\n')
    start('src/demo.nim'); time.sleep(2)
    keys('M-r')
    check('511 cross-file: the run shows the error', wait_for('mismatch', 60), screen())
    keys('Escape'); time.sleep(0.3)
    keys('C-p'); time.sleep(0.4); text('utils.nim'); time.sleep(0.6); keys('Enter'); time.sleep(1)
    keys('C-g'); time.sleep(0.5); text('1'); keys('Enter'); keys('End'); text(' # unrelated'); keys('C-s'); time.sleep(0.5)
    keys('C-p'); time.sleep(0.4); text('src/demo.nim'); time.sleep(0.6); keys('Enter'); time.sleep(8)
    check('511 cross-file: an unrelated save leaves it', 'mismatch' in screen(), screen())
    keys('C-p'); time.sleep(0.4); text('utils.nim'); time.sleep(0.6); keys('Enter'); time.sleep(1)
    keys('C-g'); time.sleep(0.5); text('7'); keys('Enter'); time.sleep(0.3)
    keys('Home'); keys('S-End'); text('proc twice*(x: int): int = x * 2'); keys('C-s'); time.sleep(0.5)
    keys('C-p'); time.sleep(0.4); text('src/demo.nim'); time.sleep(0.6); keys('Enter')
    check('511 cross-file: fixing the other file clears it', gone_within(15), screen())

def fg_map(ansi):
    """the screen as text lines, each with the foreground colour of every character"""
    out = []
    for raw in ansi.split('\n'):
        txt, cols, fg = '', [], 'default'
        i = 0
        while i < len(raw):
            if raw[i] == '\x1b' and i + 1 < len(raw) and raw[i+1] == '[':
                j = i + 2
                while j < len(raw) and not ('@' <= raw[j] <= '~'): j += 1
                if j < len(raw) and raw[j] == 'm':
                    ps = raw[i+2:j].split(';') if raw[i+2:j] else ['0']
                    k = 0
                    while k < len(ps):
                        if ps[k] == '38' and k + 4 < len(ps) and ps[k+1] == '2':
                            fg = ';'.join(ps[k+2:k+5]); k += 5; continue
                        if ps[k] in ('0', '39', ''): fg = 'default'
                        elif ps[k] in ('48', '58') and k + 1 < len(ps) and ps[k+1] == '2': k += 5; continue
                        k += 1
                i = j + 1
                continue
            txt += raw[i]; cols.append(fg); i += 1
        out.append((txt, cols))
    return out

def fg_of(m, needle, offset=0):
    for txt, cols in m:
        k = txt.find(needle)
        if k >= 0 and k + offset < len(cols): return cols[k + offset]
    return None

def t_511_embedded():
    # code of another language inside Nim strings, templates and Markdown, coloured as that language
    setup({"theme": "one-dark", "editor.languageServerHints": False, "nim.ide": "off"})
    for x in os.listdir(FIX + '/emb'): shutil.copy(FIX + '/emb/' + x, W + '/' + x)
    start('web.nim', w=110, h=60); time.sleep(2)
    m = fg_map(tm('capture-pane', '-t', 'f', '-e', '-p').stdout)
    kw, st, cm = fg_of(m, 'proc cTwice'), fg_of(m, '"shop.db"'), fg_of(m, '# nim comment')
    check('511 references found', None not in (kw, st, cm) and len({kw, st, cm}) == 3, str((kw, st, cm)))
    check('511 emit: a C block comment', fg_of(m, '/* a C comment') == cm, str(fg_of(m, '/* a C comment')))
    check('511 emit: a C line comment', fg_of(m, '// doubled') == cm)
    check('511 emit: .} after the block is the pragma again', fg_of(m, '""".}', 3) == fg_of(m, '{.emit'), str(fg_of(m, '""".}', 3)))
    check('511 HTML in a string: tags', fg_of(m, '<title>Shop', 1) not in (st, None), str(fg_of(m, '<title>Shop', 1)))
    check('511 HTML: <style> is CSS', fg_of(m, 'margin: 0') not in (st, fg_of(m, '<title>Shop', 1), None))
    check('511 HTML: <script> is JavaScript', fg_of(m, 'const n = 3') == kw, str(fg_of(m, 'const n = 3')))
    check('511 Nim again after the string', fg_of(m, 'let name = "Ann"') == kw)
    check('511 fmt: {expressions} stand out', fg_of(m, '{name}') not in (st, None) and fg_of(m, '{name}', 1) != st)
    check('511 fmt: {{ is an escape, the text a string', fg_of(m, '{{braces', 2) == st and fg_of(m, '{{braces') != st)
    check('511 sql"…" is SQL', fg_of(m, 'SELECT id, name') == kw and fg_of(m, 'WHERE price') == kw)
    check('511 sql"""…""" over lines', fg_of(m, 'FROM orders') == kw and fg_of(m, '-- all of them') == cm)
    check('511 re"…": a class stands out', fg_of(m, '[\\w.+-]') not in (st, None), str(fg_of(m, '[\\w.+-]')))
    check('511 parseJson("""…"""): numbers', fg_of(m, '8080') not in (st, None))
    check('511 #[css]# marks a string', fg_of(m, 'padding: 4px') not in (st, None))
    check('511 a plain triple-quoted string stays a string', fg_of(m, 'just some text') == st and fg_of(m, 'if x then') == st)
    check('511 and Nim after it', fg_of(m, 'plain.len') not in (st, None))
    tag = fg_of(m, '<title>Shop', 1)
    # strformat templates: HTML with {expressions}
    keys('C-p'); time.sleep(0.4); text('shop.nim'); time.sleep(0.6); keys('Enter'); time.sleep(1.5)
    m = fg_map(tm('capture-pane', '-t', 'f', '-e', '-p').stdout)
    br = fg_of(m, '<title>{title}', 7)
    check('511 fmt"""…""" with HTML: the tags', fg_of(m, '<title>{title}', 1) == tag and fg_of(m, '<ul>{items}', 1) == tag,
          str((fg_of(m, '<title>{title}', 1), tag)))
    check('511 fmt"""…""" with HTML: {expressions} are Nim', br not in (tag, st, None) and fg_of(m, '{title}</title>', 1) != br)
    check('511 fmt"""…""" with HTML: {{ in its CSS', fg_of(m, 'li {{', 3) == br and fg_of(m, 'padding: 4px; color') != st)
    check('511 &"…" with HTML on one line', fg_of(m, '&"<li>', 3) == tag and fg_of(m, '{r[0]}') == br)
    # completion: none of Nim's inside C code, as usual in Nim code
    setup()
    d = open(W + '/src/demo.nim').read().replace('when isMainModule:',
        '{.emit: """\nstatic int one(void) {\n  return 1;\n}\n""".}\n\nwhen isMainModule:')
    open(W + '/src/demo.nim', 'w').write(d)
    start('src/demo.nim'); time.sleep(2)
    keys('C-g'); time.sleep(0.4); text('9'); keys('Enter'); keys('End'); keys('Enter'); text('p.')
    check('511 no Nim completion inside {.emit.} C code', not wait_for(r'name\s+string', 3), screen())
    keys('Escape'); keys('BSpace', 'BSpace')
    keys('C-g'); time.sleep(0.4); text('14'); keys('Enter'); keys('End'); keys('Enter'); text('echo p.')
    check('511 Nim completion in Nim code', wait_for(r'name\s+string', 4), screen())
    keys('Escape')
    # a source-code-filter template and Markdown code blocks
    setup({"theme": "one-dark", "editor.languageServerHints": False, "nim.ide": "off"})
    for x in os.listdir(FIX + '/emb'): shutil.copy(FIX + '/emb/' + x, W + '/' + x)
    start('page.nimf', w=110, h=40); time.sleep(2)
    m = fg_map(tm('capture-pane', '-t', 'f', '-e', '-p').stdout)
    check('511 .nimf: # lines are Nim', fg_of(m, '#proc', 1) == kw, str(fg_of(m, '#proc', 1)))
    check('511 .nimf: the rest is HTML', fg_of(m, '<h1>', 1) == tag)
    check('511 .nimf: $substitutions stand out', fg_of(m, '$title') not in (tag, None, 'default'))
    keys('C-p'); time.sleep(0.4); text('notes.md'); time.sleep(0.6); keys('Enter'); time.sleep(1.5)
    m = fg_map(tm('capture-pane', '-t', 'f', '-e', '-p').stdout)
    check('511 Markdown: a nim block is Nim', fg_of(m, 'proc greet') == kw and fg_of(m, '# a comment') == cm)
    check('511 Markdown: an sql block is SQL', fg_of(m, 'SELECT *') == kw)
    check('511 Markdown: a block without a language as before', fg_of(m, 'plain block') == st)

def t_512_c_interop():
    need('clangd')
    # importc wrappers: checked against the header, F12 and hover to C, fixes, completion, c2nim, clangd
    def prep(cfg=None):
        setup(dict({"editor.languageServerHints": False}, **(cfg or {})))
        for x in ('demo.nimble', 'src', 'tests', 'examples'):
            pth = os.path.join(W, x)
            if os.path.isdir(pth): shutil.rmtree(pth)
            elif os.path.exists(pth): os.remove(pth)
        for x in os.listdir(FIX + '/cwrap'): shutil.copy(FIX + '/cwrap/' + x, W + '/' + x)
    prep()
    start('wrap.nim', w=150, h=40, path=TOOLS + ':$PATH')
    check('512 wrappers checked on open: 6 warnings', wait_for(r'▲ 6', 8), screen()[-300:])
    palette('Show problems'); time.sleep(1.5)
    sc = screen()
    for want in ('a: C has int', 'use cint', 'use cfloat', 'use cstring', 'use csize_t', 'takes 3 parameters, this 2',
                 'add {.varargs.}', 'mathx.h:7: int mx_add(int a, int b)'):
        check('512 problem: ' + want, want in sc, sc[-1500:])
    check('512 no warning for the ones that fit (mx_name, mx_errno, puts)',
          not re.search(r'\[(8|10|11):', sc), sc[-1500:])
    keys('Escape'); keys('C-g'); time.sleep(0.4); text('4:8'); keys('Enter'); time.sleep(0.3); keys('F12'); time.sleep(1.5)
    check('512 F12 on an importc declaration opens the C prototype', 'mathx.h ×' in screen() and 'Ln 7,' in screen(),
          screen()[:600] + screen()[-200:])
    keys('M-,'); time.sleep(0.5)
    keys('C-g'); time.sleep(0.4); text('14:8'); keys('Enter'); time.sleep(0.3); keys('M-h'); time.sleep(2)
    check('512 hover on a use shows the C declaration', 'int mx_add(int a, int b)' in screen() and 'C — mathx.h:7' in screen(),
          screen())
    keys('Escape')
    keys('C-g'); time.sleep(0.4); text('4:18'); keys('Enter'); time.sleep(0.3); keys('M-Enter'); time.sleep(1)
    check('512 quick fix offered: Use cint', 'Use cint' in screen(), screen())
    keys('Enter'); time.sleep(1)
    check('512 the fix changes the type and the warning goes', 'mx_add*(a: cint; b: cint)' in screen() and '▲ 5' in screen(),
          screen())
    keys('C-g'); time.sleep(0.4); text('9:8'); keys('Enter'); time.sleep(0.3); keys('M-Enter'); time.sleep(1)
    keys('C-u'); text('varargs'); time.sleep(0.4); keys('Enter'); time.sleep(1)
    check('512 quick fix: add {.varargs.}', '{.varargs, importc' in screen() and '▲ 4' in screen(), screen())
    keys('C-End'); keys('Enter'); text('proc z() {.'); time.sleep(1.5)
    check('512 typing {. in a proc line: no internal error (the Nim index)', 'Internal error' not in screen(), screen()[-600:])
    keys('C-z'); keys('C-z'); keys('BSpace'); time.sleep(0.3)
    keys('C-End'); keys('Enter'); text('proc q(): cint {.importc: "mx_'); time.sleep(1.5)
    check('512 importc: "…" completes the C names in the header', re.search(r'mx_scale\s+mathx\.h', screen()), screen())
    keys('Escape'); keys('End'); keys('Enter'); text('proc r() {.importc, header: "<stdi'); time.sleep(1.5)
    check('512 header: "<…" completes system headers', '<stdio.h>' in screen() and '<stdint.h>' in screen(), screen())
    keys('Escape'); keys('C-z'); keys('C-z'); keys('C-z'); keys('C-z'); time.sleep(0.3)
    # compile_commands.json for clangd
    palette('Nim: write compile_commands.json'); time.sleep(0.5)
    check('512 compile_commands.json written', wait_for('Wrote compile_commands.json', 60), screen()[-400:])
    cc = json.load(open(W + '/compile_commands.json')) if os.path.exists(W + '/compile_commands.json') else []
    check('512 it has the project\'s own C file with its command',
          any(e['file'].endswith('/mathx.c') and ' -c ' in ' ' + e['command'] + ' ' for e in cc), str(cc)[:400])
    # wrap a header with c2nim
    palette('Nim: wrap a C header'); time.sleep(0.8)
    text('mathx.h'); time.sleep(0.4); keys('Enter')
    if which('c2nim'): check('512 c2nim wraps the header', wait_for('Wrapped mathx.h', 20), screen()[-400:])
    out = open(W + '/mathx.nim').read() if os.path.exists(W + '/mathx.nim') else ''
    if which('c2nim'): check('512 the wrapper has the procs, importc and header', 'proc mx_add*' in out and 'header: "mathx.h"' in out, out[:300])
    # without c2nim or futhark: an offer to install
    prep()
    start('wrap.nim', w=150, h=40, path=no_nim_dir() + ':/usr/bin:/bin')     # (nim, and no c2nim or futhark)
    palette('Nim: wrap a C header'); time.sleep(0.8); text('mathx.h'); time.sleep(0.4); keys('Enter'); time.sleep(3)
    if not any(os.path.exists(d + '/' + x) for d in ['/usr/bin', '/bin'] for x in ['c2nim', 'futhark']):
        check('512 no c2nim: an offer to install it', 'Install c2nim' in screen(), screen())
    keys('Escape')
    # the setting turns the check off
    prep({"nim.checkWrappers": False})
    start('wrap.nim', w=150, h=40); time.sleep(3)
    check('512 nim.checkWrappers: false — no warnings', '✓ 0' in screen() and '▲' not in screen(), screen()[-300:])

def t_525_hints():
    # types everywhere: an array of objects, loop variables, a multi-line if / case, a conversion in command
    # syntax, a set of a range, a local array over two lines — nimsuggest off
    setup({"nim.nimsuggest": False})
    open(W + '/demo.nim', 'w').write('type\n  Person = object\n    name: string\n    age: int\n'
        'let people = [Person(name: "Ann", age: 30), Person(name: "Bo", age: 7)]\n'
        'for p in people:\n  echo p.name, p.name.len\nfor i, p in people:\n  echo i, p.age\n'
        'proc f(bytes: int): string =\n  let lg2 = if bytes == 0:\n      0\n    else:\n      bytes * 2\n'
        '  var\n    mask = BiggestUInt 1\n  let k = case bytes\n    of 1: "one"\n    else: "many"\n'
        '  let d = {\'0\'..\'9\'}\n  const pre = [\'a\', \'f\',\n      \'p\']\n  let half = result.len div 2\n'
        '  echo lg2, mask, k, d, pre, half\n'
        '{.pragma: myp, gcsafe.}\nproc g() {.myp.} = discard\n')
    start('demo.nim', w=110, h=34); time.sleep(1)
    ok = wait_for('let people: array', 10)
    s = screen()
    check('525 type hints: an array of objects, loop variables (one and two), multi-line if and case, command syntax, sets',
          ok and 'let people: array[2, Person] = [Person' in s and 'for p: Person in people' in s and
          'for i: int, p: Person in people' in s and 'let lg2: int = if' in s and 'mask: BiggestUInt = BiggestUInt 1' in s and
          'let k: string = case' in s and 'let d: set[char]' in s and 'const pre: array[3, char]' in s and
          'let half: int = result.len div 2' in s, s)
    keys('C-g'); text('7:8'); keys('Enter'); keys('M-q')
    ok = wait_for(r'REFERENCES p · 3', 5)
    s = screen()
    rows = [l for l in s.splitlines() if re.match(r'\s+7\s+echo p\.name', l)]
    check('525 references: one row for a line with two uses', ok and len(rows) == 1 and
          re.search(r'^\s+6\s+for p in people', s, re.M), s)
    a = tm('capture-pane', '-t', 'f', '-e', '-p').stdout
    row = [l for l in a.splitlines() if 'echo' in re.sub(r'\x1b\[[0-9;]*m', '', l) and '.name.len' in re.sub(r'\x1b\[[0-9;]*m', '', l)]
    check('525 references: both uses on the line are marked', row and row[-1].count('\x1b[1m') >= 2, repr(row[-1:]))
    keys('Escape'); keys('F6'); keys('Escape'); time.sleep(0.2)
    keys('C-g'); text('27'); keys('Enter'); keys('End'); text('\nproc h() {.my')
    check('525 completion: a {.pragma: name.} of the file among the pragmas', wait_for(r'myp\s+pragma', 4), screen())
    keys('Escape')
    # a long line wrapped: its type hint stays (and the colour swatches go)
    open(W + '/w.nim', 'w').write('let longName = "' + 'x' * 70 + '" & "' + 'y' * 30 + '"\nlet n = 5\n')
    keys('C-o'); time.sleep(0.4); keys('C-u'); text(W + '/w.nim'); keys('Enter'); time.sleep(1)
    palette('Toggle soft wrap'); time.sleep(0.8)
    s = screen()
    check('525 type hints on a wrapped line', 'let longName: string = "xxx' in s and 'let n: int = 5' in s, s)

def t_525_csv():
    setup()
    open(W + '/data.csv', 'w').write('name,age,city\nAnn,30,Oslo\nBo,7,Rome\nCarmen,45,"New York"\nDu,12,Lima\n')
    start('data.csv', w=100, h=24); time.sleep(1)
    ok = wait_for(r'Carmen, 45,  "New York"', 5)
    check('525 CSV: the columns lined up (the file itself unchanged)', ok and 'Ann,    30,  Oslo' in screen() and
          ftext('data.csv').startswith('name,age,city\nAnn,30,Oslo'), screen())
    keys('C-g'); text('3:5'); keys('Enter')
    check('525 CSV: the column under the cursor by its heading', wait_for(r'age  \(column 2\)', 3), screen())
    palette('CSV: sort by this column'); time.sleep(0.8)
    s = screen()
    check('525 CSV: sort by a column, as numbers', re.search(r'2.\s*Bo,\s+7.*\n.*3.\s*Du,\s+12.*\n.*4.\s*Ann,\s+30', s) is not None, s)
    palette('CSV: summary of this column'); time.sleep(0.8)
    check('525 CSV: a column\'s summary', wait_for(r'sum 94 · smallest 7 · largest 45 · mean 23.5', 3), screen())
    keys('C-z'); time.sleep(0.4)
    keys('C-s'); time.sleep(0.4)
    check('525 CSV: Ctrl+Z puts the rows back', ftext('data.csv').startswith('name,age,city\nAnn,30,Oslo\nBo,7'), ftext('data.csv'))
    open(W + '/items.csv', 'w').write('item,note\nbox 10,a\nbox 9,b\n1200,c\nbox 2,d\n')
    keys('C-o'); time.sleep(0.4); keys('C-u'); text(W + '/items.csv'); keys('Enter'); time.sleep(0.8)
    keys('C-g'); text('2:2'); keys('Enter'); palette('CSV: sort by this column'); time.sleep(0.6); keys('C-s'); time.sleep(0.4)
    check('525 CSV: numbers first, then words with their numbers in order (box 2, box 9, box 10)',
          ftext('items.csv') == 'item,note\n1200,c\nbox 2,d\nbox 9,b\nbox 10,a\n', ftext('items.csv'))

def t_525_profile():
    setup({"nim.nimsuggest": False})
    open(W + '/hot.nim', 'w').write('proc slow(n: int): int =\n  for i in 0 ..< n:\n    result += i mod 7\n'
                                    'proc fast(n: int): int = n * 2\nvar t = 0\nfor k in 0 ..< 3000:\n  t += slow(20000)\n'
                                    '  t += fast(k)\necho t\n')
    start('hot.nim', w=110, h=30); time.sleep(1)
    palette('Nim: profile')
    ok = wait_for(r'of the time', 120)
    s = screen()
    check('525 profile: the time beside the procs and the lines that call them',
          ok and re.search(r'proc slow.*◷ (9\d|100)\.\d% of the time', s) and re.search(r't \+= slow\(20000\)\s+\S+ (9\d|100)\.\d%', s) and
          re.search(r'PROFILE · \d+ samples', s), s)
    palette('Nim: hide the profile'); time.sleep(0.5)
    check('525 profile: hidden again', 'of the time' not in screen(), screen())

def t_525_engine():
    # what templates declare, routines inside routines, headers over two lines, async results, x.Type
    setup({"nim.nimsuggest": False})
    open(W + '/gen.nim', 'w').write(
        'import std/asyncdispatch\n'
        'template genCtor(lower, upper, typ: untyped) =\n'
        '  type `upper 2`* = object\n    x, y: typ\n'
        '  proc `lower 2`*(x, y: typ): `upper 2` = `upper 2`(x: x, y: y)\n'
        'genCtor(vec, Vec, float32)\n'
        'let v = vec2(1, 2)\n'
        'proc outer(n: int): int =\n'
        '  proc inner(k: int): string =\n    let q = k * 2\n    result = $q\n'
        '  let s = inner(n)\n  result = s.len\n'
        'proc fetch(): Future[string] {.async.} =\n  let r = result\n  result = "x"\n'
        'proc parse(a: int, b: string): int\n          {.raises: [].} =\n  let w = a + b.len\n  w\n'
        'let fd = 5.Natural\nlet big = 10\'i64 * 2\n')
    start('gen.nim', w=110, h=34); time.sleep(1)
    ok = wait_for('let v: Vec2', 10)
    s = screen()
    check('525 engine: declarations a template makes, routines in routines, two-line headers, async results, conversions',
          ok and 'let v: Vec2 = vec2(1, 2)' in s and 'let q: int = k * 2' in s and 'let s: string = inner(n)' in s and
          'let r: string = result' in s and 'let w: int = a + b.len' in s and 'let fd: Natural = 5.Natural' in s and
          'let big: int64' in s, s)
    keys('C-g'); text('7:10'); keys('Enter'); keys('M-.')
    time.sleep(1)
    check('525 engine: go to what a template declared → the line that calls it', status_pos() and status_pos()[0] == 6, screen()[-400:])

def t_525_macro_nested():
    # a macro that plays a saved macro, played as "the last one": the inner one replaces the last macro while the
    # outer one is still going (it used to read freed memory)
    setup()
    open(W + '/m.txt', 'w').write('\n')
    start('m.txt', w=100, h=24); time.sleep(0.8)
    keys('M-R'); time.sleep(0.2); text('a'); keys('M-R'); time.sleep(0.3)
    palette('Macro: save the last one'); time.sleep(0.4); text('inner'); keys('Enter'); time.sleep(0.4)
    keys('M-R'); time.sleep(0.2); text('b'); palette('Macro: inner'); time.sleep(0.3); text('c'); keys('M-R'); time.sleep(0.3)
    keys('Enter')
    for _ in range(3):
        keys('M-M'); time.sleep(0.4)
    keys('C-s'); time.sleep(0.4)
    t = ftext('m.txt')
    check('525 a macro that plays a saved macro, played again and again', re.search(r'Ln \d+, Col', screen()) is not None and t.count('bac') >= 4, repr(t))

def t_526_typing_errors():
    # errors while you type, without nimsuggest: the compiler checks the unsaved text (from stdin, in the file's
    # folder: same imports, same config), and a misspelled name is marked at once by the engine
    setup({"nim.nimsuggest": False})
    os.makedirs(W + '/src/sub', exist_ok=True)
    open(W + '/src/sub/helper.nim', 'w').write('proc helper*(): int = 1\n')
    open(W + '/src/config.nims', 'w').write('switch("define", "myflag")\n')
    open(W + '/src/main.nim', 'w').write('import sub/helper\nwhen not defined(myflag): {.error: "no config".}\n'
                                         'let a: string = $helper()\necho a\n')
    open(W + '/src/bad.nim', 'w').write('let n: int = "text"\necho n\n')
    start('src/main.nim', w=110, h=30); time.sleep(3)
    s = screen()
    check('526 a clean file opens clean (its config read: no "no config")', '● no config' not in s and '✓ 0' in s, s)
    keys('C-g'); text('3:18'); keys('Enter'); keys('Delete')
    ok = wait_for(r"undeclared identifier: 'elper'", 15)
    check('526 an error while typing, from the compiler, without nimsuggest', ok and 'did you mean helper' in screen(), screen())
    check('526 the file is not saved for it', ftext('src/main.nim').count('$helper()') == 1, ftext('src/main.nim'))
    keys('C-z')
    ok = wait_for_not(r"undeclared identifier", 15) if 'wait_for_not' in globals() else None
    if ok is None:
        t0 = time.time()
        while time.time() - t0 < 15 and 'undeclared identifier' in screen(): time.sleep(0.3)
        ok = 'undeclared identifier' not in screen()
    check('526 undone: the error goes', ok, screen())
    keys('C-o'); time.sleep(0.4); keys('C-u'); text(W + '/src/bad.nim'); keys('Enter')
    check('526 a file with an error shows it when it opens', wait_for(r"type mismatch|got 'string'", 15), screen())
    # the engine, at once: a misspelled local (here with the compiler's check left to nimsuggest, which is off)
    tm('kill-server'); time.sleep(0.3)
    setup({"nim.nimsuggest": False, "nim.liveDiagnosticsFrom": "nimsuggest"})
    open(W + '/t.nim', 'w').write('proc main() =\n  let total = 5\n  echo total\nmain()\n')
    start('t.nim', w=110, h=30); time.sleep(1.5)
    keys('C-g'); text('3:13'); keys('Enter'); keys('BSpace', 'BSpace'); text('l'); keys('Home')
    ok = wait_for(r"undeclared identifier: 'totl'.*did you mean total", 6)
    check('526 a misspelled name marked at once by the engine', ok, screen())
    keys('M-Enter'); time.sleep(0.6)
    ok = wait_for('Change to total', 4)
    check('526 … and Alt+Enter offers the name meant, first', ok and re.search(r'▍Change to total', screen()), screen())
    keys('Enter'); time.sleep(0.5); keys('C-s'); time.sleep(0.4)
    check('526 … which fixes it', 'echo total' in ftext('t.nim'), ftext('t.nim'))
    # a misspelled member: the members the engine knows, the closest first
    tm('kill-server'); time.sleep(0.3)
    setup({"nim.nimsuggest": False})
    open(W + '/u.nim', 'w').write('import std/strutils\necho "abc".topperAscii\n')
    start('u.nim', w=110, h=30)
    ok = wait_for(r"undeclared field: 'topperAscii'", 15)
    keys('C-g'); text('2'); keys('Enter'); keys('M-Enter')
    ok = ok and wait_for(r'Change to toUpperAscii', 5)
    check('526 an undeclared field: Alt+Enter offers the member meant', ok, screen())

def t_527_expand():
    # Alt+M without nimsuggest: a template written out by the engine, a macro expanded by the compiler (stdin)
    setup({"nim.nimsuggest": False})
    open(W + '/x.nim', 'w').write('import std/macros\nmacro twice(body: untyped): untyped =\n  result = newStmtList(body, body)\n'
        'template sq(x: untyped): untyped = x * x\ntemplate withLog(name: string, body: untyped) =\n  echo "start ", name\n'
        '  body\n  echo "end ", name\nproc f() =\n  echo sq(3 + 1)\n  withLog "job":\n    echo "working"\n    echo "done"\n'
        '  twice:\n    echo "hi"\nf()\n')
    start('x.nim', w=110, h=30); time.sleep(1.5)
    keys('C-g'); text('10:9'); keys('Enter'); keys('M-m')
    ok = wait_for(r'expand: sq', 5)
    check('527 a template written out at once: sq(3 + 1) → (3 + 1) * (3 + 1)', ok and '(3 + 1) * (3 + 1)' in screen(), screen())
    keys('C-w'); time.sleep(0.4)
    keys('C-g'); text('11:4'); keys('Enter'); keys('M-m')
    ok = wait_for(r'expand: withLog', 5)
    s = screen()
    check('527 … with its block: the body in its place', ok and 'echo "start ", "job"' in s and
          re.search(r'echo "working"\s*\n.*echo "done"\s*\n.*echo "end ", "job"', s) is not None, s)
    keys('C-w'); time.sleep(0.4)
    keys('C-g'); text('14:4'); keys('Enter'); keys('M-m')
    ok = wait_for(r'as the compiler expands it', 30)
    s = screen()
    check('527 a macro, as the compiler expands it (no nimsuggest)', ok and s.count('echo ["hi"]') == 2, s)

def t_527_complete():
    setup({"nim.nimsuggest": False})
    open(W + '/c.nim', 'w').write('import std/strformat\ntype Color = enum red, green, blue\n'
        'proc fetch(url: string, timeout = 5, retries = 3): string = url\n'
        'proc f(c: Color, name: string) =\n  case c\n  of red: echo 1\n  \n  echo fetch("x", \n  echo fmt"{name.}"\nf(red, "x")\n')
    start('c.nim', w=110, h=30); time.sleep(1.5)
    keys('C-g'); text('7'); keys('Enter'); keys('End'); text('of ')
    keys('C-space')
    ok = wait_for(r'green\s+Color', 4)
    s = screen()
    check('527 completion after `of` in a case on an enum: its values, the ones with a branch last', ok and
          s.find('green') < s.find('red ') if 'red ' in s else ok, s)
    keys('Escape'); keys('C-g'); text('8'); keys('Enter'); keys('End'); text('ti')
    ok = wait_for(r'timeout =', 4)
    check('527 completion inside a call: its parameters by name (timeout = )', ok, screen())
    keys('Escape'); keys('C-g'); text('9:18'); keys('Enter'); text('l')
    ok = wait_for(r'len\b', 4)
    check('527 completion inside fmt"{…}"', ok, screen())

def t_527_hover():
    setup({"nim.nimsuggest": False})
    open(W + '/h.nim', 'w').write('const KiB = 1024\nconst BufSize = 4 * KiB + 16\nconst Greeting = "hello" & ", " & "you"\n'
        'template sq(x: untyped): untyped = x * x\nlet a = "x"\nlet b = 2\necho BufSize, Greeting, sq(b), a & $b\n')
    start('h.nim', w=110, h=30); time.sleep(1.5)
    keys('C-g'); text('7:8'); keys('Enter'); keys('M-h')
    check('527 hover on a constant: its value worked out', wait_for(r'= 4112', 4), screen())
    keys('Escape'); keys('C-g'); text('7:17'); keys('Enter'); keys('M-h')
    check('527 … strings too', wait_for(r'= "hello, you"', 4), screen())
    keys('Escape'); keys('C-g'); text('7:27'); keys('Enter'); keys('M-h')
    check('527 hover on a template call: what it becomes here', wait_for(r'Here it becomes', 4) and 'b * b' in screen(), screen())
    keys('Escape'); keys('C-g'); text('7:32'); keys('Enter')
    for _ in range(6): keys('S-Right')
    keys('M-h')
    check('527 hover on a selection: its type', wait_for(r'a & \$b: string', 4), screen())

HIER_SRC = """type
  Shape = ref object of RootObj
    name: string
  Circle = ref object of Shape
    r: float
  Square = ref object of Shape
    side: float
  Color = enum red, green, blue
  Vec = object
    x, y: float

method area(s: Shape): float {.base.} = 0
method area(c: Circle): float = 3.14 * c.r * c.r
method area(s: Square): float = s.side * s.side

proc `+`(a, b: Vec): Vec = Vec(x: a.x + b.x, y: a.y + b.y)
proc size(v: Vec): float = v.x
proc size(s: string): int = s.len

proc paint(c: Color): string =
  case c
  of red: "r"
  of green: "g"
  of blue: "b"

let v = Vec(x: 1, y: 2) + Vec(x: 3, y: 4)
echo v.size, "abc".size
echo paint(red), red
let c = Circle(r: 2, name: "c")
echo c.r, c.name, area(c)
let x = 1 + 2
let s: Shape = c
echo s.area
"""

def t_528_hierarchy():
    setup({"nim.nimsuggest": None})
    open(W + '/h.nim', 'w').write(HIER_SRC)
    start('h.nim', w=130, h=40); time.sleep(1.5)
    ok = wait_for(r'area\(s: Square\): float = s\.side \* s\.side +1 reference', 6)
    check('528 an override counts the calls of the method it overrides (they dispatch to it)', ok, screen())
    keys('C-g'); text('4:4'); keys('Enter'); palette('Type hierarchy')
    ok = wait_for(r'Type hierarchy — Circle', 4)
    s = screen()
    check('528 type hierarchy without a language server: ↑ Shape above • Circle', ok and
          re.search(r'↑ +RootObj.*lib/system\.nim', s) is not None and s.find('↑   Shape') < s.find('•     Circle')
          if ok else False, s)
    keys('Escape'); keys('C-g'); text('29:9'); keys('Enter'); palette('Type hierarchy')
    check("528 … from a value: its type's", wait_for(r'Type hierarchy — Circle', 4), screen())
    keys('Escape'); keys('C-g'); text('2:4'); keys('Enter'); palette('Go to implementation')
    ok = wait_for(r'Implementations — Shape', 4)
    s = screen()
    check('528 go to implementation on a type: what inherits from it', ok and 'Circle' in s and 'Square' in s, s)
    keys('Escape'); keys('C-g'); text('12:9'); keys('Enter'); palette('Go to implementation')
    ok = wait_for(r'Implementations — area', 4)
    s = screen()
    check('528 … on a method: every override', ok and 'area(c: Circle)' in s and 'area(s: Square)' in s and
          'area(s: Shape)' in s, s)
    ps = sh('pgrep -af nimsuggest').stdout
    check('528 nimsuggest is off by default (none started)', W not in ps, ps)

def t_528_refs():
    setup({"nim.nimsuggest": None, "ui.panelHeight": 14})
    open(W + '/h.nim', 'w').write(HIER_SRC)
    start('h.nim', w=130, h=40); time.sleep(1.5)
    keys('C-g'); text('16:7'); keys('Enter'); keys('M-q')
    ok = wait_for(r'REFERENCES `\+` · 2', 5)
    s = screen(); s = s[s.find('REFERENCES'):]
    check('528 references of an operator: its uses whose types pick it (not 1 + 2)', ok and
          re.search(r'\n\s+26\s+let v = Vec', s) is not None and not re.search(r'\n\s+31\s+let x', s), s)
    keys('Escape'); keys('C-g'); text('31:11'); keys('Enter'); keys('M-q')
    check("528 … on the standard library's (1 + 2): says so, does not list every sum", wait_for(r"`\+` here is lib/system", 5), screen())
    keys('Escape'); keys('C-g'); text('26:25'); keys('Enter'); keys('M-h')
    check('528 hover on an operator: the overload its operands pick', wait_for(r'proc `\+`\(a, b: Vec\): Vec', 4), screen())
    keys('Escape'); keys('F12'); time.sleep(0.5)
    check('528 go to definition on an operator', status_pos() and status_pos()[0] == 16, screen()[-300:])
    keys('Escape'); keys('C-g'); text('10:5'); keys('Enter'); keys('M-q')
    ok = wait_for(r'REFERENCES x · 7', 5)
    s = screen(); s = s[s.find('REFERENCES'):]
    check('528 references of a field: its uses, in constructors too (not the variable x)', ok and not re.search(r'\n\s+31\s+let x', s), s)
    keys('Escape'); keys('C-g'); text('31:5'); keys('Enter'); keys('M-q')
    check('528 … and the variable x: not the field', wait_for(r'REFERENCES x · 1\b', 5), screen())
    keys('Escape'); keys('C-g'); text('8:17'); keys('Enter'); keys('M-q')
    check('528 references of an enum value', wait_for(r'REFERENCES red · 4', 5), screen())
    keys('Escape'); keys('C-g'); text('18:7'); keys('Enter'); keys('M-q')
    ok = wait_for(r'REFERENCES size · 2', 5)
    s = screen(); s = s[s.find('REFERENCES'):]
    check('528 references of one overload: the calls that pick it', ok and re.search(r'\n\s+27\s+echo v.size', s) is not None
          and re.search(r'\n\s+18\s+proc size', s) and not re.search(r'\n\s+17\s+proc size', s), s)
    keys('Escape'); keys('C-g'); text('10:5'); keys('Enter'); keys('F2'); time.sleep(0.3)
    keys('C-u'); text('px'); keys('Enter'); time.sleep(0.6); keys('Enter'); time.sleep(0.6); keys('C-s'); time.sleep(0.5)
    t = ftext('h.nim')
    check('528 rename a field: its uses, not the variable of the same name', 'px, y: float' in t and 'a.px + b.px' in t and
          'Vec(px: 1, y: 2)' in t and 'v.px' in t and 'let x = 1 + 2' in t, t)

def t_528_actions():
    setup({"nim.nimsuggest": None})
    open(W + '/a.nim', 'w').write('type\n  Kind = enum kA, kB\n  Base = object of RootObj\n    id: int\n'
        '  Item = object of Base\n    name: string\n    tags: seq[string]\n    kind: Kind\n    ratio: float\n    count = 7\n\n'
        'proc later(x: int,\n           y: string): string\n\nlet a = Item(name: "x")\n'
        'let b = Item(\n  name: "y",\n)\necho a, b, later(1, "")\n')
    start('a.nim', w=130, h=40); time.sleep(1.5)
    keys('C-g'); text('15:15'); keys('Enter'); keys('M-Enter')
    ok = wait_for(r'Fill in the missing fields', 5)
    check('528 an object constructor: fill in the missing fields (offered)', ok, screen())
    if ok:
        text('Fill in'); time.sleep(0.3); keys('Enter'); time.sleep(0.5); keys('C-s'); time.sleep(0.5)
        t = ftext('a.nim')
        check('528 … every field, a value of its type (inherited ones too, defaults as declared)',
              'let a = Item(name: "x", tags: @[], kind: kA, ratio: 0.0, count: 7, id: 0)' in t, t)
    keys('Escape'); keys('C-g'); text('17:3'); keys('Enter'); keys('M-Enter')
    ok = wait_for(r'Fill in the missing fields', 5)
    if ok:
        text('Fill in'); time.sleep(0.3); keys('Enter'); time.sleep(0.5); keys('C-s'); time.sleep(0.5)
    t = ftext('a.nim')
    check('528 … written one per line when the call is', ok and 'let b = Item(\n  name: "y",\n  tags: @[],\n  kind: kA,' in t, t)
    keys('Escape'); keys('C-g'); text('12:6'); keys('Enter'); keys('M-Enter')
    ok = wait_for(r'Write its body', 5)
    check('528 a forward declaration: write its body (offered)', ok, screen())
    if ok:
        text('Write its'); time.sleep(0.3); keys('Enter'); time.sleep(0.5); keys('C-s'); time.sleep(0.5)
        t = ftext('a.nim')
        check('528 … at the end of the file', t.rstrip().endswith('proc later(x: int,\n           y: string): string =\n  discard  # TODO'), t)

def t_529_clangd_fixes():
    need('clangd')
    # clangd's "(fix available)": ned says what Alt+Enter does, finds the fix from the line it is about, and
    # names a fix by what it does
    setup({})
    open(W + '/m.c', 'w').write('#include <stdio.h>\n#include <string.h>\n\nint main(void) {\n    int x = 5\n'
                                '    if (x == 6) prinf("%d\\n", x);\n    return 0;\n}\n')
    PATHC = TOOLS + ':/usr/bin:/bin'
    start('m.c', w=130, h=30, path=PATHC)
    ok = wait_for(r"Expected ';' at end of declaration  — Alt\+Enter: insert ';'", 25)
    s = screen()
    check("529 clangd's fix named after the problem (not \"(fix available)\")", ok and 'fix available' not in s, s)
    keys('C-g'); text('5'); keys('Enter'); keys('End'); keys('M-Enter')
    ok = wait_for(r"insert ';'", 6)
    check("529 Alt+Enter where the ; is missing (clang reports it on the next line)", ok, screen())
    if ok:
        keys('Enter'); time.sleep(0.5); keys('C-s'); time.sleep(0.5)
        check('529 … applied', '    int x = 5;\n' in ftext('m.c'), ftext('m.c'))
    time.sleep(3)
    keys('C-g'); text('6:22'); keys('Enter'); keys('M-Enter')
    ok = wait_for(r"Change prinf to printf\s+'prinf' → 'printf'", 8)
    check("529 a fix titled after a note (\"'printf' declared here\") is named by what it does, once", ok and
          screen().count('Change prinf to printf') == 1, screen())
    if ok:
        text('Change prinf'); time.sleep(0.3); keys('Enter'); time.sleep(0.5); keys('C-s'); time.sleep(0.5)
        check('529 … applied', 'printf("%d' in ftext('m.c'), ftext('m.c'))
    ok = wait_for(r"string\.h is not used directly  — Alt\+Enter: remove #include directive", 15)
    check('529 the unused include: its fix shown', ok, screen())
    if ok:
        x, y = find_on_screen('remove #include')
        click(x, y)
        ok = wait_for(r'Quick fixes', 5)
        check('529 a click on the fix opens it', ok, screen())
        if ok:
            keys('Enter'); time.sleep(0.5); keys('C-s'); time.sleep(0.5)
            check('529 … and Enter applies it', '<string.h>' not in ftext('m.c'), ftext('m.c'))

def t_529_examples():
    # a comment after `runnableExamples:` (the screenshot's FIXME) no longer hides it; what the examples print
    # is shown
    setup({"nim.nimsuggest": None})
    open(W + '/src/it.nim', 'w').write('iterator oddNumbers*[Idx, T](a: array[Idx, T]): T =\n'
        '  runnableExamples: # FIXME: it should run in terminal\n    echo "hello test"\n\n'
        '  for x in a:\n    if x mod 2 == 1:\n      yield x\n')
    start('src/it.nim', w=120, h=30); time.sleep(1)
    s = screen()
    check('529 runnableExamples with a comment after it: ▶ beside it', re.search(r'▶\s+2\s', s) is not None, s)
    keys('C-g'); text('3'); keys('Enter')
    palette('Nim: run the examples at the cursor')
    ok = wait_for(r'pass — their output', 60)
    s = screen()
    check('529 … run, and what they print shown', ok and re.search(r'│ hello test', s) is not None, s)

def t_60_includes():
    # a project laid out like ned's own: src/app.nim includes app/ui/menu.nim and app/core/data.nim — the engine
    # finds the includer three folders up, so names from the other parts resolve
    setup({"nim.nimsuggest": None})
    os.makedirs(W + '/src/app/core'); os.makedirs(W + '/src/app/ui')
    open(W + '/src/app.nim', 'w').write('import std/strutils\ninclude app/core/data\ninclude app/ui/menu\n')
    open(W + '/src/app/core/data.nim', 'w').write('type Item = object\n  title: string\n\nproc loud(s: string): string = s.toUpperAscii\n')
    open(W + '/src/app/ui/menu.nim', 'w').write('proc show(it: Item) =\n  echo loud(it.title)\n')
    start('src/app/ui/menu.nim', w=120, h=30); time.sleep(1.5)
    keys('C-g'); text('2:9'); keys('Enter'); keys('M-h')
    check('60 a part included from three folders up: its includer\'s other parts resolve (hover)',
          wait_for(r'proc loud\(s: string\): string', 5), screen())
    keys('Escape'); keys('F12'); time.sleep(0.6)
    check('60 … and go to definition opens the other part', 'data.nim' in screen() and status_pos() and status_pos()[0] == 4,
          screen()[-400:])

def t_60_protect():
    # files of an installed nimble package and of the standard library open read-only (go to definition lands
    # there; a stray key and a save would change them for every project) — palette › File: allow editing this file
    setup({"nim.nimsuggest": None})
    nd = TMP + '/protect-nimble'
    pk = nd + '/pkgs2/tiny-1.0.0-abc'
    os.makedirs(pk, exist_ok=True)
    open(pk + '/tiny.nim', 'w').write('proc tiny*(): int = 1\n')
    start(pk + '/tiny.nim', w=120, h=30, env_extra='NIMBLE_DIR=' + nd); time.sleep(0.6)
    keys('End'); text('x'); time.sleep(0.3)
    s = screen()
    check('60 a package\'s file opens read-only: a key does not change it, and says why',
          'int = 1x' not in s and 'Read-only' in s and 'allow editing' in s, s)
    palette('File: allow editing this file'); time.sleep(0.3)
    keys('End'); text(' + 1'); keys('C-s'); time.sleep(0.5)
    check('60 … File: allow editing this file, then it saves', open(pk + '/tiny.nim').read() == 'proc tiny*(): int = 1 + 1\n',
          open(pk + '/tiny.nim').read())
    tm('kill-server'); time.sleep(0.3)
    # the standard library, through go to definition (nothing is saved here, whatever happens)
    open(W + '/lib.nim', 'w').write('import std/strutils\necho "a".toUpperAscii\n')
    start('lib.nim', w=120, h=30); time.sleep(1.0)
    keys('C-g'); text('2:12'); keys('Enter'); keys('F12'); time.sleep(1.0)
    keys('Home'); text('x'); time.sleep(0.3)
    s = screen()
    check('60 the standard library opens read-only too (F12 into strutils)', 'strutils.nim' in s and 'Read-only' in s and
          'strutils.nim ●' not in s, s)

def t_61_semantic():
    # names coloured by what they are and where they stand: a field after a dot and a call, a template, a parameter,
    # a module before a dot
    setup({"nim.nimsuggest": None, "theme": "vscode-dark"})
    open(W + '/s.nim', 'w').write('import std/sequtils\ntype P = object\n  name: string\n  size: int\n'
        'proc size(p: P, extra: int): int = p.size + extra\n'
        'template twice(x: untyped): untyped = x * 2\n'
        'proc show(p: P, count: int) =\n  echo p.name, p.size(count), twice(count)\n'
        '  echo sequtils.toSeq(1..2), P(name: "x")\n')
    start('s.nim', w=110, h=20); time.sleep(2.5)
    row, row2 = ansi_row('echo p.'), ansi_row('sequtils.toSeq')
    field, call, param, tpl = fg_at(row, 'name'), fg_at(row, 'size'), fg_at(row, 'count'), fg_at(row, 'twice')
    check('61 after a dot: a field and a call in different colours (p.name · p.size(count))',
          field and call and field != call, str((field, call)) + row)
    check('61 a parameter in a colour of its own', param and param not in (field, call, None), str(param))
    check('61 a template call in the macro colour, not a proc\'s', tpl not in (None, call), str(tpl))
    check('61 a module name before a dot in the type colour (sequtils.toSeq · P)',
          fg_at(row2, 'sequtils') is not None and fg_at(row2, 'sequtils') == fg_at(row2, 'P('), row2)

def t_63_marks():
    # TODO / NOTE marks on the scrollbar move with their code at once — not only when typing pauses
    setup({"ui.minimap": "off", "nim.nimsuggest": None})
    lines = ['echo %d' % i for i in range(200)]
    lines[150] = '# TODO: the mark to follow'
    open(W + '/marks.nim', 'w').write('\n'.join(lines) + '\n')
    start('marks.nim', w=100, h=30); time.sleep(1.0)
    def mark_rows():
        rows = screen_ansi().split('\n')
        col = max((re.sub(r'\x1b\[[0-9;:]*m', '', r).rfind('▐') for r in rows), default=-1)
        found = [(y, fg_at_col(r, col)) for y, r in enumerate(rows) if col >= 0 and char_at_col(r, col) == '▐']
        cnt = {}
        for _, c in found: cnt[c] = cnt.get(c, 0) + 1
        thumb = max(cnt, key=cnt.get) if cnt else None
        return [y for y, c in found if c != thumb]
    before = mark_rows()
    keys('C-Home'); paste('\n' * 120)
    t0 = time.time()
    after = before
    while time.time() - t0 < 0.25:
        after = mark_rows()
        if after != before: break
        time.sleep(0.03)
    check('63 a TODO mark on the scrollbar moves down as soon as lines go in above it',
          len(before) == 1 and len(after) == 1 and after[0] > before[0], str((before, after)))
    time.sleep(0.6)
    check('63 … and stays there once the file is scanned again', mark_rows() == after, str((after, mark_rows())))

def no_clang_format_dir():
    """a PATH folder with everything in /usr/bin but clang-format (ned's own C formatter then)"""
    d = TMP + '/noclang'
    if not os.path.isdir(d):
        os.makedirs(d)
        for x in os.listdir('/usr/bin'):
            if not x.startswith('clang-format'):
                try: os.symlink('/usr/bin/' + x, d + '/' + x)
                except OSError: pass
    return d

FMT63 = ('import std/strutils\nimport std/os\n\ntype P = object\n  a: int\n  longer: string\n\n'
         'proc f(a: int, b: string): int = a\nlet xs = [100000, 200000, 300000, 400000]\n'
         '{.emit: """\nint add(int a,int b){\nreturn a+b;\n}\n""".}\n')

def t_63_format():
    # the formatter's settings: parameters one per line always, long literals one per line, 40 columns, imports
    # merged, fields lined up — and the C in an emit formatted too (clang-format, or ned's own without it)
    setup({"nim.nimsuggest": None, "nim.format.params": "always", "nim.format.collections": "onePerLine",
           "nim.format.lineLength": 40, "nim.format.imports": "merge", "nim.format.align": True})
    open(W + '/src/f63.nim', 'w').write(FMT63)
    start('src/f63.nim', w=120, h=34)
    keys('M-f'); seen = wait_for(r'Formatted', 5)
    keys('C-s'); time.sleep(0.6)
    t = ftext('src/f63.nim')
    check('63 format: says it formatted', seen, screen()[-300:])
    check('63 format: imports merged', t.startswith('import std/[os, strutils]\n'), repr(t[:80]))
    check('63 format: fields lined up', '  a:      int\n  longer: string\n' in t, repr(t))
    check('63 format: parameters one per line (always)', 'proc f(\n    a: int,\n    b: string,\n): int =\n  a\n' in t,
          repr(t))
    check('63 format: a long literal one element per line (onePerLine at 40 columns)',
          'let xs = [\n  100000,\n  200000,\n  300000,\n  400000,\n]\n' in t, repr(t))
    if which('clang-format'):
        check('63 format: the C in the emit went through clang-format',
              'int add(int a, int b)' in t and 'return a + b;' in t and 'a+b' not in t, repr(t))
    # without clang-format: ned's own C formatter, for the emit and for a .c file
    open(W + '/src/f63.nim', 'w').write(FMT63)
    open(W + '/src/c63.c', 'w').write('int main( void ){\nint x=1 ,y = 2;\nif(x==1)\ny=-x;\nreturn x+y;\n}\n')
    tm('kill-server'); time.sleep(0.3)
    start('src/f63.nim', w=120, h=34, path=NIMBIN + ':' + no_clang_format_dir())     # (no clangd either)
    keys('M-f'); wait_for(r'Formatted', 5); keys('C-s'); time.sleep(0.6)
    t = ftext('src/f63.nim')
    check('63 format: without clang-format the emit is formatted by ned (indentation, spaces)',
          '{.emit: """\nint add(int a, int b) {\n  return a + b;\n}\n""".}' in t, repr(t))
    keys('C-p'); text('c63.c'); time.sleep(0.5); keys('Enter'); time.sleep(0.6)
    keys('M-f'); seen = wait_for('C formatter', 4); keys('C-s'); time.sleep(0.6)
    c = ftext('src/c63.c')
    check('63 format: a C file without clang-format: ned\'s C formatter', seen and
          c == 'int main(void) {\n    int x = 1, y = 2;\n    if (x == 1)\n        y = -x;\n    return x + y;\n}\n',
          repr(c))     # (at the file's indentation: 4 for C unless it says otherwise)

def t_63_paste():
    # pasted code takes the indentation of where it goes; at column 0, or with editor.formatOnPaste off, as copied
    setup({"nim.nimsuggest": None})
    open(W + '/src/p63.nim', 'w').write('proc main() =\n  if true:\n    echo 1\n')
    start('src/p63.nim', w=100, h=30)
    keys('C-Home'); keys('Down'); keys('Down'); keys('End'); keys('Enter'); time.sleep(0.2)
    paste('for i in 0..2:\n  echo i\n'); time.sleep(0.5)
    keys('C-s'); time.sleep(0.5)
    t = ftext('src/p63.nim')
    check('63 paste: the pasted block takes the indentation where it goes',
          t.startswith('proc main() =\n  if true:\n    echo 1\n    for i in 0..2:\n      echo i\n'), repr(t))
    keys('C-End'); keys('Home'); time.sleep(0.1)
    paste('  x = 1\n    y = 2\n'); time.sleep(0.4)
    keys('C-s'); time.sleep(0.5)
    t = ftext('src/p63.nim')
    check('63 paste: at column 0 it stays as copied', '      echo i\n  x = 1\n    y = 2\n' in t, repr(t))
    setup({"nim.nimsuggest": None, "editor.formatOnPaste": "off"})
    open(W + '/src/p63.nim', 'w').write('proc main() =\n  if true:\n    echo 1\n')
    start('src/p63.nim', w=100, h=30)
    keys('C-Home'); keys('Down'); keys('Down'); keys('End'); keys('Enter'); time.sleep(0.2)
    paste('for i in 0..2:\n  echo i\n'); time.sleep(0.5)
    keys('C-s'); time.sleep(0.5)
    t = ftext('src/p63.nim')
    check('63 paste: editor.formatOnPaste off pastes exactly as copied',
          '    for i in 0..2:\n  echo i\n' in t, repr(t))

MYLIB_H = """/* mylib — tiny helpers for the tests
   Copyright (C) 2026 Nobody. Licensed under the MIT License. */
#ifndef MYLIB_H
#define MYLIB_H
#include <stddef.h>

/* Adds two numbers.
   Overflow wraps around. */
int my_add(int a, int b);

/// Copies at most n bytes of src.
char *my_copy(char *dst, const char *src, size_t n);

double my_scale(double x); /* scales x by the global factor */
void my_reset(void);
#endif
"""

def t_63_cdocs():
    # C knowledge in Nim: a wrapper's C documentation on hover, its C signature beside it, header: "…" coloured,
    # hovered and opened with F12, a wrapper rewritten from C, a new wrapper completed from the header
    setup({"nim.nimsuggest": None, "editor.languageServerHints": False})
    os.makedirs(W + '/c63', exist_ok=True)
    open(W + '/c63/mylib.h', 'w').write(MYLIB_H)
    open(W + '/c63/w.nim', 'w').write(
        'proc my_add(a, b: cint): cint {.importc, header: "mylib.h".}\n'
        'proc myCopy(dst: cstring, src: cstring, n: int): cstring {.importc: "my_copy", header: "mylib.h".}\n'
        'proc my_scale(x: cdouble): cdouble {.importc, header: "mylib.h".}\n'
        '\n'
        'echo my_add(1, 2)\n'
        'echo "plain"\n')
    start('c63/w.nim', w=160, h=40)
    check('63 cdocs: the C signature beside the wrapper (dimmed)', wait_for(r'⟵ int my_add\(int a, int b\)', 6), screen())
    keys('C-g'); time.sleep(0.4); text('5:7'); keys('Enter'); time.sleep(0.3); keys('M-h'); time.sleep(1.5)
    sc = screen()
    check('63 cdocs: hover on a use shows the C declaration and its comment',
          'int my_add(int a, int b)' in sc and 'Adds two numbers.' in sc and 'Overflow wraps around.' in sc, sc)
    keys('Escape')
    keys('C-g'); time.sleep(0.4); text('3:7'); keys('Enter'); time.sleep(0.3); keys('M-h'); time.sleep(1.5)
    sc = screen()
    check('63 cdocs: a comment after the declaration counts too', 'scales x by the global factor' in sc, sc)
    keys('Escape')
    row1 = ansi_row('header: "mylib.h"')
    row6 = ansi_row('echo "plain"')
    check('63 cdocs: header: "…" has a colour of its own (not the strings\' or the pragma\'s)',
          fg_at(row1, 'mylib.h') is not None and fg_at(row1, 'mylib.h') != fg_at(row6, 'plain') and
          fg_at(row1, 'mylib.h') != fg_at(row1, 'header'), str((fg_at(row1, 'mylib.h'), fg_at(row6, 'plain'))))
    keys('C-g'); time.sleep(0.4); text('1:54'); keys('Enter'); time.sleep(0.3); keys('M-h'); time.sleep(1.5)
    sc = screen()
    check('63 cdocs: hover on header: "…" — the file, what it says it is, what it declares',
          'mylib — tiny helpers for the tests' in sc and 'functions' in sc and 'Copyright' not in sc, sc[-1500:])
    keys('Escape'); keys('F12'); time.sleep(1.2)
    check('63 cdocs: F12 on header: "…" opens it', 'mylib.h ×' in screen() or 'mylib.h' in screen().split('\n')[1],
          screen()[:400])
    keys('M-,'); time.sleep(0.5)
    keys('C-g'); time.sleep(0.4); text('2:8'); keys('Enter'); time.sleep(0.3); keys('M-Enter'); time.sleep(1)
    check('63 cdocs: quick fix offered: rewrite the wrapper from C', 'Rewrite this wrapper' in screen(), screen())
    keys('C-u'); text('Rewrite'); time.sleep(0.4); keys('Enter'); time.sleep(1)
    keys('C-s'); time.sleep(0.5)
    t = ftext('c63/w.nim')
    check('63 cdocs: the wrapper written from its C declaration (size_t → csize_t), its pragmas kept',
          'proc myCopy(dst: cstring, src: cstring, n: csize_t): cstring {.importc: "my_copy", header: "mylib.h".}' in t,
          repr(t))
    keys('C-End'); keys('Enter'); text('proc my_r'); time.sleep(0.4); keys('C-space'); time.sleep(1.2)
    check('63 cdocs: proc ⟨C name⟩ offers the header\'s functions not wrapped yet',
          'my_reset' in screen() and 'my_add ' not in screen().split('\n')[-12:][0], screen())
    keys('Enter'); time.sleep(0.4); keys('C-s'); time.sleep(0.5)
    t = ftext('c63/w.nim')
    check('63 cdocs: … accepting writes the whole wrapper', 'proc my_reset() {.importc, header: "mylib.h".}' in t, repr(t))

def t_64_engine():
    # 6.4: parameter names before literal arguments, a generic routine's instance on hover, `;` statements,
    # Box[string](…) and Box(val: "x") typed, organize imports, an import from the project's own modules
    setup({"nim.nimsuggest": None})
    open(W + '/src/p64.nim', 'w').write(
        'proc draw(width, height: int, filled: bool) = discard\n'
        'proc biggest[T](a, b: T): T = (if a > b: a else: b)\n'
        'type Box[T] = object\n  val: T\n\n'
        'draw(10, 20, true)\n'
        'let z = biggest(3, 4)\n'
        'let one = 1; let word = "x"\n'
        'let bx = Box(val: "x")\n'
        'echo max(1, 2), z, one, word, bx.val\n')
    # (the files quick open finds: made before ned starts)
    open(W + '/src/o64.nim', 'w').write('import std/tables\nimport std/strutils, std/os\n\necho "a".toUpperAscii\n')
    open(W + '/src/extra64.nim', 'w').write('proc helperSixtyFour*(): int = 64\n')
    open(W + '/src/u64.nim', 'w').write('echo helperSixtyFour()\n')
    start('src/p64.nim', w=130, h=30)
    ok = wait_for(r'draw\(width: 10, height: 20, filled: true\)', 8)
    check('64 parameter names before literal arguments', ok, screen())
    check('64 … not for one-letter names (max(1, 2))', 'max(1, 2)' in screen() and 'max(x:' not in screen(), screen())
    check('64 a `;` statement has its type hint too', re.search(r'word: string = "x"', screen()), screen())
    check('64 a generic object built without its arguments: Box[string]', re.search(r'bx: Box\[string\] = Box', screen()),
          screen())
    keys('C-g'); time.sleep(0.4); text('7:11'); keys('Enter'); time.sleep(0.3); keys('M-h'); time.sleep(1.2)
    check('64 hover on a generic call: what it is here', 'Here:' in screen() and 'T = int' in screen(), screen())
    keys('Escape')
    # organize imports: the unused ones go (the compiler says which, on save), the rest sorted
    keys('C-p'); time.sleep(0.4); text('o64.nim'); time.sleep(0.5); keys('Enter'); time.sleep(0.8)
    keys('C-s'); ok = wait_for(r'imported and not used', 20)
    palette('Nim: organize imports'); time.sleep(1)
    keys('C-s'); time.sleep(0.6)
    t = ftext('src/o64.nim')
    check('64 organize imports: the unused ones removed, the rest sorted', ok and t.startswith('import std/strutils\n\necho'),
          repr(t) + screen()[-300:])
    # a name one of the project's own modules exports: Alt+Enter imports it
    keys('C-p'); time.sleep(0.4); text('u64.nim'); time.sleep(0.5); keys('Enter'); time.sleep(0.8)
    keys('C-s'); wait_for('undeclared identifier', 20)
    keys('C-Home'); keys('End'); keys('Left'); keys('Left'); keys('Left'); keys('M-Enter'); time.sleep(1.2)
    check('64 quick fix: import the project\'s module that exports it', 'Import ./extra64' in screen(), screen())
    keys('C-u'); text('extra64'); time.sleep(0.3); keys('Enter'); time.sleep(0.6); keys('C-s'); time.sleep(0.5)
    t = ftext('src/u64.nim')
    check('64 … the import is added', t.startswith('import ./extra64\n'), repr(t))

PT_H = """#ifndef PT_H
#define PT_H

/** A point in the plane. */
typedef struct {
    int x;       /**< across */
    int y;       /**< down */
} Point;

struct node {
    struct node *next;
    Point at;
};

/** Moves a point by dx, dy. */
Point pt_move(Point p, int dx, int dy);

#endif
"""

def t_65_cengine():
    # 6.5: ned's own C engine (c.engine: builtin) — no clangd started; members after ->, hover with the header's
    # comment, F12 through #include and to the body in another .c file, goto labels, rename, signature help, the
    # C compiler's errors on the unsaved text, a missing #include added
    setup({"c.engine": "builtin"})
    os.makedirs(W + '/c65', exist_ok=True)
    open(W + '/c65/pt.h', 'w').write(PT_H)
    open(W + '/c65/geometry_util.h', 'w').write('int gu_area(int w, int h);\n')
    open(W + '/c65/pt.c', 'w').write('#include "pt.h"\n\nPoint pt_move(Point p, int dx, int dy)\n{\n'
                                     '    p.x += dx;\n    p.y += dy;\n    return p;\n}\n')
    open(W + '/c65/main.c', 'w').write(
        '#include "pt.h"\n\nint walk(struct node *head)\n{\n    int steps = 0;\n    while (head) {\n'
        '        steps++;\n        head = head->next;\n    }\n    if (steps > 100)\n        goto done;\n'
        '    return steps;\ndone:\n    return -1;\n}\n\nint main(void)\n{\n    struct node n = {0};\n'
        '    Point q = pt_move(n.at, 1, 2);\n    return walk(&n) + q.x;\n}\n')
    start('c65/main.c', w=130, h=34); time.sleep(1)
    keys('C-g'); text('20:17'); keys('Enter'); keys('M-h'); time.sleep(1)
    sc = screen()
    check("65 C engine: hover — the header's declaration and its comment",
          'Point pt_move(Point p, int dx, int dy)' in sc and 'Moves a point by dx, dy.' in sc, sc)
    keys('Escape')
    keys('C-g'); text('21:25'); keys('Enter'); keys('M-h'); time.sleep(1)
    sc = screen()
    check('65 C engine: hover on a member of a typedef\'d anonymous struct — its comment', 'int x' in sc and 'across' in sc, sc)
    keys('Escape')
    keys('C-g'); text('20:17'); keys('Enter'); keys('F12'); time.sleep(1.2)
    check('65 C engine: F12 on a function declared in a header — its body in the other .c file',
          wait_for(r'pt\.c', 3) and status_pos() and status_pos()[0] == 3, screen()[:600])
    keys('M-,'); time.sleep(0.5)
    keys('C-g'); text('3:18'); keys('Enter'); keys('F12'); time.sleep(1.2)
    check('65 C engine: F12 on struct node — through the #include', wait_for(r'pt\.h', 3) and status_pos() and
          status_pos()[0] == 10, screen()[:600])
    keys('M-,'); time.sleep(0.5)
    keys('C-g'); text('11:15'); keys('Enter'); keys('F12'); time.sleep(0.8)
    check('65 C engine: F12 on a goto — its label', status_pos() and status_pos()[0] == 13, screen()[-300:])
    keys('C-g'); text('5:10'); keys('Enter'); keys('F2'); time.sleep(0.3)
    keys('C-u'); text('count'); keys('Enter'); time.sleep(0.6)
    check('65 C engine: rename a local — a preview first', 'Rename steps → count' in screen(), screen()[:800])
    keys('Enter'); time.sleep(0.6); keys('C-s'); time.sleep(0.5)
    t = ftext('c65/main.c')
    check('65 C engine: … renamed in its function only', t.count('count') == 4 and 'steps' not in t, t)
    keys('C-g'); text('8'); keys('Enter'); keys('End'); keys('Enter'); text('head->')
    check('65 C engine: members after -> (a struct from the header)', wait_for(r'next\s+struct node \*', 4) and
          re.search(r'at\s+Point', screen()), screen())
    keys('Escape'); text('at.')
    check('65 C engine: … and after . through the typedef', wait_for(r'x\s+int', 4) and re.search(r'y\s+int', screen()),
          screen())
    keys('Escape'); keys('C-k'); time.sleep(0.3)
    keys('C-g'); text('19'); keys('Enter'); keys('End'); keys('Enter'); text('pt_move(')
    check('65 C engine: signature help on (', wait_for(r'Point pt_move\(Point p, int dx, int dy\)', 4), screen())
    keys('Escape'); text('n.at, 1, 2); '); keys('Enter'); text('int z = ; ')   # (a ; last is tmux's separator)
    ok = wait_for(r'expected expression', 15)
    check("65 C engine: the C compiler's error while typing (the unsaved text)", ok, screen())
    check('65 C engine: … the file is not saved for it', 'int z' not in ftext('c65/main.c'), ftext('c65/main.c'))
    for _ in range(10): keys('BSpace')
    text('printf("hi\\n"); ')
    ok = wait_for(r"implicit declaration of function .printf", 15)
    check('65 C engine: a function used without its #include', ok, screen())
    if ok:
        keys('M-Enter'); time.sleep(0.6)
        ok = wait_for(r'#include <stdio\.h>', 4)
        check('65 C engine: … Alt+Enter offers the #include', ok, screen())
        if ok:
            keys('Enter'); time.sleep(0.5); keys('C-s'); time.sleep(0.5)
            check('65 C engine: … added', '#include <stdio.h>' in ftext('c65/main.c'), ftext('c65/main.c'))
    keys('C-End'); text('struct node gn = { .')
    check('65 C engine: members in a designated initializer ({ .)', wait_for(r'next\s+struct node \*', 4), screen())
    keys('Escape'); keys('C-k')
    keys('C-Home'); keys('End'); keys('Enter'); text('#include "')
    check('65 C engine: #include "… offers the headers beside the file', wait_for(r'geometry_util\.h', 4), screen())
    keys('Escape'); keys('C-k')
    keys('C-t'); text('wal'); time.sleep(0.5)
    check('65 C engine: symbols in the file', 'walk' in screen(), screen())
    keys('Escape')
    mine = [pid for pid in sh('pgrep -x clangd').stdout.split() if
            os.path.realpath('/proc/%s/cwd' % pid).startswith(os.path.realpath(W))]
    check('65 C engine: no clangd started (c.engine: builtin)', not mine, str(mine))

def t_65_ligatures():
    # editor.fontLigatures: symbols — ned draws ≠ ≤ ═⇒ ─→ itself, in the same columns; not in strings or comments, not on
    # the cursor's line; font — nothing replaced (the terminal's font joins them)
    setup({"editor.fontLigatures": "symbols"})
    open(W + '/lig.nim', 'w').write('import std/sugar\nproc f(a, b: int): bool =\n  result = a != b and a <= b\n'
                                    'let g = (x: int) => x\necho "a != b"  # a >= b\n')
    open(W + '/lig.c', 'w').write('struct n { struct n *next; };\nint f(struct n *p) {\n    return p->next != 0;\n}\n')
    start('lig.nim', w=100, h=24); time.sleep(1)
    sc = screen()
    check('65 ligatures: ≠ and ≤ drawn, same columns', re.search(r'result = a ≠  b and a ≤  b', sc) is not None, sc)
    check('65 ligatures: => as a long double arrow', '(x: int) ═⇒ x' in sc, sc)
    check('65 ligatures: not inside strings or comments', 'echo "a != b"  # a >= b' in sc, sc)
    keys('C-g'); text('3'); keys('Enter'); time.sleep(0.4)
    sc = screen()
    check("65 ligatures: the cursor's line shows the text itself", 'result = a != b and a <= b' in sc and
          '(x: int) ═⇒ x' in sc, sc)
    keys('C-o'); time.sleep(0.4); keys('C-u'); text(W + '/lig.c'); keys('Enter'); time.sleep(1)
    sc = screen()
    check('65 ligatures: -> as a long arrow in C', 'return p─→next ≠  0;' in sc, sc)
    tm('kill-server'); time.sleep(0.3)
    setup({"editor.fontLigatures": "font"})
    open(W + '/lig.nim', 'w').write('proc f(a, b: int): bool =\n  result = a != b\n')
    start('lig.nim', w=100, h=24); time.sleep(1)
    check('65 ligatures: font — the text as it is (the terminal joins it)', 'result = a != b' in screen(), screen())
    palette('View: ligatures (off › font › symbols)'); time.sleep(0.5)
    check('65 ligatures: View › Ligatures goes on to symbols (and saves it)', 'result = a ≠  b' in screen() and
          '"symbols"' in open(CFG + '/ned/config.json').read(), screen())

def t_66_cwrap():
    # a wrapper of a system header laid out the way the formatter does (one parameter a line, `):` under proc): the C
    # signature beside it, printf's documentation on hover — on the wrapper's name, a call and "printf" —, varargs[T]
    # flagged, and the wrapper rewritten from C
    setup({"nim.nimsuggest": None})
    open(W + '/cw66.nim', 'w').write('proc cprintf(\n  str: varargs[cstring],\n): cint {.importc: "printf", varargs, '
                                     'header: "stdio.h", discardable, nodecl.}\n\ncprintf("%d\\n", 3)\n')
    start('cw66.nim', w=170, h=32)
    check("66 the C signature beside a wrapper written one parameter a line",
          wait_for(r'⟵ int printf\(const char \*', 8), screen())
    keys('C-g'); text('1:7'); keys('Enter'); keys('M-h'); time.sleep(1.2)
    sc = screen()
    check("66 hover on the wrapper's name: printf's declaration and documentation", 'printf(const char' in sc and
          re.search(r'(?i)formatted output', sc) is not None, sc)
    keys('Escape')
    keys('C-g'); text('5:3'); keys('Enter'); keys('M-h'); time.sleep(1.2)
    sc = screen()
    check('66 … and on a call', 'printf(const char' in sc, sc)
    keys('Escape')
    keys('C-g'); text('3:23'); keys('Enter'); keys('M-h'); time.sleep(1.2)
    sc = screen()
    check('66 … and on "printf"', 'printf(const char' in sc and 'stdio.h' in sc, sc)
    keys('Escape')
    keys('C-s'); ok = wait_for(r'varargs\[cstring\] is a Nim array', 10)
    check('66 varargs[cstring] for C\'s … flagged', ok, screen())
    keys('C-g'); text('2:3'); keys('Enter'); keys('M-Enter'); time.sleep(0.8)
    ok = wait_for('Rewrite this wrapper from its C declaration', 5)
    check('66 Alt+Enter offers the wrapper written from C', ok, screen())
    if ok:
        keys('C-u'); text('Rewrite'); time.sleep(0.4); keys('Enter'); time.sleep(1); keys('C-s'); time.sleep(0.6)
        t = ftext('cw66.nim')
        check('66 … the signature corrected (format: cstring, its pragmas kept)',
              'cprintf(format: cstring): cint {.importc: "printf", varargs, header: "stdio.h", discardable, nodecl.}'
              in t.replace('\n', ' ').replace('  ', ' ').replace('( ', '(').replace(', )', ')') or
              ('format: cstring' in t and 'varargs[' not in t), repr(t))

def t_66_zen_menu():
    # zen mode: no git change marks in the gutter unless zen.gitChanges; the File menu, short
    setup()
    open(W + '/src/demo/utils.nim', 'a').write('proc added*(): int = 1\n')
    start('src/demo/utils.nim', w=150, h=34); time.sleep(1.5)
    rows = [l for l in screen().split('\n') if 'proc added' in l]
    check('66 a change mark beside a changed line (outside zen)', rows and '▎' in rows[0], screen())
    keys('M-z'); time.sleep(0.8)
    rows = [l for l in screen().split('\n') if 'proc added' in l]
    check('66 zen: no change marks', rows and '▎' not in rows[0], screen())
    keys('M-z'); time.sleep(0.5)
    keys('F10'); time.sleep(0.6)
    sc = screen()
    items = [l for l in sc.split('\n')[1:30] if '│' in l]
    check('66 the File menu is short (submenus for the rest)', 'Open recent' in sc and 'Preferences' in sc and
          'Settings sync' not in sc and len(items) <= 22, sc)
    keys('Escape')

def t_66_align_hints():
    # declarations lined up on `=` (nim.format.align) stay lined up with type hints shown — with a hint on every line,
    # on some, or on none — and with the hints turned off, as written
    setup({"nim.nimsuggest": None, "nim.format.align": True})
    open(W + '/al66.nim', 'w').write('var\n  s   = 443\n  mff = 5454\n  mmm = 5555493\n\nconst\n'
                                     '  data    = "mov;btc"\n  opcodes = mystery(data)\n\necho s, mff, mmm\n')
    start('al66.nim', w=110, h=26)
    wait_for(r'data: string', 8); time.sleep(0.5)
    rows = screen().split('\n')
    def eq_col(word):
        r = [l for l in rows if re.search(r'\b' + word + r'\b', l) and '=' in l]
        return r[0].index('=') if r else -1
    cols = [eq_col(w) for w in ['s', 'mff', 'mmm']]
    check('66 align + hints: a run with a hint on every line stays lined up', cols[0] > 0 and len(set(cols)) == 1,
          str(cols) + '\n' + '\n'.join(rows[:12]))
    c2 = [eq_col('data'), eq_col('opcodes')]
    check('66 align + hints: … and one with a hint on some lines (the hint over the spaces, no gap)',
          c2[0] > 0 and c2[0] == c2[1] and re.search(r'data: string = "mov', screen()) is not None,
          str(c2) + '\n' + '\n'.join(rows[:12]))
    keys('C-g'); text('8:5'); keys('Enter'); keys('End'); time.sleep(0.3)
    p = status_pos()
    check('66 align + hints: the cursor still on its column', p == (8, 26), str(p))
    palette('Toggle inlay hints'); time.sleep(0.6)
    sc = screen()
    check('66 hints off: the lines as the formatter wrote them', 'data    = "mov;btc"' in sc and 'opcodes = mystery' in sc and
          ': string' not in sc, sc)

def t_66_postfix():
    # postfix completion: what is in front of the `.` is wrapped — xs.for, c.case (every value of its enum),
    # n.for (a counting loop), v.if (by its type), x.echo
    setup({"nim.nimsuggest": None})
    open(W + '/pf66.nim', 'w').write('type Color = enum red, green, blue\n'
        'proc f(items: seq[string], c: Color, n: int, name: string, opt: ref int) =\n'
        '  \n  \n  \n  \n  \n  discard\n'
        'f(@["a"], red, 3, "x", nil)\n')
    start('pf66.nim', w=110, h=30); time.sleep(1.5)
    keys('C-g'); text('3'); keys('Enter'); keys('End'); text('items.for')
    check('66 postfix: xs.for → for x in xs:', wait_for(r'for item in items:', 4), screen())
    keys('Tab'); time.sleep(0.3); keys('Escape')
    keys('C-g'); text('5'); keys('Enter'); keys('End'); text('c.case')
    check('66 postfix: c.case — every value of its enum', wait_for(r'case c — all 3', 4), screen())
    keys('Tab'); time.sleep(0.3); keys('Escape')
    keys('C-g'); text('12'); keys('Enter'); keys('End'); text('n.for')
    check('66 postfix: n.for on an int counts', wait_for(r'for i in 0 \.\.< n:', 4), screen())
    keys('Tab'); time.sleep(0.3); keys('Escape')
    keys('C-g'); text('14'); keys('Enter'); keys('End'); text('opt.if')
    check('66 postfix: v.if by its type (a ref: != nil)', wait_for(r'if opt != nil:', 4), screen())
    keys('Tab'); time.sleep(0.3); keys('Escape')
    keys('C-g'); text('16'); keys('Enter'); keys('End'); text('name.echo')
    wait_for(r'echo name', 4)
    keys('Tab'); time.sleep(0.3); keys('Escape')
    keys('C-s'); time.sleep(0.6)
    got = open(W + '/pf66.nim').read()
    want = ['  for item in items:', '  case c\n  of red:\n    discard\n  of green:\n    discard\n  of blue:\n    discard',
            '  for i in 0 ..< n:', '  if opt != nil:', '  echo name\n  discard']
    check('66 postfix: each written in place of its receiver, indented like it', all(w in got for w in want), got)
    keys('C-g'); text('17'); keys('Enter'); keys('End'); keys('Enter'); text('name.le')
    time.sleep(0.8)
    sc = screen()
    check('66 postfix: in the list after a dot, after the procs (len before let)', wait_for(r'postfix', 4) and
          sc.find(' len ') < sc.find(' let '), sc)

def t_66_copies():
    # where ARC/ORC copies: after a save, ⧉copy beside each value the compiler copies (not refs, not moves), and
    # hovering it says why
    setup({"nim.nimsuggest": None, "nim.showCopies": None})
    open(W + '/cp66.nim', 'w').write('type Obj = object\n  name: string\n\n'
        'proc keep(s: sink seq[string]) = discard s.len\n\n'
        'proc f(o: Obj, r: ref Obj): int =\n'
        '  var o2 = o\n'
        '  o2.name = "x"\n'
        '  var names: seq[string]\n'
        '  keep(names)\n'
        '  echo names.len, o2.name\n'
        '  let q = r\n'
        '  var w = @["a"]\n'
        '  var w2 = w\n'
        '  result = w2.len + q.name.len\n')
    start('cp66.nim', w=110, h=30); time.sleep(1.5)
    keys('C-s')
    ok = wait_for(r'var o2(: Obj)? = o ⧉copy', 15)
    sc = screen()
    check('66 copies: after a save, ⧉copy where ARC/ORC copies (a borrowed parameter kept)', ok, sc)
    check('66 copies: … a value given to a sink parameter and used again', re.search(r'keep\(names ⧉copy\)', sc) is not None, sc)
    check('66 copies: none for a ref, nor for a last use (moved)', 'r ⧉copy' not in sc and 'w ⧉copy' not in sc, sc)
    keys('C-g'); text('7:12'); keys('Enter'); keys('M-h')
    check('66 copies: hover says why, and what to do', wait_for(r'only borrowed', 4) and 'sink' in screen(), screen())
    keys('Escape'); keys('End'); text(' # edited'); time.sleep(0.5)
    check('66 copies: an edited line drops its mark until the next save', re.search(r'= o ⧉copy', screen()) is None, screen())

def t_66_test_on_save():
    # tests on save: saving a module runs the test files that import it, in the background — ✓/✗ beside each
    # test, a failed check's message on its line; saving the fixed test file runs it again
    setup({"nim.nimsuggest": None, "nim.testOnSave": None})
    open(W + '/mathy.nim', 'w').write('proc add*(a, b: int): int = a + b\n')
    os.makedirs(W + '/tests', exist_ok=True)
    open(W + '/tests/tmathy.nim', 'w').write('import std/unittest\nimport ../mathy\n\nsuite "math":\n'
        '  test "adds":\n    check add(1, 1) == 2\n  test "adds wrong":\n    let x = 1\n    check add(x, 1) == 3\n')
    start('mathy.nim', w=120, h=30); time.sleep(1.2)
    keys('C-s')
    ok = wait_for(r'1 test failed in tmathy.nim', 60)
    check('66 tests on save: saving a module runs its tests, a failure says so', ok, screen())
    keys('C-p'); time.sleep(0.3); text('tmathy'); time.sleep(0.5); keys('Enter'); time.sleep(1)
    sc = screen()
    check('66 tests on save: ✓ beside a test that passed', re.search(r'test "adds":.*✓ passed', sc) is not None, sc)
    check('66 tests on save: ✗ beside one that failed, with the line', re.search(r'test "adds wrong":.*✗ failed — line 9', sc) is not None, sc)
    check('66 tests on save: the failed check, on its line, with what each side was',
          re.search(r'check add\(x, 1\) == 3.*Check failed: add\(x, 1\) == 3 — add\(x, 1\) was 2', sc) is not None, sc)
    keys('C-g'); text('9'); keys('Enter'); keys('End'); keys('BSpace'); text('2'); keys('C-s')
    ok = wait_for(r'All 2 tests pass in tmathy.nim', 60)
    sc = screen()
    check('66 tests on save: the fixed test file run again: all pass, the error gone', ok and 'Check failed' not in sc and
          re.search(r'test "adds wrong":.*✓ passed', sc) is not None, sc)

def t_66_ctvalues():
    # compile-time values: hover a constant, a `when`, a selection — worked out as the compiler would; the `when`
    # branch that is false here dimmed like a comment, the true one not
    setup({"nim.nimsuggest": None})
    open(W + '/ct66.nim', 'w').write('const K = 1 shl 10\nconst Mask = 0xFF and not 0x0F\nconst Tag = "v" & $K\n'
        '# a comment\nwhen defined(windows):\n  proc winOnly(): int = 1\nelse:\n  proc posixOnly(): int = 2\n'
        'echo K, Mask, Tag, high(int16) + 1\nwhen defined(windows):\n  echo winOnly()\nelse:\n  echo posixOnly()\n')
    start('ct66.nim', w=110, h=26); time.sleep(1.2)
    keys('C-g'); text('9:6'); keys('Enter'); keys('M-h')
    check('66 compile-time: hover a constant, its value (1 shl 10)', wait_for(r'= 1024', 4), screen())
    keys('Escape'); keys('C-g'); text('9:15'); keys('Enter'); keys('M-h')
    check('66 compile-time: strings joined with $ of a constant', wait_for(r'= "v1024"', 4), screen())
    keys('Escape'); keys('C-g'); text('5:2'); keys('Enter'); keys('M-h')
    check('66 compile-time: hover a `when`, its condition here', wait_for(r'= false here', 4) and 'this branch is' in screen(), screen())
    keys('Escape'); time.sleep(0.3); keys('C-Home'); time.sleep(0.8)
    rw, rp, rc = ansi_row('proc winOnly'), ansi_row('proc posixOnly'), ansi_row('# a comment')
    check('66 compile-time: the branch left out here is dimmed like a comment; the other is not',
          fg_at(rw, 'winOnly') is not None and fg_at(rw, 'winOnly') == fg_at(rc, 'comment') and
          fg_at(rp, 'posixOnly') != fg_at(rc, 'comment'), str((fg_at(rw, 'winOnly'), fg_at(rp, 'posixOnly'), fg_at(rc, 'comment'))))
    keys('C-g'); text('9:20'); keys('Enter')
    for _ in range(15): keys('S-Right')
    keys('M-h')
    check('66 compile-time: a selection that overflows its type: the compile error it is',
          wait_for(r'a compile error: over- or underflow: int16', 4), screen())
    keys('Escape'); keys('C-g'); text('2:7'); keys('Enter'); keys('M-h')
    check('66 compile-time: bits of an int (0xFF and not 0x0F): an int, 240', wait_for(r'= 240', 4) and
          'Mask: bool' not in screen(), screen())
    # C: what #if 0 leaves out, dimmed too
    open(W + '/dim66.c', 'w').write('/* a comment */\n#if 0\nint dead_code(void) { return 1; }\n#endif\n'
                                    'int live_code(void) { return 2; }\n')
    tm('kill-server'); time.sleep(0.3); start('dim66.c', w=110, h=20); wait_for('live_code', 8); time.sleep(1)
    rd, rl, rc = ansi_row('dead_code'), ansi_row('live_code'), ansi_row('a comment')
    check('66 C: #if 0 dimmed like a comment, the code after #endif not',
          fg_at(rd, 'dead_code') == fg_at(rc, 'comment') and fg_at(rl, 'live_code') != fg_at(rc, 'comment'),
          str((fg_at(rd, 'dead_code'), fg_at(rl, 'live_code'), fg_at(rc, 'comment'))) + '\n' + screen())

def t_66_include_check():
    # a file another one includes is no module of its own: checked inside the module that includes it — no
    # "undeclared identifier" for what that module declares; a real error, typed or saved, on its own line
    setup({"nim.nimsuggest": None})
    os.makedirs(W + '/app/parts', exist_ok=True)
    open(W + '/app/main.nim', 'w').write('import std/tables\ntype Shop = object\n  stock: Table[string, int]\n'
                                         'include parts/sell\necho sell(Shop(), "tea")\n')
    open(W + '/app/parts/sell.nim', 'w').write('proc sell(s: Shop, item: string): int =\n'
                                               '  result = s.stock.getOrDefault(item)\n')
    start('app/parts/sell.nim', w=110, h=20); time.sleep(10)
    sc = screen()
    check('66 include: an included file opens without errors for what its module declares',
          'undeclared' not in sc and re.search(r'✓ 0', sc) is not None, sc)
    keys('C-g'); text('2'); keys('Enter'); keys('End'); text(' + missing')
    check('66 include: an error typed in it shows on its line', wait_for(r"undeclared identifier: 'missing'", 20), screen())
    keys('C-s'); time.sleep(6)
    check('66 include: … and stays after a save (the module checked on disk)', "undeclared identifier: 'missing'" in screen(),
          screen())
    for _ in range(10): keys('BSpace')
    keys('C-s')
    ok = wait_for(r'✓ 0', 20)
    check('66 include: fixed and saved, the error goes', ok and 'missing' not in screen(), screen())

def t_67_github_signin():
    # a push GitHub refuses for a login: the ways that work (the GitHub CLI, an SSH key) instead of a password
    # prompt that cannot succeed; with an SSH key and the GitHub CLI signed in, the key is added and the remote
    # switches to SSH
    setup({"nim.nimsuggest": None})
    git('remote remove origin'); git('remote add origin https://github.com/foxtest/demo.git')
    mock = TMP + '/mockbin'
    shutil.rmtree(mock, ignore_errors=True); os.makedirs(mock)
    open(mock + '/git', 'w').write('#!/bin/sh\ncase "$1" in push|pull|fetch) echo "fatal: could not read Username for '
                                   "'https://github.com': terminal prompts disabled\" >&2; exit 128;; esac\n"
                                   'exec ' + (which('git') or '/usr/bin/git') + ' "$@"\n')
    os.chmod(mock + '/git', 0o755)
    home = TMP + '/home67'
    shutil.rmtree(home, ignore_errors=True); os.makedirs(home + '/.ssh')
    open(home + '/.ssh/id_ed25519.pub', 'w').write('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest ned-test\n')
    # (no GitHub CLI: PATH without /usr/local/bin, where one may be installed)
    start('src/demo.nim', w=130, h=34, path=mock + ':' + TOOLS + ':/usr/bin:/bin', env_extra='GIT_CONFIG_COUNT=0 HOME=' + home)
    palette('Git: push')
    ok = wait_for(r'GitHub needs you to sign in', 10)
    sc = screen()
    check('67 GitHub: a push refused for a login offers the ways that work, not a password prompt',
          ok and 'Sign in with GitHub' in sc and 'Use an SSH key' in sc and 'access token' in sc, sc)
    check('67 GitHub: … the GitHub CLI installed for you when it is missing', 'installs the GitHub CLI' in sc,
          '\n'.join(l for l in sc.split('\n') if 'GitHub' in l or 'SSH' in l or 'token' in l))
    keys('Escape'); time.sleep(0.3); tm('kill-server'); time.sleep(0.3)
    # the GitHub CLI, signed in (a stand-in): the SSH key goes to the account, the remote to SSH
    open(mock + '/gh', 'w').write('#!/bin/sh\necho "$@" >> ' + TMP + '/gh.log\n'
                                  'case "$1 $2" in "auth status") exit 0;; "api user") echo foxtest; exit 0;;'
                                  ' "ssh-key add") exit 0;; "auth setup-git") exit 0;; esac\nexit 1\n')
    os.chmod(mock + '/gh', 0o755)
    start('src/demo.nim', w=130, h=34, path=mock + ':' + TOOLS + ':$PATH', env_extra='GIT_CONFIG_COUNT=0 HOME=' + home)
    palette('Git: push')
    wait_for(r'GitHub needs you to sign in', 10)
    text('SSH key'); time.sleep(0.4); keys('Enter')
    for _ in range(20):
        if 'git@github.com:foxtest/demo.git' in git('config --get remote.origin.url').stdout: break
        time.sleep(0.5)
    log = open(TMP + '/gh.log').read() if os.path.exists(TMP + '/gh.log') else ''
    log += '\n' + screen()
    check('67 GitHub: the SSH key added to the account by the GitHub CLI', 'ssh-key add' in log and 'id_ed25519.pub' in log, log)
    # (git config, not get-url: an insteadOf rule of the environment would rewrite it back)
    check('67 GitHub: … and the remote switched to SSH', git('config --get remote.origin.url').stdout.strip() ==
          'git@github.com:foxtest/demo.git', git('config --get remote.origin.url').stdout)
    tm('kill-server'); time.sleep(0.3)
    start('src/demo.nim', w=130, h=34, path=mock + ':' + TOOLS + ':$PATH', env_extra='GIT_CONFIG_COUNT=0 HOME=' + home)
    palette('Git panel')
    check('67 GitHub: the Git dock says who you push as', wait_for(r'GitHub: @foxtest', 10), screen())

def t_67_git_undo():
    # undo: the branch's last steps, each undone in one step — a commit (its changes staged), a pushed commit
    # (reverted with a new one), a pull (back to before it, uncommitted work kept)
    setup({"nim.nimsuggest": None})
    shutil.rmtree(TMP + '/remote67.git', ignore_errors=True)
    sh('git init -q --bare ' + TMP + '/remote67.git')
    git('remote remove origin'); git('remote add origin ' + TMP + '/remote67.git')
    git('config user.email a@b'); git('config user.name tester')
    git('commit -qam base --allow-empty'); git('push -q -u origin HEAD')
    open(W + '/one.txt', 'w').write('one\n'); git('add one.txt'); git('commit -qm "add one"')
    start('src/demo.nim', w=130, h=34)
    palette('Git: undo…')
    ok = wait_for(r'Undo the commit “add one”', 6)
    check('67 git undo: the last steps listed, newest first', ok and 'Go back to before' in screen(), screen())
    keys('Enter'); time.sleep(0.6); keys('u'); time.sleep(1.5)
    st = git('status --porcelain').stdout
    check('67 git undo: a commit undone — its changes staged, not lost', 'A  one.txt' in st and
          'add one' not in git('log --format=%s -3').stdout, st + git('log --format=%s -3').stdout)
    git('commit -qm "add one again"'); git('push -q')
    palette('Git: undo the last step'); time.sleep(1)
    check('67 git undo: a pushed commit — offered a revert, not a rewrite', wait_for(r'pushed already', 5), screen())
    keys('r'); time.sleep(1.5)
    log = git('log --format=%s -3').stdout
    check('67 git undo: … reverted with a new commit', log.startswith('Revert "add one again"'), log)
    # a pull, undone: back to before it (other people's commits gone again), a file being edited kept
    other = TMP + '/other67'
    shutil.rmtree(other, ignore_errors=True)
    sh('git clone -q ' + TMP + '/remote67.git ' + other)
    sh('cd ' + other + ' && git -c user.email=b@c -c user.name=o commit -q --allow-empty -m "theirs" && git push -q')
    before = git('rev-parse HEAD').stdout.strip()
    git('pull -q --no-rebase')
    open(W + '/notes.txt', 'w').write('mine\n')
    palette('Git: undo…'); time.sleep(1)
    check('67 git undo: a pull listed', wait_for(r'Undo the pull', 5), screen())
    keys('Enter'); time.sleep(0.6); keys('u'); time.sleep(1.5)
    check('67 git undo: the pull undone — back where the branch was, the uncommitted file kept',
          git('rev-parse HEAD').stdout.strip() == before and os.path.exists(W + '/notes.txt'), git('log --oneline -3').stdout)

def t_67_commit_checks():
    # checks before a commit: an unformatted staged file stops it (format and stage, or commit anyway); a test that
    # fails stops it too; once formatted and passing, it commits
    setup({"nim.nimsuggest": None, "git.checksBeforeCommit": None, "editor.formatOnSave": True})
    git('config user.email a@b'); git('config user.name tester')
    open(W + '/calc.nim', 'w').write('proc twice*(x:int):int=x*2\n')
    os.makedirs(W + '/tests', exist_ok=True)
    open(W + '/tests/tcalc.nim', 'w').write('import std/unittest\nimport ../calc\n\ntest "twice":\n  check twice(2) == 5\n')
    git('add calc.nim tests/tcalc.nim')
    start('src/demo.nim', w=130, h=34)
    palette('Git: commit (message box)…'); time.sleep(0.8)
    text('add calc'); keys('C-s')
    check('67 commit checks: an unformatted staged file stops the commit', wait_for(r'Not formatted: calc.nim', 8), screen())
    keys('f')
    ok = wait_for(r'Tests fail: tcalc.nim: twice', 60)
    check('67 commit checks: formatted and staged, then the tests run — one fails, not committed', ok and
          git('show :calc.nim').stdout == 'proc twice*(x: int): int =\n  x * 2\n', screen() + git('show :calc.nim').stdout)
    check('67 commit checks: … nothing committed yet', 'add calc' not in git('log --format=%s -1').stdout, git('log -1').stdout)
    keys('x'); time.sleep(0.4)
    open(W + '/tests/tcalc.nim', 'w').write('import std/unittest\nimport ../calc\n\ntest "twice":\n  check twice(2) == 4\n')
    git('add tests/tcalc.nim')
    keys('C-s')                                  # (the message is still open: commit again)
    for _ in range(60):
        if 'add calc' in git('log --format=%s -1').stdout: break
        time.sleep(1)
    check('67 commit checks: formatted, the tests pass — committed', 'add calc' in git('log --format=%s -1').stdout,
          screen() + git('log --format=%s -2').stdout)

def t_67_review_comments():
    # the review comments of the branch's pull request (GitHub, through gh — a stand-in here): a note at the end of
    # their line, the thread on hover, a list; reply and resolve go to GitHub
    setup({"nim.nimsuggest": None})
    mock = TMP + '/mockbin'
    shutil.rmtree(mock, ignore_errors=True); os.makedirs(mock)
    js = ('{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":['
          '{"id":"T1","isResolved":false,"isOutdated":false,"path":"src/demo.nim","line":5,"originalLine":5,'
          '"comments":{"nodes":[{"databaseId":111,"author":{"login":"alice"},"body":"Use fmt here?","url":"https://x/1"},'
          '{"databaseId":112,"author":{"login":"bob"},"body":"Agreed.","url":"https://x/2"}]}},'
          '{"id":"T2","isResolved":true,"isOutdated":false,"path":"src/demo.nim","line":2,"originalLine":2,'
          '"comments":{"nodes":[{"databaseId":121,"author":{"login":"carol"},"body":"Old nit","url":"https://x/3"}]}}'
          ']}}}}}')
    open(TMP + '/threads.json', 'w').write(js)
    open(mock + '/gh', 'w').write('#!/bin/sh\necho "$*" >> ' + TMP + '/gh.log\n'
        'case "$1 $2" in\n'
        '  "pr view") echo \'{"number":7,"url":"https://github.com/foxtest/demo/pull/7"}\'; exit 0;;\n'
        '  "repo view") echo \'{"owner":{"login":"foxtest"},"name":"demo"}\'; exit 0;;\n'
        '  "run list") echo "[]"; exit 0;;\n'
        'esac\n'
        'case "$*" in\n'
        '  *reviewThreads*) cat ' + TMP + '/threads.json; exit 0;;\n'
        '  *resolveReviewThread*) echo "{}"; exit 0;;\n'
        '  *replies*) echo "{}"; exit 0;;\n'
        'esac\nexit 1\n')
    os.chmod(mock + '/gh', 0o755)
    start('src/demo.nim', w=130, h=34, path=mock + ':' + TOOLS + ':$PATH')
    palette('Git: GitHub review comments…')
    ok = wait_for(r'review comments', 8)
    sc = screen()
    check('67 reviews: the pull request\'s threads listed, open ones first', ok and sc.find('alice: Use fmt here?') >= 0 and
          sc.find('alice') < sc.find('carol'), sc)
    keys('Escape'); time.sleep(0.4)
    sc = screen()
    check('67 reviews: an open thread\'s first comment at the end of its line (+ the replies)',
          re.search(r'alice: Use fmt here\?\s+\(\+1\)', sc) is not None and 'Old nit' not in sc, sc)
    keys('C-g'); text('5'); keys('Enter'); keys('M-h')
    check('67 reviews: the whole thread on hover', wait_for(r'bob.*Agreed', 4), screen())
    keys('Escape')
    palette('Git: GitHub review comments…'); wait_for(r'review comments', 8); keys('Enter'); time.sleep(0.5)
    text('Resolve'); time.sleep(0.3); keys('Enter'); time.sleep(1.5)
    palette('Git: GitHub review comments…'); wait_for(r'review comments', 8); keys('Enter'); time.sleep(0.5)
    text('Reply'); time.sleep(0.3); keys('Enter'); time.sleep(0.5); text('Done, thanks'); keys('Enter'); time.sleep(1.5)
    log = open(TMP + '/gh.log').read()
    check('67 reviews: resolve and reply go to GitHub', 'threadId' in log and '"T1"' not in log and 'T1' in log and
          'pulls/7/comments/111/replies' in log and 'Done, thanks' in log, log[-800:])

def t_67_ai_grounded():
    # inline suggestions get the declarations the code nearby uses, and a suggestion that names what does not exist
    # here (a proc string does not have) is not shown — the engine checks it first
    setup({"nim.nimsuggest": None, "ai.inlineCompletion": True, "ai.inlineCompletionDelay": 300})
    open(W + '/gh67.nim', 'w').write('import std/strutils\n\nproc shout(name: string): string =\n  # GHOSTGOOD\n  result =\n')
    open(W + '/gb67.nim', 'w').write('import std/strutils\n\nproc shout(name: string): string =\n  # GHOSTBAD\n  result =\n')
    start('gh67.nim', w=110, h=20); time.sleep(1.5)
    keys('C-g'); text('5'); keys('Enter'); keys('End'); text(' ')
    ok = wait_for(r'result = name\.toUpperAscii', 8)
    check('67 AI: a suggestion that uses real names is shown', ok, screen())
    log = open(os.environ['NED_TEST_MOCK_LOG']).read() if os.path.exists(os.environ.get('NED_TEST_MOCK_LOG', '')) else ''
    reqs = [l for l in log.splitlines() if 'GHOSTGOOD' in l]
    check('67 AI: … asked with the declarations the code nearby uses', reqs and '<definitions' in reqs[-1], (reqs or [''])[-1][-600:])
    tm('kill-server'); time.sleep(0.3)
    start('gb67.nim', w=110, h=20); time.sleep(1.5)
    keys('C-g'); text('5'); keys('Enter'); keys('End'); text(' ')
    time.sleep(4)
    log = open(os.environ['NED_TEST_MOCK_LOG']).read()
    asked = any('GHOSTBAD' in l for l in log.splitlines())
    check('67 AI: a suggestion naming what does not exist (name.toUpperFirst) is not shown', asked and
          'toUpperFirst' not in screen(), screen())

def t_67_ai_fix_test():
    # a failing test: Alt+Enter › make it pass with AI — the change applied, the test run again, kept when it passes;
    # a first answer that does not make it pass is undone and the model asked once more with the new failure
    for case in ['first', 'second try']:
        setup({"nim.nimsuggest": None, "nim.testOnSave": None})
        open(W + '/calc.nim', 'w').write('proc twice*(x: int): int = x * 3\n')
        os.makedirs(W + '/tests', exist_ok=True)
        open(W + '/tests/tcalc.nim', 'w').write('import std/unittest\nimport ../calc\n\ntest "twice ' + case + '":\n'
                                                 '  check twice(2) == 4\n')
        start('tests/tcalc.nim', w=120, h=26); time.sleep(1.2)
        keys('C-s')
        wait_for(r'Check failed', 60)
        keys('C-g'); text('5'); keys('Enter'); keys('M-Enter'); time.sleep(0.6)
        check('67 AI test fix (' + case + '): offered on the failed check', 'Make this test pass with AI' in screen(), screen())
        text('Make this test'); keys('Enter')
        ok = wait_for(r'passes now', 90)
        check('67 AI test fix (' + case + '): the code fixed and kept — the test passes', ok and
              ftext('calc.nim') == 'proc twice*(x: int): int = x * 2\n', screen() + ftext('calc.nim'))
        if case == 'second try':
            log = open(os.environ['NED_TEST_MOCK_LOG']).read()
            check('67 AI test fix: a first answer that failed was undone, then asked again with the failure',
                  'Your previous answer was' in log, '')

def t_67_format_changed():
    # format on save, only where lines changed (git): the proc you edited is formatted, the old one untouched
    setup({"nim.nimsuggest": None, "editor.formatOnSave": True, "editor.formatOnSaveScope": "changed"})
    git('config user.email a@b'); git('config user.name tester')
    open(W + '/old67.nim', 'w').write('proc a(x:int):int=x+1\n\nproc b(y:int):int=y+2\n')
    git('add old67.nim'); git('commit -qm old')
    start('old67.nim', w=110, h=20); time.sleep(1.5)
    keys('C-g'); text('3'); keys('Enter'); keys('End'); keys('BSpace'); text('3'); keys('C-s'); time.sleep(1)
    got = ftext('old67.nim')
    check('67 format changed lines: the edited proc formatted, the untouched one as it was',
          got == 'proc a(x:int):int=x+1\n\nproc b(y: int): int =\n  y + 3\n', got)

def t_67_format_preview():
    # what formatting would change, side by side first — then applied (or left)
    setup({"nim.nimsuggest": None})
    open(W + '/pv67.nim', 'w').write('proc a(x:int):int=x+1\n')
    start('pv67.nim', w=120, h=24); time.sleep(1.2)
    palette('Format: preview the change')
    ok = wait_for(r'Format pv67.nim: \+2', 6)
    sc = screen()
    check('67 format preview: the change shown, then asked', ok and 'Apply it' in sc and 'Leave it' in sc, sc)
    keys('Escape'); time.sleep(0.3)
    check('67 format preview: side by side, nothing changed yet', 'Diff: pv67.nim' in screen() and
          ftext('pv67.nim') == 'proc a(x:int):int=x+1\n', screen())
    keys('C-w'); time.sleep(0.3)                 # (the side-by-side view closed: the file in front)
    palette('Format: preview the change'); wait_for(r'Apply it', 6); keys('Enter'); time.sleep(0.5)
    keys('C-s'); time.sleep(0.6)
    check('67 format preview: applied', ftext('pv67.nim') == 'proc a(x: int): int =\n  x + 1\n', ftext('pv67.nim'))

def t_67_yaml_toml():
    # ned's own YAML and TOML formatters: only the layout changes
    setup({"nim.nimsuggest": None})
    open(W + '/c67.yaml', 'w').write('a:\n  b:\n    c: 1\n  d:\n      e: 2\n  f:\n    g:     3\n')
    open(W + '/c67.toml', 'w').write('name="x"\n[ deps ]\nlist=[1,2]\n')
    start('c67.yaml', w=110, h=20); time.sleep(1)
    keys('M-f'); time.sleep(0.5); keys('C-s'); time.sleep(0.5)
    check('67 YAML formatted: one indentation width (the file\'s), one space after a key',
          ftext('c67.yaml') == 'a:\n  b:\n    c: 1\n  d:\n    e: 2\n  f:\n    g: 3\n', ftext('c67.yaml'))
    keys('C-p'); text('c67.toml'); time.sleep(0.4); keys('Enter'); time.sleep(0.6)
    keys('M-f'); time.sleep(0.5); keys('C-s'); time.sleep(0.5)
    check('67 TOML formatted', ftext('c67.toml') == 'name = "x"\n\n[deps]\nlist = [1, 2]\n', ftext('c67.toml'))

def t_67_termux_clock():
    # Termux's colours from the theme (yours kept and put back), following theme changes; light by day, dark at night
    home = TMP + '/termux67'
    shutil.rmtree(home, ignore_errors=True)
    os.makedirs(home + '/.termux'); os.makedirs(home + '/bin')
    own = 'background=#123456\nforeground=#abcdef\n'
    open(home + '/.termux/colors.properties', 'w').write(own)
    open(home + '/bin/termux-reload-settings', 'w').write('#!/bin/sh\necho x >> %s/reloaded\n' % home)
    os.chmod(home + '/bin/termux-reload-settings', 0o755)
    f = home + '/.termux/colors.properties'
    env = 'HOME=%s TERMUX_VERSION=0.118.1' % home
    setup({"theme": "nim-crown", "nim.nimsuggest": None})
    start('src/demo.nim', w=120, h=30, path=home + '/bin:' + TOOLS + ':$PATH', env_extra=env); time.sleep(0.6)
    palette('Theme: use these colours in all of Termux'); time.sleep(1.0)
    c = open(f).read()
    check('67 Termux colours written from the theme', c.startswith('# written by ned') and 'nim-crown' in c and
          'background=#' in c and 'color15=#' in c and 'cursor=#' in c, c)
    check('67 your own Termux colours kept beside them', open(f + '.ned-backup').read() == own)
    check('67 Termux told to read them again', os.path.exists(home + '/reloaded'))
    palette("Theme: put Termux's own colours back"); time.sleep(0.8)
    check("67 Termux's own colours put back", open(f).read() == own and not os.path.exists(f + '.ned-backup'), open(f).read())
    # following the theme
    setup({"theme": "nim-crown", "theme.termuxColors": True, "nim.nimsuggest": None})
    start('src/demo.nim', w=120, h=30, path=home + '/bin:' + TOOLS + ':$PATH', env_extra=env); time.sleep(0.6)
    check('67 Termux follows the theme from the start', 'nim-crown' in open(f).read(), open(f).read())
    keys('M-t'); time.sleep(0.6); text('modus-operandi'); time.sleep(0.4); keys('Enter'); time.sleep(1.0)
    check('67 Termux follows a theme change', 'modus-operandi' in open(f).read(), open(f).read())
    # day and night by the clock (the Termux file says which theme is on)
    setup({"theme": "auto", "theme.autoBy": "clock", "theme.dayStarts": "00:00", "theme.nightStarts": "23:59",
           "theme.termuxColors": True, "nim.nimsuggest": None})
    start('src/demo.nim', w=120, h=30, path=home + '/bin:' + TOOLS + ':$PATH', env_extra=env); time.sleep(0.6)
    check('67 by the clock: the light theme by day', 'github-light' in open(f).read(), open(f).read())
    setup({"theme": "auto", "theme.autoBy": "clock", "theme.dayStarts": "23:59", "theme.nightStarts": "00:00",
           "theme.termuxColors": True, "nim.nimsuggest": None})
    start('src/demo.nim', w=120, h=30, path=home + '/bin:' + TOOLS + ':$PATH', env_extra=env); time.sleep(0.6)
    check('67 by the clock: the dark theme at night', 'nim-crown' in open(f).read(), open(f).read())
    # not Termux: nothing written
    setup({"theme": "nim-crown", "nim.nimsuggest": None})
    os.remove(f)
    start('src/demo.nim', w=120, h=30, env_extra='HOME=' + home); time.sleep(0.6)
    palette('Theme: use these colours in all of Termux'); time.sleep(0.6)
    check('67 not Termux: said, nothing written', 'not Termux' in screen() and not os.path.exists(f), screen())

def sgr_at_col(row, k):
    """the SGR attributes (1 bold, 9 struck through …) in force at column k of an ANSI row"""
    at, col, i = set(), 0, 0
    while i < len(row):
        m = re.match(r'\x1b\[([0-9;:]*)m', row[i:])
        if m:
            ps = m.group(1).split(';')
            j = 0
            while j < len(ps):
                if ps[j] in ('38', '48', '58') and j + 1 < len(ps) and ps[j + 1] == '2': j += 5; continue
                if ps[j] in ('0', ''): at = set()
                elif ps[j] in ('22',): at -= {'1', '2'}
                elif ps[j] in ('29',): at.discard('9')
                else: at.add(ps[j])
                j += 1
            i += m.end(); continue
        if col == k: return at
        col += 1; i += 1
    return set()

def t_67_rich_colors():
    # Nim: a var tinted, a let plain, the module's own variables in bold, deprecated names struck through, cast/addr tinted
    setup({"nim.nimsuggest": None})
    open(W + '/r67.nim', 'w').write('var counter = 0\nlet limit = 10\nproc old(x: int): int {.deprecated: "use fresh".} = x\n'
        'proc fresh(x: int): int = x\nproc work(a: int): int =\n  var total = a\n  let step = 2\n'
        '  total += step + counter + limit\n  let p = addr total\n  result = old(total) + cast[int](p)\n')
    start('r67.nim', w=110, h=20); time.sleep(2.0)
    keys('Down'); time.sleep(1.0)
    row = ansi_row('total += step')
    plain = re.sub(r'\x1b\[[0-9;:]*m', '', row)
    check('67 a var is tinted, a let is not', fg_at(row, 'total') != fg_at(row, 'step') and fg_at(row, 'total') == fg_at(row, 'counter'),
          str((fg_at(row, 'total'), fg_at(row, 'step'), fg_at(row, 'counter'))))
    check("67 the module's own variables in bold", '1' in sgr_at_col(row, plain.find('counter')) and
          '1' in sgr_at_col(row, plain.find('limit')) and '1' not in sgr_at_col(row, plain.find('step')),
          str((sgr_at_col(row, plain.find('counter')), sgr_at_col(row, plain.find('step')))))
    row2 = ansi_row('result = old(')
    p2 = re.sub(r'\x1b\[[0-9;:]*m', '', row2)
    check('67 a deprecated proc is struck through where it is called', '9' in sgr_at_col(row2, p2.find('old(')),
          str(sgr_at_col(row2, p2.find('old('))))
    row3 = ansi_row('addr total')
    check('67 addr and cast in the warning colour', fg_at(row3, 'addr') != fg_at(row3, 'let') and fg_at(row3, 'addr') is not None and
          fg_at(row2, 'cast') == fg_at(row3, 'addr'), str((fg_at(row3, 'addr'), fg_at(row3, 'let'), fg_at(row2, 'cast'))) + row2 + row3)
    setup({"nim.nimsuggest": None, "nim.richColors": False})
    start('r67.nim', w=110, h=20); time.sleep(2.0)
    keys('Down'); time.sleep(1.0)
    row = ansi_row('total += step')
    check('67 nim.richColors off: as before', fg_at(row, 'total') == fg_at(row, 'step'), str((fg_at(row, 'total'), fg_at(row, 'step'))))

def t_67_theme_editor():
    # every colour of the theme with its contrast; a change goes into your copy of the theme and shows at once
    setup({"theme": "nim-crown"})
    if os.path.exists(CFG + '/ned/themes/nim-crown-mine.json'): os.remove(CFG + '/ned/themes/nim-crown-mine.json')
    start('src/demo.nim', w=120, h=34); time.sleep(0.6)
    palette('Theme: edit colours'); time.sleep(0.6)
    s = screen()
    check('67 theme editor lists the colours with their contrast', 'Theme editor' in s and 'comment' in s and ':1' in s and '██' in s, s)
    text('comment'); time.sleep(0.3); keys('Enter'); time.sleep(0.5)
    keys('Enter'); time.sleep(0.4)                       # Type a colour…
    keys('C-u'); text('#22252a'); keys('Enter'); time.sleep(1.0)
    f = CFG + '/ned/themes/nim-crown-mine.json'
    j = json.load(open(f)) if os.path.exists(f) else {}
    check('67 the change goes into your copy of the theme, put in use', j.get('colors', {}).get('comment', '').lower() == '#22252a' and
          re.search(r'"theme"\s*:\s*"nim-crown-mine"', open(CFG + '/ned/config.json').read()) is not None,
          str(j) + open(CFG + '/ned/config.json').read())
    s = screen()
    check('67 a hard-to-read colour is marked', '⚠ comment' in s and 'hard to read' in s, s)
    text('comment'); time.sleep(0.3); keys('Enter'); time.sleep(0.5)
    s = screen()
    check('67 "make it readable" is offered', 'Make it readable' in s, s)
    text('readable'); time.sleep(0.3); keys('Enter'); time.sleep(1.0)
    c = json.load(open(f))['colors']['comment']
    check('67 made readable', c.lower() != '#22252a' and '⚠ comment' not in screen(), c + screen())

def t_67_two_servers():
    # a linter's server next to the main one: both servers' problems in one list, edits keep both, its fix applies
    setup({"lsp": {"python": ["python3", MOCKS + "/mocklsp.py"]},
           "lsp.alsoRun": {"python": [["python3", MOCKS + "/mocklint.py"]]}})
    open(W + '/two.py', 'w').write('x = PRIMARY_ERR\ny = TODO_LINT\nprint(x, y)\n')
    start('two.py', w=120, h=26); time.sleep(2.5)
    s = screen()
    check('67 both servers named in the status bar', 'mocklsp.py + mocklint.py' in s, s)
    palette('Show problems'); time.sleep(0.8)
    s = screen()
    check("67 both servers' problems listed", 'PRIMARY_ERR here' in s and 'TODO_LINT left in' in s, s)
    keys('Escape'); time.sleep(0.2)
    keys('C-g'); text('3:1'); keys('Enter'); time.sleep(0.2)
    text('z = 1\n'); time.sleep(1.5)
    palette('Show problems'); time.sleep(0.8)
    s = screen()
    check("67 after an edit both servers' problems are still there", 'PRIMARY_ERR here' in s and 'TODO_LINT left in' in s, s)
    keys('Escape'); time.sleep(0.2)
    keys('C-g'); text('2:6'); keys('Enter'); time.sleep(0.3)
    keys('M-Enter'); time.sleep(1.2)
    s = screen()
    check("67 the linter's fix among the quick fixes", 'Replace TODO_LINT with DONE' in s, s)
    text('Replace TODO'); time.sleep(0.3); keys('Enter'); time.sleep(0.6)
    keys('C-s'); time.sleep(1.2)
    check("67 the linter's fix applied", 'y = DONE' in ftext('two.py'), ftext('two.py'))
    palette('Show problems'); time.sleep(0.8)
    s = screen()
    check("67 the linter's problem gone, the main server's stays", 'PRIMARY_ERR here' in s and 'TODO_LINT left in' not in s, s)
    if which('ruff'):
        # the known linters: ruff next to the main server, when installed
        setup({"lsp": {"python": ["python3", MOCKS + "/mocklsp.py"]}, "lsp.linters": True})
        open(W + '/r.py', 'w').write('import os\nprint(1)\n')
        start('r.py', w=120, h=26); time.sleep(4)
        palette('Show problems'); time.sleep(0.8)
        s = screen()
        check('67 ruff found and run next to the main server', '`os` imported but unused' in s or 'F401' in s, s)

def t_67_lsp_links():
    # pull diagnostics (a server that only answers when asked), document links (underlined, F12 opens them, a URL in
    # a comment too), on-type formatting (editor.formatOnType)
    mock = TMP + '/l2bin'
    shutil.rmtree(mock, ignore_errors=True); os.makedirs(mock)
    open(mock + '/xdg-open', 'w').write('#!/bin/sh\necho "$1" > %s/opened\n' % mock)
    os.chmod(mock + '/xdg-open', 0o755)
    setup({"lsp": {"lua": ["python3", MOCKS + "/mockl2.py"]}, "editor.formatOnType": True})
    open(W + '/l2.lua', 'w').write('local a = 1\nlocal b = BAD\n-- see LINK:other here\n-- docs: https://example.com/x\n')
    open(W + '/other.lua', 'w').write('-- other\nlocal second = 2\n')
    start('l2.lua', w=110, h=24, path=mock + ':' + TOOLS + ':$PATH'); time.sleep(2.5)
    palette('Show problems'); time.sleep(0.8)
    s = screen()
    check('67 pull diagnostics: the server is asked for the problems', 'BAD is pulled' in s, s)
    keys('Escape'); time.sleep(0.2)
    row = ansi_row('see LINK:other')
    plain = re.sub(r'\x1b\[[0-9;:]*m', '', row)
    check("67 the server's link is underlined", '4' in sgr_at_col(row, plain.find('other here')), str(sgr_at_col(row, plain.find('other here'))))
    keys('C-g'); text('3:13'); keys('Enter'); time.sleep(0.3)
    keys('F12'); time.sleep(0.8)
    s = screen()
    check("67 F12 on a server's link opens its target, at its line", 'other.lua' in s and status_pos() == (2, 1), str(status_pos()) + s)
    keys('M-,'); time.sleep(0.5)
    keys('C-g'); text('4:18'); keys('Enter'); time.sleep(0.3)
    keys('F12'); time.sleep(1.0)
    check('67 F12 on a URL in a comment opens the browser', os.path.exists(mock + '/opened') and
          'https://example.com/x' in open(mock + '/opened').read())
    keys('C-g'); text('2:1'); keys('Enter'); time.sleep(0.2)
    keys('C-k'); time.sleep(0.2)                         # (the line with BAD goes)
    keys('Enter'); keys('Up'); time.sleep(0.2)
    text('local  c   =  {}'); time.sleep(1.5)
    check('67 on-type formatting after }', 'local c = {}' in screen(), screen())
    palette('Show problems'); time.sleep(0.8)
    s = screen()
    check('67 pulled again after the edit', 'BAD is pulled' not in s, s)

def t_67_ai_plan():
    # plan first (reading only: an edit is refused), then one step, then the rest; back to before step 1
    setup({"ai.agent": True, "ai.autoApprove": "edits", "ai.checkEdits": False})
    utils = W + '/src/demo/utils.nim'
    before = open(utils).read()
    start('src/demo.nim', w=130, h=40); time.sleep(0.6)
    palette('AI: plan a change'); time.sleep(0.4)
    text('PLANTASK add two procs'); keys('Enter')
    ok = wait_for('Do it: all 2 steps', 15)
    s = screen()
    check('67 the plan comes first, as a menu', ok and 'One step' in s and 'Change the plan' in s, s)
    check('67 nothing is changed while planning (an edit is refused)', open(utils).read() == before, open(utils).read())
    keys('Down'); keys('Enter')                          # One step
    ok = wait_for('Go on: the last step', 15)
    check('67 one step done, then the menu again', ok and 'twice2' in open(utils).read() and 'thrice2' not in open(utils).read(),
          open(utils).read() + screen())
    keys('Enter')                                        # Go on
    ok = wait_for('plan is done', 15)
    check('67 the rest done', ok and 'thrice2' in open(utils).read(), open(utils).read() + screen())
    palette('AI: the plan'); time.sleep(0.6)
    s = screen()
    check('67 restore points for each step', 'Back to before step 2' in s and 'Back to before step 1' in s, s)
    text('before step 1'); time.sleep(0.3); keys('Enter'); time.sleep(0.4); keys('y'); time.sleep(1.0)
    check('67 back to before step 1: the files as they were', open(utils).read() == before, open(utils).read())

def t_67_ai_offline():
    # AI on this device: a running Ollama found, a model that fits downloaded (progress shown), ned set to it, timed
    port = 11999
    srv = subprocess.Popen(['python3', MOCKS + '/mockollama.py', str(port)])
    try:
        time.sleep(0.5)
        setup({"ai.localUrl": "http://127.0.0.1:%d" % port})
        start('src/demo.nim', w=130, h=34); time.sleep(0.6)
        palette('AI: on this device'); time.sleep(1.5)
        s = screen()
        check('67 offline AI: a running Ollama found, a model that fits offered', 'Ollama is running' in s and
              'Download and use qwen2.5-coder' in s, s)
        keys('Enter')
        ok = wait_for('answers on this device', 15)
        cfg = open(CFG + '/ned/config.json').read()
        check('67 the model downloaded, ned set to it, a first answer timed', ok and '"ollama"' in cfg and
              'qwen2.5-coder' in cfg and '127.0.0.1:%d/v1' % port in cfg, cfg + screen())
        palette('AI: on this device'); time.sleep(1.5)
        s = screen()
        check('67 the downloaded model listed', 'Use qwen2.5-coder' in s and 'in use' in s, s)
    finally:
        srv.kill()

def t_66_trust():
    # a folder's code runs only once you trust it: its config.nims (run by the compiler) does nothing on open or
    # while typing, the built-in engine still answers, and Trust runs what was held back
    setup({"nim.nimsuggest": None, "security.folderTrust": "ask"})
    open(W + '/config.nims', 'w').write('writeFile("PWNED", "config.nims ran")\n')
    open(W + '/tr.nim', 'w').write('proc greet(name: string): string = "hi " & name\necho greet("x")\n'
                                   'let n: int = "no"\n')
    start('tr.nim', w=150, h=30); time.sleep(4)
    check('66 trust: opening an untrusted folder runs none of its code', not os.path.exists(W + '/PWNED'), screen())
    check('66 trust: … says so, with the way to trust it', wait_for(r'Not trusted', 4), screen())
    keys('C-g'); text('2:7'); keys('Enter'); keys('M-h'); time.sleep(1)
    check('66 trust: the built-in engine still answers', 'name: string' in screen(), screen())
    keys('Escape')
    keys('C-End'); keys('Enter'); text('echo greet("y")'); time.sleep(4)
    check('66 trust: typing runs none of it either', not os.path.exists(W + '/PWNED'), screen())
    palette('Nim: check project'); time.sleep(2)
    check('66 trust: nor a check you ask for — it says why', not os.path.exists(W + '/PWNED') and
          re.search(r'(?i)not trusted', screen()) is not None, screen())
    palette('Workspace: trust this folder')
    t0 = time.time()
    while time.time() - t0 < 25 and not os.path.exists(W + '/PWNED'): time.sleep(0.5)
    check('66 trust: trusted — the compiler checks it now (its config.nims ran)', os.path.exists(W + '/PWNED'), screen())
    check('66 trust: … and finds the error', wait_for(r"type mismatch|got 'string'", 20), screen())
    check('66 trust: the badge goes', 'Not trusted' not in screen(), screen())

def t_63_git():
    # git for new folders: initialize here (asked first inside another repository), git asks your name once;
    # a new Nim project gets its first commit; clone from a link (a branch in the link, a login in it refused)
    setup({"nim.nimsuggest": None})
    home = TMP + '/home63'
    shutil.rmtree(home, ignore_errors=True); os.makedirs(home)
    env = 'HOME=%s GIT_CONFIG_NOSYSTEM=1' % home
    os.makedirs(W + '/fresh'); open(W + '/fresh/a.nim', 'w').write('echo 1\n')
    start('fresh', w=120, h=34, env_extra=env); time.sleep(1.0)
    palette('Git: initialize a repository here'); time.sleep(0.6)
    check('63 git init inside another repository asks first', 'inside the git repository' in screen(), screen())
    keys('y'); time.sleep(1.5)
    ok = os.path.isdir(W + '/fresh/.git')
    check('63 … and makes the repository', ok, str(os.listdir(W + '/fresh')))
    check('63 git asks your name for commits (once, kept in your git settings)', wait_for('Your name, for git commits', 5),
          screen())
    keys('C-u'); text('Test Person'); keys('Enter'); time.sleep(0.4)
    text('test@example.com'); keys('Enter'); time.sleep(0.6)
    cfg = open(home + '/.gitconfig').read() if os.path.exists(home + '/.gitconfig') else ''
    check('63 … and git config --global has it', 'Test Person' in cfg and 'test@example.com' in cfg, cfg)
    # a new Nim project: its repository with a first commit
    palette('Nim: new project…'); time.sleep(0.4); text('proj63'); keys('Enter')
    end = time.time() + 15
    log = ''
    while time.time() < end:
        log = sh('git -C %s/fresh/proj63 log --oneline 2>&1' % W).stdout
        if 'First commit' in log: break
        time.sleep(0.4)
    check('63 a new Nim project is a git repository with its first commit', 'First commit' in log, log)
    tm('kill-server'); time.sleep(0.3)
    # clone from a link
    src = TMP + '/origin63'
    shutil.rmtree(src, ignore_errors=True); os.makedirs(src)
    open(src + '/README.md', 'w').write('# Hello from the clone\n')
    open(src + '/thing.nimble', 'w').write('version = "0.1.0"\nrequires "nim >= 2.0.0"\n')
    G = 'git -C %s -c user.name=t -c user.email=t@t ' % src
    sh('git init -q -b main ' + src); sh(G + 'add -A'); sh(G + 'commit -qm one')
    dest = TMP + '/cloned63'
    shutil.rmtree(dest, ignore_errors=True)
    start('', w=120, h=34, env_extra=env); time.sleep(0.8)
    keys('g'); time.sleep(0.5)                       # (the Welcome page: g)
    check('63 the Welcome page: g clones from a link', 'Link to clone' in screen(), screen())
    keys('C-u'); text('https://ann:secret@github.com/x/y'); keys('Enter'); time.sleep(0.5)
    check('63 a link with a login in it is refused', wait_for('password or token', 3), screen())
    palette('File: clone from a link…'); time.sleep(0.4)
    keys('C-u'); text('https://github.com/x/y/tree/dev/src'); keys('Enter'); time.sleep(0.4)
    keys('C-u'); text(TMP + '/never63'); keys('Enter'); time.sleep(0.5)
    s = screen()
    check('63 a branch named in the link is cloned (github.com/x/y/tree/dev → branch dev)',
          'https://github.com/x/y' in s and 'branch dev' in s and '/tree/' not in s, s)
    keys('Escape'); time.sleep(0.3)
    palette('File: clone from a link…'); time.sleep(0.4)
    keys('C-u'); text('file://' + src); keys('Enter'); time.sleep(0.4)
    keys('C-u'); text(dest); keys('Enter'); time.sleep(0.5)
    keys('Enter'); time.sleep(0.3)                   # Clone
    check('63 cloned: the folder opens with its README', wait_for('Hello from the clone', 15) and
          os.path.isdir(dest + '/.git'), screen())
    check('63 … and a Nim project offers to install what it needs', wait_for('install the packages it needs', 5), screen())

def t_68_nedfmt():
    # ned --format (and nedfmt): --diff, stdin, --outDir, .nph.toml filters, the pre-commit hook; then the Nim
    # parser as the formatter's second check (nim.format.verify) — in the editor too
    setup()
    messy = 'proc  g(a:int,b:int):int=\n    a+b\n'
    open(W + '/m.nim', 'w').write(messy)
    r = subprocess.run([BIN, '--format', '--diff', W + '/m.nim'], capture_output=True, text=True)
    check('68 --diff shows the change and changes nothing', r.returncode == 0 and '-proc  g(a:int,b:int):int=' in r.stdout and
          '+proc g(a: int, b: int): int =' in r.stdout and ftext('m.nim') == messy, r.stdout + r.stderr)
    r = subprocess.run([BIN, '--format', '--stdin-name=x.nim', '-'], input='let  x=1\n', capture_output=True, text=True)
    check('68 stdin to stdout', r.returncode == 0 and r.stdout == 'let x = 1\n', repr((r.returncode, r.stdout, r.stderr)))
    os.makedirs(W + '/fmtdir/vendor', exist_ok=True)
    open(W + '/fmtdir/a.nim', 'w').write(messy)
    open(W + '/fmtdir/vendor/b.nim', 'w').write(messy)
    open(W + '/fmtdir/.nph.toml', 'w').write('extend-exclude = [\n  "vendor",\n]\n')
    r = subprocess.run([BIN, '--format', '--check', '.'], capture_output=True, text=True, cwd=W + '/fmtdir')
    check('68 .nph.toml: vendor/ left out', r.returncode == 1 and 'a.nim: would change' in r.stdout and 'vendor' not in r.stdout,
          r.stdout + r.stderr)
    r = subprocess.run([BIN, '--format', '--quiet', '--outDir:out', 'a.nim'], capture_output=True, text=True, cwd=W + '/fmtdir')
    check('68 --outDir writes beside, the original stays', r.returncode == 0 and ftext('fmtdir/out/a.nim').startswith('proc g(a: int') and
          ftext('fmtdir/a.nim') == messy, r.stdout + r.stderr)
    # the hook: an unformatted staged file stops the commit, a formatted one goes through
    env = dict(os.environ, PATH=os.path.dirname(BIN) + ':' + os.environ.get('PATH', ''))
    r = subprocess.run([BIN, '--format', '--install-hook'], capture_output=True, text=True, cwd=W, env=env)
    hook = open(W + '/.git/hooks/pre-commit').read() if os.path.exists(W + '/.git/hooks/pre-commit') else ''
    sh('cd %s && git add m.nim' % W)
    c1 = sh('cd %s && git -c user.name=t -c user.email=t@t commit -qm messy' % W)
    subprocess.run([BIN, '--format', '--quiet', W + '/m.nim'])
    sh('cd %s && git add m.nim' % W)
    c2 = sh('cd %s && git -c user.name=t -c user.email=t@t commit -qm tidy' % W)
    check('68 pre-commit hook: unformatted refused, formatted committed', r.returncode == 0 and '--format --check' in hook and
          c1.returncode != 0 and 'm.nim' in c1.stderr and c2.returncode == 0, repr((r.stdout, r.stderr, c1.stderr, c2.stderr)))
    sh('rm -f %s/.git/hooks/pre-commit' % W)
    # Nim's parser as a second check: needs the compiler's sources (a source build here)
    if not os.path.exists(NIMROOT + '/compiler/parser.nim'):
        check('68 parser check (skipped: no compiler sources)', True); return
    open(W + '/v.nim', 'w').write(messy)
    r = subprocess.run([BIN, '--format', '--verify', W + '/v.nim'], capture_output=True, text=True, timeout=300,
                       env=dict(os.environ, PATH=NIMBIN + ':' + os.environ.get('PATH', '')))
    check('68 --verify builds the checker once and formats', r.returncode == 0 and ftext('v.nim').startswith('proc g(a: int'),
          repr((r.returncode, r.stdout, r.stderr)))
    setup({"nim.format.verify": True})
    open(W + '/v2.nim', 'w').write(messy)
    start('v2.nim')
    keys('M-f'); ok = wait_for(r'Formatted', 20); keys('C-s'); time.sleep(0.5)
    check('68 the editor formats with the parser check on', ok and ftext('v2.nim').startswith('proc g(a: int'), screen()[-600:])

def t_68_engine_checks():
    # the engine's own checks, at once while typing (the compiler's check left to nimsuggest, which is off): a
    # field typo, a wrong number of arguments, code after a return, an unused local
    setup({"nim.nimsuggest": False, "nim.liveDiagnosticsFrom": "nimsuggest"})
    open(W + '/ec.nim', 'w').write('type\n  Point = object\n    x, y: int\n    label: string\n\n'
                                   'proc dist(a, b: Point): int =\n  abs(a.x - b.x) + abs(a.y - b.y)\n\n'
                                   'proc main() =\n  var p = Point(x: 1, y: 2, label: "a")\n  let q = Point(x: 3, y: 4)\n'
                                   '  echo p.label\n  echo dist(p, q)\n\nmain()\n')
    start('ec.nim', w=130, h=34); time.sleep(1.5)
    keys('C-g'); text('12:16'); keys('Enter'); keys('BSpace', 'BSpace'); text('le')         # label → lable
    keys('C-g'); text('13:16'); keys('Enter'); text(', 3')                                  # dist(p, q, 3)
    keys('C-g'); text('13'); keys('Enter', 'End', 'Enter'); text('return'); keys('Enter'); text('echo "never"')
    keys('Enter'); text('let spare = 1')
    ok = wait_for(r"did you mean 'label'", 8)
    palette('Show problems'); time.sleep(0.8)
    s = screen()
    check('68 engine: a field typo, with the field meant', ok, s)
    check('68 engine: a call with one argument too many', 'dist takes 2 arguments, here 3' in s, s)
    check('68 engine: code after a return', 'never runs' in s, s)
    keys('Escape')
    # off: nothing from the engine but its typo marks
    tm('kill-server'); time.sleep(0.3)
    setup({"nim.nimsuggest": False, "nim.liveDiagnosticsFrom": "nimsuggest", "nim.engineChecks": False})
    start('ec.nim', w=130, h=34); time.sleep(1.5)
    keys('C-g'); text('13:16'); keys('Enter'); text(', 3'); time.sleep(2)
    check('68 engine checks off: no argument count', 'takes 2 arguments' not in screen(), screen())
    # a value neither used nor discarded, a literal of the wrong type, an import nothing uses — the compiler's
    # words, so its quick fixes apply
    tm('kill-server'); time.sleep(0.3)
    setup({"nim.nimsuggest": False, "nim.liveDiagnosticsFrom": "nimsuggest"})
    open(W + '/ec2.nim', 'w').write('import std/[strutils, os]\n\nproc area(w, h: int): int = w * h\n\n'
                                    'proc main() =\n  let n: int = "three"\n  area(2, 3)\n  echo n, getCurrentDir()\n\nmain()\n')
    start('ec2.nim', w=130, h=34); time.sleep(1.5)
    keys('C-g'); text('10'); keys('Enter', 'End', 'Enter')
    ok = wait_for(r'has to be used', 8)
    palette('Show problems'); time.sleep(0.8)
    s = screen()
    check('68 engine: a value not used or discarded', ok, s)
    check('68 engine: a literal of the wrong type', "got 'string' for" in s, s)
    check('68 engine: an import nothing uses', "imported and not used: 'strutils'" in s and "'os'" not in s, s)
    keys('Escape')
    keys('C-g'); text('7:3'); keys('Enter', 'M-Enter'); time.sleep(0.8)
    ok = wait_for(r'Discard the result', 4)
    keys('Enter'); time.sleep(0.5)
    check('68 engine: its quick fix (discard) applies', ok and 'discard area(2, 3)' in screen(), screen())

def t_68_compiler_answers():
    # nimsuggest off (the default): a name the engine cannot know (a macro makes it) — hover and Go to definition
    # ask the compiler once
    setup({"nim.nimsuggest": False})
    open(W + '/mac.nim', 'w').write('import std/macros\n\nmacro makeProcs(names: varargs[untyped]): untyped =\n'
                                    '  result = newStmtList()\n  for n in names:\n    let nm = ident("get" & $n)\n'
                                    '    result.add quote do:\n      proc `nm`*(): string = "x"\n\nmakeProcs(Foo, Bar)\n\n'
                                    'echo getFoo()\n')
    start('mac.nim', w=130, h=34); time.sleep(1.5)
    keys('C-g'); text('12:7'); keys('Enter'); time.sleep(0.3)
    keys('M-h')
    ok = wait_for(r'getFoo\(\): string', 40)
    check('68 hover on a name a macro makes: the compiler answers', ok, screen())
    keys('Escape')

def t_68_macro_names():
    # names a macro makes, known without nimsuggest: the compiler expands the top-level macro calls once (the file
    # and the project files it imports) and completion, hover and Go to definition know what they declare
    setup({"nim.nimsuggest": False, "nim.compilerAnswers": False})
    open(W + '/gen.nim', 'w').write('import std/macros\n\nmacro makeProcs*(names: varargs[untyped]): untyped =\n'
                                    '  result = newStmtList()\n  for n in names:\n    let nm = ident("get" & $n)\n'
                                    '    result.add quote do:\n      proc `nm`*(): string = "x"\n\n'
                                    'macro makeType*(name: untyped): untyped =\n  result = quote do:\n'
                                    '    type `name`* = object\n      width*: int\n\n'
                                    'makeProcs(Foo, Bar)\nmakeType(Thing)\n')
    open(W + '/mm.nim', 'w').write('import gen\n\necho getBar()\nvar t: Thing\necho t.wi\necho getF\n')
    start('mm.nim', w=130, h=34); time.sleep(5)
    keys('C-g'); text('6'); keys('Enter', 'End', 'C-space')
    ok = wait_for(r'getFoo', 10)
    check('68 macro names: completion offers what an imported module\'s macro call makes', ok, screen())
    keys('Escape'); keys('C-g'); text('5'); keys('Enter', 'End', 'C-space')
    check('68 macro names: a field of a type a macro makes', wait_for(r'width', 6), screen())
    keys('Escape'); keys('C-g'); text('3:7'); keys('Enter', 'M-h')
    ok = wait_for(r'getBar\(\): string', 6)
    check('68 macro names: hover on the made proc, with the call that made it', ok and 'makeProcs(Foo, Bar)' in screen(), screen())
    keys('Escape'); keys('F12'); time.sleep(1.0)
    s = screen()
    check('68 macro names: Go to definition goes to the macro call', 'gen.nim' in s and re.search(r'Ln 15, Col 1\b', s) is not None, s)
    tm('kill-server'); time.sleep(0.3)
    setup({"nim.nimsuggest": False, "nim.compilerAnswers": False, "nim.macroNames": False})
    start('mm.nim', w=130, h=34); time.sleep(4)
    keys('C-g'); text('6'); keys('Enter', 'End', 'C-space'); time.sleep(2)
    check('68 macro names off: not offered', 'getFoo' not in screen(), screen())

tests = [t_edit_save_undo, t_find_replace, t_multicursor, t_project_search, t_terminal, t_run_file, t_lsp, t_lsp_diag, t_ai_chat, t_split_zen_theme, t_vim, t_recovery, t_quit_dirty, t_mixed_folder, t_builtin_nimsuggest, t_server_crash_restart, t_engine_member_completion, t_engine_hover_def_sig, t_engine_refs_rename, t_engine_imports, t_engine_without_nimsuggest, t_engine_outline_symbols, t_format_keeps_cursor, t_zen_vim, t_ai_insert, t_format_builtin, t_format_choice, t_reset_settings, t_52_refactors, t_52_format_selection, t_52_conflict, t_52_settings_search, t_52_mouse, t_521_debugger, t_521_touchbar, t_521_bp_follow_edits, t_522_navigation, t_522_peek_hierarchy_stage, t_522_rename_imports, t_522_shortcuts_markdown, t_522_multibuffer, t_522_nim_codegen, t_522_nim_tools, t_53_alerts_and_formatter, t_53_diff_view, t_53_rename_preview, t_53_debugger_watch_test, t_53_user_commands, t_531_help_menus, t_532_polish, t_54_git, t_55_publish, t_56_todos, t_561_review_fixes, t_562_format_cursor, t_563_open_folder, t_564_tiny_screens, t_564_save_safety, t_57_themes, t_57_ai, t_57_nim, t_57_git, t_571_rulers, t_572_editorconfig, t_572_tasks, t_572_errors, t_572_swatches, t_572_examples, t_59_small, t_59_html, t_59_problems_mb, t_59_lsp_more, t_59_langs_tests, t_59_ai_more, t_59_dap, t_510_large, t_510_debug_tools, t_510_testament, t_510_repl, t_510_nimble_outdated, t_510_merge_editor, t_510_spell, t_510_coverage, t_510_langs, t_510_mcp_more, t_510_emmet_css, t_510_sync, t_510_keymaps, t_510_accessible, t_510_workspace, t_510_remote, t_511_stale_errors, t_511_embedded, t_512_c_interop, t_512_refs_big, t_512_comp_stale, t_513_emit_edit, t_513_emit_errors, t_513_emit_c, t_514_emit_clangd, t_515_emit_more, t_515_strings, t_516_quickfixes, t_516_ai_fix, t_517_remote_git, t_517_workspace_git, t_518_macros, t_518_terminal, t_519_refactor, t_519_lists, t_520_agent_check, t_520_ai_tests, t_521_remote, t_521_git, t_521_format_self, t_522_perf, t_523_include, t_523_typehints, t_523_charlit, t_524_debug, t_524_format, t_524_deps, t_525_hints, t_525_engine, t_525_csv, t_525_profile, t_525_macro_nested, t_526_typing_errors, t_527_expand, t_527_complete, t_527_hover, t_528_hierarchy, t_528_refs, t_528_actions, t_529_clangd_fixes, t_529_examples, t_60_includes, t_60_protect, t_61_semantic, t_63_marks, t_63_git, t_63_format, t_63_paste, t_63_cdocs, t_64_engine, t_65_cengine, t_65_ligatures, t_66_cwrap, t_66_zen_menu, t_66_align_hints, t_66_trust, t_66_postfix, t_66_copies, t_66_test_on_save, t_66_ctvalues, t_66_include_check, t_67_github_signin, t_67_git_undo, t_67_commit_checks, t_67_review_comments, t_67_ai_grounded, t_67_ai_fix_test, t_67_format_changed, t_67_format_preview, t_67_yaml_toml, t_67_termux_clock, t_67_rich_colors, t_67_theme_editor, t_67_two_servers, t_67_lsp_links, t_67_ai_plan, t_67_ai_offline, t_68_nedfmt, t_68_engine_checks, t_68_compiler_answers, t_68_macro_names]
