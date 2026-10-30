## Regular expressions: a small backtracking VM (no PCRE needed on Termux).

import std/strutils

# ── regular expressions: a small backtracking VM (no PCRE needed on Termux) ──
# Syntax: . [abc] [^a-z] \d \w \s \D \W \S \b \B ^ $ (…) (?:…) a|b * + ? {n} {n,} {n,m}
# lazy *? +? ?? {…}?, escapes \. \t \n \\ \xHH. Matching is per line; `.` and [^…] take a
# whole UTF-8 character. A step budget keeps pathological patterns from freezing the editor.

type
  ReOp* = enum roChar, roAny, roClass, roSplit, roJmp, roSave, roBol, roEol, roWordB, roNotWordB, roMatch, roCheck
  ReInst* = object
    op*: ReOp
    c*: char
    x*, y*: int
  ReClass* = object
    bits*: set[char]       # ASCII members; '\x80' set = "every non-ASCII character" (\w, \D, \S …)
    cps*: seq[(int, int)]  # non-ASCII members as code point ranges
    neg*: bool
  ReNodeKind* = enum rnLit, rnAny, rnClass, rnCat, rnAlt, rnRep, rnGroup, rnBol, rnEol, rnWordB, rnNotWordB, rnEmpty
  ReNode* = ref object
    kind*: ReNodeKind
    c*: char
    cls*: int
    kids*: seq[ReNode]
    lo*, hi*: int           # rnRep: hi = -1 → unbounded
    greedy*: bool
    cap*: int              # rnGroup: capture index, -1 non-capturing
  Regex* = object
    prog*: seq[ReInst]
    classes*: seq[ReClass]
    ncap*: int
    nregs*: int            # extra slots after the captures: loop progress marks
    icase*: bool
    err*: string
    firstLit*: int         # byte every match starts with (-1 unknown) — a fast scan
  ReParser* = object
    p*: string
    i*: int
    ncap*: int
    icase*: bool
    re*: ptr Regex

const ReWord* = {'a'..'z', 'A'..'Z', '0'..'9', '_', '\x80'..'\xFF'}
const ReDigit* = {'0'..'9'}
const ReSpace* = {' ', '\t', '\n', '\r', '\f', '\v'}

proc reErr*(ps: var ReParser, msg: string) =
  ## records a pattern error with the position it was found at; only the first error of a pattern is kept
  if ps.re.err.len == 0: ps.re.err = msg & " at " & $ps.i

# the character as it is compared: lower-cased when the match ignores case
func reFold*(c: char, icase: bool): char {.inline.} = (if icase: toLowerAscii(c) else: c)

func reAddClass*(ps: var ReParser, bits: set[char], neg: bool, cps: seq[(int, int)] = @[]): int =
  ## adds a character class (ASCII members, non-ASCII code point ranges, negated or not) to the regex's class table and
  ## gives back its index; when ignoring case, each letter in the set brings its other case in too
  var b = bits
  if ps.icase:
    for c in 'a'..'z':
      if c in b or toUpperAscii(c) in b:
        b.incl c
        b.incl toUpperAscii(c)
  ps.re.classes.add ReClass(bits: b, cps: cps, neg: neg)
  ps.re.classes.high

func reDecode*(s: string, i: int): (int, int) =
  ## (code point, bytes) of the UTF-8 character at i (invalid bytes decode as themselves)
  let c = ord(s[i])
  if c < 0x80: return (c, 1)
  let n = if c < 0xC0: 1 elif c < 0xE0: 2 elif c < 0xF0: 3 else: 4
  if n == 1 or i + n > s.len: return (c, 1)
  var cp = c and (case n
    of 2: 0x1F
    of 3: 0x0F
    else: 0x07)
  for k in 1 ..< n:
    let d = ord(s[i + k])
    if (d and 0xC0) != 0x80: return (c, 1)
    cp = (cp shl 6) or (d and 0x3F)
  (cp, n)

