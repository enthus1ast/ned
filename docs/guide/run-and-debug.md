# Running, testing and debugging

How to run a program from ned, run its tests and step through it in the debugger — in Nim and in the other
languages ned knows. The keys are in [Key bindings](keys.md#run-test-debug); what is special to Nim is also in
[the Nim IDE](nim.md). In a folder you have not trusted yet nothing of the project runs: see
[Safety](safety.md).

## Running a file

**Alt+R** (or **F5** when the file has no breakpoints) saves your files and runs the current one; **Alt+B** builds
or checks it without running. The output goes to the **Output** panel, live; an error's `file:line` in it is a link,
and the errors are in **Problems** (Alt+N and Alt+P go through them). Running again stops the run before it.

What runs depends on the file:

| file | Alt+R | Alt+B |
|---|---|---|
| Nim | `nim c -r`, in the build mode of `nim.buildMode` (debug, release, danger) and with the backend of `nim.backend` | `nim c` |
| Rust | `cargo run` in the crate (`rustc` for a file on its own) | `cargo build` |
| C, C++ | the file compiled (`cc -Wall -O1`, `c++ -std=c++17`) and run | `make` or CMake when the project has one |
| Python | `python3` — the project's `.venv` or `venv` when there is one | |
| HTML | opens in your browser | |
| others | the language's usual command: `node`, `go run`, `java`, `bash`, `php`, `lua`, `ruby`, `dotnet run` … | |

The `run` setting changes the command per language — `{"python": "python3 -X dev $file"}`; `$file`, `$dir` and
`$name` are the file, its folder and its name without the extension. *Run: current file with arguments…* asks for
arguments; *Run in terminal (interactive)* runs the file in the integrated terminal, for a program that reads what
you type; *Run command…* runs any command with its output in the panel.

## Run configurations

A project often has more than one way to run: a server and a client, a debug and a release build, a program that
needs arguments. **Run › Configurations…** (or the ▶ menu in the title bar) lists them; the one you choose is what
Alt+R and F5 run from then on. *+ Add a configuration for this file…* asks for a name and the arguments, and saves
it in the project's `.ned/settings.json`:

```json
{
  "run.configs": [
    {"name": "server", "main": "src/app.nim", "args": "--port 8080", "env": {"DEBUG": "1"},
     "defines": ["ssl"], "mode": "release", "backend": "c", "cwd": "."},
    {"name": "docs", "command": "nimble docs"}
  ]
}
```

`main` is the file to build and run (with its `args`, `env`, `defines`, build `mode`, `backend` and working folder
`cwd`); `command` is any shell command instead.

## Tasks

**Shift+F4** lists everything the project can run: its Makefile's targets, `package.json`'s scripts, `just` recipes,
Taskfile tasks, cargo's and go's usual commands and the `.nimble` file's tasks — of the project folder and of the
current file's own sub-project. **F4** runs the last one again. *Nimble: tasks…* (Alt+Y) lists only nimble's. A task
runs in the Output panel, like a run.

## Tests

ned finds the tests in your files and puts a **▶** in the gutter beside each test, each suite and each
`when isMainModule` block; a click (or *Run tests in file*, *Run all tests*) runs them, and ✓ or ✗ appears beside
each one, with a failed check's message on its line.

| language | tests | run with |
|---|---|---|
| Nim | `std/unittest` (`suite`, `test`), testament spec files, `runnableExamples` | `nim c -r` (`nim.testFlags`), testament |
| Python | pytest | `pytest` (the project's `.venv` first) |
| Go | `func TestX(t *testing.T)` | `go test -run` |
| Rust | `#[test]` | `cargo test` |
| PHP | PHPUnit | `vendor/bin/phpunit` or `phpunit` |
| C# | `dotnet test` | `dotnet test` |
| Java, Kotlin | Gradle or Maven | `gradle test` / `mvn test` |

The **Test explorer** (the Tests dock) lists the project's tests by file, with the result of the last run; its ▶
runs them all, the right-click menu runs one file's tests, debugs one test or runs a file with coverage (`c` does
that too).

**Tests on save.** Saving a Nim test file runs it in the background — saving a module runs the test files that
import it — and puts ✓ or ✗ beside each test (`nim.testOnSave`: related, file or off).

**Coverage.** *Test coverage: run and colour the lines that ran* runs the tests and colours the line numbers: green
ran, red never ran. Nim (with gcc's gcov, or clang's own coverage on Termux and macOS), Python (coverage.py), Go,
Rust (cargo llvm-cov or tarpaulin) and JavaScript/TypeScript (Node's own); *Test coverage: load an lcov file* reads
any other tool's. *Test coverage: summary by file* gives each file's share and the total, and names the procs no
test reaches. For Nim the count is exact per Nim line — [the Nim IDE](nim.md) explains how.

**Tests from running a proc.** *Nim: write tests for this proc (from running it)* (the Nim menu) calls the proc at
the cursor with sample arguments — 0, 1, −1 and 42 for integers, empty and short strings, both ends of an enum, empty
and short seqs, a default object — and writes what each call returned as a `check`, and an exception it raised as
`expect`, into `tests/t<module>.nim` beside the `.nimble` file (made if it is missing, added to if not). The file is
opened and run with coverage. These tests keep the proc doing what it does now: read the values, since a wrong one is
a bug they would keep. A proc that is not exported is reached by `include`-ing its module (the test file says so). A
`var` parameter's value after the call is checked too; a result ned cannot write (a ref, a proc) is called and
discarded. A call that does not end within 20 seconds is left out.

The assistant can help too: *AI: write tests* keeps the tests it writes only when they compile and pass, and *AI:
make the failing test pass* keeps its change only when the test then passes — see [The AI assistant](ai.md).

## The debugger

**F9** sets a breakpoint on the line (or click the left edge of the gutter); with a breakpoint in the file, **F5**
builds the program for debugging and starts it. When it stops, the line is marked and the **Debug** panel shows:

- **VARIABLES** — the stopped procedure's variables and their values; Enter on ▸ opens an object's fields or a
  sequence's items. While stopped, the values a line uses are also shown at its end (`debug.inlineValues`), and the
  hover on a name gives its value.
- **WATCH** — expressions you add (*+ add a watch expression*), worked out again at each stop.
- **STOP WHEN IT CHANGES** — watchpoints: the program stops when a variable's value changes (*Debug: stop when this
  changes…*).
- **CALL STACK** — how it got there; Enter goes to a frame (the C runtime's frames are hidden).
- **OUTPUT** — what the program writes.

| key | |
|---|---|
| F5 | continue |
| F10 · F11 · Shift+F11 | step over · into · out |
| Ctrl+F10 | run to the cursor (starts debugging when it is not running) |
| Shift+F5 | stop |

*Debug: conditional breakpoint on this line…* stops only when a condition holds; *Debug: logpoint on this line…*
prints a message (with `{expressions}`) and goes on without stopping. Alt+Enter on a test, or *Debug: debug the test
at the cursor*, debugs just that test. Breakpoints are kept with the folder's session.

**Which debugger.** Nim uses **gdb** (or lldb) through its machine interface: F5 builds with `--debugger:native`,
and Nim's own gdb pretty printer (`nim-gdb.py` of the Nim you build with) shows strings, seqs and tables as values.
The other languages use a **Debug Adapter Protocol** debugger, as VS Code does: Python — debugpy, C, C++ and Rust —
`gdb -i dap` or lldb-dap, Go — delve, JavaScript and TypeScript — js-debug. *Debug: check the debugger for this
file* says which one F5 will use and whether it is installed; *Debug: install the debugger for this language…*
installs it in the terminal; *Debug: choose the debugger for this language…* picks another. Your own goes in
`debug.adapters`:

```json
{"debug.adapters": {"python": {"command": ["python3", "-m", "debugpy.adapter"],
                               "launch": {"program": "$file", "cwd": "$dir"}}}}
```

— with `"build"` for a command to run first, `"connect": true` (and `$port`) for an adapter reached over TCP, and
`"request": "attach"` to attach to a running program.

*Nim: debug with gdb* is the other way: the program built with debug information and gdb started on it in the
integrated terminal, to type gdb's own commands. On macOS gdb must be code-signed first, else lldb is used.

## The REPL

**Shift+Enter** sends the selection — or the statement at the cursor — to the language's REPL in the terminal panel:
inim (or `nim secret`) for Nim, the project's Python (or ipython), node, tsx, irb, lua. *REPL: send the cell*
sends a `# %%` cell (a ▶ appears beside each one), *REPL: send the proc / function at the cursor* and *REPL: send the
whole file* the rest. `repl.commands` chooses another REPL per language. In Nim, *Nim: run the selection*
(Alt+Enter with code selected) compiles just that code, with the file's imports, and shows what it prints.

## Notebooks

A Nim or Python file with `# %%` lines is a notebook: each `# %%` starts a cell, and running a cell shows its output
under it, in the editor, as **Out [n] · 12 ms** and the lines it printed. The file stays an ordinary file — the
outputs are not saved in it.

- **Ctrl+Enter** runs the cell at the cursor; **▶ run** on a cell's `# %%` line (and the ▶ in the gutter) does it with
  a tap. Once the notebook runs, **Shift+Enter** runs the cell and goes to the next one.
- The cells run in one session, so a cell sees what the cells run before it made — as in Jupyter. *Notebook: run all
  the cells*, *run the cells above and this one*, *clear the outputs* and *restart the session* (its variables
  forgotten) are in Run › Notebook.
- A cell changed since it ran says so, and its output is dimmed. An error is shown under its cell in red and goes to
  Problems on its line.
- A long output shows its first `notebook.outputLines` lines (30); *Notebook: the cell's whole output* opens all of
  it in a tab. A cell that runs longer than `notebook.timeoutSeconds` (120) is stopped.
- Nim cells run in Nim's VM (`nim secret`), which starts at once but has no C libraries: a cell that needs them (FFI,
  `importc`) says so — `notebook.nim` set to `compiled` runs each cell as a compiled program instead (the cells
  before it with it, slower but everything works). Python cells run in `python3`, and a cell's last expression is
  shown as Python's prompt would show it.

## Memory checks

*Run with memory checks* (the Run menu) builds the Nim, C or C++ program with the compiler's address and
undefined-behaviour checks (AddressSanitizer and UBSan, with gcc or clang) and runs it. What they find goes to
Problems on the line where it happened — a write or read past the end of a block, a use after `free`, a block freed
twice, a signed overflow, a shift too far, memory never freed when the program ends — with where the block was made
and freed. The program goes on after the first problem, so one run finds them all. A compiler that cannot build with
the address checks gets the undefined-behaviour ones alone; one with neither runs the program under valgrind, if it is
installed. Memory never freed is found on Linux, not on Android or macOS on ARM (the checks have no leak finder
there). For Nim the program is built with `-d:useMalloc`, so the checks see each block.

## Finding where the time goes

- *Nim: profile* builds the program with ned's line profiler and runs it: the procs that took the most time are
  listed in the panel, and each line's share of the time is shown beside it (*Nim: hide the profile*).
- *Nim: flame graph of the profile* draws the call stacks the profiler saw: each box a proc, as wide as the share of
  the time it and what it called took, the procs it called below it. Your procs are in warm colours, the libraries'
  in cool ones. A tap on a box (or Enter) looks inside it, the bar at the top (or Backspace) goes back out, and the
  line at the bottom names the box under the pointer.
- *Nim: compare with the previous profile* puts the last two profiles side by side — each proc's share of the time
  before and after, and the change — so you can see what a change to the code did.
- *Nim: benchmark a call…* times any expression in a release build: seven rounds of many calls, and the time per
  call — the median, the fastest and the slowest.
- [Compiler Explorer](compiler-explorer.md) shows the machine code a proc compiles to, and
  [the decompiler](hex-and-binaries.md#the-decompiler) a proc of the built program.
