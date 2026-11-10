## Assembly the way Compiler Explorer (godbolt.org) shows it: a compiler's `-S` output, or an object file
## disassembled by objdump, read line by line — each instruction with the line of the source it came from (the
## `.loc` directives, objdump -l), and the noise left out: directives, labels nothing jumps to, comments, the
## functions of other files (the runtime, the standard library), Nim's mangled names written as in Nim. Then what an
## instruction or a register is (x86-64 and ARM64), for the hover. A module of its own: tests/unit/tasmview.nim.

import std/[strutils, tables, sets, os]
import binfmt

type
  AsmKind* = enum akInsn, akLabel, akData, akComment, akDirective, akNote
  AsmLine* = object
    text*: string          # as shown
    kind*: AsmKind
    src*: int              # the line of the main file (0-based) it came from, -1: none
    fn*: string            # the function it is in, as shown ("" outside one)
  AsmFilters* = object
    labels*, library*, directives*, comments*, demangle*: bool
  AsmResult* = object
    lines*: seq[AsmLine]
    total*: int            # lines the compiler wrote
    arch*: string          # "x86_64", "arm64" — "" when the instructions do not say
    functions*: seq[string]   # the functions shown, in order

const AllFilters* = AsmFilters(labels: true, library: true, directives: true, comments: true, demangle: true)

const DataDirectives = [".string", ".ascii", ".asciz", ".byte", ".short", ".value", ".word", ".hword", ".long",
                        ".int", ".quad", ".xword", ".zero", ".octa", ".float", ".double", ".2byte", ".4byte",
                        ".8byte", ".dc.a", ".skip", ".space", ".base64"]

# whether a character can start a name (a label, symbol or mnemonic) in assembly: a letter, `_`, `.` or `$`
func asmNameStart(c: char): bool = c in {'A'..'Z', 'a'..'z', '_', '.', '$'}
# whether a character can continue such a name: the starting ones, digits and `@` (as in `memcpy@PLT`)
func asmNameChar(c: char): bool = c in {'A'..'Z', 'a'..'z', '0'..'9', '_', '.', '$', '@'}

proc quoted(s: string): seq[string] =
  ## the "…" strings of a directive, in order
  var i = 0
  while i < s.len:
    if s[i] == '"':
      var j = i + 1
      var w = ""
      while j < s.len and s[j] != '"':
        if s[j] == '\\' and j + 1 < s.len:
          inc j
        w.add s[j]
        inc j
      result.add w
      i = j + 1
    else: inc i

func commentStart(s: string, arm: bool): int =
  ## where an end-of-line comment starts (outside strings): `#` on x86, `//` and `@` on ARM — or -1
  var inStr = false
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '"' and (i == 0 or s[i - 1] != '\\'): inStr = not inStr
    elif not inStr:
      if not arm and c == '#': return i
      if c == '/' and i + 1 < s.len and s[i + 1] == '/': return i
      if arm and c == '@' and (i == 0 or s[i - 1] in {' ', '\t'}): return i
      if c == ';' and not arm and i > 0 and s[i - 1] in {' ', '\t'}: return i
    inc i
  -1

func labelOf(raw: string): string =
  ## `name:` at the start of a line (what follows may be a comment) → name, else ""
  if raw.len == 0 or raw[0] in {' ', '\t', '#'} or (raw.len > 1 and raw[0] == '/' and raw[1] == '/'): return ""
  var i = 0
  if raw[0] == '"':
    let e = raw.find('"', 1)
    if e < 0 or e + 1 >= raw.len or raw[e + 1] != ':': return ""
    return raw[1 ..< e]
  while i < raw.len and asmNameChar(raw[i]): inc i
  if i > 0 and i < raw.len and raw[i] == ':': raw[0 ..< i] else: ""

proc demangleIn*(s: string): string =
  ## the identifiers in an instruction's text with Nim's mangled names written as in Nim (square__m_u3 → square)
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if asmNameStart(s[i]) and (i == 0 or not asmNameChar(s[i - 1])):
      var j = i
      while j < s.len and asmNameChar(s[j]) and s[j] != '@': inc j      # (name@PLT, name@gottpoff: the name)
      let w = s[i ..< j]
      var nm = ""
      if "__" in w or w.startsWith("_ZN"):
        try: nm = nimDemangle(w)[0]
        except CatchableError: nm = ""
        # (an operator — `$`, `+`, `==` — in backticks, as Nim writes its name)
        if nm.len > 0 and not (nm[0] in {'A'..'Z', 'a'..'z', '_'} or nm[0] >= '\x80'): nm = "`" & nm & "`"
      result.add (if nm.len > 0: nm else: w)
      i = j
    else:
      result.add s[i]
      inc i

func formatInsn(t: string): string =
  ## an instruction as Compiler Explorer lays it out: indented, its mnemonic in a column of its own
  var s = t.replace('\t', ' ').strip
  var k = 0
  while k < s.len and s[k] notin {' '}: inc k
  let mn = s[0 ..< k]
  let rest = s[k .. ^1].strip
  if rest.len > 0: "        " & alignLeft(mn, 7) & " " & rest
  else: "        " & mn

