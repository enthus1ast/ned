"""What every UI test uses: ned running in a private tmux server, keys sent to it, its screen read back.

The paths come from the environment (run.py sets them):
  NEDBIN          the ned binary under test
  NED_TEST_TMP    a scratch folder (work copy, settings, state, mock-server log)
  NED_TEST_PATH   more folders for PATH, before nim's (language servers, clangd … optional)
"""
import os, re, shutil, subprocess, sys, time, json

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
FIX = HERE + '/fixtures'
MOCKS = HERE + '/mocks'
TMP = os.environ.get('NED_TEST_TMP') or '/tmp/ned-ui-%d' % os.getuid()
W = TMP + '/work'
CFG = TMP + '/cfg'
STATE = TMP + '/state'
BIN = os.path.abspath(os.environ.get('NEDBIN', REPO + '/ned'))
SOCK = os.environ.get('NED_TEST_SOCKET', 'ned-ui')
AI_PORT = int(os.environ.get('NED_TEST_AI_PORT', '8765'))
MOCK_LOG = TMP + '/mock-requests.log'

def _dir_of(exe):
    p = shutil.which(exe)
    return os.path.dirname(os.path.realpath(p)) if p else ''

NIMBIN = _dir_of('nim')                    # the Nim toolchain's bin folder (required)
NIMROOT = os.path.dirname(NIMBIN)
EXTRA = os.environ.get('NED_TEST_PATH', '')
TOOLS = ':'.join(x for x in [EXTRA, NIMBIN] if x)     # what tests put before /usr/bin:/bin

def which(exe):
    """an optional tool, looked for on the tests' PATH too"""
    return shutil.which(exe, path=TOOLS + ':' + os.environ.get('PATH', '/usr/bin:/bin'))

NODE_DIR = os.path.dirname(which('node') or '')
SSH_DIR = os.path.dirname(which('ssh') or '')
SSH_CTL = os.path.join(os.environ.get('TMPDIR', '/tmp'), 'ned-ssh-%d' % os.getuid())   # ned's shared SSH connections

class Skip(Exception):
    pass

def need(*tools):
    """skip the test when one of these is missing: an executable, or a 'name' run.py knows how to check"""
    missing = []
    for t in tools:
        if t == 'ssh-server':
            if os.environ.get('NED_TEST_SSH') != '1': missing.append('the test SSH server (NED_TEST_SSH=1, see README)')
            elif not which('ssh'): missing.append('ssh')
        elif t == 'dictionary':
            if not spell_dict(): missing.append('an en_US hunspell dictionary')
        elif not which(t):
            missing.append(t)
    if missing: raise Skip('needs ' + ', '.join(missing))

def spell_dict():
    for d in [os.environ.get('NED_TEST_DICT', ''), '/usr/share/hunspell/en_US.dic', '/usr/share/myspell/en_US.dic',
              '/usr/share/hunspell/en_US/en_US.dic']:
        if d and os.path.exists(d): return d
    return ''

results = []

def sh(c): return subprocess.run(c, shell=True, capture_output=True, text=True)
def tm(*a): return subprocess.run(['tmux', '-L', SOCK] + list(a), capture_output=True, text=True)
def keys(*k):
    for x in k:
        tm('send-keys', '-t', 'f', x); time.sleep(0.12)
def text(s): tm('send-keys', '-t', 'f', '-l', s); time.sleep(0.15)
def screen(): return tm('capture-pane', '-t', 'f', '-p').stdout
def wait_for(pat, t=8.0):
    end = time.time() + t
    while time.time() < end:
        s = screen()
        if re.search(pat, s): return True
        time.sleep(0.2)
    return False
def screen_ansi():
    """the screen with its colours (SGR escapes)"""
    return tm('capture-pane', '-t', 'f', '-p', '-e').stdout

def ansi_row(text):
    """the screen row (with its colours) whose text contains `text`, or ''"""
    for l in screen_ansi().split('\n'):
        if text in re.sub(r'\x1b\[[0-9;:]*m', '', l): return l
    return ''

