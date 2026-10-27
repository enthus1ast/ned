# Nim tour · 8 of 16 · References and inheritance
# notebook: compiled
#
# An `object` is a value: assigning it copies it. A `ref object` lives in one place, and what you assign is a
# reference to it — two names, one object. References can be `nil` (nothing), can point to each other to build
# lists and trees, and can be the base of a family of types that share procs: inheritance and methods.

# %% Values and references
# Changing a copy of an object leaves the first alone; changing through a second reference changes the one object.
type
  PointV = object
    x: int
  PointR = ref object
    x: int
var v1 = PointV(x: 1)
var v2 = v1
v2.x = 99
let r1 = PointR(x: 1)
let r2 = r1                         # (let: the reference cannot change; the object it points to can)
r2.x = 99
echo v1.x, " ", v2.x, " — ", r1.x, " ", r2.x, " ", r1 == r2
#> 1 99 — 99 99 true

# %% nil
# A reference that points to nothing is `nil`. Reading a field through nil stops the program, so check first.
var nobody: PointR
echo nobody == nil, " ", nobody.isNil
nobody = PointR(x: 5)
if nobody != nil: echo "now it has x = ", nobody.x
#> true true
#> now it has x = 5

# %% A linked list
# A type can refer to itself through a ref: each node holds a value and the next node, the last one nil.
type Node = ref object
  value: int
  next: Node
proc prepend(head: Node, v: int): Node = Node(value: v, next: head)
var list: Node = nil
for v in [3, 2, 1]: list = list.prepend(v)
var cur = list
while cur != nil:
  echo cur.value
  cur = cur.next
#> 1
#> 2
#> 3

# %% A tree
# The same with two children: a binary search tree, smaller values to the left.
type Tree = ref object
  key: int
  left, right: Tree
proc insert(t: var Tree, k: int) =
  if t == nil: t = Tree(key: k)
  elif k < t.key: insert(t.left, k)
  else: insert(t.right, k)
proc inOrder(t: Tree, into: var seq[int]) =
  if t == nil: return
  inOrder(t.left, into)
  into.add t.key
  inOrder(t.right, into)
var root: Tree
for k in [50, 30, 70, 20, 40, 60]: root.insert k
var sorted: seq[int]
root.inOrder(sorted)
echo sorted
#> @[20, 30, 40, 50, 60, 70]

# %% Inheritance
# `ref object of RootObj` makes a type others can inherit from; `of Animal` inherits its fields. A `method` is
# chosen by the object's real type while the program runs (`{.base.}` marks the first one).
type
  Animal = ref object of RootObj
    name: string
  Dog = ref object of Animal
  Cat = ref object of Animal
    lives: int
method speak(a: Animal): string {.base.} = a.name & " makes a sound"
method speak(d: Dog): string = d.name & " says woof"
method speak(c: Cat): string = c.name & " says miaow (" & $c.lives & " lives)"
let zoo: seq[Animal] = @[Dog(name: "Rex"), Cat(name: "Tom", lives: 9), Animal(name: "Fish")]
for a in zoo: echo a.speak
#> Rex says woof
#> Tom says miaow (9 lives)
#> Fish makes a sound

# %% What is it really?
# `of` asks for an object's type while the program runs, and a conversion `Cat(a)` gets the Cat back.
for a in zoo:
  if a of Cat: echo a.name, " is a cat with ", Cat(a).lives, " lives"
  elif a of Dog: echo a.name, " is a dog"
#> Rex is a dog
#> Tom is a cat with 9 lives

# %% Exercise: count and add up
# Write `count` and `sum` for the linked list above: how many nodes, and their values added up. Walk the list from
# `head` to nil as the cell "A linked list" does.
proc count(head: Node): int =
  0
proc sum(head: Node): int =
  0
# Check:
let three = nil.Node.prepend(30).prepend(20).prepend(10)
if count(three) == 3 and sum(three) == 60 and count(nil) == 0: echo "✓ count and sum work"
else: echo "not yet: the list 10 → 20 → 30 has count ", count(three), " (3) and sum ", sum(three), " (60)"
# Answer:
  # proc count(head: Node): int =
  #   var n = head
  #   while n != nil:
  #     inc result
  #     n = n.next
  # proc sum(head: Node): int =
  #   var n = head
  #   while n != nil:
  #     result += n.value
  #     n = n.next
