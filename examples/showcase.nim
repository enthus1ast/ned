## ned showcase — one Nim file that exercises what ned (6.11) does for Nim.
##
## Open it:   ned showcase.nim        Run it:   F5 (or `nim c -r showcase.nim`)
## Each section says what to try. Alt+Enter = quick fixes · Alt+H = hover · F12 = go to definition ·
## Shift+F12 = references · F2 = rename · Alt+M = expand a template/macro · Alt+F = format ·
## Ctrl+E = command palette (type "Nim:" to see every Nim command). Help › Performance… shows how ned keeps up
## on your device: frames, what each sends to the terminal, and what the engine takes.
##
## A few things need a project around the file, not just the file: put it in a folder with a .nimble
## (`nimble init`) to see the .nimble checks, `Nimble: dependency tree`, `Nim: add a CI workflow` and
## `ned --lint --fix`; and `Test coverage: run` colours the lines the tests below ran.

# ── 1. Imports ─────────────────────────────────────────────────────────────────────────────────────────
# The second import below is never used: the engine marks it at once (unused-import) — Alt+Enter removes it.
# Hover a module name to see what it is; F12 opens it. Completion after `import std/` lists the modules.
import std/[strutils, strformat, tables, json, pegs, os, options, sequtils, algorithm, asyncdispatch, macros, math]
import std/base64

# ── 2. Types: memory layout, inheritance, variants, generics, distinct, concepts ──────────────────────
type
  # Hover `Packet`: each field's offset, size and padding (as the C compiler lays it out). Alt+Enter on
  # this line: "Reorder fields to save 8 bytes (24 → 16 B)".
  Packet = object
    flag: bool
    id: int64
    kind: uint8
    size: int32

  # Inheritance: Alt+Enter / palette "Nim: type hierarchy" on Animal; "Go to implementation" on speak.
  Animal = ref object of RootObj
    name: string
  Dog = ref object of Animal
  Cat = ref object of Animal

  # A variant (case) object. Write `case n.kind` and Alt+Enter: "Add the missing branches".
  NodeKind = enum
    nkNum, nkAdd, nkNeg
  Node = ref object
    case kind: NodeKind
    of nkNum: val: int
    of nkAdd: left, right: Node
    of nkNeg: inner: Node

  # A generic type: hover `push` in main() to see the instance (T = int).
  Stack[T] = object
    items: seq[T]

  Vec2 = object
    x, y: float

  Config = object
    title: string
    size: int

  Circle = object
    r: float
  Square = object
    side: float
  Line = object
    length: float

  # A concept: hover `HasArea` — "satisfied by: Circle, Square" (Line has no area). Hover Circle:
  # "satisfies: HasArea". "Go to implementation" on HasArea lists them.
  HasArea = concept
    proc area(s: Self): float

# A template that declares things: hover `Meters` below — the engine knows what the call declares.
template defineUnit(name, base: untyped) =
  type name* = distinct base
  proc `+`*(a, b: name): name {.borrow.}
  proc `$`*(a: name): string {.borrow.}

defineUnit(Meters, float)

# A macro that makes names: `getTitle` and `getSize` exist only after it runs. ned asks the compiler once
# (in the background), then completion, hover and F12 know them (F12 goes to this call).
macro makeGetters(T: typedesc, fields: varargs[untyped]): untyped =
  result = newStmtList()
  for f in fields:
    let name = ident("get" & capitalizeAscii($f))
    result.add quote do:
      proc `name`(x: `T`): auto = x.`f`

makeGetters(Config, title, size)

# ── 3. Routines: type hints, parameter names, the engine's hints ───────────────────────────────────────
# Grey type hints appear after each `let`/`var` without a type, and parameter names before literal
# arguments in calls: `paint(width: 10, height: 20, filled: true)`.

func area(c: Circle): float = PI * c.r * c.r
func area(s: Square): float = s.side * s.side

# can-be-func: this proc has no side effects — "'perimeter' has no side effects: it can be a func".
proc perimeter(s: Square): float = 4 * s.side

proc `+`(a, b: Vec2): Vec2 = Vec2(x: a.x + b.x, y: a.y + b.y)

proc push[T](s: var Stack[T], x: T) = s.items.add x
proc pop[T](s: var Stack[T]): T = s.items.pop()