def fg_at(row, word, nth=0):
    """the 24-bit foreground colour (r, g, b strings) where the nth `word` starts on an ANSI row, or None"""
    plain = re.sub(r'\x1b\[[0-9;:]*m', '', row)
    k = -1
    for _ in range(nth + 1):
        k = plain.find(word, k + 1)
        if k < 0: return None
    return fg_at_col(row, k)

def char_at_col(row, k):
    """the character at column k of an ANSI row ('' past its end)"""
    plain = re.sub(r'\x1b\[[0-9;:]*m', '', row)
    return plain[k] if 0 <= k < len(plain) else ''

def paste(s):
    """text arriving as a terminal paste (bracketed): one event, as when you paste from the clipboard"""
    tm('set-buffer', '-b', 'nedtest', s)
    tm('paste-buffer', '-p', '-d', '-b', 'nedtest', '-t', 'f')

def fg_at_col(row, k):
    """the 24-bit foreground colour at column k of an ANSI row, or None"""
    fg, col, i = None, 0, 0
    while i < len(row):
        m = re.match(r'\x1b\[([0-9;:]*)m', row[i:])
        if m:
            ps = m.group(1).split(';')
            j = 0
            while j < len(ps):
                if ps[j] == '38' and j + 4 < len(ps) and ps[j + 1] == '2':
                    fg = tuple(ps[j + 2:j + 5]); j += 5
                elif ps[j] in ('0', '39', ''):
                    fg = None; j += 1
                elif ps[j] in ('48', '58') and j + 4 < len(ps) and ps[j + 1] == '2':
                    j += 5
                else: j += 1
            i += m.end(); continue
        if col == k: return fg
        col += 1; i += 1
    return None
def palette(cmd):
    keys('Escape'); time.sleep(0.2); keys('C-p'); text('>' + cmd); time.sleep(0.4); keys('Enter'); time.sleep(0.4)

def demo_template():
    """the demo nimble project as a git repository (one commit), made once per run"""
    t = TMP + '/demo-template'
    if not os.path.exists(t + '/.git'):
        shutil.rmtree(t, ignore_errors=True)
        shutil.copytree(FIX + '/demo', t)
        # (its own name and email for commits: a machine without a git identity — a CI runner — commits too)
        subprocess.run('git init -q -b master && git config user.name t && git config user.email t@t && '
                       'git config commit.gpgsign false && git add -A && git commit -qm init', shell=True, cwd=t,
                       check=True, capture_output=True)
    return t

def setup(cfg=None):
    tm('kill-server'); time.sleep(0.3)
    shutil.rmtree(W, ignore_errors=True); shutil.copytree(demo_template(), W)
    shutil.rmtree(STATE, ignore_errors=True)
    os.makedirs(CFG + '/ned', exist_ok=True)
    c = {"ai.provider": "openai", "ai.baseUrl": "http://127.0.0.1:%d/v1" % AI_PORT, "ai.apiKey": "sk-test",
         "ai.model": "gpt-6"}
    c["nim.nimsuggest"] = True        # (most tests were written with it on; t_528_hierarchy checks the default)
    c["security.folderTrust"] = "off"  # (the scratch project is the tests' own; t_66_trust asks)
    c.update(cfg or {})
    c = {k: v for k, v in c.items() if v is not None}
    json.dump(c, open(CFG + '/ned/config.json', 'w'))

def start(*files, w=140, h=40, path=None, env_extra=''):
    env = 'PATH=%s XDG_CONFIG_HOME=%s XDG_STATE_HOME=%s COLORTERM=truecolor TERM=xterm-256color %s' % (
        path or TOOLS + ':$PATH', CFG, STATE, env_extra)
    tm('-f', HERE + '/tmux.conf', 'new-session', '-d', '-s', 'f', '-x', str(w), '-y', str(h),
       'cd %s && env %s %s %s; echo EXITED $? > %s/exit; sleep 600' % (W, env, BIN, ' '.join(files), W))
    time.sleep(1.5)
    keys('Escape')

