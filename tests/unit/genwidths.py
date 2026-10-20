#!/usr/bin/env python3
"""The display-width tables of src/ned/core/text.nim, from the Unicode data of the Python running it.

  python3 tests/unit/genwidths.py > /tmp/widths.nim     then paste the two tables over the old ones

Zero width: marks (Mn, Me, the Hangul medial and final jamo) join the character before them; format characters
(Cf: ZWJ, the bidi marks, a BOM …) stand alone — except the soft hyphen and the prepended concatenation marks,
which glibc gives a column. Two columns: East Asian Wide and Fullwidth, the planes of CJK ideographs too.
"""
import unicodedata as u

PREPENDED = {0x600, 0x601, 0x602, 0x603, 0x604, 0x605, 0x6DD, 0x70F, 0x890, 0x891, 0x8E2, 0x110BD, 0x110CD}

def kind(cp):
    """0: not zero-width · 1: a mark (joins the character before) · 2: a format character (stands alone)"""
    if 0xD800 <= cp <= 0xDFFF or cp in PREPENDED or cp == 0xAD: return 0
    if 0x1160 <= cp <= 0x11FF or 0xD7B0 <= cp <= 0xD7FF: return 1
    c = u.category(chr(cp))
    return 1 if c in ('Mn', 'Me') else 2 if c == 'Cf' else 0

def wide(cp):
    if 0xD800 <= cp <= 0xDFFF: return False
    if 0x20000 <= cp <= 0x2FFFD or 0x30000 <= cp <= 0x3FFFD: return True
    return u.east_asian_width(chr(cp)) in ('W', 'F')

def main():
    zr, start, sk = [], None, 0
    for cp in range(0x300, 0x110001):
        k = kind(cp) if cp < 0x110000 else 0
        if start is not None and k != sk:
            zr.append((start, cp - 1, sk))
            start = None
        if k and start is None:
            start, sk = cp, k
    wr, start = [], None
    for cp in range(0x300, 0x110001):
        w = wide(cp) if cp < 0x110000 else False
        if w and start is None: start = cp
        if not w and start is not None:
            wr.append((start, cp - 1))
            start = None

    def emit(name, typ, items, fmt):
        lines, cur = [], "  "
        for it in items:
            item = fmt(it) + ", "
            if len(cur) + len(item) > 118:
                lines.append(cur.rstrip())
                cur = "  "
            cur += item
        lines.append(cur.rstrip().rstrip(','))
        return "const %s: array[%d, %s] = [\n%s]" % (name, len(items), typ, "\n".join(lines))

    print("# (Unicode %s)" % u.unidata_version)
    print(emit("ZeroRanges", "(int32, int32, int8)", zr, lambda t: "(0x%X, 0x%X, %d)" % t))
    print()
    print(emit("WideRanges", "(int32, int32)", wr, lambda t: "(0x%X, 0x%X)" % t))

main()