proc reParseAlt*(ps: var ReParser): ReNode

func reEscapeSet*(c: char): (bool, set[char], bool) =
  ## \d \w \s and their negations as byte sets: (isClass, bits, negated)
  case c
  of 'd': (true, ReDigit, false)
  of 'D': (true, ReDigit, true)
  of 'w': (true, ReWord, false)
  of 'W': (true, ReWord, true)
  of 's': (true, ReSpace, false)
  of 'S': (true, ReSpace, true)
  else: (false, {}, false)

func reEscapeChar*(ps: var ReParser, c: char): char =
  ## the character an escape stands for, with c the letter after the backslash: \t \n \r \f \v \0 and \xHH (which reads
  ## two more hex digits from the pattern); any other escaped character stands for itself
  case c
  of 't': '\t'
  of 'n': '\n'
  of 'r': '\r'
  of 'f': '\f'
  of 'v': '\v'
  of '0': '\0'
  of 'x':
    if ps.i + 1 < ps.p.len:
      try:
        let v = parseHexInt(ps.p[ps.i .. ps.i + 1])
        ps.i += 2
        return char(v)
      except ValueError: discard
    'x'
  else: c

proc reParseClass*(ps: var ReParser): ReNode =
  ## parses a bracket class after its '[': an optional ^, single characters, ranges, \d \w \s and their negations, POSIX
  ## names such as [:alpha:] and non-ASCII characters (kept as code point ranges); a ']' first in the class is a member.
  ## Reports a missing ] or a backwards range as an error
  # after '['
  var neg = false
  var bits: set[char]
  if ps.i < ps.p.len and ps.p[ps.i] == '^':
    neg = true
    inc ps.i
  var first = true
  var cps: seq[(int, int)]
  while ps.i < ps.p.len and (ps.p[ps.i] != ']' or first):
    first = false
    if ord(ps.p[ps.i]) >= 0x80:
      # a non-ASCII character (or a range of them) as code points
      let (lo, n) = reDecode(ps.p, ps.i)
      ps.i += n
      var hi = lo
      if ps.i + 1 < ps.p.len and ps.p[ps.i] == '-' and ps.p[ps.i + 1] != ']':
        let (h, n2) = reDecode(ps.p, ps.i + 1)
        hi = h
        ps.i += 1 + n2
      if hi < lo: reErr(ps, "bad range")
      cps.add (lo, hi)
      continue
    var c = ps.p[ps.i]
    inc ps.i
    if c == '\\' and ps.i < ps.p.len:
      let e = ps.p[ps.i]
      inc ps.i
      let (isCls, s, n) = reEscapeSet(e)
      if isCls:
        if n:
          for x in '\0'..'\xFF':
            if x notin s: bits.incl x
        else: bits = bits + s
        continue
      c = reEscapeChar(ps, e)
    elif c == '[' and ps.i < ps.p.len and ps.p[ps.i] == ':':
      let e = ps.p.find(":]", ps.i)
      if e > 0:
        let name = ps.p[ps.i + 1 ..< e]
        ps.i = e + 2
        case name
        of "alpha": bits = bits + {'a'..'z', 'A'..'Z'}
        of "digit": bits = bits + ReDigit
        of "alnum": bits = bits + {'a'..'z', 'A'..'Z', '0'..'9'}
        of "space": bits = bits + ReSpace
        of "upper": bits = bits + {'A'..'Z'}
        of "lower": bits = bits + {'a'..'z'}
        of "punct": bits = bits + {'!'..'/', ':'..'@', '['..'`', '{'..'~'}
        of "xdigit": bits = bits + {'0'..'9', 'a'..'f', 'A'..'F'}
        else: reErr(ps, "unknown class [:" & name & ":]")
        continue
    if ps.i + 1 < ps.p.len and ps.p[ps.i] == '-' and ps.p[ps.i + 1] != ']':
      inc ps.i
      var hi = ps.p[ps.i]
      inc ps.i
      if hi == '\\' and ps.i < ps.p.len:
        let e = ps.p[ps.i]
        inc ps.i
        hi = reEscapeChar(ps, e)
      if hi < c: reErr(ps, "bad range")
      else:
        for x in c..hi: bits.incl x
    else: bits.incl c
  if ps.i >= ps.p.len:
    reErr(ps, "missing ]")
    return ReNode(kind: rnEmpty)
  inc ps.i
  bits = bits * {'\0' .. '\x7F'} + (if '\x80' in bits: {'\x80'} else: {})
  ReNode(kind: rnClass, cls: reAddClass(ps, bits, neg, cps))

