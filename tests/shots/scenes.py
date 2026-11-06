#!/usr/bin/env python3
"""scenes.py [NAME …] — take the screenshots of ned's README, guides and blog post again: ned driven in a private tmux
server (the UI tests' harness), the mock AI answering its assistant; each screen kept as screenshots/captures/NAME.ansi
and drawn as screenshots/NAME.png by render.py (in the font NED_SHOT_FONT names: the Coder Nerd Font Mono).

  NED_SHOT_FONT=~/fonts/coder.ttf python3 tests/shots/scenes.py               every scene
  NED_SHOT_FONT=… python3 tests/shots/scenes.py hover-docs debugger           some
  NED_SHOT_FONT=… python3 tests/shots/render.py                               only draw the captures again

ned is ./ned (or NEDBIN); tmux, Nim, gdb (the debugger scene), Playwright with its Chromium and Pillow are needed. The
other screenshots of screenshots/ (each release's) were taken by hand; their captures are kept, so render.py draws
them too. A new scene: a function here that sets up, drives ned and calls snap(NAME), added to SCENES."""
import os, re, sys, time, shutil, subprocess
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
TMP = os.environ.get('NED_SHOT_TMP') or '/tmp/ned-shots-%d' % os.getuid()
os.environ['NED_TEST_TMP'] = TMP
os.environ['NED_TEST_SOCKET'] = 'ned-shots'
os.environ.setdefault('NEDBIN', os.path.join(REPO, 'ned'))
os.environ['NED_UPDATE_URL'] = TMP + '/no-release.json'          # (no look at GitHub for a newer ned)
os.environ['NED_TEST_AI_PORT'] = os.environ.get('NED_SHOT_AI_PORT', '8799')
os.environ['NED_TEST_MOCK_LOG'] = TMP + '/mock.log'
os.makedirs(TMP, exist_ok=True)
sys.path.insert(0, os.path.join(REPO, 'tests', 'ui')); sys.path.insert(0, HERE)
from harness import *
import render

BASE = {"ui.icons": "nerd", "nim.nimsuggest": None, "editor.stickyScroll": False}
SHAPES = '''import std/[tables, json, options]

type
  Color* = enum red, green, blue
  Shape* = object of RootObj
    name*: string      ## what it is called
    color*: Color
  Circle* = object of Shape
    radius*: float     ## from the centre, in metres

proc area*(c: Circle): float =
  ## The area of a circle.
  runnableExamples:
    assert Circle(radius: 1).area > 3
  3.14159 * c.radius * c.radius

proc newCircle*(r: float, name = "c"): Circle =
  ## A circle of radius `r`.
  Circle(radius: r, name: name)

proc main() =
  let c = newCircle(2.0)
  var t = initTable[string, int]()
  var counts: Table[string, seq[int]]
  let xs = @[1, 2, 3]
  let j = parseJson("{}")
  let o = some(5)
  for k, v in t.pairs:
    echo k, v
  echo j.len, o.get, xs.len, counts.len
  echo c.radius

main()
'''
SAMPLE = '''## A little sample, in every theme
import std/[strutils, tables]

type
  Shape* = object
    name: string
    sides: int

const Greeting = "salaam"   # a comment

proc area*(s: Shape, size = 2.5): float =
  ## the area of a regular shape
  result = size * size * float(s.sides) / 4
  var seen = initTable[string, int]()
  for i in 0 ..< s.sides:
    seen[s.name.toUpperAscii] = i

echo Greeting, Shape(name: "hex", sides: 6).area
'''
DBG = '''type Person = object
  name: string
  age: int

proc total(people: seq[Person]): int =
  for p in people:
    result += p.age

proc main() =
  let people = @[Person(name: "Ann", age: 30), Person(name: "Bo", age: 4)]
  let first = people[0]
  var sum = total(people)
  echo sum, " ", first.name

main()
'''
_shooter = None

def capture():
    """the screen, with its colours and every row whole, as tmux has it"""
    return tm('capture-pane', '-t', 'f', '-e', '-N', '-p').stdout

def keep(path, text):
    """a capture written to screenshots/captures"""
    open(path, 'w', encoding='utf-8').write(text)

def snap(name):
    """the screen as screenshots/captures/NAME.ansi, drawn as screenshots/NAME.png"""
    keep(os.path.join(render.CAPTURES, name + '.ansi'), capture())
    print('  ', render.draw(_shooter, name), flush=True)

