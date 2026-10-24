# Compiler Explorer

Compiler Explorer shows the machine code your program compiles to, beside the source, while you write it — the
way [godbolt.org](https://godbolt.org) does, but inside ned, on your own compiler, offline, on Linux, macOS and
Termux. It works for Nim (through the C Nim generates), C and C++.

```
┌ ce.nim ─────────────────────────────┐┌ ⚙  -d:release ✎ │ gcc 13.3.0 ▾ │ x86-64 ▾ │ Filters ▾ │ asm ▾ │ ▶ run │ ⇄ ┐
│ proc square(num: int): int =        ││ ; nim 2.2.12 · gcc 13.3.0 · x86-64 · -d:release · Intel · asm               │
│   num * num                         ││ ; compiled in 0.41 s · 120 lines (8925 filtered)                             │
│                                     ││                                                                              │
│ echo square(6)                      ││ square:                                                                      │
│                                     ││         endbr64                                                              │
│                                     ││         imul    rdi, rdi                                                     │
│                                     ││         jo      .L8                                                          │
│                                     ││         mov     rax, rdi                                                     │
│                                     ││         ret                                                                  │
```

## Opening it

Open a `.nim`, `.c` or `.cpp` file and choose **Compiler Explorer** — from the **Run** menu, **Nim › Inspect**, the
editor's right-click menu, or the palette (*Compiler Explorer*). The assembly opens in the pane beside the file and
your file keeps the focus. That is all the setting up there is: ned builds with the debug line information it needs
(`--debugger:native` for Nim, `-g` for C), in a private copy of your project, with its own cache — your build, your
settings and your files are not touched.

What it needs: `nim` on the PATH (for Nim files) and a C compiler — gcc or clang (Termux: `pkg install clang`). The
binary output needs `objdump` (Termux: `pkg install binutils`); another processor needs `zig`. If one is missing,
ned says which and how to install it.

## How it behaves

- **Live.** About half a second after you stop typing (`compilerExplorer.delay`), the file is compiled again — the
  text in the editor, saved or not. A first build takes a few seconds; after that a small file takes well under a
  second (Nim writes only the C that changed, the C compiler compiles only your module).
- **Colours.** Each source line and the instructions it produced share a background colour. The line under the
  cursor — or under the mouse, on either side — is lit up brighter on both sides, and the other side scrolls to
  show it. Moving through the assembly lights up the Nim (or C) line it came from.
- **Filters**, on by default as on the website: assembler directives, labels nothing jumps to, the compiler's
  comments and the functions of other files (Nim's runtime, the standard library) are left out, and Nim's mangled
  names are written as in Nim (`square__ce_u3` → `square`, `dollar___systemZdollars_u14` → `` `$` ``). The second
  line says how many lines were left out.
- **Hover** (Alt+H, or rest the cursor) on an instruction says what it does — `imul`: *Signed multiply (sets
  OF/CF on overflow — Nim's overflow checks test them with jo)* — and on a register what it is for (`rdi`: *the
  first argument*). x86-64 and ARM64.
- **F12** (or Ctrl+click) on a label or a called function goes to it: in the assembly, or to its declaration in
  your file.
- **Errors**: when the file does not compile, the view says `<Compilation failed>` with the compiler's messages.
- **Every proc of the file** is in the output, also the ones nothing calls yet — a library module shows all of
  its procs, each overload of an operator too. Nim itself leaves out what nothing calls (on godbolt.org you mark a
  proc `{.exportc.}` for that): ned adds, to its private copy only, one line that names each of the file's procs.
  A generic proc still needs a call (it has no code until it is used with a type). *Filters ▾ › Every proc of the
  file* (`compilerExplorer.allProcs`) turns it off: then only what the program uses is there.

## The toolbar

The bar over the assembly holds the settings that matter most; *⚙* opens all of them in one form (so does Enter on
the view's first line, or *Compiler Explorer: options…*).

| control | what it sets | setting |
|---|---|---|
| `-d:release ✎` | the Nim compiler's options: empty is a debug build (with Nim's stack-trace bookkeeping, `nimFrame`); `-d:release`, `-d:danger` (no runtime checks), `--mm:arc`, `--opt:size` … For C and C++ files: the C compiler's (`-O2`) | `compilerExplorer.options`, `compilerExplorer.cOptions` |
| `gcc 13.3.0 ▾` | the C compiler: auto, gcc, clang, zig cc | `compilerExplorer.compiler` |
| `x86-64 ▾` | the processor: native, x86-64, ARM64, RISC-V 64, x86 32-bit — another one than yours is built with zig cc | `compilerExplorer.target` |
| `Filters ▾` | unused labels, library functions, directives, comments, demangling, every proc of the file | `compilerExplorer.filter…`, `compilerExplorer.demangle`, `compilerExplorer.allProcs` |
| `asm ▾` | the compiler's assembly, or the object file disassembled with objdump (with addresses, and each call's target filled in from the relocations) | `compilerExplorer.output` |
| `Intel ▾` | x86 syntax: Intel (`mov rax, rdi`) or AT&T (`movq %rdi, %rax`) | `compilerExplorer.syntax` |
| `▶ run` | build and run the program after each compile: *Program returned: 0* and its output in the Output panel; its arguments in `compilerExplorer.args` | `compilerExplorer.execute` |
| `⇄` | compare: the assembly with other options beside this one, in the diff view | — |

On a narrow screen the toolbar shows what fits; the form always has everything.

## Comparing two builds

*⇄* (or *Compiler Explorer: compare with other options…*) asks for the other options — it proposes the next step:
debug → `-d:release` → `-d:danger` — compiles both, and opens the two listings side by side in the diff view, so you
see exactly what a flag changes: the overflow checks that `-d:danger` removes, what `--opt:size` does to a loop.

## Other processors

With [zig](https://ziglang.org) installed, the target can be another processor: ned compiles through `zig cc` for
`aarch64-linux-musl`, `x86_64-linux-musl`, `riscv64-linux-musl` or `x86-linux-musl` — ARM64 code on a PC, x86 code on
a phone. Such a program is not run (`▶ run` says so); the binary output uses `llvm-objdump` when it is installed.

## Settings

| setting | default | what it does |
|---|---|---|
| `compilerExplorer.options` | `""` | the Nim compiler's options (empty: a debug build) |
| `compilerExplorer.cOptions` | `"-O2"` | the C compiler's options for a C or C++ file |
| `compilerExplorer.compiler` | `"auto"` | gcc, clang or zig — auto: gcc (clang on Termux and macOS), else whichever is installed |
| `compilerExplorer.target` | `"native"` | native, x86_64, arm64, riscv64, i386 |
| `compilerExplorer.syntax` | `"intel"` | intel or att (x86) |
| `compilerExplorer.output` | `"asm"` | asm, or binary (objdump) |
| `compilerExplorer.filterLabels` | `true` | leave out labels nothing jumps to |
| `compilerExplorer.filterLibrary` | `true` | leave out the functions of other files |
| `compilerExplorer.filterDirectives` | `true` | leave out directives (the data a used label holds stays) |
| `compilerExplorer.filterComments` | `true` | leave out the compiler's comments |
| `compilerExplorer.demangle` | `true` | Nim's names as Nim writes them |
| `compilerExplorer.allProcs` | `true` | every proc of a Nim file, also the ones nothing calls yet (not the generic ones) |
| `compilerExplorer.execute` | `false` | run the program after each compile |
| `compilerExplorer.args` | `""` | the program's arguments |
| `compilerExplorer.delay` | `600` | ms after the last key before it compiles again |

## How it works

For a Nim file, ned writes the editor's text into a private copy of the project — a folder in ned's private temp
folder that links to everything else in your project, so imports, includes, `nim.cfg` and `config.nims` are found —
and runs `nim c --compileOnly --debugger:native` with your options into a cache of its own. Nim writes the C
compiler's command for each module into the cache's `.json`; ned runs the one for your module with `-S` (assembly)
instead of `-c`. `--debugger:native` makes Nim write `#line` directives into the C, so the C compiler's `.loc`
directives name the Nim file and line of every instruction — that is how each instruction gets its colour. The
assembly is then read and filtered as godbolt.org does. For C and C++ the C compiler is run on the copy directly.
The binary output compiles with `-c` and reads `objdump -d -r -l`: `-l` gives the source lines, `-r` the call
targets.

*Decompile this proc* (Nim › Inspect) is the other view of machine code: the whole program built and one proc
disassembled — or decompiled to C with radare2's r2ghidra — following the cursor.
