# ── executables and object files, read for the hex editor: ELF (Linux, Android), Mach-O (macOS) and PE (Windows) —
#    what kind of file it is, its sections and its symbols with where each is in the file; and the names Nim gives
#    procs in C turned back into Nim's (Nim 2: shout__app_u12 → app.shout · Nim 3: greet_0_h3j08bn01 → greet) ──

import std/[algorithm, sequtils, strutils, tables]

type
  BinSection* = object
    name*: string
    address*, offset*, size*: int64   # where it is loaded, where it is in the file (-1: not in the file), its bytes
  BinSymbol* = object
    name*: string                     # as the file has it
    nimName*, nimModule*: string      # the Nim proc it is ("" when it is no Nim name)
    address*, size*, offset*: int64   # offset: in the file (-1: none, e.g. an undefined symbol)
    code*: bool                       # a function (not data)
    section*: string
  BinInfo* = object
    format*: string                   # "ELF", "Mach-O", "PE" — "" when the file is none of them
    kind*: string                     # "executable", "shared library", "object file" …
    arch*: string                     # "x86-64", "AArch64" …
    bits*: int
    bigEndian*: bool
    entry*: int64                     # the entry point's address (0: none)
    sections*: seq[BinSection]
    symbols*: seq[BinSymbol]
    nim*: bool                        # built by Nim (or Nimony)
    note*: string                     # what could not be read

# ── reading numbers ──

proc rd(d: string, at, n: int, be: bool): int64 =
  ## an unsigned n-byte number at `at` (0 when it is past the end)
  if at < 0 or at + n > d.len: return 0
  var v: uint64 = 0
  if be:
    for i in 0 ..< n: v = (v shl 8) or uint64(ord(d[at + i]))
  else:
    for i in countdown(n - 1, 0): v = (v shl 8) or uint64(ord(d[at + i]))
  cast[int64](v)

proc cstr(d: string, at: int, maxLen = 4096): string =
  ## a zero-ended string at `at`
  if at < 0 or at >= d.len: return ""
  var e = at
  while e < d.len and d[e] != '\0' and e - at < maxLen: inc e
  d[at ..< e]

proc fixed(d: string, at, n: int): string =
  ## a name in n bytes, zero-padded
  if at < 0 or at + n > d.len: return ""
  result = d[at ..< at + n]
  let z = result.find('\0')
  if z >= 0: result.setLen(z)

# ── Nim's names ──

const Nim2Ops = [("dollar", "$"), ("percent", "%"), ("amp", "&"), ("roof", "^"), ("emark", "!"), ("qmark", "?"),
                 ("star", "*"), ("plus", "+"), ("minus", "-"), ("slash", "/"), ("backslash", "\\"), ("eq", "="),
                 ("lt", "<"), ("gt", ">"), ("tilde", "~"), ("colon", ":"), ("dot", "."), ("at", "@"), ("bar", "|")]

proc nim2Name(m: string): string =
  ## a Nim 2 proc name as C has it back to Nim's: "plus_" → "+", "eqdestroy_" → "=destroy", "dollar_" → "$",
  ## "X5BX5Deq_" → "[]="
  if m.len < 2 or m[^1] != '_': return m
  let s = m[0 ..< m.high]
  var i = 0
  var res = ""
  var special = false
  while i < s.len:
    var hit = false
    if s[i] == 'X' and i + 2 < s.len and s[i + 1] in HexDigits and s[i + 2] in HexDigits and
       s[i + 1 .. i + 2] == s[i + 1 .. i + 2].toUpperAscii:
      res.add char(parseHexInt(s[i + 1 .. i + 2]))
      i += 3
      hit = true
    elif not special or res.len == 0 or res[^1] notin IdentChars:
      for (w, op) in Nim2Ops:
        if s.continuesWith(w, i):
          res.add op
          i += w.len
          hit = true
          break
    if hit:
      special = true
      continue
    res.add s[i]
    inc i
  if not special: m else: res