def snap_tiles(name, items):
    """several screens (label, capture) kept as NAME@NN-label.ansi and drawn side by side as screenshots/NAME.png"""
    for old in [p for p in os.listdir(render.CAPTURES) if p.startswith(name + '@')]:
        os.remove(os.path.join(render.CAPTURES, old))
    for k, (label, a) in enumerate(items, 1):
        keep(os.path.join(render.CAPTURES, '%s@%02d-%s.ansi' % (name, k, label)), a)
    print('  ', render.draw(_shooter, name), flush=True)

def click(x, y):
    """a mouse click at column x, row y (from 1)"""
    tm('send-keys', '-t', 'f', '-l', '\x1b[<0;%d;%dM' % (x, y)); time.sleep(0.05)
    tm('send-keys', '-t', 'f', '-l', '\x1b[<0;%d;%dm' % (x, y)); time.sleep(0.3)

def find_on_screen(word):
    """where WORD is on the screen (column, row from 1), or None"""
    for i, l in enumerate(screen().split('\n')):
        k = l.find(word)
        if k >= 0: return (k + 2, i + 1)

def go(spec):
    """the cursor to a line (or line:column), with Ctrl+G"""
    keys('C-g'); text(str(spec)); keys('Enter'); time.sleep(0.5)

def shapes(theme, extra=None, w=112, h=30):
    """a fresh project with src/shapes.nim open in THEME"""
    setup(dict(BASE, theme=theme, **(extra or {})))
    open(W + '/src/shapes.nim', 'w').write(SHAPES)
    start('src/shapes.nim', w=w, h=h); time.sleep(2.5)

def showcase(theme, w, h, extra=None):
    """a fresh project with examples/showcase.nim open as src/showcase.nim in THEME"""
    setup(dict(BASE, theme=theme, **(extra or {})))
    shutil.copy(os.path.join(REPO, 'examples', 'showcase.nim'), W + '/src/showcase.nim')
    start('src/showcase.nim', w=w, h=h); time.sleep(2.5)

def complete_c():
    """member completion after `c.`, the third item (a field with its documentation) chosen"""
    go(31); keys('End', 'Enter'); text('echo c.'); wait_for(r'radius\s+float', 8); time.sleep(0.6)
    keys('Down', 'Down'); time.sleep(1.0)

def hover_new():
    """the hover of newCircle"""
    go('22:12'); keys('M-h'); wait_for('radius of', 8); time.sleep(0.8)

# ── the README's and the guides' ──────────────────────────────────────────────────────────────────────────────────

def completion_docs():
    """completion with the documentation beside the list (nim-crown)"""
    shapes('nim-crown'); complete_c(); snap('completion-docs')

def hover_docs():
    """the hover of a standard library proc: signature, documentation, where it is"""
    shapes('kanagawa'); go('26:13'); keys('M-h'); wait_for('JsonNode', 8); time.sleep(1.0); snap('hover-docs')

def split_panes():
    """two panes, each with its own header"""
    shapes('catppuccin-mocha', w=130, h=26)
    go(11); keys('M-\\'); time.sleep(0.8)
    keys('C-p'); text('src/demo.nim'); time.sleep(0.6); keys('Enter'); time.sleep(1.2)
    go(7); time.sleep(6)                                    # (the split's note goes)
    snap('split-panes')

def nimble_ai():
    """the Files dock and the assistant explaining the file"""
    setup(dict(BASE, theme='one-dark'))
    start('src/demo.nim', w=140, h=34); time.sleep(2)
    keys('C-b'); time.sleep(0.6)
    keys('M-c'); time.sleep(0.5); text('Explain this file'); keys('Enter')
    wait_for('package entry point', 15); time.sleep(1.5)
    snap('nimble-ai')

def split_and_replace():
    """a project-wide replace previewed in the Search dock, the editor split in two"""
    setup(dict(BASE, theme='gruvbox-dark'))
    start('src/demo.nim', w=150, h=34); time.sleep(2)
    keys('M-\\'); time.sleep(0.6); keys('C-p'); text('test_demo'); time.sleep(0.6); keys('Enter'); time.sleep(7)
    keys('M-s'); time.sleep(0.4); keys('C-u'); text('greet'); keys('Enter'); wait_for(r'test_demo\.nim', 8)
    keys('M-h'); time.sleep(0.4); text('welcome'); time.sleep(1.5)
    snap('split-and-replace')

def ai_diff_approval():
    """the Nim dock, and the assistant's edit waiting for approval as a diff"""
    setup(dict(BASE, theme='rose-pine'))
    start('src/demo.nim', w=140, h=34); time.sleep(2)
    palette('Nim panel (project, tools, toolchain)'); time.sleep(1)
    keys('M-c'); time.sleep(0.5); text('add a doc comment to shout'); keys('Enter')
    wait_for('Allow', 20); time.sleep(1.5)
    snap('ai-diff-approval')

