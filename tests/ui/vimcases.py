#!/usr/bin/env python3
"""What ned's vim mode is checked against: the cases, where each starts, and the keys as vim writes them.

A case is `(keys, line, col, edit)`: `keys` goes to ned and to vim alike, `line`/`col` is where it starts (both from 1),
and `edit` says whether the case changed the text — a movement is compared by where the cursor and the mode stand, an
edit by the text it left as well, and by the register when ned can show one.

The fixture is `fixtures/vim/oracle.txt`: long lines, a line that starts with a tab, indented lines, blank lines between
paragraphs, brackets and quotes, a tag with the other quotes, and trailing blanks — the shapes where a vim mode drifts
quietly away from vim.

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
# the motions a `c` is tried with: ones that find something from the grid's start, since a failed motion leaves what it
# typed as normal-mode keys (`cb`/`ck` from 1,1 fail, and vim then reads the typed text as commands)
C_MOTIONS = ['w', 'e', '$', 'j', 'iw', 'aw', 'ip', 'ap', 'G']
OP_STARTS = [(1, 1)]
# what a `c` case types once its motion took the text
TYPED = {'c': 'typed'}
# the edits vim's own single keys do (the keys are written as they are typed — no spaces to separate parts: a space
# is a key of its own, `l` in vim's normal mode)
SIMPLE = [('x', (1, 1)), ('X', (1, 5)), ('xx', (1, 1)), ('dd', (1, 1)), ('2dd', (1, 1)), ('yyp', (1, 1)),
          ('yyP', (1, 1)), ('D', (1, 5)), ('C', (1, 5)), ('s', (1, 1)), ('S', (2, 1)), ('A', (1, 1)),
          ('I', (2, 1)), ('a', (1, 1)), ('i', (1, 1)), ('o', (1, 1)), ('O', (2, 1)), ('J', (1, 1)),
          ('rZ', (1, 1)), ('~', (1, 1)), ('>>', (1, 1)), ('<<', (4, 1)), ('Vd', (1, 1)),
          ('dw.', (1, 1)), ('ihello', (1, 1)), ('ahello', (1, 1)),
          # (visual-line takes whole lines, its own line included — the last line of the selection is not left out when
          # the head stands at its start: `G` `k` `V` `j` `>` indents two lines, not one)
          ('GkVj>', (1, 1)), ('GVk>', (1, 1)), ('Vj>', (1, 1))]

# the text objects, after an operator (`diw`, `dap` …) and in visual mode (`vip`, then `d`), each from a place it is
# at. The fixture gives them something to work on: a paragraph and words on line 1, brackets, quotes and punctuation on
# line 2, WORDs on line 10, and a tag with the other quotes on line 15. (`it`/`at`, the tag, and `<`/`>` are vim's too.)
TEXT_OBJECTS = [('iw', 1, 5), ('aw', 1, 5), ('iW', 10, 3), ('aW', 10, 3), ('ip', 1, 5), ('ap', 1, 5),
                ('i(', 2, 55), ('a(', 2, 55), ('ib', 2, 55), ('ab', 2, 55),
                ('i[', 2, 66), ('a[', 2, 66), ('i{', 2, 74), ('a{', 2, 74), ('iB', 2, 74), ('aB', 2, 74),
                ('i"', 2, 83), ('a"', 2, 83), ("i'", 15, 24), ("a'", 15, 24), ('i`', 15, 36), ('a`', 15, 36),
                ('i<', 15, 5), ('a<', 15, 5), ('it', 15, 20), ('at', 15, 20)]
# the objects a `c` is tried with (what it types once the object is gone)
C_OBJECTS = ['iw', 'aw', 'ip', 'ap', 'i(', 'i"']

ESC = '\x1b'          # (every edit ends in normal mode: what is typed leaves insert mode)


def vim_keys(keys):
    """a case's keys as vim's `feedkeys` takes them: the characters as they are, `<Esc>` as the Escape key and
    `<Space>` as a space. `ned -es` takes the same string (src/ned/app/headless.nim)"""
    return keys.replace('<Space>', ' ').replace('<Esc>', ESC)


def _build():
    """the cases: the movements (from several places, with counts), the operator × motion grid, the text objects (after an
    operator and in visual mode), and the simple edits"""
    cases = []
    for line, col in STARTS:
        for m in MOVES:
            cases.append((m, line, col, False))
            if m in COUNTED:
                for n in COUNTS: cases.append(('%d%s' % (n, m), line, col, False))
    # (a count of a find: f or t, its character, then ; or , to repeat it)
    for m in ['fo', 'to', 'Fo', 'To', '2fo', '2to', 'fo;', 'fo,']:
        cases.append((m, 1, 1, False))
    for op in OPERATORS:
        for m in (C_MOTIONS if op == 'c' else OP_MOTIONS):
            for line, col in OP_STARTS:
                body = op + m + (TYPED[op] if op in TYPED else '')
                cases.append((body, line, col, True))
    # the text objects: `d` and `y` with each, `c` with a few, and `v` + the object + `d` (vim's `vip`, `vap`)
    for op in ['d', 'y']:
        for obj, line, col in TEXT_OBJECTS:
            cases.append((op + obj, line, col, True))
    for obj in C_OBJECTS:
        line, col = next((l, c) for o, l, c in TEXT_OBJECTS if o == obj)
        cases.append(('c' + obj + TYPED['c'], line, col, True))
    for obj, line, col in TEXT_OBJECTS:
        cases.append(('v' + obj + 'd', line, col, True))
    for keys, (line, col) in SIMPLE:
        cases.append((keys, line, col, True))
    # (an edit ends by leaving insert mode: `Esc` is added to those and to nothing else — a movement is not ended. No
    # space before it: a space is a key of its own in vim (it moves), and would be compared on the two sides)
    return [(k + '<Esc>' if e else k, l, c, e) for (k, l, c, e) in cases]


CASES = _build()


# (the cases ned and vim are still known to differ on: the case, and who is right — `ned` is a bug to fix, and the
# entry goes when the fix lands; `case` is a case the two may honestly read two ways, with the reason on it)
KNOWN_DIFFERS = {}


def main(argv):
    """the module on its own: every case, where it starts, and whether it is an edit"""
    for (keys, line, col, edit) in CASES:
        print('%-18r start %d,%-3d %s' % (keys, line, col, 'edit' if edit else 'move'))
    print('%d cases: %d movements, %d edits' % (len(CASES), sum(1 for c in CASES if not c[3]),
                                                sum(1 for c in CASES if c[3])))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
