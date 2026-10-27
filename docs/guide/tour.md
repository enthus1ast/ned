# The Nim tour

The Nim tour teaches Nim inside ned, by running it. It has sixteen short lessons, from the first `echo` to calling C.
Each lesson is a [notebook](run-and-debug.md#notebooks): a Nim file cut into cells. You run a cell and read what it
printed under it, change the code and run it again. Every lesson ends with an exercise that checks your answer.

The lessons are built into ned, so you need no files and no network to take the tour. To run the cells you need Nim
(`nim` on the PATH) and a C compiler: gcc or clang (on Termux: `pkg install nim clang`). *Help › Check setup* says
whether they are there.

## Starting

Choose **Help › Nim tour › Start or go on**, or *Nim: tour (lessons in the notebook)* in the palette (Ctrl+E). The
first time, the first lesson opens. After that, the tour opens the lesson you were at.

| command | what it does |
|---|---|
| *Nim: tour (lessons in the notebook)* | opens the lesson you were at (the first one, the first time) |
| *Nim: tour — next lesson* | opens the next lesson |
| *Nim: tour — previous lesson* | opens the lesson before the one in front |
| *Nim: tour — all the lessons…* | lists the lessons, with a ✓ beside each one you finished, and opens the one you choose |
| *Nim: tour — reset this lesson* | brings the lesson in front back as it was, after asking |

They are all in *Help › Nim tour*.

## A lesson

A lesson starts with a few lines about its subject. After that come the cells. Each cell starts with a line
`# %% Title` and has comments that explain one idea, the code that shows it, and lines that start with `#>`. The `#>`
lines show what the cell prints.

- **Ctrl+Enter** runs the cell at the cursor. You can also tap **▶ run** on its `# %%` line. **Shift+Enter** runs the
  cell and moves to the next one.
- What the cell printed is shown under it. A compile error is shown under its cell in red, and its line is marked.
- Each run builds the lesson as one program, from the first cell to the one you run, and runs it. The line
  `# notebook: compiled` at the top of every lesson asks for this. It takes a second or two, but anything Nim can do
  works, including async, destructors and C libraries.
- A cell can use what the cells above it declare. A name can be declared only once in a lesson, as in any Nim module.

Change whatever you like and run it again: trying things out is the point. The lesson is your own copy (see
[Your copies and your progress](#your-copies-and-your-progress)). To start a lesson again from the beginning, use
*Nim: tour — reset this lesson*. Ctrl+Z brings your version back.

## The exercises

The last cell of every lesson is an exercise. Its comments say what to write. Below them is code that does not
work yet, then a line `# Check:` and the code that checks your answer. Change the code above `# Check:` and run the
cell:

- **✓** and a few words: your answer works. The lesson counts as done: ned shows a toast with **Next lesson**, and
  the list of lessons shows a ✓ beside it.
- **not yet** and what the check found: try again.

An answer is folded away under the line `# Answer:`. To read it, put the cursor on that line and press **Alt+=**,
or click the ▸ beside it.

## The lessons

| | lesson | what it covers |
|---|---|---|
| 1 | Hello, Nim | `echo`, `let`, joining strings, comments, what a compile error looks like |
| 2 | Values and types | `let`, `var` and `const`, the basic types, arithmetic, conversions, strings and characters, integer sizes |
| 3 | Choices and loops | `if`, `case`, `while`, `for` and ranges, `break`, `continue` and named blocks |
| 4 | Procedures | parameters and results, defaults and named arguments, method call syntax, overloading, `var` parameters, `func`, procs as values |
| 5 | Arrays, sequences and tuples | arrays, seqs, slices, copies, tuples, `openArray`, sets |
| 6 | Iterators | writing iterators, yielding tuples, changing items in place, `toSeq` and `collect`, closure iterators |
| 7 | Types of your own | enums, objects, procs for a type, distinct types, ranges, objects with variants |
| 8 | References and inheritance | `ref` against values, `nil`, linked lists and trees, inheritance and methods, `of` |
| 9 | Generics | generic procs and types, constraints, `when` on a type, `typedesc` |
| 10 | When things go wrong | exceptions, raising your own, `finally` and `defer`, `{.raises.}`, `Option`, defects |
| 11 | Templates and compile time | templates, arguments pasted in place, `{.inject.}`, `const` and `static`, `when` and `defined` |
| 12 | Macros | the syntax tree, `quote do`, building calls and procs, a small language of your own |
| 13 | Async | `async` and `await`, running tasks at once, futures with values, errors, a web server |
| 14 | The standard library | strutils, strformat, sequtils, algorithm, tables, sets, math, times, json, os |
| 15 | Memory: ARC, ORC, sink and lent | destructors, copies and moves, `sink` and `lent`, counted refs, cycles |
| 16 | Calling C | `importc` and headers, varargs, `emit`, C structs, callbacks with `qsort`, `exportc` |

The lessons point you to the parts of ned that go with them. *Nim › Expand macro* shows what a template or a macro
call becomes. *Nim › Inspect* shows what a proc can raise, and the copies and destructor calls ARC puts in. *Nim ›
C interop* wraps a C header for you.

## Your copies and your progress

A lesson opens as a file of your own in ned's state folder: `~/.local/state/ned/tour/` (or `$XDG_STATE_HOME/ned/tour/`).
What you change stays there. Save it with Ctrl+S, as any file. The same folder holds `progress.json`, which records
the lesson you were at and the lessons you finished.

A newer ned may come with a newer version of a lesson. If you have not changed your copy, ned replaces it with the
new version when you open it. If you have changed it, ned keeps your copy and says that a newer version is there.
*Nim: tour — reset this lesson* brings in the newer version, and your changes go.

To take the tour again from the start, delete the folder `~/.local/state/ned/tour/`.

## For people who change the tour

The lessons are the files `tour/lesson01_hello.nim` … in ned's source. `src/ned/editor/tourlessons.nim` reads them
into ned when it is built, and `src/ned/editor/tour.nim` has the commands. A change to a lesson shows in ned after
the next build. `python3 tests/tour/check.py` runs every cell of every lesson as the notebook runs it. It checks
that each cell prints what its `#>` lines say, that each exercise says "not yet" as it is given and ✓ with its
answer, and that `nim check` accepts the whole lesson. `nim r tests/unit/ttour.nim` checks what ned reads from the
lessons.
