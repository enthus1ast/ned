# ned changelog

The newest release is described in the [README](README.md#whats-new-in-643). Older releases:

## What's new in 6.42.1

**The assistant with llama.cpp and other strict servers.** A search result cut in the middle of a character, or a
line of a file in another encoding (Latin-1, Windows-1252), put bytes into the request that are not UTF-8, and
llama.cpp refused all of it (*HTTP 500 … ill-formed UTF-8 byte*). What ned sends is now always UTF-8: text is cut
between characters, and a byte of another encoding goes as �. And a tool call a local model wrote with a literal tab
or newline inside a string, which ned runs as meant, now goes back with the conversation as strict JSON, which
llama.cpp also refused.

**A quicker start after ned was stopped.** What earlier copies of ned left behind when they were killed (by Android,
say) is now cleared a little at a time once ned is on the screen, not all at once before it.

## What's new in 6.42

**Your own keys in vim and Helix mode.** `vim.keys`, `vim.visualKeys` and `helix.keys` put any command of the
palette, or a `:` line, on keys of your own, written as vim writes them:

```json
"vim.keys": {"<leader>n": "Next tab", "<leader>p": "Previous tab", "<leader>x": "Close tab", "<leader>w": ":w"},
"helix.keys": {"<space>n": "Next tab", "<space>x": "Close tab"}
```

They come before ned's own use of the keys and before a plugin's, a count before them repeats the command
(`3<leader>n`), and the which-key plugin lists them. See [Your own keys](docs/guide/vim-and-zen.md#your-own-keys).

**jj as Esc in Helix mode too.** `vim.escapeSequence` (`"jj"`, `"jk"` …) now leaves Helix's insert mode as well. In
both modes it also works while the completion list is open, which the sequence's first key often opens.

**Next tab and Previous tab** are commands of the palette, so the `keys` setting, your vim and Helix keys and
plugins can use them (`{"alt+n": "Next tab"}`).

**The one-line installer works on Linux and macOS again.** Outside Termux it stopped at once with `PREFIX:
parameter not set`.

## What's new in 6.41.1

- **A struct's members in C inside an `{.emit}`.** After `.` and `->`, completion lists the members of a struct or a
  union, and the hover of a member shows it, from ned's own C engine — no clangd needed, as in a `.c` file.
- **Ctrl+P puts the file you name first.** Typing a file's whole name (`demo.nim`) opens that file, not a longer name
  that starts with it (`demo.nimble`).
- **Nim 2.4's names.** Nim 2.4 writes a proc's name into the C differently (`shout_u0__app`, where Nim 2.2 wrote
  `shout__app_u1`): Compiler Explorer, the view of a program Nim built, the debugger's stop when a global changes and
  the memory checks' stacks read both, and show Nim's names again.
- **The debugger with Nim 2.4.** Nim 2.4 writes a line's C over several lines, and the C compiler took the later
  ones for the Nim lines below: a breakpoint stopped before the line's variables were set, a step went to a line that
  had not run, and Compiler Explorer's shading and the memory checks' stacks were a few lines out. ned now builds for
  the debugger, the program view, Compiler Explorer and the memory checks with every line of that C under its own
  Nim line, as with Nim 2.2 — and C in an `{.emit}` keeps its own lines, so a breakpoint there stops on the line it
  is on (a top-level emit's was one line off with Nim 2.2 too).
- **Benchmark a call and runnableExamples with Nim 2.4.0.** Both build a program read from ned, which Nim 2.4.0's new
  separate code generator could not find; they work again.
- **Nim 2.4's answers, as ned's own.** A type hint shows an array by its length (`array[2, Person]`, not
  `array[0..1, Person]`), and Go to definition on a name a template made goes to the line that calls the template.
- **Compiler Explorer on macOS shows the code.** clang there puts it in a section ned left out, so the view was empty.
- **For contributors.** GitHub's tests pass with Nim 2.4 — the version it installs: a few checks no longer depend on
  what the machine has installed, its SSH server starts on a fresh machine, and macOS has its own speed limits.

## What's new in 6.41

**Every ray.so theme, and mint-night.** All of [ray.so](https://ray.so)'s themes are in, dark and light, each named
with `ray-` before it: `ray-vercel-dark`, `ray-candy-light`, `ray-midnight` (the dark one of a pair) … 65 in all.
`mint-night` is near black, with mint keywords and types, lavender function names and light blue strings. ned now
has 150 themes ([Themes](docs/guide/themes.md#the-built-in-themes)).

**Vim: the `:` line reaches everything.** Every command by its name, or by enough of its start (`:about`), and every
setting with `:set` — by its key (`:set editor.tabSize=2`), only its last part (`:set tabSize?`), or Vim's own name
(`tabstop`, `colorcolumn=80`, `ignorecase`, `nowrap`); `:colorscheme NAME`. **Tab** completes command names,
settings and their values, themes, files and tabs. New line commands with ranges: `:sort` (`! i n u`), `:g/text/d`,
`:v/text/d`, `:m`, `:t`, `:d`, `:y`, `:j`, `:>`, `:<`; and `:tabnew`, `:ls`, `:b`, `:cn`, `:cp`, `:r`, `:sav`,
`:help` ([Vim](docs/guide/vim-and-zen.md#vim)).

**ned says when a newer version is out.** Once a day, a little after it starts, ned looks on GitHub; when there is a
newer version, a note says so and a mark in the status bar opens what is new in it. *Help › Check for updates* looks
now; `"update.check": false` stops the daily look. `ned --update` and `install.sh` build the new version with nimble
(on Termux too); GitHub's checks build ned on every platform, and publish nothing.

**Ideas from Zed's own changelog.** A jump into a folded part — go to line, a definition, a symbol, a problem, a
picked result, back and forward — opens it. Selected text put in the find box is found as it is written, also when
the find is by regular expression. Two cursors in one word change it once. Vim: `:set gdefault`.

**nedls in Zed's extensions.** The Zed extension is ready for Zed's list, in a repository of its own
([nedls-zed](https://github.com/foxoman/nedls-zed)) and named `nedls-language-server` as Zed asks
([editors/zed](editors/zed/README.md)).

**Faster.** Typing in a very long line — a minified JSON or JavaScript file — is about four times faster, and
colouring code about 15% faster.

**For contributors.** [docs/dev/source-map.md](docs/dev/source-map.md) lists every source file, folder by folder,
with what it is; files describe themselves more clearly at the top, and code nothing used is gone. Every screenshot is
drawn in one font from its capture, and `tests/shots` takes them again
([Screenshots](docs/dev/testing.md#screenshots)).

**Announcing ned.** [The announcement post](docs/blog/announcing-ned.md): what ned is, and how to start.

## What's new in 6.40

**A clean start.** ned opens with no dock and no panel, and the keys go to the editor or the welcome screen. A dock
that is not on the screen no longer takes keys: a file tree left open last time could take the welcome screen's `d`
(*Open folder*) as *Delete* for the file selected in it. Turn on `ui.restorePanels` to get the docks and the panel
back as you left them; `ui.restoreLayout` still restores your split panes.

**Memory no longer grows with large files opened again and again.** The undo history saved for a file's next
opening gained a branch on every visit and was read back in full each time. It now shares one 4 MB budget across
all files, keeping the steps nearest the current text, so undo still works after a file is reopened. No build flag
is needed for this: `-d:useMalloc` is not required, and the Termux build keeps Nim's own memory allocator.

**About ned** and `ned --help` show the author, the website and a contact address.

## What's new in 6.39

**Eighteen more themes.** Each from its author's own colours: Gruvbox Material (dark and light), Material Palenight,
Nightfox, Carbonfox and Dawnfox, Oxocarbon, Poimandres, Synthwave '84, Cobalt2, Horizon, Vesper, Flexoki (dark and
light), Zenburn, Melange (dark and light) and Monokai Pro, 84 in all. The short names other editors use work too:
`"theme": "gruvbox-material"`, `"flexoki"`, `"melange"`, `"synthwave"`, `"palenight"`.

**Twelve more of ned's own plugins.** Off until turned on in the Plugins dock; 85 in all.

- **notify-done**: a note when a long run, build or test ends (✓ done in 42 s, ✗ failed after 3 min); on a phone, a
  Termux:API notification that buzzes on failure; notify-send on Linux.
- **read-aloud**: the selection, the line or the file read aloud (Termux:API, espeak-ng, spd-say or say).
- **blame-heat**: lines tinted by when they last changed: today red, this week orange, this month blue.
- **todo-to-issue**: the TODO on the cursor's line made a GitHub issue (gh), with `TODO(#42):` written back.
- **log-tail**: a log followed as it grows, errors red, warnings yellow; the lines with chosen words in a tab.
- **inline-calc**: select `12*(3+4)` to get 84, or end a line with `=` for its result.
- **license-audit**: every dependency's version and licence in one table, the ones to look at marked.
- **typing-stats**: words a minute and the days in a row of writing, in the status bar.
- **code-pet**: a pet in the status bar that eats on save, grows with commits and naps when typing stops.
- **rubber-duck**: the routine talked through a line at a time, the duck asking the questions.
- **power-mode**: a combo count, sparks after the line being typed, a cheer at 50.
- **nim-tips**: a Nim tip a day when ned starts.

**For plugins: `onJobDone`.** A plugin is told when a run, build or test ends, with its exit code and how long it
took.

## What's new in 6.38

**The Nim panel in parts.** Project, Code intelligence, Build & run, Nimble, Dependencies, Nim tools, Atlas, Nim 3, C
· clangd and Toolchain. A tap on a part's title folds or opens it; the folds are kept with the session.

**clangd status.** The panel's C · clangd part shows whether clangd is installed and which version, how many are
running, any that stopped with an error (a tap restarts it) and what answers for the current file, and writes
`compile_commands.json`. The status bar shows it for a Nim file with C in `{.emit}`, and for a C file when clangd is
missing or stopped: *C · clangd*, *C · clangd …* while it starts, *C · clangd ✗* when it stopped, *C · ned* when ned's
own C engine answers.

**Undo history with a limit.** Each file keeps at most 64 MB of undo history (8 MB when memory is short,
`ui.lowMemory`) instead of 2000 steps of any size, so repeated *Replace all* over a large file no longer makes ned
grow without end. The oldest steps go first, and the undo tree's oldest branches before them.

**Themes.** Every colour of code now has a contrast of at least 3:1 with its background. Ayu Light, Everforest Light,
Catppuccin Latte, Solarized Light, Rosé Pine Dawn, Kanagawa Lotus and Light Owl keep their hues, a little darker, so
strings, functions and warnings stay readable in daylight. New: `ayu-dark`.

**Settings reference.** `ned --doc-settings` also reports a setting declared twice, a default that is none of its
values, or a description too short to act on.

**Fixes.** A plugin's `filetype` now reaches the files already open when the plugins start, such as a session's files,
unless the file's own lines or its .editorconfig say otherwise.

## What's new in 6.37

**Lighter on a phone.** Android closes Termux, and ned with it, when it runs out of memory.

- **No more than two checks at once.** The compiler's checks (on save, while typing, a test on save) run two at a
  time, so a *Save all* or quick switching between files no longer starts a compiler for each.
- **Short of memory** (`ui.lowMemory`, 300 MB). With less than that free, ned drops what it keeps to answer faster (in
  its engine worker too), runs checks one at a time and on save only, and reads nothing ahead. *mem low* in the status
  bar shows it until twice that is free again.
- **One copy of a program's names.** A file that a module includes no longer keeps its own copy of everything the
  module sees.
- **One budget.** `nim.indexMemory` now bounds everything the engine keeps, not only the files it read.

**Nim 3 while typing.** nimony's check of the unsaved text now gives its reading too, as `nim nif -` does for Nim 2.4:
hover has the compiler's type, F12 goes where the compiler says, and the colours follow it, before any save.

**Smaller things.** Cursor places are remembered for the recent files only.

## What's new in 6.36

**One check of a module at a time.** A *Save all* of several files of one program no longer starts a compiler of the
whole program for each of them at once, which on a phone was enough for Android to close Termux. A module has one
check running; when it ends, it runs once more for the files saved meanwhile.

**The compiler's reading while typing (Nim 2.4 and newer).** The check after a pause in typing is now `nim nif -` in
place of `nim check -`: the same messages, as fast, with the compiler's reading of the unsaved text. Before any save,
names are coloured by what the compiler says they are, hover has the type it gave each let and var (on a declaration
such as `let fresh = …` too), F12 goes to the overload it chose, and Alt+M shows what a macro call made. A changed
line keeps the engine's answers until the next check.

**Less memory over a long session.** ned and its engine worker level off instead of climbing. The unused names the
compiler found in another project's files go when a different project is opened, and the list of each file's includes
has a limit.

**Fixes.** Go to definition follows `import "."/[ast, msgs]`, a quoted folder before the modules, as Nim's own
compiler writes its imports.

**The showcase.** `examples/showcase.nim` has a section on the compiler's reading;
[docs/blog/announcing-ned.md](docs/blog/announcing-ned.md) says what ned does with Nim 2.4.

## What's new in 6.35

**Installing nimony no longer closes Termux.** *Nim 3: install or update nimony* ran Nimony's `hastur build all`,
which starts about a dozen compilers at once. Now each part is built in turn at a low priority, the C compiler two at
a time, with the step in the status bar (*building nimony 4 of 10: nimony*); with less than about 1.5 GB free ned asks
first. A new nimony that cannot build a small program is never used. The build is a job of its own, so Alt+R or a test
no longer stops it.

**More from the compiler's reading (Nim 2.4 and newer).** On a saved project the compiler has read (`nim nif`):

- **Find references** of the declaration the compiler chose (of `show(2.5)`, only the `show` that takes a float)
  across the project's files; the list says *(compiler)*.
- **Hover** with the type the compiler gave a let or var (*the compiler's type: `Table[string, seq[int]]`*).
- **Alt+M** on a macro call shows what it made at once, without running the compiler again.
- No nimsuggest in the background for the types the engine cannot work out: on a phone, a process fewer.

The on-save check with `nim nif` reports every error, not only the first; colours and type hints appear as soon as it
ends; in `"a".replace("b", "x").replace('c', 'y')`, F12 on each `replace` goes to its own overload.

**The engine.** A module that offered nothing when first read (`import util` written before `util.nim` has its first
`proc …*`) shows its new names without reopening the folder. In a generic routine T is one type for all the arguments,
so `elems.add cur` goes to the right `add`. A C file's checks lost when the engine worker stopped are asked for again.
The Nim library's files are looked at once a session, not every second.

**Install with nimble.** `nimble install https://github.com/foxoman/ned` builds ned, nedfmt and nedls into
`~/.nimble/bin`; [docs/blog/announcing-ned.md](docs/blog/announcing-ned.md) says what ned is and the ways to install
it.

## What's new in 6.34

Nim 2.4's own reading of the code, and a lighter screen.

**The compiler's answers on a saved file (Nim 2.4 and newer).** The check on save is now `nim nif` in place of
`nim check`: the same messages in about the same time, and what the compiler made of each module without errors, kept
in `~/.cache/ned/nif`. A saved file then gets its names coloured by what each one is (names a macro made among them),
the types of lets and vars where the engine had none or another (`let a: int = answer()`), and Go to definition of the
declaration the compiler chose. A Nim 3 project gets the same from nimony. After an edit the engine's answers are back
until the next save. An older Nim is checked with `nim check` as before; `nim.compilerNif` off does that with 2.4 too.

**Which Nim, at a tap.** A tap on `✓ Nim` in the status bar says which Nim the project is and why (*Nim 3 (nimony):
~/proj/nimony.paths is here*, *Nim 2.4.0 (PATH)*) and offers the rest: make it Nim 3 or Nim 2, decide from the
project, install or update nimony, choose the Nim.

**Less to draw on a phone.** A run of blank cells is erased in its colour rather than sent as spaces, so a jump or a
scroll sends less to the terminal. On a narrow screen a menu item's keys no longer run over its label and the menu's
frame, and long setting names end in `…`.

**Fixes.** The engine sees an import in a one-line `when` branch (`else: import std/os`) and the values of an enum
type a module re-exports by name (`pcFile`).

**For contributors.** Every file and routine of ned's source, plugins and tests has a comment saying what it does.

## What's new in 6.33

Nim 2.4 and Nim 3 side by side, and an engine that holds less.

**Nim 2.4.** Sum types: in an `object` whose `case` has no field, each branch's name is a constructor, so completion,
hover and Go to definition know `Leaf(3)` makes a `Node`, and `of Pair(a, b):` gives `a` and `b` the branch's field
types. The new operator characters `⟑ ⟇ ⩓ ⩔ ■ □ ☆` are operators for the formatter and the engine, and
`import b {.cyclic.}` is an import like any other. A message about code given on standard input (`--stdinfile`) names
the file. The library names Nim 2.4 added are known for `nim.minVersion`.

**Nim 2 or Nim 3, decided by the project.** `nim.compiler` is now `auto`: a project with `nimony.args`, `nimony.paths`
or `pnak.nif` (in its folder or up to three above) is Nim 3 when nimony is installed, any other is Nim 2. The status
bar says which; `nim` and `nimony` still decide outright. **Nim 3: install or update nimony** clones Nimony into
`~/.local/nimony` (or brings it up to date) and builds it in the Run panel; ned finds it there with nothing added to
PATH. Once nimony has checked a saved file, each name has the colour of what nimony says it is, names a macro or
template made among them.

**Less memory, fewer waits.**

- Files that import the same module share one list of the names it brings. ned keeps what 96 files see (it was 48), in
  less memory than before.
- A file's problems are put together once after each change, not several times each frame, which slowed every key with
  thousands of problems.
- Whether a file changed on disk is asked at most once a second, and the git folder a file is in is remembered.
- What the C compiler predefines (`cc -dM -E`) is kept on disk, so the first C file of a session no longer waits for
  it, and a C file's checks run in the engine worker, so typing does not wait for them.

## What's new in 6.32.4

**Memory no longer keeps growing.** Less is kept while editing, opening files and going from project to project.

- **Opening another folder** lets go of what was kept for the last project and its open tabs: the engine's colours,
  checks and hints, the words of every file, the compiler's answers, the names macros make, the indexes of C headers
  and stylesheets. They come back from the disk when that project is opened again.
- **nedls** lets go of what it worked out for a file when the client closes it, as ned does.
- Fourteen more things kept per open file (a diff, a merge, a notebook …) are let go when its tab closes.
- Reference counts and the result types of `auto` routines no longer add an entry at every edit, and the copies of
  files kept by the typo check and by plugins have a bound.
- **The C standard headers' index** is kept on disk, so the first check of a C file in a session no longer reads them
  all.

## What's new in 6.32.3

- **A member a macro makes is no longer marked as missing.** In the showcase, `cfg.getTitle`, made by
  `makeGetters(Config, title, size)`, was marked *undeclared field*. A member is not marked until the names macro
  calls make are known, nor when they never are (`nim.macroNames` off, no `nim`, a folder not trusted).
- **What the compiler told ned is kept with what it depends on**, an idea from the Nim compiler's new `nimsuggest2`.
  The names macro calls make are kept on disk, so a file opened again as it was has them at once; what `nim dump` says
  of a project (its defines, search paths, packages) is kept, so the engine has it from the first screen; a type hint
  from the compiler no longer stays when a return type changes in another file.
- **An edit inside a body** no longer makes the modules that import the file gather their names again, when the file
  declares the same as before.
- **Reference counts** come at once when a project is opened again.

## What's new in 6.32.2

- **ned no longer grows as files are opened and closed.** A closed tab now takes with it everything kept for it (the
  semantic colours, the dimmed code, the engine's checks, inlay hints, the C engine's parse), in ned and in its engine
  worker.
- **Typing in a big C file is quicker.** Marking the uses of the name under the cursor waits for a pause in typing,
  and drawing no longer looks through all of a file's problems for each line.
- **A big Nim file opens faster**: the code a `when` leaves out is dimmed just after the first screen, not before it.
- **Control characters** U+0080–U+009F in a file, a program's output or an AI's answer are drawn as �, as ESC and BEL
  already were (␛ ␇): some terminals obey them as escape sequences.
- A plugin request whose arguments are not an object is read as having none, instead of making an internal error. A
  message from a plugin or a script is cut at 4 000 bytes.
- The Nim menu's *Nimble › add dependency…* is no longer always greyed out. Emacs's `C-x 1` closes the other panes,
  not the one in use.

## What's new in 6.32.1

- **Typing in a very big Nim file is quick again.** Dimming the code a `when` leaves out waits for a pause in typing,
  as the semantic colours do.
- **The formatter lays out a long `return @[…]`** as nph does, the list on the line after `return`, instead of
  refusing the whole file.
- **Nothing in the sandbox can tell ned what to do.** A plugin in the sandbox could reach ned's remote-control socket
  and the socket of a terminal kept running (Landlock does not limit that), and through them run any command or type
  into the shell. Each now answers only a program that sends its key, kept in ned's private folder where the sandbox
  cannot read it.
- **A plugin allowed to run programs runs in a process of its own**, so the other plugins stay in the sandbox.

## What's new in 6.32

6.32 is about seeing what Nim does, with panes that have their own tabs, nedls in more editors and plugins in a
sandbox.

**Macros you can see.** Alt+M on a macro or template call shows what it writes right under the call, coloured as Nim
but not part of the file: nothing is saved and the line numbers stay. In it a name hovers with its documentation and a
tap goes to its declaration; an error the compiler reports on the call is shown on the generated line. The expansion
follows its call and is written again when the call changes; Alt+M again hides it. *Nim: expand macro/template in a
tab* keeps the old way. [Expansion](docs/guide/nim.md).

**Why?** A tap on a routine's exception hint, or *Nim: why?*, shows where an exception comes from, call by call down
to the `raise` or a `{.raises.}`, each step a row that goes there; for a routine that cannot be a func, down to the
global or the routine with side effects. Alt+Enter offers it on the compiler's *can raise an unlisted exception* and
*can have side effects*.

**More errors before the compiler.** As you type and in `ned --lint`, in the compiler's words: an assignment to a
`let`, a `const`, a loop's variable or a parameter that is not `var`; a literal of the wrong type given to a variable,
to `result` or by `return`; a member an object of the project does not have.

**Bigger refactorings.** Each is a diff before anything changes, undone file by file with Ctrl+Z: *object ⇄ ref
object*, *split the selected declarations into a new module* (imports and exports put right both ways), *callback →
async* (`Future[T]`, `await` in async callers), *switch call syntax* (`f(x, y)` · `x.f(y)` · `f x, y`, only where the
meaning stays).

**Find references.** It also finds `0..s.len`, a tuple's labels, a variable in its own value, `high(int64)` and
`int.high`, a declaration below its use, command calls, forward declarations, a `let` in a condition, a module's own
type over an imported one, pragma names, and `when` over several lines or decided by `(NimMajor, NimMinor)`.

**A package installed while ned runs is found.** When nimble's package folders or the files that put packages on the
path change, the engine reads them again, nimsuggest and nimlangserver restart, and the open Nim files are checked
again, with no save needed. nedls too.

**The Nim tour.** Sixteen short lessons that run in the notebook, from the first `echo` to ARC/ORC with `sink` and
`lent` and calling C. Ctrl+Enter runs a cell; each lesson ends with an exercise that says ✓ when the code works, its
answer folded away beneath. The lessons are built in, so only Nim and a C compiler are needed; each opens as your own
copy, and ned remembers where you were. *Help › Nim tour*. A notebook can say how it runs: `# notebook: compiled`
above its first cell. [The Nim tour](docs/guide/tour.md).

**Panes with their own tabs.** A pane's files are tabs in its header: a tap shows one, Ctrl+PgUp/PgDn go through them,
× takes one out. **Named layouts**: *View: save this layout as…* and *View: layouts…*. **More in a pane**: *View:
terminal in a pane*, *View: assistant in a pane*, *View: panel in a pane*.
[Panes](docs/guide/projects.md#panes-tiling).

**In the editor.** A breadcrumb tapped lists what is beside it. The minimap marks what the find box finds and git's
changes. In a Nim file the touch bar adds ▶ run, ✓ check, μ macro, ? why and ⚡ fixes (`ui.touchBarLanguageKeys`); with
the touch bar shown, lists have rows twice as tall (`ui.bigTargets`). **Battery saver** (`ui.batterySaver`, on by
itself on battery): no cursor glide, the compiler on save only, no AI completion as you type, fewer wake-ups; a leaf ❦
in the status bar. Themes for outdoors and e-ink screens: `sunlight`, `sunlight-warm`, `sunlight-blue`, `e-ink`,
`e-ink-dark`. *Theme: import a Zed or Helix theme…* (or `ned --import-theme FILE…`) turns a Zed theme family `.json`
or a Helix `.toml` into themes of your own, filling the gaps from the nearest built-in theme.

**Formatter.** Closer to nph: empty lines in type sections and before a commented member, `x = block:`,
`typeof(for …)` and `collect(for …)` as blocks, a `while` with a long condition, comment blocks at their statement's
level. SQL, HTML and JSON in triple-quoted strings is formatted with the file (`nim.format.embedded`). A closing
bracket and `of`/`elif`/`else`/`except`/`finally` go back to where they belong as you type (`editor.autoDedent`).
**Format only what I changed** works in files git does not have, and gives black, ruff and clang-format only the
changed lines.

**nedls in more editors.** Set-ups for **Neovim** (`editors/nvim`, `lsp/nedls.lua` or `require('nedls').setup()`),
**Helix** (`editors/helix/languages.toml`) and **Zed** (`editors/zed`), each with a README. An editor that asks for
problems (pull diagnostics) gets the whole workspace's, checked while nedls is idle (`workspaceDiagnostics`), so VS
Code's Problems panel lists the project's errors and warnings. Colours come as semantic token deltas. Workspace
symbols answer at once, with word starts (`nsv` finds `newShapeValue`) and `Shape.wid` for fields. Text typed on the
last, empty line of a file no longer joins the line above. [nedls in other
editors](docs/guide/nim.md#nedls-neds-engine-in-other-editors).

**Safety.** Releases carry SHA256SUMS and a signature, which `ned --update` and install.sh check
(`ned --update --verify DIR` for a download). Secrets in what goes to the AI are replaced with placeholders, and files
of secrets such as `.env` are not sent (`ai.redactSecrets`). On Linux, plugins run in a Landlock sandbox
(`plugins.sandbox`): they read the project, write only to it and their data folder, and have no network unless
allowed; `ned --sandbox CMD` runs any command that way. [Safety](docs/guide/safety.md).

**Fifteen new plugins of ned's own** (Plugins dock › AVAILABLE). For Nim: **benchy**, **web-routes** (a Jester or
Prologue app's routes), **examples-to-tests**, **nimble-browser** and **nim-playground**. Also **containers** (Docker
or Podman), **github** (pull requests and issues through gh), **kanban** (a board from TODO.md), **wiki-notes**
(Markdown notes with [[links]] and backlinks), and the languages **Typst, Kotlin, Fortran, Pascal, Ada** and **V**.
[ned's own plugins](docs/plugins/available.md). The plugin library comes with the [ned Plugin
Exception](PLUGIN-EXCEPTION.md): a plugin that imports it can be under terms of your choice; ned stays
GPL-3.0-or-later.

**Termux.** The package reads Nim's standard library into ned's index when it is installed (`ned --warm-index`), so
completion and hover start at once. The debugger shows Nim strings, seqs and tables readably even without Nim's gdb
pretty printers.

## What's new in 6.31

ned is now under the **GNU GPL (version 3 or later)**, with documentation for those who want to work on it and a
plugin API documented end to end.

**Panes, tiled.** Split the editor right or down as often as there is room (*View › Panes*, or *View: panes: two
columns*, *three columns*, *grid of four*, *one large and three*). Ctrl+Alt+Shift+arrows go to the pane that way,
Alt+\ to the next, Alt+| closes it; drag the line between panes or resize with Ctrl+Alt+arrows; swap, zoom, make
equal, turn a split. A tab dropped on a pane shows there, or on its right or bottom quarter cuts it in two. Vim's
Ctrl+W works, and `:q` closes a pane. Panes come back the next time. [Panes](docs/guide/projects.md#panes-tiling).

**Multibuffers.** Search results, problems, TODOs, the open files or a selection (*Multibuffer: add the selection*),
numbered as their files are and following them until edited; saving writes only the edited pieces. Each piece has ⇡ ⇣
(more lines) and ✕ (out); F12 works through the file; *next piece*, *previous piece*, *refresh*. A piece of a
library's file or a read-only tab is not written.
[Multibuffers](docs/guide/search.md#editing-the-results-multibuffers).

**Telescope.** Alt+V opens the chosen place in a pane at the right, Alt+X below, and Alt+Q puts the whole list in a
multibuffer. New finders: *Lines of this file*, *Panes*, *Jumps*. Its **⊙** is in the status bar, and in a Markdown
file **M↓** opens and closes the preview.
[Telescope](docs/guide/search.md#telescope-one-finder-for-everything-altshiftf).

**Plugins.** Every proc of the API is documented with an example, and a new [cookbook](docs/plugins/cookbook.md) has
21 whole plugins. Plugins can work with panes and multibuffers (`panes`, `splitPane`, `showInPane`, `paneLayout`,
`openMultibuffer`, `pieces`, `addPiece`, `placeInFile` …). A plugin that gives ned a program to run (a language
server, a formatter, a run or build command) now asks for the permission to run programs; ned's own plugins that were
on keep working. A plugin's `:` command starts with a capital letter, so `:w` and `:q` stay ned's.
[Plugins](docs/plugins/README.md) · [API](docs/plugins/api.md) · [Cookbook](docs/plugins/cookbook.md).

**For contributors.** [docs/dev](docs/dev/README.md) says how ned is put together, with recipes and the pitfalls to
avoid.

**Code snap as PNG.** *Code snap: selection as PNG* uses rsvg-convert, resvg, ImageMagick, Inkscape or Chromium; with
none installed, it offers to install one (`pkg install librsvg` in Termux, apt, dnf, pacman, Homebrew …).

**VS Code.** The nedls extension needs no npm packages and is built into a `.vsix` with Python alone.

**Fixes.** A problem the compiler puts after the last line ("expected: ')', but got: '[EOF]'") is shown at the end of
the last line, and F8 goes there. In zen mode, what follows a line goes on into the margin instead of being cut. A
.nimble's `name = value` fields are lined up as nimble's template writes them (`nim.format.alignNimbleFields`). The
find box selects the text it opens with.

## What's new in 6.30

6.30 is about themes: **Shades of Purple**, **ClassicBlue**, the **Nebula** themes, **true black for any dark theme**,
and five duplicate themes left out.

**New themes.** `shades-of-purple`, `shades-of-purple-super-dark`, `classic-blue`, `nebula-pulse`, `nebula-nova`,
`nebula-nord`, `nebula-serenity`, `nebula-glow` and `nebula-dawn`, each with its title bar, docks and status bar in
its own colours. Colours are lifted to at least 4.5:1 on their background (3:1 for comments), hue kept, to read in
daylight. Nebula Void is ned's own `slate`. [Themes](docs/guide/themes.md#the-built-in-themes).

**True black** (`theme.trueBlack`). Any dark theme with its editor, bars and docks black, so an OLED screen's pixels
are off where nothing is written; popups, menus and the current line a little lifted; text and syntax in the theme's
own colours.

**Fewer themes.** Left out: `molokai` (it is `monokai`), `catppuccin-frappe` and `catppuccin-macchiato`
(`catppuccin-mocha`, a shade apart), `github-dark-dimmed` (`github-dark`) and `slate-night` (`slate`). A setting that
names one of them gets the one it was.

## What's new in 6.29

6.29 brings Telescope, terminals that outlive ned, remote language servers, more from the assistant, plugin updates,
twenty-four more of ned's own plugins, and much of clangd in ned's own C engine.

**Telescope** (Alt+Shift+F). Every finder in one list, from files, live grep and symbols to git, Nim's library, nimble
packages, themes and plugins, each with a preview. *Telescope: resume* opens the last one again, with what was typed.
[Search](docs/guide/search.md#telescope-one-finder-for-everything-altshiftf).

**The cursor glides** (`ui.cursorAnimation`). A jump leaves a short trail that fades behind it, at only a few
kilobytes to the terminal. [Themes and appearance](docs/guide/themes.md#the-rest-of-the-look).

**Terminals that outlive ned.** Quit ned, close its window or let Termux end its session, and its terminals go on; the
next ned in the same folder takes them back, with what they showed. *Terminal: kill* ends one; *Terminal: kept
terminals…* lists them. `terminal.keepRunning`. Not on Windows.
[Terminal](docs/guide/terminal.md#terminals-that-outlive-ned).

**Remote folders: language servers on the server.** A folder over SSH has its language servers run on the server, with
its packages and toolchain; ned maps the paths both ways, and a definition in the server's library opens to read. With
no Nim on this device, ned's engine reads the server's Nim library. `remote.languageServers`. [Remote
folders](docs/guide/terminal.md#remote-folders-over-ssh).

**The assistant.** **Pictures**: `@shot.png`, a pasted path or *AI: attach a picture…*. **Code from a comment** (as in
Zed and Aider): Alt+Shift+C on a comment, or its ✦, writes the code it describes; a comment ending in `AI!` asks for a
change, made on save; one ending in `AI?` is answered in the chat. Each is checked by the compiler and shown side by
side before it is used. **With git**: *Git: why did this line change? (AI)*, *Git: resolve the conflicts with AI*,
*Review the changes with AI* in the Git dock. [AI](docs/guide/ai.md).

**Git status when something changes.** ned watches the repository (Linux, Android) and runs git status just after a
commit, a stage, a checkout or a save, not every 5 seconds. [Git](docs/guide/git.md#the-git-dock).

**Plugins.** With `pluginInfo(version, author, homepage, license)` the dock shows a plugin's version; *Plugins: check
for updates* (and once a day by itself) finds newer ones (*↑ 1.3.0*), to update, *Roll back* or *Pin*. Plugins start
sooner and read files much faster. A plugin can say how indentation looks (`indentStyle`). **Twenty-four more of ned's
own**: Swift, Scala, R, Nix, Terraform, Protocol Buffers, GraphQL, Svelte, CMake, LaTeX, Perl, Erlang; **indent-dots**
and **rainbow-indent** (dots in the indentation's spaces, or a colour for each level); **todo** (a task list in
`TODO.md`, due dates written as `due:fri`); **nim-html** (Karax and htmlgen); doc-gen, import-graph, release-helper,
yank-ring, color-picker, db-client (PostgreSQL, MySQL), code-snap, char-picker.
[Plugins](docs/plugins/README.md#versions-and-updates) · [ned's own](docs/plugins/available.md).

**C and C++: what clangd does, in ned's own engine.** References and rename go by the symbol, not the name. A
completed function writes its arguments to fill in; a name from a header not yet included is offered with its
`#include`, and Alt+Enter on an unknown name adds its header. Alt+Enter also adds a `switch`'s missing cases, extracts
a variable and inverts an `if`. Signature help across lines, the other uses of a name marked, a colour for each kind
of name, Go to type definition, Ctrl+T, Alt+F on a selection, and in C++ the type hierarchy and go to implementation;
nedls gives other editors all of it. [C and C++](docs/guide/c.md).

**Nim.** Nimja and Jinja templates (`.nimja`, `.jinja`, `.j2`) are coloured, with the code in `{{ }}` and `{% %}` as
Nim. The other uses of the name under the cursor are marked by what it is, not by its spelling. The engine reads a
project without its cache about a tenth faster, and the check while typing is left out when only a comment or spacing
changed.

**Installing and updating.** `curl -fsSL …/install.sh | sh` (Termux: the release's package; elsewhere: nimble),
`nimble install https://github.com/foxoman/ned`, and `ned --update` for the newest release, installed the way this ned
was. [Installing](README.md#installing).

**Also.** A dialog, a form or a picker moves with its title bar dragged, and opens there again. On Windows (still
experimental), the programs ned builds get their `.exe`, the Nims of choosenim are found, and *Check setup* says when
Git for Windows' sh is missing. The welcome screen fits a phone; *Git: commit…* with nothing changed says so; a few
lists and docks fit their text better. A button over the minimap (the find bar's ×, a note's) takes a click again.

## What's new in 6.28

6.28 brings more compiler errors caught as you type, C and C++ definitions and hovers level with clangd's, a formatter
closer to nph, more of LSP in nedls and more of Nim 3.

**Nim errors as you type.** The engine also finds a call's value left unused where it is a block's last statement but
not the routine's value, a module-qualified call not discarded (`posix.nanosleep(…)`), and a misspelled name inside a
`when` branch that is taken, with no wrong error in a clean file.

**C and C++ closer to clangd.** ned's C engine reads Lua's `LUA_API void (lua_concat) (…)` declarations, the macros of
the `#if` branch that is taken, a struct's members a macro gives it (`CommonHeader;`), comma expressions, casts in
extra parentheses, and a class's own name inside it.

**The formatter, closer to nph.** Now laid out as nph does: a name with its pragmas whose type does not fit
(`var X* {.importc: "…".}:` ⏎ `cint`), `let (a, b) = …`, an if-expression among a call's arguments, no empty lines
between an enum's values, `tuple[…]`, `ptr [T]`, `iterator (…)` and `` `$`*( ``. What ned cannot lay out as nph would
keeps its line breaks, rather than becoming one line of 200 columns. There is no setting to keep the old way.
[Formatting](docs/guide/formatting.md#compared-with-nph).

**nedls.** Pull diagnostics (LSP 3.17); Enter formats the statement just written (on-type formatting); an HTML tag and
its closing tag are renamed together (linked editing); workspace symbols find the project's C, C++, JavaScript and
JSON names, in files not open as well. [nedls](docs/guide/nim.md#nedls-neds-engine-in-other-editors).

**Nim 3 (Nimony).** Contracts as you type see a `const`, a `let` given a value and a loop's variable over `a .. b` or
`a ..< b`, and a `return` or `result =` that breaks the routine's own `{.ensures: …}`. A file in `tests/` with the
output it should print (`t1.output`) or the messages it should give (`t1.msgs`) beside it, as Nimony's own tests are
written, is in the test explorer and runs with Nimony's `hastur`. When nimony stops on an error of its own during F12,
the status bar says so. [Nim 3](docs/guide/nim.md#nim-3-nimony).

**HTML.** A link to an `#id` is no longer flagged in a fragment, a template or a page whose script makes elements.

**Plugins.** A tap on one of ned's own in the Plugins dock's AVAILABLE turns it on, and the status bar says what it
added ("the Zig language, a formatter, 6 snippets, 2 commands"); a right-click gives its menu. **Julia**:
LanguageServer.jl, when installed, starts the first time a Julia file is saved; a plugin can ask the same for its own
server (`languageServer(…, afterSave = true)`). [ned's own plugins](docs/plugins/available.md).

**Fixes.** On Windows, the Nim parser check (`nim.format.verify`) is found and no longer built again at every format;
a build that fails says why. The Julia plugin's server command with quotes is no longer cut at its spaces. The
formatter no longer leaves a condition's `:` on a line of its own or makes lines of over 200 columns from a condition
with a comment inside its brackets, and a wrapped if-expression among a call's arguments stays as it was.

## What's new in 6.27

6.27 makes `nedls` a language server for every language ned knows, with a VS Code extension. It adds a JSON engine,
JavaScript across modules, more HTML, CSS and SQL checks, more of Nim 3, Nim wrappers for C headers, fifteen new
plugins of ned's own and six themes easy on the eyes.

**Windows Terminal colours.** Themes no longer show on a blue, teal or grey background. Windows Terminal and the
Windows console (also through WSL) get 24-bit colour, and a terminal with only 256 colours gets the nearest of them
for each colour. *Check setup* says which is in use and why.

**The Nim engine.** References tell the uses of an overloaded name apart (`len`, `addInt`), and a type in a long proc
header with pragmas is now read.

**nedls.** New: call and type hierarchies, implementations, selection ranges, code lenses (▶ run a test, a suite, a
nimble task), document links, and imports fixed when a file is renamed. It now also serves C and C++ (completion,
hover, definition, references and rename across the project, the compiler's errors and fix-its as you type),
JavaScript, HTML, CSS, SQL and JSON, each with formatting. The VS Code extension is in `editors/vscode`, and each
release has it as a `.vsix`. See [nedls](docs/guide/nim.md#nedls-neds-engine-in-other-editors).

**JSON.** A missing or extra comma, an unclosed string, a key given twice and comments in plain JSON (JSONC allows
them) are flagged as you type. In `package.json`, `tsconfig.json`, `atlas.config`, `atlas.lock`, `nimble.lock`, ned's
own settings and `.ned/lint.json`, keys and values are completed, explained on hover and checked
(`"nmae" is not a key of package.json — "name"?`). The Outline lists the keys, and the breadcrumbs show the key path
at the cursor.

**JavaScript across modules.** F12 on an imported name opens its module, *Find references* and rename reach the files
that import it, and the Outline lists functions, classes with their members, and constants.

**HTML, CSS and SQL checks.** HTML: a link to an `#id` no element has or to a file that is not beside the page, and a
misspelt attribute (`clas`). CSS: `var(--primay)` where the sheet sets `--primary`. SQL: an `INSERT` with more or
fewer values than columns, and an unknown column in a column list or `UPDATE … SET`.

**.nimble files.** A `requires` package name is completed from nimble's package list and explained on hover (F12 opens
its installed .nimble). A name the list does not have is flagged, with the one meant.

**Nim 3 (Nimony).** `.nif` files have colours, an Outline and a hover that says what each tag is and where it comes
from in the Nim source (F12 goes there). *Nim 3: the NIF of this file beside it* shows both, each following the cursor
in the other. New checks as you type: a call that breaks the routine's `{.requires: …}` (*contract violated*),
`delay()` of a passive proc that takes a `var`, and a name written in another case than its declaration. For **pnak**,
Nim 3's package tool: *pnak fetch* and *pnak pin*, and its lockfile `pnak.nif` with an Outline, hover, F12 to each
package's checkout, and problems such as a missing commit or a package not fetched. See [Nim
3](docs/guide/nim.md#nim-3-nimony).

**Nim for a C header.** *Nim: wrap a C header…* uses ned's own C engine, with nothing to install: functions as
`importc` procs, structs and unions as objects (bit fields too), enums, function-pointer types, `#define` constants
and globals. *… with c2nim* uses c2nim or futhark instead.

**Fifteen new plugins of ned's own.** In the Plugins dock under AVAILABLE: **regex-lab** (matches lit up in the file,
a replace checked first, a pattern explained), **transform** (sort, unique, number, encode and decode, pretty JSON,
add up), **sqlite** (a database's tables in the dock and in completion, the query at the cursor run), **web-preview**,
**commit-helper** (a commit message drafted from what is staged), **nim-eval** (the selection run, its output beside
it), **license-header**, **dotenv**, **mermaid**, and the languages **Zig**, **Julia**, **OCaml**, **Crystal**,
**Dart** and **Clojure**. Plugins can use ned's regular expressions (`regexMatches`, `regexReplace`). See [ned's own
plugins](docs/plugins/available.md).

**Six themes easy on the eyes.** `oled-black`, `oled-warm` (no blue, for the evening), `oled-dim` (for a dark room),
and for LCD screens `lcd-soft`, `lcd-warm` and the light `lcd-paper`. See [Themes](docs/guide/themes.md).

**Fixes.** In a picture's bytes, Tab moves between the hex and text columns. Settings sync offers a plugin of your
other device once, not at every sync. A NIF file with something other than a number after `@` no longer stops its
view. The Plugins dock shows the plugins' log above the list of ned's own. A misspelt field is one problem, with the
field meant, not two.

## What's new in 6.26

6.26 brings notebooks, memory checks for Nim, C and C++, tests written from running a proc, flame graphs, pictures
that open as pictures, a fuller Markdown preview, plugin permissions and settings sync both ways.

**Notebooks.** In a Nim or Python file with `# %%` cells, **Ctrl+Enter** (or a tap on **▶ run**) runs a cell and shows
its output under it; Shift+Enter also moves to the next. Cells share one session, as in Jupyter. A cell changed since
it ran says so, and an error shows under its cell and in Problems. Run › Notebook has *run all*, *run the cells
above*, *clear the outputs* and *restart the session*. Nim cells run in Nim's VM; `notebook.nim` = `compiled` runs
them as a program, for code that needs C libraries. Outputs are not saved in the file. See
[Notebooks](docs/guide/run-and-debug.md#notebooks).

**Run with memory checks.** In the Run menu: the program runs with the compiler's address and undefined-behaviour
checks (valgrind when the compiler has neither). Each write past a block's end, use after `free`, double free, signed
overflow and leak shows in Problems on its line, with where the block was allocated and freed. One run finds them all.

**Tests from running a proc.** *Nim: write tests for this proc (from running it)* calls the proc at the cursor with
sample arguments, writes each result as a `check` (an exception as `expect`) in `tests/t<module>.nim`, and runs them
with coverage. The tests record what the proc does now, so read the values.

**Profiling.** *Nim: flame graph of the profile* shows the call stacks, each box as wide as its share of the time,
your code in warm colours and the libraries in cool ones; a tap on a box looks inside it. *Nim: compare with the
previous profile* shows each proc's share before and after a change.

**Pictures.** `.png`, `.jpg`, `.gif`, `.bmp` and `.webp` files open as the picture: `+` and `−` zoom, the arrows move,
Tab shows the bytes. kitty, Ghostty, iTerm2, WezTerm and sixel terminals draw it at full resolution; elsewhere, such
as Termux and tmux, it is drawn in text cells.

**Markdown preview.** View › Markdown preview follows the cursor and now draws tables, task lists, nested lists and
quotes, GitHub's notes (`[!NOTE]`, `[!TIP]`, `[!WARNING]` …), strikethrough and pictures. A tap on a link goes to the
heading, web address or file it names.

**Plugin permissions.** Before a plugin runs, ned reads its source for anything beyond editing (running programs,
changing files, the clipboard, the network) and asks you once, showing what, why (the plugin's `permission(…)` reason)
and where. What is not allowed is refused with an error naming the permission. *Plugins: permissions…* takes them
back. A plugin's own data folder (`writeData`, `appendData`, `readData`) needs none, and plugins you already had on
keep what they use. See [Permissions](docs/plugins/README.md).

**Settings sync both ways.** *Settings sync: sync now* merges both devices' changes setting by setting; where both
changed one, this device's value is kept and ned says so. Words and plugin lists are put together, and a plugin your
other device has is offered for installing. `sync.auto` takes `start`, `quit` or `both`; `sync.exclude` keeps settings
on this device.

**The C and Nim engines.** In C, a header's `#if`s see the macros of the file that includes it; in C++, a class name
goes to the class, not its constructors. The Nim engine's checks as you type also run in a file that `include`s
others, such as most of the standard library's modules.

**Fixes.** A plugin's `clipboard()` returns what Ctrl+V would paste, also where ned cannot read the system's
clipboard, and `setClipboard` gives ned's own paste the text too.

## What's new in 6.25

6.25 brings nineteen plugins of ned's own with a Plugins menu to manage them, the compiler as a background oracle for
the Nim engine, and a C engine that works out the preprocessor's `#if`.

**ned's own plugins.** They are off until turned on in the Plugins dock under **AVAILABLE** (*Turn on*, *View its
source*, *Copy to my plugins*). The [list](docs/plugins/available.md):
- editing: **dial** (Ctrl+A / Ctrl+X on numbers, dates, times, true/false), **case-change** (vim's `crs`, `crc`),
  **split-join** (`gS`, `gJ`), **text-objects**, **exchange** (`cx`), **align** (`ga`);
- moving around: **harpoon** (a few pinned files, one key each), **which-key** (what each next key does, after `g`,
  `z`, `<leader>`, C-x or helix's space), **oil** (a folder edited as text; ned asks first, and deleted files go to a
  trash folder);
- tools: **json-to-nim**, **rest-client** (`.http` files sent with curl), **path-complete**, **markdown-tools**,
  **pomodoro**, **time-tracker**;
- languages: **Odin**, **Gleam**, **Elixir**, **Haskell**, with their language servers and formatters when installed.

**The Plugins menu.** The menu bar has a Plugins menu for the Plugins panel, ned's own plugins, each plugin's
commands, turning one on or off, uninstalling, reloading, updating, installing from git or from the list, a new plugin
and the API. In the dock, a plugin's menu has *its settings*, *view its source* and *uninstall*; **+** adds one.

**The plugin API.** New: a plugin's own tabs (`newTab`, `onSaveTab`, `markSaved`, `setTitle`, `closeTab`), keys for
one language (`keyIn`, `nmapIn`, `vmapIn`), key hints (`onKeysWaiting`, `showKeyHints`, `keyMaps`), `onEnter`,
`onQuit`, `shellAsync`, `unixTime`, `clipboard`, `vimMode`, `setting()` in top-level code and `projectRoot()`.
Language specs get more lexer options, plugin operators work with `gg` and `f{char}`, and plugin completions work
inside strings.

**The Nim engine.**
- **The compiler as an oracle** (`nim.compilerOracle`): what the engine cannot work out by reading, such as a type a
  macro makes or the overload a call picks, is asked of the compiler after a pause and kept on disk. Type hints use
  the answers, an overloaded call's hover says **Called here — the compiler's choice**, and Go to definition goes
  straight to it.
- **Chain hints** (`nim.chainHints`): the type after each step of a call chain over several lines.
- **Checks as you type**: a `case` over an enum that leaves values out (Alt+Enter adds the branches), an argument that
  can never be the parameter's type (`twice("x")`), and a dropped method-call result (`s.pop()`).
- **Completion** ranks what you chose lately first, kept between sessions.
- **Rename** reaches `{name}` in `fmt"…"` and `&"…"` strings, `` `name` `` in doc comments, and your other packages.

**The C engine.** No clangd needed:
- **`#if` worked out** from `compile_commands.json`, the `#define`s of the file and its headers, and the compiler's
  own macros. A branch left out is dimmed and declares nothing.
- **Declarations macros make**, such as `get_width` from `DECLARE_GETTER(width, int)`, are completed, hovered and
  reached with F12.
- **Checks without a compiler** (`c.engineChecks`): an unused `#include`, a struct that would be smaller with its
  fields ordered by size (*Order the fields*), and printf and scanf formats that do not fit their arguments.
- **C++**: a call to an overloaded function goes to the overload its arguments fit, and a class template's
  specialisations are found, hovered and completed.

**Indent and unindent.** *Indent lines* and *Unindent lines (outdent, dedent)* are in the Edit menu, the palette and
on the touch bar (`indent` in `ui.touchBarKeys`), besides Tab and Shift+Tab, vim's `>>` and `<<`, and Ctrl+T and
Ctrl+D in insert mode.

## What's new in 6.24.1

Fixes for what 6.24 got wrong on a tablet, and Compiler Explorer for library modules.

- **Compiler Explorer's toolbar sets what you pick.** In 6.24 every item of its menus did what the last one does: any
  filter switched *Demangle* off, any compiler chose zig cc. If you used them, switch *Demangle* back on under
  *Filters ▾* and check the compiler. The same fault is fixed in the dock's view menu, the C compiler's fixes on
  Alt+Enter, the JSON settings' *edit…* links, plugins' views and completions, and the Git dock.
- **Compiler Explorer shows every proc of the file.** Procs nothing calls yet are shown too, so a library module is no
  longer only `NimMain`. *Filters ▾ › Every proc of the file* (`compilerExplorer.allProcs`) turns it off.
- **No false errors in a plugin's source.** `import nedplugin` (and `nedlsp`) resolves for the compiler's checks too,
  so a full-Nim `plugin.nim` no longer shows every line red.
- **`AGENTS.md`.** A short guide to building ned and the rules of its source, for AI agents working on ned.

## What's new in 6.24

6.24 brings Compiler Explorer into ned and a full set of documentation.

**Compiler Explorer.** Open a Nim, C or C++ file and choose *Compiler Explorer* (the Run menu, Nim › Inspect, the
right-click menu or the palette). The assembly opens beside the file and follows it as you type, compiled from the
unsaved text in a private copy of the project, so your build and your files are not touched. As on godbolt.org:
- each source line and the instructions it made share a colour, and the line under the cursor lights up on both sides;
- the noise is filtered, and Nim's mangled names are written as in Nim (`square__ce_u3` → `square`);
- a toolbar sets the options, the C compiler (gcc, clang, zig cc), the processor (x86-64, ARM64, RISC-V, x86), Intel
  or AT&T syntax, the compiler's assembly or the object file disassembled, and the filters; **▶ run** runs the program
  after each compile, and **⇄ compare** shows two sets of options side by side;
- hover on an instruction or a register says what it does (x86-64 and ARM64, also in `.s` files), and **F12** on a
  label or a call goes to it.

Its settings are its own (`compilerExplorer.*`), so it never changes your project's build mode. See the
[guide](docs/guide/compiler-explorer.md).

**Documentation.** The README is now an overview; everything else is in [`docs/`](docs/README.md): a
[FAQ](docs/FAQ.md), a guide for each part of ned, from [key bindings](docs/guide/keys.md) to
[troubleshooting](docs/guide/troubleshooting.md), a [plugin tutorial](docs/plugins/tutorial.md), the [API
reference](docs/plugins/api.md) for `nedplugin` and `nedlsp`, and references of [every
setting](docs/reference/settings.md) (`ned --doc-settings`) and [every command](docs/reference/commands.md)
(`ned --doc-commands`).

**Windows.** The release has a Windows build, `ned-6.24.0-windows-x86_64.zip`, with ned, nedfmt and nedls;
`nimble windowszip` builds it. Windows is still the least mature platform, and WSL is the safe way.

**Plugins.** Two registrations of the same kind in one plugin, such as two `onChange("*")`, now both work.
`projectDir()` gives the project's folder.

**Fixes.** A one-line commit runs `git.checksBeforeCommit`, as the message box does. `c` in the Git dock opens the
message box. vim's `:sp`, `:vs` and `:only` split the editor and close the split. Assembly views have no indentation
guides.

## What's new in 6.23

6.23 lets you turn clangd off and lose little: ned's own C engine and C formatter learn what clangd and clang-format
do. The Nim side gains rewrites on Alt+Enter, argument placeholders, `# fmt: off`, a magic trailing comma and comments
lined up.

**C without clangd.** With `c.engine` on `builtin` (or `auto` with no clangd installed):
- hover shows a struct's size, alignment, field offsets and padding, the value of an enum constant or a `#define` of a
  number, and what a macro's use expands to;
- the compiler's own fix-its are quick fixes on Alt+Enter, such as `.` → `->` on a pointer or a misspelt member;
- parameter names before literal arguments (`area(width: 3, height: 4)`), set by `nim.parameterHints`;
- the call hierarchy, and *C: switch between header and source*.

**C formatting in clang-format's styles.** `c.format.style` takes `LLVM`, `Google`, `Chromium`, `Mozilla`, `WebKit`,
`Microsoft`, `GNU` or `Linux`. `auto`, the default, reads the project's `.clang-format`: `BasedOnStyle` and the common
keys for indentation, tabs, the column limit, braces, pointer alignment, alignment and short lines. Without one, ned
keeps its old `keep` way. `c.format.options` adds clang-format keys over the style (`{"ColumnLimit": 100}`), and
`// clang-format off` … `on` and `#if 0` blocks are left as written. `c.formatter` takes `auto`, `clang-format` or
`builtin`, and the C in `{.emit: """…""".}` follows the same choice.

**The Nim formatter.**
- `nim.format.alignComments` lines up the comments at the end of lines that follow each other.
- `nim.format.magicTrailingComma` keeps a list that ends in a comma one element per line, as black and ruff do (off by
  default).
- `nim.format.normalizeNumbers` writes `0X1f'u8` as `0x1F'u8` and `1E5` as `1e5`.
- `nim.format.docCode` formats the Nim in a doc comment's code blocks too.
- `# fmt: off` … `# fmt: on` and `# fmt: skip` (and nph's `#!fmt: off`) leave code as written.

**Nim rewrites on Alt+Enter.** Also as nedls' code actions: **Write the type**, **Write as `x.f(y)`** / **`f(x, y)`**,
**Name the arguments**, **Write as a case** and **Write as if/elif**, **Invert the if**, and **Write 255 as 0xFF**
(and binary, octal, decimal).

**Argument placeholders.** With `nim.completeCallArguments` on (it is off by default), completion writes a call with
its parameters to fill in, and Tab moves to the next one. nedls sends them as snippets.

**Doc comments carry on.** With `editor.continueComments`, Enter in a doc comment starts the next line with `##`,
`///`, `//!` or ` * `.

**The decompiler in the menu bar.** Run › *Decompile* and Nim › *Inspect*.

**Fixes.** A constant's `## \` doc that goes on at the constant's own indentation shows on hover again. The C
formatter's `keep` way no longer writes `{return 1;}` as `{return 1; }`.

## What's new in 6.22

6.22 makes ned answer in NimScript files and plugins as it does in a program, reads doc comments the way `nim doc`
does, formats scripts from the shell, and gives the Settings window clearer controls and a scroll bar a finger can
use.

**NimScript files.** In config.nims, build scripts and .nimble files, system's NimScript part (`exec`, `mkDir`,
`switch`, `task` …) has hover and completion. Hover on a task says how to run it, and tasks are in the Outline and *Go
to symbol*. Importing a module the VM cannot run (osproc, net, httpclient …) is a problem, with what a script uses
instead (rule `nimscript-only`).

**Plugins.** In a plugin (`plugin.nims`, `plugin.nim`, anything that imports `nedplugin` or `nedlsp`), the plugin API
resolves wherever the file is, with its docs on hover and in completion.

**Doc comments as `nim doc` reads them.** A `##` that goes on below the declaration is one doc, a line ending in `\`
is joined with the next, and a constant written over several lines gets the doc below it.

**Closer to nimsuggest.** Signature help finds the file's own routines first, Go to definition on a forward
declaration goes to its body, a `do (x: T):` block knows its parameters, a name in `from m import a, b` is m's, and
`import std / [os, strutils]` written with spaces is read as an import.

**The formatter on scripts.** `ned --format` formats .nims and .nimble files as NimScript, as the editor and nedfmt
already did.

**The Settings window.** Check boxes, text fields, numbers (with − and +), lists (▾) and buttons each look like
themselves, and ↺ puts a changed setting's default back. The scroll bar is two columns wide with ▲ and ▼, jumps where
its track is tapped (Termux), drags with a mouse, and scrolls with the wheel or a swipe without snapping back.

**Fixes.** A file saved right after typing is checked again at once; it used to wait for the next edit, and scripts
saved that way showed no problems.

## What's new in 6.21

6.21 makes ned work more like a desktop app, puts a decompiler beside your code, takes Atlas projects further, builds
ned for Windows itself and can reset everything to a first start.

**Dialogs and forms.** The Settings window has categories, a search over every setting, check boxes, lists, number
fields and OK, Apply and Cancel; OK writes only what you changed and keeps the file's comments. *New Nim project…*,
Atlas's commands and *Reset everything* are forms. Prompts and pickers get OK and Cancel (`ui.formButtons`); Tab moves
between fields, Enter is the default button, Esc closes.

**Text fields you can select in.** Every field takes the mouse (click, drag, double- and triple-click), Shift+arrows,
Ctrl+A, Ctrl+C and Ctrl+X, and a right-click menu with Cut, Copy, Paste and Select all.

**Right-click everywhere.** Tabs, the gutter (breakpoints, logpoints, bookmarks, folds, the line's git change), every
dock item, the status bar, the title bar, breadcrumbs, the minimap, the panel, messages, a split's pane header, a
picker's rows and the welcome page's recent files.

**Drag and drop.** Drag a tab onto a pane, or to the editor's edge to split. Drop a file from the tree to open it,
move it into a folder (after asking) or put its path in the terminal. Drag selected text to move it, or hold Ctrl or
Alt to copy it (`ui.dragAndDrop`).

**A decompiler beside your code.** *Nim: decompile this proc (side by side)* shows the proc at the cursor as C
(radare2 with r2ghidra or r2dec, rizin with rz-ghidra, RetDec) or as assembly with the Nim lines it came from
(radare2, rizin, objdump, llvm-objdump), whichever is installed (`decompiler.tool`). In the hex editor, *Hex:
decompile a function…* lists a program's functions, and *Decompile a program…* opens one. In Termux,
`pkg install radare2` (or binutils) is enough.

**Atlas.** An Atlas project shows its dependencies first in the Nim panel, marked *linked*, *≠ lock* or *not on the
path*, each with its own menu, and lists the Nims `atlas env` installed. Atlas's commands (install, update, add a
dependency, link, pin, replay, outdated, the dependency tree, tasks, build, tests) are in the palette and *Atlas…*,
and its errors go to Problems on the `requires` line they name.

**Windows, natively (experimental).** ned builds for Windows itself: Windows Terminal is its terminal, PowerShell runs
in its terminal panel (ConPTY), commands run through Git for Windows' sh, and the clipboard is Windows'. WSL is still
the safer way. See [Windows](README.md#windows).

**Reset everything.** File › Preferences › *Reset everything (start fresh)…* shows what ned keeps and its size,
removes what you tick and starts ned again as on its first run. `ned --reset` does the same from the shell, for when
ned no longer starts as it should.

**The formatter.** `{.emit: """` stays on its line, with its C coloured. A comment after `=`, `x = if/try/case …` with
the first branch on the same line, `quote do:`, `expect E: body`, a long proc type and other shapes are formatted
instead of refused.

## What's new in 6.20

6.20 takes plugins further, shows a macro's tree and a module's docs beside the code, checks async, raises and gcsafe
before you compile, makes a .nimble easier to edit, understands Nim names in an emit, and opens files of any size.

**Plugins v2.** A plugin can give a language `completions`, `hover`, `codeActions` (Alt+Enter), `symbols` and
`snippet`s; give the assistant a tool (`aiTool`, `aiToolReadOnly`); and add a section to the Plugins dock (`view`),
progress in the status bar, lines in the Output panel and a command in ned's terminal. `settingDef` puts its settings
in the Settings panel, and `requiresNed(">= 6.20")` keeps it off an older ned.

**Plugins in full Nim.** A folder with a `plugin.nim` is compiled in the background into a program of its own, with
the whole standard library; its errors go to Problems. `plugins.alone` gives a NimScript plugin its own process, so a
slow one never holds up the others, and `plugins.native: auto` compiles plugins for faster calls. *Plugins: browse the
plugin list…* installs from your own list (`plugins.indexUrl`), and *Plugins: update* pulls the ones from git. New
examples: **ini-tools** and **clock-native**. See [Plugins](docs/plugins/README.md).

**The AST view and the docs preview.** *Nim: AST view* shows the statement or selection at the cursor as the tree a
macro gets, and what a macro or template call expands to. *Nim: preview this file's docs* shows the module the way
`nim doc` will, with whether its runnableExamples passed.

**Async, raises and gcsafe before compiling.** Flagged as you type: a discarded Future, `await` outside an `{.async.}`
proc, `waitFor` or `os.sleep` inside one, a `{.raises: [...].}` that leaves out what the body raises, and a
`{.gcsafe.}` or `{.thread.}` routine using a global seq, string, ref or Table. Hover says what a type lacks for the
concept a routine takes.

**Editing a .nimble and config.nims.** `requires "jsony >= ` completes the package's versions, and hover on a package
shows what it is, the versions installed, the one in use and the newest. Alt+Enter on `version =` bumps it. *Nimble:
add a dependency…* writes the `requires` line, and *Nimble: lock file* shows what nimble.lock pins and what changed.
In config.nims, `-d:` and `--path:` are completed, and `--gc:orc` and `--threads:on` come with fixes. *Nim: the
configuration the compiler ends up with* shows the config files read and where they disagree.

**Nim names in an emit.** The backticked names in an emit are Nim's: completed, hovered with the C name they become,
reached with F12, renamed and checked. An `exportc` proc's hover gives its C name.

**Files of any size.** A text file over 512 MB (`editor.viewerSize`) opens read-only in the large-file viewer instead
of being refused, and Go to line, Ctrl+End, Find and F3 reach any of its lines.

**Fewer waits.** Opening a big program no longer holds up typing, and the first completion after an import changes is
quicker. The compiler's checks and other work no one waits for run only when a core is idle (Linux, Android).

## What's new in 6.19

6.19 brings plugins written in NimScript, tells a NimScript file from a program, shows nimble's dependency conflicts
on the lines that cause them, keeps unsaved edits when you quit, reads and writes other encodings, and checks your key
bindings.

**Plugins, in NimScript.** A folder with a `plugin.nims` in `~/.config/ned/plugins/` (or a trusted project's
`.ned/plugins/`) can add commands and keys, answer events, edit the text, ask you things, and show problems with
fixes, gutter signs, highlights and a status-bar item. It can teach ned a language, format it, give it a language
server (one written with `nedlsp` is served to any editor by `ned --lsp-bridge server.nims`), and add vim mappings,
operators, text objects and `:` commands. Plugins share one `nim e` process that starts when needed, or are compiled
(`plugins.native`). The Plugins dock lists, turns on and off and reloads them; *New plugin…*, *Add an example…* and
*Install from git…* start one. See [Plugins](docs/plugins/README.md).

**config.nims and .nimble files.** `exec`, `thisDir`, `mkDir`, `switch` … are known in config.nims and .nimble files
only, and are a problem in a program. A .nimble knows nimble's own API (`namedBin`, `taskRequires`, `before`/`after`,
`feature` …) and completes package names in `requires`. Compiler switches are completed, explained on hover and
checked (`--threds:on`: "did you mean --threads?"). The formatter keeps NimScript's layout.

**nimble 0.26.** When nimble cannot resolve the dependencies, its explanation is a problem on each `requires` line it
is about. *refresh packages* works on 0.26. Git URLs that start with `-` are refused wherever ned runs git, as nimble
0.26.1 does.

**Hot exit.** Quitting with unsaved edits no longer asks: the next time ned opens the folder they are back in their
tabs, still unsaved (`files.hotExit`). Closing the terminal in Termux keeps them too.

**Encodings.** A file that is not UTF-8 is read as Windows-1252 (or what `files.encoding` names), a UTF-16 or BOM file
as such, and each is saved as it was read. The status bar shows the encoding, with *Reopen with encoding…* and *Save
with encoding…*. A character the encoding cannot hold stops the save, instead of a file written wrong.

**Key bindings.** *Keyboard shortcuts…* asks before giving a key that another command has, and marks keys that clash.
Problems in your `keys` setting, such as a command that does not exist or a key most terminals never send, are listed
and noted when ned starts.

**Smaller changes.** Fewer pauses while a project opens. A narrow status bar keeps an encoding that is not UTF-8, and
CRLF, in view longest. *Plugins: the API* opens read-only. The `plugins` setting holds each plugin's own settings.

## What's new in 6.18

6.18 gives nedls, ned's engine as a language server for VS Code, Neovim, Helix, Zed, Emacs, Kate and Sublime, the rest
of ned's Alt+Enter list, and an AI fix that the compiler checks before it reaches your code.

**ned's quick-fix list as code actions.** nedls now sends every edit in ned's list: the fix under the cursor and *Fix
all N like this in the file*; refactorings (generate `$`, `==`, hash and a constructor, add the missing case branches
or fields, reorder fields to save bytes, inline, extract a variable, a fmt string, a doc comment, a forward
declaration's body, format the JSON, SQL, CSS … in a string); *Organize imports* (`source.organizeImports`) and *Fix
all* (`source.fixAll`), which editors can run on save (VS Code:
`"editor.codeActionsOnSave": {"source.organizeImports": "explicit"}`); and *Turn off a rule for this project*, which
writes `.ned/lint.json`. What needs a dialog or runs something stays in ned.

**Fix with AI, checked with `nim check`.** On a compiler error, nedls offers *Fix with AI (checked with nim check)*
when `ai.provider` and its key are set. The model gets the declaration with the error, the declarations it uses and
the compiler's message. An answer that does not compile goes back once with the error. Only one that compiles is sent
to your editor, and not if you changed the file meanwhile; if the second answer fails too, the editor asks whether to
apply it anyway. `"aiFix": false` in nedls's settings turns it off.

**Fewer quick fixes that do nothing.** *Add the missing case branches*, *Inline this variable*, *Use fmt* and *Add a
doc comment* are offered only where they apply, and an action both ned and nedls offer is listed once.

**The debugger where `DEBUGINFOD_URLS` is set.** Ubuntu 24.04 sets it for every shell, and gdb's question about
downloading debug information made a logpoint print only once. ned now starts gdb without it.

## What's new in 6.17

6.17 makes ned answer sooner in a big program, and use less memory there.

**Faster in a big program.** Opening a file, typing with completion and adding an import hold ned up about half as
long as in 6.16, or less, and a completion takes about half the time. Completion gathers the names from the imports,
`system` and the program's other files once, in the quiet moments after a file opens, instead of at every first
letter. What a file can see is worked out in a third of the time, and an edit that keeps the imports updates it in
place.

**Less memory.** The engine worker needs less than half the memory, and no longer grows as you edit: it stays at about
25 MB.

**No pauses of half a second at start.** The engine worker now tidies the index's disk cache, and on Linux and Termux
the cache files are read ahead, so a slow disk does not hold ned up.

**More work off the keys.** Recovery files are written on a thread of their own, the C compiler's include folders are
looked up in the background, the TODO dock and the colours of imported names are worked out a slice at a time, and a
burst of answers from a language server is handled over several rounds.

**Help › Performance shows more.** It lists the index's files, the editor's heap and what the engine worker holds.
`NED_PERF_TRACE=file` writes every round of the main loop over 4 ms, with what it did.

## What's new in 6.16

**The engine worker.** Type and parameter hints, the engine's checks and misspelled names, reference counts and ned's
own CSS, HTML, SQL and JavaScript checks now run in a second ned (`ned --engine-worker`) on another processor core, so
they no longer hold up your keys. Completion, hover, go to definition and the rest you ask for stay in the editor and
come at once. In a big program, opening a file, typing and scrolling hold ned up much less, and hints and problems
arrive sooner.

**What the worker takes.** About 20 MB in a large program (Help › Performance shows it), and the editor takes less
than before. A worker idle for 10 minutes stops and frees its memory; if it stops four times in ten minutes, the
editor does the work itself and Help › Performance says why. `"nim.engineWorker": false` keeps everything in the
editor.

**Completion is about twice as fast in a big program.** The first completion after `nim dump` runs again no longer
pauses, and opening a file no longer pauses to read every include file.

Tip: the formatter wraps at `nim.format.lineLength` (88 unless your settings or `.editorconfig` say otherwise). A
ruler at another column (`"editor.rulers": [80]`) does not move it: `"editor.rulers": ["lineLength"]` puts the ruler
where the formatter wraps, or set `"nim.format.lineLength": 80`.

## What's new in 6.15

6.15 is about editing, and two more languages ned handles itself: JavaScript and C++.

**Select by the code's structure.** Alt+Shift+→ widens the selection step by step — name, call, argument, brackets,
statement, block, routine, file — and Alt+Shift+← narrows it back. It goes by brackets, quotes and indentation, so it
works in every language.

**Surround.** Alt+Shift+S (*Edit › Surround*) puts brackets, quotes, backticks or a tag around each selection or the
word under each cursor, or a block of the language around lines (Nim's `if`, `for`, `try` …, and the blocks of Python,
C, JavaScript, Go, Rust, shell, Lua and Ruby). *Change the surrounding pair…* and *Delete the surrounding pair* are
there too. In vim mode it works like vim-surround: `ys{motion}{char}`, `yss)`, `cs"'`, `ds(`, `S{char}`.

**The undo tree.** An edit after an undo no longer throws away what was undone: it stays as a branch. *Edit › Undo
history…* (Alt+Shift+U) lists every state of the file, with the text at that state beside the list; Enter goes there.
Vim's `g-` and `g+` move through time across branches. Branches are kept with `editor.persistentUndo`.

![Undo history: every state of the file, the branch an edit after an undo left, and the text at the selected state](screenshots/undo-tree-615.png)

**Next-edit suggestions.** With `editor.nextEdit`, change a name — `width` to `size` — and the next `width` shows
*→ size ⇥*: Tab goes there, Tab again changes it, Esc declines. With `ai.nextEdit` the assistant suggests where other
edits lead.

**Every git change in one place.** *Git › Changes…* (Alt+Shift+G) shows every uncommitted change in every file in one
editable view. Ctrl+S writes your edits back to their files; the right-click menu or the palette stages, unstages or
reverts the change at the cursor. *Git: unstage this change* is new for any file too.

![Git › Changes: every change in one editable view, staged or not](screenshots/git-changes-615.png)

**JavaScript, handled by ned itself.** In .js files, an HTML page's `<script>`s and Nim strings: completion after `.`
(the file's classes, the browser's and Node's globals, common values), hover with the MDN or Node.js page, F12, and
problems with the rules `js-brace`, `js-redeclare`, `js-const-assign`, `js-typo`, `js-unused` and `js-eqeq`. An
installed JavaScript language server answers instead (`web.engine`). `ned --lint app.js style.css page.html query.sql`
runs ned's checks on the files named.

**C++, read by ned's own C engine.** In `.cpp`, `.cc`, `.hpp` and `.h` files, and in emits when `nim.backend` is cpp:
completion after `.`, `->` and `::` through classes, namespaces, templates, `auto` and smart pointers; hover and F12
between a method's body and its declaration; errors while you type from `c++ -std=c++17`; members under their class in
the outline. Overloads are not resolved, and `decltype`, concepts and template specialisations are not understood;
clangd is still used first when installed.

**The showcase.** `examples/showcase.nim` has a section for all of this.

## What's new in 6.14.1

- **Scrolling no longer waits for reference counts.** Counts are worked out a little at a time in quiet moments, and
  no longer stop at *300+ references*. A name not exported with `*` is counted only in its own module and the files it
  includes.
- **Quick fixes without Alt+Enter.** Windows Terminal keeps Alt+Enter for full screen, so in WSL the quick fixes never
  opened. Alt+Shift+Enter opens them, as do Ctrl+. (with the kitty keyboard protocol), *Quick fix…* in the right-click
  menu and *Edit › Quick fix…*.
- **`ned --lint` checks the SQL, HTML and CSS in strings.** Rules `sql-args`, `sql-table`, `sql-column`,
  `css-property`, `css-value`, `css-semicolon`, `css-brace`, `html-close`, `html-id`, `html-element`, `html-alt`;
  `.ned/lint.json` and `# ned: ignore[…]` apply.
- **The showcase covers 6.14.** `examples/showcase.nim` now shows the CSS, HTML and SQL in strings, jump labels, the
  picker's preview, the counts, ned's terminal and the hex editor.

## What's new in 6.14

6.14 is about speed, and about the other languages in a Nim project: ned handles CSS, HTML and SQL itself, in their
own files and in Nim strings.

**Faster where you wait.**

- Opening a file of a big program no longer pauses for a quarter of a second, and typing with completion does a
  quarter of the work per key.
- Background work stops each round at 15 ms, and frames no key asked for (the assistant's streaming answer, a
  terminal's output) come at most 60 a second, 30 on a slow terminal.
- Formatting a file again formats only the statements that changed, about ten times faster on a large file.
- `nim.indexCacheProject` keeps the project's own files in the index cache, so a large project reopens sooner.
- git: a new folder is one line in the Git dock (`git.untrackedFiles`), and ned's `git status` takes no lock, so your
  own git commands never find the index locked.
- The assistant sends long tool outputs of earlier questions cut short: fewer tokens at every step
  (`ai.trimOldResults`).

**CSS, HTML and SQL, handled by ned itself.** In their own files, an HTML file's `<style>` and Nim strings (`sql"…"`,
HTML and CSS strings), with hover and completion; an installed language server answers instead (`web.engine`).

- **CSS**: properties, values, colours, units, `var(--…)` and the page's classes and ids; problems for an unknown
  property (*did you mean 'color'?*), a wrong value, a missing `;` and unbalanced braces.
- **HTML**: elements, attributes, their values and the stylesheets' classes; problems for mismatched or unclosed tags,
  an id used twice, an unknown element and an `<img>` without alt text.
- **SQL**: your project's tables (`CREATE TABLE`) and their columns, keywords and functions; problems for an unknown
  table or column, and in Nim **a query given more or fewer values than its `?`**.
- **Formatting HTML and SQL** with Alt+F, *Format the code in this string*, nedfmt and *Format: every file in the
  folder*; text the formatter is not sure of is left alone. The C in an emit is formatted by ned's own C formatter
  when clang-format is not installed.

![SQL in Nim strings: the columns of the table the project creates after `u.`, and a query given more values than its `?`](screenshots/web-614.png)

**Jump labels.** Alt+Shift+J puts a letter or two over every word on screen; type it to move the cursor there, or in
upper case to extend the selection there.

**A preview beside the picker.** On a screen 110 columns wide, Open file, Go to symbol and the buffer list show the
selected file beside the list (`editor.pickerPreview`).

## What's new in 6.13

6.13 is about ned and the terminal it runs in: ned asks the terminal what it can do, and a running ned can be reached
from its own terminal, from git and from scripts.

**`ned FILE` in ned's terminal opens FILE in this ned.** `ned app.nim:42` opens a tab at that line and `git log | ned`
opens the log in a tab; `ned --new` starts another ned. The terminal finds this ned through `$NED_SOCKET`.

**This ned is git's editor in its terminal.** With `terminal.editorEnv`, `git commit` opens the message in a tab and
git waits until you save and close it (Ctrl+S, Ctrl+W); `git rebase -i` and anything that runs `$EDITOR` work the
same, unless you have set `GIT_EDITOR` or `EDITOR` yourself. Elsewhere, use `GIT_EDITOR="ned --wait"`.

**Scripts reach the running ned.** They talk to the one whose project holds the file, or else the one started last:

```sh
ned --remote src/app.nim:120                # open it there
ned --remote-command "Format document"      # a command of the palette
ned --remote-message "deploy finished"
make 2>&1 | ned --remote-problems build     # file:line: lines become problems (sent again: replaced)
ned --remote-get selection                  # file, line, col, selection, word, root, files, text
ned --remote-list                           # the neds running: process, project, files
```

![git commit typed in ned's terminal: the message opens in a tab of this ned, and git waits for it](screenshots/remote-commit-613.png)

**ned asks the terminal what it can do.** *Help › Check setup* shows the answers.

- **The kitty keyboard protocol** (`ui.kittyKeyboard`): bindings for Ctrl+Shift+letters, Ctrl+I apart from Tab,
  Ctrl+Enter and Shift+Enter, and Alt+key without the Esc delay.
- **24-bit colour** is found by asking, not only from `COLORTERM`, which SSH, mosh, `sudo` and tmux often lose.
- **Curly underlines** in the problem's colour (`ui.undercurl`).
- **Light and dark follow the system** with `"theme": "auto"`, in terminals that report the switch.
- **Focus**: files changed meanwhile are noticed as soon as you come back, and while you are away type hints, checks
  and AI suggestions wait, saving battery on a phone (`ui.pauseWhenAway`). `editor.saveOnFocusLost` saves when you
  switch to another window or app.

**Emoji and accents as wide as the terminal draws them.** Widths now follow Unicode 15.1, so ✅ ⭐ 🫠 take two columns
and the cursor no longer drifts on such lines. A letter with its accent is one character, and so are joined emoji such
as 👨‍👩‍👧 where the terminal joins them; Backspace deletes one whole. `ui.graphemes`.

**Smaller things.**

- the line a jump lands on lights up and fades (`ui.jumpHighlight`);
- long jobs show their progress in the status bar, and on the tab in Windows Terminal and Ghostty (`ui.progressBar`);
- the terminal's title shows the file and the project (`ui.terminalTitle`);
- `ui.transparentBackground` leaves the background to the terminal, for a see-through window;
- *Edit: put the selection through a command…* (`sort`, `jq .`), and in Vim mode `:%!sort`, `:'<,'>!cmd`, `:N,M!cmd`
  and `:!cmd`;
- your own commands (`commands` in settings) with `"output": "problems"` turn a linter's `file:line:col: message`
  lines into problems.

## What's new in 6.12

**Nim 3 (Nimony).** *Nim › Nim 3 (Nimony) › This project is Nim 3* sets `"nim.compiler": "nimony"` in
`.ned/settings.json`, and the status bar shows *Nim 3*. Names are then matched case-sensitively (unless a module has
`{.feature: "ignoreStyle".}`); completion, hover and go to definition use Nimony's own standard library; errors while
you type and on save come from `nimony check`, run on a private copy so no `nimcache/` lands in the project, and Run
uses `nimony c -r`. Where ned's engine has no answer, `nimony check --def` and `--usages` give go to definition and
references. Nim 3's syntax and pragmas are understood, and the formatter takes Nimony's own code.

**Porting to Nim 3.** *Nim › Nim 3 (Nimony) › What this file needs* shows what a Nim 2 file must change for Nim 3,
following Nimony's `doc/porting.md` — `except IOError as e`, `raise newException(…)`, `{.async.}`, `x.isNil` and more;
quick fixes, *Fix all* and `ned --lint --fix` make the mechanical changes. *Nim › Nim 3 (Nimony) › Port this file with
AI* has the assistant port the file with Nimony's guides, each edit run through `nimony check` until the file is
clean.

![A Nim 2 file with Nim 3's porting problems in Problems, and the quick fixes of one — Fix all makes the six ned can](screenshots/nim3-port-612.png)

**The hex editor.** A binary file opens as bytes you can edit — offset, hex and text — instead of a read-only dump:
type in hex or as text (Tab switches), insert and delete, undo, and save with the file's permissions kept. Ctrl+G goes
to an offset, Ctrl+F finds bytes or text, and a data inspector shows the numbers at the cursor. Ctrl+C copies bytes as
hex, and *Hex: copy as a Nim array*, *as a Nim string* or *as a C array*. A file of a hundred megabytes scrolls like a
small one.

![A program Nim built in the hex editor: what it is, the proc the cursor is in (shout, of the module app), the bytes and the data inspector](screenshots/hex-editor-612.png)

**Programs and libraries.** For ELF, Mach-O and PE files the hex editor says what the file is and which proc the
cursor is in. *Hex: symbols…* lists the symbols, Nim's procs by their Nim names; *Hex: open the Nim source of the proc
at the cursor*; *Hex: Nim modules by size* shows what makes a program big; *Hex: sections…*.

![Hex: Nim modules by size — the bytes of code each module of the program takes](screenshots/hex-modules-612.png)

**Big files take less memory.** A text file of 8 MB or more is read straight into lines, and takes about a third less
memory.

**Also.** The compiler's warning about a `break` that leaves a block (Nim 2.2) has a quick fix and *Fix all*. The
debugger's call stack, and the hex editor for a program built with `--debugger:native`, name procs as Nim does
(`demo.+`, not `_ZN4demo5plus_E6string6string`).

## What's new in 6.11.2

- **The ▶ on `runnableExamples` works again after a format on save.** It ran nothing when the save re-wrapped a
  comment above the block.
- **The built-in terminal keeps up with a flood of output.** A long scrollback no longer slows it down.
- **Very long lines are as fast as short ones.** Minified JSON, JS and CSS and one-line logs no longer slow the
  screen.
- **The formatter leaves fewer files alone.** It now takes a `using` parameter after one with a default, comment lines
  inside parentheses, a `;` after the last parameter, and Nim 3's keyword routine names and parameter pragmas.

## What's new in 6.11.1

- **Type hints keep up with scrolling.** They are worked out for what is on screen first, then ahead in the direction
  you scroll, and kept, so scrolling with hints on costs about what it costs with them off.
- **Long comments wrapped to the line length.** `nim.format.reflowComments` re-wraps `#` comments of prose as
  `nim.format.reflowDocComments` does `##` ones; commented-out code, examples, lists, links, TODOs and `# ned:`
  directives stay as they are.
- **Doc comment re-wrapping fixed.** Doc comments inside a routine or a type are re-wrapped now, a line starting with
  `code` or *emphasis* no longer ends the paragraph, and lines with `·` or `—` no longer wrap too early.

Tip: the formatter wraps at `nim.format.lineLength` (88 unless your settings or `.editorconfig` say otherwise). A
ruler at another column (`"editor.rulers": [80]`) does not move it: `"editor.rulers": ["lineLength"]` puts the ruler
where the formatter wraps, or set `"nim.format.lineLength": 80`.

## What's new in 6.11

6.11 is about speed on a phone: what each frame sends to the terminal, and what keeps ned from answering a swipe.

- **Scrolling sends only the new lines.** The terminal moves what is on the screen and ned draws only what came in: a
  fifth to a third of the bytes. `"ui.terminalScroll": false` draws every line, for a terminal that gets scroll
  regions wrong.
- **Checks no longer hold up the screen.** This was the slowdown 6.10 brought with big files. The checks now run once
  per text, wait for a pause in typing and scrolling, and read imported modules a file at a time.
- **Background work steps aside.** The compiler's checks and language servers run at a lower priority, extra servers
  start one at a time once you pause, and type hints, reference counts and macro names wait until a swipe stops.
- **A performance report.** *Help › Performance…* (palette: *Performance report*) shows how long frames take and how
  many bytes they send, what kept ned from reading input, memory and background work, and the settings that would make
  ned lighter. `NED_PERF_LOG=file ned …` writes it when ned exits.
- **A slow terminal is noticed.** The minimap steps aside (`"ui.minimap": "auto"`).
- **The screen is redrawn when you come back.** Switching back to Termux, or any terminal that reports focus, repaints
  it; *Redraw the screen* in the palette does it any time.
- **`ned --bench` counts bytes.** It shows the bytes each kind of frame sends.
- **A showcase.** [examples/showcase.nim](examples/showcase.nim) tours what ned does for Nim; each section says what
  to try.
- **Fixed.** Names used only in a format string (`fmt"{who}"`, `&"{n}"`) were reported as never used (since 6.8).

## What's new in 6.10

![Ned's checks with their rules: Alt+Enter on a hint offers its fix, silencing the rule on that line, or turning it off for the project; the problems name each rule](screenshots/lint-rules-610.png)

**Every check has a rule, and the project decides.** `.ned/lint.json` turns a rule off or sets how serious it is
(`{"rules": {"var-let": "off", "deprecated": "error"}, "exclude": ["generated/"]}`), in the editor, nedls and
`ned --lint` alike. `# ned: ignore[var-let]` silences a line (`ignore-next-line` and `ignore-file` too), and Alt+Enter
on a problem offers *Silence var-let on this line* and *Turn off var-let for this project*. See
[Lint](docs/guide/nim.md#lint-the-engines-checks-from-the-command-line-and-in-ci).

**`ned --lint --fix`.** It makes the safe fixes in place — var → let, deprecated names, unused imports, proc → func, a
missing `requires` — or shows them first with `--diff`. `--format:sarif` writes SARIF 2.1.0 for GitHub code scanning;
`--rules` lists the rules.

**Can be a func.** A proc with no side effects is marked, and Alt+Enter makes it a func (or every one in the file).

**The project's own checks.** An `import` of a package the .nimble does not require (Alt+Enter adds the `requires`), a
requirement nothing imports, an exported routine nothing uses, and mistakes in the .nimble itself.

**Nim test coverage in the gutter.** *Test coverage: run* builds and runs the project's tests and colours the line
numbers green where code ran and red where it never did, with gcc and with clang (as on Termux and macOS). The summary
names the procs no test calls.

![Nim test coverage: the line numbers that ran in green, those that never did in red, the summary by file with the procs no test reaches](screenshots/nim-coverage-610.png)

**Concepts.** Hover on a concept lists the project's types that satisfy it, hover on a type the concepts it satisfies,
and *Go to implementation* on a concept lists them.

**The dependency tree shows what the build uses.** Each package is listed at the version nimble.lock, nimble.paths,
atlas or `nimbledeps/` gives it, and why.

**A sharper engine.** It understands chronos' futures that carry what they raise, completes by the expected type in
calls over several lines and in parameter defaults, and shows converters in exception hints.

**The formatter closer to nph, and about 30% faster.** Fixed: the `keep` layout could break a long routine header
after its `*`, and in a few rare cases 6.9 could change what code means.

**`ned --lint` is about twice as fast on a large project.**

## What's new in 6.9

![The engine's hints: a var that can be a let, a parameter never used, a routine that never sets its result, a deprecated name, a library name newer than the package's Nim](screenshots/engine-hints-69.png)

**More of what the compiler does not tell you, while you type.** A `var` that can be a `let` (Alt+Enter makes it one,
or every one in the file), an unused parameter, a routine that never sets its result, a deprecated name (with the
compiler's advice, so its quick fix applies), and a standard-library name newer than the Nim your .nimble asks for.

**Memory layout on hover.** A type's fields with their offsets, sizes and padding, and its size and alignment, for 64-
and 32-bit. When sorting the fields would make it smaller, Alt+Enter reorders them.

![Memory layout on hover: each field's offset, size and padding — sorted by alignment the object would take 16 bytes instead of 32](screenshots/memory-layout-69.png)

**Exception hints.** With `nim.raisesHints` (View › Editor), what a routine can raise is shown after its header and on
hover.

**The package versions your build uses.** From nimble.lock, nimble.paths, atlas or `nimbledeps/`, else the newest
installed version that meets the `requires`; the Nim dock shows each one and why.

**Completion by the expected type.** In an argument, an assignment, a `return` or a comparison, what has the expected
type comes first.

**The formatter closer to nph.** Long statements are laid out more as nph does them.

**One line length everywhere.** Without `nim.format.lineLength` in a settings file, `.editorconfig`'s
`max_line_length` sets where the formatter wraps and the ruler stands, in ned, `nedfmt`, `ned --format` and nedls.
Files the project's `.nph.toml` excludes are not formatted on save or by *Format: every file in the project*.

**The index's memory, capped.** Above `nim.indexMemory` (64 MB by default), the files needed least recently are let go
and read again when needed.

**One Nim per project.** `nim.toolchain` puts the project's Nim first on PATH for every tool ned starts, the terminal
included. With `auto` (the default) it is the Nim the .nimble asks for, when choosenim or grabnim installed it; a
version or a folder can be given instead. The status bar shows the version, and warns when it does not match the
.nimble. *Nim: choose the Nim for this project…*

**`ned --lint`.** `ned --lint` and `nedls --lint` run the engine's checks over files or a whole project without the
compiler, as plain lines, GitHub annotations (`--format:github`) or JSON, with `--staged` and a git pre-commit hook
(`--install-hook`).

**Nim: add a CI workflow.** It writes `.github/workflows/ci.yml` to build and test the project on Linux and macOS with
the oldest and the newest Nim the .nimble allows, with ned's lint and nedfmt's check if you ask.

## What's new in 6.8

![The engine's own checks while typing: an unused import, a literal of the wrong type, a value not used, a field typo, one argument too many, code after a return](screenshots/engine-checks-68.png)

**nedls: ned's Nim engine as a language server.** For VS Code, Neovim, Helix, Zed, Emacs, Kate and Sublime, instead of
nimlangserver or nimsuggest, with what the editor itself offers: completion, hover, definitions, references, rename,
semantic colours, inlay hints, formatting, quick fixes and problems. It starts at about 6 MB. See
[nedls](docs/guide/nim.md#nedls-neds-engine-in-other-editors).

**nedfmt: the formatter on its own.** It takes nph's command line (`--check`, `--diff`, `--out`, `--line-length`,
`--exclude` …, `.nph.toml`) and sets up a git pre-commit hook with `nedfmt --install-hook`. `ned --format` is the same
program. The release binaries include `nedfmt` and `nedls`.

**The formatter checked by Nim's own parser.** With `nim.format.verify` (`nedfmt --verify`), a file whose syntax tree
would change is left as it was. The formatter also comes closer to nph.

**The engine's own checks, at once.** An unused import, a value neither used nor discarded, a literal of the wrong
type, a field typo (*did you mean 'label'?*), the wrong number of arguments, code after a `return`, an unused local:
shown before the compiler's check, in the compiler's words so its quick fixes apply.

**Names a macro makes.** Completion, hover and *Go to definition* know `getConfig` from `makeGetters(Config)`: the
compiler expands a module's top-level macro calls once, in the background.

![Names a macro makes, in completion: getCache from makeGetters(Config, Cache, Client), and the call that made it](screenshots/macro-names-68.png)

**The compiler's answer, once.** Where the engine has none and nimsuggest is off, one nimsuggest run answers that
hover or *Go to definition* and quits.

**The index on disk.** The standard library and nimble packages are read once, not in every session, so the first
answer comes sooner.

**A sharper engine.** It now reads `when` branches left out on this platform, unions and type classes, names a
template declares, `quote do`, forward declarations and `since` blocks, among others.

**Release binaries built with link-time optimisation.** With `-d:lto` they are a little faster, and smaller.

## What's new in 6.7

![Theme editor: every colour with a swatch and its contrast, the hard-to-read ones marked](screenshots/theme-editor-67.png)

**Sign in to GitHub without a password.** When GitHub refuses a push or pull for a login, ned offers the GitHub CLI
(installed if missing) or an SSH key made in the terminal and added for you. ned never sees or stores a token. *Git:
sign in to GitHub*.

**Undo the last commit, pull or merge.** *Git: undo…* (*Undo…* in the Git dock) lists the branch's last steps from the
reflog and undoes one, keeping your uncommitted work. A pushed commit is reverted with a new commit, unless you say
otherwise.

**Checks before a commit.** `git.checksBeforeCommit` (`both`, `format`, `tests` or `off`) formats the staged files and
runs the tests that cover them; when one stops the commit, the message stays open.

**Pull request review comments on their lines.** The review threads of the branch's pull request show on their lines
and in a list; reply and resolve from ned. *Git: GitHub review comments…*

**AI that knows your code.** Inline edits and suggestions get the declarations the code uses, and a suggestion that
names a proc or field that does not exist is not shown (`ai.checkSuggestions`).

**AI: make a failing test pass.** Alt+Enter on a failed check asks the model for a change and keeps it only when the
test then passes.

**AI: plan first, then do it.** *AI: plan a change, then do it step by step…* (or `/plan …` in the chat): the
assistant answers with numbered steps, to do all at once, one at a time, or change. Each step has a restore point
(*Back to before step 3*).

![AI: plan first — numbered steps, then all of them or one at a time, each with a restore point](screenshots/plan-67.png)

**AI on your phone, offline.** *AI: on this device, offline…* installs and starts Ollama (or uses llama.cpp's server)
and downloads a model that fits the device's memory.

**Two language servers at once.** A linter's server runs beside the main one — `ruff`, `golangci-lint-langserver`,
`harper-ls` when installed (`lsp.linters`), or any you name (`lsp.alsoRun`) — with their problems and quick fixes
merged.

**Links, problems on request, formatting as you type.** Language servers' links and URLs in comments open with F12 or
Ctrl+click; servers that send problems only when asked are asked after each change; `editor.formatOnType` lets the
server tidy a line as you type `}` or `;`.

**Format only what you changed, and look first.** `editor.formatOnSaveScope: changed` (*Format: only the lines I
changed*) keeps the formatter's changes to the lines you changed since git last saw the file. *Format: preview the
change* shows it side by side before applying it.

**YAML and TOML formatters.** Built in, for the layout only; the data stays the same. The Nim formatter also comes
closer to nph.

**A theme editor.** *Theme: edit colours…* lists every colour with a swatch and its contrast, marks the hard-to-read
ones and fixes one in a step, in your own copy of the theme.

**Termux in ned's colours.** *Theme: use these colours in all of Termux* writes `~/.termux/colors.properties` from the
theme (your own colours can be put back); `theme.termuxColors` keeps Termux following every theme change.

**Richer Nim colours.** With `nim.richColors`, a `var` is tinted, the module's own variables are bold, deprecated
names are struck through, and `cast`, `addr`, `unsafeAddr` and `ptr` stand out.

![Richer Nim colours: a var tinted, the module's variables bold, a deprecated proc struck through, cast and addr in the warning colour](screenshots/colors-67.png)

**Light by day, dark at night.** *Theme: light by day, dark at night* switches between `theme.light` and `theme.dark`
at `theme.dayStarts` and `theme.nightStarts`.

**Fixes.** Files `include`d into another no longer show every name as undeclared. The Nim formatter no longer joins an
enum's values with the next type after a trailing comma, and keeps a `##` comment on a statement's line where Nim
needs it there.

## What's new in 6.6

![Where ARC/ORC copies: ⧉copy beside each value the compiler copies, and hovering one says why](screenshots/copies-66.png)

**Where ARC/ORC copies.** After a save, ned asks the compiler where it inserted `=copy` and `=dup` and marks each with
**⧉copy**; hover one for why, and how to move instead. *Nim › Inspect › Where ARC/ORC copies*; `nim.showCopies`.

**Tests on save.** Saving a `std/unittest` file, or a module its tests import, runs them in the background:
**✓ passed** or **✗ failed — line 8** beside each `test`, and each failed check on its line with what each side was.
`nim.testOnSave`: `related` (the default), `file`, `off`.

![Tests on save: ✓ or ✗ beside each test, the failed check on its line](screenshots/tests-66.png)

**Postfix completion.** After a `.`, templates that wrap what is in front: `xs.for` → `for x in xs:`, `c.case` → a
`case` with every value of its enum, `v.if` by its type (`o.isSome`, `p != nil`), and `.echo`, `.let`, `.return`,
`.not` and others. `nim.postfixCompletion`.

![Postfix completion: c.case writes a case with every value of the enum](screenshots/postfix-66.png)

**Compile-time values.** The engine works constants out as the compiler would — `0xFF and not 0x0F` is 240,
`255'u8 + 1` wraps to 0 — and shows them on hover of a constant, a selection or a `when`. The `when` branches left out
on this platform are dimmed, as is C's `#if 0` (`editor.dimInactiveCode`).

![A when hovered: its condition's value here; the branch left out is dimmed](screenshots/when-66.png)

**Folder trust.** A folder you open is not trusted until you say so: ned's engines read its code, but nothing in it
runs — not the compiler, nimble, nimsuggest, tests or the program. **Trust** in the notice, or *⛉ Not trusted* in the
status bar, trusts it. `security.folderTrust: off` trusts every folder.

**Less memory.** With many modules open, ned takes about half the memory, at the same speed.

**Fixes.** `defined(…)` follows the system ned runs on (on macOS `defined(macosx)` is true), and `mask and not 0x0F`
is typed as an integer, not a bool.

## What's new in 6.5.1

- **C wrappers written one parameter a line are understood.** They get the C signature beside them, the C
  documentation on hover, the check against the header and Alt+Enter › *Rewrite this wrapper from its C declaration*,
  which keeps the layout.
- **`varargs[T]` for C's `...` is flagged.** It is a Nim array, not C's variable arguments; Alt+Enter rewrites the
  wrapper with C's own parameters and `{.varargs.}`.
- **Lined-up declarations stay lined up with type hints.** With `nim.format.align`, every line of a run moves its `=`
  by the same amount.
- **Zen mode hides git's change marks.** `zen.gitChanges` brings them back.
- **A shorter File menu.** SSH, clone and the workspace are under *Open more*, a file's history and comparisons under
  *This file*, and settings, theme, keys and settings sync under *Preferences*.

The C engine and ligatures came in [6.5](#whats-new-in-65); [C: ned's own engine](docs/guide/c.md) describes it.

## What's new in 6.5

![ned's own C engine: the members after `.` with each field's comment from the header](screenshots/c-engine-65.png)

**C without clangd.** ned has its own C engine, with nothing to install (`c.engine`: `auto` uses it when clangd is not
installed; `builtin`, `clangd` or `both`). It gives members after `.` and `->`, each with its type and comment; hover
with a declaration's documenting comment; F12 through `#include`s, from a header's declaration to the body and back;
references and rename with a preview; signature help and the outline; the C compiler's errors while you type; and
Alt+Enter to add a missing `#include` (`printf` → `<stdio.h>`). It uses a fraction of clangd's memory. clangd stays
the more precise where only the build's configuration decides (`#ifdef HAVE_…`), for declarations made by macros, and
for C++.

![editor.fontLigatures: symbols — ≥ ≤ ≠ and the arrows drawn by ned, the cursor's line as written](screenshots/ligatures-65.png)

**Ligatures.** With `editor.fontLigatures` (*View › Editor › Ligatures*), `font` keeps each operator in one colour so
a terminal with a ligature font joins it, and `symbols` has ned draw them itself in any terminal, Termux too — never
in strings or comments, and the cursor's line shows what is really there.

**Fixes.** After a rename's preview, ned goes back to the file the rename started in.

## What's new in 6.4

**The Nim engine does more, still without nimsuggest.**
- **Parameter names before literal arguments**: `draw(width: 10, height: 20, filled: true)` (`nim.parameterHints`:
  `literals`, `all` or `off`). Never for one-parameter routines, one-letter names, arguments that already are the
  name, or named arguments.
- **Hover on a generic call** shows its instance: on `biggest(3, 4)`, `biggest(a: int, b: int): int   (T = int)`.
- **More types known**: statements after `;`, generic objects built without their arguments (`Box(val: "x")`),
  `if c:value`, `not(…)`, and what a **concept** asks for after a `.`.
- **Organize imports** (*Nim › Refactor*, palette) removes the imports the compiler reports as unused and sorts the
  rest: `import std/[…]`, then packages, then the project's own modules.
- Alt+Enter on an undeclared name also offers the project's module that exports it (`import ./extra`).
- F12 on a name inside `defined(…)` explains the define.

## What's new in 6.3

![A Nim wrapper of C: the C declaration dimmed after each importc proc, and the hover with the C documentation from the header](screenshots/c-docs-63.png)

**C wrappers explained.**
- **Hover and completion show the C documentation**: the declaration from the header or the `{.emit.}`
  (`char *getenv(const char *name)`), with the comment above it. Standard library procs that come from C use your
  system's headers.
- **The C signature beside each wrapper**, dimmed (`nim.cSignatureHints`), so a wrong type stands out.
- **`header: "…"` and `importc: "…"` have colours of their own.** Hover on a header tells where it is and what it
  declares, and F12 opens it; on `importc: "…"`, hover shows the C declaration.
- **Alt+Enter › *Rewrite this wrapper from its C declaration*** uses the Nim types C asks for (`size_t` → `csize_t`,
  `char *` → `cstring`) and keeps the pragmas.
- **New wrappers by completion**: `proc ` and part of a C name, in a file that uses headers, offers the functions not
  wrapped yet and writes the whole wrapper.

**Formatter settings** (the layout ones start out as nph does):
- `nim.format.lineLength` (88); `nim.format.params`, `nim.format.arguments` and `nim.format.collections`: `fit` (as
  nph), `onePerLine` (when too long), `always` (with two or more) or `keep` (your line breaks);
- `nim.format.imports` (`sort`, or `merge` into `std/[os, strutils]`), `nim.format.align` (field types and `=` lined
  up), `nim.format.reflowDocComments` and `nim.format.maxBlankLines`;
- `nim.formatEmitC` formats the C in `{.emit.}` with clang-format and your `.clang-format`, or else with ned's own C
  formatter, which also formats `.c` files;
- `editor.formatOnPaste` (`indent`, `format` or `off`): pasted code takes the indentation of where it goes; at column
  0 it stays as copied.

**Clone and initialize.** *File › Clone from a link…* (`g` on the Welcome screen) takes any link as copied (GitHub,
GitLab, Codeberg, `/tree/branch`, `user/repo`, ssh), offers *Latest version only*, opens the README and offers
`nimble install --depsOnly`. A link with a password or token in it is refused. *Initialize a repository here* is in
the Git dock, the File tree's menu and the palette; a new Nim project gets its first commit, and git asks for your
name and email once if needed.

**Eight new themes** (Alt+T): `frankincense`, `desert-dusk`, `lagoon`, `sea-glass`, `paper-ink`, `rose-quartz`, and
two old terminals, `amber-crt` and `green-phosphor`.

![The eight new themes](screenshots/themes-63.png)

**Also.** TODO, NOTE and error marks on the scrollbar move with their code as you type. The repository has
CONTRIBUTING.md, SECURITY.md and issue templates.

## What's new in 6.2

![A dialog with a soft half-cell shadow and rounded buttons, the Git dock's actions in the text colour](screenshots/desktop-62.png)

**A calmer, more desktop-like look.** Popups, menus, dialogs, toasts and tooltips cast a soft half-cell shadow that
leaves the text under it readable. Buttons look rounded, and so does the search box in the title bar. The header of
the dock or panel with the keyboard is tinted with the accent colour. The Git dock's actions, the outline and the
assistant's suggestions are in the text colour, with coloured icons.

**The mouse pointer changes as in a desktop app** (a hand, an I-beam, the arrow) in terminals that allow it: kitty,
foot, WezTerm, Ghostty, xterm. `ui.pointerShapes: false` leaves it alone.

**Also.** The completion list's documentation goes above or below the list, not over a dock, when there is no room
beside it.

## What's new in 6.1

![Semantic colours: parameters in a colour of their own, fields and calls after a dot told apart, a template in the macro colour](screenshots/semantic-61.png)

**Smarter colours.** Inside a routine, its **parameters** and `result` have a colour of their own. After a dot, a
**field** and a **call** look different (`p.name` · `p.size(n)`). **Templates and macros** take the macro colour, and
a **module name** before a dot the type colour.

**Faster colours.** What the imported modules declare is worked out once and kept; after an edit only the file's own
names are gone through again. *Nim: language server status* shows how long the last update took.

**More types known**: types and routines declared inside a routine, a receiver that starts on an earlier line,
arithmetic on two number types (`uint8 * uint32` is a `uint32`), operators on other types (vectors), types as
receivers (`float32.high`), `newException(…)` as a `ref`, and an integer converted to an enum with a dot (`i.Color`,
offered after `i.`).

## What's new in 6.0

**ned is a project now, not one file.** The 53 000 lines of `ned.nim` are about 215 files in `src/`, one subject each
([the layout](docs/guide/building.md#the-source)), so finding your way around or sending a patch is easier. Still the
standard library only and one binary: `nim c -d:release src/ned.nim`, or `nimble release` / `nimble termux` /
`nimble install`.
- The parts that stand on their own are **modules** other programs can use: the Nim index (`ned/nim/index`), the
  formatters (`ned/format/formatters`), the regular expressions (`ned/editor/regex`) and `ned/core/text`.
  `import ned/nim/index` gives you ned's Nim engine as a library.
- The engine follows `include`s up to three folders up, and a forward declaration with its body in another file shows
  as one routine.

![ned editing its own source: hover on a routine declared in another file of the module](screenshots/own-source.png)

**The tests are in the repository** ([tests/README.md](tests/README.md)). `nimble test` runs the unit tests;
`tests/build/cross.sh` builds for Linux, macOS and Android from one machine (with zig).

**Libraries open read-only.** Files of the standard library and of installed nimble packages, where go to definition
often lands, open read-only, so a stray key and a save cannot change them for every project. A click on *Read-only* in
the status bar (or palette › *File: allow editing this file*) unlocks one. The project you have open is never locked.
`files.protectLibraries: false` turns this off.

**Fixes.** The temporary files of a ned that was killed are removed at the next start. vim's `f` `t` `F` `T` `;` `,`
and `b` now work with the cursor past the end of a line that a change elsewhere had shortened.

## What's new in 5.29

![clangd's fixes named on the line — "Alt+Enter: insert ';'" — and the quick fixes for a call to a misspelled function](screenshots/clangd-fixes.png)

**clangd's "(fix available)", made usable.** The line says what Alt+Enter will do —
`● Expected ';' at end of declaration — Alt+Enter: insert ';'` — and a click or tap does it. Alt+Enter finds the fix
on the line where the `;` is missing. Each fix is titled by what it does (*Change prinf to printf*) and listed once,
the server's preferred one first. F8 and the Problems panel name the fix too.

**runnableExamples.** A comment after `runnableExamples:` no longer hides the block from the ▶ and *Run the examples
here*. Examples that pass show what they print in a popup.

**Menus fit a 10-inch screen.** A menu taller than the screen scrolls (wheel, arrow keys, PgUp/PgDn, or ▲ ▼ on its
frame). The Nim and Git menus group their tools in submenus: *Run*, *Inspect*, *Refactor*, *Documentation*,
*Toolchain*, *Language server* · *Stage*, *History*, *Compare* …

**Five themes from vim** (Alt+T): `molokai`, `jellybeans`, `iceberg`, `sonokai` and `papercolor-light`.

## What's new in 5.28

![Type hierarchy from ned's own engine: what Circle inherits from, and Find references on a `+` for vectors — `1 + 2` is not one of them](screenshots/type-hierarchy.png)

**nimsuggest is off by default.** Completion, hover, go to definition, implementations, type hierarchy, references,
rename, signature help, type hints, the outline and quick fixes come from ned's own index; errors while you type and
macro expansion from `nim check` on the unsaved text. Nothing has to start or compile the project first.
`"nim.nimsuggest": true` brings nimsuggest back as a second opinion; how the two compare is in
[the Nim IDE section](docs/guide/nim.md#nim-ide-the-built-in-engine).

**Navigation without a language server.** *Type hierarchy* (palette) shows what an object type inherits from, up to
`RootObj`, and every type in the project that inherits from it. Go to implementation lists a `method`'s overrides, or
the types that inherit from a type. Hover, go to definition and Find references on an operator pick the overload the
operands' types call, so your `` `+` `` for `Vec` does not list `1 + 2`. In `Vec(x: 1)`, `x` is the field for Find
references and rename.

**Code actions (Alt+Enter).** *Fill in the missing fields* of an object constructor, inherited ones too, each with a
value of its type or its declared default. *Write its body* for a forward declaration nothing implements yet: its
header with `discard`, at the end of the file.

## What's new in 5.27

![Hover on a template call: what it becomes there, its arguments in place](screenshots/hover-template.png)

**Templates and macros expanded, without nimsuggest.** **Alt+M** on a template call shows it expanded at once, with
the arguments in place (`sq(3 + 1)` is `(3 + 1) * (3 + 1)`), and hover shows the same: *Here it becomes:* … Alt+M on a
macro call shows its expansion from `nim check --expandMacro` on the unsaved text.

**Completion.** Where an argument starts, the parameters not given yet are offered by name (`timeout = `). `of` in a
`case` on an enum, and `x == `, offer its values. The code inside `fmt"{…}"` and `&"{…}"` completes. Signature help
picks the overload that fits the arguments so far.

**Hover.** A constant shows its value (`const BufSize = 4 * KiB + 16` shows `= 4112`). Alt+H on a selection shows its
type.

## What's new in 5.26

![Errors from the compiler on the unsaved text, without nimsuggest: an undeclared field, and a misspelled proc with the name meant](screenshots/typing-errors.png)

**Errors while you type, from the compiler.** After a pause in typing, ned runs `nim check` on the unsaved text in the
file's own folder, with the same imports, `nim.cfg`, `config.nims` and nimble packages as the saved file, so the
errors are the ones `nim c` would give. A project file shows them as soon as it opens. A big project whose check takes
over 10 s is checked by nimsuggest instead, when it runs (`"nim.liveDiagnosticsFrom"`: `auto`, `compiler` or
`nimsuggest`).

**Misspelled names, at once.** A name nothing declares that is a letter or two from a declared one is marked
(`toal` → *did you mean total?*), and Alt+Enter changes it. Templates, macros and `when` branches are left alone.

**Quick fixes.** An undeclared field offers the closest members (*Change to toUpperAscii*). The fixes for the line's
problem come before the refactorings, and *Change signature* and *Inline* are offered for the project's own procs
only. *Change to …* no longer suggests words from strings and comments.

**Fixes.** Type hints show again after a name the compiler says is unused, and are finished when they first run out of
time. `when defined(windows) and not someConst` is known to be false.

## What's new in 5.25

![Types from ned's own engine on lets, vars and loop variables — and on what a template declares (`vec2`); Find references marks both uses of `p` on line 19](screenshots/type-hints-everywhere.png)

**Types everywhere, without nimsuggest.** ned's own engine knows far more types, for type hints, completion and hover:
loop variables (through `items`, `pairs` and aliases); values over several lines (`if`, `case`, `try:`, `block:`);
literals and conversions (`array[2, Person]`, `10'i64`, `5.Natural`); arithmetic as Nim types it; overloads by all
their arguments (`sock.recv(10)` is a `string`, `recv(sock, buf, 10)` an `int`); generics bound by a later argument or
an alias; routines inside routines, an async proc's `result` and a macro's `untyped` arguments; and what a template
declares (`genVecConstructor(vec, Vec, float32)` makes `vec2`, `vec3` …). `when defined(…)` follows `nim dump`, so a
library's branch for another configuration is left out. Type hints stay on a long line that wraps.

**Completion** offers the pragmas the file defines (`{.pragma: rtl, …}` → `{.rtl.}`) and, after `x.` on a number, the
distinct number types in scope.

**Find references** lists a line once, with each use on it marked.

![Nim: profile — each proc's share of the time beside it, each call's share at the end of its line, the slowest procs in the panel](screenshots/profile-lines.png)

**Profiler.** *Nim: profile* builds the program with a sampling profiler, runs it, and shows each proc's share of the
time beside it (`◷ 64.0% of the time · 64.0% in itself`), each call's at the end of its line (`▆ 64.0%`), and the
slowest procs in the panel. *Nim: show the profile* brings it back and *Nim: hide the profile* takes it away. A file
changed since shows no numbers.

![A CSV file as a table: columns lined up, sorted by population, the column's sum, smallest, largest and mean](screenshots/csv-table.png)

**CSV and TSV files as tables.** The columns are lined up on screen without changing the file
(`"csv.alignColumns": false` turns it off), and the breadcrumbs name the cursor's column. *CSV: sort by this column*
(and *…, largest first*) sorts numbers by value and words in reading order, the heading row kept on top. *CSV: summary
of this column* gives the count, the number of different values, and the sum, smallest, largest and mean, or the most
common word.

## What's new in 5.24

![A logpoint (◇) printing its values in the Debug panel, and a stop each time `total` changes, old value → new](screenshots/debug-logpoints.png)

**Logpoints.** *Debug: logpoint on this line…* prints a message such as `{o.qty} × {o.price} = {cost}` in the Debug
panel each time the line runs, without stopping. A ◇ marks the line; F9 removes it. They work with gdb (Nim) and
through the Debug Adapter Protocol, and are kept with the folder's session like breakpoints.

**Stop when a value changes.** *Debug: stop when this changes…* on a variable or a field stops the program right after
it changes: *‖ stopped: total changed (6 → 11) at shop.nim:10*. With gdb a global can be watched before the program
starts; through DAP the adapter needs data breakpoints. The Debug panel lists them under *Stop when it changes*; Enter
removes one.

**Format everything.**
- Built-in formatters for **JSON, Markdown and CSS**, used when no other is installed. Only the layout changes; JSON
  keeps its comments and its numbers as written.
- ***Format: every file in the project…*** (or *Format the files in this folder…* in the Files dock) lists the files
  that would change: format them all, compare one side by side, or leave it. The toast's *Undo* puts everything back.
  What git ignores and build folders are left out.
- Alt+Enter › *Format the JSON in this string* (palette: *Format: the code in this string*) formats the JSON, CSS,
  HTML, SQL or emitted C in a Nim string.
- `"editor.formatOnSaveLanguages": ["nim", "json"]` formats on save for those languages only.
- `ned --format src/ README.md` formats files and folders from the shell; `--check` only lists them.

**Nimble: dependency tree.** What the project requires, what each of those requires in turn, and the versions
installed, with ✗ for one missing or too old. Enter opens a package's `.nimble` file, or offers `nimble install` for a
missing one.

**Fixes.** *Nim: exports nothing uses…* stops when ned's terminal goes away. In a debug session, an object passed by
pointer shows in the Variables list instead of as a bare address.

## What's new in 5.23

![Type hints from the built-in engine in a file that another one includes; completion after `result.` offers the includer's fields](screenshots/type-hints-include.png)

**Files pulled in with `include` are understood.** In a file another one `include`s, completion, hover, go to
definition, type hints and reference counts use the includer's imports, its declarations (the private ones too) and
its other include files, and F12 reaches a sibling include file. ned looks for the includer in the file's folder and
the one above it.

**Type hints from ned's own engine.** A `let`, `var` or `const` written without a type shows it after the name, at
once, also with `"nim.nimsuggest": false`. `"nim.typeHints": "nimsuggest"` takes them from nimsuggest as before;
`editor.inlayHints` turns them off.

**More types known**: `system`'s file procs (`readFile`, `stdin`, `open` …), `/` of two integers, `a ..< b`, a
literal's methods, overloads by their number of arguments, generic constraints, and what the project's config defines,
for `when defined(…)`.

**Fixes.** A character literal holding a quote (`'"'`) could turn the rest of the file into a string. After a save,
nimsuggest could go on reporting errors already fixed. Go to definition, references and rename could pick the wrong
column when the name was also inside an earlier word on its line.

## What's new in 5.22

**A big file shows at once.** A 48 000-line file is on screen about five times sooner, and the Nim engine reads a file
about a third faster.

**Less memory in big projects.** With a file of the Nim compiler open, ned now holds about 26 MB instead of 100 MB.
Forward declarations no longer get a reference count.

**Format from the shell.** `ned --format file.nim …` formats Nim files in place with the built-in formatter;
`ned --format --check …` only lists the files it would change and exits with 1, for a CI step or a git pre-commit
hook.

**Startup times.** `ned --startup-time [file …]` starts as usual, quits once everything has settled, and prints the
time of each step, the memory and what the Nim engine has read.

## What's new in 5.21

![The Git dock while bisecting — Good, Bad, Skip — beside the history of one proc's lines](screenshots/git-bisect.png)

**Remote folders, finished.** What ned runs on the server goes through `sh`, so any login shell (fish, tcsh, nushell
…) works. Every 10 seconds (`remote.autoSync`), and at once after Run, a task or one of the assistant's commands,
files changed on the server are copied into the local copy, and tabs without unsaved changes reload. The assistant's
commands run on the server once your saves are there, and Run waits for saves still on their way.

**Git.**
- **History of these lines** (right-click › Changes, the Git menu, the palette): every commit that changed the
  selection, or the Nim proc the cursor is in, with the diff of just those lines.
- **Find the commit that broke it (bisect).** Say *Good*, *Bad* or *Skip* in the Git dock at each step, or give a
  command that succeeds when it works (`nimble test` …) for git to run. ned then shows the commit and takes you back
  to where you were.
- **Worktrees…**: list, open, add to the workspace, make one for a branch, remove, prune.
- **Submodules…**: each with its state; update one or all, record its current commit, add one. Checked-out submodules
  show in the Git dock as repositories of their own.

**Fixes.** The built-in Nim formatter no longer refuses files with "would change the block structure" over a long
comment after a field list or a one-line `type X = object`. Also fixed: a comment between a type section's members,
`const ## doc` on one line, import paths written `.. / x`, and a `;` before `)`.

## What's new in 5.20

![The assistant's edit had an error: nim check told it, it fixed it, and the second check is clean](screenshots/agent-check.png)

**The assistant checks its own edits.** After the agent edits files, ned checks them — Nim with `nim check` on the
module and the project's main module, Python with ruff or py_compile, JavaScript with `node --check`, shell with
`bash -n`, Rust with `cargo check`, Go with gofmt, C and C++ with `-fsyntax-only` — and the errors go back with the
result, so the model fixes them before it says it is done. The chat marks each edit *checked ✓* or *▲ 2 errors*.
`ai.checkEdits: false` turns it off.

**Tests from the AI, kept only when they pass.** *AI: write tests* on a Nim file (palette, the editor's AI menu, or
*Write tests* in an empty chat) has the model write `tests/test_<module>.nim` with std/unittest. ned compiles and runs
it first: errors go back to the model (twice at most), failing tests are taken out and open in a tab with what they
got (*twice(-1) was -2*), and the rest are kept only when they pass. The Tests dock shows ✓ beside each. For other
languages *Write tests* asks in the chat, as before.

## What's new in 5.19

![Reference counts after each proc, and Change signature's plan: a parameter added, every call follows](screenshots/refactor.png)

**Reference counts.** Each top-level proc, func, template, macro, iterator and type in a Nim file shows a dimmed *3
references*; a click lists them. An export nothing uses says *no references* in yellow, and *Nim: exports nothing
uses…* lists all of them in the project. `nim.referenceCounts: false` (or *Nim: toggle reference counts*) turns the
counts off.

**Change signature.** Alt+Enter on a proc or a call of it › *Change signature of scale…* opens its parameters one per
line, to reorder, rename, retype or drop, or to add one with a default or with `:: value` for the existing calls; the
last line is the return type. **Ctrl+S** rewrites the declaration and every call in the project, and lists what it
cannot rewrite safely.

**Inline a proc.** *Inline twice* replaces each call of a proc, func or template whose body is one expression with
that expression, adds the imports it needs, and lists the calls it leaves. Then ned offers to delete the declaration.

**Move to another module.** *Move scale to another module…* moves a top-level proc or type, with its comments and
imports, to a project file or a *New module…*, exporting and importing as needed. If it uses private things of its
module, ned says which to move first.

All three are under *Refactor* in the editor's right-click menu and in the palette (*Nim: change signature…*, *Nim:
inline this proc*, *Nim: move to another module…*). Their edits land in tabs: Ctrl+Z undoes one file's, *Save all*
saves them.

**Fixes.** Go to definition, hover and references work on a parameter in a one-line routine. Lists where you pick one
of several things (saved macros, a terminal's commands, debugger watches, C headers to wrap, MCP resources) acted on
the last one.

## What's new in 5.18

![Two terminals side by side: each command marked, a failed one in red, and the one Ctrl+↑ went to](screenshots/terminal-commands.png)

**Keyboard macros.** **Alt+Shift+R** starts and stops recording, **Alt+Shift+M** plays it back. *Edit › Macros* plays
it N times, on each selected line or to the end of the file, in one undo step. *Save the last one…* makes it the
command *Macro: <name>* (give it a key in settings › `keys`), kept in `macros.json` and carried by Settings sync. vim
(`qa` … `q`, `@a`), Emacs (`C-x (` … `C-x )`, `C-x e`) and Helix (`Q`, `q`) keys work too. While recording, completion
lists open only with Ctrl+Space.

**The terminal knows your commands** (bash, zsh and fish). A **●** marks each command, **red when it failed**, and the
panel header shows the last result (*✓ 1.2 s* or *✗ exit 2*). **Ctrl+↑ / Ctrl+↓** go from one command to the next;
**Alt+Enter** or a click on the ● offers *Copy its output*, *Copy the command*, *Run it again* and *Open its output in
a tab*. The palette has *Terminal: commands…*, *run the last command again* and *copy the last command's output*.
`terminal.shellIntegration: false` turns it off.

**Two terminals side by side**: ◫ in the panel header (or *Terminal: split*); **Ctrl+PgUp/PgDn** moves between them.

**Fixes.** A drag in the terminal selects text, for *Copy* or Ctrl+Shift+C. Ctrl+\\ in *Open shell full screen* could
close ned. Clearing a scrolled-back terminal no longer gives an internal error. Enter in quick open (Ctrl+P) before
the files were listed made an empty file; now it says to wait a moment.

## What's new in 5.17

![A workspace of two repositories: the Git dock lists both and follows the open file](screenshots/workspace-git.png)

**Git for every folder of a workspace.** When the folders of a workspace are separate repositories, the Git dock lists
them under **REPOSITORIES**, with their branch, changes and what is to push or pull, and works on the one you click or
the one of the file you are editing. The title bar and the commit box name it; the Files tree marks changes in all of
them.

**Remote folders over SSH: git on the server.** Deleting, renaming and moving in the Files tree, new files and
folders, the assistant's changes, *Add to .gitignore* and a project-wide replace happen on the server too. In a remote
repository, git runs **on the server** (*git on devbox*), and what it changes is copied into the local copy; the
gutter's marks, blame and history come from there. A folder that is not a repository yet gets *git init on devbox*.
*Remote: pull the latest files* also removes files deleted on the server, never one with changes here.

**Also.** *Reveal file in tree* switches the left dock to Files. The breadcrumbs of another workspace folder's file
start at that folder's name. **P** and **L** in the Git dock push and pull. Fixed: *Nim: language server status* could
crash ned with nimlangserver.

## What's new in 5.16

![Alt+Enter on a Nim error: fixes worked out from the compiler's message, beside the line](screenshots/nim-quickfixes.png)

**Quick fixes from the Nim compiler.** Alt+Enter on a Nim error or warning offers fixes worked out from its message:
`let` to `var` for `cannot be assigned to`; `discard` for an unused result; a conversion (`float(i)`, `$n`,
`parseInt(s)`) for a type mismatch; close names, *Export hidden from other.nim* or *Create proc totl(a: auto): string*
for an undeclared identifier; close fields for an undeclared field; the missing `of` branches; `{.raises: […].}` or
catching it for an unlisted exception; *Use m1.counter* for an ambiguous name; the new name for a deprecated one;
`except CatchableError:` for a bare `except:`.

**Fix all like this in the file** fixes unused results, bare `except:`, unused imports and deprecated names in the
whole file, in one undo step.

**AI fixes checked by `nim check`.** *Fix with AI* applies the model's answer only when `nim check` shows the error
gone and nothing new wrong. Otherwise the model gets one more try, and then a toast shows the error and offers *Apply
it anyway*.

**Also.** The quick-fix list opens beside the line it fixes. Fixed: an internal error when a hover answer came back
after you switched tabs or deleted lines.

## What's new in 5.15

![HTML, CSS, SQL and JSON in Nim strings, checked by their language servers](screenshots/strings-lsp.png)

**Code in strings gets its language server.** The HTML, CSS, SQL and JSON in Nim strings get errors on the `.nim`
line, completion, hover and fixes on Alt+Enter from that language's server: `vscode-html-language-server`,
`vscode-css-language-server` and `vscode-json-language-server` (`npm install -g vscode-langservers-extracted`), and
`sqls` or `sql-language-server`. strformat's `{expressions}` count as a value.

**C in emits.** clangd also gets the `-D` defines from `{.passC.}`, `config.nims`, `nim.cfg` and the `.nimble` file,
and sees one-line emits and the array form.

**Also.** `.html` files use `vscode-html-language-server` when it is installed. The CSS server's quick fixes work in
`.css` files. Pictures in documentation popups are left out instead of shown as base64 text. A language server that
prints other output besides its messages no longer loses replies.

## What's new in 5.14

![clangd inside an emit: member completion, and an error with its fix](screenshots/emit-clangd.png)

**C in `{.emit.}` through clangd.** With clangd installed (Termux: `pkg install clang`; Debian/Ubuntu:
`apt install clangd`), the C a Nim file emits gets completion, errors while you type with clangd's fixes on
**Alt+Enter**, parameter hints, hover and F12. clangd sees `nimbase.h`, the headers of the file's `header:` pragmas
and the project's include folders. Without clangd, or with `"nim.emitClangd": false`, the 5.13 features work as
before.

## What's new in 5.13

![C in an emit: an error from the C compiler on its line, and completion from the header it includes](screenshots/emit-c.png)

**C inside `{.emit: """…""".}` edits like C.**
- Enter after `{` indents, a typed `}` moves back, and **Ctrl+/** comments with `//`. HTML, SQL and Markdown code
  blocks inside strings get their own comments and indentation too.
- On save, the C compiler checks the module's C (`-fsyntax-only`) and its errors show on the emit's lines. A build or
  Run maps its C errors back the same way, not into nimcache.
- Completion from the emit, its `#include`d headers, the file's `header:` pragmas, Nim's `nimbase.h`, and C keywords
  and types. Hover on a C name shows its declaration.
- F12 goes between an `{.importc, nodecl.}` proc and its C in the emit, and from a use inside the emit to its
  definition.
- Wrappers are checked against the C functions the emit defines, as against headers.

## What's new in 5.12

![A wrapper checked against its C header: the warnings in Problems, and the C declaration in the hover](screenshots/c-interop.png)

**Nim and C, side by side.**
- **F12 on an `importc` declaration** opens its C prototype, and hover shows it. Headers are found as the C compiler
  finds them, with the `-I` flags in `config.nims`, `nim.cfg`, the `.nimble` file and `{.passC.}`.
- **Wrappers are checked against their headers** on open and save: the number of parameters, a missing `{.varargs.}`,
  `cint`, `cfloat`, `csize_t` and `cstring`, a value where C takes a pointer, and a result where C returns nothing.
  Each warning has its fix on **Alt+Enter**; `"nim.checkWrappers": false` turns the check off.
- **Completion** in `header: "…"` and `importc: "…"`.
- *Nim: wrap a C header (c2nim)…* writes a Nim module with c2nim or sets up futhark, and offers to install c2nim.
- *Nim: write compile_commands.json for clangd* lets clangd understand the project's own `.c` files.

**Fixes.** *Find references* on a name used everywhere could freeze ned for minutes; it now answers in a few seconds.
On a very large project it stops after 10 s and says the list is incomplete, and *Rename* then refuses. No more
internal errors on typing `{.` on a proc's line, on a click or Enter as the completion list got shorter, or on inlay
hints just after the text got shorter.

## What's new in 5.11

![C in an emit, SQL, and an HTML page in a strformat string, each coloured as its own language](screenshots/embedded-code.png)

**Code inside Nim strings is coloured as its own language**: `{.emit.}` as C (or C++, JavaScript, following the
backend); `sql"…"`, `re"…"`, `peg"…"` and `parseJson("…")`; the `{expressions}` of `fmt"…"` and `&"…"` as Nim; and a
triple-quoted string that starts with an HTML tag or with `SELECT`, `INSERT` … (HTML or SQL). Mark any other string
with `#[html]#`, `#[c]#`, `#[sql]#`, `#[css]#` …, or colour what you pass to your own procs with
`"nim.embeddedLanguages": {"render": "html"}`. Nim's completion and hover stay out of that code.

**Also coloured by language**: Markdown code blocks, `<script>` and `<style>` in HTML files, and Nim
source-code-filter templates (`.nimf`, or `#? stdtmpl` on the first line).

**Fixes.** Everything after a multi-line `{.emit: """…""".}` was coloured as one long string. An error stayed after
you fixed it and saved, until *Nim: check project*; now every file that shows an error from a build or check is
checked again on save.

## What's new in 5.10

![Debugging JavaScript with vscode-js-debug: the variables at the end of each line, the Debug panel below](screenshots/js-debug.png)

**Debugging.** JavaScript and TypeScript debug with **vscode-js-debug** (Node), and C, C++ and Rust with **codelldb**
as well as gdb and lldb-dap. *Debug: check the debugger for this file* says what F5 will use and how to get it;
*Debug: choose…* picks another and *Debug: install…* installs one.

**Large-file mode** for files of 16 MB or more, or with a line of 10,000 characters or more: no soft wrap, language
server, minimap or word highlight, so scrolling and typing stay instant. *Large file mode* in the palette turns it off
for one file; `editor.largeFileSize` and `editor.longLineLimit` set the limits.

**Send to REPL.** **Shift+Enter** sends the selection, or the statement at the cursor with its block, to the
language's REPL in a terminal tab: `inim` (else `nim secret`), the project's `.venv` Python, `ipython`, `node`, `tsx`,
`irb` or `lua`. In a file with `# %%` cells it runs the cell and moves to the next. *REPL: send the proc / the whole
file* sends larger pieces.

![# %% cells sent to the Python REPL with Shift+Enter](screenshots/repl-cells.png)

**Merge editor** (*Git: merge editor*, or the button when a file with conflicts opens): ours and theirs above the
result, which is the file itself, with *✓ Accept*, *Accept both* and ◀ ▶ between conflicts; then *Save and stage*.

![The merge editor: ours and theirs above, the result below](screenshots/merge-editor.png)

**Spell check** in Markdown and commit messages, and with `"editor.spellCheck": "on"` in comments and strings; names
your code uses, URLs and paths are left alone. **Alt+Enter** on a word suggests the spelling, adds it to your
dictionary or ignores it. ned reads hunspell dictionaries or a word list; *Spell check: download a dictionary…* gets
one of 14 languages.

![A misspelled word in Markdown and its quick fixes (Alt+Enter)](screenshots/spell-check.png)

**Tests and coverage.** testament spec files, PHPUnit, dotnet test and Gradle/Maven tests get the ▶ in the gutter and
the test explorer. *Test coverage: run* colours the line numbers in Python, Go, Rust and JS/TS; *Load an lcov file*
reads any other tool's report.

**Nimble.** *newer versions of the dependencies* lists the packages with a newer release; choosing one, or all, moves
the `requires` up and offers `nimble install`.

**New languages.** Kotlin, C#, PHP and SQL, with colours, comments, run commands, and language server and formatter
defaults.

**AI and MCP.** An MCP server's **prompts** are `/server:prompt` commands in the chat, and its **resources** attach
with `@server:uri` (typing **@** lists them). Fixed: `@file`, `@diff` and the other mentions were dropped whenever the
current file was sent too.

**Emmet for CSS.** In a rule, Tab expands `m10-20`, `w100p`, `df`, `posr`, `jcsb`, `c#333`, `fz14!` and the like.

**Settings sync.** Settings, key bindings, snippets, themes and dictionary words go to one file, to export and import
or to push and pull from a private git repository. API keys, tokens and MCP environment values never leave the device.

**Emacs and Helix key bindings** besides vim (*Key bindings: default · vim · emacs · helix…*).

**Accessibility mode.** Plain ASCII for every frame, bar, symbol and icon, so screen readers read the screen sensibly;
letters beside the colours; no minimap, and a high-contrast theme.

**Multi-root workspaces.** *Workspace: add a folder…* puts another folder beside the project in the file tree, quick
open, project search and the language servers. *Save as…* writes a `.ned-workspace` file, and VS Code's
`.code-workspace` files open too.

**Remote folders over SSH.** *Remote: open a folder over SSH…* (`user@host:/path`, or a `Host` from `~/.ssh/config`)
copies the folder to edit here. Every save goes to the server, and the terminal, Run, tasks and tests run there. One
shared ssh connection asks for a password once, in the terminal. *Pull the latest files* brings in changes made on the
server.

**Fixes.** A sibling folder such as `work2` next to `work` is no longer taken as part of the project. A debug adapter
no longer stays behind as a zombie process.

## What's new in 5.9

**Debugging in more languages.** F9 and F5 now work in Python, C, C++, Rust and Go too, with the same Debug panel,
conditional breakpoints, watches and run to cursor: **debugpy** for Python, **gdb** 14 or newer or **lldb-dap** for
C, C++ and Rust (built with debug information first), **delve** for Go. `"debug.adapters"` sets another adapter per
language. While stopped, each line shows the values of the variables it uses (`"debug.inlineValues"`), in Nim too.

**Language servers do more.** *Go to type definition*, *Go to implementation* and *Type hierarchy* (Go menu, Nim
included); the server marks the uses of the symbol under the cursor; folding follows its ranges; **Alt+F** on
selected lines formats them through the server. When a language has no server, ned says once which to install, with
an **Install** button. New defaults for Ruby, JSON, YAML, Markdown, CSS and Dockerfile.

**Your own languages.** The `"languages"` setting gives a language ned does not know its colours, comments,
indentation, run command, formatter and language server, or changes one it does.

**Tests in Python, Go and Rust.** pytest, `go test` and `cargo test` get the ▶ in the gutter and the test explorer.

**Refactors.** Alt+Enter and Nim › Refactor offer *extract into a variable* (Nim, Python, JS/TS, Go, Rust, Lua,
Ruby), *inline a variable*, `"Hello, " & name & "!"` → `fmt"Hello, {name}!"` and *evaluate at compile time*.

**Problems with their code.** *Problems: all of them with their code* puts every error and warning, with the lines
around it, in one editable multibuffer.

**HTML.** Renaming an opening tag renames its closing tag. Tab expands **Emmet** abbreviations such as
`ul>li.item$*3`.

**AI.** `"ai.mcpServers"` gives the agent the tools of MCP servers (Claude Desktop's format works as is). Each call
asks first unless `ai.autoApprove` is `all`, and tokens in `env` go only to the server. *AI: MCP servers…* shows
each server and its tools. *AI: review the assistant's changes…* (or the toast after a run) shows each changed file
beside how it was; **r** undoes one change, *Undo all of it* puts every file back.

**Also.** The active indent guide is brighter. A program started from ned can no longer take the terminal away
from it.

## What's new in 5.8

**EditorConfig.** A project's `.editorconfig` is followed: indentation, tab width, trailing whitespace, final
newline, line ends for new files, and `max_line_length` as the ruler. *File: EditorConfig for this file* lists what
applies. `"editor.editorConfig": false` ignores it.

**Tasks.** Run › Run task… (**Shift+F4**) lists what the project can run: Makefile targets, `package.json` scripts,
`just` recipes, Taskfile tasks, cargo, go and nimble tasks and your run configurations. **F4** runs the last one
again.

**Readable Nim errors.** A type mismatch says what is wrong on the line itself (*"a" is string, foo wants b: int*),
and Alt+H shows each argument against the closest overload. An unknown name gets *did you mean greet?*. Follow-on
errors on the same line are left out.

**Colour swatches.** A small block of the colour appears before `#RRGGBB`, `rgb()`, `hsl()` and Nim's `0xRRGGBB`.
Click it to copy the colour as hex, rgb or hsl, or to make it lighter or darker. `"editor.colorSwatches": false`
turns them off.

**Run the examples.** A ▶ beside `runnableExamples:` runs that block as `nim doc` does and turns ✓ or ✗.
*Nim › Run all examples in the file* runs every block.

## What's new in 5.7.1

**Rulers.** **View › Editor › Rulers** draws a thin line at column 80. *View: set ruler columns…* or
`"editor.rulers": [80, 120]` (per project too) sets others. The line never hides code, and the part of a line past
the last ruler is tinted (`"editor.rulerTint": false` turns that off). Off by default; hidden in zen mode.

## What's new in 5.7

**AI.**
- **Undo what the assistant did:** the toast after a run offers *Undo*; *AI: undo the assistant's changes…* puts
  back the files of any run in the session.
- **What a chat costs:** the assistant panel counts tokens, and dollars with `ai.price`. A request over
  `ai.warnTokens` (60 000) asks first.
- **Fast or smart:** the ⚡ button (*AI: fast / smart model*) switches between `ai.fastModel` and `ai.model`.
- **Answers that know your Nim code:** requests from a Nim file carry the definitions the code uses
  (`ai.nimContext`).
- *AI: review staged changes* puts its findings in the Problems panel; *AI: clear review findings* removes them.

**Nim.**
- **Run configurations** (Run › Configurations): named ways to run the project, kept in `.ned/settings.json`. The
  chosen one shows as **▶ name** in the status bar and Alt+R runs it. A cloned project's configurations run only
  after *Workspace: trust this folder*. *Run: current file with arguments…* remembers each file's arguments.
- *What can this proc raise?* (Nim menu) lists the exceptions and effects and copies the matching
  `{.raises: […].}`.
- *Benchmark a call* (Nim menu) times an expression in a release build.
- *Nimble: release a new version* sets the version, commits, tags and pushes.

**Git.** Interactive rebase (edit the plan as text, Ctrl+S runs it), cherry-pick, compare with a branch, and a
coloured branch graph. With `gh`: pull requests, issues and Actions runs, and the branch's CI result in the status
bar (**CI ✓**, **CI ✗**, **CI ⟳**).

**Themes.** Nine new, 37 in all: *modus-vivendi*, *modus-operandi*, *catppuccin-frappe*, *catppuccin-macchiato*,
*tokyo-night-day*, *rose-pine-dawn*, *kanagawa-lotus*, *ayu-light* and *github-dark-dimmed*. `"theme": "auto"` uses
`theme.light` or `theme.dark` to match the terminal. `"theme.colors"` changes any colour, of every theme or one.
*Theme: import…* converts a VS Code or base16 theme into `~/.config/ned/themes/`; *Theme: make my own copy of this
theme* copies the current one there to edit.

## What's new in 5.6.4

**Saving changes only what you changed.** Trailing spaces are removed only from the lines you edited
(`"editor.trimAllLines": true` for the old way). Saving a read-only file asks first. Mixed CRLF and LF line ends are
reported when the file opens.

**Temporary files are private.** AI requests, nimsuggest, the formatter, debug builds, coverage and the clipboard
use a folder only you can read, not the shared `/tmp`.

**Faster.** Typing stays fast in big projects with many TODOs; semantic colours wait for a pause in typing; release
builds are about 1 MB smaller.

**Fixes.** A crash opening search results in a multibuffer after a file got shorter, and one with very many tabs
open.

## What's new in 5.6.3

**Open folder is a folder browser.** *File › Open folder…* (or **d** on the Welcome page): Enter or → goes in,
Backspace or ← goes up, Alt+Enter opens the highlighted folder. Projects are marked ◆; typing filters, and `/path`
or `~/path` jumps there. In the Files tree, right-click a folder › *Open as the project*. *File: open folder by
path…* keeps the typed prompt.

## What's new in 5.6.2

**Format on save keeps the cursor in place.** When the formatter removes the blank line the cursor is on, the
cursor stays at the end of the line above instead of jumping to the start of the last line.

## What's new in 5.6.1

**macOS and Windows (WSL).** ned runs there as well as on Linux and Termux; the built-in terminal, the clipboard and
*Check setup* work there too. Building natively on Windows stops with a pointer to WSL. See
[Installing](README.md#installing).

**TODO comments.** The Files tree shows ⚑3 beside a file with three tag comments. *Create a GitHub issue* in the
TODOs dock makes an issue from a comment, with a permalink (needs `gh`).

**Fixes.** Deleting a TODO comment can be undone and keeps a block comment's `/*` or `*/`. Piped input works on
macOS, and `yes | head` in the built-in terminal. Links copied from git never contain a token from the remote's
address. A branch name can no longer inject a shell command on the first push. *Stage selected lines* uses the
file's own repository and keeps CRLF intact. Clipboard text, commit messages and staged lines no longer go through
a shared `/tmp` file. Pushing and pulling keep your own ssh command. Local branches named `you/topic` no longer
show as remote. Counting TODOs no longer slows typing.

## What's new in 5.6

**TODO comments, like VS Code's Todo Tree.**

![TODO, FIXME, BUG, HACK and NOTE coloured in the code, and the TODOs dock counting them](screenshots/todos.png)

- **Coloured in the code:** a comment starting with `TODO`, `FIXME`, `BUG`, `HACK`, `XXX` or `NOTE` shows the tag
  as a coloured badge, in every language ned colours, and on the scrollbar.
- **The TODOs dock** (View › TODOs): a chip per tag with its count, to hide or show it, then every tag grouped by
  file, FIXME and BUG first, for the project or this file.
- **⚑ 3** in the status bar counts FIXME and BUG comments. **Alt+V** / **Alt+Shift+V** go to the next / previous
  tag.
- *Edit › Insert TODO comment…* uses the language's comment marker; `"todo.withName": true` adds your git name.
- In the dock, x deletes a comment (Ctrl+Z brings it back) and *Copy the list as Markdown* gives a checklist.
- `"todo.tags"` sets your own tags and colours; `"todo.highlight": false` turns the colours off.

## What's new in 5.5

- **Help › Check setup** (or `ned --check`) lists the tools ned found and the install command for anything missing.
- **Help › Copy info for bug report** copies ned's version, Nim's, the system, terminal and tools.
- **Piped input:** `git log | ned` or `nim check app.nim 2>&1 | ned -` opens what the command printed.
- **Typos in settings are reported:** `"editor.tabsize"` → *did you mean "editor.tabSize"?*
- **Unknown options are errors** (`ned --verison`); `ned -- -odd-name.txt` opens a file whose name starts with `-`.
- ned needs **Nim 2.2 or newer**, and the package ships its MIT **LICENSE** file.

## What's new in 5.4.1

**Four new themes.** *everforest-dark*, *everforest-light*, *night-owl* and *light-owl*. Alt+T previews them.

![everforest-dark, everforest-light, night-owl and light-owl](screenshots/everforest-nightowl.png)

## What's new in 5.4

**Git, much more of it.** A new **Git** menu, with the same actions in the Source control dock.

- **Branches:** click the branch in the title bar to switch, create, rename, merge or delete. ↑ and ↓ count commits
  to push and pull; ⟳ syncs.
- **Push and pull that don't hang:** when the server asks for a username, password or SSH passphrase, the command
  opens in the terminal. A new branch's first push sets its upstream. Also fetch, and pull with rebase.
- **Committing:** a message box (Ctrl+S commits), amend, and undo the last commit. With nothing staged, ned offers
  to commit every changed file.
- **Side-by-side diffs** for changed files (*Open diff as text* keeps the old view), and **stage selected lines**.
- *Git: history…*, stash, merges and rebases with *Continue* and *Abort*, and *Git: blame this file*.
- Clone, *Add to .gitignore*, tags, *Copy link to this line* (GitHub, GitLab, Codeberg) and *Create a pull request*
  with `gh`.

## What's new in 5.3.2

**Undo survives closing a file.** Ctrl+Z still undoes earlier edits when the file is opened again, as long as
nothing else changed it in between (`editor.persistentUndo`, kept in `~/.local/state/ned/undo`).

**Debugger.** Strings inside objects and seqs show as text; the C runtime's frames are hidden from the call stack;
conditions can compare strings (`name == "Ann"`).

**Also.** Rename preview shows old and new lines in diff colours. Multibuffer sections have header bars that open
the file. *Your commands…* in Settings edits your commands without JSON, and `keys` opens the shortcuts editor.

## What's new in 5.3.1

**New keys and menus.** F1 lists the new keys, with long lines wrapped. The menus (File, Edit, View, Go,
Run › Debug, Nim › Refactor) and right-click menus (peek, call hierarchy, Git stage/revert, *Refactor* and *Debug*
submenus, reopen closed tab) have the new commands.

## What's new in 5.3

**Messages pop up, whole.** They wrap instead of being cut to fit the status bar, and close after a few seconds
(warnings after 7, errors after 12) or with a click or Esc. *Show recent messages* lists the last 100;
`"ui.messages": "statusbar"` brings back the old way. Documentation popups wrap long lines too.

**A real diff view.** *Git: compare with last commit*, *File: compare with saved* and the new *File: compare with
another file…* open an aligned side-by-side diff with changed words marked. F7 / Shift+F7 go from change to change,
Enter opens the line in your file, ⟲ (or r) reverts a change.

![The side-by-side diff: the last commit on the left, your file on the right, changed words marked](screenshots/diff-view.png)

**Rename preview.** F2 first lists every change; Space unticks one, Enter applies. `"editor.renamePreview": false`
renames at once.

**Debugger.** Objects, tuples, arrays and seqs expand (▸); watch expressions (*Debug: add a watch expression…*);
*Debug: debug the test at the cursor*; breakpoints stop on exactly their line.

![The debugger: a seq expanded into its items, a watch expression, the call stack](screenshots/debugger.png)

**Your own commands.** The `commands` setting adds palette commands that run shell commands, such as
`"Word count": {"run": "wc -w $file", "output": "popup"}`, with placeholders, `output` and `input` choices and keys
of their own. In project settings they wait until you trust the folder.

**Also.** The formatter lays out `a, b, c: T = v` as nph does. Huge files open faster with less memory; files over
16 MB show "Opening …".

## What's new in 5.2.2

**nim-crown is the default theme.** A theme named in your settings stays.

**Like VS Code and Zed.** Go forward (Alt+<), reopen a closed tab (Alt+Shift+T), box selection (Alt+drag), peek
(Alt+F12; Alt+Shift+F12 for references), stage or revert a change from its gutter mark, *Call hierarchy (callers and
calls)*, imports fixed when a module is renamed, *Keyboard shortcuts…*, *Markdown: open preview to the side*, and
*Open results in a multibuffer* after a search (Ctrl+S writes the edits back). Other languages get semantic colours
and workspace symbols from their servers. Typing in very large files no longer lags.

**For Nim.** Readable type mismatch hovers. Alt+Enter adds missing `case` branches, generates `$`, `==`, `hash` and
a constructor for a type, adds a doc comment or runs the selection. Unused names are faded; Alt+H on a selection
shows its type. New commands: *Nim: test coverage*, *Nim: profile*, *Nim: share to the Playground*, *Nim: switch
compiler version…*, *Nim: standard library docs browser…* and *Nimble: dependencies and updates…*.

## What's new in 5.2.1

**Debugger.** Breakpoints are kept with the session and move with their line. Conditional breakpoints (*Debug:
conditional breakpoint on this line…*, marked ◆), run to cursor (Ctrl+F10), and values on hover while stopped. F5
debugs the current file when it is a program.

**The touch bar is opt-in.** Turn it on with *Toggle touch bar* or View › Appearance › Touch bar;
`ui.touchBar: "auto"` shows it on phones only. `ui.touchBarKeys` picks its keys, any palette command included.

**Formatter.** A long declaration in a `var` section formats the same the second time. Notes for 5.1.1 and older
are in [CHANGELOG.md](CHANGELOG.md).

## What's new in 5.2

**A debugger panel (gdb) for Nim.** F9 sets a breakpoint, F5 runs to it, F10, F11 and Shift+F11 step, Shift+F5
stops. The **DEBUG** panel shows the call stack with Nim names, the local variables and the output. Needs gdb
(Termux: `pkg install gdb`).

![The debugger: stopped at a breakpoint, with the call stack and the local variables](screenshots/debugger.png)

**Refactoring.** *Nim: extract selection into a proc*, *Nim: sort imports* and *Nim: toggle proc ⇄ func*.

**Also.** Completion offers names from standard modules not yet imported and adds the import (`nim.autoImport`).
Semantic colours (`nim.semanticColors`). Alt+F formats just the selected lines. The formatter is closer to nph.
Merge conflicts get **Accept ours · Accept theirs · Accept both**. *Git: compare with last commit (side by side)*.
Settings can be searched by name or description.

**Touch.** A touch bar (opt-in since 5.2.1); drag a tab to reorder, drag the minimap to scroll, swipe sideways in the
file tree to close or open a folder.

**Fixes.** Ctrl+Alt+↑ now makes the bottom panel taller and Ctrl+Alt+↓ shorter (they were swapped). The debugger
shows Nim type names and hides the C compiler's temporaries.

## What's new in 5.1.1

**Two monochrome themes.** `monochrome` and `monochrome-light`: grey only, with code told apart by lightness and
weight.

![The monochrome themes: dark with completion and documentation, light with hover](screenshots/monochrome.png)

## What's new in 5.1

**Every theme is equally readable.** All 22 themes have a minimum contrast for every interface colour; only
lightness changes, so each keeps its colours.

**Also.** Unfocused lists keep their selected row visible. Drag to resize splits, docks and the bottom panel (*View:
reset split and dock sizes* puts them back), or use Ctrl+Alt+arrows. The scrollbar can be clicked and dragged.
Shift+wheel and a tilt wheel scroll sideways; the wheel over the tabs switches tabs. On touch screens, press and
hold opens the context menu (`ui.longPressMenu`).

**Less memory.** nimsuggest stops after 15 minutes without a question (`nim.nimsuggestIdleMinutes`). In Termux its
ceiling is 800 MB unless you set `nim.nimsuggestMaxMB`.

**Fixes.** A drag released outside the window no longer carries into the next click. Matching a bracket across
lines no longer slows the screen.

## What's new in 5.0.1

**Layout and colour fixes.** Panes one above the other are divided by a solid bar. Inlay hints stay on their code
when lines are added or removed, and type hints appear only right after a name. Rainbow brackets never take the
colour of the text beside them.

## What's new in 5.0

**A Nim engine of ned's own.** nimlangserver is no longer needed. Completion, hover, go to definition, signature
help, references, rename, the outline, *Go to symbol* (Ctrl+T) and project symbols (Ctrl+P `#`) answer at once,
following imports as the compiler does. See [Nim IDE: the built-in engine](docs/guide/nim.md).

**nimsuggest only where the compiler is needed.** Errors while you type, inlay hints, macro expansion and
completions the engine cannot answer. `nim check` reports errors on save. `"nim.nimsuggest": false` turns it off.

**Documentation beside the completion list.** It is rendered as Markdown; Ctrl+Space toggles it
(`editor.completionDocs`).

**A Nim formatter of ned's own, in nph's style.** Nothing to install, and it leaves the file alone if the code would
change. `nim.formatter` picks `builtin`, `nph` or `nimpretty`. See [Formatting Nim](docs/guide/formatting.md#nim).

**Also.** Formatting keeps the cursor on the same code. Clearer panes and breadcrumb bar. `slate` is the default
theme. *Settings: reset to defaults* keeps a backup of the old file. AI chat › Insert puts code where it belongs, in
one undo step. In vim mode Esc no longer leaves zen (Alt+Z or `:zen` do). `nim.ide` is `builtin`, `nimlangserver`
or `off`.

## What's new in 4.1

**nimlangserver works in nimble projects.** It uses the `nimsuggest` on your `PATH`, each nimble package gets its
own nimsuggest, and loose files share one.

**A language server that crashes is restarted.** The warning names the reason. If nimlangserver keeps failing, ned
falls back to nimsuggest.

**OpenAI's newer models work.** GPT-5, GPT-6, o-series, `-pro` and codex models, the Responses API too
(`ai.openaiApi`).

**Italics are off by default.** `"ui.italics": true` turns them on.

**Two new themes.** `slate` and `slate-night`.

**Fixes.** Input handling, scrolling and vim mode, including a crash when `.` repeated itself. If the terminal
disappears, ned saves recovery files and exits. An internal error is reported once and logged to
`~/.local/state/ned/errors.log`, and ned keeps running.

## What's new in 4.0

**One nimsuggest per project.** Opening ten files no longer starts ten nimsuggest processes, on any nimlangserver
version; the Nim dock shows how many are running.

- **Split editor**, side by side or stacked.
- **Regular expressions** in find, replace and project search, and **project-wide find and replace** with a preview
  and one-step undo.
- **AI:** saved chats, edits as diffs to approve, slash commands, `@mentions`, `AGENTS.md`/`CLAUDE.md` project
  instructions, AI commit messages and opt-in inline suggestions.
- **Quick fixes** (Alt+Enter), such as `import std/…` for an undeclared name.
- **Safety:** atomic saves, recovery files, local history of every save, protection against overwriting files
  changed elsewhere, binary files as a read-only hex dump.
- **Git:** live change markers, next/previous change (F7), revert a change, inline blame.
- Bookmarks, recent projects, per-project settings, user snippets, Nim REPL, `nimble add`. Fold markers survive
  undo/redo.
