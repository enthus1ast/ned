#!/usr/bin/env python3
"""Makes the pictures tests/unit/timages.nim reads, and next to each the RGBA it should decode to.

PNG, BMP and GIF files are written here byte by byte (every colour type and depth, the five PNG filters, Adam7, the
three kinds of deflate block, BMP's headers, bit fields and RLE, GIF's local colour tables), their expected pixels
worked out from what was written and checked against PIL. JPEG files are written by PIL, and by a small baseline
encoder below for the sampling factors and scan layouts PIL cannot write; their expected pixels are PIL's (libjpeg's).

    python3 tests/unit/images/make.py           # the fixtures and manifest.txt (small: they are committed)
    python3 tests/unit/images/make.py --big     # also big.jpg, a 4000 × 3000 photo-like JPEG (not committed)

Needs Pillow and numpy. Everything is made from fixed seeds: running it again makes the same files.
"""

import io
import os
import struct
import sys
import zlib

import numpy as np
from PIL import Image, ImageOps

HERE = os.path.dirname(os.path.abspath(__file__))
W, H = 37, 23
manifest = []          # (file, expected .rgba, w, h, frames, kind)
written_rgba = {}


def out(name, data):
    with open(os.path.join(HERE, name), "wb") as f:
        f.write(data)


def expect(name, rgba):
    """the expected pixels, shared by every file that should decode to them"""
    rgba = np.ascontiguousarray(rgba, dtype=np.uint8)
    if name in written_rgba:
        assert np.array_equal(written_rgba[name], rgba), name
        return
    written_rgba[name] = rgba
    out(name, rgba.tobytes())


def add(file, exp, rgba, kind="exact", frames=1):
    expect(exp, rgba)
    manifest.append((file, exp, rgba.shape[1], rgba.shape[0], frames, kind))


def pil_rgba(data):
    return np.asarray(Image.open(io.BytesIO(data)).convert("RGBA"))


def same_visible(a, b):
    """equal, transparent pixels' colour aside"""
    a = a.copy()
    b = b.copy()
    a[a[..., 3] == 0] = 0
    b[b[..., 3] == 0] = 0
    return np.array_equal(a, b)


# ── source pictures ──

def photo(w, h, seed, noise=6.0):
    """smooth colour, a few soft shapes and some grain: something like a photograph"""
    rng = np.random.default_rng(seed)
    y, x = np.mgrid[0:h, 0:w].astype(np.float64)
    r = 128 + 100 * np.sin(x / w * 3.1 + 0.5) * np.cos(y / h * 2.3)
    g = 90 + 120 * (y / h) + 30 * np.sin((x + y) / 7.0)
    b = 200 - 150 * (x / w) + 25 * np.cos(x / 5.0 - y / 9.0)
    for _ in range(4):
        cx, cy, rad = rng.uniform(0, w), rng.uniform(0, h), rng.uniform(min(w, h) / 6, min(w, h) / 2.5)
        col = rng.uniform(0, 255, 3)
        m = np.clip(1.2 - np.hypot(x - cx, y - cy) / rad, 0, 1)
        r, g, b = r * (1 - m) + col[0] * m, g * (1 - m) + col[1] * m, b * (1 - m) + col[2] * m
    img = np.stack([r, g, b], -1) + rng.normal(0, noise, (h, w, 3))
    return np.clip(np.rint(img), 0, 255).astype(np.uint8)


def with_alpha(rgb, seed):
    h, w = rgb.shape[:2]
    rng = np.random.default_rng(seed)
    y, x = np.mgrid[0:h, 0:w]
    a = np.clip((x * 255) // max(1, w - 1) + rng.integers(-20, 20, (h, w)), 0, 255)
    a[:, :3] = 0
    a[:, -3:] = 255
    return np.dstack([rgb, a.astype(np.uint8)])


def rgba_of(rgb, alpha=255):
    return np.dstack([rgb, np.full(rgb.shape[:2], alpha, np.uint8)])


def indices(w, h, n, seed):
    rng = np.random.default_rng(seed)
    y, x = np.mgrid[0:h, 0:w]
    idx = (x * 3 + y * 7 + (x * y) // 5) % n
    flips = rng.random((h, w)) < 0.15
    idx[flips] = rng.integers(0, n, flips.sum())
    return idx.astype(np.uint8)


def palette(n, seed):
    return np.random.default_rng(seed).integers(0, 256, (n, 3)).astype(np.uint8)


# ── PNG ──

ADAM7 = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]


def chunk(kind, body):
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))


def pack_rows(samples, depth):
    """samples (h, w, c) as PNG rows of bytes"""
    rows = []
    for row in samples:
        flat = row.reshape(-1).astype(np.int64)
        if depth == 16:
            rows.append(b"".join(struct.pack(">H", int(v)) for v in flat))
        elif depth == 8:
            rows.append(bytes(int(v) for v in flat))
        else:
            bits = "".join(format(int(v), "0%db" % depth) for v in flat)
            bits += "0" * (-len(bits) % 8)
            rows.append(bytes(int(bits[i:i + 8], 2) for i in range(0, len(bits), 8)))
    return rows


def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    return a if pa <= pb and pa <= pc else (b if pb <= pc else c)