proc reParseAtom*(ps: var ReParser): ReNode =
  ## parses one item of a pattern: a dot, ^, $, a bracket class, a group — capturing, or non-capturing with (?:…) — a
  ## backslash escape (\b \B, \d \w \s …, or a literal) or a plain character; a repeat sign with nothing before it is an
  ## error
  let c = ps.p[ps.i]
  inc ps.i
  case c
  of '.': ReNode(kind: rnAny)
  of '^': ReNode(kind: rnBol)
  of '$': ReNode(kind: rnEol)
  of '[': reParseClass(ps)
  of '(':
    var cap = -1
    if ps.i + 1 < ps.p.len and ps.p[ps.i] == '?' and ps.p[ps.i + 1] == ':': ps.i += 2
    else:
      inc ps.ncap
      cap = ps.ncap
    let inner = reParseAlt(ps)
    if ps.i >= ps.p.len or ps.p[ps.i] != ')':
      reErr(ps, "missing )")
    else: inc ps.i
    ReNode(kind: rnGroup, kids: @[inner], cap: cap)
  of '\\':
    if ps.i >= ps.p.len:
      reErr(ps, "trailing \\")
      return ReNode(kind: rnEmpty)
    let e = ps.p[ps.i]
    inc ps.i
    case e
    of 'b': return ReNode(kind: rnWordB)
    of 'B': return ReNode(kind: rnNotWordB)
    else: discard
    let (isCls, s, n) = reEscapeSet(e)
    if isCls: return ReNode(kind: rnClass, cls: reAddClass(ps, s, n))
    ReNode(kind: rnLit, c: reEscapeChar(ps, e))
  of '*', '+', '?':
    reErr(ps, "nothing to repeat")
    ReNode(kind: rnEmpty)
  else: ReNode(kind: rnLit, c: c)

func reParseNum*(ps: var ReParser): int =
  ## reads the decimal number at the parser's position, capped at 1000; -1 when there is no digit
  result = -1
  while ps.i < ps.p.len and ps.p[ps.i] in ReDigit:
    result = max(0, result) * 10 + (ord(ps.p[ps.i]) - ord('0'))
    if result > 1000: result = 1000
    inc ps.i

proc reParseRepeat*(ps: var ReParser): ReNode =
  ## parses an atom followed by any repeat signs: * + ? or {n} {n,} {n,m}, each optionally lazy with a trailing ?. A
  ## brace that does not form a valid count is left as a literal '{'; repeating ^, $ or \b has no effect
  var atom = reParseAtom(ps)
  while ps.i < ps.p.len:
    let c = ps.p[ps.i]
    var lo, hi: int
    case c
    of '*': (lo, hi) = (0, -1)
    of '+': (lo, hi) = (1, -1)
    of '?': (lo, hi) = (0, 1)
    of '{':
      let save = ps.i
      inc ps.i
      let a = reParseNum(ps)
      var b = a
      if ps.i < ps.p.len and ps.p[ps.i] == ',':
        inc ps.i
        b = reParseNum(ps)          # -1 → unbounded
      if a < 0 or ps.i >= ps.p.len or ps.p[ps.i] != '}' or (b >= 0 and b < a):
        ps.i = save                 # not a repetition: a literal '{'
        return atom
      (lo, hi) = (a, b)
    else: return atom
    inc ps.i
    var greedy = true
    if ps.i < ps.p.len and ps.p[ps.i] == '?':
      greedy = false
      inc ps.i
    if atom.kind in {rnBol, rnEol, rnWordB, rnNotWordB}: continue
    atom = ReNode(kind: rnRep, kids: @[atom], lo: lo, hi: hi, greedy: greedy)
  atom

