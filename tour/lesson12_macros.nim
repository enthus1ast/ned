# Nim tour · 12 of 16 · Macros
# notebook: compiled
#
# A macro is a proc that runs while compiling: it is given code as a tree (the AST — abstract syntax tree), and
# gives back the code to compile in its place. Templates paste; macros can look at the code, take it apart and
# build new code. Use a template when it is enough, and a macro when you need to inspect or generate code.
#
# ned helps here: put the cursor on a macro call and use Nim › Expand macro to see the code it becomes.

# %% Code is a tree
# `treeRepr` shows the tree of a piece of code. This macro returns it as a string literal (`newLit`), so the program
# prints the tree of `1 + 2 * x`: a call of `+`, whose second argument is a call of `*`.
import std/macros
macro treeOf(code: untyped): untyped = newLit(code.treeRepr)
echo treeOf(1 + 2 * x)
#> Infix
#>   Ident "+"
#>   IntLit 1
#>   Infix
#>     Ident "*"
#>     IntLit 2
#>     Ident "x"

# %% Building code with quote
# `quote do:` writes the code to give back as code, with the macro's values put in where `` `name` `` stands.
# This `check` prints the expression it was given, its value, and whether it held.
macro check(cond: untyped): untyped =
  let text = cond.repr
  quote do:
    echo (if `cond`: "ok:   " else: "FAIL: "), `text`
check 1 + 1 == 2
check "nim".len == 4
#> ok:   1 + 1 == 2
#> FAIL: "nim".len == 4

# %% Taking arguments apart
# `varargs[untyped]` takes any number of arguments. The macro builds an `echo` call node by node: for each
# argument, its code as text, " = ", and its value.
macro show(args: varargs[untyped]): untyped =
  result = newCall(ident"echo")
  for i, a in args:
    if i > 0: result.add newLit(", ")
    result.add newLit(a.repr & " = ")
    result.add a
let width = 3
let height = 4
show width, height, width * height
#> width = 3, height = 4, width * height = 12

# %% Making procs
# A macro can declare things. This one makes a getter proc for each name it is given, from a table of settings.
import std/tables
let settings = {"colour": "blue", "size": "large"}.toTable
macro getters(names: varargs[untyped]): untyped =
  result = newStmtList()
  for n in names:
    let key = newLit($n)
    result.add quote do:
      proc `n`(): string = settings[`key`]
getters colour, size
echo colour(), " ", size()
#> blue large

# %% A little language
# A macro can read a block written in a shape of your own and turn it into ordinary code. Here each line
# `name: value` of a block becomes a field of a tuple.
macro record(body: untyped): untyped =
  result = nnkTupleConstr.newTree()
  for line in body:
    line.expectKind nnkCall                  # (a line `x: 1` is parsed as a call of x with a block)
    result.add nnkExprColonExpr.newTree(line[0], line[1][0])
let book = record:
  title: "Nim in Action"
  pages: 300
echo book.title, " has ", book.pages, " pages"
#> Nim in Action has 300 pages

# %% Exercise: swap the arguments
# Write the macro `swapArgs`: given a call with two arguments, `f(a, b)`, it gives back `f(b, a)`. A call's node
# has the proc at [0] and the arguments at [1] and [2]; `copyNimTree` copies a tree. As it is, it gives back the
# call unchanged.
macro swapArgs(call: untyped): untyped =
  result = call
proc minus(a, b: int): int = a - b
echo swapArgs(minus(10, 3))
# Check:
if swapArgs(minus(10, 3)) == -7 and swapArgs(`&`("b", "a")) == "ab": echo "✓ swapArgs works"
else: echo "not yet: swapArgs(minus(10, 3)) gives ", swapArgs(minus(10, 3)), ", not -7"
# Answer:
  # macro swapArgs(call: untyped): untyped =
  #   result = copyNimTree(call)
  #   result[1] = call[2]
  #   result[2] = call[1]
  # proc minus(a, b: int): int = a - b
  # echo swapArgs(minus(10, 3))