def filtered(rows, bpp, start):
    """every row with a filter of its own, the five in turn"""
    res = b""
    prev = None
    for k, row in enumerate(rows):
        ft = (start + k) % 5
        o = bytearray(len(row))
        for i in range(len(row)):
            a = row[i - bpp] if i >= bpp else 0
            b = prev[i] if prev is not None else 0
            c = prev[i - bpp] if prev is not None and i >= bpp else 0
            p = [0, a, b, (a + b) // 2, paeth(a, b, c)][ft]
            o[i] = (row[i] - p) & 255
        res += bytes([ft]) + bytes(o)
        prev = row
    return res


def png(samples, ctype, depth, plte=None, trns=None, interlace=False, level=9, strategy=zlib.Z_DEFAULT_STRATEGY,
        split=0):
    h, w = samples.shape[:2]
    ch = samples.shape[2]
    bpp = max(1, ch * depth // 8)
    if interlace:
        raw = b""
        n = 0
        for x0, y0, dx, dy in ADAM7:
            sub = samples[y0::dy, x0::dx]
            if sub.shape[0] and sub.shape[1]:
                rows = pack_rows(sub, depth)
                raw += filtered(rows, bpp, n)
                n += len(rows)
    else:
        raw = filtered(pack_rows(samples, depth), bpp, 0)
    co = zlib.compressobj(level, zlib.DEFLATED, 15, 9, strategy)
    z = co.compress(raw) + co.flush()
    d = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, depth, ctype, 0, 0, int(interlace)))
    d += chunk(b"tEXt", b"Comment\0ned test picture")
    if plte is not None:
        d += chunk(b"PLTE", plte.astype(np.uint8).tobytes())
    if trns is not None:
        d += chunk(b"tRNS", trns)
    if split:
        for i in range(0, len(z), split):
            d += chunk(b"IDAT", z[i:i + split])
    else:
        d += chunk(b"IDAT", z)
    return d + chunk(b"IEND", b"")


