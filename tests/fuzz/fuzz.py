#!/usr/bin/env python3
"""Random-input fuzzer for ned: runs it in a private tmux server and throws keys, mouse events, pastes,
palette commands and resizes at it. Reports crashes (non-zero exit), hangs and logged internal errors.

  NEDBIN=./ned_debug python3 tests/fuzz/fuzz.py [SEED [SECONDS [MODE]]]
  MODE: mixed · vim · helix · emacs · palette · refactor · ai · git · fixes · c · emit · strings · ws · term · a11y …

It works in a scratch home of its own (NED_FUZZ_HOME, default /tmp/ned-fuzz-UID): ned's settings, state and
a copy of the test project live there. Random palette commands can run tasks, git and shell commands in that
project, so give it a throwaway user if you can: NED_FUZZ_USER=fuzz runs ned as that user (with su).
A build with stack traces says where an error happened: nim c -d:release --stackTrace:on --lineTrace:on."""
import os, random, re, subprocess, sys, time, shutil, json

SEED = int(sys.argv[1]) if len(sys.argv) > 1 else int(time.time())
DUR = float(sys.argv[2]) if len(sys.argv) > 2 else 120
MODE = sys.argv[3] if len(sys.argv) > 3 else 'mixed'
rnd = random.Random(SEED)
HOME = os.environ.get('NED_FUZZ_HOME', '/tmp/ned-fuzz-%d' % os.getuid())
USER = os.environ.get('NED_FUZZ_USER', '')
TESTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIX = TESTS + '/ui/fixtures'
REPO = os.path.dirname(TESTS)
SRC_BIN = os.path.abspath(os.environ.get('NEDBIN', REPO + '/ned'))
PROJ = HOME + '/proj'
BIN = HOME + '/ned_fuzz'
SOCK = 'fz'
OUT = os.environ.get('NED_FUZZ_OUT', HOME + '-logs')
if os.getuid() == 0 and not USER and os.environ.get('NED_FUZZ_ALLOW_ROOT') != '1':
    # as root, ned under random keys can save over any file it can reach (a system header it went to the
    # definition of, a file "saved as" anywhere): run it as a throwaway user
    sys.exit('fuzz.py: running as root — set NED_FUZZ_USER to a throwaway user (ned runs as that user), or run '
             'as an ordinary user; NED_FUZZ_ALLOW_ROOT=1 if this machine is disposable')
os.makedirs(OUT, exist_ok=True)
LOG = OUT + '/run_%d.log' % SEED

def sh(cmd, check=False):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True)

def tm(args):
    cmd = 'tmux -L %s %s' % (SOCK, args)
    return subprocess.run(['su', USER, '-c', cmd] if USER else ['bash', '-c', cmd], capture_output=True, text=True)

def own(path):
    if USER: sh('chown -R %s:%s %s' % (USER, USER, path))

def nim_copy():
    """a copy of the Nim toolchain for ned to use: random keys can go to a definition in the standard library,
    allow editing it and save it — the copy takes that, not the Nim you build with (made again for each run)"""
    nim = shutil.which('nim')
    if not nim: return ''
    real = os.path.realpath(nim)
    top = os.path.dirname(os.path.dirname(real))
    dst = HOME + '/nim'
    shutil.rmtree(dst, ignore_errors=True)
    os.makedirs(dst + '/bin')
    for x in ('nim', 'nimsuggest', 'nimble'):
        p = os.path.join(os.path.dirname(real), x)
        if os.path.exists(p): shutil.copy2(os.path.realpath(p), dst + '/bin/' + x)
    for d in ('lib', 'config'):
        if os.path.isdir(top + '/' + d): shutil.copytree(top + '/' + d, dst + '/' + d, symlinks=True)
    return dst + '/bin'

NIM_BIN = ''