proc reParseCat*(ps: var ReParser): ReNode =
  ## parses a sequence of repeated atoms up to the next | or ), stopping at the first error
  result = ReNode(kind: rnCat)
  while ps.i < ps.p.len and ps.p[ps.i] notin {'|', ')'}:
    result.kids.add reParseRepeat(ps)
    if ps.re.err.len > 0: return

proc reParseAlt*(ps: var ReParser): ReNode =
  ## parses alternatives separated by |; the top of the grammar, and what a parenthesised group parses inside itself
  let first = reParseCat(ps)
  if ps.i >= ps.p.len or ps.p[ps.i] != '|': return first
  result = ReNode(kind: rnAlt, kids: @[first])
  while ps.i < ps.p.len and ps.p[ps.i] == '|':
    inc ps.i
    result.kids.add reParseCat(ps)

func reEmit*(re: var Regex, op: ReOp, c = '\0', x = 0, y = 0): int =
  ## appends one instruction to the program and gives back its index
  re.prog.add ReInst(op: op, c: c, x: x, y: y)
  re.prog.high

func reCanEmpty*(n: ReNode): bool =
  ## can this part of the pattern match without consuming any character? the compiler uses it to guard loops such as
  ## (a*)* against going round forever
  case n.kind
  of rnLit, rnAny, rnClass: false
  of rnBol, rnEol, rnWordB, rnNotWordB, rnEmpty: true
  of rnCat:
    for k in n.kids:
      if not reCanEmpty(k): return false
    true
  of rnAlt:
    for k in n.kids:
      if reCanEmpty(k): return true
    false
  of rnRep: n.lo == 0 or reCanEmpty(n.kids[0])
  of rnGroup: reCanEmpty(n.kids[0])

func reCompile*(re: var Regex, n: ReNode) =
  ## turns the parsed tree into VM instructions: a repeat is its body copied lo times and then either a split loop
  ## (unbounded) or hi-lo optional copies, an alternation a chain of splits and jumps, a capturing group a pair of save
  ## instructions. A loop whose body can match nothing gets a progress mark and a check so it stops. A program over
  ## 20,000 instructions is an error
  if re.prog.len > 20000:
    if re.err.len == 0: re.err = "pattern too large"
    return
  case n.kind
  of rnLit: discard re.reEmit(roChar, reFold(n.c, re.icase))
  of rnAny: discard re.reEmit(roAny)
  of rnClass: discard re.reEmit(roClass, x = n.cls)
  of rnBol: discard re.reEmit(roBol)
  of rnEol: discard re.reEmit(roEol)
  of rnWordB: discard re.reEmit(roWordB)
  of rnNotWordB: discard re.reEmit(roNotWordB)
  of rnEmpty: discard
  of rnCat:
    for k in n.kids: re.reCompile(k)
  of rnGroup:
    if n.cap >= 0: discard re.reEmit(roSave, x = 2 * n.cap)
    re.reCompile(n.kids[0])
    if n.cap >= 0: discard re.reEmit(roSave, x = 2 * n.cap + 1)
  of rnAlt:
    var jumps: seq[int]
    for i, k in n.kids:
      if i < n.kids.high:
        let sp = re.reEmit(roSplit)
        re.prog[sp].x = re.prog.len
        re.reCompile(k)
        jumps.add re.reEmit(roJmp)
        re.prog[sp].y = re.prog.len
      else: re.reCompile(k)
    for j in jumps: re.prog[j].x = re.prog.len
  of rnRep:
    let e = n.kids[0]
    for _ in 0 ..< n.lo: re.reCompile(e)
    if n.hi < 0:
      let sp = re.reEmit(roSplit)
      let guard = reCanEmpty(e)       # (a*)* and friends: stop looping when an iteration matched nothing
      var reg = -1
      if guard:
        reg = re.nregs
        inc re.nregs
        discard re.reEmit(roSave, x = -1 - reg)
      re.reCompile(e)
      if guard: discard re.reEmit(roCheck, x = -1 - reg)
      discard re.reEmit(roJmp, x = sp)
      let after = re.prog.len
      if n.greedy: (re.prog[sp].x, re.prog[sp].y) = (sp + 1, after)
      else: (re.prog[sp].x, re.prog[sp].y) = (after, sp + 1)
    else:
      var splits: seq[int]
      for _ in n.lo ..< n.hi:
        splits.add re.reEmit(roSplit)
        re.reCompile(e)
      let after = re.prog.len
      for sp in splits:
        if n.greedy: (re.prog[sp].x, re.prog[sp].y) = (sp + 1, after)
        else: (re.prog[sp].x, re.prog[sp].y) = (after, sp + 1)

