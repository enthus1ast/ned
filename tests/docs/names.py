#!/usr/bin/env python3
"""Every name of a command or a setting used anywhere is one that exists — a command renamed must not leave a menu
item greyed out, a key that does nothing, a plugin's call that fails, or a page of the docs that names it wrong.

  the source       menus (mc), runCmd, cmdByName, the touch bar and the docks — each a command of the palette
  ned's plugins    runCommand("…") — a command of ned's or of one of ned's own plugins
  the docs         a command in italics (*Nim: why? …*) and a setting in backticks (`nim.format.embedded`) of the
                   guides, the plugin pages and the README — each one that exists (a command's name may stop at
                   "…"; a plugin's command made with a variable part counts by its fixed start)

Usage: names.py   (from anywhere; exit status 1 and the list when one does not exist)"""
import glob, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.chdir(ROOT)
src = {f: open(f, encoding='utf-8').read() for f in glob.glob('src/**/*.nim', recursive=True)}
cmds = set()
for f in ['src/ned/app/commandlist.nim', 'src/ned/app/setupcheck.nim']:
    cmds |= set(re.findall(r'\badd\("([^"]+)"', src[f]))
# (old names that still work — the keys setting of someone who used them: CmdRenamed — but not in ned's own code)
renamed = dict(re.findall(r'"([^"]+)":\s*"([^"]+)"', src['src/ned/ui/menubar.nim'].split('CmdRenamed', 1)[1].split('}', 1)[0]))
settings = set(re.findall(r'defS\("[^"]+",\s*"([^"]+)"', src['src/ned/config/settings.nim']))

# the plugins' own commands: fixed names, and the fixed starts of names made with a variable part
pcmds, pstarts = set(), set()
for f in glob.glob('plugins/*/*.nim*') + glob.glob('examples/**/*.nim*', recursive=True):
    s = open(f, encoding='utf-8').read()
    for m in re.finditer(r'\b(?:command|regCommand)\s*\(?\s*"([^"]*)"(\s*&)?', s):
        (pstarts if m.group(2) else pcmds).add(m.group(1))

NimWords = {'for', 'if', 'case', 'while', 'when', 'let', 'var', 'not', 'try', 'echo', 'len'}
bad = []
def line_of(s, i): return s[:i].count('\n') + 1

# ── the source: what names a command of the palette ──
for f, s in src.items():
    for pat in [r'\bmc\("([^"]+)"', r'\brunCmd\("([^"]+)"', r'\bcmdByName\("([^"]+)"']:
        for m in re.finditer(pat, s):
            n = m.group(1)
            if n in renamed:
                bad.append('%s:%d: "%s" is an old name: "%s"' % (f, line_of(s, m.start()), n, renamed[n]))
            elif n not in cmds:
                bad.append('%s:%d: no command "%s"' % (f, line_of(s, m.start()), n))

# ── ned's own plugins and the examples: runCommand ──
for f in glob.glob('plugins/*/*.nim*') + glob.glob('examples/**/*.nim*', recursive=True):
    s = open(f, encoding='utf-8').read()
    for m in re.finditer(r'\brunCommand\(\s*"([^"]+)"', s):
        n = m.group(1)
        if n not in cmds and n not in pcmds and not any(n.startswith(p) for p in pstarts if p):
            bad.append('%s:%d: runCommand("%s"): no such command' % (f, line_of(s, m.start()), n))

# ── the docs ──
def cmd_exists(n):
    n = n.strip()
    if n in cmds or n in pcmds: return True
    stem = n.rstrip('…').rstrip('.').rstrip()
    # (the docs may give a command's name up to its explanation: "Nim: why?" for "Nim: why? (where …)")
    for c in cmds | pcmds:
        if c.startswith(stem) and (c == stem or c[len(stem):][:2] in (' (', ' —', ' –', '…', ' …', ' ·') or
                                   n.endswith('…') or n.endswith('...')):
            return True
    if any(p and n.startswith(p) for p in pstarts): return True
    return False

# (prefixes of the palette's commands: "Nim: …", "View: …"; a word in italics that is not one is prose)
prefixes = {c.split(':')[0] for c in cmds | pcmds | pstarts if ':' in c}
setting_groups = {k.split('.')[0] for k in settings}
docs = glob.glob('docs/**/*.md', recursive=True) + ['README.md']
for f in docs:
    if f.startswith('docs/reference/'): continue          # (made from ned itself: ned --doc-settings, --doc-commands)
    s = open(f, encoding='utf-8').read()
    body = re.sub(r'```.*?```', lambda m: '\n' * m.group(0).count('\n'), s, flags=re.S)   # (code blocks: examples)
    body = body.replace('\\*', '\x00')                    # (an asterisk escaped: part of the name, `(\\*)`)
    for m in re.finditer(r'(?<![*\w])\*([A-Z][A-Za-z0-9 ]*?: [^*\n]{2,90}?)\*(?![*\w])', body):
        n = m.group(1)
        n = n.replace('\x00', '*')
        if n.split(':')[0] not in prefixes: continue      # (prose in italics, or a heading-like phrase)
        if '/' in n.split(':')[1][:3]: continue
        if not cmd_exists(n):
            bad.append('%s:%d: no command "%s"' % (f, line_of(body, m.start()), n))
    for m in re.finditer(r'`([a-z][A-Za-z0-9]*\.[A-Za-z0-9.]+)`', body):
        n = m.group(1)
        if n.split('.')[0] not in setting_groups or n in settings: continue
        if n.startswith('plugins.') and n.count('.') >= 2: continue       # (a plugin's own: plugins.ID.NAME)
        if n.split('.')[-1] in NimWords: continue                           # (a postfix template: `c.case`)
        near = body[body.rfind('\n', 0, max(0, body.rfind('\n', 0, m.start()))) + 1:body.find('\n', m.start())]
        if 'Helix' in near or 'Zed' in near: continue                       # (a theme's key, not a setting)
        if any(k.startswith(n + '.') for k in settings): continue          # (a group of settings: `ai.agent`)
        if re.search(r'\.(nim|nims|nimble|md|json|toml|py|sh|js|c|h|cfg|txt|lua|png|html|yml)$', n): continue
        bad.append('%s:%d: no setting `%s`' % (f, line_of(body, m.start()), n))

if bad:
    print('\n'.join(bad))
    print('%d names that do not exist' % len(bad))
    sys.exit(1)
print('every command and setting named exists (%d commands, %d of the plugins, %d settings)' %
      (len(cmds), len(pcmds), len(settings)))
