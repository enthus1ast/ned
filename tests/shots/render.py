#!/usr/bin/env python3
"""render.py [NAME …] — the screenshots of ned's documentation (screenshots/NAME.png), drawn from their tmux captures
(screenshots/captures/NAME.ansi) in one font: every picture looks the same whichever machine took it.

A capture is `tmux capture-pane -e -N -p` of ned's screen (tests/shots/scenes.py takes them). It is drawn cell by cell
in the font NED_SHOT_FONT names (the Coder Nerd Font Mono's .ttf: the font of every screenshot; not in the
repository), 15 px on 20 px rows, at twice the size, framed on a dark ground, and kept in 256 colours. Several
captures named NAME@NN-label.ansi are drawn side by side, two across, each with its label under it (a theme gallery).
A capture taken without -N lost the spaces at each row's end: they get the background in force where the row stops
(tmux keeps the colour change before them).

Needs Python 3 with Playwright (its Chromium) and Pillow. With no NAME, every capture is drawn."""
import re, html, unicodedata, os, io, sys, glob, base64
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SHOTS = os.path.join(REPO, 'screenshots')
CAPTURES = os.path.join(SHOTS, 'captures')
PAL16 = ['000000', 'cd0000', '00cd00', 'cdcd00', '0000ee', 'cd00cd', '00cdcd', 'e5e5e5', '7f7f7f', 'ff0000', '00ff00',
         'ffff00', '5c5cff', 'ff00ff', '00ffff', 'ffffff']

def c256(n):
    """xterm's 256-colour palette entry n as rrggbb"""
    if n < 16: return PAL16[n]
    if n < 232:
        n -= 16; r, g, b = n // 36, (n // 6) % 6, n % 6
        f = lambda v: 0 if v == 0 else 55 + v * 40
        return '%02x%02x%02x' % (f(r), f(g), f(b))
    v = 8 + (n - 232) * 10; return '%02x%02x%02x' % (v, v, v)

def cellw(ch):
    """how many columns a character takes in the terminal"""
    return 2 if unicodedata.east_asian_width(ch) in ('W', 'F') else 1

def parse(text, dfg='d0d0d0', dbg='1e1e1e'):
    """the capture as rows of cells (char, fg, bg, bold, italic, underline, strike), a wide character followed by None
    for its second column; and for each row the background in force at its end"""
    st = dict(fg=None, bg=None, b=False, d=False, i=False, u=False, r=False, s=False)
    rows = []; ends = []
    for line in text.split('\n'):
        row = []
        for p in re.split(r'(\x1b\[[0-9;:]*m)', line):
            if p.startswith('\x1b['):
                ps = [int(x) if x else 0 for x in re.split('[;:]', p[2:-1])] or [0]
                k = 0
                while k < len(ps):
                    v = ps[k]
                    if v == 0: st.update(fg=None, bg=None, b=False, d=False, i=False, u=False, r=False, s=False)
                    elif v == 1: st['b'] = True
                    elif v == 2: st['d'] = True
                    elif v == 3: st['i'] = True
                    elif v == 4: st['u'] = True
                    elif v == 7: st['r'] = True
                    elif v == 9: st['s'] = True
                    elif v == 22: st['b'] = st['d'] = False
                    elif v == 23: st['i'] = False
                    elif v == 24: st['u'] = False
                    elif v == 27: st['r'] = False
                    elif v == 29: st['s'] = False
                    elif 30 <= v <= 37: st['fg'] = PAL16[v - 30]
                    elif 90 <= v <= 97: st['fg'] = PAL16[v - 82]
                    elif 40 <= v <= 47: st['bg'] = PAL16[v - 40]
                    elif 100 <= v <= 107: st['bg'] = PAL16[v - 92]
                    elif v == 39: st['fg'] = None
                    elif v == 49: st['bg'] = None
                    elif v in (38, 48):
                        if k + 1 < len(ps) and ps[k + 1] == 2:
                            col = '%02x%02x%02x' % tuple(ps[k + 2:k + 5]); k += 4
                        elif k + 1 < len(ps) and ps[k + 1] == 5:
                            col = c256(ps[k + 2]); k += 2
                        else: col = None
                        st['fg' if v == 38 else 'bg'] = col
                    k += 1
                continue
            for ch in p:
                fg = st['fg'] or dfg; bg = st['bg'] or dbg
                if st['r']: fg, bg = bg, fg
                if st['d']:     # faint: the colour blended toward the background, as a terminal draws it
                    a = [int(fg[i:i + 2], 16) for i in (0, 2, 4)]; c = [int(bg[i:i + 2], 16) for i in (0, 2, 4)]
                    fg = '%02x%02x%02x' % tuple(int(x * 0.6 + y * 0.4) for x, y in zip(a, c))
                row.append((ch, fg, bg, st['b'], st['i'], st['u'], st['s']))
                if cellw(ch) == 2: row.append(None)
        rows.append(row)
        ends.append((st['fg'] or dfg) if st['r'] else (st['bg'] or dbg))
    return rows, ends

def fill(parsed):
    """every row as wide as the widest, the dropped spaces in the background in force at the row's end"""
    rows, ends = parsed
    w = max(len(r) for r in rows)
    out = [list(r) for r in rows]
    for r, bg in zip(out, ends):
        r.extend([(' ', 'd0d0d0', bg, False, False, False, False)] * (w - len(r)))
    return out

