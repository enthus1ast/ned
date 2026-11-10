#!/usr/bin/env python3
"""ned's own vim mode, asked the way the oracle asks vim: the same file, the same cursor place, the same keys.

One ned runs per fixture, in vim mode, in the UI tests' tmux session. A case starts with the editor's own keys: Reload
from disk (`Ctrl+X` in these tests' settings — a keystroke, not a palette dialog), then `C-End`, `C-Home`, which put
the cursor at the start of the file whatever vim mode had pending from the case before. The case's keys go one by one,
and what is read back is ned's own state: the cursor and the mode from the status bar, and the text from the disk once
`:w` wrote it.

A case that leaves more behind than a changed text (another mode, another window) is run in a ned of its own — see
`fresh`. A case costs about 0.2 s this way; a start costs 1.4 s.

    n = Ned(setup, start, keys, text, screen, tm, W)   # the UI harness's own helpers
    n.start(fixture)                                   # one setup, one ned, the fixture
    n.case(keys, line, col, edit=True)                 # {'line', 'col', 'visual', 'text'}
    n.stop()
"""
import os
import re
import time

POS = re.compile(r'Ln (\d+), Col (\d+)')
MODE = re.compile(r'\b(NORMAL|INSERT|VISUAL|V-LINE|REPLACE)\b')
MODES = {'NORMAL': '', 'INSERT': 'i', 'VISUAL': 'v', 'V-LINE': 'V', 'REPLACE': 'R'}


