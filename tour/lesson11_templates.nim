# Nim tour · 11 of 16 · Templates and compile time
# notebook: compiled
#
# A template looks like a proc, but it is not called: its body is pasted where it is used, with the arguments put
# in, while compiling. That makes a template good for small helpers that cost nothing and for new kinds of blocks.
# Nim can also run ordinary code while it compiles — for constants, checks and tables worked out ahead of time.

# %% A first template
# `untyped` takes a piece of code as it is written; the body below says that code twice.
template twice(body: untyped) =
  body
  body
twice:
  echo "hello"
#> hello
#> hello

# %% Arguments are pasted, not passed
# A proc's arguments are worked out before the call; a template's are pasted where they appear — so one that is
# not used is never worked out. Here the expensive message is only built when logging is on.
var logging = false
proc expensive(): string =
  echo "  (building the message)"
  "a message"
template log(msg: string) =
  if logging: echo "log: ", msg
log(expensive())
logging = true
log(expensive())
#>   (building the message)
#> log: a message

# %% Templates that make names
# A name declared in a template is its own (hygiene) unless marked `{.inject.}`: then the code using the template
# sees it — here `it`, as in std/sequtils' mapIt.
template withEach(xs: openArray[int], body: untyped) =
  for x in xs:
    let it {.inject.} = x
    body
withEach([1, 2, 3]):
  echo it * it
#> 1
#> 4
#> 9

# %% Timing a block
# A template can wrap code around a block: here the time it took (std/monotimes). `astToStr` gives the code of an
# argument as a string.
import std/[monotimes, times]
template timed(label: string, body: untyped) =
  let t0 = getMonoTime()
  body
  let took = getMonoTime() - t0
  echo label, ": done", (if took < initDuration(seconds = 10): "" else: " (slow)")
template show(e: untyped) = echo astToStr(e), " = ", e
timed "summing":
  var s = 0
  for i in 1 .. 1_000_000: s += i
  show s
show 6 * 7
#> s = 500000500000
#> summing: done
#> 6 * 7 = 42

# %% Running code while compiling
# `const` values are worked out by the compiler, and may call ordinary procs: here a table of squares, built before
# the program runs. A `static:` block runs while compiling, and `doAssert` in it stops the build when it fails.
proc squares(n: int): seq[int] =
  for i in 0 ..< n: result.add i * i
const table = squares(8)
static:
  doAssert table.len == 8
echo table
#> @[0, 1, 4, 9, 16, 25, 36, 49]

# %% when and defined
# `when` picks code while compiling: the other branch is not even compiled. `defined(x)` asks about the platform or
# a switch given with -d:x, so what this cell prints depends on your system. (Nim › Inspect › "Macro expansion in a
# tab" shows a template call pasted out.)
when defined(windows):
  echo "on Windows"
elif defined(posix):
  echo "on a POSIX system: ", hostOS, " on ", hostCPU
when not defined(release):
  echo "a debug build: every check on"

# %% Exercise: repeat
# Write the template `repeat`, which runs its block `n` times. As it is, it does nothing.
template repeat(n: int, body: untyped) =
  discard
var hits = 0
repeat 3:
  inc hits
echo hits
# Check:
var later = 0
repeat 5:
  later += 2
if hits == 3 and later == 10: echo "✓ repeat works"
else: echo "not yet: repeat 3 ran its block ", hits, " times"
# Answer:
  # template repeat(n: int, body: untyped) =
  #   for _ in 1 .. n:
  #     body
  # var hits = 0
  # repeat 3:
  #   inc hits
  # echo hits