const NimonyOps = [("getQ", "[]"), ("putQ", "[]="), ("eqQ", "=="), ("eQ", "="), ("leQ", "<="), ("ltQ", "<"),
                   ("geQ", ">="), ("gtQ", ">"), ("dollarQ", "$"), ("percentQ", "%"), ("ampQ", "&"), ("roofQ", "^"),
                   ("emarkQ", "!"), ("qmarkQ", "?"), ("starQ", "*"), ("plusQ", "+"), ("minusQ", "-"),
                   ("slashQ", "/"), ("bslashQ", "\\"), ("tildeQ", "~"), ("colonQ", ":"), ("atQ", "@"), ("barQ", "|")]

proc nimonyUnmangle(m: string): string =
  ## Nimony's C name back to its NIF name ("greet_0_h3j08bn01" → "greet.0.h3j08bn01"); "" when it is not one
  var i = 0
  while i < m.len:
    let c = m[i]
    if c == 'Q':
      if i + 1 < m.len and m[i + 1] == 'Q':
        result.add 'Q'
        i += 2
      elif i + 1 < m.len and m[i + 1] == '_':
        result.add '_'
        i += 2
      else: return ""
    elif c == '_':
      result.add '.'
      inc i
    elif c == 'X' and i + 3 < m.len and m[i + 3] == 'Q' and m[i + 1] in HexDigits and m[i + 2] in HexDigits:
      result.add char(parseHexInt(m[i + 1 .. i + 2]))
      i += 4
    else:
      var hit = false
      for (w, op) in NimonyOps:
        if m.continuesWith(w, i):
          result.add op
          i += w.len
          hit = true
          break
      if not hit:
        result.add c
        inc i

proc nimDemangle*(sym: string): (string, string) =
  ## (Nim's name, its module) of a symbol a Nim (2 or 3) compiler made — ("", "") when it is no such name
  var s = sym
  if s.startsWith("__ZN"): s = s[1 .. ^1]
  if s.startsWith("_ZN"):
    # Nim 2 with --debugger:native: C++'s form, _ZN4demo5plus_E6string6string — the module, then the name
    var i = 3
    var parts: seq[string]
    while i < s.len and s[i] in Digits:
      var n = 0
      while i < s.len and s[i] in Digits and n < 100_000:
        n = n * 10 + ord(s[i]) - ord('0')
        inc i
      if n == 0 or i + n > s.len: return ("", "")
      parts.add s[i ..< i + n]
      i += n
    if parts.len < 2 or i >= s.len or s[i] != 'E': return ("", "")
    let (inner, im) = nimDemangle(parts[^1])          # (rttiDestroy__systemZexceptions_u58: its own module)
    if inner.len > 0: return (inner, im)
    return (nim2Name(parts[^1]), parts[0 .. ^2].join("/"))
  if s.len > 1 and s[0] == '_' and s[1] != '_': s = s[1 .. ^1]   # (Mach-O and old Windows put a _ in front)
  # Nim 2: <name>__<module>_u<number>
  let u = s.rfind("_u")
  if u > 0 and u + 2 < s.len and s[u + 2 .. ^1].allCharsInSet(Digits):
    let sep = s.rfind("__", last = u - 1)
    if sep > 0 and sep + 2 < u:
      var module = s[sep + 2 ..< u]
      var nm = s[0 ..< sep]
      # (`plus___it_u12`: the last "__" before the module — the name's own trailing _ stays with it)
      if nm.len > 0 and module.len > 0:
        var modPath = ""
        for i, c in module:
          if c == 'Z' and i > 0 and i + 1 < module.len and module[i - 1] in {'a'..'z', '0'..'9'} and
             module[i + 1] in {'a'..'z'}: modPath.add '/'
          else: modPath.add c
        return (nim2Name(nm), modPath)
  # Nim 3 (Nimony): <name>_<number>_<module key>
  let parts = nimonyUnmangle(s).split('.')
  if parts.len >= 3 and parts[^2].len > 0 and parts[^2].allCharsInSet(Digits) and parts[^1].len >= 4 and
     parts[^1].allCharsInSet({'a'..'z', '0'..'9'}):
    return (parts[0 .. ^3].join("."), parts[^1])
  ("", "")

# ── ELF ──

proc elfMachine(m: int): string =
  ## the processor's name for an ELF header's machine number ("machine N" when it is not one of the common ones)
  case m
  of 3: "x86"
  of 0x3E: "x86-64"
  of 0x28: "ARM"
  of 0xB7: "AArch64"
  of 0xF3: "RISC-V"
  of 8: "MIPS"
  of 0x14: "PowerPC"
  of 0x15: "PowerPC64"
  of 0x2B: "SPARC V9"
  of 0x16: "s390"
  of 0x102: "LoongArch"
  else: "machine " & $m