def make_png():
    rgb = photo(W, H, 1)
    rgba = with_alpha(rgb, 2)
    grey8 = (rgb.astype(np.int64) @ [77, 150, 29] >> 8).astype(np.uint8)
    lo = np.random.default_rng(3).integers(0, 256, (H, W, 4))
    # 16 bits: the high byte the 8-bit picture, the low byte noise (the decoder must take the high one)
    rgba16 = rgba.astype(np.int64) * 256 + lo
    pal256 = palette(256, 4)
    idx256 = indices(W, H, 256, 5)

    def grey_rgba(g, a=255):
        return np.dstack([g, g, g, np.full(g.shape, a, np.uint8) if np.isscalar(a) else a]).astype(np.uint8)

    for depth in (1, 2, 4, 8):
        n = 1 << depth
        g = indices(W, H, n, 10 + depth)
        scale = 255 // (n - 1)
        exp = grey_rgba((g.astype(np.int64) * scale).astype(np.uint8))
        add("png_g%d.png" % depth, "png_g%d.rgba" % depth, exp)
        out("png_g%d.png" % depth, png(g[..., None], 0, depth))
        out("png_g%d_i.png" % depth, png(g[..., None], 0, depth, interlace=True))
        add("png_g%d_i.png" % depth, "png_g%d.rgba" % depth, exp)
        p = palette(n, 20 + depth)
        pi = indices(W, H, n, 30 + depth)
        exp = rgba_of(p[pi])
        out("png_p%d.png" % depth, png(pi[..., None], 3, depth, plte=p))
        add("png_p%d.png" % depth, "png_p%d.rgba" % depth, exp)
    # grey with tRNS (8 and 2 bits), 16-bit grey
    g = grey8.copy()
    key = int(g[5, 5])
    out("png_g8_trns.png", png(g[..., None], 0, 8, trns=struct.pack(">H", key)))
    add("png_g8_trns.png", "png_g8_trns.rgba", grey_rgba(g, np.where(g == key, 0, 255).astype(np.uint8)))
    g2 = indices(W, H, 4, 12)
    out("png_g2_trns.png", png(g2[..., None], 0, 2, trns=struct.pack(">H", 1)))
    add("png_g2_trns.png", "png_g2_trns.rgba", grey_rgba((g2 * 85).astype(np.uint8),
                                                          np.where(g2 == 1, 0, 255).astype(np.uint8)))
    g16 = grey8.astype(np.int64) * 256 + lo[..., 0]
    out("png_g16.png", png(g16[..., None], 0, 16))
    add("png_g16.png", "png_grey.rgba", grey_rgba(grey8))
    k16 = int(g16[4, 6])
    out("png_g16_trns.png", png(g16[..., None], 0, 16, trns=struct.pack(">H", k16)))
    add("png_g16_trns.png", "png_g16_trns.rgba", grey_rgba(grey8, np.where(g16 == k16, 0, 255).astype(np.uint8)))
    # grey and alpha
    ga = np.dstack([grey8, rgba[..., 3]])
    out("png_ga8.png", png(ga, 4, 8))
    add("png_ga8.png", "png_ga8.rgba", grey_rgba(grey8, rgba[..., 3]))
    out("png_ga16.png", png(np.dstack([g16, rgba16[..., 3]]), 4, 16, interlace=True))
    add("png_ga16.png", "png_ga8.rgba", grey_rgba(grey8, rgba[..., 3]))
    # RGB, RGB with tRNS (8 and 16 bits: 16 compares all 16 bits)
    out("png_rgb8.png", png(rgb, 2, 8))
    add("png_rgb8.png", "rgb.rgba", rgba_of(rgb))
    out("png_rgb8_stored.png", png(rgb, 2, 8, level=0))
    add("png_rgb8_stored.png", "rgb.rgba", rgba_of(rgb))
    out("png_rgb8_fixed.png", png(rgb, 2, 8, strategy=zlib.Z_FIXED, split=97))
    add("png_rgb8_fixed.png", "rgb.rgba", rgba_of(rgb))
    out("png_rgb8_i.png", png(rgb, 2, 8, interlace=True))
    add("png_rgb8_i.png", "rgb.rgba", rgba_of(rgb))
    rgb_k = rgb.copy()
    rgb_k[::5, ::4] = (12, 34, 56)
    out("png_rgb8_trns.png", png(rgb_k, 2, 8, trns=struct.pack(">HHH", 12, 34, 56)))
    m = np.all(rgb_k == (12, 34, 56), -1)
    add("png_rgb8_trns.png", "png_rgb8_trns.rgba", np.dstack([rgb_k, np.where(m, 0, 255).astype(np.uint8)]))
    rgb16 = rgba16[..., :3].copy()
    out("png_rgb16.png", png(rgb16, 2, 16))
    add("png_rgb16.png", "rgb.rgba", rgba_of(rgb))
    kc = tuple(int(v) for v in rgb16[3, 3])
    out("png_rgb16_trns.png", png(rgb16, 2, 16, trns=struct.pack(">HHH", *kc), interlace=True))
    m = np.all(rgb16 == kc, -1)
    add("png_rgb16_trns.png", "png_rgb16_trns.rgba", np.dstack([rgb, np.where(m, 0, 255).astype(np.uint8)]))
    # palette with tRNS (fewer entries than colours), 8 and 4 bits, one interlaced
    tr = bytes(np.random.default_rng(6).integers(0, 256, 200).astype(np.uint8))
    out("png_p8_trns.png", png(idx256[..., None], 3, 8, plte=pal256, trns=tr))
    alpha = np.array(list(tr) + [255] * 56, np.uint8)[idx256]
    add("png_p8_trns.png", "png_p8_trns.rgba", np.dstack([pal256[idx256], alpha]))
    out("png_p8_trns_i.png", png(idx256[..., None], 3, 8, plte=pal256, trns=tr, interlace=True))
    add("png_p8_trns_i.png", "png_p8_trns.rgba", np.dstack([pal256[idx256], alpha]))
    p4 = palette(16, 24)
    i4 = indices(W, H, 16, 34)
    out("png_p4_trns_i.png", png(i4[..., None], 3, 4, plte=p4, trns=bytes([0, 128, 255, 7]), interlace=True))
    a4 = np.array([0, 128, 255, 7] + [255] * 12, np.uint8)[i4]
    add("png_p4_trns_i.png", "png_p4_trns.rgba", np.dstack([p4[i4], a4]))
    # RGBA 8 and 16
    out("png_rgba8.png", png(rgba, 6, 8))
    add("png_rgba8.png", "rgba.rgba", rgba)
    out("png_rgba8_i.png", png(rgba, 6, 8, interlace=True, strategy=zlib.Z_FIXED))
    add("png_rgba8_i.png", "rgba.rgba", rgba)
    out("png_rgba16.png", png(rgba16, 6, 16))
    add("png_rgba16.png", "rgba.rgba", rgba)
    # small and thin ones: 1 × 1 and a single row and column
    out("png_1x1.png", png(rgba[:1, :1], 6, 8, interlace=True))
    add("png_1x1.png", "png_1x1.rgba", rgba[:1, :1])
    out("png_row.png", png(rgb[:1], 2, 8))
    add("png_row.png", "png_row.rgba", rgba_of(rgb[:1]))
    out("png_col.png", png(idx256[:, :1, None], 3, 8, plte=pal256, interlace=True))
    add("png_col.png", "png_col.rgba", rgba_of(pal256[idx256[:, :1]]))


# ── BMP ──

def bmp(w, h, bpp, pixels, palette_=None, header=40, comp=0, masks=None, top_down=False, ncol=0):
    """pixels: the file's rows, bottom-up unless top_down, already packed"""
    pal = b""
    if palette_ is not None:
        for c in palette_:
            pal += bytes([c[2], c[1], c[0]]) + (b"" if header == 12 else b"\0")
    extra = b""
    if header == 12:
        info = struct.pack("<IHHHH", 12, w, h, 1, bpp)
    else:
        info = struct.pack("<IiiHHIIiiII", header, w, -h if top_down else h, 1, bpp, comp, len(pixels), 2835, 2835,
                           ncol, 0)
        if header >= 52:
            m = (masks or [0, 0, 0, 0]) + [0] * 4
            info += struct.pack("<III", *m[:3])
            if header >= 56:
                info += struct.pack("<I", m[3])
            info += b"\0" * (header - len(info))
        elif comp == 3:
            extra = struct.pack("<III", *masks[:3])
    off = 14 + len(info) + len(extra) + len(pal)
    return b"BM" + struct.pack("<IHHI", off + len(pixels), 0, 0, off) + info + extra + pal + pixels


