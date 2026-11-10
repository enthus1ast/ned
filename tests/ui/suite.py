"""ned's UI tests: every feature driven through tmux, the screen read back. Run them with run.py."""
import shlex, subprocess, time, os, shutil, json, sys, re
# the helpers live in this module's namespace (a test can point W elsewhere for a while)
exec(compile(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'harness.py')).read(), 'harness.py', 'exec'))

# ── tests ──
def t_edit_save_undo():
    setup(); start('src/demo/utils.nim')
    mode0 = os.stat(os.path.join(W, 'src/demo/utils.nim')).st_mode & 0o777
    keys('C-End'); keys('Enter'); text('proc thrice*(x: int): int = x * 3'); keys('C-s')
    wait_until(lambda: 'thrice' in ftext('src/demo/utils.nim'), 5)      # (the first test: ned may be slow to start)
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
    # :vs splits the editor side by side, :only goes back to one pane (6.24; it used to say "one editor pane")
    bars = screen().count('│')
    text(':vs'); keys('Enter'); time.sleep(0.5)
    s = screen()
    check('624 vim :vs splits the editor', s.count('│') > bars + 20 and 'one editor pane' not in s, s[:400])
    text(':only'); keys('Enter'); time.sleep(0.5)
    check('624 vim :only closes the split', screen().count('│') <= bars + 2, screen()[:400])

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
    check('612 the call stack names procs as Nim does', 'dbg.main' in s and '_ZN' not in s, s[-1500:])
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
    if "alt+z runs" in screen(): keys('y'); time.sleep(0.5)      # (6.19: Alt+Z is zen mode's — asked first)
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
    palette('Nim: add the missing case branches'); wait_for('of blue:', 8)
    keys('C-s'); wait_until(lambda: 'of blue:' in ftext('src/cs.nim'), 8)
    t = ftext('src/cs.nim')
    check('missing case branches added', 'of green:' in t and 'of blue:' in t and t.count('of red') == 1, repr(t))
    tm('kill-server'); time.sleep(0.3)
    start('src/gen.nim')
    keys('C-g'); text('2'); keys('Enter'); time.sleep(0.2)
    palette('Nim: generate $'); wait_for(r'proc `\$`', 8)
    keys('C-s'); wait_until(lambda: 'proc hash*' in ftext('src/gen.nim'), 8)
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
    keys('C-g'); text('2:9'); keys('Enter', 'S-End', 'M-h')
    check('type of the selection', wait_for(r'"a" & "b": string', 8), screen()[:1200])

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
    # c in the Git dock: the message box, as its Commit… row says (6.24)
    keys('M-g'); time.sleep(1.2); keys('c'); time.sleep(0.8)
    s = screen()
    check('624 git dock: c opens the commit message box', 'Write the message above' in s, s)
    keys('C-w'); time.sleep(0.4)
    if 'unsaved' in screen().lower() or '(y/n)' in screen(): keys('n'); time.sleep(0.3)
    keys('Escape'); time.sleep(0.2)
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
    check('513 C error in an emit: shown on the Nim line, with the C file named', ok and re.search(r'4 .*return x \* 2 \+;.*C: expected expression.*@me\.nim\.c:\d+', screen()), screen())
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
    # (6.11: the servers start one after another, when you pause: each in turn)
    check('515 SQL in a sql"…" string: its syntax error', wait_for(r'18 .*SQL: Expected', 25), screen())
    check('515 the multi-line SQL string is fine', not re.search(r'2[0-3] .*SQL:', screen()), screen())
    check('515 JSON in parseJson: its error', wait_for(r'25 .*JSON: Value expected', 25), screen())
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
    # (all three found before the quick fixes are asked for: the engine's and the compiler's come at their own pace)
    keys('C-o'); time.sleep(0.4); text('b.nim'); keys('Enter'); time.sleep(1); keys('C-s')
    wait_for(r'(?s)(has to be used.*){3}', 30)
    keys('C-g'); text('2'); keys('Enter'); keys('M-Enter')
    ok = wait_for('Fix all 3 like this', 8)
    check('516 "fix all like this in the file"', ok, screen())
    if ok:
        text('Fix all'); time.sleep(0.3); keys('Enter'); time.sleep(0.5); keys('C-s'); time.sleep(0.5)
        check('516 … every one fixed', open(W + '/b.nim').read().count('discard one()') == 3, open(W + '/b.nim').read())
    # a deprecated name used twice: both changed at once
    # (the problems themselves, both: the pragma's own text says "deprecated" from the start)
    keys('C-o'); time.sleep(0.4); text('dep.nim'); keys('Enter'); time.sleep(1); keys('C-s')
    wait_for(r'(?s)(is deprecated.*){2}', 30); time.sleep(0.5)
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
    start('src/long.nim', w=120, h=16); time.sleep(1.0)
    check('571 no rulers by default', '\u258f' not in screen(), screen())
    palette('View: toggle rulers'); wait_for('\u258f', 3); time.sleep(0.3)
    s = screen()
    check('571 View › Rulers puts one at the line length (a Nim file: nim.format.lineLength, 88)',
          s.splitlines()[3].find('\u258f') == 94 and '"lineLength"' in open(CFG + '/ned/config.json').read(), s)
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
    # the ruler follows the formatter's line length; another language: 80
    setup({"editor.rulers": ["lineLength"], "nim.format.lineLength": 80})
    open(W + '/notes.txt', 'w').write('x\ny\n')
    start('src/long.nim', w=120, h=16); time.sleep(0.5)
    s = screen()
    check('571 "lineLength": the ruler moves with nim.format.lineLength (80)', s.splitlines()[3].find('\u258f') == 86, s)
    tm('kill-server'); time.sleep(0.3)
    setup({"editor.rulers": ["lineLength", 100], "nim.format.lineLength": 72})
    start('src/long.nim', w=120, h=16); time.sleep(0.5)
    s = screen()
    check('571 "lineLength" beside a fixed column', s.splitlines()[3].find('\u258f') == 78 and s.splitlines()[3].count('\u258f') == 2, s)
    tm('kill-server'); time.sleep(0.3)
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
    inim_dir = os.path.dirname(which('inim') or '')         # (found on the runner's PATH: ned's too)
    start('r.nim', w=130, h=44, path=TOOLS + (':' + inim_dir if inim_dir else '') + ':/usr/bin:/bin'); time.sleep(0.6)
    palette('REPL: send the whole file'); time.sleep(6)
    s = screen()
    if inim_dir: check('510 REPL: inim runs a Nim file', '42' in s.split('TERMINAL')[-1] and 'INim' in s, s)
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
    palette('Workspace: add a folder'); time.sleep(0.3); keys('C-u'); text(other); keys('Enter'); wait_for('work2', 8)
    s = screen()
    check('510 workspace: the tree shows both folders', 'work2' in s and 'work ' in s.split('\n')[2] or ('work2' in s and 'src' in s), s)
    keys('C-p'); time.sleep(0.3); text('helper'); wait_for('helper.nim work2/lib', 15)
    s = screen()
    check('510 workspace: quick open finds the other folder\'s files', 'helper.nim work2/lib' in s, s)
    keys('Enter'); wait_for('helperProc', 8)
    check('510 workspace: and opens them', 'helper.nim' in screen().split('\n')[1] and 'helperProc' in screen(), screen())
    keys('M-s'); time.sleep(0.3); keys('C-u'); text('helperProc'); keys('Enter'); wait_for(r'1 result|helperProc\*', 10)
    check('510 workspace: project search covers every folder', 'helper.nim' in screen() and '1 result' in screen() or 'helperProc*' in screen(), screen())
    keys('Escape')
    palette('Workspace: save as'); time.sleep(0.3); keys('Enter')
    wf = W + '/work.ned-workspace'
    ok = wait_until(lambda: len(json.load(open(wf))['folders']) == 2, 8)
    check('510 workspace: saved as a .ned-workspace file', ok, open(wf).read() if os.path.exists(wf) else 'none')
    tm('kill-server'); time.sleep(0.3)
    start('work.ned-workspace', w=130, h=36); wait_for('work2', 10)
    keys('C-p'); time.sleep(0.3); text('helper')
    check('510 workspace: opening the file brings both folders back', wait_for('helper.nim work2/lib', 12), screen())
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
        if nm == 'zsh': wait_for(r'zsh% ', 5)
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
        was = sh(G + 'rev-parse HEAD').stdout.strip()
        palette('Git: bisect — ' + ('bad' if bad else 'good'))
        # (the next commit checked out, or the answer: under load git takes a while)
        wait_until(lambda: sh(G + 'rev-parse HEAD').stdout.strip() != was or 'first bad commit' in screen(), 20)
        time.sleep(0.3)
        steps += 1
    s = screen()
    check('521 bisect by hand: it finds the commit', 'first bad commit' in s and ' c4' in s, s)
    keys('y')
    wait_until(lambda: sh(G + 'rev-parse --abbrev-ref HEAD').stdout.strip() == 'master', 15); time.sleep(0.5)
    head = sh(G + 'rev-parse --abbrev-ref HEAD').stdout.strip()
    check('521 bisect: stopped, back on the branch', head == 'master' and 'BISECTING' not in screen(), head + screen())
    # bisect with a command
    keys('Escape'); time.sleep(0.3)
    bisect_start('A command')
    keys('C-u'); text('! grep -q broken bug.txt'); keys('Enter')
    ok = wait_for('first bad commit is', 60)
    check('521 bisect with a command: it finds the commit', ok and ' c4' in screen(), screen())
    keys('y')
    wait_until(lambda: sh(G + 'rev-parse --abbrev-ref HEAD').stdout.strip() == 'master', 15)
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
    r = subprocess.run(('cd %s && ' + NIMBIN + '/nim check --hints:off big.nim 2>&1 | grep Error') % W,
                       shell=True, capture_output=True, text=True)
    errs = [l for l in r.stdout.split('\n') if l.strip()]
    check('521 format: … and still compiles', not errs and ftext('big.nim').count('\n') > 50000,
          '%d errors:\n%s' % (len(errs), '\n'.join(errs[:8])))
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
          '4.0.3 ✓' in rows.get('chronos', '') and '│   ├── results' in s and re.search(r'\d+\.\d+\.\d+ ✓', rows.get('nim', '')), s)
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
    palette('Nim: wrap a C header with c2nim'); time.sleep(0.8)
    text('mathx.h'); time.sleep(0.4); keys('Enter')
    if which('c2nim'): check('512 c2nim wraps the header', wait_for('Wrapped mathx.h', 20), screen()[-400:])
    out = open(W + '/mathx.nim').read() if os.path.exists(W + '/mathx.nim') else ''
    if which('c2nim'): check('512 the wrapper has the procs, importc and header', 'proc mx_add*' in out and 'header: "mathx.h"' in out, out[:300])
    # without c2nim or futhark: an offer to install
    prep()
    start('wrap.nim', w=150, h=40, path=no_nim_dir() + ':/usr/bin:/bin')     # (nim, and no c2nim or futhark)
    # (6.27: "Nim: wrap a C header…" is ned's own wrapper; c2nim has a command of its own)
    palette('Nim: wrap a C header with c2nim'); time.sleep(0.8); text('mathx.h'); time.sleep(0.4); keys('Enter'); time.sleep(3)
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
          'for i: range 0..1(int), p: Person in people' in s and 'let lg2: int = if' in s and 'mask: BiggestUInt = BiggestUInt 1' in s and
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
    def in_tab():
        keys('C-p'); text('>Nim: expand macro/template in a tab'); time.sleep(0.4); keys('Enter')
    keys('C-g'); text('10:9'); keys('Enter'); in_tab()
    ok = wait_for(r'expand: sq', 5)
    check('527 a template written out at once: sq(3 + 1) → (3 + 1) * (3 + 1)', ok and '(3 + 1) * (3 + 1)' in screen(), screen())
    keys('C-w'); time.sleep(0.4)
    keys('C-g'); text('11:4'); keys('Enter'); in_tab()
    ok = wait_for(r'expand: withLog', 5)
    s = screen()
    check('527 … with its block: the body in its place', ok and 'echo "start ", "job"' in s and
          re.search(r'echo "working"\s*\n.*echo "done"\s*\n.*echo "end ", "job"', s) is not None, s)
    keys('C-w'); time.sleep(0.4)
    keys('C-g'); text('14:4'); keys('Enter'); in_tab()
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

def t_6112_examples_after_format():
    # the ▶ saves the file first; format on save wraps the doc comment above the block into two lines, which moves
    # the block down one line — the ▶ still runs it (it used to find nothing on its old line, and showed nothing)
    setup({"nim.nimsuggest": None, "editor.formatOnSave": True, "nim.format.reflowDocComments": True,
           "nim.format.lineLength": 80})
    open(W + '/src/it.nim', 'w').write(
        'proc shout*(s: string): string =\n'
        '  ## Shouts the string back at you, with an exclamation mark added at the very end of it so it is louder.\n'
        '  runnableExamples:\n    echo "hello test"\n    echo shout("hi")\n  s & "!"\n')
    start('src/it.nim', w=120, h=30); time.sleep(1.5)
    keys('C-g'); text('6'); keys('Enter', 'End'); text(' '); keys('BSpace')     # an unsaved edit (and back)
    time.sleep(0.4)
    s = screen()
    rows = [i for i, l in enumerate(s.split('\n')) if 'runnableExamples' in l]
    col = s.split('\n')[rows[0]].find('▶') if rows else -1
    check('6112 runnableExamples: ▶ beside the block', col >= 0, s)
    if col < 0: return
    click(col + 1, rows[0] + 1)
    ok = wait_for(r'pass — their output', 60)
    s = screen()
    check('6112 … the save wraps the comment above (the block moves down) and the ▶ still runs it',
          ok and '│ hi!' in s and '## end of it so it is louder.' in ftext('src/it.nim'), s)

def t_6112_long_line():
    # a very long line: the cursor's column and the text around it come from marks along the line (not counted from
    # its start each frame) — they must say what counting says, wide characters included
    setup({"nim.nimsuggest": None})
    open(W + '/src/long.txt', 'w').write('abc中 ' * 50000 + 'THE-END\nsecond line\n')
    start('src/long.txt', w=120, h=30); time.sleep(1)
    keys('End'); time.sleep(0.5)
    s = screen()
    check('6112 a 350 KB line: End shows its end, and the column counts the wide characters twice',
          'THE-END' in s and 'Col 300008' in s, s)
    keys('Left', 'Left', 'Left', 'Left', 'Left', 'Left', 'Left', 'Left'); time.sleep(0.3)
    s = screen()
    check('6112 … moving left from there: the column follows (a wide character is two columns)',
          'Col 300000' in s, s)
    keys('Home'); time.sleep(0.3)
    s = screen()
    check('6112 … and Home goes back to the start', 'Col 1' in s and 'abc中 abc中' in s, s)

def t_6112_terminal_flood():
    # a flood of output with a long scrollback: the oldest lines are dropped a chunk at a time (it used to shift the
    # whole scrollback for every line: 200 000 lines took 6 s with 20 000 kept); what is kept is still in order
    setup({"terminal.shell": "/bin/bash", "terminal.scrollback": 20000})
    start('src/demo.nim', w=120, h=30)
    keys('C-\\'); time.sleep(1.2)
    text('clear; time seq 1 200000'); keys('Enter')
    ok = wait_for(r'real\s+\d+m[\d.]+s', 60)
    s = screen()
    m = re.search(r'real\s+(\d+)m([\d.]+)s', s)
    took = int(m.group(1)) * 60 + float(m.group(2)) if m else 99
    check('6112 terminal: 200 000 lines with 20 000 kept in well under 2 s (was 6 s): %.2f s' % took,
          ok and took < 2.0, s)
    keys('S-PageUp'); time.sleep(0.4)
    s = screen()
    sb = re.search(r'scrollback (\d+)/(\d+)', s)
    nums = [int(x) for x in re.findall(r'^\s*│?\s*(\d{6})\s*$', s, re.M)]
    check('6112 … the scrollback keeps at least the 20 000 lines asked for (and not many more), in order',
          sb is not None and 20000 <= int(sb.group(2)) <= 22600 and len(nums) > 5 and
          all(b == a + 1 for a, b in zip(nums, nums[1:])), s)
    keys('S-PageDown'); keys('C-d')

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
    # (the engine finds `tables` at once; `os` is the compiler's finding, a moment later — the test waits for both)
    keys('C-s'); ok = wait_for(r"imported and not used: 'os'", 25)
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
                                    '    type `name`* = object\n      width*: int\n    proc helperThing(): int = 1\n\n'
                                    'makeProcs(Foo, Bar)\nmakeType(Thing)\n')
    open(W + '/mm.nim', 'w').write('import gen\n\necho getBar()\nvar t: Thing\necho t.wi\necho getF\necho helperT\n')
    start('mm.nim', w=130, h=34); time.sleep(5)
    keys('C-g'); text('6'); keys('Enter', 'End', 'C-space')
    ok = wait_for(r'getFoo', 10)
    check('68 macro names: completion offers what an imported module\'s macro call makes', ok, screen())
    keys('Escape'); keys('C-g'); text('5'); keys('Enter', 'End', 'C-space')
    check('68 macro names: a field of a type a macro makes', wait_for(r'width', 6), screen())
    keys('Escape'); keys('C-g'); text('7'); keys('Enter', 'End', 'C-space'); time.sleep(1.5)
    check('68 macro names: a proc the macro writes without * is not offered in another module',
          'helperThing' not in screen(), screen())
    keys('Escape'); keys('C-g'); text('3:7'); keys('Enter', 'M-h')
    ok = wait_for(r'getBar\(\): string', 6)
    check('68 macro names: hover on the made proc, with the call that made it', ok and 'makeProcs(Foo, Bar)' in screen(), screen())
    keys('Escape'); keys('F12'); time.sleep(1.0)
    s = screen()
    check('68 macro names: Go to definition goes to the macro call', 'gen.nim' in s and re.search(r'Ln 16, Col 1\b', s) is not None, s)
    tm('kill-server'); time.sleep(0.3)
    setup({"nim.nimsuggest": False, "nim.compilerAnswers": False, "nim.macroNames": False})
    start('mm.nim', w=130, h=34); time.sleep(4)
    keys('C-g'); text('6'); keys('Enter', 'End', 'C-space'); time.sleep(2)
    check('68 macro names off: not offered', 'getFoo' not in screen(), screen())

def t_68_settings_panel():
    # every setting ned reads is in the Settings panel — the 6.8 ones too, found by name or by words of their text
    setup()
    start('src/demo.nim', w=130, h=40)
    for q, key in [('macroNames', 'nim.macroNames'), ('indexCache', 'nim.indexCache'), ('engineChecks', 'nim.engineChecks'),
                   ('compilerAnswers', 'nim.compilerAnswers'), ('format.verify', 'nim.format.verify'),
                   ('lineLength', 'nim.format.lineLength'), ('rulers', 'editor.rulers')]:
        palette('Settings'); time.sleep(0.4)
        text(q); time.sleep(0.5)
        s = screen()
        check('68 settings panel: ' + key, re.search(re.escape(key.split('.')[-1]), s, re.I) is not None, s[:1200])
        keys('Escape'); time.sleep(0.2)
    # (and none missing: each key the source reads has its entry — the unit-style check over the source)
    import glob as _g
    defs, used = set(), set()
    for f in _g.glob(REPO + '/src/**/*.nim', recursive=True):
        t = open(f).read()
        defs |= set(re.findall(r'defS\(\s*"[^"]*",\s*"([^"]+)"', t))
        used |= set(m[1] for m in re.findall(r'\b(sBool|sStr|sInt|sval|settingNode|setSetting)\(\s*"([A-Za-z0-9_.]+)"', t))
    missing = sorted(k for k in used if k not in defs and not k.endswith('.'))
    check('68 settings panel: every setting the source reads has an entry', not missing, repr(missing))

def t_69_locked_versions():
    # 6.9: the engine reads the dependency versions the project builds with: its nimble.lock pins the older of two
    # installed versions of a package — hover and Go to definition are the locked one's, the Nim dock says why
    setup({"nim.nimsuggest": False})
    nd = TMP + '/nimble69'
    shutil.rmtree(nd, ignore_errors=True)
    for ver, sha, word in [('1.0.0', 'a' * 40, 'old'), ('2.0.0', 'b' * 40, 'new')]:
        d = nd + '/pkgs2/vfoo-%s-%s' % (ver, sha)
        os.makedirs(d)
        open(d + '/vfoo.nimble', 'w').write('version = "%s"\n' % ver)
        open(d + '/vfoo.nim', 'w').write('proc lockedGreet*(): string =\n  ## vfoo %s says %s\n  "%s"\n' % (ver, word, word))
    open(W + '/demo.nimble', 'a').write('requires "vfoo"\n')
    json.dump({"version": 2, "packages": {"vfoo": {"version": "1.0.0", "vcsRevision": "x", "url": "https://example.com/vfoo",
               "downloadMethod": "git", "dependencies": [], "checksums": {"sha1": "a" * 40}}}, "tasks": {}},
              open(W + '/nimble.lock', 'w'))
    open(W + '/src/v69.nim', 'w').write('import vfoo\necho lockedGreet()\n')
    start('src/v69.nim', w=140, h=50, env_extra='NIMBLE_DIR=' + nd); time.sleep(1)
    keys('C-g'); text('2:7'); keys('Enter'); keys('M-h')
    ok = wait_for(r'vfoo 1\.0\.0 says old', 6)
    check('69 locked versions: hover shows the version nimble.lock pins (the older one)', ok and 'says new' not in screen(),
          screen())
    keys('Escape'); keys('F12'); time.sleep(1.0)
    s = screen()
    check('69 locked versions: Go to definition opens the locked version', 'vfoo.nim' in s and '"old"' in s and
          '"new"' not in s, s[:1500])
    keys('M-,'); time.sleep(0.5)                       # (back to the project's file: the dock shows its .nimble)
    keys('M-e'); ok = wait_for(r'1\.0\.0 \(nimble\.lock\)', 6)
    check('69 locked versions: the Nim dock shows the version and why (vfoo 1.0.0 (nimble.lock))', ok, screen())

def t_69_expected_type():
    # 6.9: completion where the code expects a type (a call's argument, `let x: T = `): the items of that type first,
    # the others still listed after them
    setup({"nim.nimsuggest": False})
    open(W + '/src/e69.nim', 'w').write(
        'type Color = enum cRed, cGreen, cBlue\n'
        'proc paint(c: Color, times: int) = discard\n'
        'proc main() =\n'
        '  let aTitle = "x"\n'
        '  let zCount = 3\n'
        '  let myShade = cGreen\n'
        '  \n')
    start('src/e69.nim', w=130, h=34); time.sleep(1.5)
    def row(word, below):
        """the screen row of `word` in the completion list (the rows under the line being written)"""
        ls = screen().split('\n')
        k = max([i for i, l in enumerate(ls) if below in l] or [len(ls)])
        for i, l in enumerate(ls[k + 1:]):
            if re.search(r'\b%s\b' % word, l): return i
        return -1
    keys('C-g'); text('7'); keys('Enter', 'End'); text('paint(myShade, '); keys('C-space')
    ok = wait_for(r'zCount\s+int', 4)
    m = 'paint(myShade, '
    check('69 expected type: an int argument — the int local first, before the others', ok and
          0 <= row('zCount', m) < row('aTitle', m) and row('zCount', m) < row('myShade', m), screen())
    keys('Escape'); keys('Home', 'S-End'); text('paint('); keys('C-space')
    ok = wait_for(r'cGreen', 4)
    m = 'paint('
    check('69 expected type: an enum argument — its values and the enum local first', ok and
          0 <= row('myShade', m) < row('aTitle', m) and 0 <= row('cBlue', m) < row('aTitle', m), screen())
    keys('Escape'); keys('Home', 'S-End'); text('let t: string = '); keys('C-space')
    ok = wait_for(r'aTitle\s+string', 4)
    m = 'let t: string ='
    check('69 expected type: let x: string = — the string local first', ok and
          0 <= row('aTitle', m) < row('myShade', m) and row('aTitle', m) < row('zCount', m), screen())

LAYOUT_SRC = '''type
  Rec = object
    flag: bool  # set once
    count: int
    small: int16
    big: float

var r = Rec(flag: true, count: 1, small: 2, big: 3.0)
echo r.count, " ", sizeof(Rec)
'''

def t_69_memory_layout():
    # 6.9: the hover of a type shows its memory layout — offsets, sizes, the padding after each field — and Alt+Enter
    # on its line sorts the fields by alignment when that saves bytes (comments move with their field); it compiles
    setup({"nim.nimsuggest": False})
    open(W + '/a.nim', 'w').write(LAYOUT_SRC)
    start('a.nim', w=120, h=36); time.sleep(1.5)
    keys('C-g'); text('2:4'); keys('Enter'); keys('M-h')
    ok = wait_for(r'Memory layout', 5)
    s = screen()
    check('69 layout: the hover of a type shows offsets, sizes and padding', ok and '32 bytes, align 8' in s and
          'flag: bool' in s and '+7 padding' in s and 'sorted by alignment: 24 bytes' in s, s)
    keys('Escape'); keys('C-g'); text('9:28'); keys('Enter'); keys('M-h')
    check('69 layout: … and where the type is used', wait_for(r'32 bytes, align 8', 5), screen())
    t, sc = qf_fix(2, 4, 'Reorder fields to save 8 bytes')
    check('69 layout: Alt+Enter reorders the fields, a comment with its field', t is not None and
          t.index('count: int') < t.index('big: float') < t.index('small: int16') < t.index('flag: bool') and
          'flag: bool  # set once' in t, sc)
    r = subprocess.run([shutil.which('nim', path=TOOLS) or 'nim', 'r', '--hints:off', '--nimcache:' + TMP + '/laycache',
                        W + '/a.nim'], capture_output=True, text=True, timeout=300)
    check('69 layout: the reordered file compiles, and the object is smaller', r.returncode == 0 and '1 24' in r.stdout,
          r.stdout + r.stderr)

RAISES_SRC = '''import std/strutils

proc load(s: string): int =
  result = parseInt(s)

proc safe(s: string): int =
  try:
    result = parseInt(s)
  except ValueError:
    result = 0

proc check(x: int) =
  if x < 0:
    raise newException(IOError, "negative")

echo load("1") + safe("x")
check(1)
'''

def t_69_raises_hints():
    # 6.9: nim.raisesHints — after the header of a routine without {.raises.}, what it can raise as the engine works
    # it out (not where a try catches it); the hover of a call says the same; off by default
    setup({"nim.nimsuggest": False, "nim.raisesHints": True})
    open(W + '/r.nim', 'w').write(RAISES_SRC)
    start('r.nim', w=120, h=36); time.sleep(2)
    ok = wait_for(r'raises: \[ValueError\]', 10)
    s = screen()
    check('69 raises hints: what a routine can raise, before the = of its header', ok and
          re.search(r'proc load\(s: string\): int \{\.raises: \[ValueError\]\.\} =', s) and
          re.search(r'proc check\(x: int\) \{\.raises: \[IOError\]\.\} =', s), s)
    check('69 raises hints: none where a try catches it', not re.search(r'proc safe.*raises', s), s)
    keys('C-g'); text('16:7'); keys('Enter'); keys('M-h')
    check('69 raises hints: the hover of a call says what it can raise', wait_for(r'can raise:.*ValueError', 5), screen())
    keys('Escape')
    # off (the default): no hints
    tm('kill-server'); time.sleep(0.3)
    c = json.load(open(CFG + '/ned/config.json'))
    c.pop("nim.raisesHints", None)
    json.dump(c, open(CFG + '/ned/config.json', 'w'))
    start('r.nim', w=120, h=36); time.sleep(2.5)
    s = screen()
    check('69 raises hints: off by default', 'proc load(s: string): int =' in s and 'raises:' not in s, s)

def t_69_engine_hints():
    # hints the compiler does not give, at once while typing: a var nothing changes (quick fix: let, and all of
    # them in the file), a parameter never used, a routine that never sets its result; a deprecated name from
    # another module (its replacement as the quick fix); a standard-library name and module newer than the Nim the
    # .nimble asks for — but not inside a `when` that asks which Nim this is
    setup({"nim.nimsuggest": False, "nim.liveDiagnosticsFrom": "nimsuggest"})
    nb = open(W + '/demo.nimble').read().replace('nim >= 2.0.0', 'nim >= 1.6.0')
    open(W + '/demo.nimble', 'w').write(nb)
    open(W + '/oldapi.nim', 'w').write('proc oldSum*(a, b: int): int {.deprecated: "use newSum instead".} = a + b\n'
                                       'proc newSum*(a, b: int): int = a + b\n')
    open(W + '/hints.nim', 'w').write('import std/[sequtils, paths]\nimport oldapi\n\n'
                                      'proc total(xs: seq[int], spare: int): int =\n  var sum = 0\n'
                                      '  for x in xs: sum += x\n  var limit = 10\n  var cap = 3\n'
                                      '  echo limit, cap\n  result = sum\n\n'
                                      'proc pick(a: int): int =\n  if a > 1:\n    echo "big"\n\n'
                                      'proc main() =\n  let xs = @[1, 2, 3]\n  echo total(xs, 0), pick(2)\n'
                                      '  echo oldSum(1, 2)\n  echo minmax(xs)\n  when NimMajor >= 2:\n'
                                      '    echo minmax(xs)\n  echo Path("a")\n\nmain()\n')
    start('hints.nim', w=150, h=40); time.sleep(1.5)
    keys('C-g'); text('26'); keys('Enter', 'End', 'Enter')          # (a change: the checks run)
    time.sleep(2)
    palette('Show problems')
    ok = wait_for(r"is never changed", 10)
    s = screen()
    check('69 engine hint: a var nothing changes can be a let', ok and "'limit' is never changed" in s and
          "'sum' is never changed" not in s, s)
    check("69 engine hint: a parameter never used", "parameter 'spare' is never used" in s, s)
    check("69 engine hint: a routine that never sets its result", "'pick' never sets its result" in s, s)
    check("69 engine: a deprecated name from another module, in the compiler's words",
          'use newSum instead; oldSum is deprecated' in s, s)
    check("69 engine: a library name newer than the package's Nim",
          "'minmax' is not in Nim 1.6.20 or older (Nim 2.0.0 has it)" in s and 'requires "nim >= 1.6.0"' in s, s)
    check("69 engine: a library module newer than the package's Nim", 'module paths is not in Nim 1.6.20' in s, s)
    check("69 engine: nothing inside `when NimMajor >= 2`", "[20:8]" in s and "[22:" not in s, s)
    keys('Escape')
    # the quick fixes: var → let (one, then all in the file), the deprecated name's replacement
    keys('C-g'); text('7:7'); keys('Enter', 'M-Enter')
    ok = wait_for(r'Make limit a let', 4)
    s = screen()
    check('69 quick fix: var → let offered, and all of them in the file', ok and 'Fix all 2 like this' in s, s)
    keys('Enter'); time.sleep(0.5)
    keys('C-s'); time.sleep(0.8)
    t = ftext('hints.nim')
    check('69 quick fix: var → let applies', 'let limit = 10' in t and 'var cap = 3' in t, t)
    keys('C-g'); text('19:8'); keys('Enter', 'M-Enter')
    ok = wait_for(r'Use newSum instead of oldSum', 4)
    keys('Enter'); time.sleep(0.5)
    keys('C-s'); time.sleep(0.8)
    check('69 quick fix: the deprecated name replaced', ok and 'echo newSum(1, 2)' in ftext('hints.nim'), screen())
    # nim.minVersion "off": no version marks
    tm('kill-server'); time.sleep(0.3)
    setup({"nim.nimsuggest": False, "nim.liveDiagnosticsFrom": "nimsuggest", "nim.minVersion": "off"})
    open(W + '/demo.nimble', 'w').write(nb)
    open(W + '/v.nim', 'w').write('import std/sequtils\n\necho minmax(@[1, 2])\n')
    start('v.nim', w=150, h=30); time.sleep(1.5)
    keys('C-g'); text('3'); keys('Enter', 'End', 'Enter'); time.sleep(3)
    check('69 nim.minVersion off: no version marks', 'is not in Nim' not in screen(), screen())

def t_69_shared_settings():
    # one source for the line length: nim.format.lineLength when a settings file says it, else the file's
    # .editorconfig max_line_length — the formatter, the ruler, nedfmt and ned --format alike; a file the
    # project's .nph.toml excludes is not formatted on save nor by "every file in the project"
    setup({"nim.nimsuggest": False, "editor.rulers": ["lineLength"]})
    open(W + '/.editorconfig', 'w').write('root = true\n\n[*.nim]\nmax_line_length = 60\n')
    long = ('proc area(width, height: int): int =\n  width * height\n\n'
            'echo area(width = 1234567, height = 7654321), area(width = 2, height = 3), area(1, 2)\n')
    open(W + '/w.nim', 'w').write(long)
    start('w.nim', w=130, h=30); time.sleep(1.2)
    s = screen()
    check('69 .editorconfig max_line_length: the ruler at 60 (nim.format.lineLength not set)',
          any(l.find('▏') == 66 for l in s.splitlines()[2:6]), s)
    keys('M-f'); time.sleep(1); keys('C-s'); time.sleep(0.6)
    t = ftext('w.nim')
    check('69 … and the formatter wraps at 60', max(len(l) for l in t.splitlines()) <= 60 and t != long, t)
    r = subprocess.run([BIN, '--format', '--check', W + '/w.nim'], capture_output=True, text=True)
    check('69 ned --format follows the .editorconfig too (the file is already as it wants)', r.returncode == 0,
          r.stdout + r.stderr)
    open(W + '/w2.nim', 'w').write(long)
    r = subprocess.run([BIN, '--format', '--out:' + W + '/w3.nim', W + '/w2.nim'], capture_output=True, text=True)
    check('69 ned --format FILE: the same layout as the editor', ftext('w3.nim') == t, ftext('w3.nim') + r.stderr)
    # a setting written in a settings file wins over the .editorconfig
    tm('kill-server'); time.sleep(0.3)
    setup({"nim.nimsuggest": False, "editor.rulers": ["lineLength"], "nim.format.lineLength": 100})
    open(W + '/.editorconfig', 'w').write('root = true\n\n[*.nim]\nmax_line_length = 60\n')
    open(W + '/w.nim', 'w').write(long)
    start('w.nim', w=130, h=30); time.sleep(1.2)
    keys('M-f'); time.sleep(1); keys('C-s'); time.sleep(0.6)
    check('69 nim.format.lineLength written: it wins (100: the line stays)', ftext('w.nim') == long,
          ftext('w.nim'))
    # .nph.toml excludes: no format on save, left out of the project's formatting
    tm('kill-server'); time.sleep(0.3)
    setup({"nim.nimsuggest": False, "editor.formatOnSave": True})
    open(W + '/.nph.toml', 'w').write('[tool.nph]\nextend-exclude = "generated/"\n')
    os.makedirs(W + '/generated', exist_ok=True)
    messy = 'proc  f( a:int ):int=a+1\necho   f(2)\n'
    open(W + '/generated/g.nim', 'w').write(messy)
    open(W + '/m.nim', 'w').write(messy)
    start('generated/g.nim', w=130, h=30); time.sleep(1.2)
    keys('End'); text(' '); keys('BSpace'); keys('C-s'); time.sleep(0.8)
    check('69 .nph.toml excludes a file: not formatted on save', ftext('generated/g.nim') == messy, ftext('generated/g.nim'))
    palette('Format: every file in the project'); time.sleep(0.5)
    ok = wait_for('would change', 30)
    s = screen()
    check('69 … and left out of "every file in the project"', ok and 'm.nim' in s and 'generated/g.nim' not in s, s)
    keys('Escape')

def t_69_toolchain():
    # one Nim per project (nim.toolchain): auto picks an installed Nim the .nimble asks for (PATH's does not do),
    # the status bar and the Nim dock say which; a requirement no installed Nim meets is a warning
    fake = TMP + '/toolchains'
    shutil.rmtree(fake, ignore_errors=True)
    d = fake + '/nim-9.1.0'
    os.makedirs(d + '/bin'); os.makedirs(d + '/lib/system')
    open(d + '/bin/nim', 'w').write('#!/bin/sh\necho "Nim Compiler Version 9.1.0 [Linux: amd64]"\n')
    os.chmod(d + '/bin/nim', 0o755)
    open(d + '/lib/system/compilation.nim', 'w').write('const\n  NimMajor* {.intdefine.}: int = 9\n'
                                                       '  NimMinor* {.intdefine.}: int = 1\n  NimPatch* {.intdefine.}: int = 0\n')
    setup({"nim.nimsuggest": False})
    nb = open(W + '/demo.nimble').read()
    open(W + '/demo.nimble', 'w').write(nb.replace('nim >= 2.0.0', 'nim >= 9.0'))
    start('src/demo.nim', w=150, h=34, env_extra='NED_NIM_TOOLCHAINS=' + fake); time.sleep(2)
    s = screen()
    check('69 nim.toolchain auto: the Nim the .nimble asks for (an installed one), in the status bar',
          'Nim 9.1.0' in s, s)
    palette('Toggle terminal'); time.sleep(1.5)
    text('nim --version'); keys('Enter'); time.sleep(1)
    check('69 … and every tool ned starts uses it (the terminal: nim --version)', 'Version 9.1.0' in screen(), screen())
    # nothing installed meets it: a warning, in the status bar too
    tm('kill-server'); time.sleep(0.3)
    setup({"nim.nimsuggest": False})
    open(W + '/demo.nimble', 'w').write(nb.replace('nim >= 2.0.0', 'nim >= 99.0'))
    start('src/demo.nim', w=150, h=34, env_extra='NED_NIM_TOOLCHAINS=' + fake); time.sleep(2)
    s = screen()
    check('69 a requirement no installed Nim meets: a warning in the status bar', 'needs nim >= 99.0' in s, s)
    palette('Nim: choose the Nim for this project'); time.sleep(0.6)
    s = screen()
    check('69 Nim › choose the Nim for this project: PATH\'s and the installed ones', 'Nim 9.1.0' in s and 'PATH' in s, s)
    keys('Escape')

def t_69_lint_and_ci():
    # ned --lint (the engine's checks, no compiler): plain lines, GitHub annotations, the exit status; Nim › add a
    # CI workflow writes .github/workflows/ci.yml (the Nims the .nimble allows; ned's lint when asked)
    setup({"nim.nimsuggest": False})
    open(W + '/src/l.nim', 'w').write('proc f(x: int): int =\n  if x > 1:\n    echo "big"\n\necho f(2)\n')
    r = subprocess.run([BIN, '--lint', W + '/src/l.nim'], capture_output=True, text=True, cwd=W)
    check('69 ned --lint: a problem as path:line:col, exit 1',
          r.returncode == 1 and "src/l.nim:1:6: warning: 'f' never sets its result" in r.stdout, r.stdout + r.stderr)
    r = subprocess.run([BIN, '--lint', '--format:github', 'src/l.nim'], capture_output=True, text=True, cwd=W)
    check('69 ned --lint --format:github: annotations', '::warning file=src/l.nim,line=1,col=6' in r.stdout, r.stdout)
    r = subprocess.run([BIN, '--lint', '--fail-on:error', 'src/l.nim'], capture_output=True, text=True, cwd=W)
    check('69 ned --lint --fail-on:error: warnings do not fail', r.returncode == 0, r.stdout + r.stderr)
    start('src/l.nim', w=150, h=34); time.sleep(1.2)
    palette('Nim: add a CI workflow'); time.sleep(0.6)
    check('69 Nim › add a CI workflow: what it runs, to choose', wait_for('Build and test', 4), screen())
    keys('Enter'); time.sleep(1)
    ci = ftext('.github/workflows/ci.yml') if os.path.exists(W + '/.github/workflows/ci.yml') else ''
    check('69 … ci.yml: the oldest Nim the .nimble allows and the newest, the tests',
          "nim: ['2.0.0', 'stable']" in ci and 'nimble test -y' in ci and 'nimble install -y --depsOnly' in ci, ci)
    # with ned's lint: the repository asked (a login in the link refused)
    os.remove(W + '/.github/workflows/ci.yml')
    palette('Nim: add a CI workflow'); time.sleep(0.6)
    keys('Down', 'Enter'); time.sleep(0.6)
    keys('C-u'); text('https://user:secret@example.com/x/ned'); keys('Enter'); time.sleep(0.6)
    check('69 … a link with a login in it is refused', not os.path.exists(W + '/.github/workflows/ci.yml'), screen())
    palette('Nim: add a CI workflow'); time.sleep(0.6)
    keys('Down', 'Enter'); time.sleep(0.6)
    keys('C-u'); text('https://example.com/x/ned'); keys('Enter'); time.sleep(1)
    ci = ftext('.github/workflows/ci.yml') if os.path.exists(W + '/.github/workflows/ci.yml') else ''
    check("69 … with ned's lint: built from the repository given, annotations on the pull request",
          'git clone --depth 1 https://example.com/x/ned' in ci and 'ned --lint --format:github .' in ci, ci)

def t_610_expected_multiline():
    # 6.10: completion ranked by the expected type also for an argument on a line of its own (the call started on a
    # line above) and for a parameter's default in a routine's header (here over two lines)
    setup({"nim.nimsuggest": False})
    open(W + '/src/e610.nim', 'w').write(
        'type Color = enum cRed, cGreen, cBlue\n'
        'proc paint(c: Color, times: int) = discard\n'
        'proc main() =\n'
        '  let aTitle = "x"\n'
        '  let zCount = 3\n'
        '  let myShade = cGreen\n'
        '  paint(myShade,\n'
        '        )\n'
        'proc wrap(a: int,\n'
        '          c: Color = ) = discard\n')
    start('src/e610.nim', w=130, h=34); time.sleep(1.5)
    def row(word, below):
        """the screen row of `word` in the completion list (the rows under the line being written)"""
        ls = screen().split('\n')
        k = max([i for i, l in enumerate(ls) if below in l] or [len(ls)])
        for i, l in enumerate(ls[k + 1:]):
            if re.search(r'\b%s\b' % word, l): return i
        return -1
    keys('C-g'); text('8:9'); keys('Enter'); keys('C-space')
    ok = wait_for(r'zCount\s+int', 4)
    m = 'paint(myShade,'
    check('610 expected type: an argument on a line of its own — the int local first, before the others', ok and
          0 <= row('zCount', m) < row('aTitle', m) and row('zCount', m) < row('myShade', m), screen())
    keys('Escape'); keys('C-g'); text('10:22'); keys('Enter'); keys('C-space')
    ok = wait_for(r'cBlue', 4)
    m = 'c: Color = )'
    check("610 expected type: a parameter's default in a header over two lines — the enum's values first", ok and
          0 <= row('cBlue', m) < row('main', m) and 0 <= row('cRed', m) < row('paint', m), screen())


def t_610_can_be_func():
    # 6.10: a proc with no side effects — it uses no module variable, calls nothing that has side effects, the
    # engine sure of every call — can be a func (an engine hint, rule can-be-func); quick fix: proc → func, and all
    # of them in the file
    setup({"nim.nimsuggest": False, "nim.liveDiagnosticsFrom": "nimsuggest"})
    open(W + '/fx.nim', 'w').write('var counter = 0\n\n'
                                   'proc add1(x: int): int =\n  x + 1\n\n'
                                   'proc bump() =\n  inc counter\n\n'
                                   'proc twice(x: int): int =\n  add1(add1(x))\n\n'
                                   'proc talk(x: int) =\n  echo twice(x)\n\n'
                                   'proc main() =\n  bump()\n  talk(3)\n\nmain()\n')
    start('fx.nim', w=150, h=40); time.sleep(1.5)
    keys('C-g'); text('20'); keys('Enter', 'End', 'Enter')          # (a change: the checks run)
    time.sleep(2)
    palette('Show problems')
    ok = wait_for(r"has no side effects", 10)
    s = screen()
    check('610 can be a func: a proc with no side effects', ok and "'add1' has no side effects: it can be a func" in s and
          "'twice' has no side effects" in s, s)
    check('610 can be a func: not one that uses a global, echoes, or calls one that does',
          "'bump' has no" not in s and "'talk' has no" not in s and "'main' has no" not in s, s)
    keys('Escape')
    keys('C-g'); text('3:6'); keys('Enter', 'M-Enter')
    ok = wait_for(r'Make add1 a func', 4)
    s = screen()
    check('610 quick fix: proc → func offered, and all of them in the file', ok and 'Fix all 2 like this' in s, s)
    keys('Down', 'Enter'); time.sleep(0.5)
    keys('C-s'); time.sleep(0.8)
    t = ftext('fx.nim')
    check('610 quick fix: every proc without side effects made a func', 'func add1(x: int): int =' in t and
          'func twice(x: int): int =' in t and 'proc bump() =' in t and 'proc talk(x: int) =' in t, t)

CONCEPT_SRC = """type
  Shape = concept
    proc area(s: Self): float
  Circle = object
    r: float
  Square = object
    side: float
  Line = object
    length: float

proc area(c: Circle): float = 3.14 * c.r * c.r
proc area(s: Square): float = s.side * s.side

let c = Circle(r: 1)
echo area(c), Line(length: 2).length
"""

def t_610_concepts():
    # 6.10: concepts — the hover of a concept lists the types that satisfy it, the hover of a type the concepts it
    # satisfies; Go to implementation on a concept: those types
    setup({"nim.nimsuggest": False})
    open(W + '/cpt.nim', 'w').write(CONCEPT_SRC)
    start('cpt.nim', w=130, h=36); time.sleep(1.5)
    keys('C-g'); text('2:4'); keys('Enter'); keys('M-h')
    ok = wait_for(r'satisfied by:', 5)
    s = screen()
    check('610 hover on a concept: the types that satisfy it', ok and re.search(r'satisfied by:.*Circle.*Square', s) and
          not re.search(r'satisfied by:.*Line', s), s)
    keys('Escape'); keys('C-g'); text('4:4'); keys('Enter'); keys('M-h')
    check('610 hover on a type: the concepts it satisfies', wait_for(r'satisfies:.*Shape', 5), screen())
    keys('Escape'); keys('C-g'); text('8:4'); keys('Enter'); keys('M-h')
    time.sleep(1.5)
    check("610 … not on one that does not", 'satisfies:' not in screen(), screen())
    keys('Escape'); keys('C-g'); text('2:4'); keys('Enter'); palette('Go to implementation')
    ok = wait_for(r'Implementations — Shape', 4)
    s = screen()
    ls = s.split('\n')
    top = max([i for i, l in enumerate(ls) if 'Implementations — Shape' in l] or [0])
    box = []
    for l in ls[top + 1:]:
        if l.lstrip().startswith('╰'): break
        a = l.find('│')
        b = l.find('│', a + 1) if a >= 0 else -1          # (the list's box only: the preview beside it is not)
        box.append(l[a:b] if b > a else (l[a:] if a >= 0 else l))
    box = '\n'.join(box)
    check('610 go to implementation on a concept: the types that satisfy it', ok and 'Circle' in box and
          'Square' in box and 'satisfies Shape' in box and 'Line' not in box, s)
    keys('Escape')

def t_610_nim_coverage():
    if not (which('gcov') or which('llvm-cov')): raise Skip('needs gcov (with gcc) or llvm-cov')
    import glob
    def numcol(raw, n):
        """the colour of line number n in the editor's gutter (the first row that starts with it)"""
        for l in raw.splitlines():
            fg, vis, first = None, '', None
            for m in re.finditer(r'\x1b\[([0-9;]*)m|([^\x1b])', l):
                if m.group(1) is not None:
                    c = re.search(r'(?:^|;)38;2;(\d+;\d+;\d+)', m.group(1))
                    if c: fg = c.group(1)
                    elif m.group(1) in ('', '0'): fg = None
                elif m.group(2):
                    vis += m.group(2)
                    if first is None and m.group(2).isdigit(): first = fg
            if re.match(r'\s*%d(\s|$)' % n, vis): return first
        return None
    def fnv(s):
        x = 2166136261
        for c in s.encode():
            x = ((x ^ c) * 16777619) & 0xffffffff
        return '%08x' % x
    def drop_cache():
        for t in [os.environ.get('TMPDIR') or '/tmp', None]:
            d = ('%s/ned-%d' % (t, os.getuid())) if t else STATE + '/ned/tmp'
            shutil.rmtree(d + '/ned_cov/work_' + fnv(W), ignore_errors=True)
    setup()
    open(W + '/src/demo/calc.nim', 'w').write(
        '## numbers\n'
        'proc classify*(x: int): string =\n'      # 2  ran
        '  if x > 5:\n'                            # 3  ran
        '    result = "big"\n'                     # 4  ran
        '  else:\n'                                # 5  no code
        '    result = "small"\n'                   # 6  never ran
        '\n'
        'proc neverCalled*(x: int): int =\n'       # 8  no test calls it: not in the C at all
        '  result = x * 2\n')                      # 9
    open(W + '/tests/tcalc.nim', 'w').write('import unittest\nimport demo/calc\n\ntest "classify":\n  check classify(10) == "big"\n')
    # (the kept builds of an earlier run of this test: gone, so the first run here builds everything)
    drop_cache()
    start('src/demo/calc.nim', w=150, h=42); time.sleep(0.6)
    t0 = time.time()
    palette('Test coverage: run and colour the lines that ran')
    ok = wait_for(r'Coverage: \d+% of \d+ lines ran \(\d+ files, 2 test files', 240)
    first = time.time() - t0
    raw = tm('capture-pane', '-t', 'f', '-e', '-p').stdout
    s = screen()
    check('610 nim coverage: the project\'s tests built with gcov, run, one result', ok, s[-1200:])
    ran, never, plain = numcol(raw, 4), numcol(raw, 6), numcol(raw, 7)
    check('610 nim coverage: a line that ran and one that never did (green, red)',
          ran and never and ran != never and numcol(raw, 2) == ran and numcol(raw, 3) == ran, raw[:3000])
    check('610 nim coverage: `else:` and blank lines hold no code (their own colour)',
          numcol(raw, 5) == plain and plain not in (ran, never), raw[:3000])
    check('610 nim coverage: a proc no test calls is red (Nim leaves it out of the C)',
          numcol(raw, 8) == never and numcol(raw, 9) == never, raw[:3000])
    check('610 nim coverage: the summary by file — the project\'s files, not the tests', 'COVERAGE' in s and
          re.search(r'50%\s+3/6\s+src/demo/calc\.nim', s) and re.search(r'100%\s+2/2\s+src/demo\.nim', s) and
          'neverCalled (line 8)' in s and 'tests/tcalc.nim' not in s and 'test_demo' not in s.split('COVERAGE')[-1], s)
    check('610 nim coverage: the procs of a module the tests import but never call count too',
          re.search(r'0%\s+0/\d+\s+src/demo/utils\.nim', s) and 'shout' in s, s)
    # again: the C build is kept, only the tests run
    exe = glob.glob('%s/ned-%d/ned_cov/work_%s/tcalc_*/tcalc' % (os.environ.get('TMPDIR') or '/tmp', os.getuid(), fnv(W))) + \
          glob.glob(STATE + '/ned/tmp/ned_cov/work_%s/tcalc_*/tcalc' % fnv(W))
    m0 = os.stat(exe[0]).st_mtime if exe else 0
    keys('Escape'); time.sleep(0.3)
    t0 = time.time()
    palette('Test coverage: run and colour the lines that ran')
    ok = wait_for(r'Coverage: \d+% of \d+ lines ran \(\d+ files, 2 test files', 120) and \
         wait_for(r'50%\s+3/6\s+src/demo/calc\.nim', 10)
    again = time.time() - t0
    check('610 nim coverage: run again, the kept C build (not linked again) (%.1fs, then %.1fs)' % (first, again),
          ok and exe and os.stat(exe[0]).st_mtime == m0 and again < first, screen()[-800:])
    # one test file, from the test explorer (c on its row)
    keys('Escape'); palette('Test explorer'); time.sleep(0.8)
    keys('Home'); keys('c')
    ok = wait_for(r'Coverage: \d+% of \d+ lines ran \(\d+ files?, t(calc|est_demo)\.nim', 120)
    check('610 nim coverage: one test file from the test explorer', ok, screen()[-1200:])
    # clang (Termux's compiler): coverage, or a clear word on what is missing
    if which('clang') and which('llvm-cov') and which('llvm-profdata'):
        setup({"nim.extraFlags": "--cc:clang"})
        open(W + '/src/demo/calc.nim', 'w').write('proc classify*(x: int): string =\n  if x > 5:\n    result = "big"\n'
                                                  '  else:\n    result = "small"\n')
        open(W + '/tests/tcalc.nim', 'w').write('import unittest\nimport demo/calc\n\ntest "c":\n  check classify(10) == "big"\n')
        start('tests/tcalc.nim', w=150, h=42); time.sleep(0.6)
        palette('Test coverage: this Nim test file')
        ok = wait_for(r'Coverage: \d+% of|libclang_rt\.profile\) is missing', 180)
        s = screen()
        check('610 nim coverage: clang (source-based) — counted, or says what is missing', ok and
              (re.search(r'75%\s+3/4\s+src/demo/calc\.nim', s) or 'pkg install libcompiler-rt' in s), s[-1500:])
    # a folder you have not trusted: none of its code runs (the compiler would run its config.nims, then the tests)
    setup({"security.folderTrust": "ask"})
    drop_cache()
    open(W + '/tests/config.nims', 'a').write('writeFile("%s/PWNED", "ran")\n' % W)
    start('tests/test_demo.nim', w=150, h=42); time.sleep(1)
    palette('Test coverage: this Nim test file'); time.sleep(4)
    cache = glob.glob('%s/ned-%d/ned_cov/work_%s' % (os.environ.get('TMPDIR') or '/tmp', os.getuid(), fnv(W)))
    check('610 nim coverage: nothing runs in a folder you have not trusted', not os.path.exists(W + '/PWNED') and
          not cache and not re.search(r'Coverage: \d+%|Coverage: building', screen()), screen()[-1200:])
    drop_cache()                                                  # (the kept builds of this test's folder)

def t_610_lint_rules():
    # rules: each of ned's checks has one; a quick fix silences it on a line (# ned: ignore[rule]) or turns it off
    # for the project (.ned/lint.json) — the editor, ned --lint and nedls alike
    setup({"nim.nimsuggest": False, "nim.liveDiagnosticsFrom": "nimsuggest"})
    open(W + '/src/r.nim', 'w').write('proc total(xs: seq[int], spare: int): int =\n  var limit = 10\n'
                                      '  var cap = 3\n  echo limit, cap\n  result = xs.len\n\necho total(@[1], 0)\n')
    start('src/r.nim', w=140, h=34); time.sleep(1.5)
    keys('C-g'); text('7'); keys('Enter', 'End', 'Enter'); time.sleep(2)
    palette('Show problems'); ok = wait_for(r"'cap' is never changed", 10); s = screen()
    check('610 rules: the hints as before', ok and "parameter 'spare' is never used" in s, s)
    keys('Escape')
    keys('C-g'); text('3:7'); keys('Enter', 'M-Enter')
    ok = wait_for(r'Silence var-let on this line', 4)
    check('610 quick fix: silence the rule on this line, or turn it off for the project',
          ok and 'Turn off var-let for this project' in screen(), screen())
    text('Silence'); wait_for(r'› Silence', 3); time.sleep(0.4); keys('Enter'); time.sleep(0.5); keys('C-s'); time.sleep(1.5)
    check('610 … # ned: ignore[var-let] added', '  var cap = 3  # ned: ignore[var-let]' in ftext('src/r.nim'), ftext('src/r.nim'))
    keys('C-g'); text('1:26'); keys('Enter', 'M-Enter'); time.sleep(0.6)
    ok = wait_for(r'Turn off unused-param for this project', 4)
    text('Turn off'); wait_for(r'› Turn off', 3); time.sleep(0.4); keys('Enter')
    for _ in range(20):
        if os.path.exists(W + '/.ned/lint.json'): break
        time.sleep(0.2)
    j = ftext('.ned/lint.json') if os.path.exists(W + '/.ned/lint.json') else ''
    check('610 … the rule off in .ned/lint.json', ok and '"unused-param": "off"' in j, j + screen())
    keys('End'); text(' '); keys('BSpace'); time.sleep(2)
    palette('Show problems'); time.sleep(1); s = screen()
    check("610 … and the problems follow: 'limit' still, not 'cap', not 'spare'",
          "'limit' is never changed" in s and "'cap' is never changed" not in s and "'spare'" not in s, s)
    keys('Escape')
    # ned --lint: rule ids, --fix and --diff, SARIF, lint.json's exclude, a .nimble's problems
    os.makedirs(W + '/src/gen', exist_ok=True)
    open(W + '/src/gen/g.nim', 'w').write('proc g(a: int): int =\n  var b = a\n  result = b\n')
    open(W + '/.ned/lint.json', 'w').write('{"rules": {"var-let": "warning"}, "exclude": ["src/gen/"]}\n')
    r = subprocess.run([BIN, '--lint', 'src/r.nim', 'src/gen/g.nim'], capture_output=True, text=True, cwd=W)
    check('610 ned --lint: [rule] after each problem, .ned/lint.json\'s severity and exclude',
          "src/r.nim:2:7: warning: 'limit' is never changed: it can be a let [var-let]" in r.stdout and
          'g.nim' not in r.stdout and 'left out by .ned/lint.json' in r.stderr, r.stdout + r.stderr)
    r = subprocess.run([BIN, '--lint', '--fix', '--diff', 'src/r.nim'], capture_output=True, text=True, cwd=W)
    check('610 ned --lint --fix --diff: the change shown, nothing written',
          '+  let limit = 10' in r.stdout and 'var limit = 10' in ftext('src/r.nim'), r.stdout + r.stderr)
    r = subprocess.run([BIN, '--lint', '--fix', 'src/r.nim'], capture_output=True, text=True, cwd=W)
    check('610 ned --lint --fix: written, the silenced line left alone',
          'let limit = 10' in ftext('src/r.nim') and 'var cap = 3  # ned: ignore[var-let]' in ftext('src/r.nim') and
          '1 fixed' in r.stderr, ftext('src/r.nim') + r.stderr)
    open(W + '/src/r2.nim', 'w').write('proc f(): int =\n  var x = 1\n  result = x\n')
    r = subprocess.run([BIN, '--lint', '--format:sarif', 'src/r2.nim'], capture_output=True, text=True, cwd=W)
    try:
        sj = json.loads(r.stdout); res = sj['runs'][0]['results']
        ok = sj['version'] == '2.1.0' and res and res[0]['ruleId'] == 'var-let' and \
             res[0]['locations'][0]['physicalLocation']['artifactLocation']['uri'] == 'src/r2.nim'
    except Exception as e:
        ok = False
    check('610 ned --lint --format:sarif: SARIF 2.1.0 with the rule', ok, r.stdout[:600])
    nb = open(W + '/demo.nimble').read()
    open(W + '/demo.nimble', 'w').write(nb + 'requires "foo >> 1"\nrequires "foo"\n')
    r = subprocess.run([BIN, '--lint', 'demo.nimble'], capture_output=True, text=True, cwd=W)
    check('610 ned --lint: a .nimble\'s own problems', 'not a version nimble reads' in r.stdout and
          "'foo' is required twice" in r.stdout and 'no license' not in r.stdout, r.stdout + r.stderr)

def t_610_imports_required():
    # an installed package imported without the .nimble requiring it: marked, and a quick fix adds the line
    nd = TMP + '/fakenimble610'
    shutil.rmtree(nd, ignore_errors=True)
    pd = nd + '/pkgs2/tinypkg-1.2.0-' + 'b' * 40
    os.makedirs(pd)
    open(pd + '/tinypkg.nimble', 'w').write('version = "1.2.0"\nauthor = "t"\ndescription = "t"\nlicense = "MIT"\n')
    open(pd + '/tinypkg.nim', 'w').write('proc tiny*(): int = 1\n')
    setup({"nim.nimsuggest": False, "nim.liveDiagnosticsFrom": "nimsuggest"})
    open(W + '/src/uses.nim', 'w').write('import tinypkg\n\necho tiny()\n')
    start('src/uses.nim', w=140, h=34, env_extra='NIMBLE_DIR=' + nd); time.sleep(2)
    keys('C-g'); text('3'); keys('Enter', 'End', 'Enter'); time.sleep(2)
    ok = wait_for(r"'tinypkg' is imported but demo.nimble does not require it", 10)
    check('610 an import the .nimble does not require', ok, screen())
    keys('C-g'); text('1:8'); keys('Enter', 'M-Enter')
    ok = wait_for(r'Add requires "tinypkg" to demo.nimble', 4)
    keys('Enter'); time.sleep(0.8)
    palette('Save all'); time.sleep(0.8)
    check('610 … the quick fix adds the requirement (the version this project builds with)',
          ok and 'requires "tinypkg >= 1.2.0"' in ftext('demo.nimble'), ftext('demo.nimble') + screen())

def t_610_dep_tree_locked():
    # the dependency tree shows the version the build uses — nimble.lock's, older than the newest installed — and why,
    # and what that version requires in turn
    setup({"nim.nimsuggest": False})
    nd = TMP + '/nimble610t'
    shutil.rmtree(nd, ignore_errors=True)
    def pkg(name, ver, reqs, sha):
        d = nd + '/pkgs2/%s-%s-%s' % (name, ver, sha * 40)
        os.makedirs(d, exist_ok=True)
        open(d + '/%s.nimble' % name, 'w').write('version = "%s"\n' % ver +
                                                 ''.join('requires "%s"\n' % r for r in reqs))
    pkg('vfoo', '1.0.0', ['vbar >= 0.5'], 'a')
    pkg('vfoo', '2.0.0', [], 'b')
    pkg('vbar', '0.5.0', [], 'c')
    for f in os.listdir(W):
        if f.endswith('.nimble'): os.remove(W + '/' + f)
    open(W + '/app.nimble', 'w').write('version = "0.1.0"\nauthor = "Ann"\ndescription = "x"\nlicense = "MIT"\n'
                                       'requires "nim >= 2.0.0", "vfoo"\n')
    json.dump({"version": 2, "packages": {"vfoo": {"version": "1.0.0", "vcsRevision": "x", "url": "https://example.com/vfoo",
               "downloadMethod": "git", "dependencies": ["vbar"], "checksums": {"sha1": "a" * 40}},
               "vbar": {"version": "0.5.0", "vcsRevision": "y", "url": "https://example.com/vbar",
               "downloadMethod": "git", "dependencies": [], "checksums": {"sha1": "c" * 40}}}, "tasks": {}},
              open(W + '/nimble.lock', 'w'))
    start('app.nimble', w=130, h=40, env_extra='NIMBLE_DIR=' + nd); time.sleep(1.5)
    palette('Nimble: dependency tree'); time.sleep(1)
    s = screen()
    rows = {r.split('──')[-1].split()[0]: r for r in s.splitlines() if '──' in r}
    check('610 dependency tree: the locked version and why (vfoo 1.0.0 (nimble.lock), not 2.0.0)',
          '1.0.0 ✓' in rows.get('vfoo', '') and 'nimble.lock' in rows.get('vfoo', '') and '2.0.0' not in rows.get('vfoo', ''), s)
    check('610 … and what that version requires, under it', '│   └── vbar' in s or '    └── vbar' in s, s)

def t_610_project_checks():
    # ned --lint over a program's project: an exported routine nothing uses, a requirement nothing imports — and the
    # same answers when only some of its files are given (the others are read for what they use); a library's
    # exports are for others
    setup()
    for f in os.listdir(W):
        if f.endswith('.nimble'): os.remove(W + '/' + f)
    os.makedirs(W + '/src/pc', exist_ok=True)
    open(W + '/pc.nimble', 'w').write('version = "0.1.0"\nauthor = "A"\ndescription = "d"\nlicense = "MIT"\n'
                                      'srcDir = "src"\nbin = @["pc"]\nrequires "nim >= 2.0.0", "zzunusedpkg >= 1.0"\n')
    open(W + '/src/pc.nim', 'w').write('import pc/helper\n\nwhen isMainModule:\n  echo usedOne()\n')
    open(W + '/src/pc/helper.nim', 'w').write('proc usedOne*(): int = 1\nproc nobodyCalls*(): int = 2\n')
    r = subprocess.run([BIN, '--lint', '--severity:hint', '.'], capture_output=True, text=True, cwd=W)
    out = r.stdout
    check("610 project: an exported routine nothing in the program uses [unused-export]",
          "'nobodyCalls' is exported but nothing in the project uses it [unused-export]" in out and
          "'usedOne' is exported" not in out,
          out + r.stderr)
    check("610 project: a requirement nothing imports [require-unused]",
          "nothing in the project imports 'zzunusedpkg'" in out, out + r.stderr)
    r = subprocess.run([BIN, '--lint', '--severity:hint', 'pc.nimble', 'src/pc/helper.nim'], capture_output=True,
                       text=True, cwd=W)
    check("610 project: only some files given — the others read for what they use ('usedOne' is used in pc.nim)",
          "'nobodyCalls' is exported" in r.stdout and "'usedOne' is exported" not in r.stdout, r.stdout + r.stderr)
    open(W + '/pc.nimble', 'w').write('version = "0.1.0"\nauthor = "A"\ndescription = "d"\nlicense = "MIT"\n'
                                      'srcDir = "src"\nbinDir = "out"\nrequires "nim >= 2.0.0"\n')
    r = subprocess.run([BIN, '--lint', '--severity:hint', '.'], capture_output=True, text=True, cwd=W)
    check("610 project: a library (binDir is not bin) — its exports are for others", "unused-export" not in r.stdout,
          r.stdout + r.stderr)

def t_610_fmt_uses():
    # names used only inside fmt"…" / &"…" / a fmt"""…""" over several lines are uses: no "declared but not
    # used" or "never used" for them (the compiler says nothing either) — a local nothing uses still is one
    setup()
    open(W + '/f.nim', 'w').write(
        'import std/strformat\n'
        'proc a1(): string =\n  let who = "x"\n  result = fmt"{who} here"\n'
        'proc a2(): string =\n  let n = 3\n  result = &"{n} items"\n'
        'proc a3(n: int): string =\n  result = fmt"""\n  count: {n}\n  """\n'
        'proc a4(): string =\n  let unused = 1\n  result = "plain"\n'
        'echo a1(), a2(), a3(1), a4()\n')
    r = subprocess.run([BIN, '--lint', '--severity:hint', 'f.nim'], capture_output=True, text=True, cwd=W)
    out = r.stdout
    check("610 lint: names only a format string uses are used ({who}, {n}, a fmt over several lines)",
          "'who'" not in out and "'n'" not in out and "parameter 'n'" not in out, out + r.stderr)
    check("610 lint: … and a local nothing uses is still found", "'unused' is declared but not used" in out,
          out + r.stderr)

def t_612_hints_ahead():
    # type hints worked out a chunk at a time, ahead of the scrolling: what scrolls in has its hints at once,
    # scrolling back works nothing out again, and an edit gets the lines on screen right first
    setup({"nim.nimsuggest": False, "editor.autoHover": False})
    body = ''.join('proc p%d(n: int) =\n  let a%d = n * %d\n  let s%d = $n & "x"\n  echo a%d, s%d\n\n' %
                   (i, i, i, i, i, i) for i in range(120))
    open(W + '/many.nim', 'w').write(body)
    start('many.nim', w=110, h=30); time.sleep(0.5)
    ok = wait_for('let a0: int = n', 10)
    time.sleep(1.5)                                     # (a quiet moment: the chunks below are worked out)
    for _ in range(40):                                 # (a swipe: four screens down)
        tm('send-keys', '-t', 'f', '-l', '\x1b[<65;40;12M')
    time.sleep(0.12)
    s = screen()
    rows = [l for l in s.splitlines() if 'let a' in l]
    check('612 type hints: the lines that scrolled in have theirs at once', ok and len(rows) >= 3 and
          all(': int = n' in l for l in rows) and 'let a0' not in s, s)
    for _ in range(40):
        tm('send-keys', '-t', 'f', '-l', '\x1b[<64;40;12M')
    time.sleep(0.12)
    s = screen()
    check('612 type hints: back up, still there', 'let a0: int = n' in s and 'let s0: string = $n' in s, s)
    # an edit: the hints of the screen follow it
    keys('C-g'); text('2'); keys('Enter'); keys('End')
    for _ in range(5): keys('BSpace')
    text('2.5'); time.sleep(1.2)
    check('612 type hints: an edit, the line on screen follows', 'let a0: float = 2.5' in screen(), screen())

def t_612_reflow_comments():
    # nim.format.reflowComments: a long # comment of prose re-wrapped to the line length on Alt+F (with the ##
    # ones, reflowDocComments), commented-out code left as it is, a banner's rule cut to fit
    setup({"nim.nimsuggest": False, "nim.format.lineLength": 60, "nim.format.reflowComments": True,
           "nim.format.reflowDocComments": True})
    src = ('## A module whose documentation is a long line that goes past the line length here.\n'
           '# ── Section ───────────────────────────────────────────────────────────────────────\n'
           'proc p(x: int): int =\n'
           '  # The value is doubled here because the caller expects twice what it gave, always.\n'
           '  # let old = compute(x, x, x, x, x, x, x, x, x, x, x, x, x, x, x, x, x, x)\n'
           '  x * 2\n')
    open(W + '/src/rc.nim', 'w').write(src)
    start('src/rc.nim', w=120, h=30); time.sleep(0.5)
    keys('M-f'); seen = wait_for(r'Formatted', 5)
    keys('C-s'); time.sleep(0.6)
    t = ftext('src/rc.nim')
    check('612 reflow: a ## paragraph re-wrapped', seen and '## A module whose documentation is a long line that goes\n'
          '## past the line length here.\n' in t, repr(t))
    check('612 reflow: a # paragraph re-wrapped, in its routine',
          '  # The value is doubled here because the caller expects\n  # twice what it gave, always.\n' in t, repr(t))
    check('612 reflow: commented-out code as it was', '  # let old = compute(x, x, x, x, x, x, x' in t, repr(t))
    lines = t.split('\n')
    check('612 reflow: the banner cut to the line length', lines[2].startswith('# ── Section ──') and len(lines[2]) == 60,
          repr(lines[2]))

def t_611_terminal_scroll():
    # 6.11: scrolling moves what the terminal shows (a scroll region) and sends only the new lines — what is on the
    # screen afterwards is exactly what a full redraw draws, scrolling down, up, by the wheel and by the cursor
    setup({"nim.nimsuggest": False, "editor.autoHover": False})
    shutil.copy(FIX + '/showcase.nim', W + '/src/showcase.nim')
    start('src/showcase.nim', w=130, h=40); time.sleep(2)
    def cells(cap):
        """each row as (character, its colour unless it is a space, background, attributes): what one sees"""
        rows = []
        fg, bg, at = None, None, frozenset()     # (tmux's capture carries the colours over from the line above)
        for line in cap.split('\n'):
            row = []
            for m in re.finditer(r'\x1b\[([0-9;]*)m|([^\x1b])', line):
                if m.group(1) is not None:
                    ps = [int(x) if x else 0 for x in m.group(1).split(';')]
                    k = 0
                    while k < len(ps):
                        v = ps[k]
                        if v == 0: fg, bg, at = None, None, frozenset()
                        elif v in (38, 48) and k + 4 < len(ps) and ps[k + 1] == 2:
                            if v == 38: fg = tuple(ps[k + 2:k + 5])
                            else: bg = tuple(ps[k + 2:k + 5])
                            k += 4
                        elif v in (38, 48) and k + 2 < len(ps) and ps[k + 1] == 5:
                            if v == 38: fg = ps[k + 2]
                            else: bg = ps[k + 2]
                            k += 2
                        elif v == 39: fg = None
                        elif v == 49: bg = None
                        elif v in (1, 2, 3, 4, 7, 9): at = at | {v}
                        elif v in (22, 23, 24, 27, 29): at = at - {{22: 1, 23: 3, 24: 4, 27: 7, 29: 9}[v]} - ({2} if v == 22 else set())
                        k += 1
                else:
                    c = m.group(2)
                    shows = at & {4, 7, 9}
                    row.append((c, fg if c != ' ' or shows else None, bg, at if c != ' ' else frozenset(shows)))
            rows.append(row)
        return rows
    def same(label):
        time.sleep(0.6)
        a = tm('capture-pane', '-t', 'f', '-e', '-p').stdout
        ta0 = tm('capture-pane', '-t', 'f', '-p').stdout.splitlines()
        tm('send-keys', '-t', 'f', '-l', '\x1b[I'); time.sleep(0.8)      # (focus back: ned draws everything again)
        b = tm('capture-pane', '-t', 'f', '-e', '-p').stdout
        ca, cb = cells(a), cells(b)
        ta = tm('capture-pane', '-t', 'f', '-p').stdout.splitlines()       # (the text: exact)
        # (the colours as far as tmux shows each row: it leaves out blank cells at the end of a row)
        bad = [i for i, (x, y) in enumerate(zip(ca, cb)) if x[:min(len(x), len(y))] != y[:min(len(x), len(y))]]
        check('611 terminal scroll: ' + label + ' — the screen is what a full redraw draws',
              not bad and len(ca) == len(cb) and ta0 == ta,
              '\n'.join('row %d:\n  %s\n  %s' % (i, a.splitlines()[i][:300], b.splitlines()[i][:300]) for i in bad[:4]))
    for i in range(12):
        tm('send-keys', '-t', 'f', '-l', '\x1b[<65;60;20M'); time.sleep(0.05)
    same('the wheel, down')
    for i in range(5):
        tm('send-keys', '-t', 'f', '-l', '\x1b[<64;60;20M'); time.sleep(0.05)
    same('the wheel, up')
    keys('C-g'); text('120'); keys('Enter'); time.sleep(0.3)
    for i in range(25): keys('Down')
    same('the cursor going down past the bottom')
    for i in range(45): keys('Up')
    same('… and up past the top')
    keys('PageDown'); keys('PageDown')
    same('page down')

def t_611_frames_vt():
    # 6.11: every frame ned sends — scrolled by the terminal, colours only where they change, unchanged cells
    # stepped over — read by a plain VT100-style terminal model gives exactly the screen a full redraw gives, step
    # after step (cursor, wheel, page)
    import pty, select, struct, fcntl, termios
    sys.path.insert(0, HERE)
    from vt import VT
    setup({"nim.nimsuggest": False, "editor.autoHover": False, "ui.tooltips": False})
    shutil.copy(FIX + '/showcase.nim', W + '/src/showcase.nim')
    Wd, Hd = 130, 40
    env = dict(os.environ, TERM='xterm-256color', COLORTERM='truecolor', XDG_CONFIG_HOME=CFG, XDG_STATE_HOME=STATE)
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(W)
        os.execvpe(BIN, [BIN, 'src/showcase.nim'], env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', Hd, Wd, 0, 0))
    vt = VT(Wd, Hd)
    def drain(t):
        end = time.time() + t; got = b''
        while True:
            r, _, _ = select.select([fd], [], [], max(0, end - time.time()))
            if not r: break
            try: d = os.read(fd, 65536)
            except OSError: break
            got += d
            if b'\x1b[6n' in d: os.write(fd, b'\x1b[1;1R')
        vt.feed(got)
    def send(b, t): os.write(fd, b); drain(t)
    try:
        drain(4)
        send(b'\x07', 0.4)
        for ch in '120': send(ch.encode(), 0.05)
        send(b'\r', 0.5)
        send(b'\x1b[I', 0.8)
        seqs = {'up': b'\x1b[A', 'down': b'\x1b[B', 'wheel-down': b'\x1b[<65;60;20M', 'wheel-up': b'\x1b[<64;60;20M',
                'pgdn': b'\x1b[6~', 'pgup': b'\x1b[5~'}
        plan = ['down'] * 25 + ['up'] * 45 + ['wheel-down'] * 8 + ['wheel-up'] * 8 + ['pgdn'] * 3 + ['pgup'] * 2
        first_bad = None
        for step, k in enumerate(plan):
            send(seqs[k], 0.6)
            a = vt.visible()
            send(b'\x1b[I', 0.6)                        # (focus back: a full redraw)
            b = vt.visible()
            if a != b and first_bad is None:
                rows = [i for i, (x, y) in enumerate(zip(a, b)) if x != y]
                first_bad = '%d %s rows %s\n%s\n%s' % (step, k, rows[:6], ''.join(c[0] for c in a[rows[0]]),
                                                        ''.join(c[0] for c in b[rows[0]]))
        check('611 frames read by a terminal model: the same screen as a full redraw, %d steps' % len(plan),
              first_bad is None, first_bad)
    finally:
        os.write(fd, b'\x11'); time.sleep(0.3)
        try: os.kill(pid, 9)
        except OSError: pass

def t_611_perf_report():
    # 6.11: Help › Performance report — frames, what they send, the terminal's speed, rounds that kept ned busy,
    # what runs in the background, memory, what would make it lighter; NED_PERF_LOG writes it on the way out
    setup({"nim.nimsuggest": False})
    shutil.copy(FIX + '/showcase.nim', W + '/src/showcase.nim')
    log = TMP + '/perf.txt'
    if os.path.exists(log): os.remove(log)
    start('src/showcase.nim', w=130, h=40, env_extra='NED_PERF_LOG=' + log); time.sleep(1.5)
    for i in range(10):
        tm('send-keys', '-t', 'f', '-l', '\x1b[<65;60;20M'); time.sleep(0.05)
    time.sleep(0.5)
    palette('Performance report'); time.sleep(1)
    s = screen()
    check('611 performance report: frames, bytes, the terminal, busy rounds, background, memory',
          'made in' in s and 'bytes on average' in s and 'scrolled by the terminal' in s and
          'Answering keys and the mouse' in s and 'Running in the background' in s and 'Memory: ned' in s, s)
    keys('C-q'); time.sleep(1.0)
    for k in ('Escape', 'n', 'Enter'):
        if os.path.exists(log): break
        keys(k); time.sleep(0.6)
    t = open(log).read() if os.path.exists(log) else ''
    m = re.search(r'scrolled by the terminal \(only the new lines sent\): (\d+)', t)
    check('611 NED_PERF_LOG: the report on the way out, the wheel scrolls done by the terminal', m and int(m.group(1)) >= 3,
          t[:1500])

def t_612_nim3():
    # a Nim 3 project (nim.compiler: nimony): Nimony's library, names as written, errors from nimony check, go to
    # definition into Nimony's own library, Nim 3's pragmas completed
    need('nimony')
    setup({"nim.compiler": "nimony", "nim.nimsuggest": None})
    open(W + '/src/n3.nim', 'w').write('import std/syncio\n\nproc fooBar(x: int): int = x + 1\n\necho fooBar(1)\n'
                                       'echo foobar(2)\nlet s: int = "oops"\n')
    start('src/n3.nim', w=140, h=30); time.sleep(1)
    keys('C-g'); text('5:7'); keys('Enter'); text(' '); keys('BSpace')          # (an edit: the checks run)
    ok = wait_for(r'type mismatch', 30)
    found = wait_for(r"undeclared identifier: 'foobar'", 30)      # (under load nimony takes its time: both, waited for)
    s = screen()
    check('612 Nim 3: the status bar says so', 'Nim 3' in s, s)
    check('612 Nim 3: names are case-sensitive (foobar is not fooBar)', found, s)
    check('612 Nim 3: errors while typing come from nimony check', ok, s)
    keys('C-g'); text('5:1'); keys('Enter'); keys('F12'); time.sleep(1.2)
    s = screen()
    check("612 Nim 3: go to definition goes into Nimony's own library (echo in std/syncio)",
          'syncio.nim' in s and 'template echo' in s, s)
    keys('C-w'); time.sleep(0.4)
    keys('C-g'); text('3'); keys('Enter', 'End'); keys('BSpace', 'BSpace', 'BSpace', 'BSpace', 'BSpace')
    text(' {.pas'); keys('C-Space'); time.sleep(0.6)
    s = screen()
    check("612 Nim 3: Nimony's pragmas are completed, with what they do ({.passive.})", 'passive' in s and
          'continuation' in s, s)
    keys('Escape')
    check("612 Nim 3: nimony's build files are not left in the project (no nimcache/)",
          not os.path.exists(W + '/src/nimcache') and not os.path.exists(W + '/nimcache'), str(os.listdir(W + '/src')))

def t_612_nim3_port():
    # porting a Nim 2 file: what Nim 3 needs shown as problems (Nim › Nim 3: what this file needs), and fixed in one go
    setup({"nim.nimsuggest": None})
    open(W + '/src/old.nim', 'w').write(
        'type Color = enum red, green\n\ntemplate reset() = discard\n\n'
        'proc twice(x: SomeInteger): int = int(x) * 2\n\n'
        'proc load(path: string): string =\n  try:\n    result = readFile(path)\n  except IOError as e:\n'
        '    raise newException(ValueError, "cannot read " & path)\n\n'
        'type MyError = ref object of CatchableError\n\n'
        'proc safe() =\n  try: discard\n  except MyError as m: discard\n\n'
        'proc pick(n: ref int): bool =\n  for c in Color:\n    echo c\n  block search:\n    if n.isNil:\n      break\n'
        '  reset\n  true\n')
    start('src/old.nim', w=150, h=56); time.sleep(1.5)
    palette('Nim 3: what this file needs')
    time.sleep(2.5)
    s = screen()
    check('612 port: Nim 3 problems listed (except as, newException, enum loop, template call)',
          all(x in s for x in ['no `as e`', '`raise ValueError`', 'low(Color)..high(Color)', '`reset()`']), s)
    check("612 port: what today's nimony takes is not flagged (generics without [T], the project's own exception type)",
          '[T: SomeInteger]' not in s and 'no `as m`' not in s, s)
    keys('Escape')
    keys('C-g'); text('10'); keys('Enter'); keys('M-Enter')
    ok = wait_for('Fix all', 8)
    s = screen()
    check('612 port: the quick fixes offer the change, and all of them in the file', ok and 'Remove `as e`' in s, s)
    if ok:
        text('Fix all'); time.sleep(0.3); keys('Enter'); time.sleep(0.6)
    keys('C-s'); time.sleep(0.6)
    t = ftext('src/old.nim')
    check('612 port: fixed in one go — the file is what Nim 3 wants', 'proc twice(x: SomeInteger)' in t and
          'except MyError as m:' in t and 'except IOError:' in t and 'raise ValueError' in t and 'low(Color)..high(Color)' in t and
          'break search' in t and 'reset()' in t and 'n == nil' in t, t)

def t_612_hex():
    # a binary file in the hex editor: typed over (hex and text), undone, saved; inserted, deleted; found, gone to
    setup()
    open(W + '/data.bin', 'wb').write(bytes(range(256)) * 4)
    start('data.bin', w=120, h=32); time.sleep(1)
    s = screen()
    check('612 hex: a binary file opens in the hex editor (offset · hex · text, the data inspector)',
          re.search(r'00000040\s+40 41 42 43', s) is not None and '@ABCDEFG' in s and 'u16 256' in s, s)
    text('41'); text('4'); keys('Tab'); text('Z'); time.sleep(0.3)
    check('612 hex: typed over in hex, then in the text column (Tab)', re.search(r'00000000\s+41 5a 02', screen())
          is not None, screen())
    keys('C-z'); time.sleep(0.3)
    check('612 hex: undo', re.search(r'00000000\s+41 41 02', screen()) is not None, screen())
    keys('C-s'); time.sleep(0.5)
    d = open(W + '/data.bin', 'rb').read()
    check('612 hex: saved as bytes', d[:3] == b'\x41\x41\x02' and len(d) == 1024, repr(d[:8]))
    # (still in the text column: Insert, then two letters go in after the first byte; Delete takes the next one)
    keys('Insert'); text('ab'); keys('Delete'); time.sleep(0.2); keys('C-s'); time.sleep(0.5)
    d = open(W + '/data.bin', 'rb').read()
    check('612 hex: Insert adds bytes, Delete takes one away', len(d) == 1025 and d[:5] == b'\x41ab\x02\x03', repr(d[:8]))
    keys('C-f'); time.sleep(0.3); text('fe ff 00'); keys('Enter'); time.sleep(0.4)
    s = screen()
    check('612 hex: Ctrl+F finds bytes', re.search(r'Found at 0x0000\w+', s) is not None, s)
    keys('C-g'); time.sleep(0.3); text('0x300'); keys('Enter'); time.sleep(0.3)
    check('612 hex: Ctrl+G goes to an offset', '0x00000300 (768)' in screen(), screen())
    rows = screen().split('\n')
    r = [i for i, l in enumerate(rows) if l.startswith('00000300')]
    if r:
        click(10 + 2 * 3 + 1, r[0] + 1); time.sleep(0.3)       # (the third byte of that row)
        check('612 hex: a click puts the cursor on the byte clicked', '0x00000302 (770)' in screen(), screen())
        text('é'); time.sleep(0.4)                               # (found by the fuzzer: it stopped ned)
        check('612 hex: a letter beyond ASCII in the hex column is no hex digit', 'Hex digits here' in screen() and
              '0x00000302 (770)' in screen(), screen())

def t_612_hex_exe():
    # a program Nim built: what it is, its symbols by their Nim names (the biggest first), the bytes of one,
    # its Nim source; Nim's modules by size
    setup()
    open(W + '/app.nim', 'w').write('proc shout*(s: string): string = s & "!"\nproc `+`(a, b: int): int = a * b\n'
                                    'echo shout("hi"), 2 + 3\n')
    r = subprocess.run([NIMBIN + '/nim', 'c', '-d:release', '--hints:off', '--nimcache:' + TMP + '/hexnc',
                        '-o:' + W + '/app', W + '/app.nim'], capture_output=True, text=True)
    check('612 hex: a Nim program built for the test', r.returncode == 0, r.stdout + r.stderr)
    start('app', w=130, h=34); time.sleep(1.2)
    s = screen()
    check('612 hex: an ELF program, built with Nim', 'ELF' in s and 'executable' in s and 'Nim' in s, s)
    palette('Hex: symbols')
    time.sleep(0.8)
    text('shout'); time.sleep(0.5)
    s = screen()
    check('612 hex: symbols by their Nim names (shout of app)', 'shout  (app)' in s, s)
    keys('Enter'); time.sleep(0.5)
    s = screen()
    check("612 hex: picking it goes to its bytes (the header says which proc the cursor is in)", 'in shout (app)' in s, s)
    palette('Hex: open the Nim source')
    time.sleep(0.8)
    s = screen()
    check('612 hex: … and its Nim source opens', 'app.nim' in s and 'proc shout*' in s, s)

def t_612_big_text():
    # a text file of 8 MB or more is read straight into lines, a megabyte at a time: CRLF line ends, a line across
    # two megabytes, no line end at the end — and saved again byte for byte
    setup()
    lines = ['line %07d %s' % (i, 'x' * (i % 97)) for i in range(160000)]
    lines[5000] = 'L' * 2_500_000                       # (a line longer than a megabyte: across the reads)
    data = '\r\n'.join(lines) + '\r\nTHE LAST LINE'
    open(W + '/big.log', 'w', newline='').write(data)
    start('big.log', w=120, h=30); time.sleep(2)
    s = screen()
    check('612 big text: opened, CRLF seen', 'CRLF' in s and 'line 0000000' in s, s)
    keys('C-End'); time.sleep(0.5)
    s = screen()
    check('612 big text: the last line (no line end after it) is there', 'THE LAST LINE' in s and 'Ln 160001' in s, s)
    keys('C-g'); text('5002'); keys('Enter'); time.sleep(0.3)
    check('612 big text: the line after the long one', 'line 0005001' in screen(), screen())
    keys('C-g'); text('3'); keys('Enter', 'End'); text('!'); keys('BSpace'); keys('C-s'); time.sleep(1.5)
    check('612 big text: saved byte for byte as it was read', open(W + '/big.log', newline='').read() == data,
          'differs')

def raw_in(b):
    """bytes as if the terminal sent them (an answer to a question, a key in the kitty protocol)"""
    tm('send-keys', '-t', 'f', '-H', *['%02x' % x for x in b]); time.sleep(0.3)

def t_613_remote():
    # `ned FILE` in ned's own terminal opens FILE in this ned; git's editor there is this ned (it waits for the tab to
    # close); scripts: --remote-get, --remote-list, --remote-message, --remote-problems, --remote-command
    setup()
    open(W + '/a.txt', 'w').write('zeta\nalpha\nmid\n')
    open(W + '/b.txt', 'w').write('one\ntwo\nthree\n')
    subprocess.run('cd %s && git add a.txt b.txt' % W, shell=True, capture_output=True)
    start('a.txt', w=120, h=34, env_extra='GIT_EDITOR=')
    keys('C-\\'); time.sleep(1.5)
    text(BIN + ' b.txt:2'); keys('Enter')
    ok = wait_for(r'Ln 2, Col 1', 6)
    s = screen()
    check('613 remote: ned FILE in ned\'s terminal opens it in this ned (at its line)', ok and '• b.txt' in s and
          'ned: ' not in s, s)
    r = subprocess.run([BIN, '--remote-get', 'file'], capture_output=True, text=True, cwd=W)
    check('613 remote: --remote-get file', r.returncode == 0 and r.stdout.strip() == W + '/b.txt', repr((r.stdout, r.stderr)))
    r = subprocess.run([BIN, '--remote-list'], capture_output=True, text=True, cwd=W)
    check('613 remote: --remote-list names the project and its files', r.returncode == 0 and W in r.stdout and
          'b.txt' in r.stdout, repr((r.stdout, r.stderr)))
    r = subprocess.run([BIN, '--remote-message', 'build finished'], capture_output=True, text=True, cwd=W)
    check('613 remote: --remote-message shows there', r.returncode == 0 and wait_for('build finished', 3), screen())
    r = subprocess.run([BIN, '--remote-problems', 'mylint'], input='a.txt:2:1: error: no alpha here\nnot a location\n',
                       capture_output=True, text=True, cwd=W)
    time.sleep(0.5)
    check('613 remote: --remote-problems: file:line: lines become problems', r.returncode == 0 and
          r.stdout.strip() == '1 problem' and '● 1' in screen(), repr(r.stdout) + screen()[-300:])
    r = subprocess.run([BIN, '--remote-command', 'No such thing at all'], capture_output=True, text=True, cwd=W)
    check('613 remote: --remote-command with an unknown name says so', r.returncode == 1 and 'no command' in r.stderr,
          r.stderr)
    # git commit: the message in a tab; saved and closed, git goes on — and the terminal has the focus again
    keys('C-\\'); time.sleep(0.5)
    if 'TERMINAL' not in screen(): keys('C-\\'); time.sleep(0.5)
    tab = find_on_screen('TERMINAL')
    if tab: click(*tab)
    text('git -c user.name=t -c user.email=t@t commit'); keys('Enter')
    ok = wait_for('COMMIT_EDITMSG', 8)
    check('613 remote: git commit opens its message in a tab of this ned, and says git waits', ok and 'waits for it' in
          screen(), screen())
    text('a message from ned'); keys('C-s'); time.sleep(0.4); keys('C-w')
    ok = wait_for(r'\[master [0-9a-f]+\] a message from ned', 8)
    log = subprocess.run('cd %s && git log -1 --format=%%s' % W, shell=True, capture_output=True, text=True).stdout
    check('613 remote: … closed: git goes on and commits', ok and log.strip() == 'a message from ned', log + screen())
    text('echo back-in-the-terminal'); keys('Enter'); time.sleep(0.4)
    check('613 remote: … and the terminal has the focus again', 'back-in-the-terminal\n' in screen() or
          screen().count('back-in-the-terminal') >= 2, screen())
    text(BIN); keys('Enter'); time.sleep(0.8)
    check('613 remote: ned alone in ned\'s terminal tells how to open a file (and starts no second ned)',
          "this is ned's terminal" in screen(), screen())

def t_613_terminal_answers():
    # what the terminal answers: the kitty keyboard protocol (keys ned could not tell apart before), grapheme
    # clusters (mode 2027), light and dark (mode 2031), XTGETTCAP; the focus (save when it goes)
    setup({"keys": {"ctrl+shift+f": "New file", "ctrl+i": "Toggle soft wrap"}, "theme": "auto",
           "editor.saveOnFocusLost": True})
    open(W + '/e.txt', 'w').write('👨‍👩‍👧x✅y\n')
    start('e.txt', w=110, h=26)
    keys('End'); time.sleep(0.3)
    check('613 emoji: ✅ takes two columns; a ZWJ family each of its emoji where the terminal does not join them',
          'Ln 1, Col 11' in screen(), screen()[-200:])
    raw_in(b'\x1b[?2027;2$y')
    keys('Home', 'End'); time.sleep(0.3)
    check('613 emoji: the terminal joins clusters (mode 2027): the family is one character, two columns',
          'Ln 1, Col 7' in screen(), screen()[-200:])
    keys('Home', 'Right'); time.sleep(0.2)
    check('613 emoji: … and the cursor steps over it at once', 'Ln 1, Col 3' in screen(), screen()[-200:])
    raw_in(b'\x1b[?1u')                          # (the terminal speaks the kitty keyboard protocol)
    raw_in(b'\x1b[102;6u')                       # Ctrl+Shift+F
    check('613 kitty keys: Ctrl+Shift+F has a binding of its own', 'untitled' in screen().split('\n')[1], screen()[:300])
    raw_in(b'\x1b[119;5u')                       # Ctrl+W
    raw_in(b'\x1b[105;5u')                       # Ctrl+I — not Tab
    check('613 kitty keys: Ctrl+I is not Tab', 'Soft wrap' in screen() and 'untitled' not in screen().split('\n')[1],
          screen())
    raw_in(b'\x1b[27u')                          # Esc
    raw_in(b'\x1b[119;5u')                       # Ctrl+W closes e.txt …
    gone = 'e.txt' not in screen().split('\n')[1]
    raw_in(b'\x1b[116:84;4u')                    # … Alt+Shift+T as the protocol sends it: 'T' with Alt, as before
    check('613 kitty keys: Alt+Shift+letter arrives as it always did (Alt+Shift+T reopens the closed tab)',
          gone and 'e.txt' in screen().split('\n')[1], screen()[:300])
    keys('Escape', 'C-End'); text('!'); time.sleep(0.2)
    raw_in(b'\x1b[O'); time.sleep(0.6)           # the terminal lost the focus
    check('613 focus: editor.saveOnFocusLost saves when the terminal loses the focus', ftext('e.txt').rstrip('\n').endswith('!'),
          repr(ftext('e.txt')))
    raw_in(b'\x1b[I')
    a0 = screen_ansi().split('\n')[3][:40]
    raw_in(b'\x1b[?997;2n'); time.sleep(0.4)     # the system went light
    a1 = screen_ansi().split('\n')[3][:40]
    check('613 light/dark: "theme": "auto" follows the terminal when it switches (mode 2031)', a0 != a1, repr((a0, a1)))
    raw_in(b'\x1bP1+r536d756c78=5c45\x1b\\')    # XTGETTCAP: Smulx — curly underlines
    palette('Check setup'); time.sleep(1)
    s = screen()
    check('613 check setup: what the terminal answered', 'kitty keyboard protocol' in s and 'grapheme' in s and
          'curly underlines' in s, s)
    keys('Escape'); time.sleep(0.2)
    open(W + '/e.txt', 'w').write('changed outside\n')
    raw_in(b'\x1b[O'); raw_in(b'\x1b[I')        # (away and back: what changed is looked at at once)
    check('613 focus: back in the terminal, a file changed meanwhile is noticed at once', wait_for('changed outside|changed on disk', 1.5),
          screen())

def t_613_edit_tools():
    # a selection through a command (and vim's :%!), a command of yours whose output becomes problems, the line a jump
    # lands on, the terminal's title, a transparent background, Backspace over an emoji with a skin tone
    setup({"commands": {"lint": {"run": "printf 'a.txt:2:1: error: no alpha here\\n'; exit 1", "output": "problems"},
                        "slow": {"run": "sleep 2.5; echo slow-done", "output": "panel"}},
           "ui.transparentBackground": True})
    open(W + '/a.txt', 'w').write('zeta\nalpha\nmid\n')
    open(W + '/long.txt', 'w').write(''.join('line %d\n' % i for i in range(200)))
    start('a.txt', w=110, h=30)
    keys('C-a')
    palette('Edit: put the selection through a command'); time.sleep(0.3)
    text('sort'); keys('Enter'); time.sleep(1.2)
    keys('C-s'); time.sleep(0.4)
    check('613 pipe: the selection through sort', ftext('a.txt') == 'alpha\nmid\nzeta\n', repr(ftext('a.txt')))
    palette('lint'); time.sleep(1.5)
    check('613 commands: output "problems" — a linter\'s file:line: lines are problems', 'no alpha here' in screen() and
          '● 1' in screen(), screen())
    def status_bgs():
        row = screen_ansi().rstrip('\n').split('\n')[-1]
        return set(re.findall(r'48;2;(\d+;\d+;\d+)', row))
    idle = status_bgs()
    palette('slow'); time.sleep(1.4)
    busy = status_bgs()
    wait_for('Finished in', 6); time.sleep(0.4)
    check('613 progress: a long run fills the status bar (a band moving across)', len(busy - idle) >= 1 and
          len(status_bgs() - idle) == 0, repr((idle, busy, status_bgs())))
    keys('Escape')
    title = tm('display', '-p', '-t', 'f', '#{pane_title}').stdout.strip()
    check('613 title: the file and the project in the terminal\'s title', title == 'a.txt — work', repr(title))
    keys('End'); text('x'); time.sleep(0.3)
    title = tm('display', '-p', '-t', 'f', '#{pane_title}').stdout.strip()
    check('613 title: … ● while it has unsaved changes', title == '● a.txt — work', repr(title))
    keys('C-z')
    keys('C-p'); time.sleep(0.3); text('long.txt'); time.sleep(0.4); keys('Enter'); time.sleep(0.8)
    keys('C-g'); time.sleep(0.2); text('150'); keys('Enter'); time.sleep(0.1)
    plain = screen().split('\n')
    an = screen_ansi().split('\n')
    i = [k for k, l in enumerate(plain) if ' line 149' in l]
    lit = an[i[0]] if i else ''
    time.sleep(1.0)
    an2 = screen_ansi().split('\n')
    check('613 jump: the line a jump lands on lights up, then it fades', i and lit != an2[i[0]], repr((lit[:60], an2[i[0]][:60] if i else '')))
    other = [l for k, l in enumerate(an2) if ' line 151' in plain[k]] if i else []
    check('613 transparent: the editor\'s background is the terminal\'s', other and '\x1b[49m' in other[0] or
          (other and '48;2;' not in other[0].split('line')[-1]), repr(other[:1]))
    keys('C-End'); text('a'); keys('Enter')
    tm('send-keys', '-t', 'f', '-l', 'b👍🏽'); time.sleep(0.3)
    keys('BSpace'); time.sleep(0.2); keys('C-s'); time.sleep(0.4)
    check('613 emoji: Backspace takes an emoji with its skin tone at once', ftext('long.txt').endswith('a\nb\n') or
          ftext('long.txt').endswith('a\nb'), repr(ftext('long.txt')[-12:]))

def t_613_vim_filter():
    # vim: :%!sort puts the lines through a command, :!cmd runs one (its output in the panel)
    setup({"editor.vimMode": True, "editor.keymap": "vim"})
    open(W + '/v.txt', 'w').write('c\nb\na\n')
    start('v.txt', w=100, h=26)
    text(':%!sort'); keys('Enter'); time.sleep(1.2)
    text(':w'); keys('Enter'); time.sleep(0.5)
    check('613 vim: :%!sort', ftext('v.txt') == 'a\nb\nc\n', repr(ftext('v.txt')))
    text(':!echo hi-from-bang'); keys('Enter')
    check('613 vim: :!cmd runs it, its output in the panel', wait_for('hi-from-bang', 4), screen())


def t_614_web_css():
    # ned's own CSS engine: a property and then its value completed; an unknown property, a value its property does
    # not take, a missing `;` — found as you write; the hover
    setup({"web.engine": "on"})
    open(W + '/style.css', 'w').write('a {\n  \n}\n\nb {\n  colr: red;\n  display: flexx;\n  color: blue\n  margin: 0;\n}\n')
    start('style.css', w=130, h=30)
    check('614 css: an unknown property, and the one meant', wait_for("unknown property 'colr' — did you mean 'color'", 5),
          screen())
    check('614 css: a value its property does not take', "'flexx' is not a value of display" in screen(), screen())
    check('614 css: a missing ; between two declarations', "missing ';'" in screen(), screen())
    keys('Down', 'End'); text('disp'); time.sleep(0.7)
    check('614 css: properties completed', ' display ' in screen() and 'property' in screen(), screen())
    keys('Tab'); time.sleep(0.3); text('fl'); time.sleep(0.7)
    check('614 css: … then the property\'s values', 'inline-flex' in screen(), screen())
    keys('Tab'); time.sleep(0.3); keys('C-s'); time.sleep(0.5)
    check('614 css: accepted, as `display: flex`', ftext('style.css').startswith('a {\n  display: flex\n}'),
          repr(ftext('style.css')))
    keys('Home'); keys('Right', 'Right'); keys('M-h'); time.sleep(0.6)
    check('614 css: hover on a property', 'CSS property' in screen(), screen())

def t_614_web_html():
    # ned's own HTML: a closing tag that closes the wrong element, class names from the project's stylesheets, the
    # elements and attributes; the built-in HTML formatter
    setup({})
    open(W + '/site.css', 'w').write('.hero-title { margin: 0 }\n')
    open(W + '/page.html', 'w').write('<!DOCTYPE html>\n<html>\n<body>\n  <div>\n    <span>x</div>\n  <p class="">\n</body>\n</html>\n')
    open(W + '/ugly.html', 'w').write('<ul><li>one</li><li>two</li></ul>\n<section><h1>Hi</h1><p>text</p></section>\n')
    start('page.html', w=130, h=30)
    check('614 html: a closing tag that closes the wrong element', wait_for('<span> is not closed before </div>', 5),
          screen())
    keys('C-g'); text('6'); keys('Enter'); keys('End', 'Left', 'Left'); text('he'); time.sleep(0.7)
    check('614 html: the class names the project\'s stylesheets have', 'hero-title' in screen(), screen())
    keys('Escape'); keys('End'); keys('Enter'); text('<sec'); time.sleep(0.7)
    check('614 html: elements', 'section' in screen() and 'element' in screen(), screen())
    keys('Tab'); time.sleep(0.3); text(' '); time.sleep(0.7)
    check('614 html: attributes', ' class ' in screen() and ' attribute ' in screen(), screen())
    keys('Escape')
    keys('C-p'); time.sleep(0.3); text('ugly.html'); time.sleep(0.4); keys('Enter'); time.sleep(1.0)
    keys('M-f'); time.sleep(0.8); keys('C-s'); time.sleep(0.5)
    check('614 html: the built-in formatter', ftext('ugly.html') ==
          '<ul>\n  <li>one</li>\n  <li>two</li>\n</ul>\n<section>\n  <h1>Hi</h1>\n  <p>text</p>\n</section>\n',
          repr(ftext('ugly.html')))

def t_614_web_sql():
    # ned's own SQL: the tables the project creates after FROM, a table's columns after `u.` — in a .sql file and in
    # the SQL of a Nim string; a query given more values than its `?`, a column its table does not have
    setup({})
    open(W + '/schema.sql', 'w').write('CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT);\n')
    open(W + '/q.sql', 'w').write('select * from \n')
    open(W + '/db.nim', 'w').write('proc exec(a: int, s: string, x: varargs[string]) = discard\n'
                                   'proc sql(s: string): string = s\nlet db = 1\n'
                                   'db.exec(sql"INSERT INTO users (name, email) VALUES (?, ?)", "a", "b", "c")\n'
                                   'db.exec(sql"SELECT  FROM users u WHERE u.nam = ?", "1")\n')
    start('q.sql', w=130, h=30)
    keys('End'); text('u'); time.sleep(0.8)
    check('614 sql: the project\'s tables after FROM', 'users' in screen() and '3 columns' in screen(), screen())
    keys('Escape')
    keys('C-p'); time.sleep(0.3); text('db.nim'); time.sleep(0.4); keys('Enter')
    check('614 sql: more values than `?`', wait_for("exec: 3 values for the query's 2 '\\?'", 6), screen())
    check('614 sql: a column its table does not have', "has no column 'nam' — did you mean 'name'" in screen(), screen())
    keys('C-g'); text('5'); keys('Enter'); keys('Home')
    for _ in range(19): keys('Right')
    text('u.'); time.sleep(0.8)
    check('614 sql: a table\'s columns after `u.`, in a Nim string', 'email' in screen() and 'users' in screen(), screen())

def t_614_picker_preview():
    # the file picker shows the selected file beside the list; the symbol picker the symbol's line
    setup({})
    open(W + '/notes.txt', 'w').write('first line of the notes\nsecond line\n')
    start('src/demo.nim', w=140, h=34)
    keys('C-p'); time.sleep(0.3); text('notes'); time.sleep(0.6)
    check('614 preview: the selected file beside the list', 'first line of the notes' in screen() and
          '─ notes.txt' in screen(), screen())
    keys('Escape')

def t_614_jump_labels():
    # Alt+Shift+J: a label on each word on screen; its letter puts the cursor there
    setup({})
    open(W + '/j.txt', 'w').write('alpha beta\ngamma delta\n')
    start('j.txt', w=100, h=20)
    keys('M-J'); time.sleep(0.5)
    sc = screen()
    check('614 jump: a label over each word', 'jeta' in sc and 'kelta' in sc, sc)
    text('k'); time.sleep(0.3); text('X'); keys('C-s'); time.sleep(0.5)
    check('614 jump: its letter puts the cursor there', ftext('j.txt') == 'alpha beta\ngamma Xdelta\n', repr(ftext('j.txt')))

def t_614_git_new_folder():
    # a new folder in the Git dock is one line (with how many files), not every file in it
    setup({})
    os.makedirs(W + '/newdir/sub', exist_ok=True)
    open(W + '/newdir/a.txt', 'w').write('a\n')
    open(W + '/newdir/sub/b.txt', 'w').write('b\n')
    start('src/demo.nim', w=130, h=34)
    keys('M-g'); time.sleep(2.0)
    sc = screen()
    check('614 git: a new folder is one line, with its files counted', 'newdir/' in sc and '2 files' in sc and
          'b.txt' not in sc, sc)

def t_614_format_pieces():
    # formatting a file again formats only the statements that changed — the result the same as all at once
    setup({})
    procs = ''.join('proc p%d(a:int):int=\n  a+%d\n\n' % (i, i) for i in range(400))
    open(W + '/many.nim', 'w').write(procs)
    start('many.nim', w=120, h=30)
    keys('M-f'); time.sleep(1.5)
    keys('C-g'); text('5'); keys('Enter'); keys('End'); text(';let x=1'); time.sleep(0.2)
    keys('M-f'); time.sleep(1.0); keys('C-s'); time.sleep(0.6)
    shutil.copy(W + '/many.nim', W + '/again.nim')
    open(W + '/fresh.nim', 'w').write(procs.replace('a+1\n', 'a+1;let x=1\n', 1))
    r = sh('cd %s && %s --format fresh.nim' % (W, BIN))
    check('614 format: piece by piece, the same as the whole file at once', ftext('many.nim') == ftext('fresh.nim'),
          r.stdout + r.stderr + repr(ftext('many.nim')[:300]) + ' | ' + repr(ftext('fresh.nim')[:300]))


def t_6141_quick_fix_keys():
    # quick fixes without Alt+Enter — Windows Terminal keeps it for full screen: Alt+Shift+Enter (arrives as Alt+Enter),
    # Ctrl+. (where the terminal tells it apart: the kitty keyboard protocol), the right-click menu, Edit › Quick fix…;
    # in Windows Terminal (WT_SESSION) the key shown is Alt+Shift+Enter
    setup({"nim.nimsuggest": False})
    open(W + '/q.nim', 'w').write('import std/base64\necho "hi"\n')
    start('q.nim', w=120, h=30, env_extra='WT_SESSION=test-session'); time.sleep(2)
    keys('C-p'); text('>Quick fix'); time.sleep(0.5)
    check('6141 Windows Terminal: the key shown is Alt+Shift+Enter', 'Alt+Shift+Enter · Ctrl+.' in screen(), screen())
    keys('Escape')
    tm('send-keys', '-t', 'f', '-l', '\x1b[<2;12;4M'); time.sleep(0.05)
    tm('send-keys', '-t', 'f', '-l', '\x1b[<2;12;4m'); time.sleep(0.5)
    check('6141 the right-click menu: Quick fix…', 'Quick fix…' in screen(), screen())
    keys('Escape'); time.sleep(0.2)
    keys('F10'); time.sleep(0.3); keys('Down'); time.sleep(0.2); keys('Right'); time.sleep(0.4)
    check('6141 the Edit menu: Quick fix…', 'Quick fix…' in screen() and 'Undo' in screen(), screen())
    keys('Escape'); keys('Escape'); time.sleep(0.3)
    keys('C-Home'); tm('send-keys', '-t', 'f', '-l', '\x1b\r'); time.sleep(0.8)
    check('6141 Alt+Shift+Enter (as the terminal sends it): the quick fixes', 'Remove unused import base64' in screen(),
          screen())
    keys('Escape'); time.sleep(0.2)
    tm('send-keys', '-t', 'f', '-l', '\x1b[46;5u'); time.sleep(0.8)
    check('6141 Ctrl+.: the quick fixes', 'Remove unused import base64' in screen(), screen())
    keys('Escape')

def t_6141_ref_counts():
    # a routine the module keeps to itself is counted in the module only: `js`, used once here, is "1 reference" however
    # often other modules name something js (it was "300+ references": the word, project-wide)
    setup({"nim.nimsuggest": False, "nim.referenceCounts": True})
    os.makedirs(W + '/other', exist_ok=True)
    for k in range(40):
        open(W + '/other/o%d.nim' % k, 'w').write(''.join('proc f%d_%d(js: int): int = js + %d\n' % (k, i, i) for i in range(10)))
    open(W + '/rc.nim', 'w').write('func js(s: string): string = s\n\nconst Script = js"""a"""\necho Script\n')
    start('rc.nim', w=120, h=30)
    check('6141 counts: a name the module keeps to itself, counted in the module', wait_for('1 reference', 15) and
          '300+' not in screen(), screen())

def t_6141_showcase():
    # the showcase shows what ned's own engines find in strings: a CSS property misspelled, a query given more values
    # than its `?` — and ned --lint says so too
    setup({"nim.nimsuggest": False})
    shutil.copy(REPO + '/examples/showcase.nim', W + '/showcase.nim')
    r = subprocess.run([BIN, '--lint', 'showcase.nim'], capture_output=True, text=True, cwd=W)
    check("6141 ned --lint: the SQL and CSS in the strings", "[sql-args]" in r.stdout and "'paddng'" in r.stdout,
          r.stdout + r.stderr)
    start('showcase.nim', w=150, h=40); time.sleep(1)
    at = [i + 1 for i, l in enumerate(ftext('showcase.nim').split('\n')) if 'db.exec(sql"INSERT' in l][0]
    keys('C-g'); text(str(at)); keys('Enter')
    check("6141 the showcase: exec given 3 values for 2 '?'", wait_for("exec: 3 values for the query's 2", 10), screen())


def t_615_select_structure():
    # Alt+Shift+→ grows the selection to the next piece of code: the name, the call, the argument, the brackets, the
    # member chain, the statement, the block, the routine — Alt+Shift+← goes back
    setup({"nim.nimsuggest": None})
    src = 'proc go(a: int): int =\n  let x = foo.bar(a, call(a, 3)).baz\n  result = x\n'
    for name, n, want in [('s1.nim', 2, '  let x = foo.bar(a, Z).baz\n'), ('s2.nim', 6, '  let x = Z.baz\n'),
                          ('s6.nim', 7, '  let x = Z\n'),
                          ('s3.nim', 8, '  Z\n  result = x\n'), ('s4.nim', 9, 'proc go(a: int): int =\n  Z\n')]:
        open(W + '/' + name, 'w').write(src)
        tm('kill-server'); time.sleep(0.3)
        start(name, w=110, h=24); time.sleep(0.5)
        keys('C-g'); text('2:22'); keys('Enter'); time.sleep(0.2)
        for _ in range(n): keys('M-S-Right'); time.sleep(0.12)
        text('Z'); keys('C-s'); time.sleep(0.5)
        check('615 select by structure: %d steps out from a name' % n, want in ftext(name), repr(ftext(name)))
    tm('kill-server'); time.sleep(0.3)
    open(W + '/s5.nim', 'w').write(src)
    start('s5.nim', w=110, h=24); time.sleep(0.5)
    keys('C-g'); text('2:22'); keys('Enter'); time.sleep(0.2)
    for _ in range(4): keys('M-S-Right'); time.sleep(0.12)
    for _ in range(2): keys('M-S-Left'); time.sleep(0.12)
    text('Z'); keys('C-s'); time.sleep(0.5)
    check('615 select by structure: Alt+Shift+← goes back a step', 'foo.bar(a, Z).baz' in ftext('s5.nim'), repr(ftext('s5.nim')))

def t_615_surround():
    # Edit › Surround with… (Alt+Shift+S): quotes around a word, the pair changed, taken away; a block around lines
    setup({"nim.nimsuggest": None})
    open(W + '/sr.nim', 'w').write('let a = foo + bar\n')
    open(W + '/sb.nim', 'w').write('echo 1\necho 2\n')
    start('sr.nim', w=120, h=26); time.sleep(0.5)
    keys('C-g'); text('1:10'); keys('Enter')
    keys('M-S'); time.sleep(0.5)
    check('615 surround: the picker of pairs and blocks', 'Surround with' in screen() and 'when' in screen(), screen())
    text('double'); time.sleep(0.3); keys('Enter'); time.sleep(0.3)
    keys('C-s'); time.sleep(0.4)
    check('615 surround: quotes around the word', ftext('sr.nim') == 'let a = "foo" + bar\n', repr(ftext('sr.nim')))
    keys('C-g'); text('1:11'); keys('Enter')
    palette('Change the surrounding pair'); time.sleep(0.4)
    text('square'); time.sleep(0.3); keys('Enter'); time.sleep(0.3); keys('C-s'); time.sleep(0.4)
    check('615 surround: the pair changed', ftext('sr.nim') == 'let a = [foo] + bar\n', repr(ftext('sr.nim')))
    keys('C-g'); text('1:11'); keys('Enter')
    palette('Delete the surrounding pair'); time.sleep(0.4); keys('C-s'); time.sleep(0.4)
    check('615 surround: the pair taken away', ftext('sr.nim') == 'let a = foo + bar\n', repr(ftext('sr.nim')))
    keys('C-p'); time.sleep(0.3); text('sb.nim'); time.sleep(0.4); keys('Enter'); time.sleep(0.6)
    keys('C-a'); keys('M-S'); time.sleep(0.5)
    text('when'); time.sleep(0.3); keys('Enter'); time.sleep(0.3)
    text('true'); keys('C-s'); time.sleep(0.4)
    check('615 surround: a block around the lines (its condition typed in its place)',
          ftext('sb.nim') == 'when true:\n  echo 1\n  echo 2\n', repr(ftext('sb.nim')))

def t_615_vim_surround():
    # vim: ys{motion}{char}, yss, cs{old}{new}, ds{char}, S{char} on a visual selection (as vim-surround)
    setup({"editor.vimMode": True, "editor.keymap": "vim", "nim.nimsuggest": None})
    open(W + '/vs.txt', 'w').write('hello world\nsecond line\n')
    start('vs.txt', w=100, h=24); time.sleep(0.5)
    text('ysiw"'); time.sleep(0.2); text(':w'); keys('Enter'); time.sleep(0.4)
    check('615 vim: ysiw" quotes the word', ftext('vs.txt').startswith('"hello" world\n'), repr(ftext('vs.txt')))
    text("cs\"'"); time.sleep(0.2); text(':w'); keys('Enter'); time.sleep(0.4)
    check("615 vim: cs\"' changes the quotes", ftext('vs.txt').startswith("'hello' world\n"), repr(ftext('vs.txt')))
    text("ds'"); time.sleep(0.2); text(':w'); keys('Enter'); time.sleep(0.4)
    check("615 vim: ds' takes them away", ftext('vs.txt').startswith('hello world\n'), repr(ftext('vs.txt')))
    text('yss)'); time.sleep(0.2); text(':w'); keys('Enter'); time.sleep(0.4)
    check('615 vim: yss) around the line', ftext('vs.txt').startswith('(hello world)\n'), repr(ftext('vs.txt')))
    text('jwve'); text('S]'); time.sleep(0.2); text(':w'); keys('Enter'); time.sleep(0.4)
    check('615 vim: S] around the visual selection', '\nsecond [line]\n' in ftext('vs.txt'), repr(ftext('vs.txt')))

def t_615_undo_tree():
    # an edit after an undo keeps what was undone: Undo history… (Alt+Shift+U) lists every state with a preview,
    # going to one makes the edits left a branch in turn; vim's g- goes back in time across branches
    setup({"nim.nimsuggest": None})
    open(W + '/u.txt', 'w').write('abc\n')
    start('u.txt', w=130, h=30); time.sleep(0.5)
    keys('End'); text('1'); time.sleep(1.8); text('2'); time.sleep(1.8)
    keys('C-z'); time.sleep(0.3); text('X'); time.sleep(0.3)
    keys('M-U'); time.sleep(0.8)
    sc = screen()
    check('615 undo tree: every state, the undone one on a branch', 'Undo history' in sc and '⑂ typed “2”' in sc and
          'typed “X”' in sc, sc)
    check('615 undo tree: a preview of the text there', 'the text at that state' in sc and 'abc1X' in sc, sc)
    keys('Down'); time.sleep(0.4)
    check('615 undo tree: … the preview follows the selection', 'abc12' in screen(), screen())
    keys('Enter'); time.sleep(0.4); keys('C-s'); time.sleep(0.4)
    check('615 undo tree: to the branch', ftext('u.txt') == 'abc12\n', repr(ftext('u.txt')))
    keys('M-U'); time.sleep(0.8)
    check('615 undo tree: the edits left are a branch now', '⑂ typed “X”' in screen(), screen())
    keys('Escape')
    tm('kill-server'); time.sleep(0.3)
    start('u.txt', w=130, h=30); time.sleep(0.6)
    keys('M-U'); time.sleep(0.8)
    check('615 undo tree: kept with the file\'s undo history (after a restart)', '⑂ typed “X”' in screen(), screen())

def t_615_git_changes():
    # Git › Changes… (Alt+Shift+G): every change not committed in one editable view — staged or not in each header;
    # stage, unstage, revert the change at the cursor; an edit there written back with Ctrl+S
    setup({"nim.nimsuggest": None})
    open(W + '/ga.txt', 'w').write(''.join('line %d\n' % i for i in range(1, 21)))
    open(W + '/gb.txt', 'w').write('alpha\nbeta\n')
    git('add -A'); git('-c user.email=a@b -c user.name=t commit -qm base')
    open(W + '/ga.txt', 'w').write(''.join(('LINE %d\n' if i == 3 else 'line %d\n') % i for i in range(1, 21)) + 'line 21\n')
    open(W + '/gb.txt', 'w').write('alpha\nBETA\n')
    start('ga.txt', w=140, h=34); time.sleep(0.8)
    keys('M-G')
    ok = wait_for(r'changes in 2 files', 8)
    sc = screen()
    check('615 git changes: every change in one view, with what it is', ok and 'ga.txt  line 2  +1 −1 · not staged' in sc and
          'LINE 3' in sc and 'gb.txt  line 1' in sc and 'line 21' in sc, sc)
    keys('Down'); keys('Down'); time.sleep(0.2)
    palette('Git: stage this change')
    ok = wait_for(r'Change staged', 8); time.sleep(1.0)
    cached = git('diff --cached').stdout
    check('615 git changes: the change at the cursor staged (and the view says so)', ok and '+LINE 3' in cached and
          'line 21' not in cached and '· staged' in screen(), cached + screen())
    keys('C-Home'); keys('Down'); keys('Down'); time.sleep(0.2)
    palette('Git: unstage this change')
    ok = wait_for(r'Change unstaged', 8); time.sleep(0.8)
    check('615 git changes: … and unstaged', ok and git('diff --cached').stdout.strip() == '', git('diff --cached').stdout)
    keys('C-Home'); keys('Down'); keys('Down'); time.sleep(0.2)
    palette('Git: revert this change')
    ok = wait_for(r'reverted to the last commit', 8); time.sleep(0.8)
    check('615 git changes: … and reverted', ok and 'LINE 3' not in ftext('ga.txt') and 'line 3\n' in ftext('ga.txt') and
          'line 21' in ftext('ga.txt'), ftext('ga.txt'))
    sc = screen()
    rows = sc.split('\n')
    i = [k for k, r in enumerate(rows) if 'BETA' in r]
    check('615 git changes: the view made again', i and 'LINE 3' not in sc, sc)
    keys('C-End'); keys('Home'); text('X'); keys('C-s')
    wait_for(r'Saved changes to 1', 6); time.sleep(0.8)
    check('615 git changes: an edit in the view written back to its file', 'XBETA' in ftext('gb.txt'), ftext('gb.txt'))

def t_615_next_edit():
    # after a name is changed, the next place that has it shows → new ⇥: Tab goes there, Tab makes it, Esc says no;
    # with ai.nextEdit, where an edit has no repeat the quick model suggests what follows
    setup({"nim.nimsuggest": None})
    open(W + '/ne.nim', 'w').write('let width = 10\necho width * 2\necho width + 1\nlet widthy = 3\n')
    start('ne.nim', w=110, h=24); time.sleep(0.6)
    keys('C-g'); text('1:5'); keys('Enter'); keys('M-S-Right'); text('size'); time.sleep(0.3); keys('Escape')
    ok = wait_for('→ size ⇥', 4)
    check('615 next edit: the next place with the old name shows the change', ok and 'Tab: “width” → “size”' in screen(), screen())
    keys('Tab'); time.sleep(0.2); keys('Tab'); time.sleep(0.3)
    keys('Tab'); time.sleep(0.2); keys('Tab'); time.sleep(0.3)
    keys('C-s'); time.sleep(0.4)
    check('615 next edit: Tab, Tab — made at each place (a longer name that starts the same left as it is)',
          ftext('ne.nim') == 'let size = 10\necho size * 2\necho size + 1\nlet widthy = 3\n', repr(ftext('ne.nim')))
    keys('C-g'); text('1:5'); keys('Enter'); keys('M-S-Right'); text('w'); time.sleep(0.3); keys('Escape')
    wait_for('→ w ⇥', 4); keys('Escape'); time.sleep(0.3)
    check('615 next edit: Esc says no', '→ w ⇥' not in screen(), screen())
    keys('C-z'); keys('C-s')
    tm('kill-server'); time.sleep(0.3)
    setup({"nim.nimsuggest": None, "ai.nextEdit": True})
    open(W + '/na.nim', 'w').write('# NEXTEDIT\nlet a = 1\nlet b = 2\n')
    start('na.nim', w=110, h=24); time.sleep(0.6)
    keys('C-g'); text('2'); keys('Enter'); keys('End'); text('.0'); time.sleep(0.3); keys('Escape')
    ok = wait_for(r'→ 2\.0 ⇥ \(AI\)', 8)
    check('615 next edit: from AI, where the edit has no repeat', ok, screen())
    keys('Tab'); time.sleep(0.2); keys('Tab'); time.sleep(0.3); keys('C-s'); time.sleep(0.4)
    check('615 next edit: … Tab, Tab takes it', ftext('na.nim') == '# NEXTEDIT\nlet a = 1.0\nlet b = 2.0\n', repr(ftext('na.nim')))


def t_615_web_js():
    # ned's own JavaScript: a class's members after `p.`, a global's (Math.), hover with the signature, F12 to the
    # declaration; problems — a const assigned, a name one letter off; in an HTML page's <script> too
    setup({"web.engine": "on"})
    open(W + '/app.js', 'w').write('class Point {\n  constructor(x, y) { this.x = x; this.y = y; }\n'
                                   '  norm() { return Math.hypot(this.x, this.y); }\n}\n'
                                   'const p = new Point(1, 2);\nconst total = 1;\ntotal = 2;\nconsole.log(p, totl);\n\n')
    open(W + '/page.html', 'w').write('<!DOCTYPE html>\n<html>\n<body>\n<script>\n  const n = 1;\n  n = 2;\n'
                                      '</script>\n</body>\n</html>\n')
    start('app.js', w=130, h=30)
    ok = wait_for("'total' is a constant", 6)
    check('615 js: assigning a const', ok, screen())
    check("615 js: a name one letter off one that is declared", wait_for("did you mean 'total'", 4), screen())
    keys('C-g'); text('9'); keys('Enter'); text('p.'); time.sleep(0.8)
    sc = screen()
    check('615 js: a class\'s members after p.', 'norm' in sc and ' x ' in sc, sc)
    keys('Escape'); text('norm'); time.sleep(0.2); keys('Escape'); keys('Left')
    keys('F12'); time.sleep(0.6)
    check('615 js: F12 to the method', status_pos() and status_pos()[0] == 3, screen())
    keys('M-,'); time.sleep(0.3)
    keys('C-g'); text('3:24'); keys('Enter'); keys('M-h'); time.sleep(0.8)
    check('615 js: hover on Math.hypot', 'hypot' in screen() and 'MDN' in screen() or 'developer.mozilla' in screen(), screen())
    keys('Escape')
    keys('C-p'); time.sleep(0.3); text('page.html'); time.sleep(0.4); keys('Enter')
    check("615 js: in an HTML page's <script>", wait_for("'n' is a constant", 6), screen())
    r = subprocess.run([BIN, '--lint', '--format:text', 'app.js'], capture_output=True, text=True, cwd=W)
    check('615 js: ned --lint', '[js-const-assign]' in r.stdout and '[js-typo]' in r.stdout, r.stdout + r.stderr)

def t_615_cpp():
    # C++ in ned's own C engine: members after `.` through a class's bases, `ns::`, hover on a method; in an emit when
    # the backend is C++
    setup({"c.engine": "builtin", "nim.backend": "cpp", "nim.emitClangd": False})
    open(W + '/shape.cpp', 'w').write('namespace geo {\nstruct Base {\n  int id;\n  void hello() {}\n};\n'
                                      'class Circle : public Base {\npublic:\n  double r;\n  double area() const { return 3.14 * r * r; }\n};\n'
                                      'int count() { return 1; }\n}\n\nint main() {\n  geo::Circle c;\n  \n  return 0;\n}\n')
    open(W + '/ec.nim', 'w').write('{.emit: """\nnamespace util {\nstruct Acc {\n  int total;\n  void add(int x) { total += x; }\n};\n}\n'
                                   'static int run() {\n  util::Acc a;\n  \n  return a.total;\n}\n""".}\n')
    start('shape.cpp', w=130, h=34); time.sleep(1)
    keys('C-g'); text('16'); keys('Enter'); keys('End'); text('c.'); time.sleep(1.0)
    sc = screen()
    check('615 C++: members after c. — its own and its base class\'s', 'area' in sc and 'hello' in sc and ' r ' in sc, sc)
    keys('Escape'); keys('Home'); keys('S-End'); text('  geo::'); time.sleep(1.0)
    sc = screen()
    check('615 C++: a namespace\'s names after ::', 'count' in sc and 'Circle' in sc, sc)
    keys('Escape')
    keys('C-p'); time.sleep(0.3); text('ec.nim'); time.sleep(0.4); keys('Enter'); time.sleep(1.5)
    keys('C-g'); text('10'); keys('Enter'); keys('End'); text('a.'); time.sleep(1.0)
    sc = screen()
    check('615 C++ in an emit (backend cpp): a struct\'s members', 'add' in sc and 'total' in sc, sc)
    keys('Escape')


def t_616_engine_worker():
    # the engine worker (nim.engineWorker): type hints, misspelled names and reference counts worked out by a second
    # ned — started when needed, started again when it stops; an unsaved file's names reach it; off: the editor
    # works them out itself
    setup({"nim.nimsuggest": False})
    open(W + '/lib6.nim', 'w').write('proc helper*(): int = 1\n')
    open(W + '/use6.nim', 'w').write('import lib6\n\nproc area(w, h: int): int = w * h\n\nlet size = area(2, 3)\n'
                                     'echo size, helper()\necho siez\n')
    start('use6.nim', w=120, h=30); time.sleep(0.5)
    check('616 worker: type hints', wait_for('let size: int = area', 10), screen())
    check("616 worker: a misspelled name", wait_for("did you mean 'size'", 8) or "'siez'" in screen(), screen())
    check('616 worker: reference counts', wait_for('1 reference', 8), screen())
    palette('Performance'); time.sleep(1.0)
    sc = screen()
    m = re.search(r'engine worker: pid (\d+)', sc)
    check('616 worker: Help › Performance says it runs, and what it costs', m is not None and ' MB' in sc, sc)
    keys('Escape'); keys('C-w'); time.sleep(0.3)
    if m:
        os.kill(int(m.group(1)), 9); time.sleep(0.5)
    # an unsaved file: the names it declares now are what the other file sees
    keys('C-p'); time.sleep(0.3); text('lib6.nim'); time.sleep(0.4); keys('Enter'); time.sleep(0.5)
    keys('C-End'); keys('Enter'); text('proc helper2*(): string = "two"'); time.sleep(0.3)
    keys('C-p'); time.sleep(0.3); text('use6.nim'); time.sleep(0.4); keys('Enter'); time.sleep(0.5)
    keys('C-g'); text('6'); keys('Enter'); keys('End'); text('\nlet more = size + 1\nlet h2 = helper2()')
    ok = wait_for('let more: int = size', 10)
    check('616 worker: started again after it stopped — the hints go on', ok, screen())
    check("616 worker: what an unsaved file declares is what it sees (helper2's type, not on disk)",
          wait_for('let h2: string = helper2', 10), screen())
    tm('kill-server'); time.sleep(0.3)
    setup({"nim.nimsuggest": False, "nim.engineWorker": False})
    open(W + '/use6.nim', 'w').write('proc area(w, h: int): int = w * h\nlet size = area(2, 3)\necho siez\n')
    start('use6.nim', w=120, h=30); time.sleep(0.5)
    check('616 worker off: the hints worked out by the editor itself', wait_for('let size: int = area', 10), screen())
    palette('Performance'); time.sleep(1.0)
    check('616 worker off: Help › Performance says so', 'engine worker: off' in screen(), screen())
    keys('Escape')


def t_618_nedls_in_ned():
    # ned with nedls as its Nim server (README: mostly for testing nedls): nedls's code actions next to ned's own,
    # each listed once, and one only nedls offers in the quick-fix list (Organize imports) applied through it
    nedls = os.path.join(os.path.dirname(BIN), 'nedls')
    if not os.path.exists(nedls):
        raise Skip('needs nedls next to ned (nimble nedls)')
    setup({"nim.ide": "nimlangserver", "lsp": {"nim": [nedls]}})
    open(W + '/gen618.nim', 'w').write('type\n  Pt* = object\n    x*, y*: int\n\necho Pt(x: 1)\n')
    open(W + '/imp618.nim', 'w').write('import std/strutils\nimport std/os\n\necho "a".toUpperAscii, getCurrentDir()\n')
    start('gen618.nim', w=140, h=40); time.sleep(3)
    keys('C-g'); text('2:3'); keys('Enter'); time.sleep(0.3); keys('M-Enter')
    ok = wait_for('Generate hash', 10); time.sleep(2.8)        # (the server's answer is in by then)
    s = screen()
    check("618 ned with nedls: an action both have listed once (ned's own)", ok and s.count('Generate hash') == 1, s)
    keys('Escape'); time.sleep(0.2)
    keys('C-p'); time.sleep(0.3); text('imp618.nim'); time.sleep(0.4); keys('Enter'); time.sleep(2)
    keys('C-g'); text('2:3'); keys('Enter'); time.sleep(0.3); keys('M-Enter')
    ok = wait_for('Organize imports', 10)
    if ok:
        text('Organize imports'); time.sleep(0.4); keys('Enter'); time.sleep(0.8); keys('C-s'); time.sleep(0.6)
    t = ftext('imp618.nim')
    check("618 ned with nedls: nedls's Organize imports from the quick-fix list, applied", ok and
          t.startswith('import std/[os, strutils]\n'), (t, screen()))

def t_619_nimble_resolve():
    # nimble 0.26's explanation of a dependency conflict (PubGrub's prose): a problem on each requires line of the
    # package it is about, the whole explanation its message (a fake nimble prints what 0.26.1 does)
    setup()
    d = TMP + '/fakenimble619'
    os.makedirs(d, exist_ok=True)
    open(d + '/nimble', 'w').write(
        '#!/bin/sh\n[ "$1" = "--version" ] && { echo "nimble v0.26.1 compiled at 2026-10-22"; exit 0; }\n'
        'echo "    Error:  Dependency resolution failed:"\n'
        'echo "        ... Because every version of b depends on a (-inf, 1.0) and demo depends on a [1.0, inf), '
        'every version of b is forbidden."\n'
        'echo "        ... So, because demo depends on b *, version solving failed."\nexit 1\n')
    os.chmod(d + '/nimble', 0o755)
    open(W + '/demo.nimble', 'a').write('requires "a >= 1.0"\nrequires "b"\n')
    start('demo.nimble', w=140, h=40, path=d + ':' + TOOLS + ':$PATH'); time.sleep(0.5)
    palette('Nimble: build')
    ok = wait_for('Exit code 1', 15)
    s = screen()
    check("619 nimble: the explanation points at the .nimble's requires line", ok and
          'demo.nimble:7' in s and 'cannot resolve the dependencies' in s, s)
    palette('Show problems'); time.sleep(0.8)
    s = screen()
    rows = s.splitlines()
    marked = lambda t: any(t in r and '● nimble cannot resolve' in r for r in rows)
    check("619 nimble: a problem on each requires line it is about (a >= 1.0, b), none on nim",
          marked('requires "a >= 1.0"') and marked('requires "b"') and not marked('requires "nim') and
          'PROBLEMS 2' in s, s)

HELLO_PLUGIN = '''import nedplugin

command "Hello: upper-case the line", "ctrl+alt+u":
  let b = current()
  let l = b.cursor.line
  b.replace(b.lineRange(l), b.line(l).toUpperAscii)
  b.insert(pos(l, b.line(l).len), "!")

command "Hello: problems":
  let b = current()
  var p = Problem(range: rng(pos(0, 0), pos(0, 3)), severity: 2, message: "three letters here")
  p.fixes.add Fix(title: "Make it four", edits: @[Edit(range: rng(pos(0, 0), pos(0, 3)), text: "four")])
  b.setProblems([p])
  b.sign(1, "★", "warn")
  b.virtualText(1, "a plugin's note")

onSave("*.txt") do (ev: Event):
  status("hello: saved " & $ev.buf.lineCount & " lines")

onSave("*.txt") do (ev: Event):          # (a second handler for the same event and pattern: both run)
  message("hello: the second save handler")

onOpen("*.md") do (ev: Event):
  log("opened " & ev.path.split('/')[^1])

onChange("lang:markdown") do (ev: Event):
  log("changed: " & ev.buf.line(0))
'''

def plugins_ready(t=30):
    """the Plugins dock says they run"""
    palette('Plugins panel')
    ok = wait_for('running · (nim e|native)', t)
    keys('Escape'); time.sleep(0.2)
    return ok

def t_619_plugins():
    # a plugin of yours (~/.config/ned/plugins/hello): its command from the palette and on its key (its two edits
    # one undo step), its event after saving (a status-bar item), a problem with a fix (Alt+Enter), a sign and a
    # note after a line, the Plugins dock listing what it has
    setup()
    d = CFG + '/ned/plugins/hello'
    os.makedirs(d, exist_ok=True)
    open(d + '/plugin.nims', 'w').write(HELLO_PLUGIN)
    # (and one that does not compile: left out, its error in Problems, the other runs)
    os.makedirs(CFG + '/ned/plugins/broken', exist_ok=True)
    open(CFG + '/ned/plugins/broken/plugin.nims', 'w').write('import nedplugin\ncommand "x":\n  undefinedThing()\n')
    open(W + '/notes.txt', 'w').write('abc def\nsecond\n')
    start('notes.txt', w=140, h=40); time.sleep(0.5)
    palette('Plugins panel')
    ok = wait_for('running · (nim e|native) · 1 plugin', 30) and wait_for("broke the plugins' start", 5)
    s = screen()
    keys('Escape'); time.sleep(0.2)
    check("619 plugins: the dock — the host runs, the plugin and its commands listed; a broken one left out", ok, s)
    palette('Show problems'); wait_for("undeclared identifier: 'undefinedThing'", 8)
    s = screen()
    check("619 plugins: the broken plugin's error in Problems", "undeclared identifier: 'undefinedThing'" in s, s)
    keys('Escape'); time.sleep(0.2)
    palette('Hello: upper-case the line')
    ok = wait_for('ABC DEF!', 10)
    check("619 plugins: a plugin's command from the palette edits the text", ok, screen())
    keys('C-z'); wait_for('abc def', 6)
    s = screen()
    check("619 plugins: its edits are one undo step", 'abc def' in s and 'ABC' not in s, s)
    keys('C-M-u'); time.sleep(0.2)
    ok = wait_for('ABC DEF!', 8)
    check("619 plugins: … and on the key it gave it (ctrl+alt+u)", ok, screen())
    keys('C-s')
    ok = wait_for('hello: saved 2 lines', 10)
    check("619 plugins: an event after saving → its status-bar item", ok, screen())
    ok = wait_for('the second save handler', 6)
    check("624 plugins: a second handler of the same event and pattern runs too", ok, screen())
    palette('Hello: problems')
    ok = wait_for('three letters here', 10)
    s = screen()
    check("619 plugins: its problem, a sign in the gutter, a note after a line",
          ok and '★' in s and "a plugin's note" in s, s)
    keys('C-g'); text('1:1'); keys('Enter'); time.sleep(0.3); keys('M-Enter')
    ok = wait_for('Quick fixes', 8)
    if ok:
        text('Make it four'); time.sleep(0.3); keys('Enter'); time.sleep(0.6)
    check("619 plugins: Alt+Enter offers its fix, which applies", ok and 'four DEF!' in screen(), screen())
    open(W + '/readme.md', 'w').write('# title\n')
    keys('C-p'); time.sleep(0.3); text('readme.md'); time.sleep(0.4); keys('Enter'); time.sleep(0.5)
    keys('End'); text(' more'); time.sleep(1.5)
    palette('Plugins panel')
    ok = wait_for('hello: opened readme.md', 8) and wait_for('hello: changed: # title more', 8)
    check("619 plugins: events when a file opens and after a pause in the typing (their log lines)", ok, screen())

def t_619_plugins_vim():
    # the commentary example (vim): gcc, gc with a motion, gc in visual mode, the ie text object, :Comment
    setup({"editor.vimMode": True})
    shutil.copytree(REPO + '/examples/plugins/commentary', CFG + '/ned/plugins/commentary')
    open(W + '/v.nim', 'w').write('let a = 1\nlet b = 2\nlet c = 3\n')
    start('v.nim', w=120, h=34); time.sleep(0.5)
    check("619 vim plugin: ready", plugins_ready(), screen())
    keys('Escape'); keys('g', 'g'); text('gcc'); time.sleep(1.0)
    check("619 vim plugin: gcc comments the line", wait_for('# let a = 1', 6), screen())
    text('u'); time.sleep(0.5)
    text('gcj'); time.sleep(1.0)
    s = screen()
    check("619 vim plugin: u (one undo step), then gcj comments two lines",
          '# # let a' not in s and '# let a = 1' in s and '# let b = 2' in s and '# let c' not in s, s)
    text('Vjgc'); time.sleep(1.0)
    s = screen()
    check("619 vim plugin: gc on a visual selection uncomments them", '# let' not in s, s)
    text(':Comment 3'); keys('Enter'); time.sleep(1.0)
    s = screen()
    check("619 vim plugin: :Comment 3", '# let a = 1' in s and '# let c = 3' in s, s)
    text('die'); time.sleep(1.0)
    keys(':'); text('w'); keys('Enter'); time.sleep(0.5)
    check("619 vim plugin: die — the ie text object (the whole text) deleted", ftext('v.nim').strip() == '',
          ftext('v.nim'))

def t_619_plugins_lsp_lang():
    # the wordinfo-lsp example: a language server written in NimScript (ned --lsp-bridge) — its diagnostics and
    # hover; zig-lite: a language ned does not have, formatted by a formatter written in NimScript
    setup()
    for ex in ['wordinfo-lsp', 'zig-lite']:
        shutil.copytree(REPO + '/examples/plugins/' + ex, CFG + '/ned/plugins/' + ex)
    open(W + '/fruit.txt', 'w').write('apple banana apple\nTODO: more apples\n')
    open(W + '/m.zig', 'w').write('const x = 1;   \n\n\n\n\tconst y = 2;\n')
    start('fruit.txt', w=140, h=40); time.sleep(0.5)
    check("619 plugins (lsp, language): ready", plugins_ready(), screen())
    keys('C-g'); text('2:1'); keys('Enter')
    ok = wait_for('a TODO: something left to do', 25)
    check("619 plugins: a NimScript language server's diagnostic", ok, screen())
    keys('C-g'); text('1:2'); keys('Enter'); time.sleep(0.3); keys('M-h')
    ok = wait_for('apple.{0,6}— 2 times', 10)
    check("619 plugins: … and its hover", ok, screen())
    keys('Escape')
    keys('C-p'); time.sleep(0.3); text('m.zig'); time.sleep(0.4); keys('Enter'); time.sleep(1.0)
    s = screen()
    check("619 plugins: zig-lite — the language (status bar)", ' Zig ' in s, s)
    palette('Format document'); time.sleep(1.5)
    keys('C-s'); time.sleep(0.5)
    t = ftext('m.zig')
    check("619 plugins: zig-lite — formatted by its NimScript formatter",
          t == 'const x = 1;\n\n    const y = 2;\n' or (shutil.which('zig') is not None), repr(t))

def t_628_plugin_server_after_save():
    # a plugin's language server that starts when a file of its language is first saved (Julia's: slow to start) —
    # opening the file starts nothing; the save starts it, and its diagnostics come
    setup()
    d = CFG + '/ned/plugins/later-lsp'
    shutil.copytree(REPO + '/examples/plugins/wordinfo-lsp', d)
    open(d + '/plugin.nims', 'w').write('## later-lsp — wordinfo-lsp, started after the first save\nimport nedplugin\n'
                                        'languageServerScript("plaintext", "server.nims", afterSave = true)\n')
    open(W + '/fruit.txt', 'w').write('apple banana apple\nTODO: more apples\n')
    start('fruit.txt', w=140, h=40); time.sleep(0.5)
    check("628 plugin server after save: ready", plugins_ready(), screen())
    keys('C-g'); text('2:1'); keys('Enter')
    time.sleep(4)
    check("628 plugin server after save: opening the file starts no server", 'a TODO' not in screen(), screen())
    keys('End'); text(' x'); keys('C-s')
    ok = wait_for("Starting Plain Text's language server|a TODO: something left to do", 10)
    check("628 plugin server after save: the save starts it", ok, screen())
    ok = wait_for('a TODO: something left to do', 25)
    check("628 plugin server after save: … and its diagnostics come", ok, screen())

def t_628_hastur_tests():
    # a Nim 3 project's tests, as Nimony's hastur runs them: a test file with what it should print beside it
    # (t1.output) is listed in the test explorer and run with hastur — ✓ and ✗ from what hastur says
    need('nimony')
    setup({"nim.compiler": "nimony", "nim.nimsuggest": None})
    os.makedirs(W + '/tests', exist_ok=True)
    open(W + '/tests/thello.nim', 'w').write('import std/syncio\necho "hello"\n')
    open(W + '/tests/thello.output', 'w').write('hello\n')
    open(W + '/tests/tbad.nim', 'w').write('import std/syncio\necho "bye"\n')
    open(W + '/tests/tbad.output', 'w').write('hello\n')
    start('tests/thello.nim', w=140, h=40); time.sleep(1)
    palette('Test explorer'); time.sleep(1.0)
    s = screen()
    check("628 hastur: a test with its .output listed in the test explorer", 'hastur' in s and 'thello.nim' in s and
          'tbad.nim' in s, s)
    palette('Run all tests')
    ok = wait_for(r'1 hastur test\(s\) failed', 180)
    s = screen()
    check("628 hastur: Run all tests runs them with hastur, and says which failed", ok and 'FAILURE' in s, s)
    check("628 hastur: its build files are not left in the project (no nimcache/)", not os.path.exists(W + '/nimcache'),
          str(os.listdir(W)))

def t_628_parser_check_fails():
    # nim.format.verify: a parser check that cannot be built says why — once, with where the whole output is — and is
    # not built again (and the message not shown again) at every format; the file is formatted all the same
    setup({"nim.format.verify": True})
    fake = W + '/fakenim'
    os.makedirs(fake + '/bin'); os.makedirs(fake + '/compiler')
    open(fake + '/compiler/parser.nim', 'w').write('# (a compiler source tree, as far as ned can tell)\n')
    open(fake + '/bin/nim', 'w').write('#!/bin/sh\necho "fake.nim(1, 1) Error: this nim cannot build it"\nexit 1\n')
    os.chmod(fake + '/bin/nim', 0o755)
    open(W + '/v3.nim', 'w').write('proc  g(a:int,b:int):int=\n  a+b\n')
    start('v3.nim', path=fake + '/bin:/usr/bin:/bin', env_extra='XDG_CACHE_HOME=' + W + '/cache')
    keys('M-f')
    ok = wait_for(r'Nim parser check not built: Error: this nim cannot build it', 20)
    s = screen()
    check("628 parser check: a build that fails says why (the compiler's error) and where its whole output is",
          ok and 'nedastcheck-build.log' in s, s)
    keys('C-s'); time.sleep(0.4)
    check("628 parser check: … the file is formatted all the same", ftext('v3.nim').startswith('proc g(a: int'),
          ftext('v3.nim'))
    # (its message closed; another format does not build it again)
    for _ in range(4):
        p = place_of('Nim parser check not built')
        if not p: break
        click(*p); time.sleep(0.3)
    keys('C-End'); text('\nproc  h()=discard\n'); keys('M-f'); time.sleep(4)
    s = screen()
    check("628 parser check: not built again (nor said again) at the next format", 'not built' not in s and
          'building the Nim parser check' not in s, s)

def t_629_move_boxes():
    # 6.29: a dialog, a form or a picker moves with its title bar dragged, and opens where it was left the next time
    setup()
    start('src/demo.nim', w=120, h=34)
    keys('C-p'); time.sleep(0.6)
    p = place_of('─ Open file')
    check('629 move: the picker is open', p is not None, screen())
    if not p: return
    x, y = p[0] + 15, p[1]
    press(x, y); drag(x, y + 2); drag(x, y + 5); release(x, y + 5)
    q = place_of('─ Open file')
    check('629 move: the picker follows its title bar', q and q[1] == p[1] + 5, '%s → %s\n%s' % (p, q, screen()))
    keys('Escape'); time.sleep(0.3); keys('C-p'); time.sleep(0.6)
    r = place_of('─ Open file')
    check('629 move: … and opens there again', r == q, '%s / %s\n%s' % (q, r, screen()))
    keys('Escape'); time.sleep(0.3)
    # a dialog (unsaved changes at quit)
    text('xx'); keys('C-q'); time.sleep(0.6)
    p = place_of('─ Unsaved changes')
    check('629 move: the dialog is open', p is not None, screen())
    if not p: return
    x, y = p[0] + 10, p[1]
    press(x, y); drag(x - 6, y - 3); drag(x - 12, y - 5); release(x - 12, y - 5)
    q = place_of('─ Unsaved changes')
    check('629 move: the dialog follows its title bar', q == (p[0] - 12, p[1] - 5), '%s → %s\n%s' % (p, q, screen()))
    keys('Escape'); time.sleep(0.3); keys('C-q'); time.sleep(0.6)
    r = place_of('─ Unsaved changes')
    check('629 move: … and opens there again', r == q, '%s / %s\n%s' % (q, r, screen()))
    # a click on the title bar alone moves nothing, and the dialog's buttons still work
    click(x - 12, y - 5)
    check('629 move: a click on the title moves nothing', place_of('─ Unsaved changes') == q, screen())
    keys('Escape'); time.sleep(0.3)

def kept_terminals_end():
    """end the terminals the tests kept running (terminal.keepRunning) in the scratch project"""
    import glob, signal
    for f in glob.glob(os.environ.get('TMPDIR', '/tmp') + '/ned-%d/term-*.json' % os.getuid()):
        try:
            j = json.load(open(f))
            if j.get('project', '').startswith(TMP): os.kill(j['shell'], signal.SIGKILL)
        except (OSError, ValueError, KeyError): pass

def t_629_kept_terminals():
    # 6.29 (terminal.keepRunning): a terminal's shell goes on after ned quits — what it runs still running — and the
    # next ned in the folder takes it back, with what it printed; Terminal: kill ends it for good
    kept_terminals_end()
    setup({"terminal.shell": "/bin/bash", "terminal.keepRunning": True})
    start('src/demo.nim')
    keys('C-\\'); time.sleep(1.2); text('echo kept-$$'); keys('Enter')
    wait_for(r'kept-\d+', 5)
    m = re.search(r'kept-(\d+)', screen())
    check('629 kept: the terminal runs a shell', m, screen())
    if not m: return
    pid = m.group(1)
    text('for i in $(seq 1 400); do echo $i > %s/tick; sleep 0.2; done' % W); keys('Enter'); time.sleep(0.8)
    keys('C-\\'); time.sleep(0.3); keys('C-q')
    for _ in range(30):
        if os.path.exists(W + '/exit'): break
        time.sleep(0.2)
    check('629 kept: ned quits', os.path.exists(W + '/exit') and 'EXITED 0' in open(W + '/exit').read(), screen())
    tm('kill-session', '-t', 'f'); time.sleep(0.5)          # (its window closed too)
    a = open(W + '/tick').read(); time.sleep(1.0); b = open(W + '/tick').read()
    check('629 kept: … and what ran in its terminal runs on', a != b and os.path.exists('/proc/' + pid), a + ' / ' + b)
    os.remove(W + '/exit')
    start('src/demo.nim')
    palette('Show recent messages'); time.sleep(0.6)
    s = screen()
    check('629 kept: the next ned says it took the terminal back', 'kept running since last time' in s, s)
    keys('Escape'); time.sleep(0.2)
    keys('C-\\'); time.sleep(1.0)
    check('629 kept: … with what it printed', 'kept-' + pid in screen(), screen())
    keys('C-c'); time.sleep(0.4); text('echo again-$$'); keys('Enter')
    check('629 kept: … the same shell, still running', wait_for('again-' + pid, 5), screen())
    keys('C-\\'); time.sleep(0.3)
    palette('Terminal: kept terminals…'); time.sleep(0.6)
    s = screen()
    check('629 kept: the kept terminals, listed', 'End bash in this folder' in s and 'End all 1' in s, s)
    keys('Escape'); time.sleep(0.2)
    palette('Terminal: kill'); time.sleep(1.5)
    keys('C-\\'); time.sleep(0.5)
    check('629 kept: Terminal: kill ends it for good', not os.path.exists('/proc/' + pid) and 'process exited' in screen(),
          screen())
    kept_terminals_end()

def t_629_remote_servers():
    # 6.29 (remote.languageServers): a remote folder's language server runs on the server — where its program is (not
    # here) — and sees the server's paths; what it answers comes back as the local copy's, and a file of the server's
    # outside the folder that it points to (F12) is fetched, to read
    need('ssh-server')
    srv = TMP + '/remote-srv/proj'
    shutil.rmtree(TMP + '/remote-srv', ignore_errors=True)
    os.makedirs(srv); os.makedirs(TMP + '/remote-srv/lib')
    open(srv + '/hello.py', 'w').write('import helper\nhelper.go()\n')
    open(TMP + '/remote-srv/lib/helper.py', 'w').write('def go():\n    print("on the server only")\n')
    log = TMP + '/remote-srv/ls.log'
    # the server's program: in ~/.local/bin, on the server's PATH (a login's) and not on this ned's
    bindir = os.path.expanduser('~/.local/bin')
    os.makedirs(bindir, exist_ok=True)
    exe = bindir + '/ned-test-remotels'
    open(exe, 'w').write('#!/bin/sh\nexec python3 %s "$@"\n' % (MOCKS + '/mockremotels.py'))
    os.chmod(exe, 0o755)
    SP = SSH_DIR + ':' + TOOLS + ':/usr/bin:/bin'
    sh('for c in ' + SSH_CTL + '/*; do ' + SSH_DIR + '/ssh -o ControlPath=$c -O exit x 2>/dev/null; done; rm -f ' + SSH_CTL + '/*')
    try:
        setup({"lsp": {"python": ["ned-test-remotels", log, TMP + '/remote-srv/lib/helper.py']}})
        start('src/demo.nim', w=130, h=40, path=SP); time.sleep(0.5)
        palette('Remote: open a folder over SSH'); time.sleep(0.3); text('devbox:' + srv); keys('Enter')
        check('629 remote servers: the folder opens', wait_for('every save goes', 30), screen())
        keys('C-p'); time.sleep(0.3); text('hello.py'); time.sleep(0.4); keys('Enter')
        ok = wait_for('seen at', 15)
        l = open(log).read() if os.path.exists(log) else ''
        check('629 remote servers: it runs on the server, told the folder there', 'rootUri=file://' + srv in l and
              'processId=null' in l, l)
        check('629 remote servers: … and the file by its path there', 'didOpen file://' + srv + '/hello.py' in l, l)
        palette('Show problems'); time.sleep(0.8)
        s = screen()
        check('629 remote servers: its problem is on the file here', ok and 'seen at ' in s and 'hello.py' in s, s)
        keys('Escape'); time.sleep(0.2)
        keys('C-g'); text('2:2'); keys('Enter'); keys('F12')
        ok = wait_for('on the server only', 15)
        s = screen()
        check('629 remote servers: F12 into a file of the server\'s outside the folder: fetched, to read', ok and
              'helper.py' in s, s)
        text('x'); time.sleep(0.3)
        check('629 remote servers: … read-only', 'xdef go' not in screen() and 'def go' in screen(), screen())
    finally:
        os.remove(exe)

def tiny_png(path, w=8, h=6, rgb=(200, 40, 40)):
    """a small PNG of one colour"""
    import zlib, struct
    raw = b''.join(b'\x00' + bytes(rgb) * w for _ in range(h))
    def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) +
                           chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))

def t_629_ai_pictures():
    # 6.29: a picture with a message (@shot.png, a pasted path, AI: attach a picture…) goes to the model as a picture —
    # OpenAI's image_url, Anthropic's image — and the chat shows it; one too big or of another kind is said why
    import base64
    setup()
    tiny_png(W + '/shot.png')
    open(W + '/notes.bmp', 'wb').write(b'BM' + b'\0' * 60)
    data = base64.b64encode(open(W + '/shot.png', 'rb').read()).decode()
    start('src/demo.nim', w=130, h=40)
    keys('M-c'); time.sleep(0.4); text('what is in '); paste(W + '/shot.png'); time.sleep(0.4)
    check('629 pictures: a pasted picture path becomes @shot.png: it goes with the message',
          'The picture goes with the message' in screen(), screen())
    keys('Enter')
    wait_for('You said', 8); time.sleep(0.5)
    log = open(MOCK_LOG).read().splitlines()
    body = json.loads(log[-1])['body'] if log else {}
    um = [m for m in body.get('messages', []) if m.get('role') == 'user']
    c = um[-1]['content'] if um else ''
    ok = isinstance(c, list) and any(x.get('type') == 'image_url' and x['image_url']['url'] == 'data:image/png;base64,' + data
                                      for x in c) and any(x.get('type') == 'text' and 'what is in' in x.get('text', '') for x in c)
    check('629 pictures: sent as a picture (OpenAI: image_url, data:image/png;base64)', ok, json.dumps(c)[:600])
    s = screen()
    check('629 pictures: the chat shows it (drawn, its name and size)', '▣ shot.png' in s and '8×6' in s and '▀' in s, s)
    # Anthropic: an image block before the text
    keys('C-l'); time.sleep(0.3)
    setup({"ai.provider": "anthropic", "ai.model": "claude-test"})
    tiny_png(W + '/shot.png')
    start('src/demo.nim', w=130, h=40)
    keys('M-c'); time.sleep(0.4); text('and now '); paste(W + '/shot.png'); time.sleep(0.3); keys('Enter')
    time.sleep(2.5)
    log = open(MOCK_LOG).read().splitlines()
    body = json.loads(log[-1])['body'] if log else {}
    um = [m for m in body.get('messages', []) if m.get('role') == 'user']
    c = um[-1]['content'] if um else ''
    ok = isinstance(c, list) and c and c[0].get('type') == 'image' and c[0]['source'] == {
        'type': 'base64', 'media_type': 'image/png', 'data': data} and c[-1].get('type') == 'text'
    check('629 pictures: Anthropic: an image block, then the text', ok, json.dumps(c)[:600])
    # a pasted path; a kind the assistants do not read
    setup()
    tiny_png(W + '/shot.png')
    open(W + '/notes.bmp', 'wb').write(b'BM' + b'\0' * 60)
    start('src/demo.nim', w=130, h=40)
    keys('M-c'); time.sleep(0.4)
    paste("'" + W + "/notes.bmp'"); time.sleep(0.4)
    check('629 pictures: a pasted path in quotes too (a BMP: said why it will not go)',
          'notes.bmp: the assistant takes PNG' in screen(), screen())
    keys('Enter'); time.sleep(1.0)
    palette('Show recent messages'); time.sleep(0.6)
    check('629 pictures: a BMP is not sent, and ned says why', 'PNG, JPEG, GIF and WebP' in screen(), screen())
    keys('Escape'); time.sleep(0.2)
    palette('AI: attach a picture…'); time.sleep(0.6)
    s = screen()
    check('629 pictures: AI: attach a picture… lists the project\'s', 'shot.png' in s and '8×6' in s, s)

def t_629_jinja():
    # 6.29: Jinja-style templates (Nimja's .nimja, Jinja's .j2): HTML, with {{ }} and {% %} coloured as Nim, the
    # statement words (extends, endfor …) as keywords, {# #} as a comment
    setup({"theme": "one-dark", "editor.languageServerHints": False, "nim.ide": "off"})
    open(W + '/page.nimja', 'w').write('{% extends "base.nimja" %}\n{# a comment here #}\n<ul class="list">\n'
                                       '{% for item in items %}\n  <li>{{ item.name.toUpperAscii() }}</li>\n'
                                       '{% endfor %}\n</ul>\n')
    start('page.nimja', w=110, h=30); time.sleep(1.5)
    m = fg_map(tm('capture-pane', '-t', 'f', '-e', '-p').stdout)
    kw, tag = fg_of(m, 'for item'), fg_of(m, '<ul', 1)
    check('629 jinja: {% for … %} is Nim (for: a keyword, not as the name after it)',
          kw is not None and kw != fg_of(m, 'item in'), str((kw, fg_of(m, 'item in'))))
    check('629 jinja: extends and endfor are keywords', fg_of(m, 'extends') == kw and fg_of(m, 'endfor') == kw,
          str((fg_of(m, 'extends'), fg_of(m, 'endfor'), kw)))
    check('629 jinja: the rest is HTML', fg_of(m, '<li', 1) == tag, str((fg_of(m, '<li', 1), tag)))
    check('629 jinja: {# … #} is a comment', fg_of(m, 'a comment') == fg_of(m, '{# a') and
          fg_of(m, 'a comment') not in (tag, kw, None), str((fg_of(m, 'a comment'), fg_of(m, '{# a'))))
    check('629 jinja: {{ … }} stands out from the text', fg_of(m, 'toUpperAscii') not in (tag, None),
          str(fg_of(m, 'toUpperAscii')))
    check('629 jinja: the status bar names it', 'Jinja template' in screen(), screen()[-300:])

def last_ai_user_text():
    """the newest request's last user message, as text"""
    lines = open(MOCK_LOG).read().splitlines() if os.path.exists(MOCK_LOG) else []
    if not lines: return ''
    body = json.loads(lines[-1])['body']
    for m in reversed(body.get('messages', [])):
        if m.get('role') == 'user':
            c = m.get('content')
            return ' '.join(x.get('text', '') for x in c if isinstance(x, dict)) if isinstance(c, list) else (c or '')
    return ''

def t_629_ai_git():
    # 6.29: the assistant with git — why a line changed (its commit, explained in the chat); a file's merge conflicts
    # resolved by it, checked by the compiler and shown side by side to take
    setup()
    open(W + '/src/demo/utils.nim', 'a').write('\nproc why*(): int = 42   # WHYLINE\n')
    git('add -A'); git('-c user.name=t -c user.email=t@t commit -qm "Add why, the answer"')
    n = open(W + '/src/demo/utils.nim').read().split('\n').index('proc why*(): int = 42   # WHYLINE') + 1
    start('src/demo/utils.nim', w=130, h=40)
    keys('C-g'); text(str(n)); keys('Enter'); time.sleep(0.3)
    palette('Git: why did this line change? (AI)')
    ok = wait_for('You said', 12)
    u = last_ai_user_text()
    check('629 ai git: why a line changed — its commit goes to the assistant', ok and '<commit>' in u and
          'Add why, the answer' in u and 'WHYLINE' in u, u[-600:])
    check('629 ai git: … and the chat says which commit', 'Why did line %d of utils.nim change?' % n in screen(),
          screen())
    keys('Escape'); time.sleep(0.2)
    open(W + '/src/merged.nim', 'w').write('proc a*(): int = 1\n<<<<<<< HEAD\nproc b*(): int = 2\n=======\n'
                                          'proc c*(): int = 3\n>>>>>>> other\n')
    keys('C-p'); text('src/merged.nim'); time.sleep(0.6); keys('Enter'); time.sleep(0.6)
    palette('Git: resolve the conflicts with AI')
    ok = wait_for('Take it', 20)
    s = screen()
    check('629 ai git: the resolution, side by side, checked by the compiler', ok and 'the compiler finds no error' in s,
          s)
    keys('Enter'); time.sleep(0.6); keys('C-s'); time.sleep(0.4)
    t = ftext('src/merged.nim')
    check('629 ai git: … taken: both sides, no conflict marks', 'proc b*' in t and 'proc c*' in t and '<<<<' not in t, t)

def t_629_code_from_comments():
    # 6.29: a comment says what to write — ✦ (or Alt+Shift+C on it) and the assistant writes it below, checked by the
    # compiler and shown side by side first; a comment ending in AI! is acted on at save
    setup()
    open(W + '/src/calc.nim', 'w').write('proc twice*(x: int): int = x * 2\n\n# triple a number\n')
    start('src/calc.nim', w=130, h=40)
    keys('C-g'); text('3'); keys('Enter'); time.sleep(0.4)
    check('629 comments: ✦ write it after the comment the cursor is on', '✦ write it' in screen(), screen())
    keys('M-C')
    ok = wait_for('Take it', 20)
    s = screen()
    check('629 comments: Alt+Shift+C: the code, side by side, checked', ok and 'the compiler finds no error' in s, s)
    keys('Enter'); time.sleep(0.6); keys('C-s'); time.sleep(0.4)
    t = ftext('src/calc.nim')
    check('629 comments: … taken: the code below the comment', '# triple a number\nproc triple*' in t, t)
    keys('C-End'); text('\n# make twice use a shift AI!'); keys('C-s')
    ok = wait_for('Take it', 20)
    check('629 comments: AI! at save: the change it asks for, shown', ok and 'AI!' in screen(), screen())
    keys('Enter'); time.sleep(0.6); keys('C-s'); time.sleep(0.4)
    t = ftext('src/calc.nim')
    check('629 comments: … taken: done, and the AI! comment gone', 'x shl 1' in t and 'AI!' not in t, t)

def t_629_plugin_updates():
    # 6.29: a plugin's version and author (pluginInfo) in the Plugins dock; Check for updates sees a newer version in
    # its repository; Update brings it; Roll back takes it back; a pinned plugin is left alone
    setup()
    origin = TMP + '/plug-origin'
    shutil.rmtree(origin, ignore_errors=True); os.makedirs(origin)
    src = ('## upd — a plugin to update\nimport nedplugin\n\npluginInfo(version = "%s", author = "Tester", '
           'license = "MIT")\n\ncommand("Upd: hello"):\n  message("hello %s")\n')
    open(origin + '/plugin.nims', 'w').write(src % ('1.0.0', '1.0.0'))
    sh('cd %s && git init -q -b main && git add -A && git -c user.name=t -c user.email=t@t commit -qm one' % origin)
    shutil.rmtree(CFG + '/ned/plugins/upd', ignore_errors=True)
    sh('git clone -q %s %s' % (origin, CFG + '/ned/plugins/upd'))
    start('src/demo.nim', w=130, h=40)
    palette('Plugins panel'); time.sleep(1.5)
    s = screen()
    check('629 plugin updates: the dock shows its version', 'upd' in s and '1.0.0' in s, s)
    open(origin + '/plugin.nims', 'w').write(src % ('1.1.0', '1.1.0'))
    sh('cd %s && git -c user.name=t -c user.email=t@t commit -qam two' % origin)
    palette('Plugins: check for updates')
    ok = wait_for(r'upd 1\.0\.0 → 1\.1\.0', 15)
    check('629 plugin updates: Check for updates: 1.0.0 → 1.1.0', ok, screen())
    palette('Plugins: update (git pull)')
    ok = wait_for('Updated: upd', 15)
    time.sleep(1.0)
    check('629 plugin updates: updated', ok and 'version = "1.1.0"' in open(CFG + '/ned/plugins/upd/plugin.nims').read(),
          screen())
    palette('Upd: hello'); time.sleep(1.0)
    check('629 plugin updates: … and running as 1.1.0', wait_for('hello 1.1.0', 8), screen())
    # roll back, through the plugin's menu in the dock
    palette('Plugins panel'); time.sleep(1.0)
    p = place_of('upd ')
    if p: click(p[0] + 1, p[1]); time.sleep(0.6)
    s = screen()
    check('629 plugin updates: its menu: who made it, roll back, pin', '1.1.0 · Tester · MIT' in s and
          'Roll back to 1.0.0' in s and 'Pin at 1.1.0' in s, s)
    p = place_of('Roll back to 1.0.0')
    if p: click(p[0] + 1, p[1]); time.sleep(2.0)
    check('629 plugin updates: rolled back to 1.0.0', 'version = "1.0.0"' in open(CFG + '/ned/plugins/upd/plugin.nims').read(),
          screen())
    p = place_of('Pin')
    if p: click(p[0] + 1, p[1]); time.sleep(0.8)
    c = open(CFG + '/ned/config.json').read()
    check('629 plugin updates: pinned (kept in plugins.pinned)', '"upd"' in c and 'pinned' in c, c[-400:])
    palette('Plugins: update (git pull)'); time.sleep(2.0)
    check('629 plugin updates: a pinned plugin is left alone', 'version = "1.0.0"' in open(CFG + '/ned/plugins/upd/plugin.nims').read(),
          screen())

def t_629_git_watch():
    # 6.29: git status when something changes, not every few seconds: a file staged or committed from outside ned
    # shows in the Git dock at once
    setup()
    start('src/demo.nim', w=130, h=40)
    keys('M-g'); time.sleep(1.5)
    open(W + '/src/demo.nim', 'a').write('# changed outside\n')
    git('add src/demo.nim')
    ok = wait_for('STAGED CHANGES', 4)
    check('629 git watch: a stage from outside ned shows at once', ok, screen())
    git('-c user.name=t -c user.email=t@t commit -qm outside')
    ok = wait_for('Working tree clean', 4)
    check('629 git watch: … and a commit', ok, screen())

def t_629_update():
    # 6.29: ned --update — whether a newer release is out (GitHub's list of releases; here a file in its place), and
    # how it would be installed; nothing is run without asking
    rel = TMP + '/release.json'
    json.dump({"tag_name": "v99.1.0", "assets": [{"name": "ned_99.1.0_aarch64.deb",
               "browser_download_url": "https://example.invalid/ned_99.1.0_aarch64.deb"}]}, open(rel, 'w'))
    r = subprocess.run([BIN, '--update', '--check'], capture_output=True, text=True, env=dict(os.environ, NED_UPDATE_URL=rel))
    check('629 update: --check says a newer release is out', r.returncode == 0 and 'ned 99.1.0 is out' in r.stdout, r.stdout + r.stderr)
    r = subprocess.run([BIN, '--update'], capture_output=True, text=True, input='n\n',
                       env=dict(os.environ, NED_UPDATE_URL=rel))
    check('629 update: it says what it would run (or the ways to get it), and changes nothing unasked',
          ('It will run:' in r.stdout and 'Nothing changed' in r.stdout) or 'Any of these brings 99.1.0' in r.stdout,
          r.stdout + r.stderr)
    json.dump({"tag_name": "v1.0.0"}, open(rel, 'w'))
    r = subprocess.run([BIN, '--update'], capture_output=True, text=True, env=dict(os.environ, NED_UPDATE_URL=rel))
    check('629 update: an older release is not one to install', r.returncode == 0 and 'This is the newest' in r.stdout,
          r.stdout + r.stderr)

def t_629_telescope():
    # 6.29: Telescope (Alt+Shift+F) — a list of finders, each a picker with its preview beside it: live grep (the
    # file at the line), settings (what one does, its default), git commits (the change); Telescope: resume opens
    # the last finder again with what was typed
    setup()
    start('src/demo.nim', w=150, h=40)
    keys('M-F')
    ok = wait_for('Telescope — what to find', 4)
    s = screen()
    check('629 telescope: Alt+Shift+F lists the finders, the selected one explained beside them',
          ok and 'Live grep' in s and 'Git: commits' in s and 'Settings' in s and 'The project' in s, s)
    text('settings'); time.sleep(0.4); keys('Enter')
    ok = wait_for('Settings — Enter opens', 4)
    text('editor.tabsize'); time.sleep(0.6)
    s = screen()
    check("629 telescope: settings — each one's description, value and default beside it",
          ok and 'Default:' in s and 'Now:' in s, s)
    keys('Escape'); time.sleep(0.3)
    keys('M-F'); wait_for('Telescope — what to find', 4)
    text('git: commits'); time.sleep(0.4); keys('Enter')
    ok = wait_for('Git: commits — the change', 4) and wait_for(r'diff --git|demo\.nimble *\|', 6)
    check('629 telescope: git commits — the change of the selected one beside it', ok, screen())
    keys('Escape'); time.sleep(0.3)
    keys('M-F'); wait_for('Telescope — what to find', 4)
    text('live grep'); time.sleep(0.4); keys('Enter')
    wait_for('Live grep — type', 4)
    text('greet'); time.sleep(0.2)
    ok = wait_for('lines with “greet”', 6)
    s = screen()
    check('629 telescope: live grep — the lines found as you type, the file at the line beside them',
          ok and 'src/demo.nim:4' in s and 'proc greet*' in s, s)
    keys('Escape'); time.sleep(0.3)
    palette('Telescope: resume')
    ok = wait_for('lines with “greet”', 6)
    check('629 telescope: resume — the last finder again, with what was typed', ok, screen())
    keys('Enter'); time.sleep(0.5)
    s = screen()
    check('629 telescope: Enter goes to the line', re.search(r'Ln [49], Col', s) is not None and 'demo.nim' in s, s)

def t_629_cursor_glide():
    # 6.29: ui.cursorAnimation — a jump of the cursor glides there with a fading trail (frames of its own, only the
    # trail's cells), then the cursor shows where it went; a step of one column does not glide; off: no trail
    setup({"ui.cursorAnimation": "glide", "ui.cursorAnimationMs": 300, "ui.cursorStyle": "block"})
    log = TMP + '/perf-glide.txt'
    if os.path.exists(log): os.remove(log)
    start('src/demo.nim', w=120, h=34, env_extra='NED_PERF_LOG=' + log)
    time.sleep(0.5)
    base = screen().count('█')
    tm('send-keys', '-t', 'f', 'C-End')
    trail, end = 0, time.time() + 0.5
    while time.time() < end:
        trail = max(trail, screen().count('█') - base)
    time.sleep(0.5)
    s = screen()
    check('629 cursor glide: a jump to the end of the file draws a trail on the way', trail >= 2, (trail, s))
    check('629 cursor glide: … gone when the cursor has arrived', s.count('█') == base and
          re.search(r'Ln 1[01], Col', s) is not None, s)
    tm('send-keys', '-t', 'f', 'Left')
    small, end = 0, time.time() + 0.4
    while time.time() < end:
        small = max(small, screen().count('█') - base)
    check('629 cursor glide: a step of one column does not glide', small == 0, small)
    keys('C-q'); time.sleep(1.0)
    for k in ('Escape', 'n', 'Enter'):
        if os.path.exists(log): break
        keys(k); time.sleep(0.6)
    t = open(log).read() if os.path.exists(log) else ''
    check('629 cursor glide: the performance report counts the glides and their frames',
          re.search(r'Cursor glides: [1-9]\d* \([1-9]\d* frames of their own', t) is not None, t[:1500])
    setup({"ui.cursorAnimation": "off", "ui.cursorStyle": "block"})
    start('src/demo.nim', w=120, h=34)
    time.sleep(0.5)
    base = screen().count('█')
    tm('send-keys', '-t', 'f', 'C-End')
    trail, end = 0, time.time() + 0.4
    while time.time() < end:
        trail = max(trail, screen().count('█') - base)
    check('629 cursor glide: off — the cursor jumps, no trail', trail == 0, trail)

def bg_at_col(row, k):
    """the 24-bit background colour at column k of an ANSI row, or None"""
    bg, col, i = None, 0, 0
    while i < len(row):
        m = re.match(r'\x1b\[([0-9;:]*)m', row[i:])
        if m:
            ps = m.group(1).split(';')
            j = 0
            while j < len(ps):
                if ps[j] == '48' and j + 4 < len(ps) and ps[j + 1] == '2':
                    bg = tuple(ps[j + 2:j + 5]); j += 5
                elif ps[j] in ('0', '49', ''):
                    bg = None; j += 1
                elif ps[j] in ('38', '58') and j + 4 < len(ps) and ps[j + 1] == '2':
                    j += 5
                else: j += 1
            i += m.end(); continue
        if col == k: return bg
        col += 1; i += 1
    return None

def t_629_engine_highlights():
    # 6.29: the other uses of the name under the cursor marked by what it names (ned's engines, as clangd's document
    # highlights): a local of another proc (another C function) with the same name is left alone
    setup({"nim.nimsuggest": False, "c.engine": "builtin", "editor.hoverDelay": 10000})
    open(W + '/hl.nim', 'w').write('proc first(): int =\n  var count = 1\n  count += 1\n  count\n\n'
                                  'proc second(): int =\n  var count = 2\n  count\n')
    open(W + '/hl.c', 'w').write('int first(void) {\n  int count = 1;\n  count += 1;\n  return count;\n}\n\n'
                                'int second(void) {\n  int count = 2;\n  return count;\n}\n')
    for f in ('hl.nim', 'hl.c'):
        start(f, w=110, h=30)
        keys('C-g'); text('2:9'); keys('Enter'); time.sleep(1.2)
        rows = screen_ansi().split('\n')
        plain = [re.sub(r'\x1b\[[0-9;:]*m', '', r) for r in rows]
        def bg_of(line_no):
            for r, t in zip(rows, plain):
                m = re.match(r'^[^0-9]*?(\d+)\s', t)
                if m is not None and int(m.group(1)) == line_no and 'count' in t:
                    return bg_at_col(r, t.index('count'))
            return 'missing'
        own, other_bg = bg_of(3), bg_of(8 if f == 'hl.nim' else 9)
        check('629 engine highlights (%s): the uses of this local are marked, the same name in the other routine is not'
              % f, own not in (None, 'missing') and other_bg != own and other_bg != 'missing',
              repr((own, other_bg)) + '\n' + '\n'.join(plain[:14]))
        tm('kill-server'); time.sleep(0.3)

def t_629_click_over_minimap():
    # 6.29 (Foxoman's bug): a box drawn over the minimap — the find and replace bar — took no clicks there: its ×
    # did not close it, the minimap under it jumped instead
    setup({"ui.minimap": "on"})
    open(W + '/long.nim', 'w').write(''.join('let value%d = %d  # a line long enough to fill the minimap\n' % (i, i)
                                             for i in range(400)))
    start('long.nim', w=150, h=40)
    keys('C-r'); time.sleep(0.4); text('value'); time.sleep(0.5)
    s = screen()
    rows = s.split('\n')
    y = next((i for i, l in enumerate(rows) if ' of ' in l and 'Aa' in l), -1)
    x = rows[y].rfind('×') if y >= 0 else -1
    check('629 click over the minimap: the find bar\'s × lies over the minimap', y >= 0 and x > 120, s)
    click(x + 1, y + 1); time.sleep(0.4)
    s = screen()
    check('629 click over the minimap: the × closes the bar (the minimap under it does not jump)',
          ' of ' not in s.split('\n')[y] and 'value0' in s, s)

def t_629_indent_plugins():
    # 6.29: indent-dots — a dot in each space of the indentation, up to the first letter, none between words, a blank
    # line's as deep as the code around it; rainbow-indent — each level a band of its own colour (ned draws both)
    setup({"plugins.bundled": ["indent-dots", "rainbow-indent"], "editor.indentGuides": False})
    for p in ('indent-dots', 'rainbow-indent'):       # (their on/off from an earlier run: in their data folder)
        shutil.rmtree(os.path.join(os.environ.get('XDG_DATA_HOME', os.path.expanduser('~/.local/share')), 'ned',
                                   'plugins', p), ignore_errors=True)
    open(W + '/ind.py', 'w').write('def f(x):\n    if x:\n        print("a  b")\n\n    return 1\n')
    start('ind.py', w=110, h=30)
    ok = wait_for(r'········print', 30)
    s = screen()
    check('629 indent dots: · in the indentation up to the first letter, not between the words', ok and
          'print("a  b")' in s and '····if x:' in s and '····return' in s, s)
    rows = s.split('\n')
    blank = next((l for l in rows if re.match(r'^[^0-9]*4\s', l)), '')
    check('629 indent dots: a blank line\'s dots as deep as the code around it', '····' in blank and '·····' not in blank,
          blank)
    def bands_now():
        row = ansi_row('print("a  b")')
        plain = re.sub(r'\x1b\[[0-9;:]*m', '', row)
        k = plain.find('········print')
        return k, [bg_at_col(row, k), bg_at_col(row, k + 4)], bg_at_col(row, plain.find('print') + 1), plain
    good = lambda r: r[0] >= 0 and None not in r[1] and r[1][0] != r[1][1] and r[2] not in r[1]
    wait_until(lambda: good(bands_now()), 10)          # (the plugins start one after the other)
    k, bands, after, plain = bands_now()
    check('629 rainbow indent: each level its own band, the text after them on the plain background',
          good((k, bands, after, plain)), repr((bands, after)) + '\n' + plain)
    palette('Rainbow indent: on/off'); time.sleep(1.0)
    row = ansi_row('print("a  b")')
    plain = re.sub(r'\x1b\[[0-9;:]*m', '', row)
    check('629 rainbow indent: off — no bands (the dots stay)',
          bg_at_col(row, k) == bg_at_col(row, k + 4) and '········print' in plain, plain)

def t_630_themes():
    # 6.30: Shades of Purple, ClassicBlue and the Nebula themes; a theme left out (molokai) gives the one it was, with
    # no warning; theme.trueBlack puts a dark theme on true black, its syntax colours kept
    def bg_of_code():
        row = ansi_row('import demo')
        plain = re.sub(r'\x1b\[[0-9;:]*m', '', row)
        return bg_at_col(row, plain.find('import') + 2), fg_at(row, 'import')
    for th, bg in (("shades-of-purple", ('45', '43', '85')), ("classic-blue", ('62', '48', '139')),
                   ("nebula-pulse", ('30', '35', '64')), ("molokai", ('39', '40', '34'))):
        setup({"theme": th, "nim.nimsuggest": False})
        start('src/demo.nim', w=120, h=30); time.sleep(0.6)
        got, _ = bg_of_code()
        s = screen()
        check('630 themes: %s — its background%s' % (th, ' (monokai\'s: molokai was the same theme)' if th == 'molokai'
                                                      else ''), got == bg and 'not one of' not in s, (got, s[-400:]))
    setup({"theme": "nebula-pulse", "theme.trueBlack": True, "nim.nimsuggest": False})
    start('src/demo.nim', w=120, h=30); time.sleep(0.6)
    got, kw = bg_of_code()
    check('630 themes: theme.trueBlack — the editor on true black, the keywords in the theme\'s colour',
          got in (None, ('0', '0', '0')) and kw == ('198', '120', '221'), (got, kw))
    keys('M-t'); time.sleep(0.5); text('nebula'); time.sleep(0.4)
    s = screen()
    check('630 themes: the theme list has the Nebula themes, not the ones left out',
          'nebula-nova' in s and 'nebula-dawn' in s, s)
    keys('Escape'); time.sleep(0.2)
    keys('M-t'); time.sleep(0.5); text('molokai'); time.sleep(0.4)
    s = screen()
    check('630 themes: … molokai is not in it', 'molokai' not in s.replace('› molokai', ''), s)
    keys('Escape')

def t_631_tiling():
    # 6.31: tiled panes — three side by side, one cut in two, a divider dragged, the pane to the right by keys and by a
    # click on its header, one pane alone (zoom) and back, a pane closed; the layout back the next time; vim's Ctrl+W;
    # on a phone held upright two panes one above the other
    setup({"nim.nimsuggest": False})
    start('src/demo/utils.nim', 'src/demo/types.nim', 'src/demo.nim', w=150, h=40)
    def div_cols():
        # (a divider: the same column holds │ on every row of the editor)
        body = screen().split('\n')[6:30]
        n = min(len(r) for r in body)
        return [c for c in range(n) if all(r[c] == '│' for r in body)]
    def header_row():
        for i, r in enumerate(screen().split('\n')[2:8]):
            if r.count('.nim') >= 2: return i + 2, r
        return -1, ''
    palette('View: panes: three columns'); time.sleep(0.6)
    hy, hdr = header_row()
    check('631 tiling: three panes side by side, each with its file',
          'demo.nim' in hdr and 'utils.nim' in hdr and 'types.nim' in hdr and len(div_cols()) == 2, screen())
    # the pane to the right (Ctrl+Alt+Shift+→): typing goes to utils.nim
    keys('C-M-S-Right'); time.sleep(0.3)
    keys('C-Home'); text('# tiled'); keys('Enter'); keys('C-s'); time.sleep(0.5)
    check('631 tiling: Ctrl+Alt+Shift+→ — the pane to the right takes the typing',
          ftext('src/demo/utils.nim').startswith('# tiled') and not ftext('src/demo.nim').startswith('# tiled'),
          ftext('src/demo/utils.nim')[:80])
    # a click on the third pane's header: typing goes to types.nim
    hy, hdr = header_row()
    x = hdr.find('types.nim')
    click(x + 3, hy + 1); time.sleep(0.3)
    keys('C-Home'); text('# third'); keys('Enter'); keys('C-s'); time.sleep(0.5)
    check('631 tiling: a click on a pane\'s header gives it the focus', ftext('src/demo/types.nim').startswith('# third'),
          ftext('src/demo/types.nim')[:80])
    # split down: a divider across that pane only
    palette('View: split editor down'); time.sleep(0.5)
    cols = div_cols()
    rows = screen().split('\n')
    across = [i for i, r in enumerate(rows[4:36]) if len(cols) == 2 and len(r) > cols[1] + 4 and
              set(r[cols[1] + 2:cols[1] + 12]) == {'─'}]
    check('631 tiling: split down — one pane cut in two, the others as they were', len(cols) == 2 and across, screen())
    keys('M-|'); time.sleep(0.4)
    rows = screen().split('\n')
    across = [i for i, r in enumerate(rows[4:36]) if len(r) > cols[1] + 4 and set(r[cols[1] + 2:cols[1] + 12]) == {'─'}]
    check('631 tiling: Alt+| closes the pane, its place goes back', not across and len(div_cols()) == 2, screen())
    # the first divider dragged to the left
    before = div_cols()
    c = before[0] + 1
    press(c, 15); drag(c - 5, 15); drag(c - 10, 15); release(c - 10, 15); time.sleep(0.3)
    after = div_cols()
    check('631 tiling: a divider dragged moves it, the other stays',
          len(after) == 2 and after[0] <= before[0] - 8 and after[1] == before[1], str((before, after)))
    # one pane alone and back
    palette('View: this pane alone (zoom)'); time.sleep(0.4)
    z = div_cols()
    palette('View: this pane alone (zoom)'); time.sleep(0.4)
    check('631 tiling: zoom shows the pane alone, again every pane', z == [] and len(div_cols()) == 2, str((z, div_cols())))
    # the layout the next time
    keys('C-q'); time.sleep(1.0)
    tm('kill-server'); time.sleep(0.3)
    if os.path.exists(W + '/exit'): os.remove(W + '/exit')
    start(w=150, h=40); time.sleep(0.8)
    hy, hdr = header_row()
    check('631 tiling: the three panes back when the folder opens again',
          len(div_cols()) == 2 and 'demo.nim' in hdr and 'types.nim' in hdr, screen())
    # vim: Ctrl+W v splits, Ctrl+W l / h move, Ctrl+W q closes
    setup({"nim.nimsuggest": False, "editor.vimMode": True})
    start('src/demo.nim', w=150, h=40)
    keys('C-w'); keys('v'); time.sleep(0.4)
    two = len(div_cols())
    keys('C-w'); keys('q'); time.sleep(0.4)
    check('631 tiling: vim — Ctrl+W v splits, Ctrl+W q closes the pane', two == 1 and div_cols() == [], str(two) + screen())
    # a phone held upright: two panes one above the other
    setup({"nim.nimsuggest": False})
    start('src/demo.nim', w=56, h=40)
    keys('M-\\'); time.sleep(0.5)
    rows = screen().split('\n')
    check('631 tiling: a narrow screen puts two panes one above the other',
          any(r.count('─') > 40 for r in rows[4:36]) and div_cols() == [], screen())

def t_631_multibuffer():
    # 6.31: a multibuffer numbers its lines as their files do; follows its files while it has no edits of its own;
    # a piece grows with more lines, goes out; an edit saved lands where the piece is now; the selection of a file
    # added to it; F12 in it goes to the definition through the file
    setup({"nim.nimsuggest": False})
    start('src/demo/utils.nim', 'src/demo.nim', w=150, h=40)
    keys('M-s'); time.sleep(0.3)
    for _ in range(20): keys('BSpace')
    text('shout'); keys('Enter'); time.sleep(1.5)
    palette('Open results in a multibuffer'); time.sleep(0.6)
    s = screen()
    check('631 multibuffer: the lines numbered as in their files', re.search(r'\b3 .{0,4}proc shout\*', s), s)
    # the file changed in its own tab: the multibuffer follows (it has no edits of its own)
    keys('M-1'); time.sleep(0.3)
    keys('C-Home'); text('# top'); keys('Enter'); keys('C-s'); time.sleep(0.4)
    palette('Multibuffer: show the one in use'); time.sleep(1.2)
    s = screen()
    check('631 multibuffer: a line added above a piece in its file moves the piece', re.search(r'\b4 .{0,4}proc shout\*', s) and
          'utils.nim  line 3' in s, s)
    # more lines below the piece
    keys('C-f'); time.sleep(0.2)
    for _ in range(20): keys('BSpace')
    text('proc shout'); keys('Enter'); keys('Escape'); time.sleep(0.3)
    palette('Multibuffer: more lines below this piece'); time.sleep(0.5)
    check('631 multibuffer: more lines below a piece', 'proc twice' in screen(), screen())
    # an edit in the multibuffer, saved: it lands in the file, where the piece is now
    keys('Escape', 'Left', 'C-f'); time.sleep(0.2)
    for _ in range(20): keys('BSpace')
    text('a bang'); keys('Enter'); keys('Escape'); time.sleep(0.2)
    text('a mark'); keys('C-s'); time.sleep(0.8)
    t = ftext('src/demo/utils.nim')
    check('631 multibuffer: the edit saved in its file, the line added there kept', t.startswith('# top\n') and
          '## upper-case and add a mark' in t and 'a bang' not in t, t)
    # the piece out
    keys('Escape', 'Left', 'C-f'); time.sleep(0.2)
    for _ in range(20): keys('BSpace')
    text('proc twice'); keys('Enter'); keys('Escape'); time.sleep(0.3)
    palette('Multibuffer: remove this piece'); time.sleep(0.5)
    s = screen()
    check('631 multibuffer: a piece removed', 'proc twice' not in s and 'shout("done")' in s, s)
    # F12 in it: the definition, through its file
    keys('C-End', 'Home', 'Right', 'Right', 'Right', 'Right', 'Right'); time.sleep(0.2)     # (on shout("done"))
    keys('F12'); time.sleep(1.5)
    s = screen()
    check('631 multibuffer: F12 goes to the definition in its file', re.search(r'Ln 4, Col \d', s) and
          '› utils.nim › shout' in s, s)
    # the selection of a file added to the multibuffer in use
    keys('M-2'); time.sleep(0.4)                  # (demo.nim's tab)
    keys('C-g'); text('4'); keys('Enter'); time.sleep(0.2)
    palette('Multibuffer: add the selection'); time.sleep(0.4)
    palette('Multibuffer: show the one in use'); time.sleep(0.5)
    s = screen()
    check('631 multibuffer: the line of a file added to it', 'proc greet*' in s and 'shout("done")' in s, s)

def t_631_plugin_panes():
    # 6.31: the plugin API's panes and multibuffers, through the cookbook's word-places: a multibuffer of every line
    # with the word, the file behind its cursor, a module's test in a pane beside it
    setup({"nim.nimsuggest": False, "editor.hoverDelay": 10000})
    d = CFG + '/ned/plugins/word-places'
    os.makedirs(d, exist_ok=True)
    shutil.copy(os.path.join(HERE, '..', 'plugins', 'cookbook', 'panes_pieces.nims'), d + '/plugin.nims')
    start('src/demo/utils.nim', 'src/demo.nim', w=150, h=40)
    palette('Plugins panel')
    ok = wait_for('running', 30)
    keys('Escape'); time.sleep(0.3)
    keys('C-g'); text('10:9'); keys('Enter'); time.sleep(0.2)
    palette('Word places: every line with this word, together')
    ok = wait_for('in the open files', 10)
    s = screen()
    check('631 plugin API: a multibuffer of the plugin\'s pieces', ok and 'proc shout*' in s and 'echo shout(' in s, s)
    keys('C-Home', 'Down', 'Down'); time.sleep(0.2)
    palette('Word places: the file behind the cursor')
    ok = wait_until(lambda: re.search(r'Ln \d+, Col', screen()) and '› utils.nim' in screen(), 10)
    check('631 plugin API: placeInFile — the file behind the multibuffer\'s cursor', ok, screen())
    keys('M-2'); time.sleep(0.4)                   # (demo.nim)
    palette("Word places: the module's test beside it")
    ok = wait_until(lambda: 'test_demo.nim' in screen() and screen().count('│') > 30, 10)
    s = screen()
    hdr = [r for r in s.split('\n')[2:5] if 'test_demo.nim' in r]
    check('631 plugin API: splitPane — the test in a pane beside the module', ok and hdr and 'demo.nim' in hdr[0].replace('test_demo.nim', ''), s)
    # numbers a plugin should not give — negative, huge, a pane that is not there — are clamped or refused: ned goes on
    d2 = CFG + '/ned/plugins/mb-edge'
    os.makedirs(d2, exist_ok=True)
    open(d2 + '/plugin.nims', 'w').write('import nedplugin\n'
        'command "Edge: odd numbers":\n'
        '  discard openMultibuffer("edge", [piece("src/demo.nim", -5, 1_000_000_000_000), piece("", 3), piece("nope.nim", 1)])\n'
        '  discard addPiece(piece("src/demo.nim", 1_000_000_000_000, -7))\n'
        '  focusPane(99); closePane(-3); showInPane(42, current())\n'
        '  try: paneLayout("spiral") except ValueError: discard\n'
        '  current().removePiece(77)\n'
        '  message("edge done")\n')
    palette('Plugins: reload'); time.sleep(3)
    palette('Edge: odd numbers')
    ok = wait_for('edge done', 15)
    s = screen()
    check('631 plugin API: odd numbers from a plugin — ned goes on, the multibuffer made of what there is',
          ok and 'Multibuffer: edge' in s, s)

def t_631_eof_problem():
    # a problem the compiler puts after the last line ("expected: ')', but got: '[EOF]'" at line 9 of an 8-line
    # file) is shown on the last line: its text after the line, and F8 goes there — not only in Problems
    setup()
    open(W + '/src/eof.nim', 'w').write('## eof\n\nproc greet*(who: string): string =\n  ## hi\n  "Hello, " & who\n\n'
                                       'when isMainModule:\n  echo greet("Nim"\n')
    start('src/eof.nim', w=140, h=34)
    keys('C-s')
    ok = wait_until(lambda: re.search(r'echo greet\("Nim"\s+● ', screen()), 30)
    check("631 a problem past the last line: shown at the end of the last line", ok, screen())
    keys('C-Home'); keys('S-F8'); time.sleep(0.5)        # (the one before the top: the last — a hint may come first)
    check("631 … Shift+F8 from the top goes to it (the last line)", re.search(r'Ln 8, Col 19', screen()), screen()[-300:])

def t_631_zen_tail():
    # zen: what follows a line's end (here a problem's text) goes on into the margin at the right of the column, not
    # cut at the column's edge (a C signature after a line was cut on a tablet)
    setup({"zen.width": 40})
    open(W + '/src/zt.nim', 'w').write('let total = 1\necho totall + 1 + 2 + 3 + 4 + 5 + 6 + 7\n')
    start('src/zt.nim', w=150, h=30)
    keys('C-s'); wait_for('undeclared identifier', 30)
    keys('M-z'); time.sleep(1.0)
    row = next((r for r in screen().split('\n') if 'echo totall' in r), '')
    check("631 zen: the text after a line goes on past the column", "undeclared identifier: 'totall'" in row, screen())

def t_631_nimble_fields():
    # a .nimble's package fields written `name = value` each are lined up, as nimble's template writes them — on
    # save (format on save) and by ned --format; nim.format.alignNimbleFields off keeps them as written
    setup({"editor.formatOnSave": True})
    src = 'mode = ScriptMode.Verbose\n\npackageName = "nt"\nversion = "0.3.0"\nauthor = "D"\ndescription = "x"\n\nrequires "nim >= 2.0.8"\n'
    want = 'mode = ScriptMode.Verbose\n\npackageName = "nt"\nversion     = "0.3.0"\nauthor      = "D"\ndescription = "x"\n\nrequires "nim >= 2.0.8"\n'
    open(W + '/nt.nimble', 'w').write(src)
    r = subprocess.run([BIN, '--format', W + '/nt.nimble'], capture_output=True, text=True)
    check("631 nimble: ned --format lines up the package's fields", open(W + '/nt.nimble').read() == want,
          r.stdout + r.stderr + open(W + '/nt.nimble').read())
    open(W + '/nt.nimble', 'w').write(src)
    start('nt.nimble', w=120, h=30)
    keys('End'); text(' '); keys('BSpace'); keys('C-s'); time.sleep(1.5)
    check("631 nimble: … and saving it with format on save", open(W + '/nt.nimble').read() == want,
          open(W + '/nt.nimble').read())

def t_631_multibuffer_safety():
    # multibuffers keep a file's text whole: a piece that ends with an empty line keeps it (and the file its last
    # line end); a piece emptied takes its lines out, typed into again puts them back; a multibuffer with edits not
    # saved is not replaced by a new one of the same name
    setup({"nim.nimsuggest": False, "editor.hoverDelay": 10000})
    open(W + '/src/mb.nim', 'w').write('x = 1\n# NOTE one\n\n')
    open(W + '/src/mc.nim', 'w').write('a = 1\nb = 2\nc = 3\n')
    start('src/mb.nim', w=140, h=34)
    keys('M-s'); time.sleep(0.3)
    for _ in range(20): keys('BSpace')
    text('NOTE one'); keys('Enter'); time.sleep(1.5)
    palette('Open results in a multibuffer'); time.sleep(0.6)
    keys('C-f'); time.sleep(0.2)
    for _ in range(20): keys('BSpace')
    text('x = 1'); keys('Enter'); keys('Escape'); time.sleep(0.2)
    text('x = 2'); keys('C-s'); time.sleep(0.8)
    t = ftext('src/mb.nim')
    check("631 multibuffer safety: a piece ending with an empty line keeps it, the file its last line end",
          t == 'x = 2\n# NOTE one\n\n', repr(t))
    # a piece emptied, then typed into
    keys('C-w'); time.sleep(0.3)
    keys('C-p'); text('src/mc.nim'); time.sleep(0.4); keys('Enter'); time.sleep(0.4)
    keys('C-g'); text('2'); keys('Enter')
    palette('Multibuffer: add the selection'); time.sleep(0.4)
    palette('Multibuffer: show the one in use'); time.sleep(0.5)
    keys('C-End'); keys('C-k'); time.sleep(0.2)                 # (the piece's one line deleted: the piece empty)
    s1 = screen()
    keys('C-s'); time.sleep(0.8)
    t1 = ftext('src/mc.nim')
    keys('C-End', 'End', 'Enter'); text('b = 9'); keys('C-s'); time.sleep(0.8)
    t2 = ftext('src/mc.nim')
    check("631 multibuffer safety: a piece emptied takes its line out; typed into again, it is put back",
          t1 == 'a = 1\nc = 3\n' and t2 == 'a = 1\nb = 9\nc = 3\n', repr((t1, t2)) + s1)
    # its edits not saved: adding to it makes another one, it keeps its edits
    keys('C-End'); text('XX'); time.sleep(0.2)
    keys('M-1'); time.sleep(0.3)
    palette('Multibuffer: add the selection'); time.sleep(0.5)
    s = screen()
    check("631 multibuffer safety: one with edits not saved is not replaced", 'collected (2)' in s or
          'collected (2)' in s.replace('\n', ' '), s)

def t_631_telescope_more():
    # 6.31: Telescope — the lines of this file, Alt+V opens the chosen place in a pane at the right, Alt+Q puts what a
    # finder lists in a multibuffer; its ⊙ in the status bar; M↓ beside it in a Markdown file opens and closes the
    # preview
    setup({"nim.nimsuggest": False, "editor.hoverDelay": 10000})
    open(W + '/notes.md', 'w').write('# Notes\n\nSome *text*.\n')
    start('src/demo/utils.nim', 'src/demo.nim', w=150, h=40)
    keys('M-F'); wait_for('Telescope — what to find', 4)
    text('lines of this'); time.sleep(0.4); keys('Enter')
    ok = wait_for('Lines of demo.nim', 4)
    text('echo greet'); time.sleep(0.5)
    keys('M-v'); time.sleep(0.8)
    s = screen()
    body = s.split('\n')[6:30]
    n = min(len(r) for r in body)
    divs = [c for c in range(n) if all(r[c] == '│' for r in body)]
    check('631 telescope: lines of this file — Alt+V opens the place in a pane at the right',
          ok and len(divs) >= 1 and re.search(r'Ln 9\b', s), s)
    keys('M-|'); time.sleep(0.3)
    keys('M-F'); wait_for('Telescope — what to find', 4)
    text('live grep'); time.sleep(0.4); keys('Enter')
    wait_for('Live grep — type', 4)
    text('shout'); time.sleep(0.2)
    wait_for('lines with “shout”', 6)
    keys('M-q'); time.sleep(0.8)
    s = screen()
    check('631 telescope: Alt+Q — what the finder lists, in a multibuffer', 'Multibuffer: Live grep' in s and
          'proc shout*' in s and 'echo shout(' in s, s)
    # the status bar: ⊙ opens Telescope
    last = screen().split('\n')[-2] if screen().split('\n')[-1].strip() == '' else screen().split('\n')[-1]
    rows = screen().split('\n')
    sb = max(i for i, r in enumerate(rows) if 'Ln ' in r)
    x = rows[sb].find('⊙')
    click(x + 1, sb + 1); time.sleep(0.5)
    check('631 telescope: ⊙ in the status bar opens it', x >= 0 and 'Telescope — what to find' in screen(), rows[sb])
    keys('Escape'); time.sleep(0.2)
    keys('C-p'); text('notes.md'); time.sleep(0.4); keys('Enter'); time.sleep(0.5)
    rows = screen().split('\n')
    sb = max(i for i, r in enumerate(rows) if 'Ln ' in r)
    x = rows[sb].find('M↓')
    click(x + 1, sb + 1); time.sleep(0.8)
    s = screen()
    opened = 'Preview: notes.md' in s
    rows = s.split('\n')
    sb = max(i for i, r in enumerate(rows) if 'Ln ' in r)
    x2 = rows[sb].find('M↓')
    click(x2 + 1, sb + 1); time.sleep(0.6)
    check('631 markdown: M↓ in the status bar opens the preview, again closes it', x >= 0 and opened and
          'Preview: notes.md' not in screen(), s)

def t_619_hot_exit():
    # files.hotExit: quitting with unsaved edits asks nothing; they come back, unsaved, in their tabs (a file and an
    # untitled one) the next time ned opens the folder — the file on disk untouched meanwhile
    setup({"files.hotExit": True})
    before = ftext('src/demo.nim')
    start('src/demo.nim', w=120, h=34); time.sleep(0.4)
    keys('C-End'); text('# kept for later'); time.sleep(0.3)
    keys('C-n'); time.sleep(0.3); text('untitled words'); time.sleep(0.3)
    keys('C-q'); time.sleep(1.2)
    ex = open(W + '/exit').read() if os.path.exists(W + '/exit') else ''
    check("619 hot exit: quit without a question", 'EXITED 0' in ex, (ex, screen()))
    check("619 hot exit: the file on disk is as it was", ftext('src/demo.nim') == before, ftext('src/demo.nim')[-200:])
    tm('kill-server'); time.sleep(0.3)
    os.remove(W + '/exit')
    start(w=120, h=34); time.sleep(1.0)
    s = screen()
    check("619 hot exit: the edits are back, unsaved (a toast says so)",
          'untitled words' in s and 'still unsaved' in s, s)
    keys('C-p'); time.sleep(0.3); text('src/demo.nim'); time.sleep(0.4); keys('Enter'); time.sleep(0.5)
    s = screen()
    check("619 hot exit: … in the file's tab too, marked unsaved", '# kept for later' in s and '• demo.nim' in s, s)

def t_619_encodings():
    # a file that is not UTF-8 (Windows-1252) and one in UTF-16: read as them (the status bar says which), written
    # back as them; a character the encoding cannot hold stops the save (where it is said); Save with encoding…
    setup()
    open(W + '/latin.txt', 'wb').write(b'caf\xe9 cr\xe8me \x80\n')
    open(W + '/u16.txt', 'wb').write('h\u00e9llo\n'.encode('utf-16'))      # (with its BOM)
    start('latin.txt', w=120, h=30); time.sleep(0.5)
    s = screen()
    check("619 encodings: Windows-1252 read as such (é, è, €), the status bar says so",
          'café crème €' in s and 'Windows-1252' in s, s)
    keys('End'); text('!'); keys('C-s'); time.sleep(0.5)
    check("619 encodings: written back in Windows-1252", open(W + '/latin.txt', 'rb').read() == b'caf\xe9 cr\xe8me \x80!\n',
          open(W + '/latin.txt', 'rb').read())
    text(' \u0161\u20ac\u4e2d'); keys('C-s'); time.sleep(0.5)
    s = screen()
    check("619 encodings: a character it cannot hold — not saved, and which one", 'Not saved: 中' in s and
          open(W + '/latin.txt', 'rb').read() == b'caf\xe9 cr\xe8me \x80!\n', s)
    palette('File: save with encoding…'); time.sleep(0.4); text('UTF-8'); time.sleep(0.3); keys('Enter'); time.sleep(0.6)
    check("619 encodings: Save with encoding… UTF-8", open(W + '/latin.txt', 'rb').read() ==
          'café crème €! š€中\n'.encode('utf-8'), open(W + '/latin.txt', 'rb').read())
    keys('C-p'); time.sleep(0.3); text('u16.txt'); time.sleep(0.4); keys('Enter'); time.sleep(0.5)
    s = screen()
    check("619 encodings: UTF-16 (its BOM) read, the status bar says so", 'héllo' in s and 'UTF-16 LE' in s, s)
    keys('End'); text('!'); keys('C-s'); time.sleep(0.5)
    check("619 encodings: written back in UTF-16 with its BOM",
          open(W + '/u16.txt', 'rb').read() == b'\xff\xfe' + 'héllo!\n'.encode('utf-16-le'),
          open(W + '/u16.txt', 'rb').read())

def t_619_key_conflicts():
    # the "keys" setting: a command that does not exist and a key terminals do not send are pointed out (a note at
    # the start, the shortcuts list); binding a key another command has asks first, naming it
    setup({"keys": {"ctrl+shift+a": "Save", "alt+z": "Fromat document"}})
    start('src/demo.nim', w=140, h=40); time.sleep(0.8)
    s = screen()
    check("619 keys: a note about the setting at the start", 'keys' in s and 'Fromat document' in s, s)
    palette('Keyboard shortcuts…'); time.sleep(0.6)
    s = screen()
    check("619 keys: the shortcuts list shows the setting's problems",
          '"Format document"?' in s and 'ctrl+shift+a' in s and 'send it as ctrl+a' in s, s)
    text('Find next'); time.sleep(0.3); keys('Enter'); time.sleep(0.3)
    keys('C-s'); time.sleep(0.5)
    s = screen()
    check("619 keys: a key another command has — asked first, naming it", "ctrl+s runs ned's “Save”" in s, s)
    keys('y'); time.sleep(0.4)
    cfg = json.load(open(CFG + '/ned/config.json'))
    check("619 keys: … and bound when you say yes", cfg.get('keys', {}).get('ctrl+s') == 'Find next', cfg.get('keys'))

def t_620_plugin_language():
    # ini-tools (a NimScript plugin) for INI files: the outline from its symbols, its completions in the list, its
    # hover, its code action (Alt+Enter), a view in the Plugins dock (a click goes there), progress and the Output
    # panel from a command, its setting in the Settings panel
    setup()
    shutil.copytree(REPO + '/examples/plugins/ini-tools', CFG + '/ned/plugins/ini-tools')
    os.makedirs(W + '/cfg', exist_ok=True)
    open(W + '/cfg/app.ini', 'w').write('[server]\nport = 80\nhost = a\n\n[client]\nport = 81\nzeta = 1\nalpha = 2\n'
                                        'port = 82\n')
    start('cfg/app.ini', w=150, h=40); time.sleep(0.5)
    check("620 plugin language: ready", plugins_ready(), screen())
    palette('Outline panel')
    ok = wait_for('\\[client\\]', 8) and wait_for('alpha', 4)
    check("620 plugin language: the Outline from its symbols (sections, keys)", ok, screen())
    keys('Escape')
    keys('C-g'); text('9:1'); keys('Enter'); time.sleep(0.3); keys('End'); keys('Enter')
    text('ho'); time.sleep(1.0)
    s = screen()
    check("620 plugin language: its completion in the list (a key another section has)", 'as in [server]' in s, s)
    keys('Enter'); time.sleep(0.5)
    s = screen()
    check("620 plugin language: … accepted as a snippet (the value to type over)", '  host = a' in s, s)
    keys('Escape')
    for _ in range(4):
        keys('C-z'); time.sleep(0.2)
    time.sleep(0.3)
    keys('C-g'); text('2:2'); keys('Enter'); time.sleep(0.3); keys('M-h')
    ok = wait_for('port.{0,4} — in 3 sections', 8)
    check("620 plugin language: its hover", ok, screen())
    keys('Escape')
    keys('C-g'); text('9:1'); keys('Enter'); time.sleep(0.3); keys('M-Enter')
    ok = wait_for('Quick fixes', 8)
    s = screen()
    check("620 plugin language: Alt+Enter — its code actions", ok and 'Sort the keys of [client]' in s and
          'Remove the second port (line 9)' in s, s)
    if ok:
        text('Sort the keys'); time.sleep(0.3); keys('Enter'); time.sleep(0.6)
    keys('C-s'); time.sleep(0.5)
    check("620 plugin language: the code action applied",
          ftext('cfg/app.ini') == '[server]\nport = 80\nhost = a\n\n[client]\nalpha = 2\nport = 81\nport = 82\nzeta = 1\n',
          ftext('cfg/app.ini'))
    palette('Plugins panel')
    ok = wait_for('INI SECTIONS', 10) and wait_for('§ \\[client\\]', 10)
    check("620 plugin language: its view in the Plugins dock", ok, screen())
    open(W + '/cfg/b.ini', 'w').write('[db]\nurl = x\nurl = y\n')
    palette("INI: check the project's config files")
    ok = wait_for('url is in \\[db\\] twice', 15)
    check("620 plugin language: a command's lines in the Output panel (and its message)",
          ok and 'INI: 2 keys twice' in screen(), screen())
    palette('Settings'); time.sleep(0.4); text('sortCaseSensitive'); time.sleep(0.5)
    s = screen()
    check("620 plugin language: its setting in the Settings panel", 'Ini-tools.sort case sensitive' in s, s)
    keys('Escape')
    keys('M-c'); time.sleep(0.5); text('ask the ini plugin for the port'); keys('Enter')
    ok = wait_for('Tool said: 80', 20)
    check("620 plugin language: the assistant calls the plugin's tool (it only reads: no question)", ok, screen())

def t_620_plugin_full_nim():
    # clock-native: a plugin in full Nim (plugin.nim) — compiled into a program of its own (the dock says so), its
    # timer's status-bar clock, its command (std/times); a NimScript plugin beside it keeps its own process; reload one
    setup()
    shutil.copytree(REPO + '/examples/plugins/clock-native', CFG + '/ned/plugins/clock-native')
    d = CFG + '/ned/plugins/hello'
    os.makedirs(d, exist_ok=True)
    open(d + '/plugin.nims', 'w').write(HELLO_PLUGIN)
    open(W + '/notes.txt', 'w').write('abc def\nsecond\n')
    start('notes.txt', w=150, h=40); time.sleep(0.5)
    palette('Plugins panel')
    ok = wait_for('clock-native \\(Nim\\) · running · native', 90)
    s = screen()
    check("620 full Nim: compiled, then running in its own process (the dock)", ok and 'running · nim e · 1 plugin' in s, s)
    ok = wait_for('⏱ [0-9][0-9]:[0-9][0-9]', 6)
    check("620 full Nim: its timer — the clock in the status bar", ok, screen())
    keys('Escape')
    palette('Clock: insert the date'); time.sleep(1.0)
    s = screen()
    import datetime
    check("620 full Nim: its command (std/times)", datetime.date.today().isoformat() + 'abc def' in s, s)
    palette('Plugins: reload one…'); time.sleep(0.4); text('hello'); time.sleep(0.3); keys('Enter'); time.sleep(0.5)
    palette('Plugins panel')
    ok = wait_for('running · (nim e|native) · 1 plugin', 30)
    s = screen()
    check("620 full Nim: reload one plugin — the other process keeps running",
          ok and 'clock-native (Nim) · running · native' in s, s)

def t_6241_plugin_check():
    # a plugin's own source is checked as ned runs it: `import nedplugin` resolves (the compiler is given the plugin
    # library's folder), so a full-Nim plugin opens and saves without errors — before 6.24.1 every line was red
    setup({"nim.liveDiagnosticsFrom": "compiler"})
    shutil.copytree(REPO + '/examples/plugins/clock-native', CFG + '/ned/plugins/clock-native')
    start(CFG + '/ned/plugins/clock-native/plugin.nim', w=150, h=40); time.sleep(1.0)
    keys('C-End'); text('\n# a comment'); time.sleep(0.3); keys('C-s'); time.sleep(0.5)
    ok = wait_for('✓ 0', 60); time.sleep(2.0)
    s = screen()
    check('6241 plugin source: no "cannot open file: nedplugin", no errors after an edit and a save',
          ok and 'cannot open file' not in s and 'undeclared identifier' not in s and '✓ 0' in s, s)

def t_620_ast_docs():
    # Nim: AST view — the statement at the cursor as the tree a macro gets (beside the code, again after an edit);
    # Nim: preview this file's docs — the exported declarations with their doc comments, as nim doc shows them
    setup()
    open(W + '/src/m.nim', 'w').write('## The m module.\n\nproc add*(a, b: int): int =\n  ## adds a and b\n  a + b\n'
                                      '\nlet x = add(1, 2)\n')
    start('src/m.nim', w=150, h=40); time.sleep(0.5)
    keys('C-g'); text('3:1'); keys('Enter'); time.sleep(0.2)
    palette('Nim: AST view')
    ok = wait_for('ProcDef', 15) and wait_for('Ident "add"', 5)
    check("620 AST view: the proc's tree beside it", ok, screen())
    keys('C-g'); text('7:1'); keys('Enter'); time.sleep(1.2)
    ok = wait_for('LetSection', 10)
    check("620 AST view: follows the cursor to the next statement", ok, screen())
    palette('Nim: AST view'); time.sleep(0.5)
    check("620 AST view: run again — closed", 'LetSection' not in screen(), screen())
    palette("Nim: preview this file's docs")
    ok = wait_for('adds a and b', 10)
    s = screen()
    check("620 docs preview: the module's doc and the exported proc's", ok and 'The m module' in s, s)

def fake_nimble_dir620():
    """a NIMBLE_DIR with jsony 1.0.0 and 1.1.5 installed, and its package list pointing at a local repository tagged
    v1.0.0 v1.1.5 v1.2.0 (git ls-remote reads it offline)"""
    nd = TMP + '/nimble620'
    repo = TMP + '/jsony620.git'
    if not os.path.exists(repo + '/HEAD'):
        shutil.rmtree(nd, ignore_errors=True)
        shutil.rmtree(repo, ignore_errors=True)
        src = TMP + '/jsony620src'
        shutil.rmtree(src, ignore_errors=True)
        os.makedirs(src)
        open(src + '/jsony.nimble', 'w').write('version = "1.2.0"\n')
        cmds = ('git init -q -b master && git config user.name t && git config user.email t@t && '
                'git config commit.gpgsign false && git add -A && git commit -qm a && git tag v1.0.0 && '
                'git commit -q --allow-empty -m b && git tag v1.1.5 && git commit -q --allow-empty -m c && git tag v1.2.0')
        subprocess.run(cmds, shell=True, cwd=src, check=True, capture_output=True)
        subprocess.run(['git', 'clone', '-q', '--bare', src, repo], check=True, capture_output=True)
    os.makedirs(nd + '/pkgs2/jsony-1.0.0-aaaa', exist_ok=True)
    os.makedirs(nd + '/pkgs2/jsony-1.1.5-bbbb', exist_ok=True)
    json.dump([{"name": "jsony", "url": "file://" + repo, "method": "git", "tags": ["json"],
                "description": "A loose, direct to object json parser", "license": "MIT", "web": "https://x/jsony"},
               {"name": "jester", "url": "file:///nonexistent", "method": "git", "description": "a web framework",
                "license": "MIT"}], open(nd + '/packages_official.json', 'w'))
    return nd

def t_620_nimble_edit():
    # a .nimble: a requires' versions completed (installed, the repository's tags), the package on hover, the version
    # bumped (Alt+Enter), a dependency added from the package list; config.nims: --gc's fix; the configuration the
    # compiler ends up with (where nim.cfg and config.nims disagree); the lock file's changes since the last commit
    setup()
    nd = fake_nimble_dir620()
    open(W + '/nim.cfg', 'w').write('--mm:refc\n')
    open(W + '/config.nims', 'w').write('--gc:orc\n')
    json.dump({"version": 2, "packages": {"jsony": {"version": "1.0.0", "vcsRevision": "a" * 40, "url": "x",
                                                     "downloadMethod": "git", "dependencies": [], "checksums": {}}}},
              open(W + '/nimble.lock', 'w'))
    subprocess.run('git add -A && git commit -qm lock', shell=True, cwd=W, check=True, capture_output=True)
    json.dump({"version": 2, "packages": {"jsony": {"version": "1.1.5", "vcsRevision": "b" * 40, "url": "x",
                                                     "downloadMethod": "git", "dependencies": [], "checksums": {}},
                                           "jester": {"version": "0.6.0", "vcsRevision": "c" * 40, "url": "y",
                                                      "downloadMethod": "git", "dependencies": [], "checksums": {}}}},
              open(W + '/nimble.lock', 'w'))
    start('demo.nimble', w=150, h=40, env_extra='NIMBLE_DIR=' + nd); time.sleep(0.5)
    keys('C-End'); keys('Enter'); text('requires "jsony >= '); time.sleep(2.0)
    if 'newest tag' not in screen():
        keys('C-space'); time.sleep(1.5)
    s = screen()
    check("620 nimble: a requires' versions — the tags and those installed",
          '1.2.0' in s and 'newest tag' in s and 'installed · tag' in s and '1.0.0' in s, s)
    keys('Enter'); text('"'); time.sleep(0.3)
    check("620 nimble: … one chosen", 'requires "jsony >= 1.2.0"' in screen(), screen())
    keys('Left', 'Left', 'Left', 'Left', 'Left', 'Left', 'Left', 'Left', 'Left', 'Left', 'Left', 'Left'); time.sleep(0.2)
    keys('M-h')
    ok = wait_for('A loose, direct to object json parser', 8)
    s = screen()
    check("620 nimble: hover on a package — what it is, the versions installed, the newest",
          ok and 'installed: 1.1.5, 1.0.0' in s and 'newest release: 1.2.0' in s, s)
    keys('Escape')
    keys('C-Home'); time.sleep(0.2); keys('M-Enter')
    ok = wait_for('Bump the version to 0.1.1', 8)
    s = screen()
    check("620 nimble: on version = — bump it (patch, minor, major)", ok and '0.2.0' in s and '1.0.0' in s, s)
    if ok:
        text('0.2.0'); time.sleep(0.3); keys('Enter'); time.sleep(0.4)
    keys('C-s'); time.sleep(0.4)
    check("620 nimble: the version bumped", 'version       = "0.2.0"' in ftext('demo.nimble'), ftext('demo.nimble'))
    palette('Nimble: add a dependency…'); time.sleep(0.8)
    text('jester'); time.sleep(0.4); keys('Enter'); time.sleep(1.5)
    s = screen()
    check("620 nimble: add a dependency — its versions (none known: any, #head)", 'any version' in s and 'jester#head' in s, s)
    keys('Enter'); time.sleep(0.6)                                  # (the first: any version)
    s = screen()
    check("620 nimble: … the requires line, then install it? asked", 'install it now' in s and
          'requires "jester"' in ftext('demo.nimble'), (s, ftext('demo.nimble')))
    keys('n'); time.sleep(0.3)
    keys('C-p'); time.sleep(0.3); text('config.nims'); time.sleep(0.4); keys('Enter'); time.sleep(1.5); keys('M-Enter')
    ok = wait_for('Use --mm:orc', 8)
    if ok:
        keys('Enter'); time.sleep(0.4)
    keys('C-s'); time.sleep(0.4)
    check("620 nimble: config.nims — --gc's fix (--mm)", ftext('config.nims') == '--mm:orc\n', ftext('config.nims'))
    keys('C-p'); time.sleep(0.3); text('src/demo.nim'); time.sleep(0.4); keys('Enter'); time.sleep(0.5)
    palette('Nim: the configuration the compiler ends up with')
    ok = wait_for('Where they disagree', 25)
    s = screen()
    check("620 nim dump: the config files read, where they disagree (--mm in nim.cfg and config.nims)",
          ok and '--mm' in s and 'nim.cfg:1' in s and 'config.nims:1' in s and 'the last read wins' in s, s)
    palette('Nimble: lock file')
    ok = wait_for('Since the last commit', 10)
    s = screen()
    check("620 nimble.lock: what changed since the last commit", ok and '1.0.0 → 1.1.5' in s and 'jester' in s and
          'added' in s, s)

EMIT_NAMES = """proc add*(a, b: cint): cint {.exportc: "nim_add".} = a + b
var counter: cint = 0

proc bump() =
  var local: cint = 1
  {.emit: \"\"\"
  `counter` = `add`(`counter`, `local`);
  `ad`(1, 2);
  `add`(1);
  \"\"\".}

bump()
echo counter
"""

def t_620_emit_names():
    # Nim names in an emit (`name`): checked (no such name — the one meant; a routine's arguments), on hover (the Nim
    # declaration, the C name), F12 to the Nim declaration, completed in the backticks, renamed with the Nim name;
    # an exportc proc's hover gives its C name
    setup({"nim.nimsuggest": False})
    open(W + '/src/e.nim', 'w').write(EMIT_NAMES)
    start('src/e.nim', w=150, h=40); time.sleep(1.5)
    palette('Show problems'); time.sleep(0.8)
    s = screen()
    check("620 emit names: a name that is no Nim name (the one meant), a routine's argument count",
          'is no Nim name here' in s and '(`add`?)' in s and '`add` takes 2 arguments — the emit passes 1' in s, s)
    keys('Escape'); keys('Escape')
    keys('C-g'); text('7:6'); keys('Enter'); time.sleep(0.3); keys('M-h')
    ok = wait_for('var counter', 8)
    s = screen()
    check("620 emit names: hover on `counter` — its Nim declaration, the C name", ok and 'In the C:' in s, s)
    keys('Escape')
    keys('C-g'); text('7:33'); keys('Enter'); time.sleep(0.3); keys('F12'); time.sleep(0.6)
    check("620 emit names: F12 on `local` — its Nim declaration", 'Ln 5, Col 7' in screen(), screen())
    keys('C-g'); text('1:7'); keys('Enter'); time.sleep(0.3); keys('M-h')
    ok = wait_for('C name:.{0,4}nim_add', 8)
    check("620 emit names: hover on an exportc proc — its C name", ok, screen())
    keys('Escape')
    keys('C-g'); text('2:6'); keys('Enter'); keys('F2'); time.sleep(0.3)
    keys('C-u'); text('count'); keys('Enter'); time.sleep(0.6)
    keys('Enter'); time.sleep(0.6)
    keys('C-s'); time.sleep(0.5)
    t = ftext('src/e.nim')
    check("620 emit names: rename — the backticked uses in the emit too",
          '`count` = `add`(`count`, `local`);' in t and 'echo count\n' in t and 'counter' not in t, t)
    keys('C-g'); text('9:3'); keys('Enter'); keys('End'); keys('Enter'); text('`cou'); time.sleep(1.0)
    s = screen()
    check("620 emit names: completion in the backticks — the Nim names there", re.search(r'count\s', s) is not None, s)

def t_620_viewer():
    # a file bigger than editor.viewerSize: the large-file viewer — read-only, its lines read as you go (the index
    # made in the background): Go to line anywhere (the gutter numbers the file's lines), Ctrl+End to its end,
    # Find through the whole file, Copy from it
    setup({"editor.viewerSize": 16})
    p = TMP + '/viewer620.log'
    if not os.path.exists(p) or os.path.getsize(p) < 30 * 1024 * 1024:
        with open(p, 'w') as f:
            for i in range(1_400_000):
                f.write('line %07d %s\n' % (i, 'needle-xyz' if i == 1_234_567 else 'some ordinary text here'))
            f.write('THE VERY LAST LINE')
    shutil.copy(p, W + '/huge.log')
    start('huge.log', w=130, h=32); time.sleep(1.5)
    s = screen()
    check("620 viewer: opened in the viewer (read-only, the lines read as you go)",
          'line 0000000' in s and 'Large file' in s and re.search(r'Ln 1 of (≥)?\d+', s) is not None, s)
    ok = wait_for('Ln 1 of 1400001', 30)
    check("620 viewer: the whole file indexed in the background (its line count)", ok, screen())
    keys('C-g'); text('1000000'); keys('Enter'); time.sleep(0.6)
    s = screen()
    check("620 viewer: Go to line 1 000 000 (the gutter numbers the file's lines)",
          'line 0999999' in s and '1000000' in s and 'Ln 1000000 of' in s, s)
    keys('C-End'); time.sleep(0.8)
    s = screen()
    check("620 viewer: Ctrl+End — the file's last line", 'THE VERY LAST LINE' in s and 'Ln 1400001' in s, s)
    keys('C-Home'); time.sleep(0.6)
    keys('C-f'); text('needle-xyz'); keys('Enter'); time.sleep(0.5)
    ok = wait_for('Line 1234568', 20)
    s = screen()
    check("620 viewer: Find — through the whole file (in the background)", ok and 'line 1234567 needle-xyz' in s, s)
    keys('Escape'); text('x'); time.sleep(0.3)
    check("620 viewer: read-only", 'line 1234567 needle-xyz' in screen() and open(W + '/huge.log').read(39) ==
          'line 0000000 some ordinary text here\nli', screen())
    keys('C-Home'); time.sleep(0.8)
    check("620 viewer: Ctrl+Home — the file's first line", 'Ln 1 of 1400001' in screen(), screen())

def t_620_plugin_list():
    # Plugins: browse the plugin list… (plugins.indexUrl: a file of JSON here) installs one from git; Plugins: update
    # pulls it when its repository moved on, and it reloads
    repo = TMP + '/greeter620.git'
    src = TMP + '/greeter620src'
    shutil.rmtree(repo, ignore_errors=True)
    shutil.rmtree(src, ignore_errors=True)
    os.makedirs(src)
    open(src + '/plugin.nims', 'w').write('import nedplugin\ncommand "Greeter: hello":\n  message("hello v1")\n')
    subprocess.run('git init -q -b master && git config user.name t && git config user.email t@t && '
                   'git config commit.gpgsign false && git add -A && git commit -qm v1', shell=True, cwd=src, check=True,
                   capture_output=True)
    subprocess.run(['git', 'clone', '-q', '--bare', src, repo], check=True, capture_output=True)
    idx = TMP + '/plugins620.json'
    json.dump([{"name": "greeter", "url": "file://" + repo, "description": "says hello"}], open(idx, 'w'))
    setup({"plugins.indexUrl": idx})
    start('src/demo.nim', w=140, h=40); time.sleep(0.5)
    palette('Plugins: browse the plugin list…'); time.sleep(0.6)
    s = screen()
    check("620 plugin list: the list (name, description)", 'greeter' in s and 'says hello' in s, s)
    keys('Enter')
    ok = wait_for('Installed the plugin greeter', 15)
    check("620 plugin list: installed from git", ok and os.path.exists(CFG + '/ned/plugins/greeter/plugin.nims'), screen())
    time.sleep(3)
    palette('Greeter: hello')
    check("620 plugin list: its command runs", wait_for('hello v1', 15), screen())
    open(src + '/plugin.nims', 'w').write('import nedplugin\ncommand "Greeter: hello":\n  message("hello v2")\n')
    subprocess.run('git commit -qam v2 && git push -q ' + repo + ' master', shell=True, cwd=src, check=True,
                   capture_output=True)
    palette('Plugins: update (git pull)')
    ok = wait_for('Updated: greeter', 20)
    check("620 plugin list: Plugins: update pulls it", ok, screen())
    time.sleep(3)
    palette('Greeter: hello')
    check("620 plugin list: … and it reloads", wait_for('hello v2', 15), screen())

# ── ned 6.21 ──

EMIT621 = """proc a(): cint =
  {.emit: \"\"\"
  int x = 42;
  return x;
  \"\"\".}

proc b(): cint =
  {.
    emit: \"\"\"
  long y = 7;
  return y;
  \"\"\"
  .}

let s = "long text"
echo a(), b(), s
"""

def t_621_emit_format():
    # the formatter keeps `{.emit: \"\"\"` on its line (it used to split it into `{.` ⏎ `emit: \"\"\"`, and the C lost
    # its colours); C in the nph-style split form is coloured as C too
    setup()
    open(W + '/src/em.nim', 'w').write(EMIT621)
    start('src/em.nim', w=120, h=36); time.sleep(1.0)
    row_int, row_long, row_str = ansi_row('int x = 42;'), ansi_row('long y = 7;'), ansi_row('let s = "long text"')
    c_int, c_long, c_str = fg_at(row_int, 'int'), fg_at(row_long, 'long'), fg_at(row_str, 'long')
    check("621 emit: C coloured in {.emit: and in the split {. ⏎ emit: form", c_int is not None and c_int == c_long and
          c_long != c_str, str((c_int, c_long, c_str)))
    palette('Format document'); time.sleep(1.5)
    keys('C-s'); time.sleep(0.5)
    t = ftext('src/em.nim')
    check("621 emit: formatting keeps {.emit: \"\"\" on its line", '  {.emit: """\n  int x = 42;\n' in t and
          '{.\n    emit: """' not in t.split('proc b')[0], t)
    row_int = ansi_row('int x = 42;')
    check("621 emit: … and its C keeps its colours", fg_at(row_int, 'int') == c_int, screen())

def t_621_reset():
    # Reset everything: a dialog with each part (its size), Cancel the default; Reset and restart removes the
    # settings, plugins, state, caches and downloads, and ned starts again (as on its first run). ned --reset too
    setup({"editor.tabSize": 3})
    cache, data = TMP + '/cache621', TMP + '/data621'
    shutil.rmtree(cache, ignore_errors=True); shutil.rmtree(data, ignore_errors=True)
    os.makedirs(cache + '/ned/index'); os.makedirs(data + '/ned/dicts')
    open(cache + '/ned/index/x.idx', 'w').write('x' * 5000)
    open(data + '/ned/dicts/en.dic', 'w').write('word\n')
    os.makedirs(CFG + '/ned/plugins/p621', exist_ok=True)
    open(CFG + '/ned/plugins/p621/plugin.nims', 'w').write('import nedplugin\n')
    env = 'XDG_CACHE_HOME=%s XDG_DATA_HOME=%s' % (cache, data)
    start('src/demo.nim', w=140, h=40, env_extra=env); time.sleep(1.5)
    palette('Reset everything: remove all settings and state…')
    if not wait_for('Reset and restart', 6):
        palette('Reset everything: remove all settings and state…'); wait_for('Reset and restart', 6)
    s = screen()
    check("621 reset: the dialog — each part and its size", all(w in s for w in [
        'Reset everything', 'Settings', 'Plugins you installed', 'Sessions and history', 'Caches', 'Downloads',
        'Reset and restart', 'Cancel']) and re.search(r'Caches\s+·\s+\d+ files?, [\d.]+ [KM]?B', s) is not None and
        re.search(r'Downloads\s+·\s+1 file, 5 B', s) is not None, s[s.find('Reset everything'):])
    keys('Enter'); time.sleep(0.5)
    check("621 reset: Enter is Cancel — nothing removed", os.path.exists(CFG + '/ned/config.json') and
          os.path.exists(cache + '/ned/index/x.idx') and 'Reset everything' not in screen(), screen())
    palette('Reset everything: remove all settings and state…'); time.sleep(1.0)
    p = find_on_screen('Reset and restart')
    if p: click(*p)
    ok = wait_for('Open folder…', 10)
    time.sleep(1.0)
    cfg = open(CFG + '/ned/config.json').read() if os.path.exists(CFG + '/ned/config.json') else ''
    st = open(STATE + '/ned/state.json').read() if os.path.exists(STATE + '/ned/state.json') else ''
    check("621 reset: settings, plugins, state, caches and downloads removed",
          '"editor.tabSize": 3' not in cfg and not os.path.exists(CFG + '/ned/plugins') and 'demo.nim' not in st and
          not os.path.exists(cache + '/ned') and not os.path.exists(data + '/ned'), (cfg[:200], st[:200]))
    check("621 reset: … and ned started again (its first-run page)", ok and 'EXITED' not in screen(), screen())
    keys('C-q'); time.sleep(0.5)
    # from the shell
    open(CFG + '/ned/config.json', 'w').write('{"editor.tabSize": 5}')
    os.makedirs(cache + '/ned', exist_ok=True); open(cache + '/ned/y', 'w').write('y')
    r = subprocess.run('env XDG_CONFIG_HOME=%s XDG_STATE_HOME=%s %s %s --reset --yes' % (CFG, STATE, env, BIN),
                       shell=True, capture_output=True, text=True)
    check("621 reset: ned --reset --yes (what it removes, then done)", r.returncode == 0 and 'Settings' in r.stdout and
          'Done' in r.stdout and not os.path.exists(CFG + '/ned/config.json') and not os.path.exists(cache + '/ned'),
          r.stdout + r.stderr)
    r = subprocess.run('env XDG_CONFIG_HOME=%s XDG_STATE_HOME=%s %s %s --reset --yes' % (CFG, STATE, env, BIN),
                       shell=True, capture_output=True, text=True)
    check("621 reset: … nothing left: says so", 'nothing' in r.stdout, r.stdout)

def t_621_settings_form():
    # the Settings window: categories, a search over every setting, check boxes, lists, numbers; OK writes what
    # changed (and only that); a bad number is refused
    setup({"ui.formButtons": None})
    start('src/demo.nim', w=140, h=40); time.sleep(0.5)
    palette('Settings'); time.sleep(0.8)
    s = screen()
    check("621 settings: a window — its categories, the search, the buttons", 'Settings' in s and 'Editor' in s and
          'Search every setting' in s and 'OK' in s and 'Cancel' in s and 'Apply' in s, s)
    text('tab size'); time.sleep(0.5)
    s = screen()
    check("621 settings: the search finds a setting", 'Tab size' in s, s)
    keys('Tab'); time.sleep(0.2)
    keys('C-a'); tm('send-keys', '-t', 'f', '-l', '--', '--'); time.sleep(0.2); keys('Enter'); time.sleep(0.4)
    s = screen()
    check("621 settings: a bad number is refused (the window stays)", 'Tab size' in s and 'is not a number' in s and
          'tabSize' not in open(CFG + '/ned/config.json').read(), s)
    keys('C-a'); text('6'); time.sleep(0.3)
    keys('Enter')
    for _ in range(20):                                   # (written: within a few hundred ms)
        time.sleep(0.2)
        c = open(CFG + '/ned/config.json').read()
        if 'tabSize' in c: break
    check("621 settings: OK writes what changed", re.search(r'"editor\.tabSize":\s*6', c) is not None and
          'Search every setting' not in screen(), c[-600:])
    palette('Settings'); time.sleep(0.8)
    text('format on save'); time.sleep(0.5)
    p = find_on_screen('▏ Format on save')                  # (an empty box: ▕ ▏; a ticked one: ▐✓▌)
    if p: click(p[0] + 1, p[1])
    time.sleep(0.3)
    p = find_on_screen(' OK ')
    if p: click(*p)
    time.sleep(0.6)
    c = open(CFG + '/ned/config.json').read()
    check("621 settings: a check box clicked, OK", re.search(r'"editor\.formatOnSave":\s*true', c) is not None, c[-600:])
    palette('Settings'); time.sleep(0.8)
    text('tab size'); keys('Tab'); keys('C-a'); text('9'); keys('Escape'); time.sleep(0.5)
    c = open(CFG + '/ned/config.json').read()
    check("621 settings: Esc — nothing written", re.search(r'"editor\.tabSize":\s*6', c) is not None and
          'Search every setting' not in screen(), c[-600:])

def t_621_fields():
    # text fields: Shift+arrows select, typing replaces it; Ctrl+A all; double-click a word; a right-click menu
    # (Cut, Copy, Paste, Select all)
    setup()
    start('src/demo.nim', w=140, h=40); time.sleep(0.5)
    keys('C-p'); time.sleep(0.4)
    text('demo utils'); time.sleep(0.3)
    keys('S-Left', 'S-Left', 'S-Left', 'S-Left', 'S-Left'); text('types'); time.sleep(0.4)
    s = screen()
    check("621 fields: Shift+Left selects, typing replaces it", 'demo types' in s and 'demo utils' not in s, s)
    keys('C-a'); text('test'); time.sleep(0.4)
    check("621 fields: Ctrl+A selects all", 'test_demo.nim' in screen() and 'demo types' not in screen(), screen())
    p = find_on_screen('› test')                                           # (the query, under the picker's title)
    if p:
        mouse(2, p[0] + 2, p[1]); mouse(2, p[0] + 2, p[1], up=True); time.sleep(0.4)
    s = screen()
    check("621 fields: right-click — Cut, Copy, Paste, Select all", 'Cut' in s and 'Copy' in s and 'Paste' in s and
          'Select all' in s, s)
    keys('Escape'); time.sleep(0.2)
    keys('Escape'); time.sleep(0.2)
    keys('C-f'); text('greet who'); time.sleep(0.3)
    p = find_on_screen('greet who')
    if p:
        x, y = p[0] + 7, p[1]                                            # (a double-click: the word)
        tm('send-keys', '-t', 'f', '-l', '\x1b[<0;%d;%dM\x1b[<0;%d;%dm\x1b[<0;%d;%dM\x1b[<0;%d;%dm' % (x, y, x, y, x, y, x, y))
        time.sleep(0.3)
        text('me')
    time.sleep(0.3)
    check("621 fields: a double-click selects the word", 'greet me' in screen(), screen())

def t_621_context_menus():
    # right-click: a tab (split with it), the gutter (breakpoint, bookmark, fold …), the status bar, a file in the
    # tree; the menus' entries run
    setup()
    start('src/demo.nim', 'src/demo/utils.nim', w=150, h=40); time.sleep(0.8)
    k = screen().split('\n')[1].find('demo.nim')                            # (its tab: the second row)
    if k >= 0: mouse(2, k + 2, 2); mouse(2, k + 2, 2, up=True)
    time.sleep(0.4)
    s = screen()
    check("621 context menus: a tab — close, split with it, copy its path", 'Split right with it' in s and
          'Copy relative path' in s, s)
    p = find_on_screen('Split right with it')
    if p: click(*p)
    time.sleep(0.6)
    s = screen()
    check("621 context menus: … split right with it (both files shown)", 'proc greet*' in s and 'proc shout' in s, s)
    p = find_on_screen('proc greet*')
    if p:
        mouse(2, 2, p[1]); mouse(2, 2, p[1], up=True)     # (the gutter, left of the line)
    time.sleep(0.4)
    s = screen()
    check("621 context menus: the gutter — breakpoint, bookmark, fold", 'Toggle breakpoint' in s and
          'Toggle bookmark' in s and 'Fold or unfold here' in s, s)
    keys('Escape')
    r = len(screen().rstrip('\n').split('\n'))
    mouse(2, 60, r); mouse(2, 60, r, up=True); time.sleep(0.4)
    s = screen()
    check("621 context menus: the status bar", 'Problems' in s and 'Hide the status bar' in s, s)
    keys('Escape')
    keys('C-b'); time.sleep(0.5)
    p = find_in_tree('demo.nimble')
    if p: mouse(2, p[0], p[1]); mouse(2, p[0], p[1], up=True)
    time.sleep(0.4)
    s = screen()
    check("621 context menus: a file in the tree", 'Open to the side' in s and 'Copy relative path' in s, s)
    p = find_on_screen('Open to the side')
    if p: click(*p)
    time.sleep(0.6)
    check("621 context menus: … open to the side", 'version' in screen() and 'proc shout' in screen(), screen())

def find_in_tree(word, maxx=30):
    """where `word` is in the left dock (not the tab bar or the editor)"""
    for i, l in enumerate(screen().split('\n')):
        k = l.find(word)
        if 0 <= k < maxx and i >= 2: return (k + 2, i + 1)
    return None

def t_621_drag_drop():
    # drag and drop: a tab to the editor's right edge (a split), a file from the tree into the editor (opened),
    # a file onto a folder (moved, after asking), selected text to another place (moved)
    setup()
    open(W + '/notes.txt', 'w').write('alpha beta gamma\nsecond line\n')
    start('src/demo.nim', 'src/demo/utils.nim', w=150, h=40); time.sleep(0.8)
    k = screen().split('\n')[1].find('utils.nim')                           # (its tab: the second row)
    if k >= 0:
        press(k + 2, 2); drag(k + 4, 7); drag(140, 20); release(140, 20)
    time.sleep(0.6)
    s = screen()
    check("621 drag: a tab to the right edge — split right", 'proc greet*' in s and 'proc shout' in s, s)
    keys('C-b'); time.sleep(0.5)
    p = find_in_tree('notes.txt')
    if p:
        press(p[0], p[1]); drag(p[0] + 3, p[1]); drag(60, 15); release(60, 15)
    time.sleep(0.6)
    check("621 drag: a file from the tree into the editor — opened", 'alpha beta gamma' in screen(), screen())
    keys('C-Home'); keys('S-End'); time.sleep(0.2)          # (the first line selected)
    p = find_on_screen('alpha beta gamma')
    q = find_on_screen('second line')
    if p and q:
        press(p[0] + 2, p[1]); drag(p[0] + 4, p[1] + 1); drag(q[0] + 10, q[1]); release(q[0] + 10, q[1])
    time.sleep(0.4)
    keys('C-s'); time.sleep(0.4)
    t = ftext('notes.txt')
    check("621 drag: selected text moved", t.startswith('\nsecond line') or 'second linealpha beta gamma' in t, t)
    p = find_in_tree('notes.txt')
    q = find_in_tree('examples')
    if p and q:
        press(p[0], p[1]); drag(p[0] + 2, p[1]); drag(q[0], q[1]); release(q[0], q[1])
    time.sleep(0.5)
    s = screen()
    check("621 drag: a file onto a folder — asks first", 'Move notes.txt' in s or 'move' in s.lower(), s)
    keys('y'); time.sleep(0.8)
    check("621 drag: … moved", os.path.exists(W + '/examples/notes.txt') and not os.path.exists(W + '/notes.txt'),
          screen())

def fake_atlas621():
    d = TMP + '/atlas621bin'
    shutil.rmtree(d, ignore_errors=True); os.makedirs(d)
    log = TMP + '/atlas621.log'
    if os.path.exists(log): os.remove(log)
    open(d + '/atlas', 'w').write('#!/bin/sh\necho "$@" >> %s\n'
                                  'case "$*" in *install*) echo "[Error]  (jsony) cannot resolve jsony: no versions"; '
                                  'exit 1;; esac\necho "[Success] done"\n' % log)
    os.chmod(d + '/atlas', 0o755)
    return d, log

def t_621_atlas():
    # an Atlas project: its dependencies in the Nim panel (the version, ≠ lock when the checkout is not what
    # atlas.lock pins, not on the path), atlas run from it, its errors in Problems on the .nimble's requires line
    setup()
    d, log = fake_atlas621()
    os.makedirs(W + '/deps/stew/.git'); os.makedirs(W + '/deps/.cache'); os.makedirs(W + '/deps/results/.git')
    open(W + '/deps/stew/.git/HEAD', 'w').write('1' * 40 + '\n')
    open(W + '/deps/results/.git/HEAD', 'w').write('2' * 40 + '\n')
    json.dump({"deps": "deps"}, open(W + '/atlas.config', 'w'))
    json.dump({"packages": [
        {"url": "https://github.com/status-im/nim-stew", "name": "nim-stew", "version": "0.2.0@" + '1' * 40,
         "commit": '1' * 40, "description": "stew helpers", "ondisk": W + '/deps/stew', "features": [], "isRoot": False},
        {"url": "https://github.com/arnetheduck/nim-results", "name": "results", "version": "0.5.1@" + '2' * 40,
         "commit": '2' * 40, "description": "Result type", "ondisk": W + '/deps/results', "features": [],
         "isRoot": False}]}, open(W + '/deps/.cache/atlas.active.json', 'w'))
    json.dump({"items": {"stew": {"dir": "$deps/stew", "url": "x", "commit": '9' * 40, "version": "0.1.0"}}},
              open(W + '/atlas.lock', 'w'))
    open(W + '/nim.cfg', 'w').write('############# begin Atlas config section ##########\n--noNimblePath\n'
                                    '--path:"deps/stew"\n############# end Atlas config section   ##########\n')
    with open(W + '/demo.nimble', 'a') as f: f.write('requires "jsony"\n')
    start('src/demo.nim', w=150, h=40, path=d + ':' + TOOLS + ':$PATH'); time.sleep(0.5)
    keys('M-e'); time.sleep(1.0)
    s = screen()
    check("621 atlas: the dependencies in the Nim panel", 'ATLAS' in s and '2 dependencies in deps' in s and
          re.search(r'stew\s+0\.2\.0\s+≠ lock', s) is not None and re.search(r'results\s+0\.5\.1\s+not on the', s)
          is not None, s)
    palette('Atlas: install'); time.sleep(2.0)
    lg = open(log).read() if os.path.exists(log) else ''
    check("621 atlas: atlas run (no colours)", '--colors:off install' in lg, lg)
    palette('Show problems'); time.sleep(0.6)
    s = screen()
    check("621 atlas: its error in Problems, on the requires line", 'atlas: jsony: cannot resolve jsony' in s, s)
    keys('Escape'); keys('Escape')
    palette('Atlas: update one…'); time.sleep(0.6)
    s = screen()
    check("621 atlas: update one — the dependencies to choose from", 'stew' in s and 'results' in s and
          'Result type' in s, s)
    keys('Enter'); time.sleep(1.5)
    lg = open(log).read() if os.path.exists(log) else ''
    check("621 atlas: … atlas update it", '--colors:off update results' in lg, lg)

DC621 = """import std/os
proc add3(x: int): int {.noinline.} = x + 3
proc twice(x: int): int {.noinline.} =
  result = x * 2
  if result > 100: result = 100
echo add3(paramCount()) + twice(paramCount() + 5)
"""

def t_621_decompile():
    # a Nim proc decompiled (here disassembled with objdump) beside its source; the view follows the cursor
    need('objdump')
    setup({"decompiler.tool": "objdump", "nim.nimsuggest": False})
    open(W + '/src/dc.nim', 'w').write(DC621)
    start('src/dc.nim', w=160, h=40); time.sleep(0.8)
    keys('C-g'); text('2:8'); keys('Enter'); time.sleep(0.2)
    palette('Nim: decompile this proc (side by side)')
    ok = wait_for('add3.*objdump', 60)
    time.sleep(1.5)
    s = screen()
    check("621 decompile: the proc beside its source (objdump)", ok and re.search(r'(ret|mov|lea|add)', s) is not None, s)
    keys('C-g'); text('4:5'); keys('Enter')
    ok = wait_for('twice.*objdump', 20)
    check("621 decompile: the view follows the cursor (another proc)", ok, screen())

def t_621_new_project():
    # New Nim project: a form (name, folder, kind, license, deps, git, tests) → the project made and opened
    setup()
    start('src/demo.nim', w=140, h=40); time.sleep(0.5)
    palette('Nim: new project…'); time.sleep(0.6)
    s = screen()
    check("621 new project: the form", 'New Nim project' in s and 'Kind' in s and 'License' in s and 'Create' in s, s)
    keys('Enter'); time.sleep(0.4)
    check("621 new project: a name is needed", 'The project needs a name' in screen(), screen())
    text('hello621'); keys('Enter'); time.sleep(2.0)
    check("621 new project: made — its .nimble, its source, its tests", os.path.exists(W + '/hello621/hello621.nimble')
          and os.path.exists(W + '/hello621/src/hello621.nim') and os.path.isdir(W + '/hello621/tests'), screen())

# ── ned 6.22 ──

def t_622_settings_controls():
    # the Settings window: each control looks like itself; the scroll bar has ▲ ▼ to tap and a track a tap jumps
    # on (touch screens send taps, not drags); a number has − and + beside it; ↺ puts a changed setting's default
    # back
    setup({"editor.tabSize": None})
    start('src/demo.nim', w=130, h=36); time.sleep(0.5)
    palette('Settings'); time.sleep(0.8)
    s = screen()
    check("622 settings: the scroll bar's arrows", '▲' in s and '▼' in s, s)
    first = any('Theme ' in l for l in s.split('\n')[3:7])
    p = find_on_screen('▼')
    if p:
        for _ in range(4): click(p[0] - 1, p[1])
    time.sleep(0.3)
    s2 = screen()
    check("622 settings: ▼ scrolls the settings down", first and s2 != s and 'Pointer shapes' in s2, s2)
    p = find_on_screen('▲')
    if p: click(p[0] - 1, p[1] + 2)                 # (a tap at the top of the track: back to the top)
    time.sleep(0.3)
    check("622 settings: a tap on the track jumps there", re.search(r'Theme\s', screen()) is not None, screen())
    # the wheel (a swipe on a touch screen) over the fields scrolls them; a drag of the thumb follows the pointer
    p = find_on_screen('Theme ')
    for _ in range(6):
        tm('send-keys', '-t', 'f', '-l', '\x1b[<65;%d;%dM' % (p[0] + 4, p[1] + 3)); time.sleep(0.08)
    time.sleep(0.3)
    check("622 settings: the wheel scrolls the settings", 'Pointer shapes' in screen(), screen())
    a, b = find_on_screen('▲'), find_on_screen('▼')
    if a and b:
        x = a[0] - 1
        tm('send-keys', '-t', 'f', '-l', '\x1b[<0;%d;%dM' % (x, a[1] + 1)); time.sleep(0.1)
        tm('send-keys', '-t', 'f', '-l', '\x1b[<32;%d;%dM' % (x, (a[1] + b[1]) // 2)); time.sleep(0.1)
        tm('send-keys', '-t', 'f', '-l', '\x1b[<32;%d;%dM' % (x, b[1] - 1)); time.sleep(0.1)
        tm('send-keys', '-t', 'f', '-l', '\x1b[<0;%d;%dm' % (x, b[1] - 1)); time.sleep(0.4)
    check("622 settings: the thumb dragged to the end — the last settings", re.search(r'Theme\s', screen()) is None and
          'Restore layout' in screen(), screen())
    p = find_on_screen('▲')
    if p: click(p[0] - 1, p[1] + 2)
    time.sleep(0.3)
    text('tab size'); time.sleep(0.5)
    p = find_on_screen(' + ')
    if p: click(p[0], p[1])
    time.sleep(0.3)
    s = screen()
    check("622 settings: + beside a number adds one (and ↺ shows: not the default now)",
          re.search(r'Tab size\s.*\b5\b', s) is not None and '↺' in s, s)
    p = find_on_screen('↺')
    if p: click(p[0] - 1, p[1])
    time.sleep(0.3)
    s = screen()
    check("622 settings: ↺ — the default back", re.search(r'Tab size\s.*\b4\b', s) is not None and '↺' not in s, s)
    p = find_on_screen(' + ')
    if p: click(p[0], p[1]); click(p[0], p[1])
    keys('Enter')
    for _ in range(20):
        time.sleep(0.2)
        c = open(CFG + '/ned/config.json').read()
        if 'tabSize' in c: break
    check("622 settings: OK writes the number the steps made", re.search(r'"editor\.tabSize":\s*6', c) is not None,
          c[-400:])

NIMS622 = """mode = ScriptMode.Verbose
task build, "build it":
  exec "nim c src/demo.nim"
  cpF
"""

def t_622_nimscript():
    # NimScript files: system's NimScript part (exec, cpFile, task …) on hover and in completion; a module the VM
    # cannot run is a problem; a task's name on hover
    setup({"nim.nimsuggest": False})
    open(W + '/build.nims', 'w').write(NIMS622)
    start('build.nims', w=130, h=36); time.sleep(1.5)
    keys('C-g'); text('3:4'); keys('Enter'); keys('M-h')
    check("622 nims: hover on exec — its doc (system's NimScript part)", wait_for('Executes an external process', 8),
          screen())
    keys('Escape')
    keys('C-g'); text('2:7'); keys('Enter'); keys('M-h')
    check("622 nims: hover on a task's name", wait_for('nim build runs it — build it', 8), screen())
    keys('Escape')
    keys('C-g'); text('4:6'); keys('Enter'); keys('End'); time.sleep(0.2); keys('C-space'); time.sleep(1.0)
    check("622 nims: completion — cpFile", re.search(r'cpFile', screen()) is not None, screen())
    keys('Escape')
    keys('C-Home'); text('import std/osproc\n'); keys('C-s'); time.sleep(1.0)
    palette('Show problems')
    check("622 nims: a module NimScript cannot run, a problem", wait_for('std/osproc does not run in NimScript', 12),
          screen())
    # ned --format on scripts: switches (--path:"../src") and the package's lined-up fields stay as written
    open(W + '/t622.nims', 'w').write('--path:"../src"\n--d:release\nswitch("path", "x")\n')
    open(W + '/t622.nimble', 'w').write('version       = "0.1.0"\nauthor        = "me"\nlicense       = "MIT"\n\n'
                                        'requires "nim >= 2.0"\n')
    r = subprocess.run([BIN, '--format', W + '/t622.nims', W + '/t622.nimble'], capture_output=True, text=True)
    a, b = open(W + '/t622.nims').read(), open(W + '/t622.nimble').read()
    check("622 nims: ned --format keeps a script's switches and lined-up fields", r.returncode == 0 and
          '--path:"../src"\n--d:release\n' in a and 'version       = "0.1.0"' in b, r.stdout + r.stderr + a + b)

PLUG622 = """import nedplugin

proc toggle(b: Buf) =
  let cm = b.lineComment
  message("no line comment " & cm)
  b.
"""

def t_622_plugin_api():
    # a plugin: `import nedplugin` resolves — its API on hover (with its doc) and in completion
    setup({"nim.nimsuggest": False})
    d = CFG + '/ned/plugins/p622'
    os.makedirs(d, exist_ok=True)
    open(d + '/plugin.nims', 'w').write(PLUG622)
    start(d + '/plugin.nims', w=130, h=36); time.sleep(1.5)
    keys('C-g'); text('5:4'); keys('Enter'); keys('M-h')
    check("622 plugin: hover on message — the plugin API's doc", wait_for('the status line', 8), screen())
    keys('Escape')
    keys('C-g'); text('4:18'); keys('Enter'); keys('M-h')
    check("622 plugin: hover on b.lineComment", wait_for("language's line comment", 8), screen())
    keys('Escape')
    keys('C-g'); text('6:5'); keys('Enter'); keys('End'); text('lineCo'); keys('C-space'); time.sleep(1.0)
    s = screen()
    keys('Escape'); keys('BSpace', 'BSpace', 'BSpace', 'BSpace', 'BSpace', 'BSpace'); text('setCu')
    keys('C-space'); time.sleep(1.0)
    s2 = screen()
    check("622 plugin: completion after b. — the Buf procs", re.search(r'ƒ lineComment', s) is not None and
          re.search(r'ƒ setCursor', s2) is not None, s + s2)
    keys('Escape')

DOC622 = """iterator oddNumbers(a: openArray[int]): int = ## hwad \\
  ## hello
  for x in a:
    if x mod 2 == 1: yield x

const flag* = defined(linux) or
    defined(macosx) ## \\
  ## Whether it is a Unix
  ## we know.

for o in oddNumbers([1, 2, 3]): echo o, flag
"""

def t_622_doc_comments():
    # a doc comment that starts on the declaration's line and goes on below, a line ending in \\ (joined, as
    # nim doc does): the hover shows it as one text
    setup({"nim.nimsuggest": False})
    open(W + '/src/docs.nim', 'w').write(DOC622)
    start('src/docs.nim', w=130, h=36); time.sleep(1.5)
    keys('C-g'); text('11:12'); keys('Enter'); keys('M-h')
    ok = wait_for('hwad hello', 8)
    check("622 docs: ## on the header line, \\ joining the next one", ok and re.search(r'│ hwad hello\s', screen()),
          screen())
    keys('Escape')
    keys('C-g'); text('11:42'); keys('Enter'); keys('M-h')
    check("622 docs: a constant over two lines, its ## \\ doc below it", wait_for('Whether it is a Unix we know', 8),
          screen())

# ── ned 6.23 ──

def t_623_decompile_menu():
    # the decompiler in the menu bar: Run › Decompile (this proc, a program, a function of the open binary), and
    # Nim › Inspect
    setup({"nim.nimsuggest": False})
    start('src/demo.nim', w=140, h=40); time.sleep(0.6)
    keys('F10'); time.sleep(0.3)
    for _ in range(4): keys('Right')
    time.sleep(0.4)
    s = screen()
    check("623 menu bar: Run › Decompile", 'Decompile' in s, s)
    p = find_on_screen('Decompile')
    if p:
        click(p[0] + 1, p[1]); time.sleep(0.5)
        s = screen()
        check("623 menu bar: … this proc, a program, a function of the open binary",
              'This proc (side by side)' in s and 'A program…' in s and 'A function of the open binary…' in s, s)
    keys('Escape'); keys('Escape'); keys('Escape'); time.sleep(0.3)
    keys('F10'); time.sleep(0.3)
    for _ in range(6): keys('Right')
    time.sleep(0.4)
    p = find_on_screen('Inspect')
    if p:
        click(p[0] + 1, p[1]); time.sleep(0.5)
    s = screen()
    check("623 menu bar: Nim › Inspect › Decompile this proc", 'Decompile this proc' in s and 'Decompile a program…' in s, s)
    keys('Escape'); keys('Escape'); keys('Escape')

ALIGN623 = """import std/os

const
  Version = "1.2" ## the version
  LongerName = 42 ## the answer
  X = 1 # short

proc greet() = echo "hi"
"""

def t_623_align_comments():
    # nim.format.alignComments: the comments after code on lines next to each other start in one column
    setup({"nim.nimsuggest": False, "nim.format.alignComments": True, "nim.formatter": "builtin"})
    open(W + '/src/al623.nim', 'w').write(ALIGN623)
    start('src/al623.nim', w=120, h=30); time.sleep(0.8)
    palette('Format document'); time.sleep(1.0)
    keys('C-s'); time.sleep(0.6)
    t = ftext('src/al623.nim')
    cols = [l.index('#') for l in t.split('\n') if '#' in l and not l.lstrip().startswith('#')]
    check("623 align comments: the trailing ## and # in one column", len(cols) == 3 and len(set(cols)) == 1, t)

C623 = """#include <stdio.h>
#include "shape.h"

static int area(int width, int height)
{
    return width * height;
}

int total(void)
{
    struct rect r = {0};
    int a = area(3, 4);
    return a + r.w + COLOR_BLUE;
}
"""

SHAPE623 = """#ifndef SHAPE_H
#define SHAPE_H
/* a rectangle */
struct rect {
    char tag;
    int w;
    double h;
};
enum color { COLOR_RED, COLOR_GREEN = 4, COLOR_BLUE };
int total(void);
#endif
"""

def t_623_c_engine():
    # ned's own C engine (no clangd): the parameters' names before literal arguments, a struct's size and layout and
    # an enum constant's value on hover, the compiler's own fixes on Alt+Enter, the call hierarchy, header ⇄ source
    need('cc')
    setup({"c.engine": "builtin", "nim.nimsuggest": False})
    os.makedirs(W + '/c623', exist_ok=True)
    open(W + '/c623/shape.h', 'w').write(SHAPE623)
    open(W + '/c623/shape.c', 'w').write(C623)
    start('c623/shape.c', w=140, h=40); time.sleep(1.2)
    check("623 C engine: the parameters' names before literal arguments", wait_for(r'area\(width: 3, height: 4\)', 6),
          screen())
    keys('C-g'); text('11:14'); keys('Enter'); keys('M-h')
    check("623 C engine: hover on a struct — its size and its fields' offsets",
          wait_for(r'16 bytes', 6) and 'offset' in screen(), screen())
    keys('Escape')
    keys('C-g'); text('13:26'); keys('Enter'); keys('M-h')
    check("623 C engine: hover on an enum constant — its value", wait_for(r'= 5\b', 6), screen())
    keys('Escape')
    # the compiler's fix: a pointer's member with . → ->
    keys('C-g'); text('12'); keys('Enter'); keys('End'); keys('Enter')
    text('struct rect *q = &r; '); keys('Enter'); text('q.w = a; ')
    ok = wait_for(r"is a pointer|did you mean to use '->'|member reference type", 15)
    check("623 C engine: the compiler's error on a pointer's member", ok, screen())
    if ok:
        keys('M-Enter'); time.sleep(0.8)
        s = screen()
        ok = "'.' to '->'" in s or "Change '.'" in s or 'Replace' in s
        check("623 C engine: … Alt+Enter offers the compiler's fix (. → ->)", ok, s)
        if ok:
            keys('Enter'); time.sleep(0.5); keys('C-s'); time.sleep(0.5)
            check("623 C engine: … applied", 'q->w = a;' in ftext('c623/shape.c'), ftext('c623/shape.c'))
            # two fixes on one line: the first one picked is the first one applied (6.24 applied the last)
            keys('End'); keys('Enter'); text('q.h = q.w; '); keys('Home')
            ok = wait_for(r"is a pointer|did you mean to use '->'|member reference type", 15); time.sleep(1.0)
            keys('M-Enter'); time.sleep(0.8); keys('Enter'); time.sleep(0.5); keys('C-s'); time.sleep(0.5)
            t = ftext('c623/shape.c')
            check("6241 C engine: two compiler fixes on a line — the one picked (the first) is the one applied",
                  ok and 'q->h = q.w;' in t, t)
    keys('Escape')
    # the call hierarchy of area: its caller and nothing it calls
    keys('C-g'); text('4:13'); keys('Enter')
    palette('Call hierarchy (callers and calls)'); time.sleep(0.8)
    s = screen()
    check("623 C engine: call hierarchy — area is called by total", 'Call hierarchy — area' in s and '← total' in s, s)
    keys('Escape'); time.sleep(0.2)
    palette('C: switch between header and source'); time.sleep(0.8)
    check("623 C engine: header ⇄ source — shape.c → shape.h", wait_for(r'shape\.h', 4) and
          'enum color' in screen(), screen())
    palette('C: switch between header and source'); time.sleep(0.8)
    check("623 C engine: … and back", 'static int area' in screen(), screen())

RW623 = """import std/tables

type Color = enum red, green, blue

proc area(width, height: int): int = width * height

proc describe(c: Color): string =
  if c == red:
    result = "warm"
  elif c == green or c == blue:
    result = "cool"

proc sign(x: int): string =
  if x > 0:
    result = "+"
  else:
    result = "-"

let counts = initTable[string, int]()
let n = area(3, 4)
echo len(counts)
echo counts.len
const Mask = 255
let s = "abc"
case n
of 1, 2: echo "small"
of 3..10: echo "mid"
else: echo "big"
"""

def t_623_nim_rewrites():
    # Alt+Enter rewrites learned from other languages' servers: case ⇄ if/elif, an int literal in hex, f(x) ⇄ x.f,
    # the arguments named, the type written out, an if/else inverted; Enter in a ## comment goes on with ##
    setup({"nim.nimsuggest": False})
    open(W + '/a.nim', 'w').write(RW623)
    start('a.nim', w=130, h=40); time.sleep(2.5)
    t, sc = qf_fix(25, 1, 'Write as if/elif')
    check('623 rewrite: case → if/elif', t and 'if n == 1 or n == 2: echo "small"\nelif n in 3..10: echo "mid"\n'
          'else: echo "big"' in t, sc)
    t, sc = qf_fix(23, 15, 'Write 255 as 0xFF')
    check('623 rewrite: an integer literal in hexadecimal', t and 'const Mask = 0xFF\n' in t, sc)
    t, sc = qf_fix(22, 15, 'Write as len(counts)')
    check('623 rewrite: x.f → f(x)', t and t.count('echo len(counts)') == 2, sc)
    t, sc = qf_fix(21, 7, 'Write as counts.len')
    check('623 rewrite: f(x) → x.f', t and 'echo counts.len\necho len(counts)' in t, sc)
    t, sc = qf_fix(20, 10, 'Name the arguments')
    check('623 rewrite: the arguments named', t and 'let n = area(width = 3, height = 4)' in t, sc)
    t, sc = qf_fix(19, 5, 'Write the type')
    check('623 rewrite: the type written out', t and 'let counts: Table[string, int] = initTable' in t, sc)
    t, sc = qf_fix(14, 3, 'Invert the if')
    check('623 rewrite: the if inverted', t and '  if x <= 0:\n    result = "-"\n  else:\n    result = "+"\n' in t, sc)
    t, sc = qf_fix(8, 3, 'Write as a case')
    check('623 rewrite: if/elif → case (every value covered: no else)', t and
          '  case c\n  of red:\n    result = "warm"\n  of green, blue:\n    result = "cool"\n' in t and
          'else: discard' not in t.split('proc sign')[0], sc)
    keys('Escape'); keys('C-End'); keys('Enter'); text('## one'); keys('Enter'); text('two'); keys('C-s'); time.sleep(0.6)
    check('623 Enter in a ## comment: the next line starts with ##', '## one\n## two' in ftext('a.nim'), ftext('a.nim')[-200:])

def t_623_call_args():
    # nim.completeCallArguments: a routine completed with its parameters to fill in (Tab to the next)
    setup({"nim.nimsuggest": False, "nim.completeCallArguments": True})
    open(W + '/a.nim', 'w').write('proc rectArea(width, height: int): int = width * height\n\n')
    start('a.nim', w=120, h=30); time.sleep(1.5)
    keys('C-End'); text('echo rectAr'); wait_for(r'rectArea', 5); time.sleep(0.3)
    keys('Enter'); time.sleep(0.4)
    text('3'); keys('Tab'); text('4'); keys('Escape'); keys('C-s'); time.sleep(0.5)
    check('623 completion: the call with its parameters to fill in', 'echo rectArea(3, 4)' in ftext('a.nim'),
          ftext('a.nim'))

EMIT623 = """{.emit: \"\"\"
static int twice(int x){return x*2;}
\"\"\".}

proc twice(x: cint): cint {.importc, nodecl.}
echo twice(3)
"""

def t_623_emit_builtin_c():
    # C in {.emit.}: without clangd, ned's own C formatter lays it out (as clang-format would): Format document
    setup({"nim.nimsuggest": False, "c.engine": "builtin", "c.formatter": "builtin", "nim.formatter": "builtin",
           "c.format.style": "LLVM"})
    open(W + '/src/em623.nim', 'w').write(EMIT623)
    start('src/em623.nim', w=120, h=30); time.sleep(0.8)
    palette('Format document'); time.sleep(1.0)
    keys('C-s'); time.sleep(0.6)
    t = ftext('src/em623.nim')
    check("623 emit: the C laid out by ned's own C formatter (c.format.style LLVM)",
          'static int twice(int x) { return x * 2; }' in t, t)

# ── ned 6.24 ──

def bg_at_col(row, k):
    """the 24-bit background colour at column k of an ANSI row, or None"""
    bg, col, i = None, 0, 0
    while i < len(row):
        m = re.match(r'\x1b\[([0-9;:]*)m', row[i:])
        if m:
            ps = m.group(1).split(';')
            j = 0
            while j < len(ps):
                if ps[j] == '48' and j + 4 < len(ps) and ps[j + 1] == '2':
                    bg = tuple(ps[j + 2:j + 5]); j += 5
                elif ps[j] in ('0', '49', ''):
                    bg = None; j += 1
                elif ps[j] in ('38', '58') and j + 4 < len(ps) and ps[j + 1] == '2':
                    j += 5
                else: j += 1
            i += m.end(); continue
        if col == k: return bg
        col += 1; i += 1
    return None

def bg_of(text, word):
    row = ansi_row(text)
    plain = re.sub(r'\x1b\[[0-9;:]*m', '', row)
    k = plain.find(word)
    return bg_at_col(row, k) if k >= 0 else None

CE624 = """proc square(num: int): int =
  num * num

echo square(6)
"""

def t_624_compiler_explorer():
    # Compiler Explorer (as godbolt.org): the file beside its assembly, compiled again as you type; a Nim line and
    # its instructions in one colour; the toolbar; what an instruction is on hover; F12 to a label; the program run;
    # two option sets compared
    need('gcc')
    setup({"nim.nimsuggest": False, "compilerExplorer.options": "-d:release", "compilerExplorer.delay": 300})
    open(W + '/ce.nim', 'w').write(CE624)
    start('ce.nim', w=150, h=40); time.sleep(1.0)
    keys('C-g'); text('2:3'); keys('Enter')
    palette('Compiler Explorer')
    ok = wait_for(r'square:', 40)
    s = screen()
    check('624 CE: the assembly beside the file (square and its imul)', ok and 'imul' in s, s)
    check('624 CE: the toolbar over it (options, compiler, target, filters, run, compare)',
          '-d:release ✎' in s and 'Filters ▾' in s and '▶ run' in s and re.search(r'(gcc|clang)[^▾]*▾', s), s)
    check('624 CE: what compiled it, and how much was filtered', re.search(r'compiled in [0-9.]+ s', s) and
          'filtered' in s, s)
    # the colours: the Nim line and its instructions alike
    time.sleep(0.6)
    keys('Escape'); time.sleep(0.3)
    src_bg = bg_of('num * num', '*')                   # (not on `num`: the word under the cursor is highlighted)
    asm_bg = bg_of('imul', 'imul')
    close = src_bg is not None and asm_bg is not None and max(abs(int(a) - int(b)) for a, b in zip(src_bg, asm_bg)) <= 12
    other = bg_of('ret', 'ret')                         # (an instruction of another line: another colour)
    check('624 CE: a Nim line and the instructions it made in one colour (the cursor line\'s a little lighter)',
          close and other != asm_bg, str((src_bg, asm_bg, other)))
    # typing: compiled again
    keys('End'); text(' * 3')
    ok = wait_for(r'(lea|imul)[^\n]*3', 15)
    check('624 CE: typing compiles it again (no save)', ok, screen())
    check('624 CE: … the file is not saved for it', '* 3' not in ftext('ce.nim'), ftext('ce.nim'))
    # the view: hover on an instruction, F12 on a jump's label
    p = find_on_screen('imul')
    if p:
        click(p[0], p[1]); time.sleep(0.3)
        keys('M-h'); time.sleep(0.6)
        check('624 CE: hover on an instruction: what it does', 'Signed multiply' in screen(), screen())
        keys('Escape')
    # the program run (godbolt's Execution)
    palette('Compiler Explorer: run the program after each compile (on / off)')
    ok = wait_for(r'Program returned: 0', 40)
    check("624 CE: the program run — its exit code and output in the Output panel", ok and '108' in screen(),
          screen())
    palette('Compiler Explorer: run the program after each compile (on / off)')
    # two option sets compared
    palette('Compiler Explorer: compare with other options…'); time.sleep(0.4)
    check('624 CE: compare — the other options proposed (release → danger)', '-d:danger' in screen(), screen())
    keys('Enter')
    ok = wait_for(r'Diff: ce\.nim', 40)
    check('624 CE: compare two option sets in the diff view', ok and '-d:danger' in screen(), screen())

def t_624_ce_toolbar():
    # the toolbar over the assembly is clicked, as on a tablet: Filters ▾ and an item in it, the compiler ▾ and one
    # of the compilers — each sets what was clicked (6.24 set the last item of the list, whichever was clicked)
    need('gcc'); need('clang')
    setup({"nim.nimsuggest": False, "compilerExplorer.delay": 300})
    open(W + '/ce.nim', 'w').write(CE624)
    start('ce.nim', w=150, h=40); time.sleep(1.0)
    palette('Compiler Explorer')
    ok = wait_for(r'square:', 40); time.sleep(0.5)
    def at(word, below=0):
        for r, l in enumerate(screen().splitlines()):
            c = l.find(word)
            if c >= 0 and r + 1 > below: return (c + 1, r + 1)      # (tmux's columns and rows count from 1)
        return None
    def cfg():
        return json.loads(open(CFG + '/ned/config.json').read())
    p = at('Filters ▾')
    check('624 CE toolbar: Filters ▾ is there', ok and p is not None, screen())
    if p is None: return
    click(p[0] + 2, p[1]); ok = wait_for('Library functions', 5)
    q = at('Library functions', p[1])
    check('624 CE toolbar: a click opens the filters', ok and q is not None, screen())
    if q is None: return
    click(q[0] + 2, q[1]); time.sleep(1.5)
    c = cfg()
    check('624 CE toolbar: the filter clicked is the one changed (Library functions off, Demangle still on)',
          c.get("compilerExplorer.filterLibrary") is False and c.get("compilerExplorer.demangle", True) is True, c)
    ok = wait_for(r'filtered\)', 20)
    p = at('gcc 1') or at('gcc ▾') or at('gcc')
    check('624 CE toolbar: the compiler ▾ is there', ok and p is not None, screen())
    if p is None: return
    click(p[0] + 1, p[1]); ok = wait_for('zig cc', 5)
    q = None
    for r, l in enumerate(screen().splitlines()):
        if r + 1 > p[1] and re.search(r'(^|[ │✓])clang\b', l) and 'zig' not in l:
            q = (l.find('clang') + 1, r + 1); break
    check('624 CE toolbar: a click opens the compilers', ok and q is not None, screen())
    if q is None: return
    click(q[0] + 1, q[1]); time.sleep(1.5)
    c = cfg()
    check('624 CE toolbar: the compiler clicked is the one set (clang, not the last item, zig)',
          c.get("compilerExplorer.compiler") == "clang", c)
    check('624 CE toolbar: … and the assembly is made by it', wait_for(r'; nim [0-9.]+ · clang', 40), screen())

def t_6241_dock_view_menu():
    # the dock's own menu (right-click its header): each item shows its own view — 6.24 showed the last one (Tests)
    setup()
    start('src/demo.nim', w=130, h=34); time.sleep(0.8)
    if 'demo.nimble' not in screen(): keys('C-b'); time.sleep(0.6)
    p = None
    for r, l in enumerate(screen().splitlines()):
        c = l.find('✓')
        if c >= 0 and '▤' in l: p = (c + 4, r + 1); break        # (the header's empty part, after its icons)
    check('6241 dock menu: the Files dock and its header', p is not None and 'demo.nimble' in screen(), screen())
    if p is None: return
    tm('send-keys', '-t', 'f', '-l', '\x1b[<2;%d;%dM' % p); time.sleep(0.05)
    tm('send-keys', '-t', 'f', '-l', '\x1b[<2;%d;%dm' % p); time.sleep(0.5)
    q = None
    for r, l in enumerate(screen().splitlines()):
        if r + 1 > p[1] and 'SEARCH' in l:
            q = (l.find('SEARCH') + 2, r + 1); break
    check('6241 dock menu: it lists the views', q is not None and 'TESTS' in screen(), screen())
    if q is None: return
    click(*q); time.sleep(0.8)
    s = screen()
    check('6241 dock menu: Search is the view shown (not the last, Tests)',
          'demo.nimble' not in s and 'files' in s and '.*' in s, s)

def t_6241_ce_all_procs():
    # a library module — procs nothing calls, overloads of one operator: every one is in the assembly (Nim would
    # leave them all out); off in Filters ▾, only what the program uses is left
    need('gcc')
    setup({"nim.nimsuggest": False, "compilerExplorer.delay": 300, "compilerExplorer.options": "-d:release"})
    open(W + '/lib.nim', 'w').write('type\n  Meters* = distinct int\n  Feet* = distinct int\n\n'
                                     'func `==`*(a, b: Meters): bool = int(a) == int(b)\n'
                                     'func `==`*(a, b: Feet): bool = int(a) == int(b)\n\n'
                                     'proc sevenTimes*(x: int): int = x * 7\n\n'
                                     'proc twice*[T](x: T): T = x\n')
    start('lib.nim', w=150, h=40); time.sleep(1.0)
    palette('Compiler Explorer')
    label = r'(?m)│ +[0-9]+ +%s(__[A-Za-z0-9_]+)?:\s*[▐▕▌]?\s*$'   # (a label in the assembly pane, not the source)
    ok = wait_for(label % 'sevenTimes', 40); time.sleep(0.5)
    s = screen()
    check('6241 CE: every proc of a library module (nothing calls them) — its label in the assembly, == too',
          ok and re.search(label % '`==`', s) is not None, s)
    p = None
    for r, l in enumerate(s.splitlines()):
        c = l.find('Filters ▾')
        if c >= 0: p = (c + 3, r + 1); break
    if p is None: return
    click(*p); ok = wait_for('Every proc', 5)
    q = None
    for r, l in enumerate(screen().splitlines()):
        c = l.find('Every proc')
        if c >= 0 and r + 1 > p[1]: q = (c + 2, r + 1); break
    if q is None:
        check('6241 CE: Filters ▾ has "Every proc of the file"', False, screen()); return
    click(*q); ok = wait_for(r'nothing here|filtered\)', 30); time.sleep(1.5)
    s = screen()
    check('6241 CE: switched off, procs nothing calls are left out again', re.search(label % 'sevenTimes', s) is None, s)

def t_625_indent():
    # indent and unindent, wherever they are looked for: the palette ("unindent"), the Edit menu, the touch bar's
    # ⇥ ⇤, vim's >> << and, in insert mode, Ctrl+T / Ctrl+D
    setup({"ui.touchBar": "on", "ui.touchBarKeys": ["esc", "indent", "unindent", "save"]})
    open(W + '/ind.nim', 'w').write('proc f() =\n  echo 1\n  echo 2\n')
    start('ind.nim', w=120, h=30); time.sleep(0.6)
    keys('C-g'); text('2'); keys('Enter')
    keys('C-p'); text('>unindent'); time.sleep(0.5)
    check('625 palette: "unindent" finds it', 'Unindent lines' in screen(), screen())
    keys('Enter'); time.sleep(0.3); keys('C-s'); time.sleep(0.4)
    check('625 Unindent lines: the line one level out', ftext('ind.nim').split('\n')[1] == 'echo 1', repr(ftext('ind.nim')))
    keys('F10'); time.sleep(0.4)
    if re.search(r'│\s+File\s+›', screen()): keys('Down', 'Right')      # (a narrow window: the menus in one list)
    else: keys('Right')
    time.sleep(0.4)
    check('625 the Edit menu has Indent and Unindent', 'Indent' in screen() and 'Unindent' in screen(), screen())
    keys('Escape'); keys('Escape'); time.sleep(0.2)
    p = None
    for r, l in enumerate(screen().splitlines()):
        c = l.find('⇥')
        if c >= 0 and 'Save' in l: p = (c + 1, r + 1)
    check('625 the touch bar has ⇥ and ⇤', p is not None and '⇤' in screen(), screen()[-400:])
    if p:
        click(*p); time.sleep(0.4); keys('C-s'); time.sleep(0.4)
        check('625 the touch bar\'s ⇥ indents the line', ftext('ind.nim').split('\n')[1] == '  echo 1',
              repr(ftext('ind.nim')))
    palette('Toggle vim mode'); time.sleep(0.4)
    keys('Escape'); keys('C-g'); text('3'); keys('Enter'); text('>>'); time.sleep(0.3)
    text(':w'); keys('Enter'); time.sleep(0.4)
    check('625 vim >>: one level in', ftext('ind.nim').split('\n')[2] == '    echo 2', repr(ftext('ind.nim')))
    text('<<'); time.sleep(0.2); text('A'); keys('C-t'); time.sleep(0.2); text('3'); keys('Escape')
    text(':w'); keys('Enter'); time.sleep(0.4)
    check('625 vim <<, then Ctrl+T in insert mode: in again, and typing goes on at the end', ftext('ind.nim').split('\n')[2] == '    echo 23',
          repr(ftext('ind.nim')))
    text('A'); keys('C-d'); keys('Escape'); text(':w'); keys('Enter'); time.sleep(0.4)
    check('625 vim Ctrl+D in insert mode: one level out', ftext('ind.nim').split('\n')[2] == '  echo 23',
          repr(ftext('ind.nim')))

def place_of(word, s=None):
    """(column, row) from 1 of the first place `word` is on the screen, or None"""
    for r, l in enumerate((s or screen()).splitlines()):
        c = l.find(word)
        if c >= 0: return (c + 1, r + 1)
    return None

def t_625_plugins_menu():
    # 6.25: ned's own plugins — the menu bar's Plugins menu, the dock's AVAILABLE section: one turned on there with a
    # tap (dial: Ctrl+A in vim mode adds 1), its settings, then removed again (it goes back to AVAILABLE)
    setup({"editor.vimMode": True})
    open(W + '/dl.nim', 'w').write('let n = 41\nlet day = "monday"\n')
    start('dl.nim', w=150, h=44); time.sleep(0.8)
    p = place_of('Plugins')
    check('625 the menu bar has Plugins', p is not None and p[1] <= 2, screen()[:300])
    if p:
        click(*p); time.sleep(0.5)
        s = screen()
        check('625 the Plugins menu: the panel, ned\'s own, install, uninstall, new',
              'Plugins panel' in s and "Available plugins (ned's own)" in s and 'Uninstall' in s and
              'Install from git' in s and 'New plugin' in s, s)
        keys('Escape'); time.sleep(0.2)
    palette('Plugins panel'); time.sleep(1.0)
    ok = wait_for(r"AVAILABLE · ned's own plugins", 8)
    s = screen()
    check('625 the dock lists ned\'s own plugins under AVAILABLE, each with what it does',
          ok and 'dial' in s and 'case-change' in s and 'line up the =' in s, s)
    def avail_at(name):
        for r, l in enumerate(screen().splitlines()):
            m = re.search(r'\+ ' + name + r'\b', l)
            if m: return (m.start() + 3, r + 1)
        return None
    # (6.28: a right-click on one gives its menu — Turn on, View its source, Copy …; a tap turns it on at once)
    o = avail_at('dotenv')
    if o:
        tm('send-keys', '-t', 'f', '-l', '\x1b[<2;%d;%dM' % o); time.sleep(0.05)
        tm('send-keys', '-t', 'f', '-l', '\x1b[<2;%d;%dm' % o); time.sleep(0.5)
        check('628 a right-click on one: Turn on, View its source, Copy to my plugins',
              'Turn on' in screen() and 'View its source' in screen(), screen())
        keys('Escape'); time.sleep(0.3)
    d = avail_at('dial')
    if d: click(*d); time.sleep(0.5)
    ok = wait_for(r'INSTALLED(?s:.*)dial', 10)
    check('625 turned on: dial is INSTALLED (ned\'s) — 6.28: with one tap', ok, screen())
    ok = wait_for(r'dial is on: .*(vim keys|command|setting)', 40)
    check('628 … and the status bar says what it adds, listed under it in the dock', ok, screen())
    cfg = json.load(open(CFG + '/ned/config.json'))
    check('625 … and plugins.bundled says so', 'dial' in cfg.get('plugins.bundled', []), repr(cfg.get('plugins.bundled')))
    keys('Escape'); time.sleep(0.2)
    keys('C-g'); text('1:9'); keys('Enter'); time.sleep(0.3)
    keys('Escape'); keys('C-a'); time.sleep(4)          # (the plugin's process starts on the first use)
    keys('C-a'); time.sleep(1.5)
    text(':w'); keys('Enter'); time.sleep(0.5)
    check('625 dial: Ctrl+A in vim mode adds 1 (twice: 43)', ftext('dl.nim').startswith('let n = 43'), repr(ftext('dl.nim')))
    # removed: back to AVAILABLE
    palette('Plugins: uninstall / remove one…'); time.sleep(0.6)
    text('dial'); time.sleep(0.3); keys('Enter'); time.sleep(1.0)
    cfg = json.load(open(CFG + '/ned/config.json'))
    check('625 removed: not in plugins.bundled any more', 'dial' not in cfg.get('plugins.bundled', []),
          repr(cfg.get('plugins.bundled')))
    palette('Plugins panel'); time.sleep(1.0)
    s = screen()
    check('625 … and it is in AVAILABLE again', re.search(r'\+ dial\b', s) is not None, s)

def t_625_which_key():
    # 6.25: which-key — vim mode, g and a pause: a box above the status bar of what may follow (ned's own: d go to
    # definition; a plugin's with what it does); a tap on one types it; the box goes when the keys go on
    setup({"editor.vimMode": True, "plugins.bundled": ["which-key", "harpoon"], "plugins.which-key.delay": 300})
    open(W + '/wk.nim', 'w').write('proc hello() = discard\nhello()\n\n\n')
    start('wk.nim', w=150, h=40); time.sleep(1.0)
    keys('Escape'); text('g'); time.sleep(5)              # (the plugins' process starts on the first use)
    keys('Escape'); time.sleep(0.3); text('g')
    ok = wait_for('go to definition', 6)
    s = screen()
    check('625 which-key: g and a pause — the box of what may follow', ok and 'first line' in s and 'g …' in s, s)
    text('g'); time.sleep(0.5)
    check('625 which-key: the next key typed — the box goes', 'go to definition' not in screen(), screen())
    text(' '); ok = wait_for(r'<leader>', 6)
    s = screen()
    check("625 which-key: <leader> — a plugin's mappings with what they say (harpoon's)", ok and 'harpoon' in s.lower(), s)
    keys('Escape'); time.sleep(0.3)
    keys('C-g'); text('2:1'); keys('Enter'); keys('Escape'); text('z')
    ok = wait_for('this line in the middle', 6)
    p = place_of('fold all')
    if ok and p:
        click(*p); time.sleep(0.5)                          # (zM's cell)
    check('625 which-key: z — a tap on one types it (zM: everything folded)', ok and 'this line in the middle' not in screen(),
          screen())

def t_625_oil():
    # 6.25: oil — the folder as text: a line changed is a rename, a line deleted goes to the trash, a new line makes a
    # file; saving lists what will happen and asks; Alt+Enter opens a folder, Alt+Up the one above
    setup({"plugins.bundled": ["oil"]})
    os.makedirs(W + '/oilt/sub', exist_ok=True)
    for f in ['a.txt', 'b.nim', 'sub/in.txt']: open(W + '/oilt/' + f, 'w').write('text of ' + f)
    start('oilt/b.nim', w=150, h=40); time.sleep(0.8)
    palette("Oil: edit this file's folder as text")
    ok = wait_for(r'sub/', 15)
    s = screen()
    check('625 oil: the folder as text — sub/ first, then the files', ok and 'a.txt' in s and 'b.nim' in s, s)
    # b.nim → c.nim; a.txt deleted; notes.md added
    keys('C-Home'); keys('Down'); keys('S-End'); keys('Delete'); time.sleep(0.2)     # (the a.txt line emptied)
    keys('Down'); keys('Home'); keys('S-End'); text('c.nim'); keys('End'); keys('Enter'); text('notes.md')
    keys('C-s')
    ok = wait_for(r'Rename b\.nim → c\.nim', 8)
    s = screen()
    check('625 oil: saving says what will happen and asks', ok and 'Delete a.txt' in s and 'Make notes.md' in s, s)
    keys('y'); time.sleep(0.4)
    yes = place_of('Yes')
    if yes and 'Rename b.nim' in screen(): click(*yes); time.sleep(0.5)
    done = lambda: (os.path.exists(W + '/oilt/c.nim') and not os.path.exists(W + '/oilt/b.nim') and
                    not os.path.exists(W + '/oilt/a.txt') and os.path.exists(W + '/oilt/notes.md'))
    wait_until(done, 8)                                   # (under load the moves take a moment)
    check('625 oil: renamed, deleted (to the trash), made', done(), repr(os.listdir(W + '/oilt')))
    keys('C-Home'); keys('M-Enter'); ok = wait_for(r'in\.txt', 6)
    check('625 oil: Alt+Enter on sub/ — the tab lists sub/', ok, screen())
    keys('M-Up'); ok = wait_for(r'notes\.md', 6)
    check('625 oil: Alt+Up — the folder above again', ok, screen())

def t_625_engine_checks():
    # 6.25: the engine's checks while you type — a case over an enum that leaves values out (and its fix: the branches
    # added), an argument that can never be the parameter's type, a method call whose value is neither used nor
    # discarded
    setup({"nim.nimsuggest": False, "nim.liveDiagnosticsFrom": "nimsuggest"})
    open(W + '/ec5.nim', 'w').write('import std/strutils\n\ntype Color = enum red, green, blue\n\nproc name(c: Color): string =\n'
                                    '  case c\n  of red: "r"\n  of green: "g"\n\nproc twice(n: int): int = n * 2\n\n'
                                    'proc main() =\n  var s = @[1, 2]\n  echo twice("x")\n  s.pop()\n  echo s.join(",")\n\nmain()\n')
    start('ec5.nim', w=150, h=40); time.sleep(1.5)
    keys('C-g'); text('18'); keys('Enter', 'End', 'Enter')
    wait_for(r'type mismatch', 10); time.sleep(1.0)
    palette('Show problems'); time.sleep(0.8)
    s = screen()
    check('625 engine: a case that leaves out an enum value', 'not all cases are covered; missing: {blue}' in s, s)
    check("625 engine: an argument of the wrong type (a string for an int)", "got 'string' for '\"x\"' but expected 'int'" in s, s)
    check("625 engine: a method call's value neither used nor discarded", "'s.pop()' is of type 'int'" in s, s)
    keys('Escape')
    keys('C-g'); text('6:3'); keys('Enter', 'M-Enter'); time.sleep(0.8)
    ok = wait_for(r'Add the missing branches', 4)
    keys('Enter'); time.sleep(0.5); keys('C-s'); time.sleep(0.4)
    check('625 engine: its fix adds the branch', ok and 'of blue:' in ftext('ec5.nim'), ftext('ec5.nim'))

def t_625_chain_hints():
    # 6.25: a call chain over several lines — the type after each step, at the line's end
    setup({"nim.nimsuggest": False})
    open(W + '/ch.nim', 'w').write('import std/[sequtils, strutils]\n\nlet xs = @[1, 2, 3]\nlet r = xs\n'
                                   '  .mapIt(it * 2)\n  .mapIt($it)\n  .join(", ")\necho r\n')
    start('ch.nim', w=150, h=40); time.sleep(1.0)
    ok = wait_for(r'\.mapIt\(it \* 2\): seq\[int\]', 15)
    s = screen()
    check('625 chain hints: after each step its type (seq[int], then seq[string])', ok and
          re.search(r'\.mapIt\(\$it\): seq\[string\]', s) is not None, s)
    check("625 chain hints: not on the last step of a let's value (the let's own hint says it)",
          re.search(r'\.join\(", "\): ', s) is None and 'r: string' in s, s)

def t_625_rename_reach():
    # 6.25: a rename reaches a strformat string's {name} and a doc comment's `name`
    setup({"nim.nimsuggest": False})
    open(W + '/rn.nim', 'w').write('import std/strformat\n\nproc total*(a, b: int): int =\n  ## adds; see `total`\n'
                                   '  a + b\n\nlet t = total(1, 2)\necho fmt"{total(3, 4)} and {t}"\n')
    start('rn.nim', w=150, h=40); time.sleep(1.0)
    keys('C-g'); text('3:6'); keys('Enter'); keys('F2'); time.sleep(0.4)
    keys('C-u'); text('sumOf'); keys('Enter'); time.sleep(1.0)
    check('625 rename: the preview lists the strformat string and the doc comment too',
          'Rename total → sumOf' in screen() and len(re.findall(r'total', screen())) >= 4, screen())
    keys('Enter'); time.sleep(0.6)
    keys('C-s'); time.sleep(0.5)
    t = ftext('rn.nim')
    check('625 rename: the code, the fmt string\'s {…} and the doc comment\'s `…`',
          'proc sumOf*' in t and 'see `sumOf`' in t and '{sumOf(3, 4)}' in t and 'total' not in t, t)

def t_625_completion_recent():
    # 6.25: completion ranks what you chose lately first — after a dot, nothing typed yet
    setup({"nim.nimsuggest": False})
    open(W + '/cr.nim', 'w').write('type P = object\n  alpha, beta, zeta: int\n\nvar p: P\necho p.zeta\n\n')
    start('cr.nim', w=150, h=40); time.sleep(1.0)
    keys('C-g'); text('6'); keys('Enter'); text('echo p.ze'); time.sleep(1.0); keys('Tab'); time.sleep(0.3)
    keys('Enter'); text('echo p.'); time.sleep(1.2)
    s = screen()
    rows = [l for l in s.splitlines() if re.search(r'\b(alpha|beta|zeta)\b', l) and 'echo' not in l]
    check('625 completion: zeta, chosen just now, comes first', rows and 'zeta' in rows[0], s)

def t_625_oracle():
    # 6.25: the compiler as an oracle in the background — a let whose value a macro makes has no type hint from the
    # engine; after a pause the compiler is asked (one nimsuggest run) and the hint is there; it is kept for the next
    # time (by the line's text)
    need('nimsuggest')
    setup({"nim.nimsuggest": False, "nim.macroNames": False})
    shutil.rmtree(os.path.join(os.environ.get('XDG_CACHE_HOME', os.path.expanduser('~/.cache')), 'ned', 'oracle'),
                  ignore_errors=True)
    open(W + '/orc.nim', 'w').write('import std/macros\n\nmacro mk(n: untyped): untyped =\n  result = quote do:\n'
                                    '    proc `n`(): int = 42\n\nmk(answer)\nlet x = answer()\necho x\n')
    start('orc.nim', w=150, h=40); time.sleep(1.0)
    ok = wait_for(r'let x: int = answer\(\)', 60)
    check('625 oracle: the type of a let a macro\'s proc gives, from the compiler, as a hint', ok, screen())
    tm('kill-server'); time.sleep(0.5)
    start('orc.nim', w=150, h=40); time.sleep(0.5)
    ok = wait_for(r'let x: int = answer\(\)', 4)
    check('625 oracle: kept — there at once the next time', ok, screen())

# ── 6.25: ned's own C engine — #if worked out, declarations macros make, its own checks, C++ overloads and
#    template specialisations (their fixtures first) ──

PLAT625 = """/* a comment */
#include <unistd.h>
#define USE_FAST 1
#ifdef _WIN32
static void sleep_ms(int ms) { Sleep(ms); }
#else
static void sleep_ms(int ms, int spin) { (void)spin; usleep(ms * 1000); }
#endif
#if USE_FAST && defined(__linux__)
int fast_path(void) { return 1; }
#else
int slow_path(void) { return 0; }
#endif
#define DECLARE_GETTER(name, type) type get_##name(void)
DECLARE_GETTER(width, int);
#if NET_TIMEOUT > 10
int long_wait(void) { return NET_TIMEOUT; }
#else
int short_wait(void) { return 1; }
#endif

int main(void) {
  sleep_ms(10, 0);
  int w = get_width();

  return w + fast_path() + long_wait();
}
"""

CHK625 = """#include <stdio.h>
#include <string.h>

struct point {
  char tag;
  double x;
  char kind;
  double y;
};

int main(void) {
  struct point p = { .x = 1.0 };
  double x = 2.5;
  printf("%d\\n", x);
  return (int)p.x;
}
"""

OVH625 = """#pragma once
/// Prints things.
struct Printer {
  /// A number.
  void print(int n) {}
  /// A string.
  void print(const char *s) {}
  /// Two numbers.
  void print(int lo, int hi) {}
};
template <typename T> struct Hash { int generic; };
/// Hashes ints.
template <> struct Hash<int> { int forInt; unsigned seed() const { return 7; } };
"""

OVC625 = """#include "ov.hpp"

int main() {
  Printer p;
  p.print("hi");
  p.print(1, 2);
  Hash<int> h;
  Hash<long> g;

  return h.forInt + g.generic;
}
"""


def t_625_c_if():
    # ned's own C engine works out #if: the compiler's macros (_WIN32, __linux__), the file's own #defines, -D from
    # compile_commands.json; what is left out dimmed and not among the declarations (a function in both branches
    # found once: the parameters of the one that is read); a declaration a macro makes (DECLARE_GETTER(width, int) →
    # get_width): hover says so, F12 goes to the macro's use, completion has it
    need('cc')
    setup({"c.engine": "builtin", "nim.nimsuggest": False})
    os.makedirs(W + '/c625', exist_ok=True)
    open(W + '/c625/plat.c', 'w').write(PLAT625)
    json.dump([{"directory": W + '/c625', "file": "plat.c", "arguments": ["cc", "-DNET_TIMEOUT=30", "-c", "plat.c"]}],
              open(W + '/compile_commands.json', 'w'))
    start('c625/plat.c', w=140, h=40); wait_for('long_wait', 8); time.sleep(1.2)
    rc = ansi_row('a comment')
    rw, rp = ansi_row('Sleep(ms)'), ansi_row('usleep')
    check("625 C #if: #ifdef _WIN32 on Linux dimmed like a comment, its #else not",
          fg_at(rw, 'Sleep') is not None and fg_at(rw, 'Sleep') == fg_at(rc, 'comment') and
          fg_at(rp, 'usleep') != fg_at(rc, 'comment'), str((fg_at(rw, 'Sleep'), fg_at(rp, 'usleep'),
                                                            fg_at(rc, 'comment'))) + '\n' + screen())
    rf, rs = ansi_row('fast_path(void)'), ansi_row('slow_path(void)')
    check("625 C #if: a macro of the file's and defined(__linux__) — the #else dimmed",
          fg_at(rs, 'slow_path') == fg_at(rc, 'comment') and fg_at(rf, 'fast_path') != fg_at(rc, 'comment'),
          str((fg_at(rf, 'fast_path'), fg_at(rs, 'slow_path'), fg_at(rc, 'comment'))))
    rl, rt = ansi_row('long_wait(void)'), ansi_row('short_wait(void)')
    check("625 C #if: -D from compile_commands.json (NET_TIMEOUT=30 > 10) — the #else dimmed",
          fg_at(rt, 'short_wait') == fg_at(rc, 'comment') and fg_at(rl, 'long_wait') != fg_at(rc, 'comment'),
          str((fg_at(rl, 'long_wait'), fg_at(rt, 'short_wait'), fg_at(rc, 'comment'))))
    # sleep_ms in both branches: the one that is read (two parameters) is the only one
    check("625 C #if: the parameters' names of the branch read (sleep_ms(ms: 10, spin: 0))",
          wait_for(r'sleep_ms\(ms: 10, spin: 0\)', 6), screen())
    keys('C-g'); text('23:3'); keys('Enter'); keys('F12'); time.sleep(1.0)
    check("625 C #if: F12 on sleep_ms — the definition in the #else (line 7)", status_pos() and status_pos()[0] == 7,
          screen()[-300:])
    # a declaration a macro makes
    keys('C-g'); text('24:11'); keys('Enter'); keys('M-h')
    ok = wait_for(r'declared by the macro DECLARE_GETTER', 6)
    check("625 C macros: hover on get_width — its declaration, made by DECLARE_GETTER",
          ok and re.search(r'int get_width\(', screen()), screen())
    keys('Escape')
    keys('C-g'); text('24:11'); keys('Enter'); keys('F12'); time.sleep(1.0)
    check("625 C macros: F12 on get_width — the macro's use (line 15)", status_pos() and status_pos()[0] == 15,
          screen()[-300:])
    keys('C-g'); text('25'); keys('Enter'); keys('End')
    before = screen().count('get_width')
    text('  int z = get_w'); time.sleep(1.0)
    if screen().count('get_width') <= before: keys('C-Space'); time.sleep(1.0)
    s = screen()
    check("625 C macros: completion has get_width", s.count('get_width') > before, s)
    keys('Escape')


def t_625_c_checks():
    # ned's own checks of C (c.engineChecks), no compiler needed, while you type: printf's format against its
    # arguments, a struct that takes less room with its fields ordered by size, an #include nothing of which is
    # used — each with its fix on Alt+Enter (a format's stays when gcc's own words take the line: gcc has no fix)
    need('cc')
    setup({"c.engine": "builtin", "nim.nimsuggest": False})
    os.makedirs(W + '/c625', exist_ok=True)
    open(W + '/c625/chk.c', 'w').write(CHK625)
    start('c625/chk.c', w=140, h=40); time.sleep(1.2)
    ok = wait_for(r"%d takes an int, x is a double|format '%d' expects argument of type 'int'", 10)
    check("625 C checks: printf's %d with a double — said on its line", ok, screen())
    keys('C-g'); text('14'); keys('Enter'); time.sleep(2.0)       # (the compiler's check too, after)
    keys('M-Enter')
    ok = wait_for(r'Use %f', 4)
    check("625 C checks: … Alt+Enter: the conversion the argument takes (Use %f)", ok, screen())
    if ok:
        text('Use %f'); wait_for(r'› Use %f', 3); time.sleep(0.4); keys('Enter'); time.sleep(0.5)
        keys('C-s'); time.sleep(0.5)
        check("625 C checks: … applied", 'printf("%f\\n", x);' in ftext('c625/chk.c'), ftext('c625/chk.c'))
    keys('Escape'); time.sleep(1.0)
    palette('Show problems')
    ok = wait_for(r'struct point: 32 bytes, 24 with its fields ordered by size', 8)
    check("625 C checks: a struct with room between its fields (a hint, among the problems)", ok, screen())
    keys('Escape')
    keys('C-g'); text('4'); keys('Enter'); time.sleep(0.5); keys('M-Enter')
    ok = wait_for(r'Order the fields', 4)
    check("625 C checks: … Alt+Enter: order the fields", ok, screen())
    if ok:
        text('Order the'); wait_for(r'› Order the', 3); time.sleep(0.4); keys('Enter'); time.sleep(0.5)
        keys('C-s'); time.sleep(0.5)
        t = ftext('c625/chk.c')
        check("625 C checks: … the fields by size, the doubles first",
              'struct point {\n  double x;\n  double y;\n  char tag;\n  char kind;\n};' in t, t)
    ok = wait_for(r'nothing from <string\.h> is used here', 8)
    check("625 C checks: an #include nothing of which is used — said on its line", ok, screen())
    keys('C-g'); text('2'); keys('Enter'); time.sleep(0.5); keys('M-Enter')
    ok = wait_for(r'Remove the #include', 4)
    check("625 C checks: … Alt+Enter: remove the #include", ok, screen())
    if ok:
        text('Remove the'); wait_for(r'› Remove the', 3); time.sleep(0.4); keys('Enter'); time.sleep(0.5)
        keys('C-s'); time.sleep(0.5)
        t = ftext('c625/chk.c')
        check("625 C checks: … removed, <stdio.h> kept", '<string.h>' not in t and '#include <stdio.h>' in t, t)
    keys('Escape')


def t_625_cpp_overloads():
    # C++ in ned's own engine: of a method's overloads the one the arguments fit — its parameters' names, hover,
    # signature help, F12; a template's explicit specialisation — hover, its members after `.`, F12 (the primary
    # template for the other arguments)
    need('c++')
    setup({"c.engine": "builtin", "nim.nimsuggest": False})
    os.makedirs(W + '/c625', exist_ok=True)
    open(W + '/c625/ov.hpp', 'w').write(OVH625)
    open(W + '/c625/ov.cpp', 'w').write(OVC625)
    start('c625/ov.cpp', w=140, h=40); time.sleep(1.2)
    check("625 C++ overloads: the parameters' names of the overload the arguments fit (print(lo: 1, hi: 2))",
          wait_for(r'p\.print\(lo: 1, hi: 2\)', 6), screen())
    keys('C-g'); text('5:5'); keys('Enter'); keys('M-h')
    ok = wait_for(r'A string\.', 6); s = screen()
    check("625 C++ overloads: hover on print(\"hi\") — the const char * one, only",
          ok and 'A number.' not in s and 'Two numbers.' not in s, s)
    keys('Escape')
    keys('C-g'); text('6:5'); keys('Enter'); keys('M-h')
    ok = wait_for(r'Two numbers\.', 6); s = screen()
    check("625 C++ overloads: hover on print(1, 2) — the two-int one", ok and 'A string.' not in s, s)
    keys('Escape')
    keys('C-g'); text('7:3'); keys('Enter'); keys('M-h')
    ok = wait_for(r'Hashes ints\.', 6)
    check("625 C++ specialisations: hover on Hash<int> — the explicit specialisation",
          ok and 'struct Hash<int>' in screen(), screen())
    keys('Escape')
    keys('C-g'); text('9'); keys('Enter'); keys('End'); text('p.print(1, ')
    check("625 C++ overloads: signature help follows the arguments typed (print(int lo, int hi))",
          wait_for(r'print\(int lo, int hi\)', 4), screen())
    keys('Escape'); keys('Home'); keys('S-End'); text('  h.')
    ok = wait_for(r'forInt\s+int', 4); s = screen()
    check("625 C++ specialisations: Hash<int>'s members after h. — not the primary template's",
          ok and 'seed' in s and not re.search(r'generic\s+int', s), s)
    keys('Escape'); keys('Home'); keys('S-End'); text('  g.')
    ok = wait_for(r'generic\s+int', 4); s = screen()
    check("625 C++ specialisations: … Hash<long>: the primary template's", ok and not re.search(r'forInt\s+int', s), s)
    keys('Escape'); keys('Home'); keys('S-End'); keys('BSpace')
    keys('C-g'); text('5:5'); keys('Enter'); keys('F12'); time.sleep(1.2)
    check("625 C++ overloads: F12 on print(\"hi\") — the const char * one (ov.hpp:7)",
          wait_for(r'ov\.hpp', 3) and status_pos() and status_pos()[0] == 7, screen()[-300:])
    keys('C-p'); time.sleep(0.3); text('ov.cpp'); time.sleep(0.4); keys('Enter'); time.sleep(1.0)
    keys('C-g'); text('8:3'); keys('Enter'); keys('F12'); time.sleep(1.2)
    check("625 C++ specialisations: F12 on Hash<long> — the primary template (ov.hpp:11)",
          wait_for(r'ov\.hpp', 3) and status_pos() and status_pos()[0] == 11, screen()[-300:])
    keys('C-p'); time.sleep(0.3); text('ov.cpp'); time.sleep(0.4); keys('Enter'); time.sleep(1.0)
    keys('C-g'); text('7:3'); keys('Enter'); keys('F12'); time.sleep(1.2)
    check("625 C++ specialisations: F12 on Hash<int> — its specialisation (ov.hpp:13)",
          wait_for(r'ov\.hpp', 3) and status_pos() and status_pos()[0] == 13, screen()[-300:])

def t_624_compiler_explorer_c():
    # Compiler Explorer on a C file, the object disassembled (binary: objdump, addresses, the calls' targets), AT&T
    need('gcc', 'objdump')
    setup({"compilerExplorer.cOptions": "-O2", "compilerExplorer.output": "binary", "compilerExplorer.syntax": "att"})
    open(W + '/sq.c', 'w').write('#include <stdio.h>\n\nint square(int n)\n{\n    return n * n;\n}\n\n'
                                 'int main(void)\n{\n    printf("%d\\n", square(7));\n    return 0;\n}\n')
    start('sq.c', w=150, h=40); time.sleep(1.0)
    palette('Compiler Explorer')
    ok = wait_for(r'square:', 30)
    s = screen()
    check('624 CE (C, binary): the object disassembled — square with its addresses', ok and
          re.search(r'\s0: \S', s) is not None and 'imul' in s, s)
    check('624 CE (C, binary): AT&T syntax (%-registers)', '%edi' in s or '%eax' in s, s)
    check('624 CE (C, binary): a call shows its target, not an address', re.search(r'call\S*\s+\w*(printf|puts)', s),
          s)


# ── 6.26 ──

def open626(name):
    """another file opened (Ctrl+P, its name)"""
    keys('Escape'); time.sleep(0.2); keys('C-p'); text(name); time.sleep(0.6); keys('Enter'); time.sleep(1.0)


FEAT626 = ('#ifndef FEAT_H\n#define FEAT_H\n#ifdef USE_FAST\nint fast_path(void);\n#define SPEED 9\n#else\n'
           'int slow_path(void);\n#define SPEED 1\n#endif\n#endif\n')

def t_626_c_header_macros():
    # 6.26: a header's #ifs see the macros of the file that includes it — a.c defines USE_FAST before it includes
    # feat.h, so the header's SPEED is 9 there (the #if SPEED == 9 branch read, the #else dimmed), and F12 on
    # fast_path goes to its declaration in the header; b.c does not: SPEED is 1 there
    need('cc')
    setup({"c.engine": "builtin", "nim.nimsuggest": False})
    os.makedirs(W + '/c626', exist_ok=True)
    open(W + '/c626/feat.h', 'w').write(FEAT626)
    body = ('#include "feat.h"\n#if SPEED == 9\nint nine(void) { return fast_path(); }\n#else\n'
            'int one(void) { return slow_path(); }\n#endif\n')
    open(W + '/c626/a.c', 'w').write('/* a comment */\n#define USE_FAST\n' + body)
    open(W + '/c626/b.c', 'w').write('/* a comment */\n#undef USE_FAST\n' + body)
    start('c626/a.c', w=140, h=40); wait_for('nine', 8); time.sleep(1.5)
    rc, rn, ro = ansi_row('a comment'), ansi_row('nine(void)'), ansi_row('one(void)')
    check("626 C: USE_FAST defined before the #include — the header's SPEED is 9 (#else dimmed)",
          fg_at(ro, 'one') == fg_at(rc, 'comment') and fg_at(rn, 'nine') != fg_at(rc, 'comment'),
          str((fg_at(rn, 'nine'), fg_at(ro, 'one'), fg_at(rc, 'comment'))) + '\n' + screen())
    keys('C-g'); text('5:30'); keys('Enter'); keys('F12'); time.sleep(1.2)
    s = screen()
    check("626 C: F12 on fast_path — the header's declaration, in the branch USE_FAST reads",
          'feat.h' in s and status_pos() and status_pos()[0] == 4, s[-400:])
    tm('kill-server'); time.sleep(0.3)
    start('c626/b.c', w=140, h=40); time.sleep(1.5)
    wait_for('one', 6)
    rc, rn, ro = ansi_row('a comment'), ansi_row('nine(void)'), ansi_row('one(void)')
    check("626 C: #undef USE_FAST before it — SPEED is 1 there (the SPEED == 9 branch dimmed)",
          fg_at(rn, 'nine') == fg_at(rc, 'comment') and fg_at(ro, 'one') != fg_at(rc, 'comment'),
          str((fg_at(rn, 'nine'), fg_at(ro, 'one'), fg_at(rc, 'comment'))) + '\n' + screen())


CLIP_PLUGIN = '''import nedplugin

permission("clipboard", "copies the line for you")

command "Clipper: copy the line":
  let b = current()
  setClipboard("from clipper: " & b.line(b.cursor.line))
  message("clipper copied — " & clipboard())

command "Clipper: run a program":
  try:
    discard api("terminal", %*{"cmd": "echo hi"})
    message("clipper ran it")
  except ValueError as e:
    message("clipper: " & e.msg)
'''

def t_626_plugin_permissions():
    # 6.26: a plugin that asks for the clipboard waits for your OK — a note says so; Plugins: permissions… lists
    # it, the dialog says what it asks for, why (its own words) and where in its source; Not now keeps it waiting,
    # Allow runs it; what it did not ask for (a terminal, through the raw API) is refused when it runs
    setup()
    os.makedirs(STATE + '/ned', exist_ok=True)
    open(STATE + '/ned/plugin-permissions.json', 'w').write('{"granted": {}}\n')    # (not the first ned that asks)
    d = CFG + '/ned/plugins/clipper'
    os.makedirs(d, exist_ok=True)
    open(d + '/plugin.nims', 'w').write(CLIP_PLUGIN)
    open(W + '/notes.txt', 'w').write('the first line\nsecond\n')
    start('notes.txt', w=150, h=40)
    ok = wait_for(r'clipper asks to use the clipboard', 15)
    check("626 permissions: a plugin that asks waits — a note says what for", ok, screen())
    palette('Plugins: permissions')
    ok = wait_for(r'clipper\s+waiting', 6)
    check("626 permissions: Plugins: permissions… lists it, waiting", ok, screen())
    keys('Enter')
    ok = wait_for(r"A plugin's permissions", 6)
    s = screen()
    check("626 permissions: the dialog — what it asks for, why, where in its source",
          ok and 'read and set the clipboard' in s and 'it says: copies the line for you' in s and
          re.search(r'in its source: .*[Cc]lipboard', s) is not None, s)
    nn = place_of('Not now')
    if nn: click(*nn)
    else: keys('n')
    time.sleep(0.6)
    palette('Clipper: copy the line'); time.sleep(1.0)
    check("626 permissions: Not now — it still waits (its command does not run)", 'clipper copied' not in screen(),
          screen())
    keys('Escape')
    palette('Plugins: permissions'); wait_for(r'clipper\s+waiting', 6); keys('Enter')
    wait_for(r"A plugin's permissions", 6)
    al = None                                      # (the button: the last "Allow" — the text above says it too)
    for r, l in enumerate(screen().splitlines()):
        c = l.rfind('Allow')
        if c >= 0: al = (c + 2, r + 1)
    if al: click(*al)
    else: keys('a')
    ok = plugins_ready(40)
    check("626 permissions: Allow — it runs", ok, screen())
    g = open(STATE + '/ned/plugin-permissions.json').read()
    check("626 permissions: what you allowed is kept (state folder)", re.search(r'"clipper":\s*\[\s*"clipboard"', g),
          g)
    palette('Clipper: copy the line')
    ok = wait_for(r'clipper copied — from clipper: the first line', 10)
    check("626 permissions: allowed — it sets and reads the clipboard", ok, screen())
    palette('Clipper: run a program')
    ok = wait_for(r'clipper: not allowed: run programs', 10)
    check("626 permissions: what it did not ask for is refused when it runs (a terminal)", ok, screen())
    # taken back: it waits again
    palette('Plugins: permissions'); wait_for(r'clipper\s+allowed', 6); keys('Enter'); time.sleep(1.0)
    g = open(STATE + '/ned/plugin-permissions.json').read()
    check("626 permissions: taken back — not kept any more", '"clipper"' not in g and
          wait_for('permissions taken back', 6), g + screen())


MEM626_C = ('#include <stdlib.h>\n#include <string.h>\n\nint main(void) {\n    char *p = malloc(8);\n'
            '    strcpy(p, "0123456789");\n    free(p);\n    int *q = malloc(4 * sizeof(int));\n'
            '    q[0] = 1;\n    return q[0] == 7 || p[0] == 0;\n}\n')

def t_626_memory_checks():
    # 6.26: Run with memory checks — a C program built with the address and undefined-behaviour checks: a write past
    # the end of a block on its line in Problems (the line that made the block too), a block never freed
    need('cc')
    setup({"nim.nimsuggest": False})
    open(W + '/mem.c', 'w').write(MEM626_C)
    start('mem.c', w=150, h=40); time.sleep(1.0)
    palette('Run with memory checks')
    ok = wait_for(r'memory checks \(.*\): (\d+ found|nothing found)|this compiler has none', 90)
    s = screen()
    if 'this compiler has none' in s or 'undefined-behaviour checks only' in s:
        check('626 memory checks: (this C compiler has no address checks — not tested)', True); return
    check('626 memory checks: a C program run with them — what they found, in the panel', ok and 'found' in s and
          'nothing found' not in s, s)
    palette('Show problems'); time.sleep(0.8)
    s = screen()
    check('626 memory checks: the overflow in Problems, on its line (6), where the block was made said',
          re.search(r'memory: .*(overflow|past the end)', s) and
          re.search(r'●\s+6\s.*memory: the program writes past the end', s), s)
    check('626 memory checks: a read after free, on its line (10)',
          re.search(r'●\s+10\s.*memory: the program reads memory after it was freed', s), s)
    check('626 memory checks: the block never freed (made on line 8)', re.search(r'never freed', s), s)
    keys('Escape')
    # Nim: an index past the end, through a pointer (no bound check catches it)
    open(W + '/memn.nim', 'w').write('proc main() =\n  var s = newSeq[int](3)\n'
                                     '  let p = cast[ptr UncheckedArray[int]](s[0].addr)\n  p[5] = 1\n  echo s.len\n'
                                     'main()\n')
    open626('memn.nim')
    palette('Run with memory checks')
    ok = wait_for(r'memory checks \(.*\): (\d+ found|nothing found)', 240)
    s = screen()
    check('626 memory checks: Nim too — the write past the end found', ok and 'found' in s and 'nothing found' not in s,
          s)
    palette('Show problems'); time.sleep(0.8)
    s = screen()
    check('626 memory checks: … on its line of the Nim file (4)', re.search(r'memn\.nim', s) and
          re.search(r'memory:', s), s)


NB626 = ('# %%\nvar total = 0\nfor i in 1 .. 4: total += i\necho "total ", total\n\n# %%\necho total * 2\n\n'
         '# %%\necho undefinedQzx\n')

def t_626_notebook():
    # 6.26: a Nim file with # %% cells as a notebook — ▶ run on a cell's marker line (a tap), its output under it
    # (Out [1]), one session (the next cell sees its variables), a changed cell says so, an error in Problems on
    # its line; Python too (a cell's last expression shown)
    setup({"nim.nimsuggest": False})
    open(W + '/nb.nim', 'w').write(NB626)
    start('nb.nim', w=140, h=40); time.sleep(1.0)
    b = place_of('▶ run')
    check('626 notebook: ▶ run on the cells\' marker lines', b is not None, screen())
    if b: click(b[0] + 2, b[1])
    else: palette('Notebook: run the cell')
    # (the pointer moved off the code: no hover over the outputs)
    tm('send-keys', '-t', 'f', '-l', '\x1b[<35;2;39M'); time.sleep(0.2); keys('Escape')
    ok = wait_for(r'Out \[1\]', 60)
    s = screen()
    check('626 notebook: the cell\'s output under it', ok and 'total 10' in s, s)
    keys('C-g'); text('7'); keys('Enter')
    palette('Notebook: run the cell'); time.sleep(1.5); keys('Escape')      # (Escape: the hover of the cursor's word)
    ok = wait_for(r'Out \[2\]', 60)
    s = screen()
    ls = s.split('\n')
    k = next((i for i, l in enumerate(ls) if 'Out [2]' in l), -1)
    check('626 notebook: one session — the next cell sees its variables (20)',
          ok and k >= 0 and k + 1 < len(ls) and re.search(r'\b20\b', ls[k + 1]) is not None, s)
    keys('C-g'); text('4'); keys('Enter', 'End'); text(' # changed'); time.sleep(0.8)
    check('626 notebook: a cell changed since it ran says so', 'the cell changed since it ran' in screen(), screen())
    keys('C-g'); text('10'); keys('Enter')
    palette('Notebook: run the cell'); time.sleep(1.5); keys('Escape')
    ok = wait_for(r'Out \[3\]', 60)
    s = screen()
    check('626 notebook: an error under its cell', ok and 'undefinedQzx' in s, s)
    palette('Show problems'); time.sleep(0.6)
    s = screen()
    check('626 notebook: … and in Problems on its line', re.search(r"undeclared identifier: 'undefinedQzx'", s), s)
    keys('Escape')
    if which('python3'):
        open(W + '/nb.py', 'w').write('# %%\nx = 21\nprint("x is", x)\n\n# %%\nx * 2\n')
        open626('nb.py')
        palette('Notebook: run all the cells')
        ok = wait_for(r'Out \[2\]', 30)
        s = screen()
        check('626 notebook: Python — each cell\'s output, the last expression\'s value (42)', ok and 'x is 21' in s and
              re.search(r'\b42\b', s) is not None, s)


PT626 = ('proc clampAdd*(a, b: int): int =\n  ## adds, at most 50\n  if a < 0: raise newException(ValueError, "negative")\n'
         '  min(a + b, 50)\n')

def t_626_proc_tests():
    # 6.26: Nim: write tests for this proc (from running it) — sample arguments run, what it returned written as
    # checks (an exception as `expect`), in tests/t<module>.nim beside the .nimble, opened
    setup({"nim.nimsuggest": False})
    open(W + '/src/mathy.nim', 'w').write(PT626)
    start('src/mathy.nim', w=140, h=40); time.sleep(0.8)
    keys('C-g'); text('4:5'); keys('Enter')
    palette('Nim: write tests for this proc')
    p = W + '/tests/tmathy.nim'
    ok = wait_for(r'suite "clampAdd"', 120)
    t = open(p).read() if os.path.exists(p) else ''
    check('626 proc tests: the tests written beside the .nimble (tests/tmathy.nim) and opened', ok and 'tmathy.nim' in screen()
          and 'suite "clampAdd"' in t, screen() + '\n' + t)
    check('626 proc tests: then run (with coverage)', wait_for(r'✓ passed', 120) and wait_for(r'COVERAGE', 60), screen())
    check('626 proc tests: its values as checks (0, 2, 50)', 'check clampAdd(0, 0) == 0' in t and
          'check clampAdd(1, 1) == 2' in t and 'check clampAdd(42, 42) == 50' in t, t)
    check('626 proc tests: an exception as expect', re.search(r'expect ValueError:\s*\n\s*discard clampAdd\(-1, -1\)', t), t)
    check('626 proc tests: the module imported (clampAdd is exported)', 'import ../src/mathy' in t or
          re.search(r'import .*mathy', t), t)
    r = sh('cd %s && nim c -r --hints:off %s 2>&1' % (W, p))
    check('626 proc tests: they compile and pass', r.returncode == 0 and '[OK]' in r.stdout, r.stdout[-800:])


HOT626 = ('proc slow(n: int): int =\n  for i in 0 ..< n:\n    result += i mod 7\nproc fast(n: int): int = n * 2\n'
          'proc work(): int =\n  for k in 0 ..< 3000:\n    result += slow(20000)\n    result += fast(k)\n'
          'echo work()\n')

def t_626_flame():
    # 6.26: the profile as a flame graph (the call stacks, as wide as their time) — a tap on a box looks inside it,
    # the top bar goes back; and two profiles compared, before and after
    setup({"nim.nimsuggest": False})
    open(W + '/hot.nim', 'w').write(HOT626)
    start('hot.nim', w=140, h=36); time.sleep(1)
    palette('Nim: profile')
    ok = wait_for(r'of the time', 150)
    check('626 flame: profiled', ok, screen())
    palette('Nim: flame graph of the profile')
    ok = wait_for(r'FLAME GRAPH · \d+ samples', 10)
    s = screen()
    check('626 flame: the flame graph — work, and slow inside it', ok and 'work' in s and 'slow' in s, s)
    sp = None
    for r, l in enumerate(s.splitlines()):
        if 'FLAME GRAPH' in l: continue
        c = l.find('slow')
        if c >= 0: sp = (c + 1, r + 1); break
    if sp: click(*sp)
    ok = wait_for(r'↑ ', 6)
    check('626 flame: a tap on a box looks inside it (↑ back at the top)', sp and ok, screen())
    keys('BSpace'); time.sleep(0.5)
    check('626 flame: Backspace — back up one (work)', re.search(r'↑ work · ', screen()) is not None, screen())
    for _ in range(4):                             # (the top bar: back up one a tap — to the whole program)
        tb = place_of('↑ ')
        if not tb: break
        click(*tb); time.sleep(0.5)
    check('626 flame: taps on the top bar — up to the whole program', '↑ ' not in screen() and
          'the whole program · 100.0%' in screen(), screen())
    keys('C-w'); time.sleep(0.4)
    # faster now: compared with the profile before
    s2 = HOT626.replace('slow(20000)', 'slow(2000)')
    open(W + '/hot.nim', 'w').write(s2)
    palette('Reload from disk'); time.sleep(0.5)
    palette('Nim: profile')
    ok = wait_for(r'of the time', 150)
    palette('Nim: compare with the previous profile')
    ok = wait_for(r'PROFILE · BEFORE AND AFTER', 10)
    s = screen()
    check('626 flame: two profiles compared — slow listed, before and after', ok and 'slow' in s, s)


def png626(path, w, h, px):
    """a PNG file w × h, each pixel's (r, g, b) from px(x, y)"""
    import zlib, struct
    raw = b''.join(b'\x00' + b''.join(bytes(px(x, y)) for x in range(w)) for y in range(h))
    def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) +
                           chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))

def t_626_pictures():
    # 6.26: a picture file opens as the picture (here in the terminal's cells: half blocks, its colours), + zooms,
    # Tab shows its bytes and back
    setup({"nim.nimsuggest": False})
    png626(W + '/pic.png', 16, 8, lambda x, y: (255, 0, 0) if x < 8 else (0, 0, 255))
    start('pic.png', w=140, h=40); time.sleep(1.0)
    s = screen()
    check('626 pictures: a PNG opens as the picture — its name, format and size at the top',
          re.search(r'▣ pic\.png\s+PNG · 16×8', s) is not None and '▀' in s, s)
    row = ''
    for l in screen_ansi().split('\n'):
        if '▀' in re.sub(r'\x1b\[[0-9;:]*m', '', l): row = l; break
    plain = re.sub(r'\x1b\[[0-9;:]*m', '', row)
    a, z = plain.find('▀'), plain.rfind('▀')
    check('626 pictures: its colours — red on the left, blue on the right',
          fg_at_col(row, a) == ('255', '0', '0') and fg_at_col(row, z) == ('0', '0', '255'),
          str((fg_at_col(row, a), fg_at_col(row, z))))
    text('+'); time.sleep(0.4)
    check('626 pictures: + zooms in', '150% of the view' in screen(), screen()[:300])
    text('0'); keys('Tab'); time.sleep(0.5)
    s = screen()
    check('626 pictures: Tab — its bytes (hex)', re.search(r'89 50 4[Ee] 47', s) is not None, s)
    keys('Tab'); time.sleep(0.5)
    s = screen()
    # 6.27: there Tab goes between the hex and the text columns, as in any hex view; Shift+Tab: the picture
    check('627 pictures: Tab in its bytes — the other column, still the bytes',
          re.search(r'89 50 4[Ee] 47', s) is not None and 'binary · 80 bytes' in s, s)
    keys('BTab'); time.sleep(0.5)
    check('627 pictures: Shift+Tab — the picture again', re.search(r'▣ pic\.png\s+PNG · 16×8', screen()) is not None,
          screen())


MD626 = ('# Guide\n\n| Name | Size |\n|:-----|-----:|\n| alpha | 1 |\n| beta | 22 |\n\n- [ ] write it\n- [x] test it\n\n'
         '> [!NOTE]\n> Read this first.\n\n![logo](logo.png)\n\nSee [the setup part](#setup).\n\n' +
         ''.join('Filler paragraph %d.\n\n' % i for i in range(40)) + '## Setup\n\nRun it.\n')

def t_626_markdown_preview():
    # 6.26: the Markdown preview — a table drawn with its columns lined up, task lists, a GitHub note, a picture,
    # a link to a heading (a tap goes there in the file, the preview follows)
    setup({"nim.nimsuggest": False})
    open(W + '/doc.md', 'w').write(MD626)
    png626(W + '/logo.png', 8, 4, lambda x, y: (0, 200, 0))
    start('doc.md', w=150, h=44); time.sleep(0.6)
    palette('Markdown: open preview'); time.sleep(1.2)
    s = screen()
    check('626 markdown: a table, its columns lined up', '┌' in s and re.search(r'│ alpha\s*│\s+1 │', s) is not None, s)
    check('626 markdown: task lists (☐ ☑)', '☐ write it' in s and '☑ test it' in s, s)
    check('626 markdown: a GitHub note', 'ℹ Note' in s and 'Read this first.' in s, s)
    check('626 markdown: the picture drawn', '▀' in s, s)
    lp = None
    for r, l in enumerate(s.splitlines()):
        c = l.find('the setup part')
        if c > 0 and l[c - 1] != '[': lp = (c + 3, r + 1)
    if lp: click(*lp)
    time.sleep(0.8)
    want = MD626.split('\n').index('## Setup') + 1
    p = status_pos()
    s = screen()
    check('626 markdown: a tap on a link to a heading — the file goes there, the preview follows',
          lp and '## Setup' in s and 'Run it.' in s and 'Filler paragraph 0.' not in s, str((lp, p, want)) + '\n' + s)


def t_626_settings_sync():
    # 6.26: Settings sync both ways — each device's changes merged key by key: what only one changed taken from
    # it, changed on both this device's kept (and said); at start (sync.auto) it pulls what the other pushed
    repo = TMP + '/sync626.git'
    shutil.rmtree(repo, ignore_errors=True)
    sh('git init -q --bare %s' % repo)
    url = 'file://' + repo
    cfg2, state2 = TMP + '/cfg-b', TMP + '/state-b'
    # device A
    setup({"editor.tabSize": 3, "sync.repository": url})
    start('src/demo.nim', w=140, h=34); time.sleep(0.5)
    palette('Settings sync: sync now')
    check('626 sync: device A — in sync (the repository had nothing)', wait_for('Settings in sync with', 20), screen())
    tm('kill-server'); time.sleep(0.3)
    a_cfg = open(CFG + '/ned/config.json').read()
    # device B: its own settings and state
    shutil.rmtree(cfg2, ignore_errors=True); shutil.rmtree(state2, ignore_errors=True)
    os.makedirs(cfg2 + '/ned', exist_ok=True)
    json.dump({"editor.tabSize": 8, "editor.rulers": [100], "sync.repository": url, "security.folderTrust": "off",
               "nim.nimsuggest": False}, open(cfg2 + '/ned/config.json', 'w'))
    start('src/demo.nim', w=140, h=34, env_extra='XDG_CONFIG_HOME=%s XDG_STATE_HOME=%s' % (cfg2, state2)); time.sleep(0.5)
    palette('Settings sync: sync now')
    ok = wait_for('changed on both devices, this one.s kept', 20)
    c = open(cfg2 + '/ned/config.json').read()
    check("626 sync: device B — changed on both (tabSize): this device's kept, and said", ok and
          re.search(r'"editor.tabSize":\s*8', c), screen() + c)
    tm('kill-server'); time.sleep(0.3)
    pushed = sh('git --git-dir=%s show HEAD:ned-settings.json' % repo).stdout
    check("626 sync: the repository has B's rulers now", '100' in pushed, pushed[:400])
    # device A again, sync.auto at start: B's tabSize (A did not change it since) and rulers come over
    c = json.load(open(CFG + '/ned/config.json'))
    c["sync.auto"] = "start"
    json.dump(c, open(CFG + '/ned/config.json', 'w'))
    start('src/demo.nim', w=140, h=34)
    end = time.time() + 25
    c = ''
    while time.time() < end:
        c = open(CFG + '/ned/config.json').read()
        if re.search(r'"editor.tabSize":\s*8', c) and '100' in c: break
        time.sleep(0.5)
    check("626 sync: sync.auto start — A takes what only B changed (tabSize 8, rulers)",
          re.search(r'"editor.tabSize":\s*8', c) and '100' in c, c + screen())
    tm('kill-server'); time.sleep(0.3)


# ── 6.27 ──

def t_627_256_colours():
    # 6.27: a terminal of 256 colours (ui.trueColor off, as ned took Windows Terminal before): a theme's dark
    # blue-grey background is the nearest grey, not the palette's strong blue (dracula, solarized-dark were #00005F)
    for th, want in [("dracula", 236), ("solarized-dark", 234), ("nord", 237), ("catppuccin-mocha", 235)]:
        setup({"ui.trueColor": "off", "theme": th, "nim.nimsuggest": False})
        start('src/demo.nim', w=120, h=30); time.sleep(0.8)
        a = screen_ansi()
        row = ansi_row('import')
        bgs = re.findall(r'48;5;(\d+)', row)
        check('627 256 colours: %s — the editor\'s background the nearest grey (%d), no blue' % (th, want),
              str(want) in bgs and '17' not in bgs and '48;5;17m' not in a, str(bgs[:12]))
    # 24-bit where Windows Terminal says it is there (WT_SESSION, also through WSL): Check setup says why
    setup({"nim.nimsuggest": False})
    start('src/demo.nim', w=140, h=40, env_extra='WT_SESSION=1 COLORTERM= TMUX='); time.sleep(0.8)
    a = screen_ansi()
    check('627 colours: Windows Terminal (WT_SESSION) draws in 24-bit colour', '48;2;' in a, a[:300])
    palette('Check setup'); time.sleep(1.5)
    check('627 colours: Check setup says why — Windows Terminal', '24-bit colour (Windows Terminal)' in screen(),
          screen())

PKG627 = '{\n  "name": "demo",\n  "nmae": "x",\n  "type": "modul",\n  \n  "version": "1.0.0"\n}\n'

def t_627_json():
    # 6.27: ned's own JSON engine — a known file's keys and values checked (package.json: a misspelled key, a value
    # it does not take), its keys completed with what they do, a comma missing found, the key path in the breadcrumbs
    setup({"nim.nimsuggest": False})
    open(W + '/package.json', 'w').write(PKG627)
    start('package.json', w=140, h=32); time.sleep(0.6)
    check('627 json: package.json — a misspelled key, and the one meant', wait_for(r'"nmae" is not a key of package.json — "name"\?', 8),
          screen())
    check('627 json: a value it does not take ("modul": "module"?)', '"module"?' in screen(), screen())
    keys('C-g'); text('5:3'); keys('Enter'); text('"scr'); time.sleep(0.8)
    check('627 json: the keys package.json has, completed', 'scripts' in screen(), screen())
    keys('Escape'); keys('C-g'); text('2:5'); keys('Enter'); time.sleep(0.6)
    check('627 json: the breadcrumbs — the key path at the cursor', re.search(r'package\.json\s*›\s*name', screen()) is not None,
          screen())
    open(W + '/bad.json', 'w').write('{\n  "a": 1\n  "b": 2\n}\n')
    palette('Open file'); text('bad.json'); keys('Enter'); time.sleep(0.6)
    check('627 json: a comma missing', wait_for(r'comma is missing', 6), screen())


HTML627 = ('<!doctype html>\n<html>\n<body>\n<a href="#intro">i</a> <a href="gone.html">g</a>\n'
           '<div clas="x" id="intro"></div>\n</body>\n</html>\n')

def t_627_web_more():
    # 6.27: more of ned's own HTML, CSS and SQL — a link to a file not beside the page, an attribute's typo, a
    # var(--name) the sheet does not set, an INSERT with more values than columns
    setup({"nim.nimsuggest": False})
    open(W + '/site627.html', 'w').write(HTML627)
    open(W + '/vars627.css', 'w').write(':root { --primary: #333; }\na { color: var(--primay); }\n')
    open(W + '/ins627.sql', 'w').write('CREATE TABLE users (id INTEGER, name TEXT);\nINSERT INTO users (id, nmae) VALUES (1, 2);\n'
                                       'INSERT INTO users (id, name) VALUES (1, 2, 3);\n')
    start('site627.html', w=150, h=32); time.sleep(0.6)
    check('627 html: a link to a file that is not beside the page', wait_for(r'no gone\.html beside this page', 8), screen())
    check("627 html: an attribute's typo (clas: class?)", "has no attribute 'clas' — 'class'?" in screen(), screen())
    palette('Open file'); text('vars627.css'); keys('Enter')
    check("627 css: var() of a property the sheet does not set — the one meant",
          wait_for(r"'--primay' is not set in this sheet — '--primary'\?", 8), screen())
    palette('Open file'); text('ins627.sql'); keys('Enter')
    ok = wait_for(r'3 values for 2 columns', 8)
    check("627 sql: INSERT — more values than columns, a column the table does not have", ok and
          "has no column 'nmae'" in screen(), screen())


PNAK627 = ('(.nif27)\n(stmts\n (requires "https://github.com/a/jsony.git" "0123abcd")\n'
           ' (requires "https://github.com/b/zippy.git" "main"))\n')

def t_627_pnak():
    # 6.27: pnak.nif, Nim 3's lockfile — its packages in the Outline, hover (the commit, where it is checked out),
    # its problems (a branch's name for a commit, not fetched yet), F12 to the package's .nimble
    setup({"nim.nimsuggest": False})
    open(W + '/pnak.nif', 'w').write(PNAK627)
    os.makedirs(W + '/deps/jsony/.git', exist_ok=True)
    open(W + '/deps/jsony/.git/HEAD', 'w').write('0123abcd9999\n')
    open(W + '/deps/jsony/jsony.nimble', 'w').write('version = "1.1.5"\n')
    try:
        start('pnak.nif', w=150, h=32); time.sleep(0.6)
        time.sleep(1.5)
        palette('Show problems'); time.sleep(0.8)
        check("627 pnak: a branch's name for a commit, a package not fetched yet (in Problems)",
              wait_for(r"'main' is a branch or a tag", 8) and 'zippy is not in deps/ yet' in screen(), screen())
        keys('Escape')
        palette('Outline panel'); time.sleep(0.6)
        s = screen()
        check('627 pnak: the packages in the Outline', 'jsony' in s and 'zippy' in s and '0123abcd' in s, s)
        keys('Escape')
        keys('C-g'); text('3:14'); keys('Enter'); keys('M-h'); time.sleep(0.6)
        check('627 pnak: hover — the package, its commit, where it is checked out',
              re.search(r'jsony.*github\.com/a/jsony', screen()) is not None and 'deps' in screen(), screen())
        keys('Escape'); keys('F12'); time.sleep(0.8)
        check("627 pnak: F12 — the package's .nimble", 'jsony.nimble' in screen() and 'version = "1.1.5"' in screen(),
              screen())
    finally:
        shutil.rmtree(W + '/deps', ignore_errors=True)
        os.remove(W + '/pnak.nif')


N3627 = ('import std/syncio\n\nproc needsPositive(x: int) {.requires: x > 0.} =\n  echo x\n\n'
         'proc handle(c: var int) {.passive.} =\n  inc c\n\nneedsPositive(0)\nvar c = 1\ndiscard delay(handle(c))\n')

def t_627_nim3_contracts():
    # 6.27: Nim 3 — a call whose arguments break the routine's {.requires: …}, and delay() of a passive proc with a
    # var parameter: nimony's errors, as you type
    need('nimony')
    setup({"nim.compiler": "nimony", "nim.nimsuggest": None})
    open(W + '/src/c627.nim', 'w').write(N3627)
    start('src/c627.nim', w=160, h=32); time.sleep(1)
    check('627 Nim 3: contract violated — requires x > 0 (x = 0)', wait_for(r'contract violated: requires x > 0 \(x = 0\)', 15),
          screen())
    check('627 Nim 3: delay of a passive proc with a var parameter', '`delay` hands `handle` to a scheduler' in screen(),
          screen())


X632 = ('import std/macros\nmacro twice(body: untyped): untyped =\n  result = newStmtList(body, body)\n'
        'template sq(x: untyped): untyped = x * x\ntemplate withLog(name: string, body: untyped) =\n  echo "start ", name\n'
        '  body\n  echo "end ", name\nproc f() =\n  echo sq(3 + 1)\n  withLog "job":\n    echo "working"\n'
        '    echo "done"\n  twice:\n    echo "hi"\nf()\n')

def t_632_macro_view():
    # 6.32: Alt+M shows what a template or macro writes under its call (not text: rows drawn there), follows the call
    # when lines come and go above it, is written again when the call changes; the names in it hover and go to their
    # definition; the header (or Alt+M again) hides it
    setup({"nim.nimsuggest": False})
    open(W + '/x.nim', 'w').write(X632)
    start('x.nim', w=120, h=36); time.sleep(1.5)
    keys('C-g'); text('10:9'); keys('Enter'); keys('M-m')
    ok = wait_for(r'the template sq writes', 5)
    s = screen()
    rows = s.splitlines()
    at = next((i for i, r in enumerate(rows) if 'echo sq(3 + 1)' in r), -1)
    check('632 Alt+M: the template written out under its call, in the file', ok and at >= 0 and
          'the template sq writes' in rows[at + 1] and '(3 + 1) * (3 + 1)' in rows[at + 2] and
          'withLog "job":' in rows[at + 3], s)
    check('632 … and not in the text (the file unchanged, no tab opened)', 'expand:' not in s and
          '(3 + 1) * (3 + 1)' not in ftext('x.nim'), s)
    # the call changed: written again after a pause
    keys('C-g'); text('10:11'); keys('Enter'); keys('Delete'); text('5')
    ok = wait_for(r'\(5 \+ 1\) \* \(5 \+ 1\)', 5)
    check('632 the call changed: the expansion written again', ok, screen())
    # lines added above: it follows its call
    keys('C-g'); text('9'); keys('Enter'); keys('Home'); keys('Enter'); keys('Enter'); time.sleep(0.8)
    rows = screen().splitlines()
    at = next((i for i, r in enumerate(rows) if 'echo sq(5 + 1)' in r), -1)
    check('632 lines added above: the expansion stays under its call', at >= 0 and
          'the template sq writes' in rows[at + 1], screen())
    keys('C-z'); keys('C-z'); time.sleep(0.5)
    # Alt+M again on the call: hidden
    keys('C-g'); text('10:9'); keys('Enter'); keys('M-m'); time.sleep(0.5)
    check('632 Alt+M again hides it', 'the template sq writes' not in screen(), screen())
    # a template with a block: the names in it go to their definition
    keys('C-g'); text('11:4'); keys('Enter'); keys('M-m')
    ok = wait_for(r'the template withLog writes', 5)
    s = screen()
    check('632 a template with a block: the body in its place', ok and 'echo "start ", "job"' in s and
          re.search(r'echo "working"\s*\n.*echo "done"\s*\n.*echo "end ", "job"', s) is not None, s)
    rows = s.splitlines()
    y = next((i for i, r in enumerate(rows) if 'echo "start ", "job"' in r), -1)
    x = rows[y].index('echo "start') if y >= 0 else 0
    click(x + 2, y + 1)
    ok = wait_for(r'system', 8)
    check('632 a name in the expansion: a click goes to where it is declared (echo: system)', ok and
          'system' in screen(), screen())
    keys('C-w'); time.sleep(0.6)
    # the header hides it when tapped
    rows = screen().splitlines()
    y = next((i for i, r in enumerate(rows) if 'the template withLog writes' in r), -1)
    if y >= 0: click(rows[y].index('the template') + 2, y + 1)
    time.sleep(0.5)
    check('632 a tap on its header hides it', y >= 0 and 'the template withLog writes' not in screen(), screen())
    # a macro: the compiler expands it
    need('nim')
    tm('send-keys', '-t', 'f', '-l', '\x1b[<35;1;30M')        # (the mouse away: no tooltip over the rows)
    keys('C-g'); text('14:4'); keys('Enter'); keys('M-m')
    ok = wait_for(r'the macro twice writes', 5)
    ok = ok and wait_for(r'(?s)echo \["hi"\].*echo \["hi"\]', 60)
    keys('Escape'); time.sleep(0.3)
    s = screen()
    check('632 a macro: the compiler writes it out, under the call', ok and 'expanding' not in s, s)
    keys('C-p'); text('>Nim: hide every macro expansion'); time.sleep(0.4); keys('Enter'); time.sleep(0.5)
    check('632 hide every expansion', 'the macro twice writes' not in screen(), screen())


def pkg632_install(home):
    # a nimble package as nimble installs it: ~/.nimble/pkgs2/name-version-checksum/
    d = home + '/.nimble/pkgs2/tinypkg632-0.1.0-' + 'ab' * 20
    os.makedirs(d, exist_ok=True)
    open(d + '/tinypkg632.nim', 'w').write('proc greet*(who: string): string = "hello " & who\n')
    open(d + '/tinypkg632.nimble', 'w').write('version = "0.1.0"\nauthor = "x"\ndescription = "x"\nlicense = "MIT"\n')
    return d

def t_632_package_installed():
    # 6.32: a nimble package installed while ned runs (in its terminal or another): what read the package folders
    # when it started reads them again — no "cannot open file" for it (after a save, and back after the next, was
    # the bug), with ned's engine and the compiler, and with nimlangserver
    home = W + '/home632'
    os.makedirs(home + '/.nimble/pkgs2', exist_ok=True)
    setup({"nim.nimsuggest": False})
    open(W + '/src/usepkg.nim', 'w').write('import tinypkg632\n\necho greet("you")\n')
    start('src/usepkg.nim', w=130, h=30, env_extra='HOME=' + home)
    ok = wait_for(r'cannot open file: tinypkg632', 25)
    check('632 a package not installed: cannot open file', ok, screen())
    # (nothing installed yet: no "packages changed" when ned has just started — what `nim dump` adds to the list
    # of folders it looks at is not a change)
    seen = False
    for _ in range(10):
        time.sleep(0.5)
        if 'Nimble packages changed' in screen(): seen = True
    check('632 … nothing installed: no "packages changed" after ned starts', not seen, screen())
    pkg632_install(home)
    gone = False
    for _ in range(40):
        time.sleep(0.5)
        if 'cannot open file' not in screen():
            gone = True
            break
    check('632 … installed meanwhile: found, without a save', gone, screen())
    keys('C-g'); text('3'); keys('Enter'); keys('End'); text(' # x'); keys('C-s'); time.sleep(6)
    check('632 … and still found after a save, and another', 'cannot open file' not in screen(), screen())
    keys('C-s'); time.sleep(5)
    check('632 … (the second save)', 'cannot open file' not in screen(), screen())
    # nimlangserver: its nimsuggest read the package folders when it started — it starts again
    need('nimlangserver')
    shutil.rmtree(home + '/.nimble/pkgs2', ignore_errors=True)
    os.makedirs(home + '/.nimble/pkgs2', exist_ok=True)
    setup({"nim.ide": "nimlangserver"})
    # (the project's main file: nimlangserver's nimsuggest checks the project through it)
    open(W + '/src/demo.nim', 'w').write('import tinypkg632\n\necho greet("you")\n')
    start('src/demo.nim', w=130, h=30, env_extra='HOME=' + home)
    time.sleep(3); keys('C-s')
    ok = wait_for(r'cannot open file: tinypkg632', 60)
    check('632 nimlangserver: a package not installed', ok, screen())
    pkg632_install(home)
    gone = False
    for _ in range(80):
        time.sleep(0.5)
        if 'cannot open file' not in screen():
            gone = True
            break
    check('632 nimlangserver: installed meanwhile — it starts again and finds it', gone, screen())

W632 = ('type ParseFail = object of ValueError\n\nvar counter = 0\n\nproc inner(x: int) =\n  if x < 0:\n'
        '    raise newException(ParseFail, "negative")\n\nproc middle(x: int) =\n  let y = x * 2\n  inner(y)\n\n'
        'proc outer(x: int) =\n  discard x + 1\n  middle(x)\n\nproc touch() =\n  counter = counter + 1\n\n'
        'proc viaTouch() =\n  touch()\n\nouter(1)\nviaTouch()\n')

def t_632_why():
    # 6.32: Why? — where an exception (or a side effect) comes from: the call in each routine down to the raise,
    # each step a row that goes there; a tap on a routine's raises hint asks it
    setup({"nim.nimsuggest": False, "nim.raisesHints": True})
    open(W + '/src/why632.nim', 'w').write(W632)
    start('src/why632.nim', w=130, h=34); time.sleep(2)
    keys('C-g'); text('14'); keys('Enter')
    keys('C-p'); text('>Nim: why?'); time.sleep(0.4); keys('Enter')
    ok = wait_for(r'Why outer can raise ParseFail', 15)
    s = screen()
    check('632 Why?: the chain, each routine on the way', ok and 'outer calls middle' in s and
          'middle calls inner' in s and 'inner: raise ParseFail' in s, s)
    # Enter on the last step: the raise
    keys('Down'); keys('Down'); keys('Enter'); time.sleep(0.6)
    check('632 … Enter goes to that step (the raise, line 7)', re.search(r'Ln 7, Col', screen()) is not None, screen())
    # a side effect: down to the global
    keys('C-g'); text('21'); keys('Enter')
    keys('C-p'); text('>Nim: why?'); time.sleep(0.4); keys('Enter')
    ok = wait_for(r'Why viaTouch has side effects', 15)
    s = screen()
    check('632 Why? of a side effect: the call, then the global', ok and 'viaTouch calls touch' in s and
          'touch uses the global counter' in s, s)
    keys('Escape')
    # a tap on the raises hint (from the top of the file: no sticky header over it)
    keys('C-Home'); time.sleep(0.3)
    wait_for(r'proc middle\(x: int\) \{\.raises: \[ParseFail\]', 20)
    rows = screen().splitlines()
    y = next((i for i, r in enumerate(rows) if 'proc middle' in r and 'raises' in r), -1)
    if y >= 0:
        click(rows[y].index('raises') + 2, y + 1)
        ok = wait_for(r'Why middle can raise ParseFail', 10)
        check('632 a tap on a raises hint: why', ok, screen())
    else:
        check('632 a tap on a raises hint: why (the hint is shown)', False, screen())

E632 = ('type Point = object\n  x, y: int\n\n'
        'proc gives(): int =\n  result = "no"\n\n'
        'proc flag(): bool =\n  return \'c\'\n\n'
        'proc f(p: Point, n: int) =\n  n = 3\n  let k = 1\n  k = 2\n  var s: string\n  s = 5\n  echo p.colour\n'
        '  for i in 0 .. 2:\n    i = 1\n  echo s, k\n\n'
        'const C = 1\nC = 2\n'
        'var g: float\ng = 1\nvar fine: int\nfine = 3\n'
        'proc ok(v: var int; w: int) =\n  v = 1\n  var w = w\n  w = 2\n  echo w\n\n'
        'proc caller() =\n  var a = 0\n  ok(a, 1)\n  f(Point(x: 1, y: 2), 1)\n  echo gives(), flag(), g, fine, C\n\n'
        'caller()\n')

def t_632_engine_errors():
    # 6.32: more of the compiler's errors from ned's engine, as you type (and in ned --lint): an assignment to a
    # let, a const, a for loop's variable or a parameter; a literal of the wrong type given to a variable, to
    # result or to return; a member an object does not have — each where the compiler says it, and nowhere else
    setup({"nim.nimsuggest": False})
    open(W + '/src/e632.nim', 'w').write(E632)
    r = subprocess.run([BIN, '--lint', '--format:json', '--severity:hint', '--fail-on:never', 'src/e632.nim'],
                       capture_output=True, text=True, cwd=W)
    try: got = json.loads(r.stdout)
    except Exception: got = []
    found = sorted((d['line'], d['rule']) for d in got if d['rule'] in ('assign-let', 'literal-type', 'field-missing'))
    want = [(5, 'literal-type'), (8, 'literal-type'), (11, 'assign-let'), (13, 'assign-let'), (15, 'literal-type'),
            (16, 'field-missing'), (18, 'assign-let'), (22, 'assign-let')]
    check('632 the engine: assignments the compiler refuses, literals of the wrong type, a missing member',
          found == want, '%s\n%s\n%s' % (found, r.stdout[:3000], r.stderr[:500]))
    # … where the compiler agrees
    if shutil.which('nim'):
        c = subprocess.run(['nim', 'check', '--hints:off', '--warnings:off', '--colors:off', 'src/e632.nim'],
                           capture_output=True, text=True, cwd=W)
        lines = sorted(set(int(m.group(1)) for m in re.finditer(r'e632\.nim\((\d+), \d+\) Error', c.stdout + c.stderr)))
        check('632 … the compiler says the same lines', lines == sorted(set(l for l, _ in want)), c.stdout + c.stderr)

def t_632_pane_tabs():
    # 6.32: each pane its own tabs (editor groups): the files opened in a pane are tabs in its header; a tap shows
    # one there, Ctrl+PgDn goes through that pane's tabs only, × takes one out (the file closes when no other pane
    # has it)
    setup({"nim.nimsuggest": False})
    start('src/demo.nim', w=150, h=36)
    palette('View: split editor right'); time.sleep(0.5)
    keys('C-p'); text('utils.nim'); time.sleep(0.6); keys('Enter'); time.sleep(0.5)
    keys('C-p'); text('types.nim'); time.sleep(0.6); keys('Enter'); time.sleep(0.5)
    def hdr():
        # (the right pane's header: under the tab bar, its tabs with their ×)
        for i, r in enumerate(screen().split('\n')[2:8]):
            if 'utils.nim ×' in r and 'types.nim ×' in r: return i + 2, r
        return -1, ''
    hy, h = hdr()
    check('632 pane tabs: the right pane\'s files are tabs in its header', hy >= 0 and h.count('×') >= 2, screen())
    # a tap on utils.nim's tab: the right pane shows it
    x = h.find('utils.nim', len(h) // 2)
    click(x + 2, hy + 1); time.sleep(0.4)
    keys('C-Home'); text('# right'); keys('Enter'); keys('C-s'); time.sleep(0.4)
    check('632 … a tap on a tab shows it in that pane', ftext('src/demo/utils.nim').startswith('# right') and
          not ftext('src/demo.nim').startswith('# right'), ftext('src/demo/utils.nim')[:60])
    # Ctrl+PgDn: the pane's next tab (types.nim), not demo.nim of the other pane
    keys('C-NPage'); time.sleep(0.4)
    keys('C-Home'); text('# next'); keys('Enter'); keys('C-s'); time.sleep(0.4)
    check('632 … Ctrl+PgDn goes through the pane\'s own tabs', ftext('src/demo/types.nim').startswith('# next') and
          not ftext('src/demo.nim').startswith('# next'), ftext('src/demo/types.nim')[:60])
    # × on types.nim's tab: out of the pane (and closed: no other pane has it); the pane shows utils.nim
    hy, h = hdr()
    k = h.find('types.nim', len(h) // 2)
    xx = h.find('×', k)
    if xx >= 0: click(xx + 1, hy + 1)
    time.sleep(0.6)
    s = screen()
    rows = s.split('\n')
    check('632 … × takes the tab out of the pane (closed: the tab bar has it no more); the pane shows utils.nim',
          xx >= 0 and 'types.nim' not in rows[1] and any('utils.nim' in r and 'types.nim' not in r for r in rows[2:8]), s)
    # a named layout: kept, the panes closed, put back with its files
    keys('C-p'); text('types.nim'); time.sleep(0.6); keys('Enter'); time.sleep(0.5)
    palette('View: save this layout as'); time.sleep(0.4); text('two up'); keys('Enter'); time.sleep(0.4)
    palette('View: close the other panes'); time.sleep(0.5)
    one = hdr()[0] < 0
    palette('View: layouts'); time.sleep(0.5)
    ok = wait_for(r'two up', 3)
    keys('Enter'); time.sleep(0.8)
    hy, h = hdr()
    check('632 named layouts: kept, then put back — the panes and the right pane\'s tabs', one and ok and hy >= 0, screen())

def t_632_crumbs():
    # 6.32: a breadcrumb tapped lists what is beside it — a symbol's siblings (pick one: the cursor goes there), a
    # folder's files (pick one: it opens)
    setup({"nim.nimsuggest": False})
    open(W + '/src/crumbs.nim', 'w').write('proc alpha() =\n  echo 1\n\nproc beta() =\n  echo 2\n\nproc gamma() =\n'
                                           '  echo 3\n')
    start('src/crumbs.nim', w=130, h=30); time.sleep(1)
    keys('C-g'); text('5:3'); keys('Enter'); time.sleep(0.4)
    rows = screen().split('\n')
    y = next((i for i, r in enumerate(rows[:5]) if 'crumbs.nim' in r and 'beta' in r), -1)
    x = rows[y].find('beta', rows[y].find('crumbs.nim')) if y >= 0 else -1
    if x >= 0: click(x + 2, y + 1)
    ok = wait_for(r'Beside beta', 4)
    s = screen()
    check('632 a symbol crumb: its siblings', ok and 'alpha' in s and 'gamma' in s, s)
    text('gamma'); time.sleep(0.3); keys('Enter'); time.sleep(0.4)
    check('632 … pick one: the cursor goes there (line 7)', re.search(r'Ln 7, Col', screen()) is not None, screen())
    # the folder crumb (src): its files
    rows = screen().split('\n')
    y = next((i for i, r in enumerate(rows[:5]) if 'crumbs.nim' in r and '›' in r), -1)
    x = rows[y].find('src') if y >= 0 else -1
    if x >= 0: click(x + 1, y + 1)
    ok = wait_for(r'demo\.nim', 4)
    s = screen()
    check('632 a folder crumb: what is in it', ok and 'crumbs.nim' in s and 'demo/' in s, s)
    text('demo.nim'); time.sleep(0.3); keys('Enter'); time.sleep(0.5)
    check('632 … pick a file: it opens', 'proc greet' in screen(), screen())

def t_632_minimap_marks():
    # 6.32: the minimap shows what the find box finds (▐ at its right edge) and git's changes (▎ at its left)
    setup({"ui.minimap": "on"})
    open(W + '/mm.nim', 'w').write(''.join('let value%d = %d  # a line long enough to fill the minimap\n' % (i, i)
                                           for i in range(120)))
    git('add mm.nim'); git('commit -qm mm')
    start('mm.nim', w=150, h=40)
    keys('C-g'); text('3'); keys('Enter'); keys('End'); text(' # changed'); keys('C-s'); time.sleep(2.5)
    rows = screen().split('\n')
    # (the minimap: the braille columns at the right of the editor)
    mmx = max((r.rfind('⠀') for r in rows[3:30]), default=-1)
    left = [r for r in rows[3:30] if '▎' in r[100:]]
    check('632 minimap: a changed line marked at its left edge', len(left) >= 1, '\n'.join(rows[:30]))
    keys('C-f'); time.sleep(0.3); text('value7'); time.sleep(0.6)
    rows = screen().split('\n')
    hits = [r for r in rows[3:38] if '▐' in r[100:]]
    check('632 minimap: the find box\'s matches at its right edge', len(hits) >= 2, '\n'.join(rows[:38]))

def t_632_touch_context():
    # 6.32: the touch bar adds the language's own keys while you edit one of its files — Nim's tools in a Nim file
    # (run, check, macro, why, fixes), none in a Markdown file
    setup({"nim.nimsuggest": False, "ui.touchBar": "on"})
    open(W + '/src/tc.nim', 'w').write('proc f(x: int) =\n  if x < 0:\n    raise newException(ValueError, "neg")\n\nf(1)\n')
    open(W + '/notes.md', 'w').write('# notes\n')
    start('src/tc.nim', w=120, h=30); time.sleep(1)
    def touchbar():
        return next((r for r in reversed(screen().split('\n')) if 'Esc' in r and 'Tab' in r), '')
    bar = touchbar()
    check('632 touch bar: Nim\'s keys in a Nim file', 'μ' in bar and '?' in bar and '✓' in bar and 'Esc' in bar, bar)
    keys('C-g'); text('3'); keys('Enter')
    x = bar.find('?')
    rows = screen().split('\n')
    by = next((i for i in range(len(rows) - 1, -1, -1) if 'Esc' in rows[i] and 'Tab' in rows[i]), -1)
    click(x + 1, by + 1)
    ok = wait_for(r'Why f can raise ValueError', 10)
    check('632 … its ? key: why', ok, screen())
    keys('Escape')
    keys('C-p'); text('notes.md'); time.sleep(0.6); keys('Enter'); time.sleep(0.6)
    bar = touchbar()
    check('632 … not in a Markdown file', 'μ' not in bar and 'Esc' in bar, bar)
    # with the touch bar: lists with rows twice as tall (ui.bigTargets), a tap on the second row of one picks it
    keys('C-p'); time.sleep(0.6)
    rows = screen().split('\n')
    ys = [i for i, r in enumerate(rows) if re.search(r'│[▍ ]?[●·]? ?\S+\.(nim|nimble|nims|md)\b', r[:70])][:3]
    check('632 bigger tap targets: a list\'s rows two lines apart', len(ys) >= 2 and ys[1] - ys[0] == 2, '\n'.join(rows))
    keys('Escape')

def t_632_battery():
    # 6.32: battery saver (ui.batterySaver) — on: a leaf in the status bar, the compiler's check waits for a save;
    # a tap on the leaf turns it off
    setup({"nim.nimsuggest": False, "ui.batterySaver": "on", "nim.engineChecks": False})
    open(W + '/src/bat.nim', 'w').write('proc f(x: int): int = x\n\necho f(1)\n')
    start('src/bat.nim', w=120, h=30); time.sleep(1.5)
    st = screen().split('\n')
    bar = next((r for r in reversed(st) if 'Ln ' in r), '')
    check('632 battery saver: its leaf in the status bar', '❦' in bar, bar)
    keys('C-g'); text('3'); keys('Enter'); keys('End'); text(' + "x"'); time.sleep(5)
    check('632 … the compiler waits for a save (no check while typing)', 'type mismatch' not in screen(), screen())
    keys('C-s')
    ok = wait_for(r'type mismatch', 20)
    check('632 … and checks on save', ok, screen())
    st = screen().split('\n')
    y = next((i for i in range(len(st) - 1, -1, -1) if '❦' in st[i]), -1)
    if y >= 0: click(st[y].index('❦') + 1, y + 1)
    ok = wait_for(r'Battery saver off', 4)
    check('632 … a tap on the leaf turns it off', ok and '❦' not in screen(), screen())

def t_632_warm_index():
    # 6.32: ned --warm-index — Nim's standard library read into the index cache once (the Termux package runs it
    # when installed): files appear in the cache, and the first session's hover needs no parsing of them
    need('nim')
    cache = W + '/cache632'
    shutil.rmtree(cache, ignore_errors=True)
    env = dict(os.environ, XDG_CACHE_HOME=cache, XDG_CONFIG_HOME=CFG)
    r = subprocess.run([BIN, '--warm-index'], capture_output=True, text=True, cwd=W, env=env, timeout=600)
    n = len([f for f in os.listdir(cache + '/ned/index')]) if os.path.isdir(cache + '/ned/index') else 0
    check('632 ned --warm-index: the standard library in the index cache', r.returncode == 0 and n > 200 and
          'standard library read into the index cache' in r.stdout, '%d files · %s %s' % (n, r.stdout, r.stderr))

def t_632_pane_views():
    # 6.32: a terminal and the assistant as panes — beside the code, a tab among the files: keys go to the shell
    # (or the assistant) while that pane has the focus; closing the terminal's tab ends its shell
    setup({"nim.nimsuggest": False, "ai.model": "o4-mini-2025-04-16"})
    start('src/demo.nim', w=150, h=36); time.sleep(1)
    palette('View: terminal in a pane'); time.sleep(1.5)
    text('echo hi$((600 + 32))'); keys('Enter')
    ok = wait_for(r'hi632', 8)
    s = screen()
    check('632 a terminal in a pane: the shell answers there, beside the code', ok and 'Terminal 1' in s and
          'proc greet' in s, s)
    # its tab closed (the × on the tab bar — Ctrl+W there is the shell's): the terminal gone, its shell ended
    tb = screen().split('\n')[1]
    k = tb.find('Terminal 1')
    xx = tb.find('×', k) if k >= 0 else -1
    if xx >= 0: click(xx + 1, 2)
    time.sleep(0.8)
    check('632 … its tab closed: the terminal gone', xx >= 0 and 'Terminal 1' not in screen().split('\n')[1], screen())
    palette('View: assistant in a pane'); time.sleep(1)
    text('Explain this file'); keys('Enter')
    ok = wait_for('package entry', 10)
    s = screen()
    check('632 the assistant in a pane: asked and answered beside the code', ok and 'proc greet' in s, s)
    # the panel in a pane: its Output beside the code (from the code's pane, the others closed)
    keys('C-M-S-Left'); keys('C-M-S-Left'); keys('C-M-S-Left'); time.sleep(0.3)
    palette('View: close the other panes'); time.sleep(0.5)
    palette('View: panel in a pane'); time.sleep(0.8)
    s = screen()
    check('632 the panel in a pane: its tabs (Problems, Output, Terminal) in a pane at the right',
          'PROBLEMS' in s and 'OUTPUT' in s and 'proc greet' in s, s)

def t_632_theme_import():
    # 6.32: a Zed theme family and a Helix theme (with the theme it inherits) imported: written, the dark one in use
    setup({"theme": "nim-crown", "nim.nimsuggest": False})
    start('src/demo.nim', w=120, h=30); time.sleep(0.5)
    S = REPO + '/tests/themes/samples'
    palette('Theme: import a Zed or Helix'); time.sleep(0.4)
    keys('C-u'); text(S + '/zed-harbour.json'); keys('Enter'); time.sleep(1.0)
    a = tm('capture-pane', '-t', 'f', '-e', '-p').stdout
    check('632 Zed: both themes written, the dark one in use', os.path.exists(CFG + '/ned/themes/harbour-dusk.json') and
          os.path.exists(CFG + '/ned/themes/harbour-day.json') and '48;2;27;36;48' in a, screen())
    palette('Theme: import a Zed or Helix'); time.sleep(0.4)
    keys('C-u'); text(S + '/helix-harbour-night.toml'); keys('Enter'); time.sleep(1.0)
    a = tm('capture-pane', '-t', 'f', '-e', '-p').stdout
    check('632 Helix: written and in use, its palette over the parent\'s', '48;2;22;26;32' in a, screen())

def t_632_autodedent():
    # 6.32: in Nim, `of` typed at the start of a line goes back to its case's column, a closing bracket typed alone
    # on its line to the line that opened it (editor.autoDedent); off: nothing moves
    for on in (True, False):
        setup({"nim.nimsuggest": False, "editor.autoClosePairs": False, "editor.autoDedent": on,
               "editor.autoComplete": False})
        open(W + '/src/ad.nim', 'w').write('')
        start('src/ad.nim', w=110, h=30); time.sleep(0.8)
        text('case k'); keys('Enter'); text('of 1:'); keys('Enter'); text('echo 1'); keys('Enter'); text('of 2: discard')
        keys('Enter'); keys('Enter'); text('foo('); keys('Enter'); text('a'); keys('Enter'); text(')')
        keys('C-s'); time.sleep(0.6)
        ls = ftext('src/ad.nim').split('\n')
        of2 = next((l for l in ls if 'of 2' in l), '')
        close = next((l for l in ls if l.strip() == ')'), '')
        if on:
            check('632 auto-dedent: `of` back at its case\'s column, `)` back at its line\'s', of2.startswith('of 2') and
                  close == ')', repr(ls))
        else:
            check('632 auto-dedent off: nothing moves', of2.startswith('  ') and close.startswith(' '), repr(ls))

def t_632_tour():
    # 6.32: the Nim tour — a lesson opens as your copy in ned's state folder (a folder ned trusts with folder trust
    # on), its cells run compiled (its `# notebook: compiled` line), the exercise's check says ✓ and the lesson is
    # marked done; the list of lessons, the next one
    need('nim')
    setup({"nim.nimsuggest": False, "security.folderTrust": "ask"})
    d = STATE + '/ned/tour'
    os.makedirs(d, exist_ok=True)
    lesson = open(REPO + '/tour/lesson01_hello.nim').read()
    mine = lesson.replace('let who = "World"\nlet message = ""', 'let who = "Grace"\nlet message = "Hello, " & who & "!"')
    open(d + '/lesson01_hello.nim', 'w').write(mine)
    start(w=150, h=48); time.sleep(0.5)
    keys('Escape')
    palette('Nim: tour (lessons in the notebook)')
    ok = wait_for(r'lesson01_hello\.nim', 10)
    s = screen()
    check('632 the Nim tour: lesson 1 opens, its answer folded away', ok and '# Answer:' in s and '  # let who' not in s, s)
    palette('Notebook: run all the cells')
    keys('C-g'); text('76'); keys('Enter')
    ok = wait_for(r'✓ Hello, Grace!', 120)
    check('632 … its cells run (compiled, in a folder ned trusts): the exercise says ✓', ok, screen())
    ok = wait_for(r'done ✓', 10)
    try: prog = json.load(open(d + '/progress.json'))
    except Exception: prog = {}
    check('632 … the lesson is marked done', ok and prog.get('done') == [0], '%s · %s' % (prog, screen()))
    keys('Escape')
    palette('Nim: tour — all the lessons')
    ok = wait_for(r'1 of 16', 8)
    check('632 … the list: 1 of 16 done, a ✓ beside lesson 1', ok and '✓' in screen(), screen())
    keys('Escape')
    palette('Nim: tour — next lesson')
    ok = wait_for(r'lesson02_values\.nim', 8)
    check('632 … the next lesson: your copy of lesson 2', ok and os.path.exists(d + '/lesson02_values.nim'), screen())

def t_632_refactorings():
    # 6.32: the bigger refactorings — each a diff first (Apply it / Leave it), then the change, one Ctrl+Z per file:
    # object ⇄ ref object, a call's syntax, the selection split into a new module, callback → async
    setup({"nim.nimsuggest": False})
    open(W + '/rfa.nim', 'w').write("type\n  P = object\n    x: int\n\nproc use() =\n  var q: P\n  q.x = 2\n  echo q.x\n")
    start('rfa.nim', w=150, h=42)
    keys('Down', 'End', 'Home')
    palette('Refactor: object'); time.sleep(1.0)
    s = screen()
    check('632 object ⇄ ref object: a diff first, with Apply it and Leave it', 'Apply it' in s and 'Leave it' in s and
          'ref object' in s, s)
    keys('Enter'); time.sleep(1.0); keys('C-s'); time.sleep(0.8)
    t = ftext('rfa.nim')
    check('632 … applied: ref object, `var q = P()`', 'P = ref object' in t and 'var q = P()' in t, t)
    keys('C-z'); time.sleep(0.5); keys('C-s'); time.sleep(0.8)
    t = ftext('rfa.nim')
    check('632 … one Ctrl+Z undoes it', 'P = object' in t and 'var q: P' in t, t)
    # a call's syntax at the cursor
    open(W + '/rfc.nim', 'w').write("proc f(a, b: int): int = a + b\nlet x = f(1, 2)\necho x\n")
    tm('kill-server'); time.sleep(0.3)
    start('rfc.nim', w=150, h=42)
    keys('Down', 'Home')
    for _ in range(8): keys('Right')
    palette('Refactor: switch call syntax'); time.sleep(1.0)
    s = screen()
    check('632 switch call syntax: a diff with 1.f(2)', 'Apply it' in s and '1.f(2)' in s, s)
    keys('Enter'); time.sleep(0.8); keys('C-s'); time.sleep(0.8)
    check('632 … applied', 'let x = 1.f(2)' in ftext('rfc.nim'), ftext('rfc.nim'))
    # the selected proc into a new module (the palette opened by hand: palette() presses Escape, dropping the selection)
    open(W + '/rfbig.nim', 'w').write("proc helper*(s: string): string = s & \"!\"\n\nproc main*() =\n  echo helper(\"a\")\n")
    tm('kill-server'); time.sleep(0.3)
    start('rfbig.nim', w=150, h=42)
    keys('Home', 'S-Down'); time.sleep(0.3)
    keys('C-p'); text('>Refactor: split'); time.sleep(0.5); keys('Enter'); time.sleep(1.5)
    text('rfsmall.nim'); keys('Enter'); time.sleep(1.2)
    s = screen()
    check('632 split into a new module: a diff of both files', 'Apply it' in s, s)
    keys('Enter'); time.sleep(1.0)
    palette('Save all'); time.sleep(1.0)
    big = ftext('rfbig.nim')
    small = ftext('rfsmall.nim') if os.path.exists(W + '/rfsmall.nim') else ''
    check('632 … moved, imported, exported again', 'proc helper*' in small and 'import rfsmall' in big and
          'export helper' in big, big + '\n----\n' + small)
    # callback → async
    open(W + '/rfcb.nim', 'w').write("import std/asyncdispatch\n\nproc fetch(u: string, cb: proc (r: string)) =\n"
                                     "  cb(u & \"!\")\n\nproc run() {.async.} =\n  fetch(\"a\") do (r: string):\n    echo r\n")
    tm('kill-server'); time.sleep(0.3)
    start('rfcb.nim', w=150, h=42)
    keys('Down', 'Down', 'Home')
    for _ in range(6): keys('Right')
    palette('Refactor: callback'); time.sleep(1.0)
    s = screen()
    check('632 callback → async: a diff first', 'Apply it' in s, s)
    keys('Enter'); time.sleep(1.0); keys('C-s'); time.sleep(0.8)
    t = ftext('rfcb.nim')
    check('632 … applied: Future[string], and `let r = await fetch("a")` in the caller',
          'Future[string] {.async.}' in t and 'let r = await fetch("a")' in t, t)

def t_6322_emacs_panes():
    # 6.32.2: Emacs's C-x 1 keeps the pane you are in and closes the others (delete-other-windows) — it closed the pane
    # you were in; C-x 3, C-x o and C-x 0 as Emacs has them
    setup({"editor.keymap": "emacs"})
    open(W + '/e1.txt', 'w').write('first file\n')
    open(W + '/e2.txt', 'w').write('second file\n')
    start('e1.txt', 'e2.txt', w=120, h=30); time.sleep(0.5)
    keys('C-x'); text('3'); time.sleep(0.6)                 # (a pane at the right, with the same file: e2)
    keys('C-x'); text('b'); time.sleep(0.4); text('e1.txt'); time.sleep(0.4); keys('Enter'); time.sleep(0.5)
    s = screen()
    check('6322 emacs C-x 3, C-x b: two panes, two files', 'first file' in s and 'second file' in s, s)
    keys('C-x'); text('o'); time.sleep(0.3)                 # (the other pane: e2's)
    keys('C-x'); text('1'); time.sleep(0.6)
    s = screen()
    check('6322 emacs C-x 1: the pane you are in stays, the others close', 'second file' in s and
          'first file' not in s, s)
    keys('C-x'); text('3'); time.sleep(0.5); keys('C-x'); text('0'); time.sleep(0.6)
    check('6322 emacs C-x 0: the pane you are in closes', screen().count('second file') == 1, screen())

def ned_rss_mb():
    # (the ned the test started: its resident memory, in MB — 0 when it cannot be found)
    for p in os.listdir('/proc'):
        if not p.isdigit(): continue
        try:
            if os.path.realpath('/proc/%s/exe' % p) != os.path.realpath(BIN): continue
            if b'--engine-worker' in open('/proc/%s/cmdline' % p, 'rb').read(): continue
            if os.path.realpath('/proc/%s/cwd' % p) != os.path.realpath(W): continue
            for l in open('/proc/%s/status' % p):
                if l.startswith('VmRSS:'): return int(l.split()[1]) / 1024
        except OSError: pass
    return 0

def t_6322_close_frees():
    # 6.32.2: a tab closed takes with it what ned kept about it (the semantic colours, the dimmed code, the engine's
    # checks, the hints …): a big file opened and closed thirty times — ned grew by 1.6 MB each time before
    if not os.path.exists('/proc/self/status'): raise Skip('no /proc here')
    setup({"nim.nimsuggest": False})
    # (big modules with imports of their own: ned's formatter, four copies of it beside the modules it imports)
    shutil.copytree(REPO + '/src/ned/format', W + '/src/fmt')
    for k in range(4): shutil.copy(W + '/src/fmt/nim.nim', W + '/src/fmt/big%d.nim' % k)
    start('src/demo.nim', w=130, h=36); time.sleep(1)
    def cycle(n):
        for i in range(n):
            keys('C-p'); time.sleep(0.25); text('big%d' % (i % 4)); time.sleep(0.4); keys('Enter'); time.sleep(1.8)
            keys('C-w'); time.sleep(0.4); keys('Escape')
    cycle(8)                                   # (warm: the imports read, the caches filled once)
    before = ned_rss_mb()
    cycle(30)
    after = ned_rss_mb()
    check('6322 a tab closed frees what was kept for it: 30 opens and closes, ned grows by %.0f MB' % (after - before),
          before > 0 and after - before < 12, '%.1f → %.1f MB' % (before, after))

def t_6323_macro_members():
    # 6.32.3: a member a macro call makes (`makeGetters(Config, title)` and `cfg.getTitle`) is not "undeclared field"
    # — with the engine worker (it is told what the calls make) and without it (the check is made again when the
    # names come); a member nothing makes still is; with nim.macroNames off nothing is marked (the names are never
    # known); the next start has the names, and the project's `nim dump`, from the disk: no compiler needed for them
    src = ('import std/[macros, strutils]\n\ntype Config = object\n  title: string\n  size: int\n\n'
           'macro makeGetters(T: typedesc, fields: varargs[untyped]): untyped =\n  result = newStmtList()\n'
           '  for f in fields:\n    let name = ident("get" & capitalizeAscii($f))\n    result.add quote do:\n'
           '      proc `name`(x: `T`): auto = x.`f`\n\nmakeGetters(Config, title, size)\n\n'
           'let cfg = Config(title: "t", size: 2)\necho cfg.getTitle, cfg.getSize\necho cfg.colour\n')
    real = shutil.which('nim')
    def project():
        open(W + '/mg.nim', 'w').write(src)
        os.makedirs(W + '/bin', exist_ok=True)
        # (a `nim` that takes 20 s when NIM_SLOW is set: what the next start knows at once is not the compiler's)
        open(W + '/bin/nim', 'w').write('#!/bin/sh\n[ -n "$NIM_SLOW" ] && sleep 20\nexec %s "$@"\n' % real)
        os.chmod(W + '/bin/nim', 0o755)
    path = W + '/bin:' + TOOLS + ':$PATH'
    env = 'XDG_CACHE_HOME=' + W + '/cache'
    for worker in (True, False):
        setup({"nim.nimsuggest": False, "nim.compilerAnswers": False, "nim.engineWorker": worker})
        project()
        start('mg.nim', w=130, h=30, path=path, env_extra=env)
        tag = 'worker' if worker else 'no worker'
        ok = wait_for(r"undeclared field: 'colour'", 30)
        check('6323 %s: a member nothing makes is marked' % tag, ok, screen())
        time.sleep(3)
        keys('C-g'); text('17:10'); keys('Enter'); time.sleep(0.3); keys('M-h')
        check('6323 %s: hover knows what makeGetters made' % tag, wait_for(r'made by', 10), screen())
        keys('Escape'); time.sleep(1)
        check("6323 %s: cfg.getTitle (the macro made it) is not marked" % tag, "'getTitle'" not in screen(), screen())
    cache = W + '/cache/ned'
    check('6323 kept on disk: what the macro calls made, and nim dump',
          os.path.isdir(cache + '/macros') and os.listdir(cache + '/macros') and os.path.isdir(cache + '/dump') and
          os.listdir(cache + '/dump'), str(os.listdir(cache)) if os.path.isdir(cache) else 'no cache')
    tm('kill-server'); time.sleep(0.3)
    start('mg.nim', w=130, h=30, path=path, env_extra=env + ' NIM_SLOW=1')
    time.sleep(2)
    keys('C-g'); text('17:10'); keys('Enter'); time.sleep(0.3); keys('M-h')
    check('6323 the next start: known at once, with a compiler that takes 20 s (from the disk)',
          wait_for(r'made by', 4), screen())
    keys('Escape')
    tm('kill-server'); time.sleep(0.3)
    setup({"nim.nimsuggest": False, "nim.compilerAnswers": False, "nim.macroNames": False})
    project()
    start('mg.nim', w=130, h=30, path=path, env_extra=env)
    keys('C-g'); text('17'); keys('Enter'); time.sleep(8)
    check("6323 nim.macroNames off: cfg.getTitle is not marked (what the call makes is never known)",
          "'getTitle'" not in screen(), screen())

def t_635_nim_chip():
    # a tap on the status bar's Nim label says which Nim and why, and offers the rest — on a narrow screen the
    # menu's items stay inside its frame (a command's long description was drawn over the label and the frame)
    setup({"nim.nimsuggest": False})
    start('src/demo.nim', w=80, h=30)
    time.sleep(1.5)
    s = screen()
    row = next((i for i, l in enumerate(s.split('\n')) if '✓ Nim' in l), -1)
    check('635 the status bar shows the Nim', row >= 0, s)
    if row < 0: return
    col = s.split('\n')[row].index('✓ Nim') + 3
    click(col, row + 1)
    ok = wait_for(r'Make this project Nim 3', 4)
    s = screen()
    check('635 a tap on it: which Nim and why, and the choices', ok and re.search(r'Nim \d+\.\d+\.\d+ \(', s) and
          ('Install nimony' in s or 'Update nimony' in s), s)
    # (every line of the menu begins with its frame: nothing written over it)
    lines = [l for l in s.split('\n') if 'nimony' in l or 'Choose the Nim' in l]
    check('635 … its items inside the frame on an 80-column screen', lines and all(l.lstrip().startswith('│') for l in lines),
          s)
    keys('Escape')


def t_636_typing_nif():
    # Nim 2.4: the check while typing is `nim nif -`, and the compiler's reading of the unsaved text gives hover its
    # type and F12 its overload before any save (up to 6.35 only a saved file's NIF did) — and still after a line
    # typed in above (the lines below it moved by one)
    need('nim-2.4')
    setup({"nim.nimsuggest": False})
    open(W + '/tn.nim', 'w').write('import std/tables\nproc show(x: int): string = "int " & $x\n'
                                   'proc show(x: float): string = "float " & $x\n\necho show(1)\n')
    start('tn.nim', w=110, h=30, path=NIM24 + ':' + TOOLS + ':$PATH'); time.sleep(2)
    keys('C-End', 'Enter'); text('let fresh = initTable[string, seq[int]]()')
    keys('Enter'); text('echo show(2.5), fresh.len')
    time.sleep(7)                                    # (the pause, then the check)
    keys('C-g'); text('6:6'); keys('Enter'); keys('M-h')
    ok = wait_for(r"the compiler's type: `?Table\[string, seq\[int\]\]", 8)     # (hover draws `code` without them)
    check("636 hover on a let typed in, not saved: the compiler's type", ok, screen())
    keys('Escape'); keys('C-g'); text('7:7'); keys('Enter'); keys('F12')
    check('636 F12 in unsaved text: the overload the compiler chose', wait_for(r'Ln 3, Col', 4), screen())
    keys('C-Home'); text('# top'); keys('Enter')
    keys('C-g'); text('7:6'); keys('Enter'); keys('M-h')
    check("636 … a line typed in above: still the compiler's type, one line down",
          wait_for(r"the compiler's type: `?Table", 6), screen())
    keys('Escape')
    check('636 the file is not saved for it', 'fresh' not in ftext('tn.nim'), ftext('tn.nim'))
    sh('rm -f ' + W + '/tn.nim')

def t_636_one_check():
    # Save all with five changed files that one module includes: one compiler checks that module at a time, and once
    # more at the end for the rest (each save started its own: nine `nim check` of ned's own source at once in the
    # soak, 800 MB each — on a phone, enough to close Termux)
    setup({"nim.nimsuggest": False})
    d = W + '/onecheck'
    os.makedirs(d, exist_ok=True)
    parts = ['p%d' % i for i in range(5)]
    for p in parts: open('%s/%s.nim' % (d, p), 'w').write('proc %s(): int = 1\n' % p)
    open(d + '/main.nim', 'w').write('import std/[json, httpclient, asyncdispatch, strutils, tables]\ninclude ' +
                                     ', '.join(parts) + '\necho ' + ' + '.join(p + '()' for p in parts) + '\n')
    start('onecheck/main.nim', w=110, h=30); time.sleep(2)
    for p in parts:
        keys('C-p'); text(p + '.nim'); time.sleep(0.6); keys('Enter'); time.sleep(0.6)
        keys('C-End', 'Enter'); text('# changed')
    keys('C-e'); text('Save all'); time.sleep(0.4); keys('Enter')
    most, t0 = 0, time.time()
    while time.time() - t0 < 8:
        n = sum(1 for l in sh('ps -eo args').stdout.split('\n') if l.startswith('nim ') and d + '/main.nim' in l)
        most = max(most, n)
        time.sleep(0.1)
    saved = all('# changed' in open('%s/%s.nim' % (d, p)).read() for p in parts)
    check('636 Save all of five files one module includes: one compiler at a time', saved and most == 1,
          'saved: %s, compilers at once: %d' % (saved, most))
    keys('Escape')

def t_637_nim3_typing():
    # Nim 3: the check while typing is nimony's, and its NIF of the unsaved text gives hover the compiler's type —
    # as Nim 2.4's `nim nif -` does since 6.36
    need('nimony')
    setup({"nim.compiler": "nimony", "nim.nimsuggest": None})
    open(W + '/src/n3t.nim', 'w').write('import std/syncio\n\nproc twice(x: int): int = x * 2\n\necho twice(1)\n')
    start('src/n3t.nim', w=110, h=30); time.sleep(1.5)
    keys('C-End', 'Enter'); text('let fresh = twice(4)')
    keys('Enter'); text('echo fresh')
    ok, t0 = False, time.time()
    while time.time() - t0 < 45 and not ok:                # (the check after a pause: nimony takes a few seconds)
        keys('C-g'); text('6:6'); keys('Enter'); keys('M-h')
        ok = wait_for(r"the compiler's type: `?int", 3)
        s = screen()
        keys('Escape')
    check("637 Nim 3: hover on a let typed in, not saved: nimony's type", ok, s)
    check('637 … the file is not saved for it', 'fresh' not in ftext('src/n3t.nim'), ftext('src/n3t.nim'))

def t_637_check_slots():
    # Save all with five changed modules of their own (five checks of five programs): two compilers at a time, the
    # others wait for their turn — and every file still gets its check
    setup({"nim.nimsuggest": False})
    d = W + '/slots'
    os.makedirs(d, exist_ok=True)
    mods = ['s%d' % i for i in range(5)]
    for m in mods:
        open('%s/%s.nim' % (d, m), 'w').write('import std/[json, httpclient, asyncdispatch, strutils, tables]\n'
                                              'proc %s*(): int = 1\necho %s()\n' % (m, m))
    start('slots/s0.nim', w=110, h=30); time.sleep(2)
    for m in mods:
        keys('C-p'); text(m + '.nim'); time.sleep(0.6); keys('Enter'); time.sleep(0.6)
        keys('C-End', 'Enter'); text('let bad%s: int = "x"' % m)
    keys('C-e'); text('Save all'); time.sleep(0.4); keys('Enter')
    most, t0 = 0, time.time()
    while time.time() - t0 < 12:
        n = sum(1 for l in sh('ps -eo args').stdout.split('\n') if l.startswith('nim ') and d + '/' in l)
        most = max(most, n)
        time.sleep(0.1)
    check('637 Save all of five modules: two compilers at a time', 1 <= most <= 2, 'compilers at once: %d' % most)
    keys('C-e'); text('Problems'); time.sleep(0.4); keys('Enter')
    ok = wait_until(lambda: all(('bad%s' % m) in screen() or 'type mismatch' in screen() for m in mods), 20)
    s = screen()
    check('637 … and each still checked: its error in Problems', s.count('type mismatch') >= 5 or
          all(m + '.nim' in s for m in mods), s)
    keys('Escape')

def t_637_low_memory():
    # short of memory (ui.lowMemory over what the system has free): the status bar says so, a message says what ned
    # does, and the compiler checks on save only — not while you type
    setup({"nim.nimsuggest": False, "ui.lowMemory": 100000000})
    open(W + '/lowm.nim', 'w').write('proc f(x: int): int = x + 1\necho f(1)\n')
    start('lowm.nim', w=120, h=30)
    ok = wait_for(r'mem low', 10)
    s = screen()
    check('637 low memory: the status bar says so', ok, s)
    keys('C-End', 'Enter'); text('{.error: "said by the compiler".}')    # (ned's own checks do not say this)
    time.sleep(6)
    s = screen()
    check('637 … no compiler check while typing', '● said by the compiler' not in s, s)   # (its message: after a ●)
    keys('C-s')
    ok = wait_for(r'● said by the compiler', 20)
    check('637 … the check on save still runs', ok, screen())
    sh('rm -f ' + W + '/lowm.nim')

EM638 = '{.emit: """\nstatic int twice(int x) { return 2 * x; }\n""".}\necho 1\n'

def t_638_nim_panel():
    # the Nim panel in parts, a blank row between them; a part's title folds it (▸, how many rows it hides) and a
    # second click unfolds it. A Nim file with C in {.emit}: the C · CLANGD part says what answers for it, and so does
    # the status bar — "C · ned" with no clangd (ned's own C engine), "C · clangd" once clangd answers
    setup({"nim.nimsuggest": False})
    open(W + '/em.nim', 'w').write(EM638)
    sys_clangd = any(os.path.exists(d + '/clangd') for d in ('/usr/bin', '/bin'))
    start('em.nim', w=150, h=44, path=NIMBIN + ':/usr/bin:/bin'); time.sleep(1.0)
    if not sys_clangd:
        check('638 no clangd: "C · ned" in the status bar for a Nim file with C in {.emit}', wait_for(r'C · ned', 8),
              screen())
    keys('M-e'); time.sleep(1.0)
    s = screen()
    rows = s.splitlines()
    y = next((i + 1 for i, l in enumerate(rows) if '▾ NIMBLE' in l), 0)
    check('638 the Nim panel in parts, a blank row between them', '▾ PROJECT' in s and y > 1 and
          rows[y - 2][:25].strip() == '', s)
    click(4, y); time.sleep(0.6)
    s = screen()
    check('638 a click on a part\'s title folds it: ▸ and how many rows it hides',
          re.search(r'▸ NIMBLE +\+\d+', s) is not None and 'nimble build' not in s, s)
    click(4, y); time.sleep(0.6)
    s = screen()
    check('638 … and a second click unfolds it', '▾ NIMBLE' in s and 'nimble build' in s, s)
    for _ in range(12): tm('send-keys', '-t', 'f', '-l', '\x1b[<65;5;20M'); time.sleep(0.05)   # (the wheel, over the panel)
    time.sleep(0.6)
    s = screen()
    check('638 the C · CLANGD part: what answers for the C here', '▾ C · CLANGD' in s and
          (sys_clangd or ('clangd: not installed' in s and 'here: clangd is not' in s)), s)
    if which('clangd') and not sys_clangd:
        tm('kill-server'); time.sleep(0.3)
        setup({"nim.nimsuggest": False})
        open(W + '/em.nim', 'w').write(EM638)           # (setup made the folder anew)
        start('em.nim', w=150, h=44, path=TOOLS + ':/usr/bin:/bin')
        check('638 with clangd: "C · clangd" once it answers for the {.emit}', wait_for(r'C · clangd (?!…)', 30),
              screen())
    sh('rm -f ' + W + '/em.nim')

PLUG638 = '''import nedplugin

filetype("plaintext", indentSize = 3)

command "P638: pieces":
  let m = openMultibuffer("p638", [piece("a.txt", 0, 0)])
  let m2 = addPiece(piece("b.txt", 1, 1), m)
  message("pieces " & $m2.pieces.len & " at " & $lineInMultibuffer(m2, "b.txt", 1))

command "P638: drop a piece":
  let m = current()
  removePiece(m, 0)
  refreshMultibuffer(m)
  message("left " & $m.pieces.len)

command "P638: panes":
  let n = splitPane()
  let k = panes().len
  closePane(n)
  message("panes " & $k & " then " & $panes().len)
'''

def t_638_plugin_api_rest():
    # the parts of the plugin API nothing else runs in a real ned: a multibuffer's pieces added, found, taken out and
    # read again; a pane split off and closed; a language's indent changed (filetype)
    setup()
    d = CFG + '/ned/plugins/p638'
    os.makedirs(d, exist_ok=True)
    open(d + '/plugin.nims', 'w').write(PLUG638)
    open(W + '/a.txt', 'w').write('alpha\none\n')
    open(W + '/b.txt', 'w').write('beta\ntwo\n')
    start('a.txt', w=140, h=36); time.sleep(0.5)
    palette('Plugins panel')
    ok = wait_for('running · (nim e|native) · 1 plugin', 40)
    keys('Escape'); time.sleep(0.2)
    check('638 plugin API: the plugin runs', ok, screen())
    check('638 plugin API: filetype — its indent for the language (Spaces: 3)', wait_for('Spaces: 3', 6), screen())
    palette('P638: pieces')
    check('638 plugin API: openMultibuffer, addPiece, lineInMultibuffer', wait_for(r'pieces 2 at \d+', 10), screen())
    palette('P638: drop a piece')
    check('638 plugin API: removePiece, refreshMultibuffer', wait_for('left 1', 10), screen())
    palette('P638: panes')
    check('638 plugin API: splitPane, closePane', wait_for('panes 2 then 1', 10), screen())
    sh('rm -rf ' + d + ' ' + W + '/a.txt ' + W + '/b.txt')

PLUG639 = '''import nedplugin

onJobDone do (job: JobEnd):
  message("job ended: " & job.title & " → " & $job.code)
'''

def t_639_themes_and_job_event():
    # the themes added in 6.39 in the picker, a short name other editors use taken for one of them; a plugin told when
    # a run of yours ends (onJobDone: what it was, its exit code)
    setup({"theme": "gruvbox-material", "nim.nimsuggest": False})
    d = CFG + '/ned/plugins/p639'
    os.makedirs(d, exist_ok=True)
    open(d + '/plugin.nims', 'w').write(PLUG639)
    start('src/demo.nim', w=120, h=34); time.sleep(0.8)
    a = screen_ansi()
    check('639 "theme": "gruvbox-material" is gruvbox-material-dark (its background)', '48;2;40;40;40' in a, screen())
    keys('M-t'); time.sleep(0.6); text('flexoki'); time.sleep(0.4)
    s = screen()
    check('639 the new themes in the picker (flexoki-dark, flexoki-light)', 'flexoki-dark' in s and 'flexoki-light' in s, s)
    keys('Escape'); time.sleep(0.2)
    keys('M-t'); time.sleep(0.6); text('carbonfox'); time.sleep(0.4); keys('Enter'); time.sleep(0.8)
    a = screen_ansi()
    check('639 … and chosen: carbonfox (its background)', '48;2;22;22;22' in a, screen())
    palette('Plugins panel')
    ok = wait_for('running · (nim e|native) · 1 plugin', 40)
    keys('Escape'); time.sleep(0.2)
    check('639 the plugin with onJobDone starts with ned', ok, screen())
    palette('Run command…'); time.sleep(0.4)
    keys('C-u'); text('sh -c "exit 3"'); keys('Enter')
    check('639 onJobDone: told what ended and its exit code', wait_for(r'job ended: sh -c "exit 3" → 3', 15), screen())
    sh('rm -rf ' + d)

def t_640_undo_kept_bounded():
    # the undo history kept for a file's next opening stays within its bound: a Replace all done, undone and done
    # again on every visit used to keep one more undo-tree branch each time (10 MB a file after six visits, read back
    # in every time it opened)
    setup({"nim.nimsuggest": False})
    with open(W + '/big.txt', 'w') as f:
        for k in range(60000): f.write('line %d value %d\n' % (k, k))
    start('big.txt', w=120, h=30); time.sleep(0.8)
    for _ in range(4):
        keys('C-r'); keys('C-u'); text('value'); keys('Enter'); time.sleep(0.3); keys('C-u'); text('worth')
        keys('Enter'); time.sleep(0.6); keys('a'); time.sleep(2.5); keys('Escape')
        keys('C-z'); time.sleep(1.2)
        keys('C-w'); time.sleep(0.8)
        palette('Reopen closed tab'); time.sleep(1.5)
    d = STATE + '/ned/undo'
    sizes = [os.path.getsize(os.path.join(d, f)) for f in os.listdir(d)] if os.path.isdir(d) else []
    check('640 the undo history kept on disk stays within 4 MB after four visits with a Replace all each',
          sizes and max(sizes) <= 4_100_000, str(sizes))
    keys('C-y'); time.sleep(2.0)
    check('640 … and what is kept still works: Redo after reopening redoes the Replace all',
          'line 0 worth 0' in screen(), screen())
    sh('rm -f ' + W + '/big.txt')

def t_640_no_panels_at_start():
    # (Foxoman's bug) every launch starts with no dock and no panel open, the keys in the editor: a file tree left open
    # had the keys, and the welcome screen's d (Open folder) deleted the file selected there. ui.restorePanels brings
    # them back; a dock that is not on the screen never takes a key
    setup({"nim.nimsuggest": False})
    start('src/demo.nim', w=120, h=34); time.sleep(0.5)
    keys('C-b'); time.sleep(0.6)
    palette('Toggle terminal'); time.sleep(1.0)
    s0 = screen()
    tm('kill-server'); time.sleep(0.4)
    start('src', w=120, h=34); time.sleep(1.0)        # (a folder: the tree used to open, with the keys)
    s = screen()
    check('640 a new launch: no dock and no panel open (they were open when ned last quit; a folder given)',
          '▸ examples' in s0 and 'TERMINAL' in s0 and '▸ examples' not in s and 'TERMINAL' not in s, s0 + s)
    keys('d'); time.sleep(0.6)
    s = screen()
    check('640 … the welcome screen\'s d opens a folder, nothing is deleted',
          'Open folder' in s and os.path.exists(W + '/src/demo.nim') and os.path.exists(W + '/src/demo/utils.nim'), s)
    keys('Escape'); time.sleep(0.2)
    palette('About ned'); time.sleep(0.6)
    s = screen()
    keys('Escape'); time.sleep(0.2)
    h = sh(BIN + ' --help').stdout
    check('640 the developer in About ned and ned --help: Sultan Al Isaiee (@foxoman), www.foxoman.net, sultan@foxoman.net',
          'Sultan Al Isaiee (@foxoman)' in s and 'www.foxoman.net' in s and 'sultan@foxoman.net' in s and
          'By Sultan Al Isaiee (@foxoman) — www.foxoman.net · sultan@foxoman.net' in h, s + h[:300])
    tm('kill-server'); time.sleep(0.4)
    setup({"nim.nimsuggest": False, "ui.restorePanels": True})
    start('src/demo.nim', w=120, h=34); time.sleep(0.5)
    keys('C-b'); time.sleep(0.6)
    tm('kill-server'); time.sleep(0.4)
    start(w=120, h=34); time.sleep(1.0)
    check('640 ui.restorePanels: the docks back as they were', '▸ examples' in screen(), screen())

def t_641_vim_ex():
    # 6.41: vim's : line — every setting by its key, only its last part, or Vim's name; :set key? and wrong values;
    # :colorscheme; Tab completing; the line commands :sort :g :m :t :d; ned's commands by the start of their name
    setup({"editor.vimMode": True, "editor.keymap": "vim"})
    open(W + '/v.txt', 'w').write('pear\napple\nbanana\napple\ncherry\n')
    start('v.txt', w=120, h=30)
    def cfg(): return open(CFG + '/ned/config.json').read()
    def ex(t, wait=0.6):
        text(':' + t); keys('Enter'); time.sleep(wait)
    ex('set editor.tabSize=2 nowrap')
    check('641 vim: :set key=value and Vim\'s nowrap, kept in the settings',
          re.search(r'"editor.tabSize":\s*2', cfg()) and re.search(r'"editor.softWrap":\s*false', cfg()), cfg())
    ex('set tabSize?')
    check('641 vim: :set name? shows it (only the last part of the key typed)', 'editor.tabSize=2' in screen(), screen())
    ex('set editor.tabSize=lots')
    check('641 vim: a value the setting does not take is refused, saying what it takes',
          'is a whole number' in screen() and re.search(r'"editor.tabSize":\s*2', cfg()), screen())
    text(':set editor.tabSi'); keys('Tab'); time.sleep(0.3); text('=3'); keys('Enter'); time.sleep(0.6)
    check('641 vim: Tab completes a setting\'s name', re.search(r'"editor.tabSize":\s*3', cfg()), cfg())
    ex('colorscheme ray-candy-dark')
    check('641 vim: :colorscheme', re.search(r'"theme":\s*"ray-candy-dark"', cfg()), cfg())
    ex('sort u'); ex('g/an/d'); ex('1m$'); ex('1t0'); ex('2,3d'); ex('w')
    check('641 vim: :sort u, :g/text/d, :1m$, :1t0, :2,3d', ftext('v.txt') == 'cherry\napple\n', repr(ftext('v.txt')))
    ex('about')
    check('641 vim: one of ned\'s commands by the start of its name (:about → About ned)', wait_for('Made by', 3),
          screen())
    keys('Enter'); time.sleep(0.3)
    ex('help')
    check('641 vim: :help — what the : line takes, in a tab', wait_for('The : command line', 3), screen())

def t_641_update_check():
    # 6.41: a newer ned on GitHub (here a file in its place) — said a little after start, a mark in the status bar,
    # its notes on a tap; Help: skip this update stops it
    rel = TMP + '/release-641.json'
    json.dump({"tag_name": "v99.2.0", "body": "## What's new\n\nEverything is faster.",
               "html_url": "https://github.com/foxoman/ned/releases/tag/v99.2.0"}, open(rel, 'w'))
    setup()
    start('src/demo.nim', w=140, h=34, env_extra='NED_UPDATE_URL=' + rel)
    check('641 update: a little after start, a note that a newer ned is out', wait_for('ned 99.2.0 is out', 30),
          screen())
    check('641 update: the mark in the status bar', 'ned 99.2.0 ' in screen().splitlines()[-1], screen()[-300:])
    palette("Help: what's new in the newest ned"); time.sleep(0.6)
    check('641 update: its notes, and how to update', 'Everything is faster.' in screen() and 'Update ned' in screen(),
          screen())
    palette('Help: skip this update'); time.sleep(0.6)
    check('641 update: skipped — the mark goes', 'ned 99.2.0 ' not in screen().splitlines()[-1], screen()[-300:])
    st = json.load(open(STATE + '/ned/update.json'))
    check('641 update: what was found kept for the next start', st.get('latest') == '99.2.0' and
          st.get('skipped') == '99.2.0', str(st))


def t_641_from_zed():
    # 6.41, from Zed's own changelog: a jump into a folded part opens it; the selection put in the find box is found
    # as it is written when the find is by regular expression; vim's :set gdefault
    setup()
    open(W + '/z.nim', 'w').write('proc a() =\n  let x = 1\n  let y = 2\n  echo x\n\nlet q = "a.b"\nlet s = "axb a.b"\n')
    start('z.nim', w=110, h=26)
    palette('Fold'); time.sleep(0.4)
    check('641 zed: folded', '⋯' in screen() and 'echo x' not in screen(), screen())   # (echo x: no type hint in it)
    keys('C-g'); text('3'); keys('Enter'); time.sleep(0.4)
    check('641 zed: a jump into a folded part opens it', 'echo x' in screen(), screen())
    keys('C-f'); time.sleep(0.3); keys('M-r'); time.sleep(0.2); keys('Escape'); time.sleep(0.2)   # (find by regex)
    keys('C-g'); text('6:10'); keys('Enter'); keys('S-Right', 'S-Right', 'S-Right'); time.sleep(0.2)
    keys('C-f'); time.sleep(0.5)
    check('641 zed: the selection in the find box as it is written, also by regex', 'a\\.b' in screen(), screen())
    keys('Escape')
    setup({"editor.vimMode": True, "editor.keymap": "vim"})
    open(W + '/g.txt', 'w').write('a a a\nb b b\n')
    start('g.txt', w=100, h=24)
    for t in [':set gdefault', ':s/a/x/', ':2s/b/y/g', ':w']:
        text(t); keys('Enter'); time.sleep(0.4)
    check('641 zed: vim :set gdefault — :s replaces every one, with g only the first',
          ftext('g.txt') == 'x x x\ny b b\n', repr(ftext('g.txt')))

EMIT6411 = """{.emit: \"\"\"
typedef struct { int count; double sum; } Tally;
struct Pt { int x, y; };

static int add_ints(int a, int b) {
  Tally t = {0, 0.0};
  struct Pt *p = 0;
  
  return t.count;
}
\"\"\".}
"""

def t_6411_emit_members():
    # 6.41.1: C in an {.emit} (the C backend) with no clangd: a struct's members after `.` and `->` from ned's own C
    # engine, as in a .c file; the hover of a member
    setup({"nim.emitClangd": False})
    open(W + '/src/em6411.nim', 'w').write(EMIT6411)
    start('src/em6411.nim', w=110, h=26); time.sleep(1)
    keys('C-g'); text('8'); keys('Enter'); keys('End'); text('t.'); time.sleep(1.0)
    s = screen()
    check("6411 emit C: a typedef'd struct's members after .", re.search(r'count\s+int', s) and re.search(r'sum\s+double', s), s)
    keys('Escape', 'BSpace', 'BSpace'); text('p->'); time.sleep(1.0)
    s = screen()
    check('6411 emit C: a struct pointer\'s members after ->', re.search(r'\bx\s+int', s) and re.search(r'\by\s+int', s), s)
    keys('Escape', 'BSpace', 'BSpace', 'BSpace')
    keys('C-g'); text('9:13'); keys('Enter'); keys('M-h'); time.sleep(0.8)
    check('6411 emit C: the hover of a member', re.search(r'int count', screen()), screen())

def t_6411_picker_exact():
    # 6.41.1: Ctrl+P with a file's whole name puts that file first: src/demo.nim before demo.nimble
    setup(); start('src/demo/utils.nim')
    keys('C-p'); text('demo.nim'); time.sleep(0.6); keys('Enter'); time.sleep(0.8)
    check('6411 Ctrl+P: the file named as typed comes first (demo.nim, not demo.nimble)',
          'when isMainModule' in screen() and 'demo.nimble' not in screen(), screen())

def t_642_your_keys():
    # 6.42: your own keys in vim mode (vim.keys, vim.visualKeys) and Helix mode (helix.keys) — a command of the
    # palette or a : line, a count repeating it, keys that turn out not to be yours given back; vim.escapeSequence in
    # insert mode while the completion list is open, and in Helix's insert mode; Next tab in the palette
    setup({"editor.vimMode": True, "editor.keymap": "vim", "vim.escapeSequence": "jj",
           "vim.keys": {"<leader>n": "Next tab", "<leader>p": "Previous tab", "<leader>x": "Close tab",
                        "<leader>w": ":w"},
           "vim.visualKeys": {"<leader>s": "Sort lines"}})
    for n, body in [('ka', 'alpha one\n'), ('kb', 'bravo two\n'), ('kc', 'charlie three\n'), ('ks', 'pear\napple\nfig\n')]:
        open(W + '/' + n + '.txt', 'w').write(body)
    open(W + '/kj.nim', 'w').write('let objjar = 1\necho \n')
    start('ka.txt', w=110, h=26)
    for n in ['kb', 'kc']:
        text(':e ' + n + '.txt'); keys('Enter'); time.sleep(0.5)
    text(' n'); time.sleep(0.5)
    check('642 vim.keys: <leader>n runs Next tab (round to the first)',
          'alpha one' in screen() and 'charlie three' not in screen(), screen())
    text('2 n'); time.sleep(0.5)
    check('642 vim.keys: a count before them runs it that many times (2<leader>n: two tabs on)',
          'charlie three' in screen(), screen())
    text(' p'); time.sleep(0.5)
    check('642 vim.keys: <leader>p, Previous tab', 'bravo two' in screen(), screen())
    text('A'); text(' more'); text('jj'); time.sleep(0.3); text(' w'); time.sleep(0.6)
    check('642 vim: jj leaves insert mode (the first j taken out), and <leader>w runs :w',
          ftext('kb.txt') == 'bravo two more\n' and 'NORMAL' in screen().splitlines()[-1],
          repr(ftext('kb.txt')) + '\n' + screen().splitlines()[-1])
    text('0'); text(' l'); text('x'); text(' w'); time.sleep(0.6)
    check('642 vim.keys: keys that are not yours after all go to vim (space, l: two to the right)',
          ftext('kb.txt') == 'brvo two more\n', repr(ftext('kb.txt')))
    text(':e ks.txt'); keys('Enter'); time.sleep(0.5)
    text('Vjj'); time.sleep(0.2); text(' s'); time.sleep(0.4); text(' w'); time.sleep(0.6)
    check('642 vim.visualKeys: <leader>s on the selected lines (Sort lines), back to normal mode',
          ftext('ks.txt') == 'apple\nfig\npear\n' and 'NORMAL' in screen().splitlines()[-1],
          repr(ftext('ks.txt')) + '\n' + screen().splitlines()[-1])
    text(' x'); time.sleep(0.5)
    check('642 vim.keys: <leader>x, Close tab', 'apple' not in screen(), screen())
    text(':e kj.nim'); keys('Enter'); time.sleep(0.8)
    text('jA'); text('ob'); time.sleep(1.2)
    listed = screen().count('objjar') >= 2
    text('jj'); time.sleep(0.4); text(' w'); time.sleep(0.6)
    check('642 vim: jj with the completion list open leaves insert mode too (the list was open: ' + str(listed) + ')',
          ftext('kj.nim') == 'let objjar = 1\necho ob\n' and 'NORMAL' in screen().splitlines()[-1],
          repr(ftext('kj.nim')) + '\n' + screen())
    palette('Next tab'); time.sleep(0.5)
    check('642 the palette: Next tab', 'objjar' not in screen(), screen())
    setup({"editor.keymap": "helix", "vim.escapeSequence": "jj", "helix.keys": {"<space>n": "Next tab", "<space>w": ":w"}})
    for n, body in [('ka', 'alpha one\n'), ('kb', 'brvo two\n')]:
        open(W + '/' + n + '.txt', 'w').write(body)
    start('ka.txt', w=110, h=26)
    text(':e kb.txt'); keys('Enter'); time.sleep(0.5)
    text(' n'); time.sleep(0.5)
    check('642 helix.keys: <space>n runs Next tab', 'alpha one' in screen() and 'brvo' not in screen(), screen())
    text('i'); text('zz'); text('jj'); time.sleep(0.3)
    check('642 helix: jj leaves insert mode', 'NOR' in screen().splitlines()[-1], screen().splitlines()[-1])
    text(' w'); time.sleep(0.6)
    check('642 helix.keys: <space>w runs :w — the text typed without the j\'s',
          ftext('ka.txt') == 'zzalpha one\n', repr(ftext('ka.txt')))
    text(' f'); time.sleep(0.6)
    check('642 helix: space then a key that is not yours: Helix\'s space menu (f opens a file)',
          'Open file' in screen() or 'kb.txt' in screen().split('\n')[3], screen()[:700])
    keys('Escape')

def t_6421_ai_utf8():
    # 6.42.1: what the assistant sends is UTF-8 — a search result cut in the middle of a character, a file in Latin-1
    # (llama.cpp refused the whole request: "ill-formed UTF-8 byte"; the mock's json.loads does the same) — and a tool
    # call's arguments with a literal tab in a string (a local model's) go back as strict JSON
    setup({"ai.autoApprove": "reads", "ai.baseUrl": MOCKURL})
    open(W + '/long.txt', 'w', encoding='utf-8').write('ZQXa ' + '\u00e9' * 120 + '\n')
    open(W + '/latin.txt', 'wb').write(b'ZQX caf\xe9 latin\n')
    start('src/demo.nim', w=130, h=36); time.sleep(1)
    keys('M-c'); time.sleep(0.4); text('search the project for ZQX'); keys('Enter')
    ok = wait_for('Tool said', 30)
    check('6421 ai: the search\'s result goes back and is taken (no "bad json")', ok and 'bad json' not in screen(),
          screen())
    sent = ''
    for l in open(MOCK_LOG, encoding='utf-8', errors='replace').read().splitlines()[-6:]:
        try: sent += json.dumps(json.loads(l), ensure_ascii=False)
        except ValueError: pass
    check('6421 ai: a line cut at 200 bytes between two characters, a Latin-1 byte as \ufffd',
          ('ZQXa ' + '\u00e9' * 97) in sent and 'caf\ufffd latin' in sent and ('\u00e9' * 97 + '\ufffd') not in sent,
          sent[-1500:])
    args = []
    for l in open(MOCK_LOG, encoding='utf-8', errors='replace').read().splitlines()[-6:]:
        try: msgs = json.loads(l)['body'].get('messages', [])
        except (ValueError, KeyError): continue
        args += [(tc.get('function') or {}).get('arguments', '') for x in msgs for tc in x.get('tool_calls') or []]
    def strict(a):
        try: return json.loads(a)
        except ValueError: return None
    check('6421 ai: the call\'s arguments sent back as strict JSON (the tab escaped)',
          any((strict(a) or {}).get('note') == 'a\tb' for a in args), repr(args))

def t_65_vim_oracle():
    # 6.5: ned's vim mode against a real vim (vimoracle, headless and deterministic): the same file, the same place,
    # the same keys — the movements by where the cursor and the mode end up, the edits by the text they left. Vim answers
    # from a cache while its version and the cases are the same; every difference is a failure unless the case is in
    # vimcases.KNOWN_DIFFERS and says who is right (vimdiff.py writes the report of the ones that are).
    import vimoracle, vimcases, nedvim
    o = vimoracle.Oracle()
    o.need()
    asked = [(vimcases.vim_keys(k), l, c) for (k, l, c, _) in vimcases.CASES]
    answers = o.answers(asked, vimcases.FIXTURE, cache=os.path.join(TMP, 'vim-answers.json'))
    n = nedvim.Ned(setup, start, keys, text, screen, tm, W)
    lines = vimcases.read_lines(vimcases.FIXTURE)
    differs, agree, skipped = [], 0, 0
    case_log = os.path.join(TMP, 'vim-cases.log')      # (each case as it goes: a stall is seen at once, not at the end)
    log = open(case_log, 'w', encoding='utf-8')
    try:
        n.start(vimcases.FIXTURE)
        for n_case, ((case, line, col, edit), want) in enumerate(zip(vimcases.CASES, answers), 1):
            if want['err'] or want['pending']:
                skipped += 1                     # (vim itself does not finish the case: nothing to compare)
                continue
            got = n.case(vimcases.keys_of(case), line, col, edit)
            log.write('%d/%d %r %d,%d -> %r vim %r\n' % (n_case, len(vimcases.CASES), case, line, col, got,
                                                          {k: want[k] for k in ('line', 'col')}))
            log.flush()
            # (ned's `Col` is a display column, vim's is a character column: both are compared in vim's, and on the line
            # vim is on — a case that went to another line is measured where it stands, there being no vim column then)
            vline = lines[want['line'] - 1] if want['line'] <= len(lines) else ''
            vcol = (got['col'] or 0) if got['line'] != want['line'] else vimcases.ned_to_vim(vline, got['col'] or 0)
            same_col = vcol == want['col']
            same_text = (not edit) or got['text'] == want['text']
            if same_col and got['line'] == want['line'] and same_text: agree += 1
            else: differs.append((case, line, col, edit, got, want, same_col))
    finally:
        log.close()
        n.stop()
    for case, line, col, edit, got, want, same_col in differs:
        what = []
        if got['line'] != want['line'] or not same_col:
            what.append('cursor ned %s,%s vim %s,%s' % (got['line'], got['col'], want['line'], want['col']))
        if edit and got['text'] != want['text']:
            g, w = got['text'] or [], want['text'] or []
            i = next((k for k in range(max(len(g), len(w))) if k >= len(g) or k >= len(w) or g[k] != w[k]), 0)
            what.append('text line %d ned %r vim %r' % (i + 1, (g[i:i + 1] or ['<none>'])[0],
                                                        (w[i:i + 1] or ['<none>'])[0]))
        check('vim oracle: %r from %d,%d — %s' % (case, line, col, '; '.join(what)),
              case in vimcases.KNOWN_DIFFERS, repr(got) + ' vs ' + repr(want))
    check('vim oracle: %d of %d cases agree with vim (%d vim cannot finish, %d differ as known)' % (
              agree, len(vimcases.CASES) - skipped, skipped,
              len([c for c, *_ in differs if c in vimcases.KNOWN_DIFFERS])),
          agree + len([c for c, *_ in differs if c in vimcases.KNOWN_DIFFERS]) == len(vimcases.CASES) - skipped,
          '%d differ: %r' % (len([c for c, *_ in differs if c not in vimcases.KNOWN_DIFFERS]),
                             [c for c, *_ in differs if c not in vimcases.KNOWN_DIFFERS][:25]))


tests = [t_edit_save_undo, t_find_replace, t_multicursor, t_project_search, t_terminal, t_run_file, t_lsp, t_lsp_diag, t_ai_chat, t_split_zen_theme, t_vim, t_recovery, t_quit_dirty, t_mixed_folder, t_builtin_nimsuggest, t_server_crash_restart, t_engine_member_completion, t_engine_hover_def_sig, t_engine_refs_rename, t_engine_imports, t_engine_without_nimsuggest, t_engine_outline_symbols, t_format_keeps_cursor, t_zen_vim, t_ai_insert, t_format_builtin, t_format_choice, t_reset_settings, t_52_refactors, t_52_format_selection, t_52_conflict, t_52_settings_search, t_52_mouse, t_521_debugger, t_521_touchbar, t_521_bp_follow_edits, t_522_navigation, t_522_peek_hierarchy_stage, t_522_rename_imports, t_522_shortcuts_markdown, t_522_multibuffer, t_522_nim_codegen, t_522_nim_tools, t_53_alerts_and_formatter, t_53_diff_view, t_53_rename_preview, t_53_debugger_watch_test, t_53_user_commands, t_531_help_menus, t_532_polish, t_54_git, t_55_publish, t_56_todos, t_561_review_fixes, t_562_format_cursor, t_563_open_folder, t_564_tiny_screens, t_564_save_safety, t_57_themes, t_57_ai, t_57_nim, t_57_git, t_571_rulers, t_572_editorconfig, t_572_tasks, t_572_errors, t_572_swatches, t_572_examples, t_59_small, t_59_html, t_59_problems_mb, t_59_lsp_more, t_59_langs_tests, t_59_ai_more, t_59_dap, t_510_large, t_510_debug_tools, t_510_testament, t_510_repl, t_510_nimble_outdated, t_510_merge_editor, t_510_spell, t_510_coverage, t_510_langs, t_510_mcp_more, t_510_emmet_css, t_510_sync, t_510_keymaps, t_510_accessible, t_510_workspace, t_510_remote, t_511_stale_errors, t_511_embedded, t_512_c_interop, t_512_refs_big, t_512_comp_stale, t_513_emit_edit, t_513_emit_errors, t_513_emit_c, t_514_emit_clangd, t_515_emit_more, t_515_strings, t_516_quickfixes, t_516_ai_fix, t_517_remote_git, t_517_workspace_git, t_518_macros, t_518_terminal, t_519_refactor, t_519_lists, t_520_agent_check, t_520_ai_tests, t_521_remote, t_521_git, t_521_format_self, t_522_perf, t_523_include, t_523_typehints, t_523_charlit, t_524_debug, t_524_format, t_524_deps, t_525_hints, t_525_engine, t_525_csv, t_525_profile, t_525_macro_nested, t_526_typing_errors, t_527_expand, t_527_complete, t_527_hover, t_528_hierarchy, t_528_refs, t_528_actions, t_529_clangd_fixes, t_529_examples, t_60_includes, t_60_protect, t_61_semantic, t_63_marks, t_63_git, t_63_format, t_63_paste, t_63_cdocs, t_64_engine, t_65_cengine, t_65_ligatures, t_66_cwrap, t_66_zen_menu, t_66_align_hints, t_66_trust, t_66_postfix, t_66_copies, t_66_test_on_save, t_66_ctvalues, t_66_include_check, t_67_github_signin, t_67_git_undo, t_67_commit_checks, t_67_review_comments, t_67_ai_grounded, t_67_ai_fix_test, t_67_format_changed, t_67_format_preview, t_67_yaml_toml, t_67_termux_clock, t_67_rich_colors, t_67_theme_editor, t_67_two_servers, t_67_lsp_links, t_67_ai_plan, t_67_ai_offline, t_68_nedfmt, t_68_engine_checks, t_68_compiler_answers, t_68_macro_names, t_68_settings_panel, t_69_locked_versions, t_69_expected_type, t_69_memory_layout, t_69_raises_hints, t_69_engine_hints, t_69_shared_settings, t_69_toolchain, t_69_lint_and_ci, t_610_expected_multiline, t_610_can_be_func, t_610_concepts, t_610_nim_coverage, t_610_lint_rules, t_610_imports_required, t_610_dep_tree_locked, t_610_project_checks, t_610_fmt_uses, t_611_terminal_scroll, t_611_frames_vt, t_611_perf_report, t_612_hints_ahead, t_612_reflow_comments, t_6112_examples_after_format, t_6112_long_line, t_6112_terminal_flood, t_612_nim3, t_612_nim3_port, t_612_hex, t_612_hex_exe, t_612_big_text, t_613_remote, t_613_terminal_answers, t_613_edit_tools, t_613_vim_filter, t_614_web_css, t_614_web_html, t_614_web_sql, t_614_picker_preview, t_614_jump_labels, t_614_git_new_folder, t_614_format_pieces, t_6141_quick_fix_keys, t_6141_ref_counts, t_6141_showcase, t_615_select_structure, t_615_surround, t_615_vim_surround, t_615_undo_tree, t_615_git_changes, t_615_next_edit, t_615_web_js, t_615_cpp, t_616_engine_worker, t_618_nedls_in_ned, t_619_nimble_resolve, t_619_plugins, t_619_plugins_vim, t_619_plugins_lsp_lang, t_619_hot_exit, t_619_encodings, t_619_key_conflicts, t_620_plugin_language, t_620_plugin_full_nim, t_6241_plugin_check, t_620_ast_docs, t_620_nimble_edit, t_620_emit_names, t_620_viewer, t_620_plugin_list, t_621_emit_format, t_621_reset, t_621_settings_form, t_621_fields, t_621_context_menus, t_621_drag_drop, t_621_atlas, t_621_decompile, t_621_new_project, t_622_settings_controls, t_622_nimscript, t_622_plugin_api, t_622_doc_comments, t_623_decompile_menu, t_623_align_comments, t_623_c_engine, t_623_emit_builtin_c, t_623_nim_rewrites, t_623_call_args, t_624_compiler_explorer, t_624_ce_toolbar, t_6241_dock_view_menu, t_6241_ce_all_procs, t_625_indent, t_625_plugins_menu, t_625_which_key, t_625_oil, t_625_engine_checks,
         t_625_chain_hints, t_625_rename_reach, t_625_completion_recent, t_625_oracle, t_625_c_if, t_625_c_checks,
         t_625_cpp_overloads, t_624_compiler_explorer_c,
         t_626_c_header_macros, t_626_plugin_permissions, t_626_memory_checks, t_626_notebook, t_626_proc_tests,
         t_626_flame, t_626_pictures, t_626_markdown_preview, t_626_settings_sync,
         t_627_256_colours, t_627_json, t_627_web_more, t_627_pnak, t_627_nim3_contracts,
         t_628_plugin_server_after_save, t_628_hastur_tests, t_628_parser_check_fails,
         t_629_move_boxes, t_629_kept_terminals, t_629_remote_servers, t_629_ai_pictures,
         t_629_jinja, t_629_ai_git, t_629_code_from_comments, t_629_plugin_updates, t_629_git_watch,
         t_629_update, t_629_telescope, t_629_cursor_glide, t_629_engine_highlights,
         t_629_click_over_minimap, t_629_indent_plugins, t_630_themes, t_631_tiling, t_631_multibuffer, t_631_plugin_panes, t_631_eof_problem, t_631_zen_tail, t_631_nimble_fields, t_631_multibuffer_safety, t_631_telescope_more,
         t_632_macro_view, t_632_package_installed, t_632_why, t_632_engine_errors, t_632_pane_tabs, t_632_crumbs, t_632_minimap_marks, t_632_touch_context, t_632_battery, t_632_warm_index, t_632_pane_views, t_632_theme_import, t_632_autodedent, t_632_tour, t_632_refactorings, t_6322_emacs_panes, t_6322_close_frees, t_6323_macro_members, t_636_typing_nif, t_636_one_check, t_637_nim3_typing, t_637_check_slots, t_637_low_memory,
         t_635_nim_chip, t_638_nim_panel, t_638_plugin_api_rest, t_639_themes_and_job_event,
         t_640_no_panels_at_start, t_640_undo_kept_bounded, t_641_vim_ex, t_641_update_check, t_641_from_zed,
         t_6411_emit_members, t_6411_picker_exact, t_642_your_keys, t_6421_ai_utf8,
         t_65_vim_oracle]
