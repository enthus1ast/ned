"""A tiny terminal emulator for what ned sends: CUP, SGR, CUF, DECSTBM, LF, RI, CR, text. Enough to check the
frames ned writes against a full redraw."""
import re, unicodedata

def wcwidth(ch):
    o = ord(ch)
    if o == 0: return 0
    if unicodedata.east_asian_width(ch) in ('W', 'F'): return 2
    return 1

class VT:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.cells = [[(' ', None, None, frozenset()) for _ in range(w)] for _ in range(h)]
        self.x = self.y = 0
        self.top, self.bot = 0, h - 1
        self.fg = self.bg = None
        self.at = frozenset()
        self.buf = b''
    def scroll_up(self):
        r = self.cells.pop(self.top)
        self.cells.insert(self.bot, [(' ', None, self.bg, frozenset()) for _ in range(self.w)])
    def scroll_down(self):
        self.cells.pop(self.bot)
        self.cells.insert(self.top, [(' ', None, self.bg, frozenset()) for _ in range(self.w)])
    def sgr(self, ps):
        k = 0
        if not ps: ps = [0]
        while k < len(ps):
            v = ps[k]
            if v == 0: self.fg = self.bg = None; self.at = frozenset()
            elif v in (38, 48) and k + 4 < len(ps) + 0 and len(ps) > k + 1 and ps[k + 1] == 2:
                c = tuple(ps[k + 2:k + 5])
                if v == 38: self.fg = c
                else: self.bg = c
                k += 4
            elif v in (38, 48) and len(ps) > k + 2 and ps[k + 1] == 5:
                if v == 38: self.fg = ('i', ps[k + 2])
                else: self.bg = ('i', ps[k + 2])
                k += 2
            elif v == 39: self.fg = None
            elif v == 49: self.bg = None
            elif v in (1, 2, 3, 4, 7, 9): self.at = self.at | {v}
            elif v == 22: self.at = self.at - {1, 2}
            elif v in (23, 24, 27, 29): self.at = self.at - {{23: 3, 24: 4, 27: 7, 29: 9}[v]}
            k += 1
    def put(self, ch):
        wd = wcwidth(ch)
        if self.x >= self.w: return            # (no autowrap: ned turns it off)
        self.cells[self.y][self.x] = (ch, self.fg, self.bg, self.at)
        if wd == 2 and self.x + 1 < self.w: self.cells[self.y][self.x + 1] = ('', self.fg, self.bg, self.at)
        self.x += wd
    def feed(self, data):
        self.buf += data
        s = self.buf.decode('utf-8', 'ignore')
        # keep an incomplete escape for later
        cut = len(s)
        k = s.rfind('\x1b')
        if k >= 0 and not re.match(r'\x1b(\[[0-9;?]*[@-~]|\][^\x07]*\x07|[^\[\]])', s[k:]): cut = k
        self.buf = s[cut:].encode()
        s = s[:cut]
        i = 0
        while i < len(s):
            c = s[i]
            if c == '\x1b':
                m = re.match(r'\x1b\[([0-9;?]*)([@-~])', s[i:])
                if m:
                    p, f = m.group(1), m.group(2)
                    i += m.end()
                    if p.startswith('?'): continue
                    ps = [int(x) if x else 0 for x in p.split(';')] if p else []
                    if f == 'H':
                        self.y = (ps[0] if ps and ps[0] else 1) - 1
                        self.x = (ps[1] if len(ps) > 1 and ps[1] else 1) - 1
                    elif f == 'm': self.sgr(ps)
                    elif f == 'C': self.x = min(self.w - 1, self.x + (ps[0] if ps and ps[0] else 1))
                    elif f == 'r':
                        self.top = (ps[0] if ps and ps[0] else 1) - 1
                        self.bot = (ps[1] if len(ps) > 1 and ps[1] else self.h) - 1
                        self.x = self.y = 0
                    elif f == 'J' and ps and ps[0] == 2:
                        self.cells = [[(' ', None, self.bg, frozenset()) for _ in range(self.w)] for _ in range(self.h)]
                    continue
                m = re.match(r'\x1b\][^\x07]*\x07', s[i:])
                if m: i += m.end(); continue
                if s[i:i + 2] == '\x1bM':
                    if self.y == self.top: self.scroll_down()
                    elif self.y > 0: self.y -= 1
                    i += 2; continue
                i += 2; continue
            if c == '\n':
                if self.y == self.bot: self.scroll_up()
                elif self.y < self.h - 1: self.y += 1
            elif c == '\r': self.x = 0
            elif c >= ' ': self.put(c)
            i += 1
    def visible(self, rows=None):
        out = []
        for r in (rows if rows is not None else range(self.h)):
            row = []
            for (ch, fg, bg, at) in self.cells[r]:
                shows = at & {4, 7, 9}
                row.append((ch, fg if ch != ' ' or shows else None, bg, at if ch != ' ' else frozenset(shows)))
            out.append(row)
        return out