iterator evens(n: int): int =
  for i in countup(0, n, 2): yield i

method speak(a: Animal): string {.base.} = "…"
method speak(d: Dog): string = d.name & ": woof"
method speak(c: Cat): string = c.name & ": meow"

# var-let: `limit` is never changed — "it can be a let" (Alt+Enter makes it one, or every one in the file).
# unused-param: `verbose` is never used.
proc describe(s: Square, verbose: bool): string =
  var limit = 100.0
  result = "a square of side " & $s.side
  if s.side > limit: result.add " (huge)"

# result-unset: this routine never assigns its result — "it always returns the default value".
proc pick(a: int): int =
  if a > 1:
    echo "big"

proc total(xs: openArray[int]): int =
  for x in xs: result += x

# deprecated: std/os's `existsFile` is marked at once, in the compiler's words ("use fileExists");
# Alt+Enter → "Use fileExists instead".
proc haveConfig(path: string): bool =
  existsFile(path)

# Exception hints (View › Editor › Exception hints, or hover the name): {.raises: [IOError].}
proc readConfig(path: string): string =
  if not fileExists(path):
    raise newException(IOError, "no config at " & path)
  readFile(path)

# An async proc: hover the call in main() — a Future[int].
proc fetchCount(): Future[int] {.async.} =
  await sleepAsync(1)
  result = 3

# runnableExamples: ned shows a ▶ beside it and runs the examples (their output in the panel).
proc double*(x: int): int =
  ## Twice `x`.
  runnableExamples:
    assert double(21) == 42
  x * 2

# Where ARC/ORC copies (nim.showCopies, after a save): `b = a` copies — `a` is used again below.
proc keepBoth(a: seq[int]): (seq[int], seq[int]) =
  var b = a
  b.add 1
  (a, b)

# A line the lint rules leave alone: `# ned: ignore[var-let]` (Alt+Enter → "Silence var-let on this line").
proc counterStart(): int =
  var start = 0  # ned: ignore[var-let]
  start

# ── 4. Compile-time values and platform branches ──────────────────────────────────────────────────────
# Hover a const to see its value. The `when` branch left out on this platform is dimmed.
const
  TableSize = 1 shl 10
  Greeting = "salaam".toUpperAscii
when defined(windows):
  const LineEnd = "\r\n"
else:
  const LineEnd = "\n"

# ── 5. C: a header's function, and C written in {.emit} ───────────────────────────────────────────────
# F12 on `cStrlen` opens strlen's prototype in <string.h>; its C signature is shown dimmed after the
# line (nim.cSignatureHints); `header:` and `importc:` strings have hover and completion too.
proc cStrlen(s: cstring): csize_t {.importc: "strlen", header: "<string.h>".}

# The C in an emit edits as C: indentation, completion (struct members, nimbase.h, its headers), hover,
# C compiler errors on these very lines, and Alt+F formats it (clang-format or ned's own C formatter).
# F12 on `addInts` in its declaration below goes to `add_ints` here (F12 on `add_ints` comes back).
{.emit: """
/*TYPESECTION*/
#include <stdio.h>

typedef struct { int count; double sum; } Tally;

static int add_ints(int a, int b) {
    Tally t = {0, 0.0};
    t.count = a + b;
    t.sum = (double)t.count / 2.0;
    return t.count;
}
""".}

proc addInts(a, b: cint): cint {.importc: "add_ints", nodecl.}

# ── 6. Other languages inside strings ─────────────────────────────────────────────────────────────────
# Each string below is coloured as its language (and HTML, CSS, SQL, JSON and JS go to their language
# servers when installed: errors on the Nim line, completion, hover). Name your own routines with
# "nim.embeddedLanguages": {"render": "html"}.
func sql(s: string): string = s
func html(s: string): string = s
func css(s: string): string = s
func js(s: string): string = s

const
  Query = sql"""SELECT name, size FROM shapes WHERE size > 3 ORDER BY name"""
  Page = html"""<div class="card"><h1>ned</h1><p>A Nim IDE in your terminal</p></div>"""
  Style = css""".card { color: #c0caf5; padding: 2px 4px; }"""
  Script = js"""document.querySelector(".card").classList.add("seen");"""
  Marked = #[html]# """<ul><li>a #[html]# marker colours any string</li></ul>"""

