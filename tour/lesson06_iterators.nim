# Nim tour · 6 of 16 · Iterators
# notebook: compiled
#
# A `for` loop calls an iterator: `for x in s` is `for x in items(s)`, `for i, x in s` is `pairs`, `1 .. 5` is the
# iterator `..`. You can write your own: an iterator is a proc that `yield`s its values one at a time, and the loop
# runs its body for each — nothing is collected in between.

# %% A first iterator
# `yield` hands a value to the loop; the iterator goes on from there when the loop asks for the next one.
iterator countTo(n: int): int =
  var i = 1
  while i <= n:
    yield i
    inc i
for x in countTo(3): echo "got ", x
#> got 1
#> got 2
#> got 3

# %% Iterating your way
# An iterator can walk any shape: here the words of a text, without making a seq of them first.
iterator words(s: string): string =
  var w = ""
  for c in s:
    if c == ' ':
      if w.len > 0: yield w
      w = ""
    else: w.add c
  if w.len > 0: yield w
for w in words("  the quick  brown fox "): echo "[", w, "]"
#> [the]
#> [quick]
#> [brown]
#> [fox]

# %% Two values at a time
# An iterator can yield a tuple: the loop takes it apart into as many names.
iterator withIndex(s: string): (int, char) =
  for i in 0 ..< s.len: yield (i, s[i])
for i, c in withIndex("nim"): echo i, " ", c
#> 0 n
#> 1 i
#> 2 m

# %% Changing items in place
# An iterator of `var T` lets the loop change what it gives: `mitems` and `mpairs` are written so.
iterator everyOther(xs: var seq[int]): var int =
  var i = 0
  while i < xs.len:
    yield xs[i]
    i += 2
var nums = @[1, 2, 3, 4, 5]
for n in everyOther(nums): n = 0
echo nums
#> @[0, 2, 0, 4, 0]

# %% Collecting what an iterator gives
# `toSeq` (std/sequtils) runs an iterator and keeps what it yields; `collect` (std/sugar) builds a seq from a loop.
import std/[sequtils, sugar]
echo toSeq(countTo(5))
echo collect(for w in words("a bb ccc"): w.len)
let squares = collect:
  for x in countTo(10):
    if x mod 3 == 0: x * x
echo squares
#> @[1, 2, 3, 4, 5]
#> @[1, 2, 3]
#> @[9, 36, 81]

# %% Closure iterators
# The iterators above are pasted into the loop when compiled (inline: as fast as a hand-written loop). An iterator
# marked `{.closure.}` is a value instead: it can be stored, passed around, and resumed by calling it until
# `finished` says it has no more.
iterator ticks(): int {.closure.} =
  for i in 1 .. 3: yield i * 100
let next = ticks
var got: seq[int]
while true:
  let v = next()
  if finished(next): break
  got.add v
echo got
#> @[100, 200, 300]

# %% Exercise: the even numbers
# Write the iterator `evensUpTo`: 0, 2, 4 … up to and including `n` when n is even. As it is, it yields nothing.
iterator evensUpTo(n: int): int =
  discard
echo toSeq(evensUpTo(10))
# Check:
if toSeq(evensUpTo(10)) == @[0, 2, 4, 6, 8, 10] and toSeq(evensUpTo(5)) == @[0, 2, 4]: echo "✓ evensUpTo works"
else: echo "not yet: evensUpTo(10) gives ", toSeq(evensUpTo(10)), ", not @[0, 2, 4, 6, 8, 10]"
# Answer:
  # iterator evensUpTo(n: int): int =
  #   var i = 0
  #   while i <= n:
  #     yield i
  #     i += 2
  # echo toSeq(evensUpTo(10))