func archOfInsn(mn, ops: string): string =
  ## x86_64 / arm64 by the registers an instruction names ("" when it names none)
  for w0 in ops.split({' ', ',', '[', ']', '!', '#', '\t', '(', ')', ':'}):
    let x = w0.strip(chars = {'%'})
    if x.len >= 2 and x[0] in {'x', 'w'} and x[1 .. ^1].allCharsInSet(Digits): return "arm64"
    if x in ["rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rsp", "rbp", "rip", "eax", "ebx", "ecx", "edx", "esi", "edi",
             "esp", "ebp"] or (x.len >= 2 and x[0] == 'r' and x[1] in Digits): return "x86_64"
  ""

proc parseGas*(text, mainPath: string, f: AsmFilters): AsmResult =
  ## a compiler's assembly (gcc's or clang's -S, GNU as syntax, Intel or AT&T, x86 or ARM)
  type Raw = object
    t: string             # the line, trimmed
    kind: AsmKind
    src: int
    fn: string
    section: int          # 0 code · 1 data · 2 what is never shown when directives are left out (debug info …)
    label: string
  var files: Table[int, string]
  var compDir = ""
  var mainFiles: HashSet[int]
  var fnTypes: HashSet[string]
  var raws: seq[Raw]
  var curSrc = -1
  var section = 0
  var curFn = ""
  let mainN = normalizedPath(mainPath)
  let mainBase = extractFilename(mainPath)
  proc isMain(p: string): bool =
    ## is the path (as a `.file` or a comment names it) the program's file?
    let pn = normalizedPath(p)
    pn == mainN or (not p.isAbsolute and extractFilename(p) == mainBase) or
      (pn.endsWith("/" & mainBase) and mainN.endsWith(pn))
  proc inlinedAt(t: string): (string, int) =
    ## where clang's comment on a `.loc` says the code was inlined, the outermost place ("… @[ a.nim:3:1 @[ ex.nim:2:7
    ## ] ]" — the last): (its file, its line); ("", 0) when it says none
    let k = t.rfind("@[ ")
    if k < 0: return ("", 0)
    var e = k + 3
    while e < t.len and t[e] notin {' ', ']'}: inc e
    let parts = t[k + 3 ..< e].rsplit(':', maxsplit = 2)
    if parts.len < 3: return ("", 0)
    try: result = (parts[0], parseInt(parts[1]))
    except ValueError: result = ("", 0)
  var arm = false
  var machO = false                  # (clang on macOS: Mach-O sections, its own labels start with L)
  let allLines = text.splitLines
  result.total = allLines.len
  for raw0 in allLines:
    let raw = raw0.strip(leading = false)
    let t = raw.strip
    if t.len == 0: continue
    let lab = labelOf(raw)
    if lab.len > 0:
      # (a function's name — not a label of the assembler's own: .L5 here, and on macOS every name without the `_`
      # C names have there: Ltmp0, LBB0_2, Lfunc_begin0)
      let local = lab.startsWith(".") or (machO and not lab.startsWith("_"))
      if section == 0 and (lab in fnTypes or not local): curFn = lab
      raws.add Raw(t: lab & ":", kind: akLabel, src: -1, fn: curFn, section: section, label: lab)
      continue
    if t.startsWith("#") or t.startsWith("//") or (arm and t.startsWith("@")) or t.startsWith(";"):
      raws.add Raw(t: t, kind: akComment, src: -1, fn: curFn, section: section)
      continue
    if t[0] == '.':
      var word = t
      let sp = t.find({' ', '\t'})
      if sp > 0: word = t[0 ..< sp]
      let args = if sp > 0: t[sp .. ^1].strip else: ""
      case word
      of ".file":
        let q = quoted(args)
        var n = -1
        let a0 = args.split({' ', '\t'})[0]
        try: n = parseInt(a0)
        except ValueError: n = -1
        if n >= 0 and q.len > 0:
          var p = if q.len >= 2: (if q[1].isAbsolute: q[1] else: q[0] / q[1]) else: q[0]
          if n == 0 and q.len >= 1: compDir = q[0]
          if not p.isAbsolute and compDir.len > 0: p = compDir / p
          files[n] = p
          if isMain(p): mainFiles.incl n
      of ".loc":
        let ps = args.split({' ', '\t'})
        var n, ln: int
        try:
          n = parseInt(ps[0])
          ln = parseInt(ps[1])
        except CatchableError: continue
        curSrc = if n in mainFiles and ln > 0: ln - 1 else: -1
        if curSrc < 0:
          # code of another file inlined into the program's — Nim's nimMulInt into `num * num` (clang on macOS):
          # the line of the program it is inlined at, from clang's comment "… @[ ex.nim:2:7 ]"
          let (f, l) = inlinedAt(t)
          if l > 0 and isMain(f): curSrc = l - 1
      of ".build_version", ".macosx_version_min", ".ios_version_min": machO = true
      of ".text": section = 0
      of ".data", ".bss": section = 1
      of ".section", ".pushsection":
        let nm = args.split({',', ' ', '\t'})[0]
        # (Mach-O, clang on macOS: a segment and a section — __TEXT,__text is the code, __TEXT,__cstring or
        # __DATA,__data the data, __DWARF … never shown)
        let machSect = if nm.startsWith("__"): args.split({','})[min(1, args.split({','}).high)].strip else: ""
        if nm.startsWith("__"): machO = true
        section = if nm == "__TEXT" and machSect == "__text": 0
                  elif nm in ["__TEXT", "__DATA", "__DATA_CONST"] and machSect in
                       ["__cstring", "__const", "__literal4", "__literal8", "__literal16", "__data", "__bss",
                        "__common", "__mod_init_func"]: 1
                  elif nm.startsWith("__"): 2
                  elif nm.startsWith(".text"): 0
                  elif nm.startsWith(".rodata") or nm.startsWith(".data") or nm.startsWith(".bss") or
                       nm.startsWith(".tdata") or nm.startsWith(".tbss") or nm.startsWith(".lit") or
                       nm.startsWith(".cstring") or nm.startsWith("__TEXT,__cstring") or nm.startsWith(".init_array"):
                    1
                  else: 2
      of ".type":
        let ps = args.split({',', ' ', '\t'})
        if ps.len >= 2 and ("function" in args): fnTypes.incl ps[0]
      of ".arch", ".cpu": arm = true
      else: discard
      let k = if section == 1 and word in DataDirectives: akData else: akDirective
      raws.add Raw(t: t, kind: k, src: -1, fn: curFn, section: section)
      continue
    # an instruction
    if section != 0:
      raws.add Raw(t: t, kind: akData, src: -1, fn: curFn, section: section)
      continue
    let mn = t.split({' ', '\t'})[0]
    if result.arch.len == 0:
      result.arch = archOfInsn(mn, t[mn.len .. ^1].strip)
      if result.arch == "arm64": arm = true
    raws.add Raw(t: t, kind: akInsn, src: curSrc, fn: curFn, section: 0)
  if not f.directives and not f.labels and not f.comments and not f.library:
    # (nothing left out: the compiler's text as it is, the lines still known)
    for r in raws:
      result.lines.add AsmLine(text: (if r.kind == akInsn: formatInsn(r.t) elif r.kind == akLabel: r.t
                                     else: "        " & r.t), kind: r.kind, src: r.src, fn: r.fn)
    return
  # the functions with code of the main file (the library filter keeps only those — or all, when none has)
  var fnHasMain: HashSet[string]
  for r in raws:
    if r.kind == akInsn and r.src >= 0: fnHasMain.incl r.fn
  let libOn = f.library and fnHasMain.len > 0
  var keep = newSeq[bool](raws.len)
  for i, r in raws:
    keep[i] = true
    if r.section == 2 and f.directives: keep[i] = false
    elif r.section == 0 and libOn and r.fn.len > 0 and r.fn notin fnHasMain: keep[i] = false
    elif r.section == 0 and libOn and r.fn.len == 0 and r.kind in {akInsn, akLabel}: keep[i] = false
    if r.kind == akDirective and f.directives: keep[i] = false
    if r.kind == akComment and f.comments: keep[i] = false
  # the labels the kept code uses (and the data under them)
  var used: HashSet[string]
  for i, r in raws:
    if keep[i] and r.kind == akInsn:
      var j = 0
      let s = r.t
      while j < s.len:
        if asmNameStart(s[j]) and (j == 0 or not asmNameChar(s[j - 1])):
          var e = j
          while e < s.len and asmNameChar(s[e]): inc e
          let w = s[j ..< e]
          used.incl w
          if w.startsWith("$"): used.incl w[1 .. ^1]          # (AT&T: $.LC0)
          j = e
        else: inc j
  # data: a used label's lines in a data section (strings, constants) — they may use labels in turn
  var changed = true
  var rounds = 0
  while changed and rounds < 4:
    changed = false
    inc rounds
    var inUsed = false
    for i, r in raws:
      if r.section != 1: continue
      if r.kind == akLabel: inUsed = r.label in used
      elif r.kind == akData and inUsed:
        for w in r.t.split({' ', '\t', ',', '+', '-'}):
          if w.len > 0 and asmNameStart(w[0]) and w notin used and not w.startsWith("."):
            used.incl w
            changed = true
          elif w.startsWith(".L") and w notin used:
            used.incl w
            changed = true
  var inUsed = false
  for i, r in raws:
    if r.section == 1:
      if r.kind == akLabel: inUsed = r.label in used
      if f.directives or f.labels:
        if r.kind == akLabel and not inUsed: keep[i] = false
        if r.kind == akData and not inUsed: keep[i] = false
    elif r.kind == akLabel and keep[i] and f.labels:
      let isFn = r.label in fnTypes or (not r.label.startsWith(".") and r.label == r.fn)
      if not isFn and r.label notin used: keep[i] = false
  # what is shown
  for i, r in raws:
    if not keep[i]: continue
    var t = r.t
    if f.comments and r.kind in {akInsn, akLabel, akData}:
      let c = commentStart(t, arm)
      if c > 0: t = t[0 ..< c].strip(leading = false)
    if f.demangle: t = demangleIn(t)
    let fnShown = if f.demangle: demangleIn(r.fn) else: r.fn
    case r.kind
    of akInsn: result.lines.add AsmLine(text: formatInsn(t), kind: akInsn, src: r.src, fn: fnShown)
    of akLabel:
      result.lines.add AsmLine(text: t, kind: akLabel, src: -1, fn: fnShown)
      if r.section == 0 and r.label == r.fn and fnShown notin result.functions: result.functions.add fnShown
    else:
      var d = t.replace('\t', ' ')
      while "  " in d and not d.contains('"'): d = d.replace("  ", " ")
      result.lines.add AsmLine(text: "        " & d, kind: r.kind, src: -1, fn: fnShown)

