# Nim tour · 7 of 16 · Types of your own
# notebook: compiled
#
# `type` makes new types: enumerations (a fixed list of names), objects (named fields together), distinct types (a
# number that must not be mixed up with another) and ranges. With them the compiler knows what your values mean,
# and catches more mistakes.

# %% Enumerations
# An `enum` is a list of names. `$` gives the name as a string, `ord` its number, and a `for` goes through them all.
type Direction = enum
  north, east, south, west
let heading = east
echo heading, " ", ord(heading), " ", succ(heading)
for d in Direction: echo "  ", d
#> east 1 south
#>   north
#>   east
#>   south
#>   west

# %% case and enums
# A `case` on an enum must cover every name: add one to the enum and the compiler shows each `case` that needs it.
proc turnRight(d: Direction): Direction =
  case d
  of north: east
  of east: south
  of south: west
  of west: north
echo turnRight(west), " ", west.turnRight.turnRight
#> north east

# %% Objects
# An object has fields; `Name(field: value, …)` makes one (fields left out are 0, "" …). `echo` shows them all.
type Point = object
  x, y: float
var p = Point(x: 3.0, y: 4.0)
p.y = 4.5
echo p, " ", p.x
#> (x: 3.0, y: 4.5) 3.0

# %% Procs for a type
# Procs with the object as their first parameter read like methods: `p.distance(q)`. Objects are values: `var q = p`
# copies, and `==` compares field by field.
import std/math
proc distance(a, b: Point): float = sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
proc `$`(p: Point): string = "(" & $p.x & " | " & $p.y & ")"    # how echo shows a Point, from now on
let origin = Point()
var q = Point(x: 3.0, y: 4.0)
echo q.distance(origin), " ", q, " ", q == Point(x: 3, y: 4)
#> 5.0 (3.0 | 4.0) true

# %% Distinct types
# `distinct` makes a new type out of an old one that does not mix with it: metres and feet are both floats, but
# adding one to the other is now a compile error. `{.borrow.}` takes the operations you want from the base type.
type
  Metres = distinct float
  Feet = distinct float
proc `+`(a, b: Metres): Metres {.borrow.}
proc `$`(m: Metres): string {.borrow.}
proc toMetres(f: Feet): Metres = Metres(float(f) * 0.3048)
let run = Metres(400) + toMetres(Feet(1000))
echo run
# let wrong = Metres(1) + Feet(1)      # take away the # and run: the compiler refuses
#> 704.8

# %% Ranges
# A `range` type holds only the numbers between its ends; a value outside them stops the program (it is checked).
type Percent = range[0 .. 100]
var charge: Percent = 80
charge = charge + 15
echo charge
#> 95

# %% Objects with variants
# A `case` inside an object makes fields that depend on a kind: a circle has a radius, a rectangle a width and a
# height. Reading a field the kind does not have stops the program.
type
  ShapeKind = enum circle, rectangle
  Shape = object
    case kind: ShapeKind
    of circle: radius: float
    of rectangle: width, height: float
proc area(s: Shape): float =
  case s.kind
  of circle: PI * s.radius * s.radius
  of rectangle: s.width * s.height
let shapes = @[Shape(kind: circle, radius: 1.0), Shape(kind: rectangle, width: 2.0, height: 3.0)]
for s in shapes: echo s.kind, ": ", round(s.area, 2)
#> circle: 3.14
#> rectangle: 6.0

# %% Exercise: the perimeter
# Write `perimeter` for the Shape above: 2 × π × radius for a circle, 2 × (width + height) for a rectangle.
proc perimeter(s: Shape): float =
  0.0
# Check:
let rp = perimeter(Shape(kind: rectangle, width: 2.0, height: 3.0))
let cp = perimeter(Shape(kind: circle, radius: 1.0))
if rp == 10.0 and abs(cp - 6.2832) < 0.001: echo "✓ perimeter works"
else: echo "not yet: the 2 × 3 rectangle gives ", rp, " (10.0), the circle of radius 1 ", cp, " (6.283…)"
# Answer:
  # proc perimeter(s: Shape): float =
  #   case s.kind
  #   of circle: 2 * PI * s.radius
  #   of rectangle: 2 * (s.width + s.height)