def setup():
    global NIM_BIN
    sh('tmux -L %s kill-server 2>/dev/null' % SOCK)
    sh('pkill -9 -f ' + BIN); time.sleep(0.5)
    shutil.rmtree(PROJ, ignore_errors=True)
    shutil.copytree(FIX + '/demo', PROJ)
    sh('cd %s && git init -q -b master && git add -A && git -c user.name=t -c user.email=t@t commit -qm init' % PROJ)
    shutil.copy(FIX + '/mac/m.nim', PROJ + '/m.nim')
    with open(PROJ + '/uni.txt', 'w') as f:
        f.write('tab\there\nemoji 😀👍🏽 done\n日本語のテキスト\ncombining e\u0301 a\u0308\r\nCRLF line\r\n' + 'x' * 3000 + '\n\n\tindent\n')
    with open(PROJ + '/py.py', 'w') as f:
        f.write('def f(x):\n    return x * 2\n\nclass A:\n    pass\n')
    with open(PROJ + '/README.md', 'w') as f:
        f.write('# Title\n\nSome *text* with `code`.\n\n```nim\necho 1\n```\n- item\n- item2\n')
    with open(PROJ + '/big.nim', 'w') as f:
        for i in range(30000): f.write('proc p%d*(x: int): int = x + %d  # line\n' % (i, i))
    open(PROJ + '/empty.nim', 'w').close()
    for x in ('web.nim', 'page.nimf', 'notes.md'): shutil.copy(FIX + '/emb/' + x, PROJ + '/' + x)
    for x in ('wrap.nim', 'mathx.h', 'mathx.c'): shutil.copy(FIX + '/cwrap/' + x, PROJ + '/' + x)
    shutil.copy(FIX + '/emitc/words.nim', PROJ + '/words.nim')
    # a workspace of two repositories, both with changes (mode "ws")
    if MODE == 'ws':
        lib = HOME + '/lib2'
        shutil.rmtree(lib, ignore_errors=True); os.makedirs(lib + '/src')
        open(lib + '/src/lib2.nim', 'w').write('proc libProc*(): int = 1\n')
        sh('git init -q -b trunk %s && git -C %s -c user.name=f -c user.email=f@f add -A && '
           'git -C %s -c user.name=f -c user.email=f@f commit -qm base' % (lib, lib, lib))
        open(lib + '/src/lib2.nim', 'a').write('proc more*(): int = 2\n')
        open(lib + '/new.txt', 'w').write('untracked\n')
        open(PROJ + '/src/demo.nim', 'a').write('# changed\n')
        json.dump({"folders": [{"path": PROJ}, {"path": lib}]}, open(PROJ + '/both.ned-workspace', 'w'))
    # history to bisect and look through (mode "git")
    if MODE == 'git':
        G = 'git -C %s -c user.name=f -c user.email=f@f ' % PROJ
        for i in range(1, 7):
            open(PROJ + '/bug.txt', 'w').write(('broken' if i >= 4 else 'fine') + ' %d\n' % i)
            open(PROJ + '/src/demo/utils.nim', 'a').write('# change %d\n' % i)
            sh(G + 'add -A && ' + G + 'commit -qm c%d' % i)
    # procs to refactor, called in every way (mode "refactor")
    if MODE == 'refactor':
        open(PROJ + '/src/demo/utils.nim', 'a').write('\nproc scale*(x: int, factor = 2): int = x * factor\n'
            'proc helper(x: int): int = x + 1\nproc bump*(x: int): int = helper(x)\n'
            'proc multi*(a: int,\n            b = "s"): string =\n  result = $a & b\n'
            'type Box* = object\n  v*: int\nproc lonely*(): int = 1\n')
        open(PROJ + '/src/demo.nim', 'a').write('  let n = 5\n  echo scale(3)\n  echo n.scale(factor = 3)\n  let s = scale(x = 1)\n'
            '  echo s, twice(4), n.twice, bump(1), multi(1), 2.multi(b = "x"), Box(v: 1)\n  echo scale 4\n'
            '  echo scale(\n    5,\n    6)\n')
    # Nim code with compiler errors of every kind the quick fixes know (mode "fixes")
    open(PROJ + '/other.nim', 'w').write('proc secret*(x: int): int = x\nproc hidden(x: int): int = x + 1\nvar counter* = 1\n')
    open(PROJ + '/other2.nim', 'w').write('var counter* = 2\n')
    open(PROJ + '/qf.nim', 'w').write("""import std/[strutils, sequtils]
import other, other2

type Color = enum red, green, blue
type P = object
  name: string
  age: int

proc twice(x: int): int = x * 2
proc area(w, h: float): float = w * h
proc old(x: int): int {.deprecated: "use twice instead".} = x * 2
proc risky() {.raises: [].} =
  discard parseInt("1")

let k = 3
k = 4
twice(2)
let i = 5
echo area(i, 3.0)
let n: int = "7"
echo twce(2)
echo hidden(1)
echo undefinedProc(1, "a")
let p = P(name: "a", age: 1)
echo p.nmae
let c = red
case c
of red: echo 1
let msg = "n=" & i
echo counter
echo old(1)
try:
  discard
except:
  discard
proc total(xs: seq[int]): int =
  let sum = 0
  for x in xs:
    sum += x
  sum
""")
    # C for ned's own engine, with ligatures drawn (mode "c")
    open(PROJ + '/cmain.c', 'w').write(C_MAIN)
    os.makedirs(HOME + '/.config/ned', exist_ok=True)
    cfg = {"terminal.shell": "/bin/cat", "ai.provider": "custom", "ai.baseUrl": "http://127.0.0.1:8765/v1",
           "ai.model": "gpt-6", "ai.apiKey": "x"}
    if MODE == 'vim': cfg["editor.vimMode"] = True
    if MODE == 'c': cfg.update({"c.engine": "builtin", "editor.fontLigatures": rnd.choice(["symbols", "font"])})
    if MODE == 'term': cfg["terminal.shell"] = "/bin/bash"
    if MODE == 'ai': cfg["ai.autoApprove"] = rnd.choice(["edits", "reads", "all"])
    if MODE == 'nimsuggest': cfg["nim.ide"] = "nimsuggest"
    if MODE == 'nls': cfg["nim.ide"] = "nimlangserver"
    if MODE in ('helix', 'emacs'): cfg["editor.keymap"] = MODE
    if MODE == 'a11y':
        cfg.update({"ui.accessible": True, "editor.largeFileSize": 200000, "editor.longLineLimit": 1000,
                    "editor.spellCheck": "on", "editor.spellDictionary": os.environ.get('NED_TEST_DICT', '/usr/share/hunspell/en_US.dic')})
    json.dump(cfg, open(HOME + '/.config/ned/config.json', 'w'))
    NIM_BIN = nim_copy()
    shutil.copy(SRC_BIN, BIN)
    sh('rm -f %s/.local/state/ned/errors.log %s/exitcode' % (HOME, HOME))
    own(HOME)