proc parseObjdump*(text, mainPath: string, f: AsmFilters): AsmResult =
  ## `objdump -d -r -l --no-show-raw-insn` of an object file: the functions, the source lines (-l), the call
  ## targets from the relocations (-r) written in the instruction
  type Fn = object
    name: string
    lines: seq[AsmLine]
    hasMain: bool
  var fns: seq[Fn]
  var curSrc = -1
  let mainN = normalizedPath(mainPath)
  let mainBase = extractFilename(mainPath)
  let allLines = text.splitLines
  result.total = allLines.len
  for raw in allLines:
    let t = raw.strip
    if t.len == 0 or "file format" in t or t.startsWith("Disassembly of section"): continue
    # 0000000000000000 <square>:
    if t.endsWith(">:") and t.find(" <") > 0 and t[0] in HexDigits:
      let nm = t[t.find(" <") + 2 ..< t.len - 2]
      fns.add Fn(name: nm)
      curSrc = -1
      continue
    if t.endsWith("():") and ' ' notin t: continue          # (objdump -l: the function's name again)
    # /path/to/file.nim:12 (discriminator 3)
    if (t.startsWith("/") or t.contains(".nim:") or t.contains(".c:") or t.contains(".h:")) and ':' in t and
       not t.contains("\t") and raw.len > 0 and raw[0] notin {' ', '\t'}:
      var p = t
      let d = p.find(" (")
      if d > 0: p = p[0 ..< d]
      let c = p.rfind(':')
      if c > 0:
        var ln = 0
        try: ln = parseInt(p[c + 1 .. ^1])
        except ValueError: ln = 0
        let fp = p[0 ..< c]
        let isMain = normalizedPath(fp) == mainN or extractFilename(fp) == mainBase
        curSrc = if isMain and ln > 0: ln - 1 else: -1
      continue
    if fns.len == 0: continue
    # a relocation: its symbol goes into the instruction before it
    let tab = t.find('\t')
    if t.contains(": R_") and tab > 0:
      var sym = t[tab + 1 .. ^1].strip
      for cut in ["-0x", "+0x"]:
        let k = sym.find(cut)
        if k > 0: sym = sym[0 ..< k]
      if f.demangle: sym = demangleIn(sym)
      if fns[^1].lines.len > 0 and fns[^1].lines[^1].kind == akInsn:
        var s = fns[^1].lines[^1].text
        let lt = s.find(" <")
        if lt > 0 and s.endsWith(">"):
          # `call   23 <square+0x23>` → `call   raiseOverflow`
          var a = lt
          while a > 0 and s[a - 1] in HexDigits: dec a
          s = s[0 ..< a] & sym
        elif not s.contains(sym): s.add "  # " & sym
        fns[^1].lines[^1].text = s
      continue
    # an instruction:    1e:	call   23 <square+0x23>
    let colon = t.find(':')
    if colon > 0 and tab > colon and t[0 ..< colon].allCharsInSet(HexDigits):
      var ins = t[tab + 1 .. ^1].strip
      if ins.len == 0: continue
      if f.demangle: ins = demangleIn(ins)
      let mn = ins.split({' ', '\t'})[0]
      if result.arch.len == 0: result.arch = archOfInsn(mn, ins[mn.len .. ^1].strip)
      # (its address in front: what a jump's `18 <square+0x18>` points at)
      let shown = align(t[0 ..< colon] & ":", 7) & " " & formatInsn(ins).strip(trailing = false)
      fns[^1].lines.add AsmLine(text: shown, kind: akInsn, src: curSrc, fn: fns[^1].name)
      if curSrc >= 0: fns[^1].hasMain = true
  var anyMain = false
  for fn in fns:
    if fn.hasMain: anyMain = true
  for fn in fns:
    if f.library and anyMain and not fn.hasMain: continue
    let nm = if f.demangle: demangleIn(fn.name) else: fn.name
    result.functions.add nm
    result.lines.add AsmLine(text: nm & ":", kind: akLabel, src: -1, fn: nm)
    for l in fn.lines:
      var x = l
      x.fn = nm
      result.lines.add x

