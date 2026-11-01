## inline-calc — sums worked out where you write them: select 12*(3+4) and get 84, or end a line with = for its result
##
##   Calc: work it out       the selection replaced with its result; with none, the sum before the cursor on its line,
##                           after its last = or : ("total = 3*4 + 2 =" → "total = 3*4 + 2 = 14")
##   Calc: show the result   the result in the status line and on the clipboard; the text stays as it is
##   it understands          + - * / and // (whole division), % (remainder), ^ or ** (power), brackets, 1_000, 2.5,
##                           1e3, 50%, 0x1F 0b101 0o17, pi e and ans (the last result), sqrt sin cos tan asin acos
##                           atan exp ln log log2 abs round floor ceil, and min(…) max(…) of any number of values
##   settings                plugins.inline-calc.decimals (10): the most digits after the point
##
## A whole number is written as one (84, not 84.0); 1/3 as 0.3333333333. Angles are in radians.
import nedplugin
import std/math

requiresNed(">= 6.31")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")
permission("clipboard", "puts the result on the clipboard (Calc: show the result)")

settingDef("decimals", 10, "Calc: the most digits after the point in a result")

var ans = 0.0                   # the last result (ans in a sum)

type Parser = object
  s: string
  i: int

proc fail(p: Parser, what: string, where = true) =
  ## the sum cannot be worked out: says why, and where when it is in the writing (not for a division by 0)
  raise newException(ValueError, what & (if not where: ""
                                         elif p.i < p.s.len: " at “" & p.s[p.i .. min(p.s.high, p.i + 7)] & "”"
                                         else: " at the end"))

proc skip(p: var Parser) =
  ## past spaces
  while p.i < p.s.len and p.s[p.i] in {' ', '\t'}: inc p.i

proc peek(p: var Parser): char =
  ## the next character that is not a space ('\0' at the end)
  p.skip()
  if p.i < p.s.len: p.s[p.i] else: '\0'

proc expr(p: var Parser): float

proc number(p: var Parser): float =
  ## a number as written: 12, 1_000, 2.5, .5, 1e3, 0x1F, 0b101, 0o17
  let start = p.i
  if p.i + 1 < p.s.len and p.s[p.i] == '0' and p.s[p.i + 1] in {'x', 'X', 'b', 'B', 'o', 'O'}:
    let base = case p.s[p.i + 1]
               of 'x', 'X': 16
               of 'b', 'B': 2
               else: 8
    p.i += 2
    var v = 0
    var any = false
    while p.i < p.s.len:
      let c = p.s[p.i]
      let d = if c in '0'..'9': ord(c) - ord('0')
              elif c in 'a'..'f': ord(c) - ord('a') + 10
              elif c in 'A'..'F': ord(c) - ord('A') + 10
              elif c == '_': -2
              else: -1
      if d == -2:
        inc p.i
        continue
      if d < 0 or d >= base: break
      v = v * base + d
      any = true
      inc p.i
    if not any: p.fail("no digits after " & p.s[start .. start + 1])
    return float(v)
  var t = ""
  while p.i < p.s.len and p.s[p.i] in {'0'..'9', '_', '.'}:
    if p.s[p.i] != '_': t.add p.s[p.i]
    inc p.i
  if p.i < p.s.len and p.s[p.i] in {'e', 'E'} and p.i + 1 < p.s.len and
     (p.s[p.i + 1] in {'0'..'9'} or (p.s[p.i + 1] in {'+', '-'} and p.i + 2 < p.s.len and p.s[p.i + 2] in {'0'..'9'})):
    t.add 'e'
    inc p.i
    if p.s[p.i] in {'+', '-'}:
      t.add p.s[p.i]
      inc p.i
    while p.i < p.s.len and p.s[p.i] in {'0'..'9'}:
      t.add p.s[p.i]
      inc p.i
  if t.len == 0 or t == ".": p.fail("a number expected")
  try: parseFloat(t)
  except ValueError: (p.fail("not a number: " & t); 0.0)

proc call(p: var Parser, name: string): float =
  ## a function of the sum: name( … ), or a constant
  var args: seq[float]
  if p.peek() == '(':
    inc p.i
    if p.peek() != ')':
      args.add p.expr()
      while p.peek() == ',':
        inc p.i
        args.add p.expr()
    if p.peek() != ')': p.fail("a ) expected")
    inc p.i
  proc one(p: Parser, args: seq[float], name: string): float =
    ## the one value a function of one value takes
    if args.len != 1: p.fail(name & " takes one value")
    args[0]
  let n = name.toLowerAscii
  if n in ["pi", "e", "ans"] and args.len > 0: p.fail(n & " takes nothing")
  case n
  of "pi": PI
  of "e": E
  of "ans": ans
  of "sqrt":
    let x = one(p, args, name)
    if x < 0: p.fail("the square root of a number under 0", false)
    sqrt(x)
  of "sin": sin(one(p, args, name))
  of "cos": cos(one(p, args, name))
  of "tan": tan(one(p, args, name))
  of "asin": arcsin(one(p, args, name))
  of "acos": arccos(one(p, args, name))
  of "atan": arctan(one(p, args, name))
  of "exp": exp(one(p, args, name))
  of "ln":
    let x = one(p, args, name)
    if x <= 0: p.fail("ln of a number not over 0", false)
    ln(x)
  of "log":
    let x = one(p, args, name)
    if x <= 0: p.fail("log of a number not over 0", false)
    log10(x)
  of "log2":
    let x = one(p, args, name)
    if x <= 0: p.fail("log2 of a number not over 0", false)
    ln(x) / ln(2.0)
  of "abs": abs(one(p, args, name))
  of "round": round(one(p, args, name))
  of "floor": floor(one(p, args, name))
  of "ceil": ceil(one(p, args, name))
  of "min", "max":
    if args.len == 0: p.fail(name & " takes one value or more")
    var r = args[0]
    for x in args:
      r = (if n == "min": min(r, x) else: max(r, x))
    r
  else: (p.fail("no function " & name); 0.0)