def rowhtml(r):
    """one row of cells as spans, a span for each run of the same look"""
    out = []; run = []; key = None
    def flush():
        """the run so far as one span"""
        if not run: return
        fg, bg, b, i, u, s = key
        css = 'color:#%s;background:#%s;' % (fg, bg)
        if b: css += 'font-weight:bold;'
        if i: css += 'font-style:italic;'
        dec = ' '.join(x for x, on in (('underline', u), ('line-through', s)) if on)
        if dec: css += 'text-decoration:%s;' % dec
        out.append('<span style="%s">%s</span>' % (css, ''.join(run)))
    for c in r:
        if c is None: continue
        k = c[1:]
        if k != key: flush(); run = []; key = k
        ch = c[0]
        if ord(ch) < 128: run.append(html.escape(ch))
        else:
            run.append('<span class="c%d">%s</span>' % (cellw(ch), html.escape(ch)))
    flush()
    return ''.join(out) or '&nbsp;'

CSS = '''@font-face{font-family:Coder;src:url("data:font/ttf;base64,%s")}
body{margin:0;background:#0d0d10}
.f{display:inline-block;padding:14px;background:#0d0d10}
.w{display:inline-block;border-radius:10px;overflow:hidden;box-shadow:0 0 0 1px #2a2a33}
.t{font-family:Coder,monospace;font-size:15px;line-height:20px;white-space:pre;display:inline-block}
.r{height:20px;overflow:hidden}
.r span{display:inline-block;height:20px;line-height:20px;vertical-align:top}
.c1{width:1ch;text-align:center;overflow:visible}.c2{width:2ch;text-align:center;overflow:visible}
'''
_css = None

def css():
    """the page's style, with the font in it (NED_SHOT_FONT)"""
    global _css
    if _css is None:
        font = os.environ.get('NED_SHOT_FONT', '')
        if not os.path.isfile(font):
            sys.exit('render.py: set NED_SHOT_FONT to the .ttf of the Coder Nerd Font Mono (every screenshot is in it)')
        _css = CSS % base64.b64encode(open(font, 'rb').read()).decode()
    return _css

def page(ansi):
    """the capture as a framed HTML page"""
    rows = fill(parse(ansi[:-1] if ansi.endswith('\n') else ansi))
    body = ''.join('<div class="r">%s</div>' % rowhtml(r) for r in rows)
    return '<!doctype html><meta charset="utf-8"><style>%s</style><div class="f"><div class="w"><div class="t">%s' \
           '</div></div></div>' % (css(), body)

class Shooter:
    """one Chromium for many pictures"""
    def __enter__(self):
        """Chromium started, a page at twice the size"""
        from playwright.sync_api import sync_playwright
        self.p = sync_playwright().start(); self.b = self.p.chromium.launch()
        self.pg = self.b.new_page(viewport={'width': 800, 'height': 600}, device_scale_factor=2)
        return self
    def __exit__(self, *a):
        """Chromium closed"""
        self.b.close(); self.p.stop()
    def png(self, html_text, sel='.f'):
        """the element sel of the page as PNG bytes"""
        self.pg.set_content(html_text); self.pg.wait_for_timeout(150)
        self.pg.evaluate('document.fonts.ready')
        return self.pg.locator(sel).screenshot()

def save(png_bytes, dst):
    """a PNG in 256 colours (text pictures lose nothing that shows) — about a third of the size"""
    from PIL import Image
    im = Image.open(io.BytesIO(png_bytes)).convert('RGB')
    im.quantize(colors=256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE).save(dst, optimize=True)
    return dst

def tile_page(items, cols=2):
    """several captures in a grid, each with its name under it: items = [(name, ansi)]"""
    tiles = []
    for name, ansi in items:
        rows = fill(parse(ansi[:-1] if ansi.endswith('\n') else ansi))
        body = ''.join('<div class="r">%s</div>' % rowhtml(r) for r in rows)
        tiles.append('<figure><div class="w"><div class="t">%s</div></div><figcaption>%s</figcaption></figure>' %
                     (body, html.escape(name)))
    return ('<!doctype html><meta charset="utf-8"><style>%s .g{display:inline-grid;grid-template-columns:repeat(%d,auto);'
            'gap:16px 22px;padding:22px 24px 14px;background:#0d0d10}figure{margin:0}figcaption{font-family:Coder;'
            'color:#c9c9d1;font-size:16px;text-align:center;margin-top:6px}</style><div class="g">%s</div>' %
            (css(), cols, ''.join(tiles)))


def tiles_of(name):
    """the captures drawn side by side as NAME (NAME@NN-label.ansi, in their order), as [(label, ansi)]"""
    out = []
    for p in sorted(glob.glob(os.path.join(CAPTURES, glob.escape(name) + '@*.ansi'))):
        label = os.path.basename(p)[len(name) + 1:-5].split('-', 1)[-1]
        out.append((label, open(p, encoding='utf-8', errors='replace').read()))
    return out

def names():
    """every screenshot that has its capture"""
    out = set()
    for p in glob.glob(os.path.join(CAPTURES, '*.ansi')):
        out.add(os.path.basename(p)[:-5].split('@')[0])
    return sorted(out)

def draw(shooter, name):
    """screenshots/NAME.png from its capture (or its captures side by side)"""
    one = os.path.join(CAPTURES, name + '.ansi')
    dst = os.path.join(SHOTS, name + '.png')
    if os.path.exists(one):
        return save(shooter.png(page(open(one, encoding='utf-8', errors='replace').read())), dst)
    items = tiles_of(name)
    if not items: sys.exit('render.py: no capture of ' + name)
    return save(shooter.png(tile_page(items), '.g'), dst)

if __name__ == '__main__':
    todo = sys.argv[1:] or names()
    css()
    with Shooter() as s:
        for n in todo: print(draw(s, n))