# ── what an instruction and a register are (the hover) ──

const X86Docs = [
  ("mov", "Copy the source to the destination"),
  ("movabs", "Copy a 64-bit immediate (or absolute address) into a register"),
  ("movzx", "Copy a smaller value, filling the upper bits with zeros (zero-extend)"),
  ("movsx", "Copy a smaller signed value, filling the upper bits with its sign (sign-extend)"),
  ("movsxd", "Copy a 32-bit signed value into a 64-bit register, sign-extended"),
  ("movzb", "Zero-extend a byte (AT&T: movzbl, movzbq)"), ("movsb", "Sign-extend a byte (AT&T: movsbl …)"),
  ("cdqe", "Sign-extend eax into rax"), ("cqo", "Sign-extend rax into rdx:rax (before idiv)"),
  ("cdq", "Sign-extend eax into edx:eax (before idiv)"),
  ("lea", "Load effective address: computes the address expression (often plain arithmetic) without touching memory"),
  ("push", "Decrease rsp and store the operand on the stack"), ("pop", "Load the top of the stack, then increase rsp"),
  ("add", "Add the source to the destination (sets the flags)"),
  ("sub", "Subtract the source from the destination (sets the flags)"),
  ("adc", "Add with the carry flag"), ("sbb", "Subtract with borrow (the carry flag)"),
  ("inc", "Add 1"), ("dec", "Subtract 1"), ("neg", "Two's complement negation"),
  ("imul", "Signed multiply (sets OF/CF on overflow — Nim's overflow checks test them with jo)"),
  ("mul", "Unsigned multiply: rdx:rax = rax × operand"),
  ("idiv", "Signed divide rdx:rax by the operand: quotient in rax, remainder in rdx"),
  ("div", "Unsigned divide rdx:rax by the operand: quotient in rax, remainder in rdx"),
  ("and", "Bitwise AND"), ("or", "Bitwise OR"), ("xor", "Bitwise XOR — `xor eax, eax` sets a register to 0"),
  ("not", "Bitwise NOT"), ("shl", "Shift left"), ("sal", "Shift left"), ("shr", "Logical shift right (zeros in)"),
  ("sar", "Arithmetic shift right (the sign bit in)"), ("rol", "Rotate left"), ("ror", "Rotate right"),
  ("shld", "Double-precision shift left"), ("shrd", "Double-precision shift right"),
  ("bt", "Bit test: copy a bit into the carry flag"), ("bts", "Bit test and set"), ("btr", "Bit test and reset"),
  ("bsf", "Bit scan forward: index of the lowest set bit"), ("bsr", "Bit scan reverse: index of the highest set bit"),
  ("tzcnt", "Count trailing zero bits"), ("lzcnt", "Count leading zero bits"), ("popcnt", "Count the set bits"),
  ("cmp", "Compare: subtract without storing, setting the flags for a following jump or set"),
  ("test", "Bitwise AND without storing, setting the flags (`test rax, rax`: is it zero / negative?)"),
  ("jmp", "Jump unconditionally"), ("call", "Push the return address and jump to a function"),
  ("ret", "Return: pop the return address and jump to it"),
  ("leave", "Restore the caller's frame: mov rsp, rbp; pop rbp"),
  ("nop", "No operation (padding, alignment)"), ("endbr64", "Indirect-branch target marker (Intel CET); does nothing else"),
  ("ud2", "Undefined instruction: traps on purpose (unreachable code)"), ("int3", "Breakpoint trap"),
  ("hlt", "Halt"), ("syscall", "Call the operating system"), ("cpuid", "Ask the processor what it is"),
  ("rdtsc", "Read the time-stamp counter"), ("pause", "Spin-wait hint"), ("lock", "Make the next instruction atomic"),
  ("xchg", "Exchange two operands (atomic with memory)"), ("cmpxchg", "Compare and exchange (atomic with lock)"),
  ("xadd", "Exchange and add (atomic with lock)"), ("mfence", "Memory fence"), ("sfence", "Store fence"),
  ("lfence", "Load fence"), ("rep", "Repeat the string instruction rcx times"),
  ("movs", "Copy memory [rsi] → [rdi] (string move)"), ("stos", "Store rax into [rdi] (string store)"),
  ("cmps", "Compare [rsi] and [rdi]"), ("scas", "Compare rax with [rdi]"),
  ("cmov", "Conditional move: copy only when the condition holds (no jump)"),
  ("set", "Set a byte to 1 when the condition holds, else 0"),
  ("movd", "Move 32 bits between a general register and an SSE register"),
  ("movq", "Move 64 bits between registers (SSE), or a quadword (AT&T)"),
  ("movss", "Move a single-precision float"), ("movsd", "Move a double-precision float"),
  ("movaps", "Move aligned packed singles (whole 128-bit register)"), ("movups", "Move unaligned packed singles"),
  ("movapd", "Move aligned packed doubles"), ("movupd", "Move unaligned packed doubles"),
  ("movdqa", "Move an aligned 128-bit integer vector"), ("movdqu", "Move an unaligned 128-bit integer vector"),
  ("addss", "Add single floats"), ("addsd", "Add double floats"), ("subss", "Subtract single floats"),
  ("subsd", "Subtract double floats"), ("mulss", "Multiply single floats"), ("mulsd", "Multiply double floats"),
  ("divss", "Divide single floats"), ("divsd", "Divide double floats"), ("sqrtsd", "Square root of a double"),
  ("sqrtss", "Square root of a single"), ("minsd", "Minimum of doubles"), ("maxsd", "Maximum of doubles"),
  ("ucomisd", "Compare doubles (unordered), setting the flags"), ("comisd", "Compare doubles, setting the flags"),
  ("ucomiss", "Compare singles (unordered), setting the flags"), ("comiss", "Compare singles, setting the flags"),
  ("cvtsi2sd", "Convert an integer to a double"), ("cvtsi2ss", "Convert an integer to a single"),
  ("cvttsd2si", "Convert a double to an integer, truncating"), ("cvttss2si", "Convert a single to an integer, truncating"),
  ("cvtsd2ss", "Convert a double to a single"), ("cvtss2sd", "Convert a single to a double"),
  ("pxor", "Bitwise XOR of vectors (pxor x, x: zero)"), ("xorps", "Bitwise XOR of float vectors (zeroing)"),
  ("xorpd", "Bitwise XOR of double vectors"), ("andpd", "Bitwise AND of double vectors (abs: clear the sign)"),
  ("paddd", "Add packed 32-bit integers"), ("paddq", "Add packed 64-bit integers"), ("psubd", "Subtract packed 32-bit integers"),
  ("pmulld", "Multiply packed 32-bit integers"), ("pshufd", "Shuffle packed 32-bit integers"),
  ("punpcklqdq", "Interleave the low quadwords"), ("vmovdqu", "AVX: move an unaligned vector"),
  ("vmovups", "AVX: move unaligned packed singles"), ("vpaddd", "AVX: add packed 32-bit integers"),
  ("vzeroupper", "AVX: clear the upper halves of the ymm registers (before SSE code or a call)"),
  ("prefetcht0", "Prefetch into all cache levels"), ("cwde", "Sign-extend ax into eax"),
  ("bswap", "Reverse the byte order"), ("rorx", "Rotate right without touching the flags (BMI2)"),
  ("andn", "AND NOT (BMI1)"), ("blsr", "Reset the lowest set bit (BMI1)"), ("shlx", "Shift left without the flags (BMI2)"),
  ("sarx", "Arithmetic shift right without the flags (BMI2)"), ("shrx", "Logical shift right without the flags (BMI2)")]