def check(name, cond, info=''):
    results.append((name, bool(cond)))
    print(('PASS ' if cond else 'FAIL ') + name + ('' if cond else '  ' + info[:400].replace('\n', ' | ')), flush=True)

def ftext(p): return open(os.path.join(W, p)).read()

def big_file():
    """a million-line Nim file (the large-file mode)"""
    p = TMP + '/big.nim'
    if not os.path.exists(p):
        with open(p, 'w') as f:
            for i in range(1_000_000):
                f.write('proc p%d*(x: int): int = x * %d  # line %d\n' % (i, i, i))
    return p

def ned_source():
    """ned's own source as one big Nim file (for the formatter on real code)"""
    p = TMP + '/nedsrc.nim'
    if not os.path.exists(p):
        out = []
        for root, _, files in sorted(os.walk(REPO + '/src')):
            for f in sorted(files):
                if f.endswith('.nim'): out.append(open(os.path.join(root, f)).read())
        open(p, 'w').write('\n'.join(out))
    return p

def no_nim_dir():
    """a PATH folder with nim, nimble and nimsuggest but no testament or inim"""
    d = TMP + '/nimonly'
    os.makedirs(d, exist_ok=True)
    for x in ['nim', 'nimble', 'nimsuggest']:
        p = os.path.join(NIMBIN, x)
        if os.path.exists(p) and not os.path.exists(os.path.join(d, x)): os.symlink(p, os.path.join(d, x))
    return d

def fake_nimble_dir():
    """a NIMBLE_DIR with jsony 1.1.0 installed, and package repositories whose tags offer jsony 1.2.0 (and
    `other` 2.0.0): what *Nimble: newer versions of the dependencies* reads"""
    d = TMP + '/nimbledir'
    if os.path.exists(d): return d
    repos = TMP + '/repos'
    for name, tags in [('jsony', ['1.0.0', '1.1.0', 'nightly', 'v1.2.0']), ('other', ['2.0.0'])]:
        src = TMP + '/repo-src-' + name
        os.makedirs(src, exist_ok=True)
        open(src + '/%s.nimble' % name, 'w').write('version = "0.0.0"\n')
        g = 'git -C %s -c user.name=t -c user.email=t@t ' % src
        sh('git init -q -b master %s && %s add -A && %s commit -qm init' % (src, g, g))
        for t in tags: sh(g + 'tag ' + t)
        sh('git clone -q --bare %s %s/%s.git' % (src, repos, name))
    os.makedirs(d + '/pkgs2/jsony-1.1.0-abcdef', exist_ok=True)
    open(d + '/nimbledata2.json', 'w').write('{\n  "version": 1,\n  "reverseDeps": {}\n}\n')
    json.dump([{"name": "jsony", "url": "file://%s/jsony.git" % repos, "method": "git"},
               {"name": "other", "url": "file://%s/other.git" % repos, "method": "git"},
               {"name": "jsonyAlias", "alias": "jsony"}], open(d + '/packages_official.json', 'w'))
    return d

def ned_single_file():
    """ned as one Nim file that compiles on its own (every include and ned module put in place): a big real
    program for the formatter to work on"""
    p = TMP + '/ned_single.nim'
    if os.path.exists(p): return p
    src = REPO + '/src'
    done = set()
    def inline(path, out):
        base = os.path.dirname(path)
        for line in open(path).read().split('\n'):
            t = line.strip()
            m = re.match(r'include\s+(\S+)$', t)
            if m and not line.startswith(' '):
                inline(os.path.normpath(os.path.join(base, m.group(1) + '.nim')), out)
                continue
            m = re.match(r'import\s+(ned/\S.*|\.\./\S.*)$', t)
            if m and not line.startswith(' '):
                for mod in [x.strip() for x in m.group(1).split(',')]:
                    mp = os.path.normpath(os.path.join(base, mod + '.nim'))
                    if mp not in done:
                        done.add(mp)
                        inline(mp, out)
                continue
            out.append(line)
    out = []
    inline(src + '/ned.nim', out)
    open(p, 'w').write('\n'.join(out) + '\n')
    return p