def rows_of(rows, top_down):
    """file order, each row padded to 4 bytes"""
    rows = rows if top_down else rows[::-1]
    return b"".join(r + b"\0" * (-len(r) % 4) for r in rows)


def pack_bits(idx, bpp):
    return pack_rows(idx[..., None], bpp)


def rle8(idx):
    """each row as runs and literal stretches, an end of line after it"""
    d = b""
    for row in idx[::-1]:
        row = [int(v) for v in row]
        i = 0
        while i < len(row):
            j = i
            while j < len(row) and j - i < 255 and row[j] == row[i]:
                j += 1
            if j - i >= 2:
                d += bytes([j - i, row[i]])
                i = j
            else:
                j = i
                while j < len(row) and j - i < 255 and (j + 1 >= len(row) or row[j + 1] != row[j]):
                    j += 1
                n = j - i
                if n >= 3:
                    d += bytes([0, n]) + bytes(row[i:j]) + (b"\0" if n & 1 else b"")
                else:
                    for v in row[i:j]:
                        d += bytes([1, v])
                i = j
        d += b"\0\0"
    return d + b"\0\1"


def rle4(idx):
    d = b""
    for row in idx[::-1]:
        row = [int(v) for v in row]
        i = 0
        while i < len(row):
            if i + 1 < len(row) and row[i] == row[i + 1]:
                j = i
                while j < len(row) and j - i < 255 and row[j] == row[i]:
                    j += 1
                d += bytes([j - i, row[i] << 4 | row[i]])
                i = j
            else:
                n = min(len(row) - i, 8)
                if n >= 3:
                    nib = row[i:i + n] + [0] * (n & 1)
                    body = bytes(nib[k] << 4 | nib[k + 1] for k in range(0, len(nib), 2))
                    d += bytes([0, n]) + body + b"\0" * (-len(body) % 2)
                else:
                    for k in range(n):
                        d += bytes([1, row[i + k] << 4])
                i += n
        d += b"\0\0"
    return d + b"\0\1"


