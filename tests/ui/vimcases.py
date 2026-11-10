#!/usr/bin/env python3
"""What ned's vim mode is checked against: the cases, where each starts, and the keys as vim writes them.

A case is `(keys, line, col, edit)`: `keys` goes to ned and to vim alike, `line`/`col` is where it starts (both from 1),
and `edit` says whether the case changed the text — a movement is compared by where the cursor and the mode stand, an
edit by the text it left as well, and by the register when ned can show one.

The fixture is `fixtures/vim/oracle.txt`: long lines, a line that starts with a tab, indented lines, blank lines between
paragraphs, brackets and quotes, and trailing blanks — the shapes where a vim mode drifts quietly away from vim.

    python3 tests/ui/vimcases.py --list     # every case, where it starts, and whether it is an edit
    python3 tests/ui/vimoracle.py --json OUT  # the same cases, answered by a real vim
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURE = os.path.join(HERE, 'fixtures', 'vim', 'oracle.txt')

# ── the cases, made from the lists below ──
# (where a movement is tried from: (line, col), both from 1)
STARTS = [(1, 1), (2, 5), (5, 1), (6, 3), (8, 1)]
# the movements, and the counts they are tried with (vim's `h` takes none, so it is given none)
MOVES = ['h', 'l', 'j', 'k', 'w', 'W', 'b', 'B', 'e', 'E', '0', '^', '$', 'gg', 'G', '{', '}', '%', ';', ',']
COUNTED = ['l', 'j', 'k', 'w', 'W', 'b', 'B', 'e', 'E', 'G', '{', '}']
COUNTS = [2]
# the operators and the motions they are tried with (a text object after an operator is one dialog: `diw`, `ci"`)
OPERATORS = ['d', 'c', 'y', '>', '<']
OP_MOTIONS = ['w', 'e', 'b', '$', 'j', 'k', 'iw', 'aw', 'i(', 'i"', 'ip', 'ap', 'G']
OP_STARTS = [(1, 1)]
# what a `c` case types once its motion took the text
TYPED = {'c': 'typed'}
# the edits vim's own single keys do
SIMPLE = [('x', (1, 1)), ('X', (1, 5)), ('xx', (1, 1)), ('dd', (1, 1)), ('2dd', (1, 1)), ('yy p', (1, 1)),
          ('Y P', (1, 1)), ('D', (1, 5)), ('C', (1, 5)), ('s', (1, 1)), ('S', (2, 1)), ('A', (1, 1)),
          ('I', (2, 1)), ('a', (1, 1)), ('i', (1, 1)), ('o', (1, 1)), ('O', (2, 1)), ('J', (1, 1)),
          ('r Z', (1, 1)), ('~', (1, 1)), ('>>', (1, 1)), ('<<', (4, 1)), ('vip d', (1, 1)), ('V d', (1, 1)),
          ('dw .', (1, 1)), ('i hello', (1, 1)), ('a hello', (1, 1))]

ESC = '\x1b'          # (every edit ends in normal mode: what is typed leaves insert mode)


def vim_keys(keys):
    """a case's keys as vim's `feedkeys` takes them: the same characters — `<Esc>` as the Escape key, and the keys of one
    dialog ('2 f j' is `2f j`) as one string"""
    return keys.replace('<Esc>', ESC)


def keys_of(keys):
    """a case's keys, one dialog each, as the tests send them to ned: '2f j' is '2', 'f', ' ', 'j'; 'f j' is 'f', ' ', 'j'"""
    out, i = [], 0
    while i < len(keys):
        if keys.startswith('<Esc>', i): out.append('Escape'); i += 5; continue
        out.append(keys[i]); i += 1
    return out


def _build():
    """the cases: the movements (from several places, with counts), the operator × motion grid, and the simple edits"""
    cases = []
    for line, col in STARTS:
        for m in MOVES:
            cases.append((m, line, col, False))
            if m in COUNTED:
                for n in COUNTS: cases.append(('%d%s' % (n, m), line, col, False))
    # (a count of a find: f and its character once)
    for m in ['f o', 't o', 'F o', 'T o', '2f o', '2f j', 'f o ;', 'f o ,']:
        cases.append((m, 1, 1, False))
    for op in OPERATORS:
        for m in OP_MOTIONS:
            for line, col in OP_STARTS:
                body = op + ' ' + m + (' ' + TYPED[op] if op in TYPED else '')
                cases.append((body, line, col, True))
    for keys, (line, col) in SIMPLE:
        cases.append((keys, line, col, True))
    # (an edit ends by leaving insert mode: `Esc` is added to those and to nothing else — a movement is not ended)
    return [(k + ' <Esc>' if e else k, l, c, e) for (k, l, c, e) in cases]


CASES = _build()


# (the cases ned and vim are still known to differ on: the case, and who is right — `ned` is a bug to fix, and the
# entry goes when the fix lands; `case` is a case the two may honestly read two ways, with the reason on it)
KNOWN_DIFFERS = {}


def ned_to_vim(line, viscol, tab=8):
    """vim's character column for the column ned's status bar shows. ned shows a *display* column (a tab moves the cursor
    to the next tab stop), vim's `col('.')` counts characters — on a line that starts with a tab, ned shows 5 for its
    second character, vim's column 2"""
    c, vimcol = 1, 1
    while c < viscol and vimcol <= len(line):
        c += tab - (c - 1) % tab if line[vimcol - 1] == '\t' else 1
        vimcol += 1
    return vimcol


def vim_to_ned(line, col, tab=8):
    """the column ned's status bar shows for vim's character column — the other way round"""
    c = 1
    for ch in line[:col - 1]:
        c += tab - (c - 1) % tab if ch == '\t' else 1
    return c


def read_lines(path):
    """a file as its lines, the file's final newline taken off the last"""
    with open(path, encoding='utf-8', newline='') as f:
        t = f.read()
    return t.split('\n')[:-1] if t.endswith('\n') else t.split('\n')


def main(argv):
    """the module on its own: every case, where it starts, and whether it is an edit"""
    for (keys, line, col, edit) in CASES:
        print('%-18r start %d,%-3d %s' % (keys, line, col, 'edit' if edit else 'move'))
    print('%d cases: %d movements, %d edits' % (len(CASES), sum(1 for c in CASES if not c[3]),
                                                sum(1 for c in CASES if c[3])))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
