# Nim tour · 3 of 16 · Choices and loops
# notebook: compiled
#
# A program decides with `if` and `case`, and repeats with `while` and `for`. Each of them ends its first line with a
# colon and indents what it governs by two spaces: the indentation is the block.

# %% if, elif, else
let temperature = 14
if temperature > 25:
  echo "hot"
elif temperature > 10:
  echo "mild"
else:
  echo "cold"
#> mild

# %% if gives a value
# An `if` with an `else` is an expression: it can be the value of a `let`. A short branch fits on one line.
let n = 7
let parity = if n mod 2 == 0: "even" else: "odd"
echo n, " is ", parity
#> 7 is odd

# %% case
# `case` picks a branch by value; a branch can list several values or a range (`..` takes both ends). Every possible
# value must be covered — `else` covers the rest — so the compiler can tell you when one is missing.
for c in ['a', '7', '?']:
  case c
  of 'a' .. 'z': echo c, " is a letter"
  of '0' .. '9': echo c, " is a digit"
  of ' ', '\t': echo "space"
  else: echo c, " is something else"
#> a is a letter
#> 7 is a digit
#> ? is something else

# %% while
# `while` repeats as long as its condition holds.
var steps = 0
var x = 27
while x != 1:
  x = if x mod 2 == 0: x div 2 else: 3 * x + 1
  inc steps                   # inc: add one
echo "27 reaches 1 in ", steps, " steps"
#> 27 reaches 1 in 111 steps

# %% for and ranges
# `for` goes through a range: `a .. b` includes b, `a ..< b` stops before it. `countdown` counts down, and
# `countup` with a step skips.
for i in 1 .. 3: echo "up ", i
for i in 0 ..< 2: echo "from zero ", i
for i in countdown(3, 1): echo "down ", i
for i in countup(0, 10, 5): echo "by five ", i
#> up 1
#> up 2
#> up 3
#> from zero 0
#> from zero 1
#> down 3
#> down 2
#> down 1
#> by five 0
#> by five 5
#> by five 10

# %% break, continue and named blocks
# `continue` goes on to the next round; `break` leaves the loop. `block name:` names a block, and `break name`
# leaves it — from loops inside it too.
for i in 1 .. 10:
  if i mod 3 != 0: continue
  if i > 7: break
  echo "a multiple of 3: ", i
block search:
  for row in 1 .. 3:
    for col in 1 .. 3:
      if row * col == 6:
        echo "found 6 at ", row, ", ", col
        break search
#> a multiple of 3: 3
#> a multiple of 3: 6
#> found 6 at 2, 3

# %% Exercise: FizzBuzz
# For the numbers 1 to 15, put "Fizz" for a multiple of 3, "Buzz" for a multiple of 5, "FizzBuzz" for a multiple of
# both, and the number itself otherwise — each followed by a space. The loop below only puts the numbers.
var said = ""
for i in 1 .. 15:
  said.add $i
  said.add ' '
echo said
# Check:
if said == "1 2 Fizz 4 Buzz Fizz 7 8 Fizz Buzz 11 Fizz 13 14 FizzBuzz ": echo "✓ FizzBuzz"
else: echo "not yet: 3 is Fizz, 5 is Buzz, 15 is FizzBuzz"
# Answer:
  # var said = ""
  # for i in 1 .. 15:
  #   if i mod 15 == 0: said.add "FizzBuzz"
  #   elif i mod 3 == 0: said.add "Fizz"
  #   elif i mod 5 == 0: said.add "Buzz"
  #   else: said.add $i
  #   said.add ' '
  # echo said
