#!/usr/bin/env python3
"""Every Nim file of ned says what it is, and every routine in it says what it does.

A file's first line that is not empty is a comment. A proc, func, method, iterator, converter, template or macro with
a body has a `##` comment as the first thing in it, or a comment on the line just above it (a routine on one line:
`# …` above). Forward declarations and routines without a name (`proc () = …`) are not counted, nor the UI tests' fixtures.

Usage: comments.py [--list] [paths…]     (default: src/, plugins/ and tests/; run it from the repository's folder)
  --list   each routine without its comment: file:line: its first line (for writing them)
Exit 1 when something has no comment."""
import os, re, sys

KINDS = ('proc', 'func', 'method', 'iterator', 'converter', 'template', 'macro')
DEF = re.compile(r'^([ \t]*)(?:' + '|'.join(KINDS) + r')\s+(`[^`]+`|[A-Za-z_\x80-\xff][\w\x80-\xff]*)')
SEPARATOR = re.compile(r'^\s*#+\s*[═─━=\-]{6,}\s*$')       # (a line of ═══ is a section's frame, not a comment on it)


class Scan:
    """what each line of a file is: code (and its code without strings and comments), in a string, in a comment"""

    def __init__(self, lines):
        self.code = []        # each line's code, strings blanked, comments removed; None: no code starts on it
        self.comment = []     # True: the line is a comment (nothing else on it)
        depth_block = 0
        in_triple = False
        for line in lines:
            out = []
            i, n = 0, len(line)
            started_in_string = in_triple
            only_comment = False
            while i < n:
                c = line[i]
                if depth_block:
                    if line.startswith(']#', i):
                        depth_block -= 1; i += 2; continue
                    if line.startswith('#[', i):
                        depth_block += 1; i += 2; continue
                    i += 1; continue
                if in_triple:
                    if line.startswith('"""', i) and not line.startswith('""""', i):
                        in_triple = False; out.append('"""'); i += 3; continue
                    i += 1; continue
                if line.startswith('#[', i) or line.startswith('##[', i):
                    if not ''.join(out).strip(): only_comment = True
                    depth_block += 1; i += 3 if line.startswith('##[', i) else 2; continue
                if c == '#':
                    if not ''.join(out).strip(): only_comment = True
                    break
                if line.startswith('"""', i):
                    in_triple = True; out.append('"""'); i += 3; continue
                if c == '"':
                    raw = i > 0 and (line[i - 1].isalnum() or line[i - 1] == '_')
                    j = i + 1
                    while j < n:
                        if line[j] == '\\' and not raw: j += 2; continue
                        if line[j] == '"':
                            if raw and j + 1 < n and line[j + 1] == '"': j += 2; continue
                            break
                        j += 1
                    out.append('""'); i = j + 1; continue
                if c == "'" and (i == 0 or not (line[i - 1].isalnum() or line[i - 1] == '_')):
                    m = re.match(r"'(\\x[0-9A-Fa-f]{2}|\\\d+|\\.|[^\\'])'", line[i:])
                    if m:
                        out.append("' '"); i += len(m.group(0)); continue
                out.append(c); i += 1
            self.code.append(None if started_in_string else ''.join(out))
            self.comment.append(only_comment and not started_in_string and not ''.join(out).strip())


OPS = set('=<>!:+-*/%&|^~.@$?\\')


def top_equals(code):
    """where the routine's `=` is in its signature's code (strings blanked): -1 when there is none"""
    depth = 0
    i, n = 0, len(code)
    while i < n:
        c = code[i]
        if c == '`':                                       # (an operator's name: `[]=`, `==`)
            j = code.find('`', i + 1)
            i = j + 1 if j > 0 else n; continue
        if c in '([{': depth += 1
        elif c in ')]}': depth -= 1
        elif c == '=' and depth == 0:
            prev = code[i - 1] if i > 0 else ' '
            nxt = code[i + 1] if i + 1 < n else ' '
            if prev not in OPS and nxt not in OPS: return i
        i += 1
    return -1


def routines(lines):
    """each routine with a body: (first line, the line its signature ends on, one line?, indentation, documented?)"""
    sc = Scan(lines)
    out = []
    i = 0
    while i < len(lines):
        code = sc.code[i]
        m = DEF.match(code) if code is not None else None
        if not m:
            i += 1; continue
        ind = len(m.group(1).expandtabs())
        # the signature: until its `=`, over the lines brackets keep open or that go on more indented
        j = i
        sig = code
        eq = top_equals(sig)
        while eq < 0 and j + 1 < len(lines):
            nxt = sc.code[j + 1]
            if nxt is None: break
            depth = sig.count('(') + sig.count('[') + sig.count('{') - sig.count(')') - sig.count(']') - sig.count('}')
            more = len(nxt) - len(nxt.lstrip()) > ind and nxt.strip()
            if depth <= 0 and not more and not sig.rstrip().endswith((',', ':')): break
            if not nxt.strip() and depth <= 0: break
            j += 1
            sig += ' ' + nxt
            eq = top_equals(sig)
        if eq < 0:                                          # (a forward declaration, or an importc: no body)
            i = j + 1; continue
        one_line = sig[eq + 1:].strip() != ''
        above = i - 1
        doc = above >= 0 and sc.comment[above] and not SEPARATOR.match(lines[above])
        if not doc:
            # (`##` first in the body — or, under a routine on one line, a `##` more indented than it)
            k = j + 1
            while k < len(lines) and not lines[k].strip() and not one_line: k += 1
            if k < len(lines) and lines[k].strip().startswith('##') and \
               (not one_line or len(lines[k]) - len(lines[k].lstrip()) > ind): doc = True
        if not doc and '##' in ''.join(lines[i:j + 1]): doc = True
        out.append((i, j, one_line, ind, doc))
        i = j + 1
    return out


def header_ok(lines):
    first = next((l for l in lines if l.strip()), '')
    return first.lstrip().startswith('#')


def nim_files(paths):
    for p in paths:
        if os.path.isfile(p):
            yield p; continue
        for dp, dn, fn in os.walk(p):
            # (the UI tests' fixtures are left as they are: the tests go to their lines by number)
            dn[:] = sorted(d for d in dn if not d.startswith('.') and d not in ('nimcache', 'node_modules', 'fixtures'))
            for f in sorted(fn):
                if f.endswith(('.nim', '.nims')): yield os.path.join(dp, f)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    listing = '--list' in sys.argv
    paths = args or ['src', 'plugins', 'tests']
    files = list(nim_files(paths))
    total = missing = heads = 0
    for p in files:
        lines = open(p, encoding='utf-8', errors='surrogateescape').read().split('\n')
        if not header_ok(lines):
            heads += 1
            if listing: print(f'{p}:1: (the file says what it is)')
        for (i, j, one, ind, doc) in routines(lines):
            total += 1
            if not doc:
                missing += 1
                if listing: print(f'{p}:{i + 1}: {lines[i].strip()[:150]}')
    if missing or heads:
        print(f'{missing} of {total} routines without a comment saying what they do, {heads} of {len(files)} files '
              'without one saying what the file is (comments.py --list shows where)')
        sys.exit(1)
    print(f'every file and every routine says what it is ({len(files)} files, {total} routines)')


if __name__ == '__main__':
    main()
