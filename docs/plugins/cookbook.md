# Plugin cookbook

Whole plugins, one for each part of the [plugin API](api.md), each small enough to read in a minute and ready
to use as it is. Where the [tutorial](tutorial.md) builds one plugin step by step and [Plugins](README.md) says
what plugins can do, this page shows each part at work in a plugin of its own.

**To use one**, make a folder for it in `~/.config/ned/plugins/` named as the plugin — the name on its first
line, `date-stamp` for the first — and save the plugin in it as `plugin.nims`. ned starts it when you save it,
and it shows in the Plugins dock (View › Plugins panel), where its log is. A plugin that runs programs asks
you first (*Allow…* in the dock). They need ned 6.31 or newer.

Every plugin here is also a file of [`tests/plugins/cookbook/`](../../tests/plugins/cookbook), and
`python3 tests/plugins/cookbook/check.py` checks that each one compiles — as NimScript, as ned runs it, and as
Nim, as `plugins.native` compiles it — and that this page shows each file as it is there.

1. [A command on a key, and vim mappings](#1-a-command-on-a-key-and-vim-mappings) — `date-stamp`
2. [Events](#2-events) — `file-stats`
3. [Reading and changing the text](#3-reading-and-changing-the-text) — `line-tools`
4. [Signs, text after a line, highlights, the indentation](#4-signs-text-after-a-line-highlights-the-indentation) — `long-lines`
5. [Problems and quick fixes](#5-problems-and-quick-fixes) — `whitespace-check`
6. [A language and its features](#6-a-language-and-its-features) — `just`
7. [A formatter](#7-a-formatter) — `sh-format`
8. [A language server in NimScript](#8-a-language-server-in-nimscript) — `md-links`
9. [A view in the Plugins dock](#9-a-view-in-the-plugins-dock) — `bookmarks`
10. [Timers](#10-timers) — `reminders`
11. [Settings and the plugin's data](#11-settings-and-the-plugins-data) — `daily-log`
12. [Permissions and running programs](#12-permissions-and-running-programs) — `git-line`
13. [Asking you: pick, ask, confirm](#13-asking-you-pick-ask-confirm) — `word-tools`
14. [Progress, the Output panel, the terminal](#14-progress-the-output-panel-the-terminal) — `project-tasks`
15. [Vim: an operator, text objects, mappings](#15-vim-an-operator-text-objects-mappings) — `sort-motion`
16. [Tools for the assistant](#16-tools-for-the-assistant) — `editor-tools`
17. [The status bar](#17-the-status-bar) — `selection-stats`
18. [A tab of the plugin's own](#18-a-tab-of-the-plugins-own) — `scratch`
19. [Keys that wait: which-key](#19-keys-that-wait-which-key) — `leader-hints`
20. [Regular expressions](#20-regular-expressions) — `regex-tools`
21. [Panes and multibuffers](#21-panes-and-multibuffers) — `word-places`

Three things hold for every plugin below. Lines and columns count from 0, and a column is a byte offset in the
line. All the edits one callback makes are one undo step. And a command's body cannot `return` (it is a
template's), so the commands call a proc that can.

## 1. A command on a key, and vim mappings

`date-stamp` puts today's date at the cursor: from the palette, on Ctrl+Alt+T, with vim's `<leader>dt` in
normal and visual mode, and with `:Date`. Save it as `~/.config/ned/plugins/date-stamp/plugin.nims`.

<!-- file: command_key.nims -->
```nim
## date-stamp — today's date at the cursor: a command on a key, vim mappings and a `:` command
import nedplugin

requiresNed(">= 6.31")
pluginInfo(version = "1.0.0", author = "You", license = "MIT")

proc today(withTime: bool): string =
  ## "2026-10-26", or "2026-10-26 14:03" — NimScript has no clock: ned's is asked
  let now = localTime()                       # "2026-10-26 14:03:05"
  if withTime: now[0 ..< 16] else: now[0 ..< 10]

proc stamp(b: Buf, withTime: bool) =
  ## the date in place of the selection (nothing selected: at the cursor), the cursor after it
  let s = today(withTime)
  let r = b.selection                         # (nothing selected: an empty range at the cursor)
  b.replace(r, s)
  b.setCursor(pos(r.start.line, r.start.col + s.len))

# in the palette (Ctrl+E) and on Ctrl+Alt+T
command "Date stamp: insert today's date", "ctrl+alt+t":
  stamp(current(), false)

# only in the palette
command "Date stamp: insert the date and the time":
  stamp(current(), true)

# vim's normal mode: space d t; with a count (2 space d t) the time too
nmap("<leader>dt", "insert today's date") do (count: int):
  stamp(current(), count > 1)

# vim's visual mode: the selection becomes the date (ned goes back to normal mode after it)
vmap("<leader>dt", "replace it with today's date") do (count: int):
  let b = current()
  b.replace(b.selection, today(false))

# :Date, or :Date time
exCommand("Date") do (args: string):
  stamp(current(), args == "time")
```

- [`command`](api.md#command-1) puts a command in the palette (Ctrl+E) and the Plugins dock, here on a key
  too. Your own `keys` setting wins over a plugin's key. Not every terminal passes Ctrl+Alt+T: the palette
  always works.
- [`nmap`](api.md#nmap-1) and [`vmap`](api.md#vmap-1) are vim mappings (`editor.vimMode`); `<leader>` is the
  space bar, and the text after the keys is what which-key shows. `count` is the number typed before the keys,
  1 without one. After a visual-mode mapping ned goes back to normal mode.
- [`exCommand`](api.md#excommand) is a `:` command; `args` is what follows its name.
- [`selection`](api.md#selection) is empty (`start == stop`) when nothing is selected, so replacing it inserts
  at the cursor. [`localTime`](api.md#localtime) is ned's clock: NimScript has none.
- [`pluginInfo`](api.md#plugininfo) gives the version the Plugins dock shows; [`requiresNed`](api.md#requiresned)
  keeps an older ned from running it.

**Try it:** put the cursor in a file and press Ctrl+Alt+T; with vim keys on, `<space>dt`, `2<space>dt`, and
`:Date time`. Ctrl+Z takes each back.

## 2. Events

`file-stats` answers ned's events: the lines and words of a text file in the status bar, kept up to date as
you switch tabs and type; the spaces at the ends of lines removed before a file is saved; a log of what you
save; and the files open when ned quits, to open again next time.

<!-- file: events.nims -->
```nim
## file-stats — events: a text file's lines and words in the status bar, spaces at the ends of lines removed
## before saving, a log of what you save, and the files that were open when ned last quit
import nedplugin

requiresNed(">= 6.31")

func words(lines: seq[string]): int =
  for l in lines: result += l.splitWhitespace.len

proc showCounts(b: Buf) =
  ## the file's counts in this plugin's item of the status bar — for text and Markdown; nothing for the others
  if b.valid and b.lang in ["markdown", "plaintext"]:
    let ls = b.lines                          # (one request for all the lines)
    status($ls.len & " lines · " & $words(ls) & " words")
  else:
    status("")                                # ("" removes the item)

proc trimEnds(b: Buf) =
  ## the spaces and tabs at the ends of the lines removed — one setText: ned changes only the lines that differ
  let ls = b.lines
  var changed = false
  var res: seq[string]
  for l in ls:
    let t = l.strip(leading = false)
    if t.len < l.len: changed = true
    res.add t
  if changed: b.setText(res.join("\n"))

onOpen("*") do (ev: Event):                   # a file opened (and the files open when ned starts)
  if ev.buf.id == current().id: showCounts(ev.buf)

onEnter("*") do (ev: Event):                  # another tab came to the front
  showCounts(ev.buf)

onChange("*.md,*.txt") do (ev: Event):        # after a pause in the typing
  if ev.buf.id == current().id: showCounts(ev.buf)

onBeforeSave("*") do (ev: Event):             # ned waits for this one: what it changes is saved
  # (not in Markdown, where two spaces at a line's end are a line break, nor in a diff)
  if ev.lang notin ["markdown", "diff"]: trimEnds(ev.buf)

onSave("*") do (ev: Event):                   # after the file was written
  appendData("saves.log", localTime() & "  " & ev.path & "\n")

onClose("*") do (ev: Event):                  # the tab is gone: ev.path and ev.lang say which it was
  log("closed " & ev.path)

onQuit do (ev: Event):                        # ned waits a moment: write what you keep now
  var paths: seq[string]
  for b in buffers():
    let p = b.path
    if p.len > 0: paths.add p
  writeData("last-session.txt", paths.join("\n"))

onStartup do (ev: Event):                     # once, when ned has started
  let last = readData("last-session.txt")
  if last.len > 0: log("last time " & $last.splitLines.len & " files were open")

command "File stats: open the files of last time":
  for p in readData("last-session.txt").splitLines:
    if p.len > 0 and fileExists(p): discard openFile(p)

# the same events by vim's names
autocmd("BufWritePost", "*.nim") do (ev: Event):
  log("saved " & extractFilename(ev.path))
```

- [`onOpen`](api.md#onopen), [`onEnter`](api.md#onenter), [`onChange`](api.md#onchange),
  [`onSave`](api.md#onsave), [`onClose`](api.md#onclose), [`onQuit`](api.md#onquit) and
  [`onStartup`](api.md#onstartup) each get an `Event`: the file (`ev.buf`), its path and its language. The
  pattern says which files: `"*"`, `"*.md"`, `"src/*.nim"`, `"lang:markdown"`, or several with commas.
- ned waits for [`onBeforeSave`](api.md#onbeforesave) (`plugins.timeoutMs`, 1.5 s): what it changes is saved.
  It does not wait for the others. [`onChange`](api.md#onchange) comes after a pause in the typing, not at
  every key.
- [`setText`](api.md#settext) changes only the lines that differ: one request for the whole file, and the
  cursor stays where it was.
- In [`onClose`](api.md#onclose) the tab is gone: use `ev.path`, not `ev.buf`. [`onQuit`](api.md#onquit) is
  the moment to write what the plugin keeps; ned waits a moment for it.
- [`appendData`](api.md#appenddata), [`writeData`](api.md#writedata) and [`readData`](api.md#readdata) use the
  plugin's own data folder, with no permission. [`autocmd`](api.md#autocmd) takes vim's names for the events.

**Try it:** open a Markdown file and type; switch to a code file (the item goes); save a text file with spaces
at the end of a line; quit and start ned, then run *File stats: open the files of last time*.

## 3. Reading and changing the text

`line-tools` has five commands that read and change the text: sort the selected lines, number them,
upper-case each cursor's selection, remove blank lines, swap a line with the next.

<!-- file: editing.nims -->
```nim
## line-tools — reading and changing the text: sort or number the selected lines, upper-case each cursor's
## selection, remove blank lines, swap a line with the next — each command one undo step
import nedplugin
import std/algorithm

requiresNed(">= 6.31")

proc selectedLines(b: Buf): (int, int) =
  ## the first and last line the selection touches (the cursor's line when nothing is selected) — a selection
  ## that ends at the start of a line leaves that line out
  let r = b.selection
  var last = r.stop.line
  if last > r.start.line and r.stop.col == 0: dec last
  (r.start.line, last)

proc sortLines(b: Buf) =
  ## the selected lines (nothing selected: every line) sorted, A and a together; then selected
  var (first, last) = selectedLines(b)
  if first == last: (first, last) = (0, b.lineCount - 1)
  var ls = b.lines(first, last)
  ls.sort(proc(x, y: string): int = cmp(x.toLowerAscii, y.toLowerAscii))
  b.replace(rng(pos(first, 0), pos(last, b.line(last).len)), ls.join("\n"))
  b.select(rng(pos(first, 0), pos(last, ls[^1].len)))
  message("Sorted " & $ls.len & " lines")

proc numberLines(b: Buf) =
  ## "1. ", "2. " … at the start of the selected lines — many inserts, one undo step
  let (first, last) = selectedLines(b)
  let width = len($(last - first + 1))
  for i in first .. last:
    let n = $(i - first + 1)
    b.insert(pos(i, 0), " ".repeat(width - n.len) & n & ". ")

func wordRange(l: string, line, col: int): Range =
  ## the word around column `col` of the line `l` (line number `line`): letters, digits and _
  var a = col
  var e = col
  while a > 0 and l[a - 1] in IdentChars: dec a
  while e < l.len and l[e] in IdentChars: inc e
  rng(pos(line, a), pos(line, e))

proc upperEach(b: Buf) =
  ## each cursor's selection in capitals — or, where nothing is selected, the word at that cursor
  var rs = b.selections                       # (one for each cursor; not in the file's order)
  rs.sort(proc(x, y: Range): int = cmp((x.start.line, x.start.col), (y.start.line, y.start.col)))
  # from the last to the first: an edit moves the text after it, not the text before
  for i in countdown(rs.high, 0):
    var r = rs[i]
    if r.isEmpty: r = wordRange(b.line(r.start.line), r.start.line, r.start.col)
    if not r.isEmpty: b.replace(r, b.textIn(r).toUpperAscii)

proc removeBlankLines(b: Buf) =
  ## the blank lines among the selected ones (nothing selected: in the whole file) deleted, line ends and all
  var (first, last) = selectedLines(b)
  if first == last: (first, last) = (0, b.lineCount - 1)
  let ls = b.lines(first, last)
  var n = 0
  for i in countdown(ls.high, 0):
    if ls[i].strip.len > 0: continue
    let l = first + i
    if l == b.lineCount - 1 and l > 0:
      # the file's last line has no line end of its own: it goes with the one of the line before it
      b.delete(rng(pos(l - 1, b.line(l - 1).len), pos(l, b.line(l).len)))
    else:
      b.delete(b.wholeLines(l, l))
    inc n
  message("Removed " & $n & " blank lines — Ctrl+Z puts them all back")

proc swapDown(b: Buf) =
  ## the cursor's line and the one below it change places; the cursor goes with its line
  let c = b.cursor
  if c.line + 1 >= b.lineCount: return
  let here = b.line(c.line)
  let below = b.line(c.line + 1)
  b.replace(rng(pos(c.line, 0), pos(c.line + 1, below.len)), below & "\n" & here)
  b.setCursor(pos(c.line + 1, c.col))

command "Line tools: sort the lines":
  sortLines(current())
command "Line tools: number the lines":
  numberLines(current())
command "Line tools: upper-case each selection", "ctrl+alt+u":
  upperEach(current())
command "Line tools: remove the blank lines":
  removeBlankLines(current())
command "Line tools: swap the line with the next", "alt+shift+n":
  swapDown(current())
```

- [`lines`](api.md#lines) asks for many lines in one request; [`line`](api.md#line) for one. Both are without
  their line ends.
- A [`Range`](api.md#type-range) goes from `start` up to `stop`, `stop` not included. A selection that ends at
  the start of a line does not take that line, so `selectedLines` leaves it out.
- [`selections`](api.md#selections) gives each cursor's selection (*Add cursor below*, Alt+J, makes more); they
  are not in the file's order. An edit moves the text after it, so `upperEach` and `removeBlankLines` go from
  the last place to the first.
- [`wholeLines`](api.md#wholelines) is lines with their line ends: deleting it removes them. The file's last
  line has no line end of its own, so it goes with the one before it.
- [`replace`](api.md#replace), [`insert`](api.md#insert), [`delete`](api.md#delete),
  [`select`](api.md#select) and [`setCursor`](api.md#setcursor) change the text and the cursor. However many
  edits a command makes, Ctrl+Z takes them back at once.

**Try it:** select a few lines and run *Line tools: sort the lines*, then Ctrl+Z; put several cursors on words
(Alt+J) and press Ctrl+Alt+U.

## 4. Signs, text after a line, highlights, the indentation

`long-lines` marks the lines longer than its `width` setting: a sign in the gutter, the part past the width
tinted, and how many characters too long the line is after its end. A command colours each level of
indentation.

<!-- file: decorations.nims -->
```nim
## long-lines — decorations: a line longer than plugins.long-lines.width gets a sign in the gutter, the part past
## the width tinted and how much too long it is after its end; and a command that colours the indentation's levels
import nedplugin
from std/unicode import runeLen, runeOffset   # (just these two: std/unicode's strip would clash with strutils')

requiresNed(">= 6.31")

settingDef("width", 100, "Long lines: how many characters a line may have")

proc mark(b: Buf) =
  ## this plugin's marks in the file made again: the old ones go, the long lines get new ones
  b.clearDecorations()                        # (only this plugin's: other plugins' marks stay)
  let width = setting("width", 100)
  var n = 0
  for i, l in b.lines:
    let chars = l.runeLen                     # characters — a column is a byte: "é" is two bytes, one character
    if chars <= width: continue
    inc n
    if n > 200: break                         # (each mark is a request: the first 200 long lines are enough)
    let cut = l.runeOffset(width)             # the byte where the first character past the width starts
    b.sign(i, "»", "warn")
    b.highlight(rng(pos(i, cut), pos(i, l.len)), "warn")
    b.virtualText(i, "+" & $(chars - width), "hint")

onOpen("*") do (ev: Event):
  mark(ev.buf)
onChange("*") do (ev: Event):                 # (marks stay on their line numbers: make them again after a change)
  mark(ev.buf)

var rainbow = false

command "Long lines: rainbow indentation on/off":
  rainbow = not rainbow
  if rainbow:
    # a colour for each level of indentation, a dot in each space of it, a red band where it is not whole levels
    indentStyle(IndentStyle(levels: @["warn", "add", "info", "accent"], dot: "·", blankLines: true,
                            wrongColor: "error"))
  else:
    indentStyle(IndentStyle())                # (an empty look takes this plugin's away)
  message("Rainbow indentation " & (if rainbow: "on" else: "off"))
```

- [`sign`](api.md#sign), [`highlight`](api.md#highlight) and [`virtualText`](api.md#virtualtext) are this
  plugin's own, and [`clearDecorations`](api.md#cleardecorations) removes them (other plugins' stay). They stay
  on their line numbers while you type, so the plugin makes them again on each change.
- A column is a byte: `runeLen` counts the characters and `runeOffset` finds the byte where the 101st starts.
- Each mark is one request: the plugin stops at 200 long lines. Problems ([section 5](#5-problems-and-quick-fixes))
  go in one request however many there are.
- [`indentStyle`](api.md#indentstyle) says once how indentation looks — a colour for each level, dots, a band
  where it is wrong ([`IndentStyle`](api.md#type-indentstyle)) — and ned draws it with each line: nothing is
  sent per line. `IndentStyle()` takes it away.
- [`settingDef`](api.md#settingdef) puts `plugins.long-lines.width` in the Settings panel;
  [`setting`](api.md#setting-1) reads it, where it is used, so a change applies at once.

**Try it:** set `plugins.long-lines.width` to 40 and open a file; run *Long lines: rainbow indentation on/off*
in an indented file.

## 5. Problems and quick fixes

`whitespace-check` reports spaces at the ends of lines and tabs in an indentation of spaces as problems. On a
problem's line, Alt+Enter offers to fix the line, or every line of the file at once.

<!-- file: problems.nims -->
```nim
## whitespace-check — problems with quick fixes: spaces at the end of a line, and a tab in an indentation of
## spaces; Alt+Enter on the line offers to fix it, or to fix every line of the file at once
import nedplugin

requiresNed(">= 6.31")

proc check(b: Buf) =
  ## the file's problems, all set in one request (they take the place of the ones this plugin set before)
  let ls = b.lines
  let unit = b.indentUnit                     # "  ", "    " or "\t": what this file indents with
  let lineBreaks = b.lang == "markdown"       # (two spaces at a line's end are a line break there)
  var ends: seq[Edit]                         # every line's spaces at its end: the whole-file fix
  var ps: seq[Problem]
  for i, l in ls:
    let t = l.strip(leading = false)
    if t.len < l.len and not lineBreaks:
      let r = rng(pos(i, t.len), pos(i, l.len))
      ends.add Edit(range: r, text: "")
      ps.add Problem(range: r, severity: 4, message: "spaces at the end of the line",
                     fixes: @[Fix(title: "Remove them", edits: @[Edit(range: r, text: "")])])
    var k = 0
    while k < l.len and l[k] in {' ', '\t'}: inc k
    if unit != "\t" and '\t' in l[0 ..< k]:
      let r = rng(pos(i, 0), pos(i, k))
      let spaces = l[0 ..< k].replace("\t", unit)
      ps.add Problem(range: r, severity: 2, message: "a tab in an indentation of spaces",
                     fixes: @[Fix(title: "Indent with spaces", edits: @[Edit(range: r, text: spaces)])])
  if ends.len > 1:
    # one fix with many edits: all of them one undo step
    let all = Fix(title: "Remove the spaces at the ends of all " & $ends.len & " lines", edits: ends)
    for p in ps.mitems:
      if p.severity == 4: p.fixes.add all
  b.setProblems(ps)

onOpen("*") do (ev: Event):
  check(ev.buf)
onChange("*") do (ev: Event):                 # (problems stay where they were put: set them again after a change)
  check(ev.buf)

command "Whitespace: check this file":
  let b = current()
  check(b)
  message("Whitespace: checked " & extractFilename(b.path) & " (Alt+N: the next problem)")

command "Whitespace: clear the marks":
  current().clearProblems()
```

- [`setProblems`](api.md#setproblems) sends all of a file's problems in one request, in place of the ones the
  plugin set there before. They are underlined, listed in the Problems panel, marked in the gutter, and Alt+N
  / Alt+P go from one to the next.
- A [`Problem`](api.md#type-problem) has a range, a severity (1 error, 2 warning, 3 information, 4 hint), a
  message, and [`Fix`](api.md#type-fix)es; a fix's [`Edit`](api.md#type-edit)s are applied together, as one undo
  step — the whole-file fix here has an edit for each line.
- [`indentUnit`](api.md#indentunit) is what the file indents with. Problems stay where they were put, so the
  plugin checks again on each change.

**Try it:** type a few spaces at the end of a line and pause; Alt+Enter on that line.

## 6. A language and its features

`just` teaches ned the justfiles of the [just](https://github.com/casey/just) command runner: their colours,
comments, indentation and F5 ([`language`](api.md#language)); and it gives them what a language server would —
the recipes, variables and aliases as the outline, completion of their names, a hover over a recipe, quick
fixes and snippets.

<!-- file: language.nims -->
```nim
## just — a language: justfiles (the `just` command runner) coloured and indented, F5 runs them; their recipes,
## variables and aliases as the outline, completion of their names, hover over a recipe, code actions, snippets
import nedplugin

requiresNed(">= 6.31")

const
  Settings = ["allow-duplicate-recipes", "dotenv-load", "dotenv-filename", "export", "fallback",
              "positional-arguments", "quiet", "shell", "tempdir", "windows-shell", "working-directory"]
  Functions = ["arch", "os", "os_family", "env", "env_var", "env_var_or_default", "invocation_directory",
               "justfile", "justfile_directory", "just_executable", "num_cpus", "quote", "replace", "trim",
               "uppercase", "lowercase", "join", "absolute_path", "parent_directory", "file_name",
               "without_extension", "error", "uuid", "sha256"]

language("just", LangSpec(
  name: "Just",
  files: @["justfile", "Justfile", ".justfile"],  # (no extension: by the file's whole name)
  extensions: @["just"],
  lineComment: "#",
  quotes: "\"'`",
  keywords: @["alias", "export", "import", "mod", "set", "if", "else", "unexport"],
  constants: @["true", "false"],
  builtins: @Functions,
  indentAfter: @[":"],                        # a recipe's line ends in ":": its body is indented below it
  indentSize: 4,
  tripleQuotes: true,
  nameChars: "-",                             # build-docs is one name
  run: "just --justfile $file",               # F5: the first recipe
  pairs: "()[]{}\"\"''``"))

type Item = object
  ## a recipe, a variable or an alias of a justfile
  name, kind, detail, doc: string             # kind: "function" (a recipe), "variable" or "constant" (an alias)
  line, col: int

func parse(lines: seq[string]): seq[Item] =
  ## the justfile's recipes, variables and aliases, each with the comment lines just above it
  for i, l in lines:
    if l.len == 0 or l[0] in {' ', '\t', '#', '['}: continue
    var s = l
    if s.startsWith("export "): s = s[7 .. ^1]
    var it = Item(line: i)
    let assign = s.find(":=")
    if s.startsWith("alias ") and assign > 0:
      it.name = s[6 ..< assign].strip
      it.kind = "constant"
      it.detail = "alias of " & s[assign + 2 .. ^1].strip
    elif s.startsWith("set ") or s.startsWith("import ") or s.startsWith("mod "):
      continue
    elif assign > 0:
      it.name = s[0 ..< assign].strip
      it.kind = "variable"
      it.detail = s[assign + 2 .. ^1].strip
    elif s.find(':') > 0:
      let head = s[0 ..< s.find(':')].strip   # the name and its parameters
      it.name = head.splitWhitespace[0].strip(chars = {'@'})
      it.kind = "function"
      it.detail = head
    else: continue
    it.col = l.find(it.name)
    var j = i - 1                             # its comment: the # lines above it (attributes between are skipped)
    while j >= 0 and lines[j].startsWith("["): dec j
    while j >= 0 and lines[j].startsWith("#"):
      it.doc = lines[j].strip(chars = {'#', ' '}) & (if it.doc.len > 0: "\n" & it.doc else: "")
      dec j
    result.add it

func nameAt(l: string, col: int): string =
  ## the name at `col` — with the - a justfile's names may have (wordAt stops at it)
  var a = col
  var e = col
  while a > 0 and l[a - 1] in IdentChars + {'-'}: dec a
  while e < l.len and l[e] in IdentChars + {'-'}: inc e
  l[a ..< e]

# the outline (the Outline dock, Go to symbol, the breadcrumbs): every recipe, variable and alias
symbols("just") do (b: Buf) -> seq[Symbol]:
  for it in parse(b.lines):
    result.add Symbol(name: it.name, kind: it.kind, detail: it.detail, line: it.line, col: it.col)

# completion: the settings after "set", the functions in {{ }}, else the recipes and the variables
completions("just") do (b: Buf, p: Pos, prefix: string) -> seq[CompletionItem]:
  let l = b.line(p.line)
  let before = l[0 ..< min(p.col, l.len)]
  if before.startsWith("set "):
    for s in Settings:
      if s.startsWith(prefix): result.add CompletionItem(label: s, kind: "keyword", detail: "a setting")
    return
  if before.rfind("{{") > before.rfind("}}"):
    for f in Functions:
      if f.startsWith(prefix):
        result.add CompletionItem(label: f, insert: f & "($1)$0", snippet: true, kind: "function",
                                  detail: "a function of just's")
  for it in parse(b.lines):
    if it.name.startsWith(prefix) and it.line != p.line:
      result.add CompletionItem(label: it.name, kind: it.kind, detail: it.detail, doc: it.doc)

# hover over a recipe's name (in its own line, or where another recipe needs it): what it is and does
hover("just") do (b: Buf, p: Pos) -> string:
  let ls = b.lines
  let w = nameAt(ls[p.line], p.col)
  if w.len == 0: return ""
  for it in parse(ls):
    if it.name != w: continue
    result = "**" & it.detail & "**" & (if it.doc.len > 0: "\n\n" & it.doc else: "")
    if it.kind == "function":
      var body: seq[string]
      var j = it.line + 1
      while j < ls.len and body.len < 8 and (ls[j].startsWith(" ") or ls[j].startsWith("\t")):
        body.add ls[j].strip
        inc j
      if body.len > 0: result.add "\n\n```sh\n" & body.join("\n") & "\n```"
    return

# Alt+Enter: on a recipe's line, add the comment that says what it does, or make it private; on lines of a
# recipe's body, make them quiet (@: just does not print them)
codeActions("just") do (b: Buf, r: Range) -> seq[Fix]:
  let ls = b.lines
  for it in parse(ls):
    if it.line != r.start.line or it.kind != "function": continue
    let top = rng(pos(it.line, 0), pos(it.line, 0))
    if it.doc.len == 0:
      result.add Fix(title: "Say what " & it.name & " does", edits: @[Edit(range: top, text: "# what it does\n")])
    if it.line == 0 or ls[it.line - 1] != "[private]":
      result.add Fix(title: "Make " & it.name & " private (not in just --list)",
                     edits: @[Edit(range: top, text: "[private]\n")])
  var quiet: seq[Edit]                        # one fix, an edit for each line: one undo step
  for i in r.start.line .. min(r.stop.line, ls.high):
    let t = ls[i].strip(trailing = false)
    if t.len > 0 and t.len < ls[i].len and not t.startsWith("@"):
      let at = pos(i, ls[i].len - t.len)
      quiet.add Edit(range: rng(at, at), text: "@")
  if quiet.len > 0:
    result.add Fix(title: "Do not print " & (if quiet.len == 1: "this line" else: "these lines") & " (@)",
                   edits: quiet)

# snippets: typing the trigger offers them in the completion list
snippet("just", "recipe", "# ${1:what it does}\n${2:name}:\n    $0", "a recipe with its comment")
snippet("just", "var", "${1:name} := \"${2:value}\"$0", "a variable")
snippet("just", "bash", "set shell := [\"bash\", \"-uc\"]$0", "run the recipes with bash")
```

- A [`LangSpec`](api.md#type-langspec) is the fields of the `languages` setting. A new language is coloured by
  ned's generic lexer with its words; `files` names files by their whole name, `nameChars` lets a name have
  `-`, `run` is what F5 runs.
- [`symbols`](api.md#symbols) is the outline: the Outline dock (Alt+I), Go to symbol (Ctrl+T) and the
  breadcrumbs. It takes the place of ned's own outline for the language, so give it for a language you know.
- [`completions`](api.md#completions) get the word typed so far (`prefix`); ned merges the items with its own
  and narrows the list as you type. With `snippet: true`, `insert` has places for Tab (`$1`, `$0`).
- [`hover`](api.md#hover) returns Markdown, shown under ned's own. `wordAt` stops at `-`, so `nameAt` reads the
  name itself.
- [`codeActions`](api.md#codeactions) get the selection, or the cursor's line: their fixes join the problems'
  on Alt+Enter, and ned waits for them (1 s at most). One [`Fix`](api.md#type-fix) can hold an edit for each
  line.
- [`snippet`](api.md#snippet) offers a body when you type its trigger.

**Try it:** open a `justfile`; Alt+I for the outline; Ctrl+Space after a recipe's `:`; hover over a recipe
another one needs; Alt+Enter on a recipe's line, and on a few lines of its body selected; type `recipe` and
choose the snippet.

## 7. A formatter

`sh-format` formats shell scripts (Alt+F, or on save with `editor.formatOnSave`): with
[shfmt](https://github.com/mvdan/sh) when it is installed, else with a small formatter of its own.

<!-- file: formatter.nims -->
```nim
## sh-format — formatters: shell scripts formatted by shfmt when it is installed (a formatter command), else by
## a small formatter written in Nim: no spaces at the ends of lines, one blank line at most, one line end at the end
import nedplugin

requiresNed(">= 6.31")

func tidy(text: string): string =
  ## the text with no spaces at the ends of its lines, no more than one blank line in a row, and one line end at
  ## its end
  var blank = 0
  for l in text.strip(leading = false).splitLines:
    let t = l.strip(leading = false)
    if t.len == 0:
      inc blank
      if blank > 1: continue
    else: blank = 0
    result.add t & "\n"

if findExe("shfmt").len > 0:
  # a command: the text on its standard input, the formatted text on its standard output; ned runs it in the
  # file's folder when you format (Alt+F, or on save)
  formatter("shellscript", "shfmt -i 2 -ci")
else:
  # a formatter in Nim: the text in, the formatted text out — the same text says it is formatted already
  formatter("shellscript") do (text: string) -> string:
    if "<<" in text:
      # a here-document's lines are data: raise to say why the file is left as it is (the status line shows it)
      raise newException(ValueError, "it has a here-document — install shfmt to format it")
    tidy(text)
```

- [`formatter`](api.md#formatter) with a command: ned runs it in the file's folder, the text on its standard
  input, the formatted text on its standard output. Your `formatters` setting wins over a plugin's.
- [`formatter`](api.md#formatter-1) with a proc: the text in, the formatted text out. Raising `ValueError`
  says why not (the status line shows it) and leaves the file as it is. ned waits for it — 3 s, or
  `plugins.timeoutMs` when that is longer.
- The plugin chooses when it starts (`findExe`): install shfmt later, and *Plugins: reload one…* picks it up.

**Try it:** in a `.sh` file, add blank lines and spaces at line ends, and press Alt+F.

## 8. A language server in NimScript

`md-links` is a language server for Markdown, written in NimScript with [`nedlsp`](api.md#nedlsp): a link to a
file that is not there is a problem, a hover over a link says where it goes, completion after `](#` offers the
file's headings as anchors, go to definition follows a link, and the headings are the symbols. It is two
files in `~/.config/ned/plugins/md-links/`: the plugin, `plugin.nims`, says which files the server is for —

<!-- file: lsp_plugin.nims -->
```nim
## md-links — a language server written in NimScript, for Markdown: this file says which files it serves; the
## server is server.nims beside it
import nedplugin

requiresNed(">= 6.31")

languageServerScript("markdown", "server.nims")
```

— and the server is `server.nims`:

<!-- file: lsp_server.nims -->
```nim
## md-links' server — a language server for Markdown written in NimScript: a link to a file that is not there is
## a problem; hover over a link says where it goes; after ](# completion offers the file's headings; go to
## definition follows a link; the headings are the symbols (Go to symbol)
import nedlsp
import std/os

func slug(heading: string): string =
  ## a heading's anchor, as GitHub makes it: lower case, a space a -, other punctuation left out
  for c in heading.toLowerAscii:
    if c in {'a'..'z', '0'..'9', '-', '_'} or ord(c) >= 0x80: result.add c
    elif c == ' ': result.add '-'

func pathOf(uri: string): string =
  ## file:///home/you/my%20notes.md → /home/you/my notes.md
  result = uri
  if result.startsWith("file://"): result = result[7 .. ^1]
  result = result.replace("%20", " ")

func links(l: string): seq[(int, int, string)] =
  ## the links of a line, [text](target): where each target starts and ends (bytes) and the target
  var k = l.find("](")
  while k >= 0:
    let e = l.find(')', k + 2)
    if e < 0: break
    result.add (k + 2, e, l[k + 2 ..< e])
    k = l.find("](", e)

func local(target: string): string =
  ## the file a link goes to when it is one of this computer's ("" for a web address, or #a-heading here)
  let f = target.split('#')[0]
  if f.len == 0 or "://" in f or f.startsWith("mailto:"): "" else: f

proc headings(uri: string): seq[(int, int, string)] =
  ## the document's headings: line, level (# 1, ## 2 …) and text — not the # lines of code blocks
  var code = false
  for i, l in docLines(uri):
    if l.startsWith("```"): code = not code
    elif not code and l.startsWith("#"):
      var n = 0
      while n < l.len and l[n] == '#': inc n
      if n < l.len and l[n] == ' ': result.add (i, n, l[n + 1 .. ^1].strip)

proc check(uri: string) =
  ## a problem for each link to a file that is not there (the whole list, in place of the last one)
  let dir = parentDir(pathOf(uri))
  var diags = newJArray()
  for i, l in docLines(uri):
    for (a, e, t) in links(l):
      let f = local(t)
      if f.len > 0 and not fileExists(dir / f):
        diags.add %*{"range": lspRange(i, a, e, l), "severity": 2, "source": "md-links",
                     "message": "no such file: " & f}
  publishDiagnostics(uri, diags)

proc linkAt(params: JsonNode): (int, string) =
  ## the line and the target of the link at a request's position (-1 when there is none)
  let uri = params["textDocument"]["uri"].getStr
  let ln = params["position"]["line"].getInt
  let ls = docLines(uri)
  if ln >= ls.len: return (-1, "")
  let c = byteCol(ls[ln], params["position"]["character"].getInt)   # the client's column → a byte
  for (a, e, t) in links(ls[ln]):
    if c >= a and c <= e: return (ln, t)
  (-1, "")

# the document's text is kept by the library; these notifications come after it has it
onNotification("textDocument/didOpen") do (params: JsonNode):
  check(params["textDocument"]["uri"].getStr)
onNotification("textDocument/didChange") do (params: JsonNode):
  check(params["textDocument"]["uri"].getStr)

onRequest("textDocument/hover") do (params: JsonNode) -> JsonNode:
  let (ln, t) = linkAt(params)
  if ln < 0: return newJNull()
  let f = local(t)
  let dir = parentDir(pathOf(params["textDocument"]["uri"].getStr))
  let what = if f.len == 0: "a link" elif fileExists(dir / f): "a file of yours" else: "**no such file**"
  %*{"contents": {"kind": "markdown", "value": "→ `" & t & "` — " & what}}

onRequest("textDocument/completion") do (params: JsonNode) -> JsonNode:
  let uri = params["textDocument"]["uri"].getStr
  let ls = docLines(uri)
  let ln = params["position"]["line"].getInt
  var items = newJArray()
  if ln < ls.len:
    let before = ls[ln][0 ..< byteCol(ls[ln], params["position"]["character"].getInt)]
    let k = before.rfind("](#")
    if k >= 0 and ')' notin before[k .. ^1]:
      for (i, n, h) in headings(uri):
        items.add %*{"label": slug(h), "detail": "#".repeat(n) & " " & h, "kind": 18}
  %*{"isIncomplete": false, "items": items}

onRequest("textDocument/definition") do (params: JsonNode) -> JsonNode:
  let uri = params["textDocument"]["uri"].getStr
  let (ln, t) = linkAt(params)
  if ln < 0: return newJNull()
  let f = local(t)
  if f.len > 0:
    let full = parentDir(pathOf(uri)) / f
    if fileExists(full): return %*{"uri": "file://" & full, "range": lspRange(0, 0, 0, "")}
  elif t.startsWith("#"):
    for (i, n, h) in headings(uri):
      if slug(h) == t[1 .. ^1]: return %*{"uri": uri, "range": lspRange(i, 0, 0, "")}
  newJNull()

onRequest("textDocument/documentSymbol") do (params: JsonNode) -> JsonNode:
  let uri = params["textDocument"]["uri"].getStr
  let ls = docLines(uri)
  result = newJArray()
  for (i, n, h) in headings(uri):
    let r = lspRange(i, 0, ls[i].len, ls[i])
    result.add %*{"name": "#".repeat(n) & " " & h, "kind": 15, "range": r, "selectionRange": r}

serve(%*{"hoverProvider": true, "definitionProvider": true, "documentSymbolProvider": true,
         "completionProvider": {"triggerCharacters": ["#"]}})
```

- [`languageServerScript`](api.md#languageserverscript) has ned run the server as `ned --lsp-bridge
  server.nims`, which gives it the protocol's framing. That one command is the server for any editor with a
  language client: Helix, Neovim … run `ned` with the arguments `--lsp-bridge /path/to/server.nims`.
- [`onRequest`](api.md#onrequest) answers a request (its result, or `newJNull()`);
  [`onNotification`](api.md#onnotification) takes a notification; [`serve`](api.md#serve), last, is the loop,
  with the capabilities that tell the editor what the server does.
- The library keeps each document's text ([`docLines`](api.md#doclines)) and turns the editor's columns into
  bytes and back ([`byteCol`](api.md#bytecol), [`lspRange`](api.md#lsprange)).
- [`publishDiagnostics`](api.md#publishdiagnostics) sends a document's problems, all of them each time.
- The server is a program of its own: it cannot use `nedplugin`, and its standard output is the protocol's.
  ned does not show [`logMessage`](api.md#logmessage); [`showMessage`](api.md#showmessage) with an error or a
  warning shows in the status line.

**Try it:** in a Markdown file, link to a file that is not there; hover over a link; type `[top](#` and press
Ctrl+Space; Alt+. (go to definition) on a link; Ctrl+T for the headings.

## 9. A view in the Plugins dock

`bookmarks` has a section of the Plugins dock: the lines you bookmark, by file — a click opens one — with a
row to bookmark the cursor's line and one to clear them all. It keeps them in its data folder.

<!-- file: view.nims -->
```nim
## bookmarks — a view in the Plugins dock: the lines you bookmark, by file — a click opens one; a row to bookmark
## the cursor's line and one to clear them all. They are kept in the plugin's data folder
import nedplugin
import std/algorithm

requiresNed(">= 6.31")

type Mark = object
  path: string                                # the file
  line: int                                   # the line, from 0 (it does not follow later edits)
  text: string                                # what the line said

var
  marks: seq[Mark]
  loaded = false

proc load() =
  ## the bookmarks kept last time, read once
  if loaded: return
  loaded = true
  try:
    for j in parseJson(readData("marks.json")):
      marks.add Mark(path: j{"path"}.getStr, line: j{"line"}.getInt, text: j{"text"}.getStr)
  except CatchableError: discard              # (none yet: readData gave "")

proc store() =
  ## the bookmarks written to the data folder, and the view shown again
  marks.sort(proc(a, b: Mark): int = cmp((a.path, a.line), (b.path, b.line)))
  var a = newJArray()
  for m in marks: a.add %*{"path": m.path, "line": m.line, "text": m.text}
  writeData("marks.json", a.pretty)
  refreshView("Bookmarks")                    # (its rows changed: ned asks for them again)

proc toggle(b: Buf) =
  ## the cursor's line bookmarked — or, when it is, not any more
  load()
  let p = b.path
  if p.len == 0:
    message("Bookmarks: save the file first")
    return
  let l = b.cursor.line
  for i, m in marks:
    if m.path == p and m.line == l:
      marks.delete(i)
      store()
      message("Bookmark removed")
      return
  marks.add Mark(path: p, line: l, text: b.line(l).strip)
  store()
  message("Bookmarked line " & $(l + 1))

view("Bookmarks") do () -> seq[ViewItem]:
  load()
  let root = projectRoot() & "/"
  result.add ViewItem(text: "Bookmark this line", icon: "+", color: "accent", id: "toggle")
  var last = ""
  for m in marks:
    if m.path != last:                        # a file's row, its bookmarks under it
      result.add ViewItem(text: m.path.replace(root, ""), icon: "▸")
      last = m.path
    # a row with a path and no id: a click opens the file at its line
    result.add ViewItem(text: m.text, detail: $(m.line + 1), icon: "•", path: m.path, line: m.line, depth: 1)
  if marks.len > 0:
    result.add ViewItem(text: "Clear them all", icon: "✕", color: "warn", id: "clear")
do (id: string):
  # a row with an id was clicked (a file's row has neither id nor path: it comes here as "")
  case id
  of "toggle": toggle(current())
  of "clear":
    if confirm("Remove all " & $marks.len & " bookmarks?"):
      marks.setLen(0)
      store()
  else: discard

command "Bookmarks: bookmark the line (or not)", "ctrl+alt+b":
  toggle(current())
```

- [`view`](api.md#view-1) gives the rows ([`ViewItem`](api.md#type-viewitem)): a text, a dimmer `detail`, an
  `icon`, a `color`, a `depth` for a tree. A row with a `path` and a `line` opens that file there when
  clicked; a row with an `id` calls the click callback with it.
- ned asks for the rows when the dock shows; [`refreshView`](api.md#refreshview) says they changed.
- `confirm` in a click is fine: ned does not wait for a click.
- The bookmarks are a JSON file of the plugin's data folder ([`writeData`](api.md#writedata),
  [`readData`](api.md#readdata)); `readData` gives "" for a file that is not there, and `parseJson` of "" raises,
  so the first start finds none.

**Try it:** open the Plugins dock (View › Plugins panel), press Ctrl+Alt+B on a few lines, click one in the
BOOKMARKS section.

## 10. Timers

`reminders` looks every 30 seconds for files with changes not saved for longer than its setting, and says so
once; and it sets a reminder of yours, which you can cancel.

<!-- file: timers.nims -->
```nim
## reminders — timers: a note when a file has had changes not saved for a while (`every`), and a reminder you set
## yourself (`after`), which you can cancel (`stopTimer`)
import nedplugin
import std/tables

requiresNed(">= 6.31")

settingDef("unsavedMinutes", 10, "Reminders: say so when a file has had changes not saved for this many minutes " &
           "(0: never)")

var
  dirtySince: Table[int, float]               # a tab with changes not saved → since when (unixTime)
  told: seq[int]                              # the tabs already said
  reminder = -1                               # the timer of the reminder you set (-1: none)

# every 30 seconds — ned keeps the time and calls; keep the work small (a plugin with a timer keeps running)
discard every(30_000) do ():
  let mins = setting("unsavedMinutes", 10)
  if mins <= 0: return
  let now = unixTime()                        # (NimScript has no clock: ned's)
  var seen: Table[int, float]
  for b in buffers():
    if not b.dirty: continue
    let since = dirtySince.getOrDefault(b.id, now)
    seen[b.id] = since
    if now - since >= float(mins * 60) and b.id notin told:
      told.add b.id
      toast(b.title & " has had changes not saved for " & $mins & " minutes")
  dirtySince = seen                           # (saved or closed tabs are forgotten …)
  var still: seq[int]
  for id in told:
    if id in seen: still.add id
  told = still                                # (… and said again when they change again)

proc remind() =
  let what = ask("Remind you of what?", "a break")
  if what.len == 0: return
  let mins = (try: parseInt(ask("In how many minutes?", "25")) except ValueError: 0)
  if mins <= 0:
    warn("Reminders: that is not a number of minutes")
    return
  if reminder >= 0: stopTimer(reminder)       # (one at a time: the new one takes the old one's place)
  reminder = after(mins * 60_000) do ():
    reminder = -1
    toast("Reminder: " & what)
  message("Reminder in " & $mins & " minutes (Reminders: cancel)")

command "Reminders: remind me…":
  remind()

command "Reminders: cancel":
  if reminder < 0:
    message("No reminder is set")
  else:
    stopTimer(reminder)
    reminder = -1
    message("The reminder is cancelled")
```

- [`every`](api.md#every) calls back every so many milliseconds, [`after`](api.md#after) once; both give an id
  for [`stopTimer`](api.md#stoptimer). ned keeps the time: nothing runs between the calls.
- A plugin with a timer keeps its process running, so a timer's work should be small: here a request for the
  tabs and one for each tab, twice a minute.
- [`unixTime`](api.md#unixtime) is ned's clock in seconds. A closure (the `after` callback) may use the
  variables around it, as `what` here.
- [`ask`](api.md#ask) gives "" when you cancel; `parseInt` raises for what is not a number, and the plugin
  catches it.

**Try it:** set `plugins.reminders.unsavedMinutes` to 1 and leave a change unsaved; run *Reminders: remind
me…* with 1 minute.

## 11. Settings and the plugin's data

`daily-log` keeps a log of your day: a line added from anywhere in ned, kept in a file of its own data folder
for each day, and a day's log opened in a tab.

<!-- file: settings_data.nims -->
```nim
## daily-log — settings and the plugin's data: a line added to today's log, a file of the plugin's own data
## folder (no permission needed), and a day's log opened in a tab; its settings in ned's Settings panel
import nedplugin
import std/algorithm

requiresNed(">= 6.31")

# plugins.daily-log.<key> — shown in ned's Settings panel, with their descriptions; the default's type is theirs
settingDef("withTime", true, "Daily log: begin each line with the time (14:03)")
settingDef("heading", "# $date", "Daily log: the first line of a day's log ($date: the day)")
settingDef("days", 14, "Daily log: how many days 'Daily log: open a day…' lists")

proc today(): string = localTime()[0 ..< 10]                  # "2026-10-26"

func fileOf(day: string): string = day[0 ..< 7] & "/" & day & ".md"     # "2026-10/2026-10-26.md": a folder a month

proc addLine() =
  let text = ask("Log:")
  if text.strip.len == 0: return
  let day = today()
  let f = fileOf(day)
  if readData(f).len == 0:                    # ("": there is no such file yet) — a new day: its heading first
    writeData(f, setting("heading", "# $date").replace("$date", day) & "\n\n")
    appendData("days.txt", day & "\n")        # (the days there are: NimScript cannot list a folder when compiled)
  let time = if setting("withTime", true): localTime()[11 ..< 16] & "  " else: ""
  appendData(f, "- " & time & text & "\n")
  toast("Logged")

proc openDay() =
  var days: seq[string]
  for d in readData("days.txt").splitLines:
    if d.len > 0: days.add d
  days.reverse()                              # (the latest first)
  if days.len > setting("days", 14): days.setLen(setting("days", 14))
  if days.len == 0:
    message("Daily log: nothing logged yet (Daily log: add a line…)")
    return
  let i = pick("Which day?", days)
  # the folder's own path: a file there opens as any file — and Ctrl+S saves your edits to it
  if i >= 0: discard openFile(dataDir() / fileOf(days[i]))

command "Daily log: add a line…", "ctrl+alt+l":
  addLine()

command "Daily log: open a day…":
  openDay()
```

- [`settingDef`](api.md#settingdef) shows a setting in ned's Settings panel as `plugins.daily-log.<key>`,
  with its description and default; the default's type (text, a whole number, true or false, a number) is the
  setting's. [`setting`](api.md#setting) reads it, with that default when you have not set it.
- [`dataDir`](api.md#datadir) is `~/.local/share/ned/plugins/daily-log/`; [`writeData`](api.md#writedata),
  [`appendData`](api.md#appenddata) and [`readData`](api.md#readdata) use it by names relative to it, folders
  and all, with no permission (`writeFile` would ask for "files").
- A file of the data folder opens in a tab as any file does, and you can edit and save it.

**Try it:** press Ctrl+Alt+L and type a line, twice; *Daily log: open a day…*; in the Settings panel, search
`daily-log`.

## 12. Permissions and running programs

`git-line` says who last changed the cursor's line (git blame), and fetches from the remote in the
background.

<!-- file: shell.nims -->
```nim
## git-line — permissions and programs: who last changed the cursor's line (git blame, waited for) and a git
## fetch in the background (shellAsync), its result in a note
import nedplugin

requiresNed(">= 6.31")
# what it needs beyond editing, and why: ned reads this line before the plugin runs and asks you once
permission("shell", "runs git: who changed the line, and a fetch in the background")

proc gitAllowed(): bool =
  ## a kinder word than the error when you have not allowed it (yet)
  result = allowed("shell")
  if not result: warn("git-line may not run programs: Plugins dock › git-line › Allow…")

proc blame(b: Buf) =
  if not gitAllowed(): return
  let p = b.path
  if p.len == 0:
    message("git-line: the file is not saved")
    return
  let n = $(b.cursor.line + 1)
  # shell waits for the command — and so do the plugins in the same process: keep it to quick ones
  let (o, code) = shell("git blame --porcelain -L " & n & "," & n & " -- " & quoteShell(extractFilename(p)),
                        parentDir(p))
  if code != 0:
    warn("git blame: " & o.splitLines()[0])
    return
  var author, summary = ""
  for l in o.splitLines:
    if l.startsWith("author "): author = l[7 .. ^1]
    elif l.startsWith("summary "): summary = l[8 .. ^1]
  message("Line " & n & ": " & author & " — " & summary & (if b.dirty: " (as saved)" else: ""))

proc fetch() =
  if not gitAllowed(): return
  status("⟳ git fetch")
  # shellAsync: the plugin goes on; the callback runs when git is done
  shellAsync("git fetch --quiet") do (output: string, code: int):
    status("")
    if code == 0: toast("git fetch: done")
    else: warn("git fetch: " & output.splitLines()[0])

command "Git: who changed this line", "ctrl+alt+g":
  blame(current())

command "Git: fetch in the background":
  fetch()
```

- [`permission`](api.md#permission) says what the plugin needs beyond editing and why. ned reads it — and what
  the source uses — before the plugin runs, and asks you once; the plugin waits in the dock until you allow
  it. A call that was not allowed raises `ValueError`; [`allowed`](api.md#allowed) lets the plugin say it
  more kindly.
- [`shell`](api.md#shell) runs a command and waits: its output (standard output and error) and exit code. The
  plugins in the same process wait with it, so keep it to quick commands. `quoteShell` quotes a path.
- [`shellAsync`](api.md#shellasync) runs one in the background and calls back with its output; the plugin goes
  on meanwhile.

**Try it:** in a file of a git repository, press Ctrl+Alt+G; run *Git: fetch in the background*.

## 13. Asking you: pick, ask, confirm

`word-tools` changes the case of the word at the cursor, chosen from a list, and replaces a word everywhere in
the file once you have said what with and how many.

<!-- file: ask_pick.nims -->
```nim
## word-tools — asking you things: pick a case for the word at the cursor (pick), and replace a word everywhere
## in the file (ask for the new one, confirm how many)
import nedplugin

requiresNed(">= 6.31")

func wordRange(l: string, line, col: int): Range =
  ## the word around column `col` of the line `l` (number `line`)
  var a = col
  var e = col
  while a > 0 and l[a - 1] in IdentChars: dec a
  while e < l.len and l[e] in IdentChars: inc e
  rng(pos(line, a), pos(line, e))

func snake(w: string): string =
  ## fooBar → foo_bar
  for i, c in w:
    if c in {'A'..'Z'}:
      if i > 0 and w[i - 1] notin {'_', 'A'..'Z'}: result.add '_'
      result.add c.toLowerAscii
    else: result.add c

func camel(w: string): string =
  ## foo_bar → fooBar
  var up = false
  for c in w:
    if c == '_': up = true
    elif up:
      result.add c.toUpperAscii
      up = false
    else: result.add c

proc changeCase(b: Buf) =
  let c = b.cursor
  let r = wordRange(b.line(c.line), c.line, c.col)
  if r.isEmpty:
    message("No word at the cursor")
    return
  let w = b.textIn(r)
  let forms = [w.toUpperAscii, w.toLowerAscii, w.toLowerAscii.capitalizeAscii, snake(w), camel(w)]
  # the list shows each form, its name beside it; -1 when you press Esc
  let i = pick("Change " & w & " to…", forms, ["UPPER", "lower", "Capitalised", "snake_case", "camelCase"])
  if i >= 0: b.replace(r, forms[i])

proc replaceEverywhere(b: Buf) =
  let w = b.wordAt(b.cursor)
  if w.len == 0:
    message("No word at the cursor")
    return
  let to = ask("Replace " & w & " with:", w)  # (what you typed, or "" when you press Esc)
  if to.len == 0 or to == w: return
  var places: seq[Range]                      # every place it is a whole word
  for i, l in b.lines:
    var k = l.find(w)
    while k >= 0:
      let e = k + w.len
      if (k == 0 or l[k - 1] notin IdentChars) and (e >= l.len or l[e] notin IdentChars):
        places.add rng(pos(i, k), pos(i, e))
      k = l.find(w, e)
  if not confirm("Replace " & w & " with " & to & " in " & $places.len & " places?"): return
  for i in countdown(places.high, 0):         # (from the last: the places before it stay where they are)
    b.replace(places[i], to)
  toast($places.len & " replaced — Ctrl+Z puts them all back")

command "Word: change its case…", "ctrl+alt+k":
  changeCase(current())

command "Word: replace it everywhere in the file…":
  replaceEverywhere(current())
```

- [`pick`](api.md#pick) shows a list and gives the index chosen (-1 for Esc); the third argument is dimmer text
  beside each item. [`ask`](api.md#ask) gives a line of text ("" for Esc), with a default typed in.
  [`confirm`](api.md#confirm) is yes or no.
- The plugin waits for your answer; ned does not. While ned waits for a plugin (before a save, a formatter, a
  text object), these answer at once: -1, "" and false.
- All the replacements are one undo step, done from the last to the first.

**Try it:** on `someName`, Ctrl+Alt+K and choose snake_case; *Word: replace it everywhere in the file…*.

## 14. Progress, the Output panel, the terminal

`project-tasks` lists the project's TODO and FIXME lines in the Output panel, with its progress in the status
bar, and runs your test command in ned's terminal.

<!-- file: output_terminal.nims -->
```nim
## project-tasks — progress, the Output panel and the terminal: the project's TODO and FIXME lines in the Output
## panel (a click goes to one), with progress in the status bar; and your test command in ned's terminal
import nedplugin

requiresNed(">= 6.31")
permission("shell", "lists the project's files with git and grep, and runs your test command in the terminal")

settingDef("testCommand", "nimble test", "Project tasks: the command 'Project: run the tests' runs in the terminal")

proc projectFiles(): seq[string] =
  ## the project's files: git's list in a repository, else find's (no hidden folders)
  let (o, _) = shell("(git ls-files 2>/dev/null || find . -type f -not -path '*/.*') | head -5000")
  for f in o.splitLines:
    if f.len > 0: result.add (if f.startsWith("./"): f[2 .. ^1] else: f)

proc listTodos() =
  let files = projectFiles()
  var found: seq[string]
  var i = 0
  while i < files.len:                        # grep, 50 files at a time — the progress after each
    progress("TODOs: " & files[i], i * 100 div files.len)
    var cmd = "grep -nIH -E 'TODO|FIXME' --"
    for f in files[i ..< min(i + 50, files.len)]: cmd.add " " & quoteShell(f)
    let (o, _) = shell(cmd & " 2>/dev/null")
    for l in o.splitLines:
      if l.len > 0: found.add l               # file:line:text — ned makes file:line a link
    i += 50
  progressDone()
  if found.len > 0:
    output(found.join("\n"))                  # (one request for all the lines)
    showOutput()
  message($found.len & " TODO and FIXME lines in " & $files.len & " files")

command "Project: list the TODOs":
  listTodos()

command "Project: run the tests", "f6":
  # in ned's terminal, in the project's folder: you see it run and can stop it (Ctrl+C)
  runInTerminal(setting("testCommand", "nimble test"))
```

- [`progress`](api.md#progress) shows work under way in the status bar (and the dock): a text and a percent (-1
  when not known); [`progressDone`](api.md#progressdone) removes it.
- [`output`](api.md#output) writes lines in the Output panel; a line that starts with `file:line` can be
  clicked. One call for all the lines is much quicker than one a line. [`showOutput`](api.md#showoutput) opens
  the panel.
- [`runInTerminal`](api.md#runinterminal) runs a command in ned's terminal, where you see it and can type to it.
  It needs the "shell" permission, as `shell` does.

**Try it:** *Project: list the TODOs* in a project with a few; F6.

## 15. Vim: an operator, text objects, mappings

`sort-motion` adds an operator that sorts (`gs`), text objects for a line (`il`, `al`), mappings that move a
line with a count (`]e`, `[e`), and `:Sort`. They work with vim keys on (`editor.vimMode`).

<!-- file: vim_operator.nims -->
```nim
## sort-motion — vim (editor.vimMode): an operator that sorts (gsip a paragraph's lines, gss the line and as
## many as the count, gsi( the items between brackets), text objects for a line (il its text, al the whole line),
## mappings with a count, and :Sort
import nedplugin
import std/algorithm

requiresNed(">= 6.31")

proc sortRange(b: Buf, r: Range, linewise: bool, reverse = false, unique = false) =
  if linewise or r.start.line != r.stop.line:
    let first = r.start.line
    var last = r.stop.line
    if not linewise and r.stop.col == 0 and last > first: dec last   # (a motion that ends at a line's start)
    var ls = b.lines(first, last)
    ls.sort()
    if reverse: ls.reverse()
    if unique:
      var kept: seq[string]
      for l in ls:
        if kept.len == 0 or kept[^1] != l: kept.add l
      ls = kept
    b.replace(rng(pos(first, 0), pos(last, b.line(last).len)), ls.join("\n"))
  else:
    # within a line: the items between commas — "c, a, b" → "a, b, c"
    var items = b.textIn(r).split(',')
    for it in items.mitems: it = it.strip
    items.sort()
    b.replace(r, items.join(", "))

# gs then a motion or a text object; gss for lines; gs on a visual selection
operator("gs", "sort") do (b: Buf, r: Range, linewise: bool):
  sortRange(b, r, linewise)

# il: the line's text, without its indentation and the spaces at its end — cil, dil, yil, vil
textObject("il", "the line's text") do (b: Buf, p: Pos) -> Range:
  let l = b.line(p.line)
  let t = l.strip
  if t.len == 0: return noRange()             # (nothing there: the operator does nothing)
  let a = l.len - l.strip(trailing = false).len
  rng(pos(p.line, a), pos(p.line, a + t.len))

# al: the whole line, its line end too — from its start to the next line's start: operators take it as lines
textObject("al", "the whole line") do (b: Buf, p: Pos) -> Range:
  b.wholeLines(p.line, p.line)

proc moveLine(down: bool, count: int) =
  ## the cursor's line moved down (or up) past `count` lines; the cursor goes with it
  let b = current()
  let l = b.cursor.line
  let other = if down: min(b.lineCount - 1, l + count) else: max(0, l - count)
  if other == l: return
  let (a, e) = (min(l, other), max(l, other))
  var ls = b.lines(a, e)
  if down:
    ls.add ls[0]                              # the first line to the end
    ls.delete(0)
  else:
    ls.insert(ls[^1], 0)                      # the last line to the start
    ls.setLen(ls.len - 1)
  b.replace(rng(pos(a, 0), pos(e, b.line(e).len)), ls.join("\n"))
  b.setCursor(pos(other, 0))

# ]e and [e move the line; 3]e moves it three lines down
nmap("]e", "move the line down") do (count: int):
  moveLine(true, count)
nmap("[e", "move the line up") do (count: int):
  moveLine(false, count)

# :Sort — the whole file; :Sort r backwards; :Sort u without lines given twice
exCommand("Sort") do (args: string):
  let b = current()
  sortRange(b, b.wholeLines(0, b.lineCount - 1), true, reverse = 'r' in args, unique = 'u' in args)
```

- An [`operator`](api.md#operator-1) takes a motion or a text object (`gsip`, `gs3j`, `gsi(`), its last key
  again for lines (`gss`, `3gss`), or a visual selection (`gs`). It gets the range and whether it is whole
  lines.
- A [`textObject`](api.md#textobject-1) gives the range around the cursor, or [`noRange`](api.md#norange) for
  none. It works after any operator — vim's `d`, `c`, `y` and the plugins' — and in visual mode. A range from
  a line's start to a later line's start counts as whole lines, as `al` is.
- [`nmap`](api.md#nmap-1) gets the count typed before its keys. [`exCommand`](api.md#excommand) gets what
  follows its name.

**Try it:** `gsip` in a paragraph of lines, `gsi(` inside `f(c, a, b)`, `cil`, `dal`, `3]e`, `:Sort u`.

## 16. Tools for the assistant

`editor-tools` gives ned's assistant (Alt+C, its agent mode) three tools: two that only read — what is open,
what is selected — which it calls without asking, and one that changes the text, which asks you first.

<!-- file: ai_tool.nims -->
```nim
## editor-tools — tools for ned's assistant (its agent mode): what is open in the editor and what is selected
## (read-only: called without asking), and text put in place of the selection (it asks you first)
import nedplugin

requiresNed(">= 6.31")

# no arguments: an empty object. The model knows it as plugin__editor-tools__open_files
aiToolReadOnly("open_files", "The files open in the editor, one a line: its path, then * when it has changes " &
               "not saved. The first line is the file being edited.", %*{}) do (args: JsonNode) -> string:
  let cur = current()
  var rows: seq[string]
  for b in buffers():
    let p = b.path
    let row = (if p.len > 0: p else: b.title & " (not a file)") & (if b.dirty: " *" else: "")
    if b.id == cur.id: rows.insert(row, 0) else: rows.add row
  rows.join("\n")

# an argument it may leave out ("optional": true); every other one is required
aiToolReadOnly("selection", "The text selected in the file being edited, after a line with the file and the " &
               "selected lines (counted from 1). Empty when nothing is selected.",
               %*{"maxLines": {"type": "integer", "description": "at most this many lines (200 when not given)",
                               "optional": true}}) do (args: JsonNode) -> string:
  let b = current()
  if not b.valid: raise newException(ValueError, "no file is being edited")   # (what the model reads)
  let r = b.selection
  if r.isEmpty: return ""
  var ls = b.textIn(r).splitLines
  ls.setLen(min(ls.len, args{"maxLines"}.getInt(200)))
  b.path & ":" & $(r.start.line + 1) & "-" & $(r.stop.line + 1) & "\n" & ls.join("\n")

# a tool that changes something: ned asks you before each call (ai.autoApprove)
aiTool("replace_selection", "Put new text in place of the text selected in the file being edited. The file is " &
       "not saved; Ctrl+Z takes it back.",
       %*{"text": {"type": "string", "description": "the new text"}}) do (args: JsonNode) -> string:
  let b = current()
  let r = b.selection
  if r.isEmpty: raise newException(ValueError, "nothing is selected: ask the person to select the text first")
  b.replace(r, args{"text"}.getStr)
  "replaced lines " & $(r.start.line + 1) & "-" & $(r.stop.line + 1) & " (not saved)"
```

- [`aiToolReadOnly`](api.md#aitoolreadonly) is a tool that only reads; [`aiTool`](api.md#aitool) one that
  changes something, which ned asks you about before each call (unless `ai.autoApprove` is all).
- The description and each argument's description are what the model reads: say what it does, and when to use
  it. Every argument is required unless it has `"optional": true`; `%*{}` is a tool with none.
- What the callback returns is what the model gets back; an exception's message is the error it sees.
- The model knows them as `plugin__editor-tools__open_files` and so on.

**Try it:** in the assistant's agent mode, select some text and ask "what have I selected?", then "make the
selection a numbered list".

## 17. The status bar

`selection-stats` shows the lines, words and characters of the selection in the status bar while there is
one.

<!-- file: status_bar.nims -->
```nim
## selection-stats — the status bar: while text is selected, its lines, words and characters. There is no event
## for a selection, so a timer looks twice a second, and the item is sent only when it changes
import nedplugin
from std/unicode import runeLen

requiresNed(">= 6.31")

var shown = ""                                # what the item says now

discard every(500) do ():
  let b = current()                           # (no request: ned says it with the call)
  var s = ""
  if b.valid:
    let r = b.selection                       # (one request)
    if not r.isEmpty:
      let t = b.textIn(r)
      s = "⌗ " & $(r.stop.line - r.start.line + 1) & " lines · " & $t.splitWhitespace.len & " words · " &
          $t.runeLen & " characters"
  if s != shown:
    shown = s
    status(s)                                 # this plugin's item; "" removes it
```

- [`status`](api.md#status) is the plugin's one item in the status bar: each call replaces it, "" removes it.
- There is no event for a selection, so a timer looks twice a second — and sends the item only when it changes.
  In a timer's call, `current()` costs no request.

**Try it:** select some text; then nothing.

## 18. A tab of the plugin's own

`scratch` is a scratch pad in a tab that is not a file: Ctrl+S keeps it in the plugin's data folder, and
Alt+Enter (Enter in vim's normal mode) ticks or unticks a `- [ ]` line — keys that only the pad has.

<!-- file: own_tab.nims -->
```nim
## scratch — a tab of the plugin's own: a scratch pad that is not a file. Ctrl+S keeps it in the plugin's data
## folder (onSaveTab), Alt+Enter (or Enter in vim) ticks a "- [ ]" line — keys only in that tab
import nedplugin

requiresNed(">= 6.31")

const Title = "Scratch"

# a language of its own: saving its tabs, and its keys, are this plugin's — and its own colours
language("scratch", LangSpec(name: "Scratch", lineComment: "#", keywords: @["TODO", "DONE"]))

proc keep(b: Buf) =
  ## the pad's text kept, its tab marked as saved (no ●, no question when it closes)
  writeData("scratch.md", b.text)
  b.markSaved()

proc openPad() =
  # a tab of that title already open is used again — as it is, when it has changes not saved
  let b = newTab(Title, readData("scratch.md"), "scratch")
  if not b.dirty: b.setCursor(pos(0, 0))

proc tick(b: Buf) =
  ## "- [ ]" ↔ "- [x]" on the cursor's line
  let l = b.cursor.line
  let s = b.line(l)
  let k = s.find("- [")
  if k < 0 or k + 4 >= s.len or s[k + 4] != ']': return
  b.replace(rng(pos(l, k + 3), pos(l, k + 4)), (if s[k + 3] == ' ': "x" else: " "))

onSaveTab("scratch") do (ev: Event):          # Ctrl+S (or :w) in the pad: no file name asked for
  keep(ev.buf)
  message("Scratch pad kept")

keyIn("scratch", "alt+enter", "tick or untick the line") do (b: Buf):
  tick(b)

nmapIn("scratch", "<CR>", "tick or untick the line") do (count: int):
  tick(current())

onQuit do (ev: Event):                        # (a pad with changes not saved: kept anyway)
  for b in buffers():
    if b.lang == "scratch" and b.dirty: keep(b)

command "Scratch: open the pad", "ctrl+alt+p":
  openPad()

command "Scratch: close the pad":
  for b in buffers():
    if b.lang == "scratch":
      if b.dirty: keep(b)                     # (a tab that is not a file closes without asking)
      b.closeTab()
```

- [`newTab`](api.md#newtab) opens a tab with a text and a language, or brings back the one of that title.
- A language of the plugin's own (`scratch`) makes the pad's keys and its saving the plugin's:
  [`onSaveTab`](api.md#onsavetab) is called for Ctrl+S (and `:w`) instead of asking for a file name, and
  [`markSaved`](api.md#marksaved) clears its ●. [`keyIn`](api.md#keyin) and [`nmapIn`](api.md#nmapin) are keys
  only in tabs of that language.
- [`closeTab`](api.md#closetab) closes a tab that is not a file without asking, so the plugin keeps the text
  first; [`onQuit`](api.md#onquit) keeps it when ned quits.

**Try it:** Ctrl+Alt+P, type `- [ ] milk`, Alt+Enter, Ctrl+S; close it and open it again.

## 19. Keys that wait: which-key

`leader-hints` shows, when you have pressed the space bar in vim's normal mode and paused, the keys that can
follow — the plugins' `<leader>` mappings — and what each does. ned's own `which-key` plugin does this for
every key and keymap.

<!-- file: key_hints.nims -->
```nim
## leader-hints — keys that wait (which-key): when the space bar (vim's leader) has waited a moment for the next
## key, a box of the plugins' <leader> mappings and what they do; tap one to type it
import nedplugin

requiresNed(">= 6.31")

onKeysWaiting(400) do (keys, mode: string):
  # keys as vim writes them: "<leader>", "<leader>g" …; mode "n" is vim's normal mode
  if mode != "n" or not keys.startsWith("<leader>"): return
  var hints: seq[(string, string)]
  for m in keyMaps():                         # every plugin's mapping, with what it does
    let k = m.keys.replace("<Leader>", "<leader>")
    if m.mode == "n" and k.startsWith(keys) and k.len > keys.len:
      hints.add (k[keys.len .. ^1], (if m.desc.len > 0: m.desc else: m.plugin & "'s"))
  if hints.len > 0:
    # the box shows until the keys waiting change; false when they changed already
    discard showKeyHints(keys, hints)

command "Leader hints: what waits now":
  let (keys, mode) = pendingKeys()            # ("", "") here: the palette was open, nothing waits
  message(if keys.len == 0: "No keys wait" else: keys & " waits (" & mode & ")")
```

- [`onKeysWaiting`](api.md#onkeyswaiting) is called when keys have waited for more, with the keys and the
  mode; [`pendingKeys`](api.md#pendingkeys) asks the same at any time.
- [`keyMaps`](api.md#keymaps) lists every plugin's mappings, operators, text objects and keys, with what they do
  ([`KeyMap`](api.md#type-keymap)).
- [`showKeyHints`](api.md#showkeyhints) shows the box until the keys change; tapping a key in it types it.

**Try it:** with `date-stamp` on (its `<leader>dt`), press the space bar in vim's normal mode and wait.

## 20. Regular expressions

`regex-tools` finds every match of a regular expression in the file and lists them in the Output panel, and
replaces in the selection with groups.

<!-- file: regex.nims -->
```nim
## regex-tools — ned's own regular expressions (NimScript has none): every match in the file listed in the
## Output panel, a click going to it; and a replacement in the selection with groups ($1)
import nedplugin
import std/algorithm

requiresNed(">= 6.31")

proc findAll(b: Buf) =
  let pattern = ask("Find (a regular expression):")
  if pattern.len == 0: return
  let text = b.text
  var starts = @[0]                           # where each line starts in the text
  for i, c in text:
    if c == '\n': starts.add i + 1
  var rows: seq[string]
  try:
    for m in regexMatches(pattern, text):     # one request for the whole text, not one a line
      let line = upperBound(starts, m.start) - 1
      let col = m.start - starts[line]
      rows.add b.path & ":" & $(line + 1) & ":" & $(col + 1) & ": " & text[m.start ..< min(m.stop, m.start + 80)]
  except ValueError as e:
    warn(e.msg)                               # (not a regular expression: ned says why)
    return
  output(rows.join("\n"))
  showOutput()
  message($rows.len & " matches")

proc replaceIn(b: Buf) =
  let sel = b.selection
  let r = if sel.isEmpty: rng(pos(0, 0), pos(b.lineCount - 1, b.line(b.lineCount - 1).len)) else: sel
  let pattern = ask("Replace (a regular expression):")
  if pattern.len == 0: return
  let repl = ask("With ($0 the match, $1 … $9 its groups):")
  try:
    let (t, n) = regexReplace(pattern, b.textIn(r), repl)
    if n > 0: b.replace(r, t)
    message($n & " replaced" & (if sel.isEmpty: " in the file" else: " in the selection"))
  except ValueError as e:
    warn(e.msg)

command "Regex: find every match…":
  findAll(current())

command "Regex: replace in the selection…":
  replaceIn(current())
```

- NimScript has no regular expressions; [`regexMatches`](api.md#regexmatches) and
  [`regexReplace`](api.md#regexreplace) use ned's own (its search's), one request each. A pattern that is not
  one raises `ValueError` with ned's words.
- A [`RegexMatch`](api.md#type-regexmatch) is byte offsets in the text: the plugin turns them into lines and
  columns with the lines' starts.

**Try it:** *Regex: find every match…* with `\d+`; select some lines and replace `(\w+)=(\w+)` with `$2=$1`.

## More

- [Plugins](README.md): how plugins run, permissions, settings, debugging and limits.
- [The tutorial](tutorial.md): one plugin, built step by step — and how to test a plugin without the editor
  ([Testing](tutorial.md#testing)).
- [The API reference](api.md): every proc and type, with its documentation.
- [ned's own plugins](available.md): fifty-eight more, from small (dial) to large (oil, rest-client); *View its
  source* in the Plugins dock shows each.

## 21. Panes and multibuffers

`word-places` puts every line of the open files that has the word at the cursor in one multibuffer, to edit them
together; opens a module's test in a pane beside it; and, in a multibuffer, opens the file behind the cursor.

<!-- file: panes_pieces.nims -->
```nim
## word-places — panes and multibuffers: every line of the open files with the word at the cursor, in one tab to
## edit them together; the test of a module beside it; and the file behind the cursor of a multibuffer
import nedplugin

requiresNed(">= 6.31")

proc wordPlaces() =
  let b = current()
  let w = b.wordAt(b.cursor)
  if w.len == 0:
    message("Put the cursor on a word first")
    return
  var ps: seq[Piece]
  for x in buffers():
    if x.path.len == 0 or x.isMultibuffer: continue
    let ls = x.lines                          # (all its lines at once: one request, not one a line)
    for i, l in ls:
      if w in l: ps.add piece(x.path, max(0, i - 1), min(ls.high, i + 1))   # (a line around it)
  if ps.len == 0:
    message("No open file has " & w)
    return
  discard openMultibuffer("“" & w & "” in the open files", ps)

proc testBeside() =
  ## tests/test_<module>.nim beside the module, in a pane at its right
  let b = current()
  let (_, name, _) = splitFile(b.path)
  let test = projectRoot() / "tests" / ("test_" & name & ".nim")
  var here = 0
  for p in panes():
    if p.path == test:
      focusPane(p.index)                      # (it is shown already: go there)
      return
    if p.active: here = p.index
  if not fileExists(test):
    message("No tests/test_" & name & ".nim")
    return
  let t = openFile(test)                      # (it comes to the front of this pane …)
  showInPane(here, b)                         # (… the module goes back there)
  if splitPane(show = t) < 0: message("No room for another pane")

proc fileHere() =
  let b = current()
  let (path, at) = b.placeInFile(b.cursor)
  if path.len == 0:
    message("Not in a piece of a multibuffer")
    return
  discard openFile(path, at.line, at.col)

command "Word places: every line with this word, together":
  wordPlaces()

command "Word places: the module's test beside it":
  testBeside()

command "Word places: the file behind the cursor":
  fileHere()

command "Word places: two columns, the same size":
  paneLayout("columns 2")
  paneLayout("equal")
```

- [`openMultibuffer`](api.md#openmultibuffer) makes one tab of [`piece`](api.md#piece)s of files — here a line
  around each use of the word; pieces of a file that touch become one. Ctrl+S in it writes each edited piece back
  to its file. [`isMultibuffer`](api.md#ismultibuffer) leaves multibuffers out of the search.
- [`panes`](api.md#panes) lists the panes with their files; [`focusPane`](api.md#focuspane) goes to one,
  [`showInPane`](api.md#showinpane) puts a file in one and [`splitPane`](api.md#splitpane) cuts the pane with the
  focus in two, the new one showing the file it is given.
- [`placeInFile`](api.md#placeinfile) maps a place of a multibuffer to its file and line.
- [`paneLayout`](api.md#panelayout) lays the open files out in columns, a grid, or one large and three.

**Try it:** open two or three files, put the cursor on a name they share, *Word places: every line with this word,
together*; change one of the lines and Ctrl+S. In `src/app.nim` (with `tests/test_app.nim`), *Word places: the
module's test beside it*.