proc compileRegex*(pattern: string, icase = false): Regex =
  ## parses and compiles a pattern into a Regex; on a bad pattern the Regex has its err text set and no program. Notes
  ## the first literal byte of the pattern, so the search can skip quickly to places a match could start
  result.icase = icase
  result.firstLit = -1
  if pattern.len == 0:
    result.err = "empty pattern"
    return
  var ps = ReParser(p: pattern, icase: icase, re: addr result)
  let ast = reParseAlt(ps)
  if result.err.len == 0 and ps.i < pattern.len: result.err = "unbalanced )"
  if result.err.len > 0: return
  result.ncap = ps.ncap + 1
  discard result.reEmit(roSave, x = 0)
  result.reCompile(ast)
  discard result.reEmit(roSave, x = 1)
  discard result.reEmit(roMatch)
  if result.prog.len > 1 and result.prog[1].op == roChar and not icase: result.firstLit = ord(result.prog[1].c)

func utf8Len*(c: char): int {.inline.} =
  ## the length in bytes of the UTF-8 character that starts with this byte (a continuation byte counts as 1)
  let b = ord(c)
  if b < 0xC0: 1 elif b < 0xE0: 2 elif b < 0xF0: 3 else: 4

var reBudgetHit* = false

proc reMatchAt*(re: Regex, s: string, start: int, caps: var seq[int], budget: var int): bool =
  ## backtracking VM: does the pattern match at exactly `start`?
  type Frame = object
    pc, sp, slot, old: int     # slot >= 0: a capture to restore while unwinding
  var stack: seq[Frame]
  for i in 0 ..< caps.len: caps[i] = -1
  stack.add Frame(pc: 0, sp: start, slot: -1)
  while stack.len > 0:
    let f = stack.pop()
    if f.slot >= 0:
      caps[f.slot] = f.old
      continue
    var pc = f.pc
    var sp = f.sp
    while true:
      dec budget
      if budget <= 0:
        reBudgetHit = true
        return false
      let ins = re.prog[pc]
      case ins.op
      of roChar:
        if sp < s.len and reFold(s[sp], re.icase) == ins.c:
          inc sp
          inc pc
        else: break
      of roAny:
        if sp < s.len and s[sp] != '\n':
          sp = min(s.len, sp + utf8Len(s[sp]))
          inc pc
        else: break
      of roClass:
        if sp >= s.len: break
        let cl = re.classes[ins.x]
        var inSet: bool
        var adv = 1
        if ord(s[sp]) < 0x80: inSet = s[sp] in cl.bits
        else:
          let (cp, n) = reDecode(s, sp)
          adv = n
          inSet = '\x80' in cl.bits
          if not inSet:
            for (lo, hi) in cl.cps:
              if cp >= lo and cp <= hi:
                inSet = true
                break
        if inSet == cl.neg: break
        sp += adv
        inc pc
      of roSplit:
        stack.add Frame(pc: ins.y, sp: sp, slot: -1)
        pc = ins.x
      of roJmp: pc = ins.x
      of roSave:
        let slot = if ins.x >= 0: ins.x else: 2 * re.ncap + (-1 - ins.x)
        stack.add Frame(slot: slot, old: caps[slot])
        caps[slot] = sp
        inc pc
      of roCheck:
        if caps[2 * re.ncap + (-1 - ins.x)] == sp: break
        inc pc
      of roBol:
        if sp != 0: break
        inc pc
      of roEol:
        if sp != s.len: break
        inc pc
      of roWordB, roNotWordB:
        let a = sp > 0 and s[sp - 1] in ReWord
        let b = sp < s.len and s[sp] in ReWord
        if (a != b) != (ins.op == roWordB): break
        inc pc
      of roMatch: return true
  false