def make_bmp():
    rgb = photo(W, H, 1)
    for bpp, n in ((1, 2), (4, 16), (8, 256)):
        p = palette(n, 40 + bpp)
        idx = indices(W, H, n, 50 + bpp)
        exp = rgba_of(p[idx])
        rows = pack_bits(idx, bpp)
        out("bmp_%d.bmp" % bpp, bmp(W, H, bpp, rows_of(rows, False), p))
        add("bmp_%d.bmp" % bpp, "bmp_%d.rgba" % bpp, exp)
        if bpp == 8:
            out("bmp_8_td.bmp", bmp(W, H, 8, rows_of(rows, True), p, top_down=True))
            add("bmp_8_td.bmp", "bmp_8.rgba", exp)
            out("bmp_rle8.bmp", bmp(W, H, 8, rle8(idx), p, comp=1))
            add("bmp_rle8.bmp", "bmp_8.rgba", exp)
            # a palette shorter than 2^8 (biClrUsed)
            p2 = palette(200, 48)
            i2 = indices(W, H, 200, 58)
            out("bmp_8_short.bmp", bmp(W, H, 8, rows_of(pack_bits(i2, 8), False), p2, ncol=200))
            add("bmp_8_short.bmp", "bmp_8_short.rgba", rgba_of(p2[i2]))
        if bpp == 4:
            out("bmp_rle4.bmp", bmp(W, H, 4, rle4(idx), p, comp=2))
            add("bmp_rle4.bmp", "bmp_4.rgba", exp)
    # 24 bits, bottom-up and top-down; the old 12-byte header
    rows = [b"".join(bytes(px[::-1]) for px in row.tolist()) for row in rgb]
    out("bmp_24.bmp", bmp(W, H, 24, rows_of(rows, False)))
    add("bmp_24.bmp", "rgb.rgba", rgba_of(rgb))
    out("bmp_24_td.bmp", bmp(W, H, 24, rows_of(rows, True), top_down=True))
    add("bmp_24_td.bmp", "rgb.rgba", rgba_of(rgb))
    out("bmp_core.bmp", bmp(W, H, 24, rows_of(rows, False), header=12))
    add("bmp_core.bmp", "rgb.rgba", rgba_of(rgb))
    # 32 bits without bit fields: the fourth byte is not alpha
    junk = np.random.default_rng(7).integers(0, 256, (H, W))
    rows = [b"".join(bytes([p[2], p[1], p[0], int(j)]) for p, j in zip(row.tolist(), jr)) for row, jr in zip(rgb, junk)]
    out("bmp_32.bmp", bmp(W, H, 32, rows_of(rows, False)))
    add("bmp_32.bmp", "rgb.rgba", rgba_of(rgb))
    # 32 bits with an alpha mask (V5 header)
    rgba = with_alpha(rgb, 2)
    rows = [b"".join(bytes([p[2], p[1], p[0], p[3]]) for p in row.tolist()) for row in rgba]
    out("bmp_32a.bmp", bmp(W, H, 32, rows_of(rows, True), header=124, comp=3,
                           masks=[0xFF0000, 0xFF00, 0xFF, 0xFF000000], top_down=True))
    add("bmp_32a.bmp", "rgba.rgba", rgba)
    # 16 bits: 5-5-5 (no bit fields) and 5-6-5 (bit fields after a 40-byte header, and in a V4 header)
    q = np.random.default_rng(8).integers(0, 1 << 16, (H, W))
    r5, g5, b5 = (q >> 10) & 31, (q >> 5) & 31, q & 31
    exp = np.dstack([r5 * 255 // 31, g5 * 255 // 31, b5 * 255 // 31, np.full((H, W), 255)]).astype(np.uint8)
    rows = [b"".join(struct.pack("<H", int(v) & 0x7FFF) for v in row) for row in q]
    out("bmp_555.bmp", bmp(W, H, 16, rows_of(rows, False)))
    add("bmp_555.bmp", "bmp_555.rgba", exp)
    r5, g6, b5 = (q >> 11) & 31, (q >> 5) & 63, q & 31
    exp = np.dstack([r5 * 255 // 31, g6 * 255 // 63, b5 * 255 // 31, np.full((H, W), 255)]).astype(np.uint8)
    rows = [b"".join(struct.pack("<H", int(v)) for v in row) for row in q]
    out("bmp_565.bmp", bmp(W, H, 16, rows_of(rows, False), comp=3, masks=[0xF800, 0x7E0, 0x1F]))
    add("bmp_565.bmp", "bmp_565.rgba", exp)
    out("bmp_565_v4.bmp", bmp(W, H, 16, rows_of(rows, False), header=108, comp=3, masks=[0xF800, 0x7E0, 0x1F, 0]))
    add("bmp_565_v4.bmp", "bmp_565.rgba", exp)


# ── GIF ──

def lzw(idx, min_size):
    """GIF's LZW, a clear code first and whenever the table is full"""
    clear = 1 << min_size
    out_codes = []
    size = min_size + 1
    table = {(i,): i for i in range(clear)}
    nxt = clear + 2
    bits = []

    def emit(code, sz):
        bits.append((code, sz))

    emit(clear, size)
    w = ()
    for k in idx:
        wk = w + (int(k),)
        if wk in table:
            w = wk
            continue
        emit(table[w], size)
        if nxt < 4096:
            table[wk] = nxt
            nxt += 1
            if nxt > (1 << size) and size < 12:
                size += 1
        else:
            emit(clear, size)
            table = {(i,): i for i in range(clear)}
            nxt = clear + 2
            size = min_size + 1
        w = (int(k),)
    if w:
        emit(table[w], size)
    emit(clear + 1, size)
    acc = 0
    n = 0
    data = bytearray()
    for code, sz in bits:
        acc |= code << n
        n += sz
        while n >= 8:
            data.append(acc & 255)
            acc >>= 8
            n -= 8
    if n:
        data.append(acc & 255)
    blocks = b""
    for i in range(0, len(data), 255):
        blocks += bytes([len(data[i:i + 255])]) + bytes(data[i:i + 255])
    del out_codes
    return bytes([min_size]) + blocks + b"\0"


def interlace_order(h):
    return [y for s, d in ((0, 8), (4, 8), (2, 4), (1, 2)) for y in range(s, h, d)]


def make_gif():
    # PIL's own: a 256-colour picture plain, interlaced, with a transparent colour, and two frames
    p = palette(256, 60)
    idx = indices(W, H, 256, 61)
    im = Image.fromarray(idx, "P")
    im.putpalette(p.tobytes())
    exp = rgba_of(p[idx])
    for name, kw in (("gif_basic.gif", dict(interlace=False)), ("gif_inter.gif", dict(interlace=True))):
        b = io.BytesIO()
        im.save(b, "GIF", **kw)
        out(name, b.getvalue())
        assert same_visible(pil_rgba(b.getvalue()), exp), name
        add(name, "gif_256.rgba", exp)
    b = io.BytesIO()
    im.save(b, "GIF", transparency=7, interlace=False)
    expt = exp.copy()
    expt[idx == 7] = 0
    assert same_visible(pil_rgba(b.getvalue()), expt)
    out("gif_trans.gif", b.getvalue())
    add("gif_trans.gif", "gif_trans.rgba", expt)
    idx2 = indices(W, H, 256, 62)
    im2 = Image.fromarray(idx2, "P")
    im2.putpalette(p.tobytes())
    b = io.BytesIO()
    im.save(b, "GIF", save_all=True, append_images=[im2], duration=100, loop=0)
    out("gif_anim.gif", b.getvalue())
    add("gif_anim.gif", "gif_256.rgba", exp, frames=2)
    # by hand: no global colour table, a local one, a frame smaller than the canvas and away from its corner,
    # interlaced, a transparent colour — around the frame the canvas stays transparent
    fw, fh, fx, fy = 22, 13, 9, 6
    lp = palette(16, 63)
    li = indices(fw, fh, 16, 64)
    gce = b"\x21\xF9\x04\x01\x0A\x00\x03\x00"
    order = interlace_order(fh)
    body = lzw(li[order].reshape(-1), 4)
    d = b"GIF89a" + struct.pack("<HHBBB", W, H, 0x00, 0, 0) + gce
    d += b"\x2C" + struct.pack("<HHHHB", fx, fy, fw, fh, 0x80 | 0x40 | 3) + lp.tobytes() + body + b"\x3B"
    out("gif_local.gif", d)
    exp = np.zeros((H, W, 4), np.uint8)
    sub = rgba_of(lp[li])
    sub[li == 3] = 0
    exp[fy:fy + fh, fx:fx + fw] = sub
    add("gif_local.gif", "gif_local.rgba", exp)
    # a frame larger than the logical screen: the canvas grows to hold it; 2-colour, with a table of 2 entries
    bw = indices(W, H, 2, 65)
    d = b"GIF87a" + struct.pack("<HHBBB", 20, 10, 0x80, 0, 0) + bytes([0, 0, 0, 255, 255, 255])
    d += b"\x2C" + struct.pack("<HHHHB", 0, 0, W, H, 0) + lzw(bw.reshape(-1), 2) + b"\x3B"
    out("gif_grow.gif", d)
    add("gif_grow.gif", "gif_grow.rgba", rgba_of(np.array([[0, 0, 0], [255, 255, 255]], np.uint8)[bw]))


# ── JPEG: a small baseline encoder, for sampling factors and scan layouts PIL does not write ──

ZZ = [0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14,
      21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60,
      61, 54, 47, 55, 62, 63]
QL = [16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29,
      51, 87, 80, 62, 18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92, 49, 64, 78, 87, 103, 121,
      120, 101, 72, 92, 95, 98, 112, 100, 103, 99]
QC = [17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99, 24, 26, 56, 99, 99, 99, 99, 99, 47, 66, 99, 99,
      99, 99, 99, 99] + [99] * 32
DC_L = ([0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0], list(range(12)))
DC_C = ([0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0], list(range(12)))
AC_L = ([0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d], bytes.fromhex(
    "01020300041105122131410613516107227114328191a1082342b1c11552d1f02433627282090a161718191a25262728292a3435363738"
    "393a434445464748494a535455565758595a636465666768696a737475767778797a838485868788898a92939495969798999aa2a3a4a5"
    "a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3c4c5c6c7c8c9cad2d3d4d5d6d7d8d9dae1e2e3e4e5e6e7e8e9eaf1f2f3f4f5f6f7f8f9fa"))
AC_C = ([0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77], bytes.fromhex(
    "000102031104052131061241510761711322328108144291a1b1c109233352f0156272d10a162434e125f11718191a262728292a3536"
    "3738393a434445464748494a535455565758595a636465666768696a737475767778797a82838485868788898a92939495969798999aa2"
    "a3a4a5a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3c4c5c6c7c8c9cad2d3d4d5d6d7d8d9dae2e3e4e5e6e7e8e9eaf2f3f4f5f6f7f8f9fa"))


def huff_codes(spec):
    counts, vals = spec
    codes = {}
    code = 0
    k = 0
    for l in range(1, 17):
        for _ in range(counts[l - 1]):
            codes[vals[k]] = (code, l)
            code += 1
            k += 1
        code <<= 1
    return codes


DCT = np.array([[(np.sqrt(0.5) if u == 0 else 1.0) / 2 * np.cos((2 * x + 1) * u * np.pi / 16) for x in range(8)]
                for u in range(8)])


class Bits:
    def __init__(self):
        self.out = bytearray()
        self.acc = 0
        self.n = 0

    def put(self, code, length):
        for i in range(length - 1, -1, -1):
            self.acc = (self.acc << 1) | ((code >> i) & 1)
            self.n += 1
            if self.n == 8:
                self.out.append(self.acc)
                if self.acc == 0xFF:
                    self.out.append(0)
                self.acc = 0
                self.n = 0

    def flush(self):
        if self.n:
            self.put((1 << (8 - self.n)) - 1, 8 - self.n)


def cdiv(a, b):
    return -(-a // b)


def category(v):
    v = abs(v)
    n = 0
    while v:
        n += 1
        v >>= 1
    return n


def jpeg_encode(rgb, factors, scans=None, ri=0, quality=90, ids=(1, 2, 3)):
    """baseline JPEG of an RGB picture, YCbCr with the given (h, v) a component, scans: lists of components"""
    h, w = rgb.shape[:2]
    f = rgb.astype(np.float64)
    planes = [0.299 * f[..., 0] + 0.587 * f[..., 1] + 0.114 * f[..., 2],
              128 - 0.168736 * f[..., 0] - 0.331264 * f[..., 1] + 0.5 * f[..., 2],
              128 + 0.5 * f[..., 0] - 0.418688 * f[..., 1] - 0.081312 * f[..., 2]][:len(factors)]
    hmax = max(a for a, b in factors)
    vmax = max(b for a, b in factors)
    mx, my = cdiv(w, 8 * hmax), cdiv(h, 8 * vmax)
    s = 5000 / quality if quality < 50 else 200 - 2 * quality
    qt = [[max(1, min(255, (q * s + 50) // 100)) for q in t] for t in (QL, QC)]
    comps = []
    for ci, (p, (fh, fv)) in enumerate(zip(planes, factors)):
        # pad to whole MCUs by repeating the edge, then average down to this component's sampling
        pw, ph = mx * 8 * hmax, my * 8 * vmax
        pp = np.pad(p, ((0, ph - h), (0, pw - w)), mode="edge")
        sx, sy = hmax // fh, vmax // fv
        pp = pp.reshape(ph // sy, sy, pw // sx, sx).mean(axis=(1, 3))
        q = np.array(qt[0 if ci == 0 else 1], np.float64)
        bw, bh = pp.shape[1] // 8, pp.shape[0] // 8
        coefs = np.zeros((bh, bw, 64), np.int64)
        for by in range(bh):
            for bx in range(bw):
                blk = pp[by * 8:by * 8 + 8, bx * 8:bx * 8 + 8] - 128
                c = (DCT @ blk @ DCT.T).reshape(64)
                coefs[by, bx] = np.rint(c / q)
        comps.append(dict(h=fh, v=fv, coefs=coefs, tq=0 if ci == 0 else 1,
                          cw=cdiv(cdiv(w * fh, hmax), 8), ch=cdiv(cdiv(h * fv, vmax), 8)))
    hd = [huff_codes(DC_L), huff_codes(DC_C)]
    ha = [huff_codes(AC_L), huff_codes(AC_C)]

    def block(bits, c, by, bx, t, pred):
        z = c["coefs"][by, bx]
        dc = int(z[0])
        diff = dc - pred
        n = category(diff)
        bits.put(*hd[t][n])
        if n:
            bits.put(diff if diff > 0 else diff + (1 << n) - 1, n)
        run = 0
        for k in range(1, 64):
            v = int(z[ZZ[k]])
            if v == 0:
                run += 1
                continue
            while run > 15:
                bits.put(*ha[t][0xF0])
                run -= 16
            n = category(v)
            bits.put(*ha[t][run << 4 | n])
            bits.put(v if v > 0 else v + (1 << n) - 1, n)
            run = 0
        if run:
            bits.put(*ha[t][0])
        return dc

    d = b"\xFF\xD8"
    for t, q in enumerate(qt):
        d += b"\xFF\xDB" + struct.pack(">HB", 67, t) + bytes(q[ZZ[k]] for k in range(64))
    d += b"\xFF\xC0" + struct.pack(">HBHHB", 8 + 3 * len(comps), 8, h, w, len(comps))
    for ci, c in enumerate(comps):
        d += bytes([ids[ci], c["h"] << 4 | c["v"], c["tq"]])
    for cls, specs in ((0, (DC_L, DC_C)), (1, (AC_L, AC_C))):
        for t, (counts, vals) in enumerate(specs):
            d += b"\xFF\xC4" + struct.pack(">HB", 2 + 17 + len(vals), cls << 4 | t) + bytes(counts) + bytes(vals)
    if ri:
        d += b"\xFF\xDD" + struct.pack(">HH", 4, ri)
    for sc in scans or [list(range(len(comps)))]:
        d += b"\xFF\xDA" + struct.pack(">HB", 6 + 2 * len(sc), len(sc))
        for ci in sc:
            t = 0 if ci == 0 else 1
            d += bytes([ids[ci], t << 4 | t])
        d += b"\x00\x3F\x00"
        bits = Bits()
        preds = [0] * len(comps)
        units = []
        if len(sc) == 1:
            c = comps[sc[0]]
            units = [[(sc[0], by, bx)] for by in range(c["ch"]) for bx in range(c["cw"])]
        else:
            for uy in range(my):
                for ux in range(mx):
                    units.append([(ci, uy * comps[ci]["v"] + v, ux * comps[ci]["h"] + hh) for ci in sc
                                  for v in range(comps[ci]["v"]) for hh in range(comps[ci]["h"])])
        for m, unit in enumerate(units):
            if ri and m and m % ri == 0:
                bits.flush()
                bits.out += bytes([0xFF, 0xD0 + (m // ri - 1) % 8])
                preds = [0] * len(comps)
            for ci, by, bx in unit:
                preds[ci] = block(bits, comps[ci], by, bx, 0 if ci == 0 else 1, preds[ci])
        bits.flush()
        d += bytes(bits.out)
    return d + b"\xFF\xD9"


def jpeg_expected(data, name):
    """libjpeg's decoding, through PIL, turned as EXIF says"""
    im = ImageOps.exif_transpose(Image.open(io.BytesIO(data)))
    return np.asarray(im.convert("RGBA"))


def make_jpeg():
    rgb = photo(W, H, 1, noise=3.0)
    im = Image.fromarray(rgb)

    def pil(name, image=im, kind="jpeg", **kw):
        b = io.BytesIO()
        image.save(b, "JPEG", **kw)
        out(name, b.getvalue())
        add(name, name.replace(".jpg", ".rgba"), jpeg_expected(b.getvalue(), name), kind)
        return b.getvalue()

    pil("jpg_444.jpg", quality=90, subsampling=0)
    pil("jpg_422.jpg", quality=90, subsampling=1)
    pil("jpg_420.jpg", quality=90, subsampling=2)
    pil("jpg_grey.jpg", image=im.convert("L"), quality=90)
    pil("jpg_prog.jpg", quality=85, subsampling=2, progressive=True)
    pil("jpg_prog444.jpg", quality=95, subsampling=0, progressive=True, optimize=True)
    pil("jpg_prog_grey.jpg", image=im.convert("L"), quality=85, progressive=True)
    pil("jpg_rst.jpg", quality=90, subsampling=2, restart_marker_blocks=1)
    pil("jpg_rst_prog.jpg", quality=90, subsampling=1, progressive=True, restart_marker_rows=1)
    pil("jpg_cmyk.jpg", image=im.convert("CMYK"), quality=92)
    pil("jpg_rgb.jpg", quality=90, keep_rgb=True)
    pil("jpg_q100.jpg", quality=100, subsampling=0)
    # EXIF orientation, all eight
    small = Image.fromarray(photo(21, 13, 9, noise=2.0))
    for o in range(1, 9):
        ex = Image.Exif()
        ex[0x0112] = o
        pil("jpg_exif%d.jpg" % o, image=small, quality=92, subsampling=2, exif=ex.tobytes())
    # by the encoder above: 4:1:1, 4:4:0, mixed factors, 3:1, non-interleaved scans with restart markers
    for name, kw in (("jpg_411.jpg", dict(factors=[(4, 1), (1, 1), (1, 1)])),
                     ("jpg_440.jpg", dict(factors=[(1, 2), (1, 1), (1, 1)])),
                     ("jpg_mixed.jpg", dict(factors=[(2, 2), (1, 2), (2, 1)])),
                     ("jpg_311.jpg", dict(factors=[(3, 1), (1, 1), (1, 1)])),
                     ("jpg_nonint.jpg", dict(factors=[(2, 2), (1, 1), (1, 1)], scans=[[0], [1], [2]], ri=3)),
                     ("jpg_grey22.jpg", dict(factors=[(2, 2)], ri=2))):
        d = jpeg_encode(rgb, **kw)
        out(name, d)
        add(name, name.replace(".jpg", ".rgba"), jpeg_expected(d, name), "jpeg")
    # a larger one for the reduced sizes: PIL's draft decodes at 1/2, 1/4, 1/8 with libjpeg's DCT scaling
    big = Image.fromarray(photo(64, 48, 11, noise=3.0))
    for name, kw in (("jpg_64.jpg", dict(subsampling=2)), ("jpg_64p.jpg", dict(subsampling=2, progressive=True)),
                     ("jpg_64_444.jpg", dict(subsampling=0))):
        d = pil(name, image=big, quality=90, **kw)
        for s in (2, 4, 8):
            dr = Image.open(io.BytesIO(d))
            dr.draft("RGB", (64 // s, 48 // s))
            arr = np.asarray(dr.convert("RGBA"))
            assert arr.shape[:2] == (48 // s, 64 // s), (name, s, arr.shape)
            exp = name.replace(".jpg", ".s%d.rgba" % s)
            expect(exp, arr)
            manifest.append((name, exp, arr.shape[1], arr.shape[0], 1, "jpeg/%d" % s))


def check_with_pil():
    """the expected pixels of the lossless files are what was written; PIL should agree where it reads them fully"""
    for file, exp, w, h, frames, kind in manifest:
        if kind != "exact":
            continue
        data = open(os.path.join(HERE, file), "rb").read()
        mine = written_rgba[exp].reshape(h, w, 4)
        try:
            im = Image.open(io.BytesIO(data))
            if im.mode in ("I;16", "I;16B", "I"):
                continue        # PIL keeps 16-bit grey as numbers and clips them to 255 when made RGBA
            if file in ("png_g2_trns.png", "png_rgb16_trns.png", "gif_local.gif", "bmp_rle4.bmp"):
                # PIL compares a tRNS colour with the pixels made 8-bit, fills a GIF canvas with colour 0 and drops
                # the last pixel of an odd RLE4 stretch (ImageMagick reads these as they were written)
                continue
            theirs = np.asarray(im.convert("RGBA"))
        except Exception as e:
            print("PIL cannot read", file, e)
            continue
        if not same_visible(mine, theirs):
            bad = np.argwhere(np.any(mine != theirs, -1))
            at = tuple(bad[0])
            print("PIL reads", file, "differently, e.g. at", bad[:3].tolist(), mine[at], theirs[at])
            sys.exit(1)


def make_big():
    """big.jpg: 4000 × 3000, 4:2:0, quality 90 — about what a phone camera makes"""
    rgb = photo(4000, 3000, 99, noise=4.0)
    Image.fromarray(rgb).save(os.path.join(HERE, "big.jpg"), "JPEG", quality=90, subsampling=2)


if __name__ == "__main__":
    for f in os.listdir(HERE):
        if f.endswith((".png", ".bmp", ".gif", ".jpg", ".rgba")) and f != "big.jpg":
            os.remove(os.path.join(HERE, f))
    make_png()
    make_bmp()
    make_gif()
    make_jpeg()
    check_with_pil()
    with open(os.path.join(HERE, "manifest.txt"), "w") as f:
        f.write("# file  expected-rgba  width  height  frames  kind (exact | jpeg | jpeg/<scale>) — made by make.py\n")
        for row in manifest:
            f.write("%s %s %d %d %d %s\n" % row)
    if "--big" in sys.argv:
        make_big()
    total = sum(os.path.getsize(os.path.join(HERE, f)) for f in os.listdir(HERE) if f != "big.jpg")
    print("%d fixtures, %d expected pictures, %d KB" % (len(manifest), len(written_rgba), total // 1024))