proc parseElf(d: string, r: var BinInfo) =
  ## reads an ELF file into `r`: word size, byte order, kind (a shared library with an .interp section is really a PIE
  ## executable), processor, entry point, the sections from the section table and the symbols from .symtab (else
  ## .dynsym) with each one's place in the file worked out from its section. Without a section table it only notes that.
  r.format = "ELF"
  r.bits = if ord(d[4]) == 2: 64 else: 32
  let be = ord(d[5]) == 2
  r.bigEndian = be
  let w = if r.bits == 64: 8 else: 4
  let typ = rd(d, 16, 2, be)
  r.kind = case typ
    of 1: "object file"
    of 2: "executable"
    of 3: "shared library"            # (a position-independent executable too: told apart below by its .interp)
    of 4: "core dump"
    else: "type " & $typ
  r.arch = elfMachine(int(rd(d, 18, 2, be)))
  r.entry = rd(d, 24, w, be)
  let shoff = int(rd(d, (if w == 8: 40 else: 32), w, be))
  let shentsize = int(rd(d, (if w == 8: 58 else: 46), 2, be))
  let shnum = int(rd(d, (if w == 8: 60 else: 48), 2, be))
  let shstrndx = int(rd(d, (if w == 8: 62 else: 50), 2, be))
  if shoff <= 0 or shentsize < (if w == 8: 64 else: 40) or shnum <= 0 or shoff + shnum * shentsize > d.len:
    r.note = "no section table"
    return
  type Sh = object
    name, typ, link: int
    address, offset, size, entsize: int64
  var shs: seq[Sh]
  for i in 0 ..< shnum:
    let at = shoff + i * shentsize
    if w == 8:
      shs.add Sh(name: int(rd(d, at, 4, be)), typ: int(rd(d, at + 4, 4, be)), address: rd(d, at + 16, 8, be),
                 offset: rd(d, at + 24, 8, be), size: rd(d, at + 32, 8, be), link: int(rd(d, at + 40, 4, be)),
                 entsize: rd(d, at + 56, 8, be))
    else:
      shs.add Sh(name: int(rd(d, at, 4, be)), typ: int(rd(d, at + 4, 4, be)), address: rd(d, at + 12, 4, be),
                 offset: rd(d, at + 16, 4, be), size: rd(d, at + 20, 4, be), link: int(rd(d, at + 24, 4, be)),
                 entsize: rd(d, at + 36, 4, be))
  let strOff = if shstrndx < shs.len: int(shs[shstrndx].offset) else: -1
  for s in shs:
    if typ == 3 and strOff >= 0 and cstr(d, strOff + s.name) == ".interp": r.kind = "executable (PIE)"
    if s.typ == 0: continue
    r.sections.add BinSection(name: (if strOff >= 0: cstr(d, strOff + s.name) else: ""), address: s.address,
                              offset: (if s.typ == 8: -1 else: s.offset), size: s.size)       # (8: .bss, no bytes)
  # symbols: .symtab, else .dynsym (a stripped program keeps only those)
  var tab = -1
  for i, s in shs:
    if s.typ == 2: tab = i
  if tab < 0:
    for i, s in shs:
      if s.typ == 11: tab = i
  if tab < 0: return
  let st = shs[tab]
  let strs = if st.link < shs.len: int(shs[st.link].offset) else: -1
  let esz = if st.entsize > 0: int(st.entsize) else: (if w == 8: 24 else: 16)
  let n = int(st.size) div esz
  let reloc = typ == 1                   # (an object file: a symbol's value is where it is in its section)
  for i in 1 ..< min(n, 2_000_000):
    let at = int(st.offset) + i * esz
    if at + esz > d.len: break
    var nameAt, info, shndx: int
    var value, size: int64
    if w == 8:
      nameAt = int(rd(d, at, 4, be))
      info = int(rd(d, at + 4, 1, be))
      shndx = int(rd(d, at + 6, 2, be))
      value = rd(d, at + 8, 8, be)
      size = rd(d, at + 16, 8, be)
    else:
      nameAt = int(rd(d, at, 4, be))
      value = rd(d, at + 4, 4, be)
      size = rd(d, at + 8, 4, be)
      info = int(rd(d, at + 12, 1, be))
      shndx = int(rd(d, at + 14, 2, be))
    let styp = info and 0xF
    if styp notin {0, 1, 2}: continue          # (sections and file names are not symbols one looks for)
    let name = if strs >= 0: cstr(d, strs + nameAt) else: ""
    if name.len == 0: continue
    var sym = BinSymbol(name: name, address: value, size: size, offset: -1, code: styp == 2)
    if shndx > 0 and shndx < shs.len and shndx < 0xFF00:
      let s = shs[shndx]
      sym.section = if strOff >= 0: cstr(d, strOff + s.name) else: ""
      if s.typ != 8:
        sym.offset = if reloc: s.offset + value else: s.offset + (value - s.address)
    r.symbols.add sym