def debugger():
    """stopped at a breakpoint: a seq opened into its items, a watch, the call stack (gdb)"""
    setup(dict(BASE, theme='tokyo-night'))
    open(W + '/src/dbg.nim', 'w').write(DBG)
    start('src/dbg.nim', w=120, h=44); time.sleep(2)
    go(13); keys('F9'); keys('F5')
    wait_for(r'stopped .*at dbg\.nim:13', 90); wait_for('sum', 15); time.sleep(1.5)
    palette('Debug: add a watch'); keys('C-u'); text('sum * 2'); keys('Enter'); time.sleep(1.5)
    at = find_on_screen('▸ people: seq')
    if at: click(at[0], at[1]); time.sleep(1.5)
    if '[0]' not in screen(): keys('Enter'); time.sleep(1.5)
    snap('debugger')

def desktop_62():
    """a dialog (unsaved changes) over the Git dock"""
    setup(dict(BASE, theme='nebula-nova'))
    start('src/demo.nim', w=112, h=30); time.sleep(2)
    go(9); keys('End'); text('  # changed'); time.sleep(0.3)
    palette('Git panel'); time.sleep(1.2)
    keys('C-q'); time.sleep(1.0)
    snap('desktop-62')

def diff_view():
    """the side-by-side diff against the last commit"""
    setup(dict(BASE, theme='github-dark'))
    t0 = open(W + '/src/demo.nim').read()
    open(W + '/src/demo.nim', 'w').write(t0.replace('"Hello, "', '"Hi there, "') +
                                          '\nproc farewell*(who: string): string =\n  "Goodbye, " & who\n')
    start('src/demo.nim', w=120, h=24); time.sleep(2)
    palette('Git: compare with last commit'); time.sleep(1.5)
    snap('diff-view')

def todos():
    """TODO, FIXME, BUG, HACK and NOTE in the code, and the TODOs dock"""
    setup(dict(BASE, theme='nim-crown'))
    subprocess.run([sys.executable, os.path.join(REPO, 'tests', 'ui', 'fixtures', 'todos_mk.py'), W], check=True)
    start('src/app.nim', w=130, h=30); time.sleep(2)
    palette('TODOs panel'); time.sleep(1.5)
    snap('todos')

def tiles(name, specs, w=84, h=22):
    """several themes side by side, each named: specs = [(theme, what to do in it)]"""
    items = []
    for th, act in specs:
        shapes(th, {"ui.minimap": "off"}, w=w, h=h)
        act(); items.append((th, capture())); tm('kill-server')
    snap_tiles(name, items)

def everforest_nightowl():
    """everforest and night owl, dark and light, each with a hover"""
    tiles('everforest-nightowl', [(t, hover_new) for t in ['everforest-dark', 'everforest-light', 'night-owl',
                                                          'light-owl']])

def monochrome():
    """the grey themes: dark with completion, light with a hover"""
    tiles('monochrome', [('monochrome', complete_c), ('monochrome-light', hover_new)])

# ── the blog post's (docs/blog) ─────────────────────────────────────────────────────────────────────────────────

def hero_641():
    """showcase.nim with the Files dock: the engine's hints, references and checks (nim-crown)"""
    showcase('nim-crown', 170, 44, {"editor.stickyScroll": True})
    keys('C-b'); time.sleep(0.8); go(124); time.sleep(3); keys('Escape'); time.sleep(1.5)
    snap('hero-641')

def completion_641():
    """member completion in the demo project (tokyo-night)"""
    setup(dict(BASE, theme='tokyo-night'))
    start('src/demo.nim', w=120, h=26); time.sleep(2)
    go(9); keys('End'); keys('Enter'); text('echo p.')
    wait_for(r'age\s+Natural', 5); time.sleep(0.8)
    snap('completion-641')

def vim_641():
    """vim mode's : line completing a setting's name (mint-night)"""
    showcase('mint-night', 120, 28, {"editor.vimMode": True, "editor.stickyScroll": True})
    go(124); time.sleep(1.5)
    text(':'); time.sleep(0.2); text('set editor.ta'); keys('Tab'); time.sleep(0.6)
    snap('vim-641')
    keys('Escape')

def phone_641():
    """the phone layout, 52 columns, with the touch bar (nim-crown)"""
    showcase('nim-crown', 52, 44, {"ui.touchBar": "auto", "editor.stickyScroll": True})
    go(126); time.sleep(1.5)
    snap('phone-641')