const X86Cond = [("o", "overflow"), ("no", "not overflow"), ("b", "below (unsigned <)"), ("c", "carry"),
  ("nae", "not above or equal (unsigned <)"), ("nb", "not below (unsigned >=)"), ("nc", "no carry"),
  ("ae", "above or equal (unsigned >=)"), ("e", "equal (zero)"), ("z", "zero"), ("ne", "not equal (not zero)"),
  ("nz", "not zero"), ("be", "below or equal (unsigned <=)"), ("na", "not above (unsigned <=)"),
  ("a", "above (unsigned >)"), ("nbe", "not below or equal (unsigned >)"), ("s", "sign (negative)"),
  ("ns", "not sign (zero or positive)"), ("p", "parity (also: unordered float compare)"), ("np", "no parity"),
  ("l", "less (signed <)"), ("nge", "not greater or equal (signed <)"), ("ge", "greater or equal (signed >=)"),
  ("nl", "not less (signed >=)"), ("le", "less or equal (signed <=)"), ("ng", "not greater (signed <=)"),
  ("g", "greater (signed >)"), ("nle", "not less or equal (signed >)")]

const ArmDocs = [
  ("mov", "Copy a register or an immediate"), ("movz", "Move a 16-bit immediate, zeroing the rest"),
  ("movk", "Move a 16-bit immediate into one part, keeping the rest"), ("movn", "Move the inverted immediate"),
  ("mvn", "Bitwise NOT"), ("add", "Add"), ("adds", "Add, setting the flags"), ("sub", "Subtract"),
  ("subs", "Subtract, setting the flags"), ("adc", "Add with carry"), ("sbc", "Subtract with carry"),
  ("neg", "Negate"), ("negs", "Negate, setting the flags"),
  ("mul", "Multiply (the low 64 bits)"), ("madd", "Multiply and add: d = a × b + c"),
  ("msub", "Multiply and subtract: d = c − a × b (the remainder after a division)"),
  ("smulh", "Signed multiply, the high 64 bits (overflow checks compare it with the low half)"),
  ("umulh", "Unsigned multiply, the high 64 bits"), ("smull", "Signed 32 × 32 → 64-bit multiply"),
  ("umull", "Unsigned 32 × 32 → 64-bit multiply"), ("sdiv", "Signed divide"), ("udiv", "Unsigned divide"),
  ("and", "Bitwise AND"), ("ands", "Bitwise AND, setting the flags"), ("orr", "Bitwise OR"),
  ("eor", "Bitwise exclusive OR"), ("bic", "Bit clear: AND NOT"), ("orn", "OR NOT"),
  ("lsl", "Logical shift left"), ("lsr", "Logical shift right"), ("asr", "Arithmetic shift right"),
  ("ror", "Rotate right"), ("ubfx", "Extract unsigned bits"), ("sbfx", "Extract signed bits"),
  ("ubfiz", "Insert bits in zero, unsigned"), ("bfi", "Insert a bit field"), ("bfxil", "Insert low bits"),
  ("sxtw", "Sign-extend a 32-bit word"), ("sxtb", "Sign-extend a byte"), ("sxth", "Sign-extend a halfword"),
  ("uxtb", "Zero-extend a byte"), ("uxth", "Zero-extend a halfword"), ("clz", "Count leading zeros"),
  ("rbit", "Reverse the bits"), ("rev", "Reverse the bytes"), ("cnt", "Count set bits per byte (SIMD)"),
  ("cmp", "Compare: subtract and set the flags, keeping nothing"), ("cmn", "Compare negative: add and set the flags"),
  ("tst", "Test bits: AND and set the flags"), ("ccmp", "Conditional compare"),
  ("csel", "Select: d = condition ? a : b"), ("csinc", "Select or increment"), ("csinv", "Select or invert"),
  ("csneg", "Select or negate"), ("cset", "Set to 1 when the condition holds, else 0"),
  ("csetm", "Set to all ones when the condition holds, else 0"), ("cinc", "Increment when the condition holds"),
  ("b", "Branch (jump)"), ("bl", "Branch with link: call a function (the return address in x30)"),
  ("br", "Branch to an address in a register"), ("blr", "Call the function whose address is in a register"),
  ("ret", "Return to the address in x30 (the link register)"), ("cbz", "Branch if zero"),
  ("cbnz", "Branch if not zero"), ("tbz", "Branch if a bit is zero"), ("tbnz", "Branch if a bit is set"),
  ("ldr", "Load a register from memory"), ("ldrb", "Load a byte (zero-extended)"),
  ("ldrh", "Load a halfword (zero-extended)"), ("ldrsb", "Load a signed byte"), ("ldrsh", "Load a signed halfword"),
  ("ldrsw", "Load a signed word into a 64-bit register"), ("ldur", "Load from an unscaled offset"),
  ("str", "Store a register to memory"), ("strb", "Store a byte"), ("strh", "Store a halfword"),
  ("stur", "Store to an unscaled offset"), ("ldp", "Load a pair of registers"), ("stp", "Store a pair of registers"),
  ("ldar", "Load-acquire (atomic ordering)"), ("stlr", "Store-release (atomic ordering)"),
  ("ldxr", "Load exclusive (for an atomic loop)"), ("stxr", "Store exclusive (for an atomic loop)"),
  ("ldaxr", "Load-acquire exclusive"), ("stlxr", "Store-release exclusive"), ("cas", "Compare and swap (atomic)"),
  ("ldadd", "Atomic add"), ("swp", "Atomic swap"), ("adr", "Address of a label (pc-relative)"),
  ("adrp", "Address of a label's 4 KB page (pc-relative); an add or ldr with :lo12: completes it"),
  ("nop", "No operation"), ("brk", "Breakpoint trap (also: unreachable)"), ("svc", "Call the operating system"),
  ("dmb", "Data memory barrier"), ("dsb", "Data synchronization barrier"), ("isb", "Instruction barrier"),
  ("mrs", "Read a system register (tpidr_el0: thread-local storage)"), ("msr", "Write a system register"),
  ("paciasp", "Sign the return address (pointer authentication)"), ("autiasp", "Check the signed return address"),
  ("bti", "Branch target marker (BTI)"), ("fmov", "Move a float, or between float and integer registers"),
  ("fadd", "Float add"), ("fsub", "Float subtract"), ("fmul", "Float multiply"), ("fdiv", "Float divide"),
  ("fmadd", "Fused float multiply-add"), ("fsqrt", "Float square root"), ("fabs", "Float absolute value"),
  ("fneg", "Float negate"), ("fcmp", "Float compare, setting the flags"), ("fcsel", "Float select"),
  ("scvtf", "Convert a signed integer to a float"), ("ucvtf", "Convert an unsigned integer to a float"),
  ("fcvtzs", "Convert a float to a signed integer, toward zero"), ("fcvtzu", "Convert a float to an unsigned integer"),
  ("fcvt", "Convert between float sizes"), ("dup", "Duplicate a value into every lane (SIMD)"),
  ("ld1", "Load vector lanes"), ("st1", "Store vector lanes"), ("addv", "Add every lane together (SIMD)"),
  ("movi", "Move an immediate into vector lanes"), ("umov", "Move a vector lane to a general register"),
  ("ins", "Insert into a vector lane")]