proc reSearch*(re: Regex, s: string, start: int, caps: var seq[int]): bool =
  ## leftmost match at or after `start`; caps[0..1] = match bounds, caps[2k..2k+1] = group k
  if re.err.len > 0 or re.prog.len == 0: return false
  if caps.len != 2 * re.ncap + re.nregs: caps.setLen(2 * re.ncap + re.nregs)
  var budget = 200_000 + 50 * s.len
  var i = start
  while i <= s.len:
    if re.firstLit >= 0:
      while i < s.len and ord(s[i]) != re.firstLit: inc i
      if i >= s.len: return false
    if re.reMatchAt(s, i, caps, budget): return true
    if budget <= 0: return false
    if i < s.len: i += utf8Len(s[i]) else: inc i
  false

proc reExpand*(tmpl: string, s: string, caps: seq[int], ncap = high(int)): string =
  ## replacement text: $0 / $& whole match, $1…$9 and ${12} groups, \n \t, $$ → $
  var i = 0
  proc grp(k: int): string =
    ## the text of capture group k, or an empty string when it did not take part in the match or does not exist
    if k < ncap and 2 * k + 1 < caps.len and caps[2 * k] >= 0 and caps[2 * k + 1] >= caps[2 * k] and
       caps[2 * k + 1] <= s.len: s[caps[2 * k] ..< caps[2 * k + 1]]
    else: ""
  while i < tmpl.len:
    let c = tmpl[i]
    if c == '$' and i + 1 < tmpl.len:
      let d = tmpl[i + 1]
      if d in ReDigit:
        result.add grp(ord(d) - ord('0'))
        i += 2
        continue
      if d == '&':
        result.add grp(0)
        i += 2
        continue
      if d == '$':
        result.add '$'
        i += 2
        continue
      if d == '{':
        let e = tmpl.find('}', i + 2)
        if e > 0 and e > i + 2 and e - i <= 6 and tmpl[i + 2 ..< e].allCharsInSet(ReDigit):
          result.add grp(parseInt(tmpl[i + 2 ..< e]))
          i = e + 1
          continue
    elif c == '\\' and i + 1 < tmpl.len:
      case tmpl[i + 1]
      of 'n': result.add '\n'
      of 't': result.add '\t'
      of '\\': result.add '\\'
      of '0'..'9': result.add grp(ord(tmpl[i + 1]) - ord('0'))
      else:
        result.add c
        result.add tmpl[i + 1]
      i += 2
      continue
    result.add c
    inc i

var
  reCacheKey* = ""
  reCache*: Regex

proc cachedRegex*(q: string, caseSens: bool): ptr Regex =
  ## the compiled regex for a pattern and case setting, kept until the next different one is asked for, so searching
  ## line after line with the same pattern compiles it once
  let key = (if caseSens: "1" else: "0") & q
  if key != reCacheKey:
    reCache = compileRegex(q, not caseSens)
    reCacheKey = key
  addr reCache
