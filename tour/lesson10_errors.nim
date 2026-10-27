# Nim tour · 10 of 16 · When things go wrong
# notebook: compiled
#
# A proc that cannot do its job raises an exception; a `try` that wants to deal with it catches it, anywhere up the
# calls. Nim also tells two kinds apart: an exception (`CatchableError`: bad input, a missing file — expected, and
# handled) and a defect (an index out of range, nil — a bug, to fix rather than catch).

# %% try and except
# `parseInt` raises a ValueError for text that is not a number. `except ValueError as e` catches it; `e.msg` says
# what went wrong. After the `except`, the program goes on.
import std/strutils
for text in ["42", "4x2"]:
  try:
    let n = parseInt(text)
    echo text, " is ", n
  except ValueError as e:
    echo "no: ", e.msg
#> 42 is 42
#> no: invalid integer: 4x2

# %% Raising your own
# `raise newException(Kind, "message")` raises one. A type `object of ValueError` (or of CatchableError) is a kind
# of your own; an `except` for ValueError catches it too.
type NotPositive = object of ValueError
proc squareRoot(x: float): float =
  if x <= 0: raise newException(NotPositive, "needs a number above zero, got " & $x)
  var r = x
  for _ in 1 .. 30: r = (r + x / r) / 2
  r
try:
  echo squareRoot(2.0)
  echo squareRoot(-1.0)
  echo "not printed"
except NotPositive as e:
  echo "NotPositive: ", e.msg
#> 1.414213562373095
#> NotPositive: needs a number above zero, got -1.0

# %% finally and defer
# `finally` runs whether or not something was raised — the place to close or clean up. `defer` says the same at the
# top: it runs when the scope it is in ends.
proc work(fail: bool) =
  echo "  open"
  defer: echo "  closed"
  if fail: raise newException(IOError, "the disk is full")
  echo "  written"
for fail in [false, true]:
  try:
    work(fail)
  except IOError as e:
    echo "  caught: ", e.msg
  finally:
    echo "done (fail = ", fail, ")"
#>   open
#>   written
#>   closed
#> done (fail = false)
#>   open
#>   closed
#>   caught: the disk is full
#> done (fail = true)

# %% The compiler tracks what can be raised
# `{.raises: [].}` promises that a proc raises nothing: the compiler checks it, and refuses the proc when a call in
# it can raise. It lists what may escape — so callers know what to handle. (ned's Nim › Inspect › "What can this
# proc raise?" shows it for any proc.)
proc safeParse(s: string): int {.raises: [].} =
  try: parseInt(s)
  except ValueError: -1
# proc unsafeParse(s: string): int {.raises: [].} = parseInt(s)    # take away the #: the compiler says no
echo safeParse("12"), " ", safeParse("twelve")
#> 12 -1

# %% No value is not an error: Option
# When "nothing" is a normal answer, give an `Option` (std/options) instead of raising: `some(x)` or `none(T)`.
# The caller has to look before using it.
import std/options
proc findIndex(xs: openArray[string], what: string): Option[int] =
  for i, x in xs:
    if x == what: return some(i)
  none(int)
let colours = ["red", "green", "blue"]
let g = colours.findIndex("green")
if g.isSome: echo "green at ", g.get
echo colours.findIndex("pink").isNone, " ", colours.findIndex("pink").get(-1)
#> green at 1
#> true -1

# %% Defects are bugs
# Reading past the end of a seq is a defect: Nim checks, and stops the program with the line where it happened,
# rather than reading memory that is not yours. Do not catch defects — fix the code. Here the check comes first.
let small = @[1, 2, 3]
let i = 5
if i < small.len: echo small[i]
else: echo "index ", i, " is past the end (the last is ", small.high, ")"
#> index 5 is past the end (the last is 2)

# %% Exercise: an age from a form
# Write `parseAge`: the number in the text, which must be a whole number from 0 to 150. Raise a ValueError (with a
# message that says why) for text that is not a number and for a number outside 0 .. 150. `parseInt` raises a
# ValueError by itself for text that is not a number.
proc parseAge(s: string): int =
  0
# Check:
proc refused(s: string): bool =
  try:
    discard parseAge(s)
    false
  except ValueError:
    true
if parseAge("42") == 42 and parseAge("0") == 0 and refused("abc") and refused("200") and refused("-1"):
  echo "✓ parseAge works"
else:
  echo "not yet: parseAge(\"42\") gives ", parseAge("42"), "; \"abc\" raises: ", refused("abc"),
    "; \"200\" raises: ", refused("200")
# Answer:
  # proc parseAge(s: string): int =
  #   result = parseInt(s)
  #   if result notin 0 .. 150:
  #     raise newException(ValueError, "an age is from 0 to 150, not " & s)
