# Nim tour · 9 of 16 · Generics
# notebook: compiled
#
# A generic proc or type has a type parameter, in square brackets: written once, it works for ints, strings, your
# own objects. Nim makes a copy for each type it is used with, when compiling, so it is as fast as if you had
# written each one by hand — and the types are still checked.

# %% A generic proc
# `[T]` is the type parameter. Nim works T out from the arguments, or you name it: `biggest[float](…)`.
proc biggest[T](xs: openArray[T]): T =
  result = xs[0]
  for x in xs:
    if x > result: result = x
echo biggest([3, 9, 4]), " ", biggest(["pear", "apple", "plum"]), " ", biggest[float]([1.5, 0.5])
#> 9 plum 1.5

# %% A generic type
# A type can have parameters too: a Stack of anything. Its procs take `Stack[T]` and work for every T.
type Stack[T] = object
  items: seq[T]
proc push[T](s: var Stack[T], x: T) = s.items.add x
proc pop[T](s: var Stack[T]): T = s.items.pop()
proc isEmpty[T](s: Stack[T]): bool = s.items.len == 0
var numbers: Stack[int]
numbers.push 1
numbers.push 2
var names = Stack[string]()
names.push "Ada"
echo numbers.pop, " ", numbers.pop, " ", numbers.isEmpty, " ", names.pop
#> 2 1 true Ada

# %% Constraints
# `T: SomeNumber` lets only numbers in; `int | float` is a type class of your own. Calling it with something else
# is a compile error that says why.
proc average[T: SomeNumber](xs: openArray[T]): float =
  for x in xs: result += float(x)
  result / float(xs.len)
proc half(x: int | float): float = float(x) / 2
echo average([1, 2, 3, 4]), " ", average([0.5, 1.5]), " ", half(5), " ", half(1.0)
# echo average(["a", "b"])        # take away the # and run: strings are not SomeNumber
#> 2.5 1.0 2.5 0.5

# %% Choosing while compiling
# `when` is an `if` decided while compiling: in a generic proc it can do something different for one type. `is`
# asks about a type.
proc describe[T](x: T): string =
  when T is string: "the text " & x
  elif T is SomeInteger: "the whole number " & $x
  else: "a " & $T & ": " & $x
echo describe("hi"), " · ", describe(7), " · ", describe(2.5), " · ", describe('c')
#> the text hi · the whole number 7 · a float64: 2.5 · a char: c

# %% Types as values
# A `typedesc` parameter takes a type itself: `default(T)` is a type's zero value, `sizeof` its size in bytes.
proc info(T: typedesc): string = $T & " is " & $sizeof(T) & " bytes, zero is " & $default(T)
echo info(int32)
echo info(bool)
#> int32 is 4 bytes, zero is 0
#> bool is 1 bytes, zero is false

# %% Generic types with two parameters
# A table of keys to values, a pair of two things: as many type parameters as you need.
type Pair[A, B] = object
  first: A
  second: B
proc pairOf[A, B](a: A, b: B): Pair[A, B] = Pair[A, B](first: a, second: b)
let p = pairOf("answer", 42)
echo p.first, " = ", p.second, " (", $typeof(p), ")"
#> answer = 42 (Pair[system.string, system.int])

# %% Exercise: swap the pair
# Write `swapped`: a Pair with the second value first and the first second — its type is Pair[B, A]. As it is, it
# gives back an empty Pair.
proc swapped[A, B](p: Pair[A, B]): Pair[B, A] =
  discard
# Check:
let s = swapped(pairOf(1, "one"))
if s.first == "one" and s.second == 1 and swapped(s) == pairOf(1, "one"): echo "✓ swapped works"
else: echo "not yet: swapped(pairOf(1, \"one\")) gives (", s.first, ", ", s.second, ")"
# Answer:
  # proc swapped[A, B](p: Pair[A, B]): Pair[B, A] =
  #   Pair[B, A](first: p.second, second: p.first)
