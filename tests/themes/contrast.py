#!/usr/bin/env python3
"""Every built-in theme's colours against its background (WCAG contrast ratios), and how far apart its syntax
colours are (CIE76 ΔE). ned's own themes must pass:
  text 7:1 or more · keywords, types, strings, numbers, functions, macros, properties, errors 4.5:1 ·
  comments and operators 3:1 · no two syntax colours closer than ΔE 12 (one-colour themes aside, and the themes ned
  took in for Foxoman — Shades of Purple, ClassicBlue, Nebula — which must read, their design kept)
The sunlight themes, stricter: text 10:1 · every syntax colour 7:1 · comments, operators, errors, warnings and ok
4.5:1 · no two syntax colours closer than ΔE 20. The e-ink themes: black and white only, not one colour between.
The themes ned copies from elsewhere are listed for information (ned's makeReadable lifts their interface colours).
Run: python3 tests/themes/contrast.py   (exit 1 when one of ned's own themes fails)"""
import itertools, math, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, '..', '..', 'src', 'ned', 'core', 'themes.nim')
OWN = ['nim-crown', 'frankincense', 'desert-dusk', 'lagoon', 'sea-glass', 'paper-ink', 'rose-quartz', 'amber-crt',
       'green-phosphor', 'oled-black', 'oled-warm', 'oled-dim', 'lcd-soft', 'lcd-warm', 'lcd-paper',
       'sunlight', 'sunlight-warm', 'sunlight-blue', 'e-ink', 'e-ink-dark']
# (6.32: for a tablet in sunlight — stricter than the rest)
SUN = ['sunlight', 'sunlight-warm', 'sunlight-blue']
# (6.32: for an e-ink screen, which shows a grey as dithering — black and white only)
INK = ['e-ink', 'e-ink-dark']
# (6.30: themes ned took in for Foxoman — their colours lifted to read, their design as it was: two syntax colours
# may be the same or near, as their authors made them)
READ = ['shades-of-purple', 'shades-of-purple-super-dark', 'classic-blue', 'nebula-pulse', 'nebula-nova', 'nebula-nord',
        'nebula-serenity', 'nebula-glow', 'nebula-dawn']
MONO = ['amber-crt', 'green-phosphor', 'monochrome', 'monochrome-light', 'e-ink', 'e-ink-dark']
NAMES = 'bg fg accent sel comment keyword type string number func operator macro property error warning ok'.split()

def lum(c):
    def ch(v):
        x = v / 255
        return x / 12.92 if x <= 0.03928 else ((x + 0.055) / 1.055) ** 2.4
    return 0.2126 * ch((c >> 16) & 255) + 0.7152 * ch((c >> 8) & 255) + 0.0722 * ch(c & 255)

def ratio(a, b):
    x, y = lum(a), lum(b)
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)

def lab(c):
    def lin(v):
        v /= 255
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = lin((c >> 16) & 255), lin((c >> 8) & 255), lin(c & 255)
    x = (r * 0.4124 + g * 0.3576 + b * 0.1805) / 0.95047
    y = r * 0.2126 + g * 0.7152 + b * 0.0722
    z = (r * 0.0193 + g * 0.1192 + b * 0.9505) / 1.08883
    f = lambda t: t ** (1 / 3) if t > 0.008856 else 7.787 * t + 16 / 116
    return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))

def blend(a, b, t):
    return sum(round(((a >> s) & 255) * (1 - t) + ((b >> s) & 255) * t) << s for s in (16, 8, 0))

def themes():
    src = open(SRC).read()
    for m in re.finditer(r'mkTheme\("([\w-]+)",\s*(true|false),((?:\s*0x[0-9A-Fa-f]{6},?){16})', src):
        cols = [int(x, 16) for x in re.findall(r'0x([0-9A-Fa-f]{6})', m.group(3))]
        yield m.group(1), dict(zip(NAMES, cols))
    # one-colour terminals: phosphorTheme(name, bg, fg, bright, dim, comment, err, warn) — derived as themes.nim does
    for m in re.finditer(r'phosphorTheme\("([\w-]+)",((?:\s*0x[0-9A-Fa-f]{6},?){7})', src):
        bg, fg, br, dm, cm, er, wr = [int(x, 16) for x in re.findall(r'0x([0-9A-Fa-f]{6})', m.group(2))]
        yield m.group(1), dict(bg=bg, fg=fg, accent=br, sel=blend(bg, fg, 0.2), comment=cm, keyword=br,
                               type=blend(fg, br, 0.55), string=blend(fg, dm, 0.45), number=blend(fg, br, 0.3),
                               func=blend(fg, 0xFFFFFF, 0.45), operator=dm, macro=blend(fg, br, 0.75),
                               property=blend(fg, dm, 0.2), error=er, warning=wr, ok=br)

def main():
    failed = []
    print('%-22s %6s %6s %6s %6s %6s %6s  %s' % ('theme', 'text', 'kw', 'type', 'string', 'cmt', 'sel', 'problems'))
    seen = set()
    for name, c in themes():
        seen.add(name)
        bg = c['bg']
        bad = []
        for k in NAMES[1:]:
            if k in ('sel', 'accent', 'ok', 'warning'): continue
            need = 7.0 if k == 'fg' else 3.0 if k in ('comment', 'operator') else 4.5
            r = ratio(c[k], bg)
            if r < need: bad.append('%s %.2f<%s' % (k, r, need))
        syn = ['keyword', 'type', 'string', 'number', 'func', 'macro', 'property']
        if name in SUN:
            for k in NAMES[1:]:
                if k in ('sel', 'accent'): continue
                need = 10.0 if k == 'fg' else 7.0 if k in syn else 4.5
                r = ratio(c[k], bg)
                if r < need: bad.append('%s %.2f<%s' % (k, r, need))
        if name in INK:
            for k in NAMES:
                if c[k] not in (0x000000, 0xFFFFFF): bad.append('%s #%06X is not black or white' % (k, c[k]))
        if name not in MONO and name not in READ:
            least = 20 if name in SUN else 12
            for a, b in itertools.combinations(syn, 2):
                d = math.dist(lab(c[a]), lab(c[b]))
                if c[a] != c[b] and d < least: bad.append('%s/%s ΔE %.1f' % (a, b, d))
        own = name in OWN or name in READ
        if own and bad: failed.append(name)
        print('%-22s %6.2f %6.2f %6.2f %6.2f %6.2f %6.2f  %s%s' % (
            name + (' *' if own else ''), ratio(c['fg'], bg), ratio(c['keyword'], bg), ratio(c['type'], bg),
            ratio(c['string'], bg), ratio(c['comment'], bg), ratio(c['sel'], bg), ', '.join(bad),
            '  ← FAILS' if own and bad else ''))
    print('\n* ned\'s own themes, and those it took in (must pass)')
    missing = [n for n in OWN + READ if n not in seen]
    if missing:
        print('not found in themes.nim: ' + ', '.join(missing))
        failed += missing
    if failed:
        print('failing: ' + ', '.join(failed))
        sys.exit(1)

if __name__ == '__main__':
    main()