def start():
    sh('rm -f %s/exitcode' % HOME)
    w, h = rnd.choice([(120, 40), (80, 24), (60, 20), (160, 50), (45, 30)])
    script = HOME + '/run.sh'
    with open(script, 'w') as f:
        f.write(('#!/bin/bash\nexport HOME=%s PATH=' + (NIM_BIN + ':' if NIM_BIN else '') + os.environ.get('PATH', '/usr/bin:/bin') + ' TERM=xterm-256color COLORTERM=truecolor\n'
                 'cd %s\n' + os.environ.get('FZPRE', '') + '%s ' + ('words.nim m.nim wrap.nim' if MODE == 'emit' else 'web.nim words.nim notes.md' if MODE == 'strings' else 'qf.nim m.nim' if MODE == 'fixes' else 'cmain.c mathx.h mathx.c' if MODE == 'c' else 'src/demo/utils.nim src/demo.nim' if MODE in ('refactor', 'ai', 'git') else 'both.ned-workspace' if MODE == 'ws' else 'm.nim src/demo.nim uni.txt web.nim page.nimf notes.md wrap.nim mathx.h words.nim') + ' 2> %s/stderr.txt\necho $? > %s/exitcode\nsleep 3600\n') % (HOME, PROJ, BIN, HOME, HOME))
    os.chmod(script, 0o755); own(script)
    tm('-f ' + TESTS + '/ui/tmux.conf new-session -d -s fz -x %d -y %d %s' % (w, h, script))
    time.sleep(1.5)

