# Nim tour · 4 of 16 · Procedures
# notebook: compiled
#
# A procedure — `proc` — is a named piece of code with parameters and, when it gives something back, a result type.
# Procedures are how a Nim program is built: even `echo` and `+` are procs.

# %% A first proc
# The parameters go in brackets with their types, the result type after a colon. The last expression of the body
# is the result.
proc square(x: int): int =
  x * x
echo square(12)
#> 144

# %% result and return
# Every proc that gives a value has a variable `result`, of the result type, ready from the start (0, "", false …).
# What it holds at the end is given back. `return` leaves early.
proc sumTo(n: int): int =
  for i in 1 .. n:
    result += i
proc sign(x: int): string =
  if x < 0: return "negative"
  if x == 0: return "zero"
  "positive"
echo sumTo(100), " ", sign(-5), " ", sign(0)
#> 5050 negative zero

# %% Default values and named arguments
# A parameter can have a default. An argument can be given by its name, in any order.
proc greet(name: string, greeting = "Hello", times = 1): string =
  for i in 1 .. times:
    if i > 1: result.add " "
    result.add greeting & ", " & name & "!"
echo greet("Ada")
echo greet("Ada", times = 2, greeting = "Hi")
#> Hello, Ada!
#> Hi, Ada! Hi, Ada!

# %% Method call syntax
# `f(a, b)` can be written `a.f(b)`, and `f(a)` as `a.f` — the first argument goes before the dot. Any proc can be
# called this way, so you can chain them.
echo 5.square, " ", 3.square.square, " ", "nim".len
#> 25 81 3

# %% Overloading
# Procs with the same name but different parameter types are different procs: Nim picks by the argument's type.
proc describe(x: int): string = "the number " & $x
proc describe(x: string): string = "the text \"" & x & "\""
proc describe(x: bool): string = (if x: "yes" else: "no")
echo describe(4), " · ", describe("four"), " · ", describe(true)
#> the number 4 · the text "four" · yes

# %% var parameters
# Parameters cannot be changed — unless one is `var`, and then the change is made to the caller's variable.
proc double(x: var int) =
  x = x * 2
var points = 21
double(points)
echo points
#> 42

# %% func: no side effects
# A `func` is a proc that promises not to touch anything outside it (no echo, no global variables): the compiler
# holds it to that. It makes code easier to trust and to test.
func area(w, h: float): float = w * h
echo area(2.0, 3.5)
#> 7.0

# %% Procs are values
# A proc can be put in a variable and passed to another proc. `proc (x: int): int = …` without a name is an
# anonymous proc; std/sugar writes it shorter with `=>`.
import std/sugar
proc applyTwice(f: proc (x: int): int, x: int): int = f(f(x))
echo applyTwice(square, 3)
echo applyTwice(proc (x: int): int = x + 10, 1)
echo applyTwice(x => x * 3, 2)
#> 81
#> 21
#> 18

# %% Exercise: a palindrome
# Write `isPalindrome`: true when a string reads the same backwards ("level", "abba", and "" too). Compare the
# first character with the last, the second with the one before the last, and so on — `s[s.high - i]` is the i-th
# from the end (`s.high` is the last index).
proc isPalindrome(s: string): bool =
  false
# Check:
if isPalindrome("level") and isPalindrome("abba") and isPalindrome("") and not isPalindrome("nim") and
    not isPalindrome("ab"):
  echo "✓ isPalindrome works"
else:
  echo "not yet: level ", isPalindrome("level"), ", abba ", isPalindrome("abba"), ", nim ", isPalindrome("nim")
# Answer:
  # proc isPalindrome(s: string): bool =
  #   for i in 0 ..< s.len div 2:
  #     if s[i] != s[s.high - i]: return false
  #   true
