# Nim tour · 5 of 16 · Arrays, sequences and tuples
# notebook: compiled
#
# Nim's collections are values, as numbers are: an array has a fixed length, a sequence (`seq`) grows and shrinks,
# a tuple groups a few values of different types. Assigning one to another variable copies it.

# %% Arrays
# An array's length is part of its type: `array[3, int]` holds exactly three ints. `[…]` makes one.
var scores: array[3, int]          # all zeros to start with
scores[0] = 10
scores[2] = 30
let primes = [2, 3, 5, 7]
echo scores, " ", primes.len, " ", primes[^1]
#> [10, 0, 30] 4 7

# %% Sequences
# `@[…]` makes a seq; `add` puts an item on the end, `del` and `delete` take one out, `in` asks if one is there.
var fruit = @["apple", "pear"]
fruit.add "plum"
fruit.add @["fig", "kiwi"]
echo fruit, " ", fruit.len
fruit.delete(0)                    # delete keeps the order; del is faster and moves the last one into the gap
echo fruit, " ", "fig" in fruit, " ", fruit.find("plum")
#> @["apple", "pear", "plum", "fig", "kiwi"] 5
#> @["pear", "plum", "fig", "kiwi"] true 1

# %% Going through one
# `for x in s` gives the items; `for i, x in s` their indices too. `mitems` lets the loop change them.
var lengths: seq[int]
for f in fruit: lengths.add f.len
for i, f in fruit: echo i, ": ", f
for n in lengths.mitems: n = n * 10
echo lengths
#> 0: pear
#> 1: plum
#> 2: fig
#> 3: kiwi
#> @[40, 40, 30, 40]

# %% Slices
# `s[a .. b]` is a new seq (or string) of the items from a to b; `^1` counts from the end.
let letters = @['a', 'b', 'c', 'd', 'e']
echo letters[1 .. 3], " ", letters[2 .. ^1], " ", "Hello, Nim"[7 .. ^1]
#> @['b', 'c', 'd'] @['c', 'd', 'e'] Nim

# %% Copies, not shares
# Assigning a seq copies it: changing the copy leaves the first alone. (Lesson 8 shows `ref`, which shares.)
var a = @[1, 2, 3]
var b = a
b[0] = 100
echo a, " ", b
#> @[1, 2, 3] @[100, 2, 3]

# %% Tuples
# A tuple holds a fixed number of values, each with its own type, by position or by name. `let (x, y) = …` takes
# one apart.
let person = (name: "Ada", born: 1815)
echo person.name, " ", person.born, " ", person[0]
let (who, year) = person
echo who, " was born in ", year
proc minMax(xs: seq[int]): (int, int) = (min(xs), max(xs))
let (lo, hi) = minMax(@[4, 9, 1, 7])
echo lo, " .. ", hi
#> Ada 1815 Ada
#> Ada was born in 1815
#> 1 .. 9

# %% openArray: one proc for both
# A parameter of type `openArray[T]` takes an array or a seq (or a slice of one).
proc total(xs: openArray[int]): int =
  for x in xs: result += x
echo total([1, 2, 3]), " ", total(@[10, 20]), " ", total(primes)
#> 6 30 17

# %% Sets
# A `set` of small values (chars, enums, small ints) is a bit for each: `in` is instant. `{…}` makes one.
let vowels = {'a', 'e', 'i', 'o', 'u'}
var found = 0
for c in "programming in nim":
  if c in vowels: inc found
echo found, " vowels; ", 'z' in {'a' .. 'z'}
#> 5 vowels; true

# %% Exercise: keep the even ones
# Write `evens`: a seq of the even numbers of `xs`, in their order. As it is, it gives back an empty seq (`result`
# starts empty).
proc evens(xs: seq[int]): seq[int] =
  discard
echo evens(@[1, 2, 3, 4, 6, 9])
# Check:
if evens(@[1, 2, 3, 4, 6, 9]) == @[2, 4, 6] and evens(@[1, 3]).len == 0: echo "✓ evens works"
else: echo "not yet: evens(@[1, 2, 3, 4, 6, 9]) gives ", evens(@[1, 2, 3, 4, 6, 9]), ", not @[2, 4, 6]"
# Answer:
  # proc evens(xs: seq[int]): seq[int] =
  #   for x in xs:
  #     if x mod 2 == 0: result.add x
  # echo evens(@[1, 2, 3, 4, 6, 9])