ESC = '\x1b'
keys_special = [ESC + '[A', ESC + '[B', ESC + '[C', ESC + '[D', ESC + '[1;2A', ESC + '[1;2B', ESC + '[1;2C', ESC + '[1;2D',
    ESC + '[1;5A', ESC + '[1;5B', ESC + '[1;5C', ESC + '[1;5D', ESC + '[1;3A', ESC + '[1;3B', ESC + '[1;6C', ESC + '[1;6D',
    ESC + '[H', ESC + '[F', ESC + '[5~', ESC + '[6~', ESC + '[3~', ESC + '[2~', ESC + '[Z', ESC + '[1;5H', ESC + '[1;5F',
    ESC + 'OP', ESC + 'OQ', ESC + 'OR', ESC + 'OS', ESC + '[15~', ESC + '[17~', ESC + '[18~', ESC + '[19~', ESC + '[20~',
    ESC + '[21~', ESC + '[23~', ESC + '[24~', ESC + '[1;2P', ESC + '[24;2~', ESC + '[1;2S', '\x7f', '\r', '\t', ESC]
ctrl = [chr(c) for c in range(1, 27) if c not in (3, 17, 26)]   # no Ctrl+C/Q/Z here (rarer, below)
words = ['echo', 'proc ', 'let x = ', 'import std/', 'for i in 0..10:', '"str"', '#', '(', ')', '[', ']', '{', '}', '.', ':',
         'greet', 'shout', '= ', '\r  ', 'when ', 'type T = object', 'é', '日本', '😀', 'a' * 50, '\t', ' ', '/', '@', '>', '"', "'",
         'p.', 'p.name.', '"x".', 'greet(', 'shout("a", ', 'import std/[os, str', 'from std/strutils import ', 'x.',
         '\x00', 'Person(', 'for k, (a, b) in ', 'let (a, b) = ', 'result.', 'echo @[1, 2].', 'proc q(a: int) =\r  a.']
def mouse():
    b = rnd.choice([0, 0, 0, 1, 2, 32, 64, 65, 64, 65, 4, 8, 16, 35])
    x, y = rnd.randint(1, 170), rnd.randint(1, 55)
    s = ESC + '[<%d;%d;%dM' % (b, x, y)
    if b < 64 and rnd.random() < 0.8: s += ESC + '[<%d;%d;%dm' % (b & ~32, x, y)
    return s
def paste():
    t = rnd.choice(['hello world', 'line1\nline2\n\tline3', 'proc z() = discard\n', '😀' * 5, 'x' * 500, '\n\n\n',
                    'import os\necho getAppDir()\n', ESC + '[201~ broken', ''])
    return ESC + '[200~' + t + ESC + '[201~'
def palette_commands():
    # every command of the palette, from ned's source (add("Name", …) in the command list)
    names = set()
    for root, _, files in os.walk(REPO + '/src'):
        for f in files:
            if f.endswith('.nim'):
                for m in re.finditer(r'\badd\("([^"]+)"', open(os.path.join(root, f)).read()): names.add(m.group(1))
    return sorted(names)
CMDS = palette_commands()
ENGINE = ['p.', 'p.name.', '"x".', 'greet(', 'shout("a", ', 'import std/[os, str', 'x.', 'Person(na', 'result.',
          '\x1bh', '\x1b.', '\x1bq', '\x1b[12~', '\x1bOQ', '\x00', '\x14', '\x1b[1;5A', '\x1b[1;5B', '\x1b,',
          '\r  let t = initTable[string, int]()\r  t.', '\r  for i, (a, b) in @[(1, 2)]:\r    a.', 'echo some(3).',
          '\x1bf', 'q.', '\x0b', '\x1b[A', '\x1b[B', '\t', '\r']
C_MAIN = '''#include <stdio.h>
#include <string.h>
#include "mathx.h"

/** A node of a list. */
struct node {
    struct node *next;
    int value;       /**< what it holds */
    union { int i; float f; } u;
};

typedef struct { int x, y; } Pt;

static const struct { const char *name; int v; } table[] = { { "a", 1 }, { "b", 2 } };

#ifdef __cplusplus
extern "C" {
#endif

int walk(struct node *head, Pt *p)
{
    int n = 0;
#ifdef FAST
    while (head) {
#else
    while (head != NULL) {
#endif
        n += head->value;
        head = head->next;
    }
    if (n < 0) goto out;
    p->x = n >= 0 ? n : -n;
    return n;
out:
    return -1;
}

#ifdef __cplusplus
}
#endif

int main(int argc, char **argv)
{
    struct node a = { .next = NULL, .value = 1 };
    Pt q = { .x = 1, .y = 2 };
    printf("%d %s\\n", walk(&a, &q), table[0].name);
    return argc > 1 && strcmp(argv[1], "x") != 0;
}
'''
C_TOKS = ['head->', 'a.', 'a.u.', 'q.', 'p->', 'table[0].', '{ .', '#include "', '#include <st', '#include <sys/',
          'goto ', 'walk(', 'printf(', 'struct node *m = ', '->', '!=', '<=', '>=', '=>', ':=', '\x1b[24~', '\x1bOQ',
          '\x1bh', '\x1bq', '\x1b\r', '\x00', '\x14', '\x1b,', '\x13', '\x1a', '\x0b', '\r', '\t', '\x07']
