# Nim tour · 15 of 16 · Memory: ARC, ORC, sink and lent
# notebook: compiled
#
# Nim frees memory for you, without a garbage collector that stops the program now and then. With ARC and ORC (ORC
# is the default), the compiler works out when a value is no longer used and frees it right there — when its owner
# goes out of scope — by putting calls to destructors into your code. Strings, seqs and objects are values with one
# owner: assigning one copies it, unless the compiler can see it is the last use, and then it moves it (no copy).
# `ref` objects are counted: freed when the last reference goes. ORC also finds refs that point at each other in
# a circle.
#
# ned shows it: Nim › Inspect › "ARC/ORC view" shows the destructor calls, copies and moves the compiler put into a
# proc, and "Where ARC/ORC copies" marks each copy in the file.

# %% Seeing it happen: hooks
# A type can have its own `=destroy` (called when a value of it is freed) and `=copy` (called when one is copied).
# This one says when, so we can watch the compiler at work. (Hooks are declared before the type is first used.)
type Res = object
  name: string
var copies = 0
proc `=destroy`(r: Res) =
  if r.name.len > 0: echo "  free ", r.name
proc `=copy`(dst: var Res, src: Res) =
  inc copies
  echo "  copy ", src.name
  `=destroy`(dst)
  dst.name = src.name
proc scope() =
  let a = Res(name: "a")
  echo "  in the scope, with ", a.name
echo "before"
scope()
echo "after"
#> before
#>   in the scope, with a
#>   free a
#> after

# %% Copy or move
# `b = a` copies when `a` is used again later — two owners, two values. At the last use of `a` there is nothing to
# keep: the value moves, and no copy is made. `move` asks for a move.
proc copyOrMove() =
  let a = Res(name: "first")
  var b = a                  # a is used below: copied
  b.name.add "+"             # (b is a value of its own: a does not change)
  echo "  a is still ", a.name
  let c = b                  # the last use of b: moved, not copied
  echo "  c has ", c.name
  var d = Res(name: "second")
  let e = move(d)            # d is left empty
  echo "  e has ", e.name, ", d has \"", d.name, "\""
copies = 0
copyOrMove()
echo "copies: ", copies
#>   copy first
#>   a is still first
#>   c has first+
#>   e has second, d has ""
#>   free second
#>   free first+
#>   free first
#> copies: 1

# %% sink parameters
# A `sink` parameter takes over its argument: the caller gives it away, by a move when it can. A parameter without
# `sink` is borrowed — storing it somewhere makes a copy.
var kept: seq[Res]
proc keepBorrowed(r: Res) = kept.add r      # r is borrowed: kept.add has to copy it
proc keepSink(r: sink Res) = kept.add r     # r is ours: it moves into kept
copies = 0
keepBorrowed(Res(name: "borrowed"))
echo "copies after keepBorrowed: ", copies
copies = 0
keepSink(Res(name: "sunk"))
echo "copies after keepSink: ", copies
#>   copy borrowed
#> copies after keepBorrowed: 1
#> copies after keepSink: 0

# %% lent: borrowing a result
# A proc that gives back a part of its argument can give it as `lent T`: a view of it, not a copy.
type Shelf = object
  items: seq[Res]
proc first(s: Shelf): lent Res = s.items[0]
proc firstCopy(s: Shelf): Res = s.items[0]
var shelf = Shelf(items: @[Res(name: "book")])
copies = 0
echo "  lent: ", shelf.first.name, " — copies: ", copies
echo "  copied: ", shelf.firstCopy.name, " — copies: ", copies
#>   lent: book — copies: 0
#>   copy book
#>   copied: book — copies: 1

# %% ref objects are counted
# A ref is freed when the last reference to it goes — and with it what it holds, here a Res that says so.
type Node = ref object
  tag: Res
  next: Node
proc refs() =
  var x = Node(tag: Res(name: "node x"))
  block:
    let y = x                  # two references to one node
    echo "  shared: ", y.tag.name
  x = nil                      # the last one gone: freed here
  echo "  x is nil now"
refs()
#>   shared: node x
#>   free node x
#>   x is nil now

# %% Cycles: what ORC adds
# Two nodes that point at each other keep each other's count above zero: counting alone (ARC) never frees them.
# ORC finds such cycles and frees them, which is why it is the default. (With --mm:arc you break cycles yourself,
# or mark a field {.cursor.} so it does not count.)
proc cycle() =
  let a = Node(tag: Res(name: "node a"))
  let b = Node(tag: Res(name: "node b"), next: a)
  a.next = b                   # a → b → a
  echo "  a cycle made"
cycle()
GC_fullCollect()               # ORC would find the cycle by itself in time; this asks now
echo "after the collection"
#>   a cycle made
#>   free node a
#>   free node b
#> after the collection

# %% Exercise: no copies
# `store` copies each value it puts in the box, because `r` is borrowed. Change one word in it so that it takes
# its argument over and the check counts no copies.
var box: seq[Res]
proc store(r: Res) =
  box.add r
# Check:
copies = 0
store(Res(name: "one"))
store(Res(name: "two"))
if copies == 0 and box.len == 2: echo "✓ no copies"
else: echo "not yet: ", copies, " copies"
# Answer:
  # var box: seq[Res]
  # proc store(r: sink Res) =
  #   box.add r