const ArmCond = [("eq", "equal"), ("ne", "not equal"), ("cs", "carry set (unsigned >=)"),
  ("hs", "unsigned higher or same (>=)"), ("cc", "carry clear (unsigned <)"), ("lo", "unsigned lower (<)"),
  ("mi", "minus (negative)"), ("pl", "plus (zero or positive)"), ("vs", "overflow"), ("vc", "no overflow"),
  ("hi", "unsigned higher (>)"), ("ls", "unsigned lower or same (<=)"), ("ge", "signed >="), ("lt", "signed <"),
  ("gt", "signed >"), ("le", "signed <="), ("al", "always")]

proc docIn(tab: openArray[(string, string)], m: string): string =
  ## the text a table of (mnemonic, explanation) pairs has for `m`, "" when it has none
  for (k, v) in tab:
    if k == m: return v
  ""

proc condIn(tab: openArray[(string, string)], c: string): string =
  ## the words a table of (condition code, meaning) pairs has for `c` (`ne` → not equal), "" when it has none
  for (k, v) in tab:
    if k == c: return v
  ""

proc asmDoc*(mnemonic: string, arm: bool): string =
  ## what an instruction does, in a line ("" when it is not one ned knows)
  let m = mnemonic.toLowerAscii.strip
  if m.len == 0: return
  if arm:
    let d = docIn(ArmDocs, m)
    if d.len > 0: return d
    if m.startsWith("b.") and condIn(ArmCond, m[2 .. ^1]).len > 0:
      return "Branch if " & condIn(ArmCond, m[2 .. ^1])
    return ""
  var d = docIn(X86Docs, m)
  if d.len > 0: return d
  if m.len > 1 and m[0] == 'j' and condIn(X86Cond, m[1 .. ^1]).len > 0:
    return "Jump if " & condIn(X86Cond, m[1 .. ^1]) & " (the flags of the last cmp, test or arithmetic)"
  if m.startsWith("set") and condIn(X86Cond, m[3 .. ^1]).len > 0:
    return "Set a byte to 1 if " & condIn(X86Cond, m[3 .. ^1]) & ", else 0"
  if m.startsWith("cmov") and condIn(X86Cond, m[4 .. ^1]).len > 0:
    return "Move if " & condIn(X86Cond, m[4 .. ^1]) & " (a branch-free select)"
  # AT&T: the size as a suffix (movq, addl, cmpb …)
  if m.len > 2 and m[^1] in {'b', 'w', 'l', 'q'}:
    d = docIn(X86Docs, m[0 ..< m.high])
    if d.len > 0:
      return d & " (" & (case m[^1]
                         of 'b': "8"
                         of 'w': "16"
                         of 'l': "32"
                         else: "64") & "-bit)"
  for p in ["rep ", "lock "]:
    if m.startsWith(p): return docIn(X86Docs, p.strip) & ": " & asmDoc(m[p.len .. ^1], false)
  ""