def token():
    if MODE == 'engine' and rnd.random() < 0.4: return rnd.choice(ENGINE)
    if MODE == 'c' and rnd.random() < 0.4: return rnd.choice(C_TOKS)
    if MODE == 'term' and rnd.random() < 0.3:
        # the terminal with shell integration: commands, their marks, menus, split terminals; macros
        return rnd.choice(['\x1c', '\x1b[1;5A', '\x1b[1;5B', '\x1b\r', '\x1b[5;5~', '\x1b[6;5~', 'echo hi\r', 'false\r',
                           'ls\r', 'printf "a\\nb\\n"\r', 'clear\r', '\x1bR', '\x1bM', '\x1b[1;2A',
                           '\x10>Terminal: split\r', '\x10>Terminal: commands\r', '\x10>Terminal: run the last command again\r',
                           '\x10>Terminal: copy the last command\'s output\r', '\x10>Macro: play on each selected line\r',
                           '\x10>Macro: play to the end of the file\r', '\x10>Macro: play the last one N times\r3\r'])
    if MODE == 'ws' and rnd.random() < 0.25:
        # the Git dock and its repositories, files of both folders, git commands
        return rnd.choice(['\x1bg', '\x10lib2.nim\r', '\x10demo.nim\r', '\x10new.txt\r', '\x1bg\x1b[A\r',
                           '\x1bg\x1b[B\x1b[B\r', 's', 'u', 'a', 'd', '\x10>Git: branches\r', '\x10>Git: history\r',
                           '\x10>Git: stash\r', '\x10>Git: commit (message box)\rmsg\x13', '\x10>Reveal file in tree\r',
                           '\x10>Workspace: remove a folder\r', '\x10>Git: stage this change\r'])
    if MODE == 'ai' and rnd.random() < 0.3:
        r = rnd.random()
        if r < 0.15: return '\x1bc' + rnd.choice(['add a cube proc\r', 'add a doc comment to shout\r', 'hello\r', 'list the files\r'])
        if r < 0.3: return '\x10>AI: write tests\r'
        if r < 0.5: return rnd.choice(['y', 'a', 'n'])
        if r < 0.6: return ESC
        if r < 0.7: return '\x10>AI: undo the assistant\r'
        if r < 0.8: return '\x10>AI: new chat\r'
        if r < 0.9: return '\x07' + str(rnd.randint(1, 12)) + '\r'
        return rnd.choice(['\x1b1', '\x1b2', '\x13', '\x1a'])
    if MODE == 'git' and rnd.random() < 0.35:
        r = rnd.random()
        if r < 0.2: return rnd.choice(['\x10>Git: bisect — good\r', '\x10>Git: bisect — bad\r', '\x10>Git: bisect — skip\r',
                                       '\x10>Git: bisect — stop\r'])
        if r < 0.35: return '\x10>Git: find the commit that broke it\r' + rnd.choice(['', 'c1\r', '\r', 'c2\r\r', 'c1\r\x1b[B\r! grep -q broken bug.txt\r'])
        if r < 0.5: return '\x07' + str(rnd.randint(1, 20)) + '\r\x10>Git: history of these lines\r'
        if r < 0.6: return '\x10>Git: worktrees\r' + rnd.choice(['', '\r', '\x1b[B\r', 'New\r\r', '\x1b'])
        if r < 0.7: return '\x10>Git: submodules\r' + rnd.choice(['', '\r', '\x1b'])
        if r < 0.8: return rnd.choice(['y', 'n', '\r', '\x1b', '\x1bg'])
        return rnd.choice(['\x1b1', '\x1b2', '\x13', '\x1a', '\x17'])
    if MODE == 'refactor' and rnd.random() < 0.35:
        r = rnd.random()
        if r < 0.3:
            return '\x07' + str(rnd.randint(1, 30)) + ':' + str(rnd.randint(1, 12)) + '\r' + rnd.choice([
                '\x10>Nim: change signature\r', '\x10>Nim: inline this proc\r', '\x10>Nim: move to another module\r',
                '\x1b\r', '\x1b\r\x1b[B\r', '\x1b\r\x1b[B\x1b[B\r', ''])
        if r < 0.5: return rnd.choice(['z: int :: 1', '-> string', 'y = 3  ← x', 'q: string ', '::', '←', '-> ', 'x: int  ← nope',
                                       '\x1b[1;5A', '\x1b[1;6A', '\x0b', 'factor2 = 2  ← factor', '\r'])
        if r < 0.6: return '\x13'
        if r < 0.7: return rnd.choice(['y', 'n', '\r', '\x1b', '\x17'])
        if r < 0.8: return rnd.choice(['\x10>Save all\r', '\x10>Nim: exports nothing uses\r', '\x10>Nim: toggle reference counts\r',
                                       '\x10>Reload from disk\r', '\x1bm'])
        if r < 0.9: return '\x1a'
        return rnd.choice(['\x101\r', '\x10src/demo/m', '\x1b1', '\x1b2', '\x1b3'])
    if MODE == 'fixes' and rnd.random() < 0.3:
        # a line with a problem, its quick fixes, one of them; a save now and then for nim check
        r = rnd.random()
        if r < 0.15: return '\x13'
        if r < 0.25: return '\x1a'
        seq = '\x07' + str(rnd.randint(1, 42)) + '\r' + ESC + '\r'
        seq += ESC + '[B' * rnd.randint(0, 6)
        return seq + rnd.choice(['\r', '\r', '\r', ESC, 'Fix all\r', 'Convert\r', 'AI\r'])
    if MODE in ('palette', 'vim', 'nimsuggest', 'nls', 'helix', 'emacs', 'a11y', 'emit', 'strings', 'fixes', 'c', 'ws', 'term', 'refactor', 'ai', 'git') and rnd.random() < 0.06:
        c = rnd.choice(CMDS)
        return '\x10' + '>' + c + '\r'
    r = rnd.random()
    if r < 0.25: return rnd.choice(words)
    if r < 0.30: return chr(rnd.randint(32, 126))
    if r < 0.55: return rnd.choice(keys_special)
    if r < 0.68: return rnd.choice(ctrl)
    if r < 0.80: return ESC + chr(rnd.choice(list(range(97, 123)) + list(range(65, 91)) + [44, 46, 47, 59, 91, 93, 13, 49, 50, 51]))
    if r < 0.92: return mouse()
    if r < 0.96: return paste()
    if r < 0.965: return '\x11'          # Ctrl+Q
    if r < 0.97: return '\x1a'           # Ctrl+Z
    if r < 0.975: return '\x03'          # Ctrl+C
    return rnd.choice(['\x00', ESC + '[999;999R', ESC + ']11;rgb:0000/0000/0000\x07', ESC + '[I', ESC + '[O', ESC + '[?1;2c'])