proc atom(p: var Parser): float =
  ## a number, a function or constant, or a sum in brackets — then a % after it makes it a hundredth
  let c = p.peek()
  if c == '(':
    inc p.i
    result = p.expr()
    if p.peek() != ')': p.fail("a ) expected")
    inc p.i
  elif c in {'0'..'9', '.'}: result = p.number()
  elif c in {'a'..'z', 'A'..'Z'}:
    var name = ""
    while p.i < p.s.len and p.s[p.i] in {'a'..'z', 'A'..'Z', '0'..'9'}:
      name.add p.s[p.i]
      inc p.i
    result = p.call(name)
  else: p.fail("a number expected")
  if p.peek() == '%':
    # (50% — a percent, when no value follows it; 7 % 3 is a remainder)
    var k = p.i + 1
    while k < p.s.len and p.s[k] in {' ', '\t'}: inc k
    if k >= p.s.len or p.s[k] in {')', ',', '+', '-', '*', '/', '^', '='}:
      inc p.i
      result = result / 100

proc unary(p: var Parser): float

proc power(p: var Parser): float =
  ## a value to a power: 2^10, 2**10 (right to left: 2^3^2 is 2^9; 2^-1 a half)
  result = p.atom()
  let c = p.peek()
  if c == '^' or (c == '*' and p.i + 1 < p.s.len and p.s[p.i + 1] == '*'):
    p.i += (if c == '^': 1 else: 2)
    result = pow(result, p.unary())

proc unary(p: var Parser): float =
  ## a value with any signs in front: -3, +2, --1 (after the power, as in mathematics: -2^2 is -4)
  let c = p.peek()
  if c == '-':
    inc p.i
    -p.unary()
  elif c == '+':
    inc p.i
    p.unary()
  else: p.power()

proc term(p: var Parser): float =
  ## values multiplied and divided: * / // %
  result = p.unary()
  while true:
    let c = p.peek()
    if c == '*' and not (p.i + 1 < p.s.len and p.s[p.i + 1] == '*'):
      inc p.i
      result = result * p.unary()
    elif c == '/':
      let whole = p.i + 1 < p.s.len and p.s[p.i + 1] == '/'
      p.i += (if whole: 2 else: 1)
      let d = p.unary()
      if d == 0: p.fail("a division by 0", false)
      result = if whole: floor(result / d) else: result / d
    elif c == '%':
      inc p.i
      let d = p.unary()
      if d == 0: p.fail("a remainder of a division by 0", false)
      result = result - d * floor(result / d)
    else: break

proc expr(p: var Parser): float =
  ## a sum: terms added and taken away
  result = p.term()
  while true:
    let c = p.peek()
    if c == '+':
      inc p.i
      result = result + p.term()
    elif c == '-':
      inc p.i
      result = result - p.term()
    else: break

proc evaluate*(s: string): float =
  ## the value of the sum `s` (ValueError, with what is wrong, when it is not one)
  var p = Parser(s: s.replace("×", "*").replace("÷", "/").replace("−", "-"))
  if p.peek() == '\0': p.fail("nothing to work out")
  result = p.expr()
  if p.peek() != '\0': p.fail("not understood")
  if result != result or result == Inf or result == NegInf: p.fail("no number comes out", false)

proc shown*(x: float, decimals = 10): string =
  ## a result as you would write it: a whole number without a point, else at most `decimals` digits after it, the zeros
  ## at the end left off
  if abs(x) < 1e15 and x == floor(x): return $int(x)
  result = formatFloat(x, ffDecimal, max(0, decimals))
  if '.' in result: result = result.strip(leading = false, chars = {'0'}).strip(leading = false, chars = {'.'})
  if result == "-0": result = "0"

proc sumHere(b: Buf): (Range, string, bool) =
  ## what to work out: the selection; else the line up to the cursor, after its last = or : (true: the line ends with
  ## an = still to be answered)
  let r = b.selection
  if not r.isEmpty: return (r, b.textIn(r), false)
  let c = b.cursor
  let before = b.line(c.line)[0 ..< min(c.col, b.line(c.line).len)]
  var t = before.strip(leading = false)
  var asks = false
  if t.endsWith("="):
    asks = true
    t = t[0 ..< t.high]
  let k = max(t.rfind('='), t.rfind(':'))
  let sum = if k >= 0: t[k + 1 .. ^1] else: t
  (rng(c, c), sum.strip, asks)

command "Calc: work it out":
  let b = current()
  let (r, sum, asks) = sumHere(b)
  try:
    let v = evaluate(sum)
    ans = v
    let txt = shown(v, setting("decimals", 10))
    if not r.isEmpty: b.replace(r, txt)
    else:
      let line = b.line(r.start.line)
      let sep = if asks: (if line[0 ..< r.start.col].endsWith(" "): "" else: " ") else: " = "
      b.insert(r.start, sep & txt)
    message("= " & txt)
  except ValueError as e:
    warn("Calc: " & e.msg)

command "Calc: show the result":
  let b = current()
  let (_, sum, _) = sumHere(b)
  try:
    let v = evaluate(sum)
    ans = v
    let txt = shown(v, setting("decimals", 10))
    setClipboard(txt)
    message(sum & " = " & txt & "   (on the clipboard)")
  except ValueError as e:
    warn("Calc: " & e.msg)