class Ned:
    """ned in a tmux session of the UI tests' server, in vim mode, on a copy of a file"""

    def __init__(self, setup, start, keys, text, screen, tm, work):
        """the harness's own helpers — `setup(cfg)`, `start(file)`, `keys(*k)`, `text(s)`, `screen()`, `tm(*a)` — and
        the work folder they run in: ned runs in the tests' scratch folder, which is theirs"""
        self.h = dict(setup=setup, start=start, keys=keys, text=text, screen=screen, tm=tm, work=work)
        self.path = ''                  # the case's file, in the work folder
        self.src = ''                   # the file it is a copy of
        self.started = False

    # ── the session ──
    def start(self, src, name='case.txt'):
        """one setup and one ned, in vim mode, on a copy of `src` in the work folder (Reload from disk on Ctrl+X, as
        the tests use a keystroke there)"""
        self.h['setup']({"editor.vimMode": True, "editor.keymap": "vim", "nim.nimsuggest": False,
                         "security.folderTrust": "off", "keys": {"ctrl+x": "Reload from disk"}})
        self.src, self.path = src, name
        self.put()
        self.h['start'](name, w=120, h=30)
        time.sleep(0.3)
        self.started = True
        self.reset()
        return self

    def stop(self):
        """the session goes"""
        if self.started:
            self.h['keys']('Escape')
            self.h['tm']('kill-session', '-t', 'f')
            time.sleep(0.2)
        self.started = False

    def put(self):
        """the work folder's copy of the file, as `src` is"""
        with open(os.path.join(self.h['work'], self.path), 'w', encoding='utf-8', newline='') as f:
            f.write(open(self.src, encoding='utf-8', newline='').read())

    # ── keys ──
    def keys(self, *k):
        """keys as tmux names them ('w', 'Escape', 'C-r'), one after another, as the UI tests send them"""
        for x in k:
            self.h['keys'](x)

    def text(self, s):
        """literal text, typed"""
        self.h['text'](s)

    def reset(self):
        """the file as it was opened, and the cursor at its very start, in the running ned. The file is written again and
        read back by the palette's Reload from disk (`Ctrl+E`, its name, Enter), waited for by its first line on the
        screen, and then `C-End`, `C-Home`: editor motions, whose destination does not depend on what vim mode had
        pending before. Raises rather than let a case run on a screen that is not ready — a stall said at once beats a
        hundred cases read from the wrong place."""
        self.put()
        self.h['keys']('Escape'); time.sleep(0.25)        # (no dialog of a case before may still be open)
        self.h['keys']('C-e')
        end = time.time() + 2.0
        while time.time() < end:                          # (the palette takes its keys once it is drawn)
            if 'Command palette' in self.h['screen'](): break
            time.sleep(0.03)
        self.h['text']('Reload from disk'); time.sleep(0.35)
        self.h['keys']('Enter'); time.sleep(0.25)
        if 'Command palette' in self.h['screen']():
            raise RuntimeError('the palette did not close after Reload from disk:\n' +
                               '\n'.join(self.h['screen']().split('\n')[:4]))
        first = open(self.src, encoding='utf-8').read().split('\n')[0][:20]
        end = time.time() + 3.0
        while time.time() < end:                          # (read again in the background: its own first line is back)
            if first and first in self.h['screen'](): break
            time.sleep(0.03)
        self.h['keys']('C-End', 'C-Home')
        time.sleep(0.05)
        if self.pos() != (1, 1):
            raise RuntimeError('the reset did not reach the start of the file: %r' % (self.pos(),))
        return self

    def dialog_open(self):
        """whether Go to line's prompt is still open — its keys would go there instead of the editor"""
        s = self.h['screen']()
        return 'Go to line' in s or 'Type a line number' in s

    def goto(self, line, col):
        """the cursor at a line and a column, both from 1, as vim counts them — with Go to line (a dialog, ~0.6 s, so a
        case that starts at 1,1 does not pay for it)"""
        if (line, col) == (1, 1): return self
        self.h['keys']('Escape', 'C-g')
        self.h['text']('%d:%d' % (line, col))
        self.h['keys']('Enter')
        time.sleep(0.1)
        if self.dialog_open() or self.pos() != (line, col):
            raise RuntimeError('Go to line %d:%d did not take: at %r, dialog %s' % (
                line, col, self.pos(), self.dialog_open()))
        return self

    # ── one case ──
    def case(self, keys, line=1, col=1, edit=False):
        """one case in the running ned: the file and cursor put back, the case's keys, and ned's state after them"""
        self.reset().goto(line, col)
        self.keys(*keys)
        return self.state(edit)

    def fresh(self, keys, line=1, col=1, edit=False):
        """one case in a ned of its own — for a case that leaves something a reload does not undo (an opened window, a
        mode the editor will not leave)"""
        self.h['keys']('Escape')
        self.h['tm']('kill-session', '-t', 'f')
        time.sleep(0.2)
        self.put()
        self.h['start'](self.path, w=120, h=30)
        time.sleep(0.3)
        self.goto(line, col)
        self.keys(*keys)
        return self.state(edit)

    # ── what it answers ──
    def pos(self, t=2.0):
        """(line, col) from ned's status bar, both from 1 — what the oracle's `line` and `col` are"""
        end = time.time() + t
        while True:
            m = POS.search(self.h['screen']())
            if m or time.time() >= end:
                return (int(m.group(1)), int(m.group(2))) if m else (None, None)
            time.sleep(0.03)

    def mode(self):
        """the mode from ned's status bar: 'v', 'V', 'i' or 'R', as the oracle's `visual` and insert mode say it — ''
        in normal mode"""
        for row in reversed(self.h['screen']().splitlines()):
            m = MODE.search(row)
            if m: return MODES[m.group(1)]
        return ''

    def lines(self):
        """the file as ned has it on disk: its lines, the file's final newline taken off the last"""
        with open(os.path.join(self.h['work'], self.path), encoding='utf-8', newline='') as f:
            t = f.read()
        return t.split('\n')[:-1] if t.endswith('\n') else t.split('\n')

    def ftext(self):
        """the file as ned has it, written out first (`:w`): the lines the case left"""
        self.h['keys']('Escape')
        self.h['text'](':w')
        self.h['keys']('Enter')
        end = time.time() + 2.0
        want = None
        while time.time() < end:
            got = self.lines()
            if got == want: break               # (the same twice in a row: the save has landed)
            want = got
            time.sleep(0.04)
        return want or []

    def state(self, edit=True):
        """the case's answer, in the oracle's words: the cursor, the mode, and (for an edit) the text — the text asked
        for first, `:w` being a command that leaves the mode's own counts and operators alone"""
        text = self.ftext() if edit else None
        line, col = self.pos()
        return {'line': line, 'col': col, 'visual': self.mode(), 'text': text}