# ── Mach-O ──

proc machoCpu(c: int): string =
  ## the processor's name for a Mach-O header's cpu type number ("cpu N" when unknown)
  case c
  of 7: "x86"
  of 0x01000007: "x86-64"
  of 12: "ARM"
  of 0x0100000C: "arm64"
  of 0x0200000C: "arm64_32"
  of 18: "PowerPC"
  of 0x01000012: "PowerPC64"
  else: "cpu " & $c

proc parseMachO(d: string, start: int, r: var BinInfo) =
  ## reads the Mach-O image that begins at `start` (0, or a slice of a universal binary) into `r`: header, then the load
  ## commands for segments and their sections, the symbol table and the entry point (LC_MAIN); only symbols defined in a
  ## section are kept. Mach-O has no symbol sizes, so each symbol is taken to run to the next one in its section (or the
  ## section's end).
  r.format = "Mach-O"
  let magic = rd(d, start, 4, false)
  let is64 = magic == 0xFEEDFACF
  let be = magic == 0xCEFAEDFE or magic == 0xCFFAEDFE   # (written the other way round)
  r.bigEndian = be
  r.bits = if is64 or magic == 0xCFFAEDFE: 64 else: 32
  let cpu = int(rd(d, start + 4, 4, be))
  r.arch = machoCpu(cpu)
  let ft = rd(d, start + 12, 4, be)
  r.kind = case ft
    of 1: "object file"
    of 2: "executable"
    of 6: "shared library (dylib)"
    of 8: "bundle"
    else: "type " & $ft
  let ncmds = int(rd(d, start + 16, 4, be))
  var at = start + (if r.bits == 64: 32 else: 28)
  var sectNames: seq[(string, int64, int64, int64)]      # (name, address, file offset, size), numbered from 1
  var symoff, nsyms, stroff = 0
  var textVm = 0'i64
  for _ in 0 ..< min(ncmds, 10_000):
    if at + 8 > d.len: break
    let cmd = rd(d, at, 4, be)
    let size = int(rd(d, at + 4, 4, be))
    if size < 8: break
    if cmd == 0x19 or cmd == 0x1:                         # LC_SEGMENT_64 / LC_SEGMENT
      let s64 = cmd == 0x19
      let seg = fixed(d, at + 8, 16)
      let vm = if s64: rd(d, at + 24, 8, be) else: rd(d, at + 24, 4, be)
      if seg == "__TEXT": textVm = vm
      let nsects = int(rd(d, at + (if s64: 64 else: 48), 4, be))
      var sa = at + (if s64: 72 else: 56)
      for _ in 0 ..< nsects:
        let sn = fixed(d, sa, 16)
        let addr0 = if s64: rd(d, sa + 32, 8, be) else: rd(d, sa + 32, 4, be)
        let sz = if s64: rd(d, sa + 40, 8, be) else: rd(d, sa + 36, 4, be)
        let off = rd(d, sa + (if s64: 48 else: 40), 4, be)
        sectNames.add (seg & "," & sn, addr0, (if off == 0: -1'i64 else: off + start), sz)
        r.sections.add BinSection(name: seg & "," & sn, address: addr0, offset: (if off == 0: -1'i64 else: off + start),
                                  size: sz)
        sa += (if s64: 80 else: 68)
    elif cmd == 0x2:                                       # LC_SYMTAB
      symoff = int(rd(d, at + 8, 4, be)) + start
      nsyms = int(rd(d, at + 12, 4, be))
      stroff = int(rd(d, at + 16, 4, be)) + start
    elif cmd == 0x80000028:                                # LC_MAIN
      r.entry = textVm + rd(d, at + 8, 8, be)
    at += size
  let nsz = if r.bits == 64: 16 else: 12
  for i in 0 ..< min(nsyms, 2_000_000):
    let sa = symoff + i * nsz
    if sa + nsz > d.len: break
    let strx = int(rd(d, sa, 4, be))
    let ntype = int(rd(d, sa + 4, 1, be))
    let nsect = int(rd(d, sa + 5, 1, be))
    let value = if r.bits == 64: rd(d, sa + 8, 8, be) else: rd(d, sa + 8, 4, be)
    if (ntype and 0xE0) != 0 or (ntype and 0x0E) != 0x0E or nsect == 0: continue   # (debug entries, undefined)
    var name = cstr(d, stroff + strx)
    if name.len == 0: continue
    var sym = BinSymbol(name: name, address: value, offset: -1)
    if nsect <= sectNames.len:
      let (sn, sa0, so, _) = sectNames[nsect - 1]
      sym.section = sn
      sym.code = sn.startsWith("__TEXT,__text")
      if so >= 0: sym.offset = so + (value - sa0)
    r.symbols.add sym
  # (Mach-O keeps no sizes: each runs to the next symbol of its section)
  var keys: seq[(int64, int)]
  for i, s in r.symbols: keys.add (s.address, i)
  keys.sort()
  let order = keys.mapIt(it[1])
  for k, i in order:
    var e = -1'i64
    for j in k + 1 ..< order.len:
      if r.symbols[order[j]].section == r.symbols[i].section and r.symbols[order[j]].address > r.symbols[i].address:
        e = r.symbols[order[j]].address
        break
    if e < 0:
      for (sn, sa0, _, sz) in sectNames:
        if sn == r.symbols[i].section: e = sa0 + sz
    if e > r.symbols[i].address: r.symbols[i].size = e - r.symbols[i].address

# ── PE ──

proc parsePe(d: string, r: var BinInfo) =
  ## reads a Windows PE file into `r`: processor, kind (DLL, executable or object file), word size, entry point,
  ## sections and the COFF symbols that a MinGW build keeps unless stripped (the size of each is the gap to the next
  ## symbol in its section). The format stays "" when there is no PE header.
  let pe = int(rd(d, 0x3C, 4, false))
  if pe <= 0 or pe + 24 > d.len or d[pe ..< pe + 4] != "PE\0\0":
    r.format = ""
    return
  r.format = "PE"
  let machine = rd(d, pe + 4, 2, false)
  r.arch = case machine
    of 0x14C: "x86"
    of 0x8664: "x86-64"
    of 0xAA64: "ARM64"
    of 0x1C4: "ARM"
    else: "machine 0x" & toHex(machine, 4)
  let nsec = int(rd(d, pe + 6, 2, false))
  let symPtr = int(rd(d, pe + 12, 4, false))
  let nsym = int(rd(d, pe + 16, 4, false))
  let optSize = int(rd(d, pe + 20, 2, false))
  let chars = rd(d, pe + 22, 2, false)
  r.kind = if (chars and 0x2000) != 0: "DLL" elif (chars and 0x2) != 0: "executable" else: "object file"
  let opt = pe + 24
  let magic = rd(d, opt, 2, false)
  r.bits = if magic == 0x20B: 64 else: 32
  let base = if r.bits == 64: rd(d, opt + 24, 8, false) else: rd(d, opt + 28, 4, false)
  if optSize > 0: r.entry = base + rd(d, opt + 16, 4, false)
  var secs: seq[(string, int64, int64, int64)]
  var at = opt + optSize
  for _ in 0 ..< min(nsec, 1000):
    if at + 40 > d.len: break
    var nm = fixed(d, at, 8)
    let vsize = rd(d, at + 8, 4, false)
    let va = rd(d, at + 12, 4, false)
    let rawSize = rd(d, at + 16, 4, false)
    let rawPtr = rd(d, at + 20, 4, false)
    secs.add (nm, base + va, (if rawPtr == 0: -1'i64 else: rawPtr), max(vsize, rawSize))
    r.sections.add BinSection(name: nm, address: base + va, offset: (if rawPtr == 0: -1'i64 else: rawPtr),
                              size: max(vsize, rawSize))
    at += 40
  # COFF symbols (MinGW keeps them unless stripped)
  if symPtr > 0 and nsym > 0:
    let strTab = symPtr + nsym * 18
    var i = 0
    while i < min(nsym, 2_000_000):
      let sa = symPtr + i * 18
      if sa + 18 > d.len: break
      var name = ""
      if rd(d, sa, 4, false) == 0: name = cstr(d, strTab + int(rd(d, sa + 4, 4, false)))
      else: name = fixed(d, sa, 8)
      let value = rd(d, sa + 8, 4, false)
      let secNum = int(cast[int16](uint16(rd(d, sa + 12, 2, false))))
      let typ = rd(d, sa + 14, 2, false)
      let cls = int(rd(d, sa + 16, 1, false))
      let aux = int(rd(d, sa + 17, 1, false))
      if secNum > 0 and secNum <= secs.len and cls in {2, 3} and name.len > 0 and not name.startsWith("."):
        let (sn, sva, so, _) = secs[secNum - 1]
        r.symbols.add BinSymbol(name: name, address: sva + value, offset: (if so >= 0: so + value else: -1),
                                code: (typ and 0x20) != 0, section: sn)
      i += 1 + aux
    var keys: seq[(int64, int)]
    for i, s in r.symbols: keys.add (s.address, i)
    keys.sort()
    let order = keys.mapIt(it[1])
    for k, idx in order:
      if k + 1 < order.len and r.symbols[order[k + 1]].section == r.symbols[idx].section:
        r.symbols[idx].size = r.symbols[order[k + 1]].address - r.symbols[idx].address

# ── what a file is ──

proc binParse*(d: string): BinInfo =
  ## what kind of binary `d` is, its sections and symbols (format "" when it is not an executable or object file)
  try:
    if d.len >= 52 and d.startsWith("\x7FELF"):
      parseElf(d, result)
    elif d.len >= 32 and rd(d, 0, 4, false) in [0xFEEDFACF'i64, 0xFEEDFACE, 0xCFFAEDFE, 0xCEFAEDFE]:
      parseMachO(d, 0, result)
    elif d.len >= 32 and rd(d, 0, 4, true) == 0xCAFEBABE'i64:
      # a universal (fat) binary: the slices are listed, the first one read
      let n = int(rd(d, 4, 4, true))
      var arches: seq[string]
      var first = -1
      for i in 0 ..< min(n, 16):
        let at = 8 + i * 20
        arches.add machoCpu(int(rd(d, at, 4, true)))
        if first < 0: first = int(rd(d, at + 8, 4, true))
      if first > 0 and first < d.len: parseMachO(d, first, result)
      result.format = "Mach-O universal (" & arches.join(", ") & ")"
    elif d.len >= 64 and d.startsWith("MZ"):
      parsePe(d, result)
  except CatchableError, Defect:
    result.note = "could not be read to the end"
  for s in result.symbols:
    if s.name in ["NimMain", "NimMainModule", "_NimMain", "NimMainInner"]: result.nim = true
  if not result.nim and result.format.len > 0:
    # (stripped: what Nim's runtime leaves in the data)
    for marker in ["NimMain", "fatal.nim", "system.nim", "@m..@s", "nimony"]:
      if marker in d:
        result.nim = true
        break
  for s in result.symbols.mitems:
    if not result.nim and "_ZN" in s.name: continue      # (C++'s names, not Nim's)
    let (n, m) = nimDemangle(s.name)
    s.nimName = n
    s.nimModule = m

proc nimSizes*(r: BinInfo): seq[(string, int64, int)] =
  ## Nim's modules by the bytes of code their procs take: (module, bytes, procs), the biggest first
  var t: Table[string, (int64, int)]
  for s in r.symbols:
    if s.nimModule.len > 0 and s.code:
      let x = t.getOrDefault(s.nimModule)
      t[s.nimModule] = (x[0] + s.size, x[1] + 1)
  for m, (b, n) in t: result.add (m, b, n)
  result.sort(proc(a, b: (string, int64, int)): int = cmp(b[1], a[1]))