def terminal_641():
    """the terminal panel running git and the compiler (ray-candy-dark)"""
    setup(dict(BASE, theme='ray-candy-dark', **{"terminal.shell": "/bin/bash"}))
    home = TMP + '/home'; os.makedirs(home, exist_ok=True)
    open(home + '/.bashrc', 'w').write("PS1='\\[\\e[32m\\]~/work\\[\\e[0m\\] $ '\n")   # (a short prompt)
    start('src/demo.nim', w=140, h=36, env_extra='HOME=' + home); time.sleep(2)
    keys('C-\\'); time.sleep(1.5)
    text('git log --oneline -3 && nim c -r --hints:off src/demo.nim'); keys('Enter')
    wait_for('Hello, Ann!', 90); time.sleep(0.8)
    snap('terminal-641')

def themes_641():
    """one sample file in six themes, side by side"""
    items = []
    for th in ["nim-crown", "mint-night", "ray-candy-dark", "ray-vercel-light", "flexoki-dark", "sunlight"]:
        setup(dict(BASE, theme=th, **{"ui.minimap": "off", "editor.inlayHints": False}))
        open(W + '/sample.nim', 'w').write(SAMPLE)
        start('sample.nim', w=74, h=23); time.sleep(2)
        keys('C-Home'); keys('Down', 'Down'); keys('End'); time.sleep(0.6)
        items.append((th, capture())); tm('kill-server')
    snap_tiles('themes-641', items)

def nim_layout_641():
    """the hover of an object: each field's offset, size and padding, and the order that saves bytes"""
    showcase('tokyo-night', 130, 34)
    go('35:4'); keys('M-h'); wait_for('padding', 15); time.sleep(1.0)
    snap('nim-layout-641')

def nim_macro_641():
    """a macro call (makeGetters) and what it made, at once (Alt+M)"""
    showcase('kanagawa', 130, 34, {"editor.autoHover": False})
    go('96:3'); time.sleep(1.0); keys('M-m'); wait_for('getTitle', 60); time.sleep(1.5)
    snap('nim-macro-641')

def nim_fixes_641():
    """the quick fixes of a `var` that is never changed (Alt+Enter)"""
    showcase('nim-crown', 130, 34)
    go('123:7'); time.sleep(1.5); keys('M-Enter'); wait_for('let', 10); time.sleep(1.0)
    snap('nim-fixes-641')

def emit_c_641():
    """C in a {.emit}: a struct's members completed, as in a C file (by clangd: it must be on PATH)"""
    if not shutil.which('clangd'):
        print('   emit-c-641 left out: it shows clangd answering, and clangd is not on PATH'); return
    showcase('catppuccin-mocha', 130, 34)
    go(197); keys('End', 'Enter'); text('t.'); time.sleep(1.5)
    if not re.search(r'count\s+int', screen()): keys('C-Space')
    wait_for(r'count\s+int', 15); time.sleep(1.0)
    snap('emit-c-641')

def strings_641():
    """SQL in a Nim string: the columns of the table the schema string creates, completed"""
    showcase('one-dark', 130, 34)
    go('220:26'); time.sleep(1.0); keys('C-Space'); wait_for(r'sides', 15); time.sleep(1.0)
    snap('strings-641')

SCENES = {'completion-docs': completion_docs, 'hover-docs': hover_docs, 'split-panes': split_panes,
          'nimble-ai': nimble_ai, 'split-and-replace': split_and_replace, 'ai-diff-approval': ai_diff_approval,
          'debugger': debugger, 'desktop-62': desktop_62, 'diff-view': diff_view, 'todos': todos,
          'everforest-nightowl': everforest_nightowl, 'monochrome': monochrome, 'hero-641': hero_641,
          'completion-641': completion_641, 'vim-641': vim_641, 'phone-641': phone_641, 'terminal-641': terminal_641,
          'themes-641': themes_641, 'nim-layout-641': nim_layout_641, 'nim-macro-641': nim_macro_641,
          'nim-fixes-641': nim_fixes_641, 'emit-c-641': emit_c_641, 'strings-641': strings_641}

if __name__ == '__main__':
    todo = sys.argv[1:] or list(SCENES)
    bad = [n for n in todo if n not in SCENES]
    if bad: sys.exit('scenes.py: no scene ' + ', '.join(bad) + ' (the scenes: ' + ', '.join(SCENES) + ')')
    render.css()                                            # (says now when NED_SHOT_FONT is missing)
    mock = subprocess.Popen([sys.executable, '-I', os.path.join(REPO, 'tests', 'ui', 'mocks', 'mockai.py'),
                             os.environ['NED_TEST_AI_PORT']], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.8)
    try:
        with render.Shooter() as _shooter:
            for n in todo:
                print(n, flush=True); SCENES[n](); tm('kill-server')
    finally:
        mock.terminate(); tm('kill-server')
