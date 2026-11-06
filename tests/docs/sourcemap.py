#!/usr/bin/env python3
"""docs/dev/source-map.md — every source file of ned, folder by folder, with what it is (its own first comment),
whether src/ned.nim includes it (and where in the order) or imports it as a module of its own, and the files the
other two programs (nedls, nedfmt) and the plugin library are made of. Made from the sources, so it stays true:
  python3 tests/docs/sourcemap.py           writes it
  python3 tests/docs/sourcemap.py --check   exit 1 when it is not what the sources say (CI)"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
SRC = os.path.join(ROOT, 'src')
OUT = os.path.join(ROOT, 'docs', 'dev', 'source-map.md')

FOLDERS = {
    'app': 'the program as a whole: start, the main loop, the command list, input, updates, the battery, the tour',
    'core': 'the basics everything uses: types, global state, utilities, languages, themes, text, images, secrets',
    'config': 'settings, key bindings, folder trust, settings sync',
    'editor': 'buffers and editing: the edit primitive and undo, cursors, find, folding, saving, swap files, '
              'multibuffers, the hex and large-file views',
    'ui': 'drawing and the interface: the frame, the editor view, docks, the panel, popups, pickers, menus, dialogs, '
          'the status bar',
    'keymaps': 'the key bindings that are not VS Code\'s: Vim (and its : line), Emacs, Helix',
    'term': 'the terminal: its output, the built-in terminal emulator, keys and mouse read from it',
    'sys': 'the operating system: processes, Windows, Landlock',
    'run': 'running things: jobs, the output panel, tasks, tests',
    'lsp': 'language servers: the client, their features, nimlangserver and nimsuggest',
    'nim': 'the Nim IDE: the engine (index/ is a module of its own), the engine worker, checks, macros, NIF, nimble, '
           'Nim 3',
    'c': 'ned\'s own C and C++ engine, C in Nim (emit, wrappers), clangd',
    'web': 'ned\'s own engines for CSS, HTML, SQL, JavaScript and JSON',
    'format': 'the formatters: Nim (nph-style), C, YAML, TOML, the others, nedfmt\'s command line',
    'git': 'git: the changes, commits, blame, merge, GitHub',
    'debug': 'the debugger: gdb, the Debug Adapter Protocol, the debug views',
    'ai': 'the AI assistant: providers, chat, the agent and its tools, MCP, inline suggestions',
    'plugins': 'the plugin host (host.nim) and the library plugins are written with (lib/)',
    'project': 'projects and workspaces: the file tree, project search, remote folders over SSH',
    'testing': 'test coverage and profiles read for the gutter',
    'nedls': 'nedls, ned\'s engines as a language server for other editors',
}


def describe(path):
    """the file's own first comment, as one plain sentence (decoration taken off)"""
    lines = []
    for raw in open(path, encoding='utf-8', errors='replace'):
        s = raw.strip()
        if not s:
            if lines: break
            continue
        if not s.startswith('#'): break
        s = s.lstrip('#').strip().strip('═─━').strip()
        if s: lines.append(s)
    text = ' '.join(lines)
    text = re.sub(r'\s+', ' ', text).strip(' —:.')
    m = re.match(r'(.{20,}?[.;])( |$)', text)
    if m and len(m.group(1)) < len(text): text = m.group(1).rstrip('.;')
    if len(text) > 170: text = text[:167].rsplit(' ', 1)[0] + ' …'
    return text.replace('|', '\\|')


def order():
    """the files of src/ned.nim: (relative path, 'include' or 'module', its place in the order)"""
    t = open(os.path.join(SRC, 'ned.nim'), encoding='utf-8').read()
    t = re.sub(r'(?m)#.*$', '', t)
    seen = {}
    n = 0
    for m in re.finditer(r'(?m)^\s*(include|import)\s+((?:ned/[\w/]+\s*,?\s*)+)', t):
        for name in re.findall(r'ned/[\w/]+', m.group(2)):
            rel = name + '.nim'
            if not os.path.exists(os.path.join(SRC, rel)) and os.path.isdir(os.path.join(SRC, name)):
                rel = name + '.nim'
            n += 1
            if rel not in seen: seen[rel] = (m.group(1), n)
    return seen


def build():
    """the page's text"""
    inc = order()
    files = []
    for dp, dn, fn in os.walk(os.path.join(SRC, 'ned')):
        dn[:] = sorted(d for d in dn if not d.startswith('.') and d != 'nimcache')
        for f in sorted(fn):
            if f.endswith('.nim'):
                files.append(os.path.relpath(os.path.join(dp, f), SRC).replace(os.sep, '/'))
    out = ['# The source, file by file', '',
           'Every source file of ned with what it is — the first comment of each file, so a file that says what it '
           'is well is described well here. *include N* is the file\'s place in `src/ned.nim`, which `include`s most '
           'files in order (each sees what the ones before it declare: a proc used earlier needs a forward '
           'declaration in [`app/forward.nim`](../../src/ned/app/forward.nim)); *module* is a part compiled on its '
           'own and imported. The rest belong to `nedls`, `nedfmt` or the plugin library, or are taken in by the '
           'module they are part of. [Architecture](architecture.md) says how the parts fit; this page is where to '
           'look for one.', '',
           'Made by `python3 tests/docs/sourcemap.py` from the sources (CI checks it is up to date) — run it after '
           'adding, moving or renaming a file.', '']
    out.append('| program | file | |')
    out.append('|---|---|---|')
    for p in ['ned.nim', 'nedls.nim', 'nedfmt.nim']:
        out.append('| `%s` | [`src/%s`](../../src/%s) | %s |' % (p[:-4], p, p, describe(os.path.join(SRC, p))))
    out.append('')
    by = {}
    for f in files:
        parts = f.split('/')
        folder = parts[1] if len(parts) > 2 else '.'
        by.setdefault(folder, []).append(f)
    for folder in sorted(by, key=lambda x: (x == '.', x)):
        title = folder if folder != '.' else 'src/ned'
        out.append('## %s' % title)
        out.append('')
        if folder in FOLDERS: out.append(FOLDERS[folder][0].upper() + FOLDERS[folder][1:] + '.')
        out.append('')
        out.append('| file | | what it is |')
        out.append('|---|---|---|')
        rows = []
        for f in by[folder]:
            kind, n = inc.get(f, ('', 10 ** 6))
            how = 'include %d' % n if kind == 'include' else 'module' if kind == 'import' else ''
            rows.append((n, f, how))
        for n, f, how in sorted(rows, key=lambda r: (r[0], r[1])):
            short = f[len('ned/'):]
            out.append('| [`%s`](../../src/%s) | %s | %s |' % (short, f, how, describe(os.path.join(SRC, f))))
        out.append('')
    return '\n'.join(out).rstrip('\n') + '\n'


def main():
    text = build()
    if '--check' in sys.argv:
        old = open(OUT, encoding='utf-8').read() if os.path.exists(OUT) else ''
        if old != text:
            print('docs/dev/source-map.md is not what the sources say: run python3 tests/docs/sourcemap.py')
            return 1
        print('docs/dev/source-map.md is up to date')
        return 0
    open(OUT, 'w', encoding='utf-8').write(text)
    print('wrote docs/dev/source-map.md (%d files)' % text.count('](../../src/'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