def send(s):
    hx = ' '.join('%02x' % b for b in s.encode('utf-8'))
    tm('send-keys -t fz -H ' + hx)

def status():
    ec = None
    try: ec = open(HOME + '/exitcode').read().strip()
    except Exception: pass
    errs = ''
    try: errs = open(HOME + '/.local/state/ned/errors.log').read()
    except Exception: pass
    return ec, errs

def ned_alive():
    # ned_dbg processes that still run (a zombie has exited: this container's init reaps them a second or two late)
    out = sh("ps -u fuzz -o pid=,stat=,args=").stdout
    return [l.split()[0] for l in out.splitlines() if 'ned_dbg' in l and not l.split()[1].startswith('Z')]

def nedpid():
    r = sh("pgrep -f '^%s'" % BIN).stdout.split()
    return int(r[0]) if r else None

def cputime(pid):
    try:
        f = open('/proc/%d/stat' % pid).read().rsplit(')', 1)[1].split()
        return (int(f[11]) + int(f[12])) / os.sysconf('SC_CLK_TCK')
    except Exception: return None

def main():
    setup(); start()
    hang_pid = None; hang_t = 0; hang_c = 0; busy = 0
    hist = []
    t0 = time.time(); n = 0; restarts = 0; seen = 0
    out = open(LOG, 'w')
    while time.time() - t0 < DUR:
        burst = ''.join(token() for _ in range(rnd.randint(1, 12)))
        hist.append(burst); hist = hist[-60:]
        send(burst); n += 1
        if rnd.random() < 0.01:
            tm('resize-window -t fz -x %d -y %d' % (rnd.randint(30, 170), rnd.randint(8, 55)))
        time.sleep(rnd.choice([0, 0.005, 0.02, 0.05]))
        if n % 25 == 0:
            pid = nedpid()
            now = time.time()
            if pid and pid == hang_pid and now - hang_t >= 4:
                c = cputime(pid)
                if c is not None:
                    busy = busy + 1 if (c - hang_c) / (now - hang_t) > 0.9 else 0
                    hang_t, hang_c = now, c
                    if busy >= 6:      # ~25 s of a fully busy ned
                        bt = sh('gdb -p %d -batch -ex "thread apply all bt 25" 2>/dev/null | grep -E "^#" | head -40' % pid).stdout
                        pane = tm('capture-pane -t fz -p').stdout
                        out.write('=== HANG (100%% CPU) after %d bursts\n%s\n--- pane:\n%s\n--- last input: %r\n' % (n, bt, pane, hist[-20:])); out.flush()
                        sh('kill -9 %d' % pid); busy = 0
            elif pid:
                hang_pid, hang_t, hang_c, busy = pid, now, cputime(pid) or 0, 0
            ec, errs = status()
            if len(errs) > seen:
                out.write('=== INTERNAL ERROR after %d bursts\n%s\n--- last input: %r\n' % (n, errs[seen:], hist[-15:])); out.flush()
                seen = len(errs)
            if ec is not None:
                if ec != '0':
                    st = open(HOME + '/stderr.txt', errors='replace').read()[-3000:]
                    pane = tm('capture-pane -t fz -p').stdout
                    out.write('=== CRASH exit %s after %d bursts\n%s\n--- pane:\n%s\n--- last input: %r\n' % (ec, n, st, pane, hist[-20:])); out.flush()
                restarts += 1
                tm('kill-server'); time.sleep(0.3)
                own(HOME)
                start()
    ec, errs = status()
    pid0 = nedpid()
    if pid0:
        try: stt = open('/proc/%d/stat' % pid0).read().rsplit(')', 1)[1].split()[0]
        except Exception: stt = '?'
        out.write('state before closing: %s\n' % stt)
        if stt == 'R':
            out.write(sh('gdb -p %d -batch -ex "bt 25" 2>&1 | grep "^#"' % pid0).stdout[-3000:])
    tk = time.time()
    tm('kill-server')
    out.write('kill-server returned after %.2fs\n' % (time.time() - tk))
    gone_after = None
    while time.time() - tk < 2:
        if not ned_alive():
            gone_after = time.time() - tk
            break
        time.sleep(0.05)
    out.write('exit took %s\n' % ('%.2fs' % gone_after if gone_after is not None else '>2s'))
    if gone_after is None and pid0:
        out.write(sh('ps -o pid,ppid,stat,wchan:30,etime,args -p %d --ppid %d' % (pid0, pid0)).stdout)
        out.write(sh('gdb -p %d -batch -ex "thread apply all bt 40" 2>&1 | grep -v "^\\[New\\|^Using\\|warning"' % pid0).stdout[-6000:])
    left = ned_alive()
    if left:
        time.sleep(8)
        still = ned_alive()
        out.write('=== NED DID NOT EXIT within 2 s of its terminal closing (pids %s; after 10 s: %s)\n' % (left, still))
        for pid in still:
            out.write(sh('ps -o pid,ppid,stat,wchan:30,etime,args -p %s --ppid %s' % (pid, pid)).stdout)
            out.write(sh('gdb -p %s -batch -ex "thread apply all bt 40" 2>&1 | grep -v "^\\[New\\|^Using\\|warning"' % pid).stdout[-6000:])
        sh('pkill -9 -f ' + BIN)
    out.write('done: seed %d, %d bursts, %d restarts, errors.log %d bytes\n' % (SEED, n, restarts, len(errs)))
    out.close()
    print(open(LOG).read()[-4000:])

main()