proc asmRegDoc*(reg: string, arm: bool): string =
  ## what a register is for (System V on x86-64 — Linux, macOS, Termux —, AAPCS64 on ARM64)
  var r = reg.toLowerAscii.strip(chars = {'%', ' '})
  if arm:
    if r in ["sp", "wsp"]: return "The stack pointer"
    if r in ["xzr", "wzr"]: return "The zero register: reads as 0, writes go nowhere"
    if r in ["lr", "x30"]: return "x30, the link register: the return address of a bl"
    if r in ["fp", "x29"]: return "x29, the frame pointer"
    if r.len >= 2 and r[0] in {'x', 'w'} and r[1 .. ^1].allCharsInSet(Digits):
      let n = parseInt(r[1 .. ^1])
      let size = if r[0] == 'w': " (its low 32 bits)" else: ""
      return (case n
              of 0: "x0: the first argument, and the return value"
              of 1 .. 7: "x" & $n & ": argument " & $(n + 1) & " (x1 also the second half of a returned pair)"
              of 8: "x8: the address for a returned struct (indirect result); else scratch"
              of 9 .. 15: "x" & $n & ": scratch (a call may change it)"
              of 16, 17: "x" & $n & ": scratch for calls between modules (IP" & $(n - 16) & ")"
              of 18: "x18: the platform register (reserved on some systems)"
              of 19 .. 28: "x" & $n & ": kept across calls (callee-saved)"
              else: "") & size
    if r.len >= 2 and r[0] in {'v', 'q', 'd', 's', 'h', 'b'} and r[1 .. ^1].allCharsInSet(Digits):
      let n = parseInt(r[1 .. ^1])
      return (if n <= 7: "A float/vector register: argument " & $(n + 1) & (if n == 0: " and the float return value" else: "")
              elif n <= 15: "A float/vector register (its low 64 bits kept across calls)"
              else: "A float/vector register (scratch)")
    return ""
  for (names, d) in [(@["rax", "eax", "ax", "al", "ah"], "The return value (and the low half of mul/div)"),
                     (@["rdi", "edi", "di", "dil"], "The first argument"),
                     (@["rsi", "esi", "si", "sil"], "The second argument"),
                     (@["rdx", "edx", "dx", "dl"], "The third argument (and the high half of mul/div)"),
                     (@["rcx", "ecx", "cx", "cl"], "The fourth argument (and shift counts in cl)"),
                     (@["r8", "r8d", "r8w", "r8b"], "The fifth argument"),
                     (@["r9", "r9d", "r9w", "r9b"], "The sixth argument"),
                     (@["r10", "r10d", "r11", "r11d"], "Scratch (a call may change it)"),
                     (@["rbx", "ebx", "bx", "bl", "r12", "r12d", "r13", "r13d", "r14", "r14d", "r15", "r15d"],
                      "Kept across calls (callee-saved)"),
                     (@["rbp", "ebp"], "The frame pointer (or a callee-saved register)"),
                     (@["rsp", "esp"], "The stack pointer"),
                     (@["rip"], "The instruction pointer ([rip + x]: an address relative to the code)"),
                     (@["fs"], "Thread-local storage (Nim's threadvars, the stack protector's canary at fs:40)")]:
    if r in names: return d & " — System V (Linux, macOS); on Windows the arguments are rcx, rdx, r8, r9"
  if r.startsWith("xmm") or r.startsWith("ymm") or r.startsWith("zmm"):
    let n = try: parseInt(r[3 .. ^1]) except ValueError: -1
    if n == 0: return "Float argument 1 and the float return value (SSE/AVX)"
    if n in 1 .. 7: return "Float argument " & $(n + 1) & " (SSE/AVX)"
    return "An SSE/AVX register (scratch)"
  ""
