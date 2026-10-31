#!/usr/bin/env python3
"""Everything named is wired: every command a menu, a button, a tap or a key names (mc("…"), runCmd("…")) is one ned
has — `ned --doc-commands` lists them all, the ones made in loops too — and every setting is both declared (defS in
src/ned/config/settings.nim, with its description) and read somewhere. A menu item naming a command that does not
exist is drawn greyed out and does nothing; a setting read but never declared is always its type's empty value; one
declared and never read is a promise in the Settings panel that changes nothing. And every request the plugin library
sends ned has its handler.

Usage: wiring.py [path/to/ned]      (default ./ned; exit status 1 when something is not wired)"""
import os, re, subprocess, sys, glob

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
SRC = os.path.join(REPO, 'src')
NED = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, 'ned'))
STR = r'"((?:[^"\\]|\\.)*)"'

def main():
    files = {f: open(f, encoding='utf-8', errors='replace').read()
             for f in glob.glob(SRC + '/**/*.nim', recursive=True) if '/plugins/lib/' not in f}
    problems = []
    # ── commands ──
    env = dict(os.environ, XDG_CONFIG_HOME=os.path.join('/tmp', 'ned-wiring-%d' % os.getpid()))
    out = subprocess.run([NED, '--doc-commands'], capture_output=True, text=True, env=env).stdout
    cmds = set()
    for l in out.splitlines():
        if not l.startswith('|'): continue
        cells = re.split(r'(?<!\\)\|', l)                  # (a | in a name is written \|)
        if len(cells) < 3: continue
        name = cells[1].strip().replace('\\|', '|').replace('`', '')
        if name and name != 'Command' and not set(name) <= set('-: '): cmds.add(name)
    if len(cmds) < 300: sys.exit('ned --doc-commands gave %d commands: is %s built?' % (len(cmds), NED))
    renamed = set(re.findall(r'"([^"]+)": "[^"]+"', files[os.path.join(SRC, 'ned', 'ui', 'menubar.nim')]
                             .split('const CmdRenamed')[1].split('\n\n')[0]))
    used = 0
    for f, s in files.items():
        for m in re.finditer(r'\b(?:mc|runCmd|cmdByName)\(' + STR, s):
            name = m.group(1)
            used += 1
            if name in cmds or name in renamed: continue
            line = s.count('\n', 0, m.start()) + 1
            problems.append('%s:%d: no command "%s" (the menu item or button does nothing)' %
                            (os.path.relpath(f, REPO), line, name))
    # ── settings ──
    sfile = os.path.join(SRC, 'ned', 'config', 'settings.nim')
    defs = {}
    for m in re.finditer(r'defS\(' + STR + r',\s*' + STR, files[sfile]):
        defs[m.group(2)] = files[sfile].count('\n', 0, m.start()) + 1
    allsrc = '\n'.join(files.values())
    # (read by a prefix and a list of names: `sval("nim." & k)` for k in a const list)
    prefixes = set(re.findall(r'\bs(?:val|Str|Bool|Int)\(' + STR + r'\s*&', allsrc))
    reads = set()
    for m in re.finditer(r'\b(?:sval|sStr|sBool|sInt|sFloat|sJson|setSetting|settingDef|settingNode|settingOf|toggleSetting|setIndex\.getOrDefault)\(' +
                         STR + r'\s*[,)]', allsrc):
        reads.add(m.group(1))
    for key in reads:
        if key not in defs and not key.startswith('_'):
            problems.append('setting "%s" is read but never declared (it is always empty or false)' % key)
    for key, line in sorted(defs.items()):
        if key in reads: continue
        lit = '"' + key + '"'
        others = allsrc.count(lit) - files[sfile].count(lit) + sum(1 for _ in re.finditer(re.escape(lit) + r'(?!\s*,\s*%)',
                                                                                              files[sfile])) - 1
        if others > 0: continue
        if any(key.startswith(p) and ('"' + key[len(p):] + '"') in allsrc for p in prefixes): continue
        problems.append('src/ned/config/settings.nim:%d: setting "%s" is declared but nothing reads it' % (line, key))
    # (what ned itself says is wrong with its settings: declared twice, a default that is none of its values …)
    r = subprocess.run([NED, '--doc-settings'], capture_output=True, text=True, env=env)
    for l in r.stderr.splitlines():
        if l.startswith('setting '): problems.append(l)
    # (a setting's old name, moved to its new one when settings are read: the new one must still be a setting)
    leg = files[sfile].split('const LegacyKeys')[1].split('\n\n')[0]
    for old, new in re.findall(r'\(' + STR + r',\s*' + STR + r'\)', leg):
        if new not in defs:
            problems.append('src/ned/config/settings.nim: the old setting "%s" moves to "%s", which is no setting' %
                            (old, new))
    # ── the plugin API: every request the plugin library sends ned (api("name", …)) has its handler in the host ──
    lib = ''.join(open(os.path.join(SRC, 'ned', 'plugins', 'lib', f), encoding='utf-8').read()
                  for f in ('nedplugin.nim', 'nedlsp.nim'))
    ops = set(re.findall(r'\bapi\("([A-Za-z_]+)"', lib))
    host = files[os.path.join(SRC, 'ned', 'plugins', 'host.nim')]
    handled = set()
    for m in re.finditer(r'\bof ((?:"[A-Za-z_]+"\s*,\s*)*"[A-Za-z_]+")\s*:', host):
        handled |= set(re.findall(r'"([A-Za-z_]+)"', m.group(1)))
    for op in sorted(ops - handled):
        problems.append('the plugin library sends "%s", which ned does not answer (src/ned/plugins/host.nim)' % op)
    for p in problems: print(p)
    print('%d command names used by menus and buttons, %d commands; %d settings declared, %d read by name; %d plugin '
          'API requests: %s' % (used, len(cmds), len(defs), len(reads), len(ops),
                                'all wired' if not problems else '%d problems' % len(problems)))
    sys.exit(1 if problems else 0)

main()
