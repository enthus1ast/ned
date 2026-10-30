## SHA-256 (FIPS 180-4): ned checks what it downloads against a release's SHA256SUMS. Nim's standard library has
## no SHA-256 and ned uses nothing else, so it is here — a module of its own, streaming: a file is read in chunks,
## never whole.

import std/strutils

type Sha256Ctx* = object
  ## a hash being worked out: feed it with `sha256Update`, end it with `sha256Final`
  h: array[8, uint32]
  buf: array[64, byte]
  bufLen: int
  total: uint64                          # bytes fed so far

const
  sha256K: array[64, uint32] = [
    0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32, 0x3956c25b'u32, 0x59f111f1'u32, 0x923f82a4'u32,
    0xab1c5ed5'u32, 0xd807aa98'u32, 0x12835b01'u32, 0x243185be'u32, 0x550c7dc3'u32, 0x72be5d74'u32, 0x80deb1fe'u32,
    0x9bdc06a7'u32, 0xc19bf174'u32, 0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32, 0x2de92c6f'u32,
    0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32, 0x983e5152'u32, 0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32,
    0xc6e00bf3'u32, 0xd5a79147'u32, 0x06ca6351'u32, 0x14292967'u32, 0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32,
    0x53380d13'u32, 0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32, 0xa2bfe8a1'u32, 0xa81a664b'u32,
    0xc24b8b70'u32, 0xc76c51a3'u32, 0xd192e819'u32, 0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32, 0x19a4c116'u32,
    0x1e376c08'u32, 0x2748774c'u32, 0x34b0bcb5'u32, 0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32, 0x682e6ff3'u32,
    0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32, 0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32,
    0xc67178f2'u32]
  sha256H0: array[8, uint32] = [0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32, 0x510e527f'u32,
                                0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32]

# a 32-bit number rotated right by n bits
func sha256Rotr(x: uint32, n: int): uint32 {.inline.} = (x shr n) or (x shl (32 - n))

proc sha256Block(c: var Sha256Ctx, p: ptr UncheckedArray[byte]) =
  ## one 64-byte block into the state
  var w: array[64, uint32]
  for i in 0 ..< 16:
    w[i] = (p[4*i].uint32 shl 24) or (p[4*i+1].uint32 shl 16) or (p[4*i+2].uint32 shl 8) or p[4*i+3].uint32
  for i in 16 ..< 64:
    let s0 = sha256Rotr(w[i-15], 7) xor sha256Rotr(w[i-15], 18) xor (w[i-15] shr 3)
    let s1 = sha256Rotr(w[i-2], 17) xor sha256Rotr(w[i-2], 19) xor (w[i-2] shr 10)
    w[i] = w[i-16] + s0 + w[i-7] + s1
  var a = c.h[0]
  var b = c.h[1]
  var cc = c.h[2]
  var d = c.h[3]
  var e = c.h[4]
  var f = c.h[5]
  var g = c.h[6]
  var h = c.h[7]
  for i in 0 ..< 64:
    let S1 = sha256Rotr(e, 6) xor sha256Rotr(e, 11) xor sha256Rotr(e, 25)
    let ch = (e and f) xor ((not e) and g)
    let t1 = h + S1 + ch + sha256K[i] + w[i]
    let S0 = sha256Rotr(a, 2) xor sha256Rotr(a, 13) xor sha256Rotr(a, 22)
    let maj = (a and b) xor (a and cc) xor (b and cc)
    let t2 = S0 + maj
    h = g
    g = f
    f = e
    e = d + t1
    d = cc
    cc = b
    b = a
    a = t1 + t2
  c.h[0] += a
  c.h[1] += b
  c.h[2] += cc
  c.h[3] += d
  c.h[4] += e
  c.h[5] += f
  c.h[6] += g
  c.h[7] += h

func sha256Init*(): Sha256Ctx =
  ## a new hash: the starting state of SHA-256
  result.h = sha256H0

proc sha256Update*(c: var Sha256Ctx, data: pointer, len: int) =
  ## more bytes
  if len <= 0: return
  let p = cast[ptr UncheckedArray[byte]](data)
  var i = 0
  c.total += len.uint64
  if c.bufLen > 0:
    let n = min(64 - c.bufLen, len)
    copyMem(addr c.buf[c.bufLen], addr p[0], n)
    c.bufLen += n
    i = n
    if c.bufLen == 64:
      sha256Block(c, cast[ptr UncheckedArray[byte]](addr c.buf[0]))
      c.bufLen = 0
  while len - i >= 64:
    sha256Block(c, cast[ptr UncheckedArray[byte]](addr p[i]))
    i += 64
  if i < len:
    copyMem(addr c.buf[0], addr p[i], len - i)
    c.bufLen = len - i

proc sha256Update*(c: var Sha256Ctx, s: string) =
  ## feeds the bytes of a string into the hash (the same as the pointer and length form)
  if s.len > 0: sha256Update(c, unsafeAddr s[0], s.len)

proc sha256Final*(c: var Sha256Ctx): array[32, byte] =
  ## the digest (the context is used up)
  let bits = c.total * 8
  var pad: array[72, byte]
  pad[0] = 0x80
  let padLen = (if c.bufLen < 56: 56 - c.bufLen else: 120 - c.bufLen)
  for k in 0 ..< 8: pad[padLen + k] = byte((bits shr (56 - 8 * k)) and 0xff)
  let total = c.total
  sha256Update(c, addr pad[0], padLen + 8)
  c.total = total
  for i in 0 ..< 8:
    result[4*i] = byte(c.h[i] shr 24)
    result[4*i+1] = byte((c.h[i] shr 16) and 0xff)
    result[4*i+2] = byte((c.h[i] shr 8) and 0xff)
    result[4*i+3] = byte(c.h[i] and 0xff)

func sha256ToHex*(d: array[32, byte]): string =
  ## the digest as sha256sum prints it: 64 lower-case hexadecimal digits
  const digits = "0123456789abcdef"
  result = newStringOfCap(64)
  for b in d:
    result.add digits[b.int shr 4]
    result.add digits[b.int and 15]

proc sha256Hex*(s: string): string =
  ## the SHA-256 of a string, in hexadecimal
  var c = sha256Init()
  sha256Update(c, s)
  sha256ToHex(sha256Final(c))

proc sha256FileHex*(path: string, chunk = 1 shl 20): string =
  ## the SHA-256 of a file, in hexadecimal, read `chunk` bytes at a time (raises IOError when it cannot be read)
  var f: File
  if not open(f, path, fmRead): raise newException(IOError, "cannot read " & path)
  defer: close(f)
  var c = sha256Init()
  var buf = newString(max(64, chunk))
  while true:
    let n = readBuffer(f, addr buf[0], buf.len)
    if n <= 0: break
    sha256Update(c, addr buf[0], n)
  sha256ToHex(sha256Final(c))

func sha256SumFor*(sums, name: string): string =
  ## the hash a SHA256SUMS file (sha256sum's output: "<hash>  <name>", or " *<name>" for binary mode) gives for
  ## the file `name` (its base name compared too: "dist/x.deb" names x.deb) — "" when it has none
  for raw in sums.splitLines:
    let l = raw.strip(leading = false)
    if l.len < 66 or l.startsWith("#"): continue
    let h = l[0 ..< 64]
    if not h.allCharsInSet(HexDigits) or l[64] != ' ': continue
    var n = l[65 .. ^1]
    if n.startsWith("*") or n.startsWith(" "): n = n[1 .. ^1]
    let base = (let k = n.rfind('/'); if k >= 0: n[k + 1 .. ^1] else: n)
    if n == name or base == name: return h.toLowerAscii
  ""
