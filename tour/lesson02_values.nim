# Nim tour · 2 of 16 · Values and types
# notebook: compiled
#
# Every value in Nim has a type, known when the program is compiled: a whole number is an `int`, a number with a
# point a `float`, text a `string`. You rarely write the type — Nim works it out from the value — but it is always
# there, and the compiler stops a program that mixes types up before it runs.

# %% let, var and const
# `let` names a value that does not change; `var` one that does; `const` one worked out while compiling.
let planet = "Earth"
var moons = 0
moons = moons + 1
moons += 1                    # the same as moons = moons + 1
const secondsPerDay = 24 * 60 * 60
echo planet, " ", moons, " ", secondsPerDay
#> Earth 2 86400

# %% The basic types
# `typeof` tells the type of a value (a `float` is a float64: 64 bits). You can also state the type after the name,
# with a colon.
let count = 3
let price = 2.5
let ready = true
let letter = 'n'              # a char: one byte, in single quotes
let title: string = "tour"
echo typeof(count), " ", typeof(price), " ", typeof(ready), " ", typeof(letter), " ", typeof(title)
#> int float64 bool char string

# %% Arithmetic
# `div` and `mod` divide whole numbers; `/` always gives a float.
echo 7 + 2, " ", 7 - 2, " ", 7 * 2
echo 7 div 2, " ", 7 mod 2, " ", 7 / 2
#> 9 5 14
#> 3 1 3.5

# %% No silent mixing
# An int and a float do not mix by themselves: say which you mean. `float(n)` and `toFloat` make a float, `int(x)`
# cuts the part after the point off, `round` (from std/math) rounds.
import std/math
let apples = 3
echo float(apples) * 1.5
echo int(4.99), " ", round(4.5), " ", toInt(4.4)
#> 4.5
#> 4 5.0 4

# %% Strings and characters
# A string knows its length; `s[0]` is its first character. `add` puts more on the end of a `var` string.
var word = "nim"
echo word.len, " ", word[0], " ", word[^1]   # ^1: the last one
word.add "ble"
word.add '!'
echo word
echo "say \"hi\"", " · ", r"C:\no\escapes"   # \" is a quote in a string; an r"…" string takes \ as it is
#> 3 n m
#> nimble!
#> say "hi" · C:\no\escapes

# %% Booleans
# Comparisons give a `bool`; `and`, `or` and `not` combine them.
let age = 20
echo age >= 18, " ", age == 21, " ", age != 21
echo age > 10 and age < 30, " ", not (age > 10)
#> true false true
#> true false

# %% Sizes of whole numbers
# `int` has the size of a pointer (64 bits on most machines). There are sized ones too — int8 … int64, uint8 …
# uint64 — and `low` and `high` tell their limits. Going past a limit is an error that stops the program: Nim
# checks it, so a number never wraps around without you knowing.
echo low(int8), " .. ", high(int8)
echo high(uint8), " ", sizeof(int32), " bytes"
#> -128 .. 127
#> 255 4 bytes

# %% Exercise: hours and minutes
# A film runs for `total` minutes. Work out how many whole hours that is and how many minutes are left over, with
# `div` and `mod`, instead of the zeros.
let total = 200
let hours = 0
let minutes = 0
echo total, " minutes is ", hours, " h ", minutes, " min"
# Check:
if hours == 3 and minutes == 20: echo "✓ 3 h 20 min"
else: echo "not yet: ", hours, " h ", minutes, " min — 200 minutes is 3 h 20 min"
# Answer:
  # let total = 200
  # let hours = total div 60
  # let minutes = total mod 60
  # echo total, " minutes is ", hours, " h ", minutes, " min"