proc embedded(): string =
  let conf = parseJson("""{"title": "ned", "size": 3, "tags": ["nim", "termux"]}""")
  let who = conf["title"].getStr
  var key = ""
  if "colour=blue" =~ peg"{\ident} '=' {\ident}":
    key = matches[0]
  result = fmt"{who} has {conf[""size""].getInt} tags; first key: {key}"
  result.add &" · {Query.len + Page.len + Style.len + Script.len + Marked.len} chars of other languages"

# ── 7. Formatting ─────────────────────────────────────────────────────────────────────────────────────
# Alt+F formats the file in nph's style (the next line is written badly on purpose); select lines first to
# format only those. "Format: preview as a diff" shows the change before making it.
proc  messy( a:int,b:int ):int=a+b

# ── 8. TODO tags (the TODOs dock lists them; Ctrl+E › TODO) ───────────────────────────────────────────
# TODO: read the config from ~/.config/showcase/
# FIXME: pick() never returns a value
# NOTE: `messy` is badly formatted on purpose

# ── 9. Main ───────────────────────────────────────────────────────────────────────────────────────────
# Try here: type `xs.` for member completion (fields first, then the procs that take it); `xs.for` + Tab
# (postfix completion); `p.` on a Packet; `Config(` lists its fields. Rename `total` with F2. F9 puts a
# breakpoint, F5 debugs with gdb (variables, watches, inline values at the end of each line).
proc main() =
  let xs = @[3, 1, 4, 1, 5]
  let sq = Square(side: 2)
  let shapes = (Circle(r: 1.0), sq)
  var st: Stack[int]
  st.push 10
  st.push 20
  let p = Packet(flag: true, id: 7, kind: 1, size: 64)
  let cfg = Config(title: "showcase", size: TableSize)
  let pets: seq[Animal] = @[Dog(name: "Rex"), Cat(name: "Tom")]
  var counts = initTable[string, int]()
  for w in "the cat and the dog".split: counts.mgetOrPut(w, 0).inc
  let (kept, more) = keepBoth(xs)
  let tree = Node(kind: nkAdd, left: Node(kind: nkNum, val: 2), right: Node(kind: nkNum, val: 3))
  let walked = Meters(1.5) + Meters(2.0)

  echo Greeting, " — ", cfg.getTitle, " ", cfg.getSize, LineEnd.strip
  echo "total ", total(xs), ", max ", xs.max, ", sorted? ", xs.isSorted, ", config? ", haveConfig("x.conf")
  echo "areas ", area(shapes[0]).formatFloat(ffDecimal, 2), " ", area(shapes[1]), " perimeter ", perimeter(sq)
  echo describe(sq, verbose = true), " · pick ", pick(1), " · popped ", st.pop
  echo "packet ", p.id, " of size ", p.size, " · vector ", Vec2(x: 1, y: 2) + Vec2(x: 3, y: 4)
  for a in pets: echo a.speak
  echo "evens ", toSeq(evens(8)), " · counts ", counts, " · kept ", kept.len, " more ", more.len
  echo "C strlen ", cStrlen("hello"), " · C add_ints ", addInts(40, 2), " · walked ", walked, " m"
  echo embedded(), " · double ", double(4), " · start ", counterStart(), " · messy ", messy(1, 2)
  echo "tree root ", tree.kind, " · fetched ", waitFor fetchCount(), " · some ", some(5).get
  try:
    echo readConfig("/no/such/showcase.conf")
  except IOError as e:
    echo "no config (", e.msg, ")"

# ── 10. Tests ─────────────────────────────────────────────────────────────────────────────────────────
# The Tests dock (test explorer) lists these; ▶ in the gutter runs one; with "nim.testOnSave" they run on
# every save and show ✓ or ✗ beside each test. "Test coverage: run" colours the lines they reached.
when isMainModule:
  import std/unittest

  suite "showcase":
    test "shapes":
      check area(Square(side: 3)) == 9.0
      check perimeter(Square(side: 1)) == 4.0
    test "stack":
      var s: Stack[string]
      s.push "a"
      check s.pop == "a"
    test "C from Nim":
      check addInts(2, 3) == 5
      check cStrlen("ned") == 3

  main()
