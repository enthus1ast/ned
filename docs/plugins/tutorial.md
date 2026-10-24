# Writing a plugin: a tutorial

This tutorial builds one plugin, **notes**, step by step. notes finds the notes people leave in their files —
`NOTE: …`, `TODO: …`, `FIXME: …`, and `TODO(ann): …` with a name — and each step makes it do one more useful
thing with them: a command that adds a note, a list to jump to one, marks in the editor with quick fixes, a
setting, a view in the Plugins dock, completion and hover, vim keys, a reminder, and a tool for the assistant.

The finished plugin is [`examples/plugins/notes/plugin.nims`](../../examples/plugins/notes/plugin.nims). Every
block of Nim below is a piece of that file, in the order the file has them, except the two that steps 10 and 11
mark as separate plugins. The plugin tests run it ([step 12](#12-testing-debugging-performance-sharing-safety)),
so the code works as written.

ned has a TODO list of its own (View › TODOs, Alt+V). notes is a tour of the plugin API, and it adds what that
list does not have: quick fixes on Alt+Enter, markers of your own, completion, a tool for the assistant.

**What you need.** ned 6.20 or newer, and `nim` on your PATH: ned runs plugins with it (on Termux,
`pkg install nim`). A little Nim helps. A plugin is written in NimScript, which is Nim run by the compiler's VM,
the language of `config.nims`.

**One rule for the whole API.** Lines and columns count from 0, and a column is a byte offset in the line
(UTF-8), not a count of characters. A `Range` goes from `start` up to `stop`, and `stop` itself is not included.

1. [Where a plugin lives](#1-where-a-plugin-lives)
2. [A first command: read and change the text](#2-a-first-command-read-and-change-the-text)
3. [Talking to the user](#3-talking-to-the-user)
4. [Events: mark the notes as you type](#4-events-mark-the-notes-as-you-type)
5. [Settings](#5-settings)
6. [A view, the Output panel, progress](#6-a-view-the-output-panel-progress)
7. [A language's features](#7-a-languages-features)
8. [For vim users](#8-for-vim-users)
9. [Timers and the assistant](#9-timers-and-the-assistant)
10. [A language server in NimScript](#10-a-language-server-in-nimscript)
11. [A plugin in full Nim](#11-a-plugin-in-full-nim)
12. [Testing, debugging, performance, sharing, safety](#12-testing-debugging-performance-sharing-safety)

## 1. Where a plugin lives

A plugin is a folder with a file called `plugin.nims` in it. ned looks in two places:

- `~/.config/ned/plugins/<name>/` holds your plugins, for every project.
- `.ned/plugins/<name>/` in a project holds that project's plugins. They run only once you trust the folder
  (*Workspace: trust this folder*), the same as a project's settings that start programs.

The folder's name is the plugin's name, in the Plugins dock and in its settings (`plugins.notes.…`).

The quickest way to start is the palette (Ctrl+E): run *Plugins: new plugin…* and type `notes`. ned writes
`~/.config/ned/plugins/notes/plugin.nims` from a template, opens it and runs it. Keep the `##` comment at the top,
write in it what your plugin does, and replace the rest of the template with this:

```nim
import nedplugin

requiresNed(">= 6.20")
```

`import nedplugin` is the whole API. While you edit a plugin, ned shows the documentation of each of its procs,
types and fields on hover, and completion after `b.` lists what a buffer offers. *Plugins: the API
(nedplugin.nim)* opens the library's source, and [the API reference](api.md) is the same documentation as a page.

`requiresNed(">= 6.20")` names the ned the plugin needs. An older ned leaves the plugin out and says why, and
6.20 is where the API this tutorial uses is complete.

A plugin's top-level code runs once, when the plugin starts. It does not do the work itself: it *registers*
things (commands, events, views and so on), and ned calls them back when they are needed. ned runs all your
NimScript plugins together in one process (`nim e`, about a second to start) and talks to it in lines of JSON.

**Saving reloads it.** Each time you save a plugin's file, ned starts its plugins again with the new code. If the
file does not compile, the error is in the Problems panel and at its line in the file; that plugin is left out
and the others run.

**The Plugins dock** (View › Plugins panel) shows the plugin processes, each plugin with everything it
registered, and the plugins' **log**, where `echo` and `log(text)` write. Click a plugin to turn it off, reload
just it, or run it in a process of its own; the dock's ⓘ opens the API and ⟳ reloads every plugin.

*Try it:* save the file and open the Plugins dock. `● notes` is under YOURS. It does nothing yet.

## 2. A first command: read and change the text

The first command adds a TODO at the end of the cursor's line, in a comment of the file's language: `x = 1`
becomes `x = 1  # TODO: ` in Nim or Python, and `x = 1;  // TODO: ` in C.

```nim
func withNote(l, cm, marker, text: string): string =
  ## the line with `marker: text` in a comment at its end (on a blank line the note is the line)
  let note = (if cm.len > 0: cm & " " else: "") & marker & ": " & text
  if l.strip.len == 0: l & note else: l & "  " & note

proc addNote(b: Buf, line: int, marker, text: string) =
  ## a note added to the line, the cursor after it
  let s = withNote(b.line(line), b.lineComment, marker, text)
  b.replace(b.lineRange(line), s)
  b.setCursor(pos(line, s.len))

command "Notes: add a TODO", "ctrl+alt+n":
  let b = current()
  let l = b.cursor.line
  addNote(b, l, "TODO", "")
  log("a TODO at line " & $(l + 1) & " of " & b.path)
```

What it uses:

- `command "title", "keys": …` puts a command in the palette, on a key. Keys are written `"ctrl+alt+n"`,
  `"alt+shift+k"`, `"f9"`, and your own `keys` setting wins over a plugin's. Leave the keys out
  (`command "title": …`) for a command that is only in the palette. The dock lists a plugin's commands too (click
  one to run it), and so does *Plugins: run a plugin's command…*. When ned already has a command of the same name,
  the plugin's is called `notes: …`.
- `current()` is the file being edited, a `Buf`. Everything about a file is asked through it: `b.cursor` is a
  `Pos` (`line`, `col`), `b.line(i)` is line i without its line end, `b.lineComment` is the language's line
  comment (`"#"`, `"//"`, or `""` for none), and `b.lineRange(i)` is line i as a `Range`.
- `b.replace(range, text)` is the edit. `b.insert(pos, text)` and `b.delete(range)` are shorter ways to write
  one, and `b.setText(s)` replaces the whole text (ned changes only the lines that differ).
- `b.setCursor(pos)` moves the cursor, and `pos(line, col)` makes a `Pos`. `log(text)` writes in the log.

**One undo step.** All the edits a plugin makes in one call (a command, a fix, an operator) are one step of
undo. Ctrl+Z takes back the whole command, however many edits it made.

**Each API call is a question to ned.** `b.line(l)` sends a message to ned and waits for the answer. That takes
a few milliseconds in `nim e`, and it adds up: when you need many lines, ask for `b.lines` once, as the next part
does. A helper that does not talk to ned, like `withNote`, can be a `func`: it is plain Nim, and easy to test.

A command's body cannot `return` (it is the body of a template, and Nim says *'return' not allowed here*). Put
the work in a `proc` and call it, or use `if`. The `do` blocks of the later steps can `return`.

*Try it:* save, open a file, put the cursor on a line and press Ctrl+Alt+N, then type what is left to do.
Ctrl+Z removes the note again, and the dock's log says `a TODO at line …`. A terminal does not pass every key:
if Ctrl+Alt+N does nothing in yours, run the command from the palette or give it a key of your own
([key bindings](../guide/keys.md)).

### Finding the notes

Every later step needs a file's notes. A note is a marker (`TODO`), perhaps a name in brackets, a colon, and
what it says:

```nim
type Note = object
  ## a note: its marker and what it says
  line, col: int                 ## where its marker is (col: a byte offset in the line)
  marker: string                 ## "TODO"
  textCol: int                   ## where what it says starts
  text: string                   ## what it says

proc markers(): seq[string] =
  ## the words that start a note: plugins.notes.markers in your settings (step 5)
  setting("markers", "NOTE TODO FIXME").splitWhitespace

func colonAfter(l: string, k, n: int): int =
  ## where the text starts when the n bytes at k are a marker — a colon after it, or a name in brackets and a
  ## colon — and not the end of a longer word; -1 when they are not
  if k > 0 and l[k - 1] in IdentChars: return -1
  var e = k + n
  if e < l.len and l[e] == '(':
    e = l.find(')', e) + 1
    if e == 0: return -1
  if e < l.len and l[e] == ':': e + 1 else: -1

func findNotes(lines, ms: seq[string], first = 0): seq[Note] =
  ## the notes in the lines, one a line (the first one); `first` is the number of lines[0] in the file
  for i, l in lines:
    var best = Note(col: -1)
    for m in ms:
      var k = l.find(m)
      while k >= 0:
        let t = colonAfter(l, k, m.len)
        if t >= 0:
          if best.col < 0 or k < best.col:
            var a = t
            while a < l.len and l[a] == ' ': inc a
            var s = l[a .. ^1].strip(leading = false)
            for close in ["*/", "-->"]:            # (the end of a block comment is not part of the note)
              if s.endsWith(close): s = s[0 ..< s.len - close.len].strip(leading = false)
            best = Note(line: first + i, col: k, marker: m, textCol: a, text: s)
          break
        k = l.find(m, k + 1)
    if best.col >= 0: result.add best
```

`markers()` reads a setting, with a default; step 5 shows it in the Settings window. `findNotes` is plain Nim
over strings. Nim's `find` gives byte offsets, which is what ned's columns are, so nothing needs converting. It
takes the first note of each line, skips a marker that is the end of a longer word (`MYTODO:`), and leaves the
end of a block comment (`*/`, `-->`) out of what the note says.

## 3. Talking to the user

Two commands use the notes: one lists them to jump to, one asks what to write.

```nim
func plural(n: int, word: string): string = $n & " " & word & (if n == 1: "" else: "s")

proc chooseNote(ms: seq[string]) =
  ## the file's notes in a list: the one you choose is where the cursor goes
  let b = current()
  let ns = findNotes(b.lines, ms)
  if ns.len == 0:
    message("No " & ms.join(" or ") & " in this file")
    return
  var items, details: seq[string]
  for n in ns:
    items.add n.marker & ": " & n.text
    details.add "line " & $(n.line + 1)
  let i = pick(plural(ns.len, "note") & " in " & extractFilename(b.path), items, details)
  if i >= 0: b.setCursor(pos(ns[i].line, ns[i].col))

command "Notes: go to a note…":
  chooseNote(markers())

command "Notes: add a note…":
  let ms = markers()
  let k = pick("Which kind of note?", ms)
  let text = if k >= 0: ask(ms[k] & ":") else: ""
  if text.len > 0:
    let b = current()
    addNote(b, b.cursor.line, ms[k], text)
    toast(ms[k] & " added")
```

The ways to talk to you:

- `message(text)` writes in the status line, and `warn(text)` writes there as a warning.
- `toast(text)` shows a note in the corner that goes away by itself.
- `pick(title, items, details)` is a list to choose from. It gives the index chosen, or -1 when you press Esc;
  `details` is the dimmer text beside each item.
- `ask(prompt, default)` asks for a line of text, and gives `""` when cancelled.
- `confirm(question)` asks yes or no.

`pick`, `ask` and `confirm` wait for you: the plugin's code stops at that line until you answer. ned does not
ask while it is waiting for a plugin itself (in an `onBeforeSave` event or a formatter); there they give -1, `""`
and false at once.

The third command removes the notes marked done (step 4 adds a fix that turns a `TODO` into `DONE`), once you
say yes:

```nim
func removal(l: string, n: Note, cm: string, lineCount: int): Range =
  ## what removing the note takes away: the comment it is in and the spaces before it — the whole line when the
  ## note is all the line has; noRange() when the comment says more than the note
  var a = n.col
  let before = l[0 ..< n.col].strip(leading = false)
  if cm.len > 0 and before.endsWith(cm): a = before.len - cm.len
  elif before.strip.len > 0: return noRange()
  while a > 0 and l[a - 1] in Whitespace: dec a
  if a > 0: rng(pos(n.line, a), pos(n.line, l.len))
  elif n.line + 1 < lineCount: rng(pos(n.line, 0), pos(n.line + 1, 0))
  else: rng(pos(n.line, 0), pos(n.line, l.len))

proc removeDone(b: Buf) =
  ## the file's DONE notes removed, once you have said yes
  let done = findNotes(b.lines, @["DONE"])
  if done.len == 0:
    message("No DONE notes in this file")
    return
  if not confirm("Remove the " & plural(done.len, "DONE note") & " of this file?"): return
  let cm = b.lineComment
  var n = 0
  for i in countdown(done.high, 0):     # (from the last one up: the lines above it stay where they are)
    let r = removal(b.line(done[i].line), done[i], cm, b.lineCount)
    if not r.isEmpty:
      b.delete(r)
      inc n
  toast("Removed " & plural(n, "note") & " — Ctrl+Z puts them all back")

command "Notes: remove the DONE notes…":
  removeDone(current())
```

`removal` works out what to take away: the comment and the spaces before it, or the whole line when the note is
all the line has. `rng(a, b)` makes a `Range`. When the comment says more than the note, `removal` gives
`noRange()`, the API's "no range" (`isEmpty` is true for it), and that note stays. The notes go from the last one
up, so the lines of the notes above have not moved yet when their turn comes. As in step 2, all the removals are
one undo step.

*Try it:* run *Notes: add a note…*, pick FIXME and type a few words. *Notes: go to a note…* lists the file's
notes: pick one and the cursor goes there. Change a `TODO` into `DONE` by hand, then run *Notes: remove the DONE
notes…*.

## 4. Events: mark the notes as you type

Commands run when you ask; events run when something happens to a file. notes marks a file's notes when it
opens and again each time it changes. First some small helpers, and `mark`, which shows a file's notes:

```nim
func severityOf(marker: string): int =
  ## FIXME a warning, NOTE a hint, the others information
  case marker
  of "FIXME": 2
  of "NOTE": 4
  else: 3

func colorOf(marker: string): string =
  case marker
  of "FIXME": "warn"
  of "NOTE": "hint"
  else: "info"

func iconOf(marker: string): string =
  case marker
  of "FIXME": "!"
  of "NOTE": "✎"
  else: "○"

proc showCount(n: int) =
  ## this plugin's item in the status bar: the notes of the file you see
  status(if n == 0: "" else: "✎ " & plural(n, "note"))

proc mark(b: Buf) =
  ## the file's notes: in Problems (Alt+Enter: mark it done, remove it), a sign in the gutter, the marker
  ## highlighted, a word after a note that says nothing; their count in the status bar
  let lines = b.lines
  let cm = b.lineComment
  let notes = findNotes(lines, markers())
  var problems: seq[Problem]
  b.clearDecorations()
  for i, n in notes:
    let word = rng(pos(n.line, n.col), pos(n.line, n.col + n.marker.len))
    var p = Problem(range: rng(word.start, pos(n.line, n.textCol + n.text.len)), severity: severityOf(n.marker),
                    message: n.marker & ": " & (if n.text.len > 0: n.text else: "(nothing yet)"))
    p.fixes.add Fix(title: "Mark it done", edits: @[Edit(range: word, text: "DONE")])
    let r = removal(lines[n.line], n, cm, lines.len)
    if not r.isEmpty: p.fixes.add Fix(title: "Remove the note", edits: @[Edit(range: r, text: "")])
    problems.add p
    if i < 100:                         # (each of these is a call to ned: the first 100 notes)
      b.sign(n.line, iconOf(n.marker), colorOf(n.marker))
      b.highlight(word, colorOf(n.marker))
      if n.text.len == 0: b.virtualText(n.line, "← what is it?", "warn")
  if setting("problems", true): b.setProblems(problems)
  else: b.clearProblems()
  if b.id == current().id: showCount(notes.len)
  refreshView("Notes")                  # (the view of step 6)
```

What `mark` puts in the editor:

- `b.setProblems(problems)` puts the notes in the Problems panel; they are underlined in the text, marked in the
  gutter, and Alt+N / Alt+P go from one to the next. Each call replaces the problems this plugin set in that file
  before, and `b.clearProblems()` removes them. `severity` is 1 for an error, 2 a warning, 3 information, 4 a
  hint. A problem's `fixes` are what Alt+Enter offers on its line: each `Fix` has a title and its `Edit`s (a
  range, and the text that goes there), applied as one undo step.
- `b.sign(line, text, color)` puts one character in the gutter, `b.highlight(range, color)` tints the text's
  background, and `b.virtualText(line, text, color)` shows text after the end of the line (it is not in the
  file). The colours are `error warn info hint accent add del`, or `"#rrggbb"`. `b.clearDecorations()` removes
  this plugin's signs, highlights and texts in the file, and leaves other plugins' alone. They stay on their lines
  while you type, so a plugin whose marks should follow the text sets them again, as `mark` does on each change.
- `status(text)` is this plugin's item in the status bar, and `""` removes it.

`mark` puts signs and highlights on the first 100 notes only, because each one is a call to ned, while
`setProblems` sends all the problems in one call. Its last line, `refreshView("Notes")`, is for the view of step 6, and does nothing
until there is one. Now the events:

```nim
onOpen("*") do (ev: Event): mark(ev.buf)
onChange("*") do (ev: Event): mark(ev.buf)

onSave("lang:nim") do (ev: Event):
  # a Nim file saved with a FIXME in it: a warning in the status line
  let n = findNotes(ev.buf.lines, @["FIXME"]).len
  if n > 0: warn(extractFilename(ev.path) & " still has " & plural(n, "FIXME"))
```

Each event gets an `Event`: the file (`ev.buf`), its path (`ev.path`) and its language (`ev.lang`). The pattern
says which files: `"*"` is every file, `"*.md"` matches the name, `"src/*.nim"` a path in the project, and
`"lang:nim"` a language. `onOpen` also runs for the files that are open when ned starts, and `onChange` runs after
a pause in the typing, not on every key. The other events are `onStartup`, `onBeforeSave` (what it changes is
saved with the file; ned waits for it), `onClose`, and `autocmd("BufWritePost", "*.nim")` with vim's names.

An event can be registered more than once, also for the same pattern: each handler runs, in the order the plugin
registered them (ned 6.24 and newer; before, a second `onChange("*")` in one plugin took the first one's place).

*Try it:* open a file with a few notes (or add some). Each note has a sign and a tinted marker, the status bar
counts them, and the Problems panel lists them. On a note's line, Alt+Enter offers *Mark it done* and *Remove
the note*. Save a Nim file with a FIXME in it.

## 5. Settings

notes has three settings:

```nim
settingDef("markers", "NOTE TODO FIXME", "The words that start a note, a colon after each (TODO: …, TODO(ann): …)")
settingDef("problems", true, "Show the notes in the Problems panel (Alt+Enter on one: mark it done, remove it)")
settingDef("reminderMinutes", 25, "Notes: remind me later — in how many minutes")
```

`settingDef(key, default, description)` declares a setting. ned's Settings window (*Settings* in the palette)
shows it among the Plugins settings as `plugins.notes.markers`, with its description and its default. The
default's type is the setting's type: a string, a whole number, true or false, or a number.

`setting(key, default)` reads it; you have seen it in `markers()` and in `mark`. It gives the default when the
setting is not set, or is not of the default's type. A plugin can read a setting it has not declared, but then
it is not in the Settings window. Read a setting where you use it, as notes does: a change applies at the next
call, without a reload.

In your settings file (`~/.config/ned/config.json`, see [settings](../guide/settings.md)) a plugin's settings are
written flat, or in one object for the plugin; this shows both:

```json
{
  "plugins.notes.markers": "NOTE TODO FIXME HACK",
  "plugins": {"notes": {"problems": false}}
}
```

*Try it:* in the Settings window, set `plugins.notes.markers` to `NOTE TODO FIXME HACK` and type `# HACK: …` in
a file. Set `plugins.notes.problems` off: the signs stay, and the notes leave the Problems panel.

## 6. A view, the Output panel, progress

So far notes knows only the files you open. This step finds the notes of the whole project, shows them in the
Output panel, and gives notes a section of its own in the Plugins dock. First the files and the search:

```nim
proc projectFiles(): seq[string] =
  ## the project's files: git's list in a repository, else find's (no hidden folders) — 2000 at most
  let list = "test -d .git && git ls-files || find . -type f -not -path '*/.*'"
  let (o, _) = shell("(" & list & ") 2>/dev/null | sort | head -2000")
  for f in o.splitLines:
    if f.len > 0: result.add (if f.startsWith("./"): f[2 .. ^1] else: f)

proc scan(files, ms: seq[string]): seq[(string, Note)] =
  ## the notes of the files (paths from the project's folder): grep finds the lines, 50 files at a time
  var pattern = ""
  for m in ms: pattern.add " -e " & quoteShell(m)
  var i = 0
  while i < files.len:
    if files.len > 50: progress("Notes: " & files[i], i * 100 div files.len)
    var cmd = "grep -nIH -F" & pattern & " --"
    for f in files[i ..< min(i + 50, files.len)]: cmd.add " " & quoteShell(f)
    let (o, _) = shell(cmd & " 2>/dev/null")
    for l in o.splitLines:
      # file:line:text
      let a = l.find(':')
      let c = l.find(':', a + 1)
      if a < 0 or c < 0: continue
      let ln = (try: parseInt(l[a + 1 ..< c]) - 1 except ValueError: -1)
      if ln < 0: continue
      for n in findNotes(@[l[c + 1 .. ^1]], ms, ln): result.add (l[0 ..< a], n)
    i += 50
  progressDone()
```

`shell(cmd)` runs a command in the project's folder (`shell(cmd, dir)` in another) and gives its output and exit
code; `quoteShell` makes a path safe to put in one. grep does the reading: it skips binary files, and a file it
cannot read is no error to it, while in NimScript an error of `readFile` cannot be caught. (The plugin's own
process does not run in the project's folder: a path for `readFile` starts from `projectDir()`, as in
`projectDir() & "/src/app.nim"`.)

`progress(text, percent)` shows work under way in the status bar (a percent of -1 when you do not know it), and
`progressDone()` removes it. Now the view, and the command that fills it:

```nim
var found: seq[(string, Note)]          # the project's notes, once you have asked for them
var viewBuf = -1                        # the file the view shows

view("Notes") do () -> seq[ViewItem]:
  let b = current()
  if b.valid:
    viewBuf = b.id
    for n in findNotes(b.lines, markers()):
      result.add ViewItem(text: n.marker & ": " & n.text, detail: "line " & $(n.line + 1), icon: iconOf(n.marker),
                          color: colorOf(n.marker), id: $n.line & ":" & $n.col)
  if result.len == 0: result.add ViewItem(text: "(no notes in this file)", color: "hint")
  if found.len > 0:
    result.add ViewItem(text: "In the project: " & plural(found.len, "note"), color: "accent")
    var last = ""
    for (f, n) in found:
      if f != last:
        result.add ViewItem(text: f, icon: "▸", depth: 1)
        last = f
      result.add ViewItem(text: n.marker & ": " & n.text, detail: $(n.line + 1), icon: iconOf(n.marker),
                          color: colorOf(n.marker), path: f, line: n.line, depth: 2)
do (id: string):
  # (a note of the file: its id is line:col — the project's have a path and no id, and ned opens them)
  let b = current()
  let p = id.split(':')
  if p.len == 2 and b.valid and b.id == viewBuf: b.setCursor(pos(parseInt(p[0]), parseInt(p[1])))

command "Notes: find the project's notes":
  let files = projectFiles()
  found = scan(files, markers())
  var lines: seq[string]
  for (f, n) in found:
    lines.add f & ":" & $(n.line + 1) & ":" & $(n.col + 1) & ": " & n.marker & ": " & n.text
  if lines.len > 0:
    output(lines.join("\n"))            # (one call for all of them)
    showOutput()
  refreshView("Notes")
  message("Notes: " & plural(found.len, "note") & " in " & plural(files.len, "file"))
```

- `view("Notes") do () -> seq[ViewItem]: …` is a section of the Plugins dock. ned asks for its items when the
  dock is shown, and again after `refreshView("Notes")`, which `mark` calls after each change. A `ViewItem` has a
  `text`, a dimmer `detail`, an `icon` (one character), a `color`, a `depth` (its indentation, for a tree), and
  either an `id` (what the click callback, `do (id: string): …`, gets) or a `path` and `line` (clicking opens
  that file there).
- `output(text)` writes lines in the Output panel, where a `file:line:col` at the start of a line can be clicked,
  and `showOutput()` shows the panel. One `output` call with all the lines is much quicker than one call a line.
  (`b.valid` is false when there is no file: `current()` then gives a `Buf` with id -1.)

*Try it:* open the Plugins dock: its NOTES section lists the file's notes, and clicking one moves the cursor
there. Run *Notes: find the project's notes*: the Output panel lists every note (click one to open its file),
and the dock lists them under the file's own.

## 7. A language's features

A plugin can give a language what a language server gives. notes gives its features to every file:

```nim
completions("*") do (b: Buf, p: Pos, prefix: string) -> seq[CompletionItem]:
  # the markers, in a comment (anywhere in a file whose language has no line comment)
  let cm = b.lineComment
  let l = b.line(p.line)
  if cm.len > 0 and cm notin l[0 ..< min(p.col, l.len)]: return
  for m in markers():
    if m.startsWith(prefix.toUpperAscii):
      result.add CompletionItem(label: m, insert: m & ": $0", snippet: true, kind: "keyword", detail: "a note",
                                doc: "`" & m & ": …` — the notes plugin lists it and marks it")

hover("*") do (b: Buf, p: Pos) -> string:
  # on a marker: the file's notes of that kind
  let w = b.wordAt(p)
  if w notin markers(): return ""
  let ns = findNotes(b.lines, @[w])
  var rows: seq[string]
  for n in ns[0 ..< min(ns.len, 10)]:
    rows.add "- line " & $(n.line + 1) & ": " & (if n.text.len > 0: n.text else: "*(nothing yet)*")
  "**" & w & "** — " & plural(ns.len, "note") & " in this file\n\n" & rows.join("\n")

codeActions("*") do (b: Buf, r: Range) -> seq[Fix]:
  # the cursor's line: its note made another kind (TODO → FIXME …), or a TODO added to it
  let l = r.start.line
  let s = b.line(l)
  let ms = markers()
  let ns = findNotes(@[s], ms, l)
  if ns.len == 0:
    result.add Fix(title: "Add a TODO to this line",
                   edits: @[Edit(range: rng(pos(l, 0), pos(l, s.len)), text: withNote(s, b.lineComment, "TODO", ""))])
  else:
    let n = ns[0]
    let word = rng(pos(l, n.col), pos(l, n.col + n.marker.len))
    for m in ms:
      if m != n.marker: result.add Fix(title: "Make it a " & m, edits: @[Edit(range: word, text: m)])

symbols("plaintext") do (b: Buf) -> seq[Symbol]:
  # a text file's outline (and Go to symbol) is its notes — for one language: a plugin's symbols take the place
  # of ned's outline for the files they are for
  for n in findNotes(b.lines, markers()):
    result.add Symbol(name: n.marker & ": " & n.text, kind: "section", line: n.line, col: n.col)

snippet("*", "todo", "TODO(${1:who}): ${2:what}$0", "a TODO with a name")
```

Each one takes a language id (`"nim"`, `"python"`, `"plaintext"`; the status bar shows a file's language) or
`"*"` for every file.

- `completions` gives items for the completion list (Ctrl+Space, or as you type), merged with ned's own and a
  language server's. `prefix` is the word typed so far, and ned narrows the list as you type on. With
  `snippet: true`, `insert` is a snippet: `$1`, `${1:default}`, and `$0` where the cursor ends up.
- `hover` gives Markdown, shown under ned's own hover (Alt+H, or the mouse); `""` shows nothing.
- `codeActions` gives fixes and changes for the selection, or for the cursor's line when nothing is selected.
  They join the problems' fixes in the Alt+Enter list. ned waits for them (a second at most), so keep them quick.
- `symbols` gives the file's outline: the Outline dock (Alt+I), Go to symbol (Ctrl+T) and the breadcrumbs. A
  plugin's symbols take the place of ned's outline for that language, which is why notes gives them only for text
  files and not for `"*"`. `kind` picks the icon (`function`, `type`, `section`, `variable` …), and `depth`
  makes a tree.
- `snippet(lang, trigger, body, description)` is offered when you type its trigger: type `todo` and choose it
  from the list. Your own `snippets` setting wins over a plugin's.

*Try it:* type `# FI` and press Ctrl+Space; hover over a `TODO`; press Alt+Enter on a note's line and on a line
without one; open a `.txt` file with notes, and the Outline dock (Alt+I).

## 8. For vim users

With vim mode on (`editor.vimMode`; see [vim mode](../guide/vim-and-zen.md)), notes adds `]n` and `[n` to go to
the next and the previous note, an operator that marks notes done, two text objects, and `:Notes`:

```nim
proc jump(forward: bool, count: int) =
  ## the cursor to the count-th note after it (or before it)
  let b = current()
  let ns = findNotes(b.lines, markers())
  var here = b.cursor.line
  var to = -1
  for _ in 1 .. max(1, count):
    var k = -1
    for i, n in ns:
      if forward and n.line > here:
        k = i
        break
      if not forward and n.line < here: k = i
    if k < 0: break
    to = k
    here = ns[k].line
  if to >= 0: b.setCursor(pos(ns[to].line, ns[to].col))
  else: message("No note " & (if forward: "below" else: "above"))

nmap("]n") do (count: int): jump(true, count)
nmap("[n") do (count: int): jump(false, count)

operator("<leader>d") do (b: Buf, r: Range, linewise: bool):
  # done: <leader>dd the line's note, <leader>dip a paragraph's, <leader>d on a visual selection
  let ns = findNotes(b.lines(r.start.line, r.stop.line), markers(), r.start.line)
  for n in ns: b.replace(rng(pos(n.line, n.col), pos(n.line, n.col + n.marker.len)), "DONE")
  message(plural(ns.len, "note") & " done")

textObject("in") do (b: Buf, p: Pos) -> Range:
  # what the line's note says: cin writes it again, din empties it, vin selects it
  let ns = findNotes(@[b.line(p.line)], markers(), p.line)
  if ns.len == 0: return noRange()
  rng(pos(p.line, ns[0].textCol), pos(p.line, ns[0].textCol + ns[0].text.len))

textObject("an") do (b: Buf, p: Pos) -> Range:
  # the whole note, its marker too: dan, yan, van
  let ns = findNotes(@[b.line(p.line)], markers(), p.line)
  if ns.len == 0: return noRange()
  rng(pos(p.line, ns[0].col), pos(p.line, ns[0].textCol + ns[0].text.len))

exCommand("Notes") do (args: string):
  # :Notes — the file's notes in a list; :Notes FIXME — only those
  chooseNote(if args.strip.len > 0: args.toUpperAscii.splitWhitespace else: markers())
```

- `nmap(keys) do (count: int): …` maps a key sequence in normal mode. `count` is the number typed before it (2
  for `2]n`), 1 without one. `vmap` does the same for visual mode, where `current().selection` is the selection.
  `<leader>` is the space bar.
- `operator(keys) do (b, r, linewise): …` is an operator like `d` or `gc`. ned gives it the range that a motion
  or a text object covers (`<leader>dj`, `<leader>dip`), the cursor's line when the keys' last letter is typed
  twice (`<leader>dd`, `3<leader>dd` for three lines), or the visual selection. `linewise` says whether the range
  is whole lines.
- `textObject(keys) do (b, p) -> Range: …` is a text object of two keys, for after an operator (vim's `c d y`,
  and a plugin's own) or in visual mode. It gives `noRange()` when there is none at `p`.
- `exCommand(name) do (args: string): …` is a `:` command: `:Notes`, or `:Notes fixme`.

*Try it:* `]n`, `3]n` and `[n`; on a note's line, `cin` to write it again and `<leader>dd` to mark it done;
`:Notes fixme`.

## 9. Timers and the assistant

There is no event for a switch of tabs, so the status bar would count the notes of the last file `mark` saw. A
timer fixes that:

```nim
# the status bar follows the file you look at: ned has no event for a change of tabs, so a timer asks
var shownBuf = -1
discard every(1000) do ():
  let b = current()
  if b.valid and b.id != shownBuf:
    shownBuf = b.id
    showCount(findNotes(b.lines, markers()).len)
    refreshView("Notes")
```

`every(ms) do (): …` calls back every `ms` milliseconds (100 at least), and `after(ms) do (): …` calls back
once. Both give the timer's id, and `stopTimer(id)` stops it. ned keeps the time and calls the plugin, so a timer
costs nothing between its calls. But it keeps the plugins' process running (`plugins.idleStopMinutes` does not
stop it), so keep what it does small: this one asks one question a second, and more only when the file changes.

A timer can also start in a command. Here is a reminder:

```nim
var reminder = -1                       # the reminder's timer (-1: none)

command "Notes: remind me later":
  let mins = setting("reminderMinutes", 25)
  if reminder >= 0: stopTimer(reminder)
  reminder = after(mins * 60_000) do ():
    reminder = -1
    let b = current()
    let n = if b.valid: findNotes(b.lines, markers()).len else: 0
    toast("Time for your notes: " & plural(n, "note") & " in this file (Notes: go to a note…)")
  message("A reminder in " & plural(mins, "minute") & " (Notes: cancel the reminder)")

command "Notes: cancel the reminder":
  if reminder < 0:
    message("No reminder is set")
  else:
    stopTimer(reminder)
    reminder = -1
    message("The reminder is cancelled")
```

ned's assistant (Alt+C; see [the AI assistant](../guide/ai.md)) can call tools that plugins give it. notes
gives it one that reads and one that writes:

```nim
aiToolReadOnly("notes_list", "The notes (NOTE:, TODO:, FIXME: …) of a file of the project, or of all its files: " &
               "one a line, as file:line: the note",
               %*{"path": {"type": "string",
                           "description": "a file of the project (\"\": all of them)"}}) do (args: JsonNode) -> string:
  let path = args{"path"}.getStr
  if path.len > 0 and shell("test -f " & quoteShell(path)).code != 0:
    raise newException(ValueError, "no such file: " & path)
  var rows: seq[string]
  for (f, n) in scan((if path.len > 0: @[path] else: projectFiles()), markers()):
    rows.add f & ":" & $(n.line + 1) & ": " & n.marker & ": " & n.text
  if rows.len == 0: "no notes" else: rows.join("\n")

aiTool("notes_add", "Add a TODO note at the end of a line of a file (ned opens the file; it is not saved)",
       %*{"path": {"type": "string", "description": "the file, from the project's folder"},
          "line": {"type": "integer", "description": "the line, from 1"},
          "text": {"type": "string", "description": "what is left to do"}}) do (args: JsonNode) -> string:
  let line = args{"line"}.getInt - 1
  let b = openFile(args{"path"}.getStr, line)
  if not b.valid: raise newException(ValueError, "cannot open " & args{"path"}.getStr)
  if line < 0 or line >= b.lineCount: raise newException(ValueError, "the file has no line " & $(line + 1))
  addNote(b, line, "TODO", args{"text"}.getStr)
  "added a TODO at line " & $(line + 1) & " (not saved yet)"
```

- `aiToolReadOnly(name, description, params) do (args: JsonNode) -> string: …` is a tool that only reads. The
  assistant calls it without asking you, as it reads a file.
- `aiTool(…)` is a tool that changes something. ned asks you before each call, as for its own edits
  (`ai.autoApprove`).
- `params` are the tool's arguments as JSON Schema properties, each with a `type` and a `description`. The model
  reads them, so say what each argument means (here, that lines count from 1, as people count them). The text the
  tool gives back is what the model gets; raise an exception for an error, and its message is what the model sees.
  The model knows these tools as `plugin__notes__notes_list` and `plugin__notes__notes_add`.
- `openFile(path, line)` opens a file in ned (or goes to it), at a line, and gives its `Buf`.

*Try it:* set `plugins.notes.reminderMinutes` to 1 and run *Notes: remind me later*. In the assistant's agent
mode, ask "which FIXMEs are left in this project?": it calls `notes_list`.

## 10. A language server in NimScript

The plugin API works in ned. For features that other editors should have too, write a language server instead:
`nedlsp` is a small library for one in NimScript. This is a separate plugin, not part of notes: a folder
`notes-lsp` with two files. Its `plugin.nims` says which files the server is for:

```nim
import nedplugin

languageServerScript("markdown", "server.nims")
```

and `server.nims` is the server: a diagnostic for each `TODO:`, and a word on hover.

```nim
## the TODO notes of a file as diagnostics, and a word on hover — a language server in NimScript
import nedlsp

proc check(uri: string) =
  var diags = newJArray()
  for i, l in docLines(uri):
    let k = l.find("TODO:")
    if k >= 0:
      diags.add %*{"range": lspRange(i, k, l.len, l), "severity": 3, "source": "notes", "message": l[k .. ^1]}
  publishDiagnostics(uri, diags)

onNotification("textDocument/didOpen") do (params: JsonNode):
  check(params["textDocument"]["uri"].getStr)
onNotification("textDocument/didChange") do (params: JsonNode):
  check(params["textDocument"]["uri"].getStr)

onRequest("textDocument/hover") do (params: JsonNode) -> JsonNode:
  if wordAt(params) != "TODO": return newJNull()
  %*{"contents": {"kind": "markdown", "value": "**TODO** — something left to do"}}

serve(%*{"hoverProvider": true})
```

- `onRequest(method) do (params) -> JsonNode: …` answers a request of the Language Server Protocol, and
  `onNotification(method) do (params): …` takes a notification. `serve(capabilities)` is the server's loop, and
  `capabilities` tell the editor what the server does.
- The library keeps the text of the open documents (`docText(uri)`, `docLines(uri)`), answers `initialize`,
  `shutdown` and `exit`, and converts columns: the editor may count them in UTF-16, and `byteCol`, `lspRange` and
  `wordAt(params)` do the counting for you.
- `ned --lsp-bridge server.nims` runs the server with the protocol's framing. That one command is the server for
  ned (`languageServerScript` uses it) and for any other editor with a language client (Helix, Neovim …): give it
  `ned` as the command and `--lsp-bridge /path/to/server.nims` as the arguments.

[`examples/plugins/wordinfo-lsp`](../../examples/plugins/wordinfo-lsp) is a fuller example: hover, completion of
the text's words, and diagnostics, for text files.

## 11. A plugin in full Nim

A folder with a `plugin.nim` instead of a `plugin.nims` is a plugin in full Nim. ned compiles it with `nim c`
(in the background, and again each time you save it) into a program of its own. This one is again a separate
plugin, `notes-dated`, which adds a TODO with today's date, something NimScript cannot do because it has no
clock:

```nim
## notes-dated — a plugin in full Nim (plugin.nim, not plugin.nims): ned compiles it into a program of its own,
## and it has what NimScript has not — here, a clock
import nedplugin
import std/times

requiresNed(">= 6.20")

command "Notes: add a dated TODO", "ctrl+alt+d":
  let b = current()
  let l = b.cursor.line
  let s = b.line(l) & "  " & b.lineComment & " TODO(" & now().format("yyyy-MM-dd") & "): "
  b.replace(b.lineRange(l), s)
  b.setCursor(pos(l, s.len))
```

The API is the same; notes even recognises the note it makes (`TODO(2026-10-24): …` has a name in brackets).
*Plugins: new plugin in full Nim (compiled)…* starts one from a template.

Choose full Nim when a plugin needs what NimScript does not have: the whole standard library (`std/times`,
`osproc`, sockets, threads), errors of `readFile` you can catch, or speed for heavy work; and its own process
means a slow call never holds up the other plugins. The cost is the compile: seconds on a PC (longer on a phone)
after each change, where a NimScript plugin runs a second after you save. While it builds, the dock says
*compiling…*, and its errors go to the Problems panel. [`examples/plugins/clock-native`](../../examples/plugins/clock-native)
is another full-Nim example, a status-bar clock.

## 12. Testing, debugging, performance, sharing, safety

### Testing

A plugin can be tested without the editor, by playing ned's side of the conversation.
[`tests/plugins/tplugins.py`](../../tests/plugins/tplugins.py) does that for the examples, notes among them:

```sh
python3 tests/plugins/tplugins.py ./ned            # nim on PATH
python3 tests/plugins/tplugins.py ./ned --native   # also compiled, as plugins.native does
```

Its `Host` class writes a host program as ned does (`import nedplugin`, an `import` of each plugin, `nedRun()`),
runs it with `nim e` or compiles it, and plays ned. A line from the host that starts with `\x1e` is a message in
JSON, and any other line is the log. The host sends a `reg` for each thing a plugin registers (with a callback
number), then `ready`; then ned sends a `call` and the host answers `ret`, and while it works each of the
plugin's `api` requests (`line`, `replace`, `problems` …) gets a `res`. `Host` answers them from a pretend buffer
(`h.lines`, `h.cursor`, and `h.answers` for `pick`, `ask` and `confirm`) and keeps what the plugin did
(`h.problems`, `h.decor`, `h.status`, `h.messages`, `h.output`). A check of notes looks like this:

```python
h = Host([("notes", os.path.join(EX, "notes"))], native=native, tmp=tmp)
ok = h.pump(lambda j: j.get("t") == "ready", 60)
h.lines = ["x = 1", "", "  y = 2"]
h.cursor = {"line": 0, "col": 0}
r = h.call(h.reg("command", title="Notes: add a TODO")["cb"])
check(tag + "add a TODO: at the end of the line (its comment), the cursor after it, a line in the log",
      r and "err" not in r and h.lines[0] == "x = 1  # TODO: " and h.cursor == {"line": 0, "col": 15} and
      any("a TODO at line 1 of " in l for l in h.logs), (r, h.lines, h.cursor, h.logs[-3:]))
```

`run_notes` in that file goes through every step of this tutorial this way. To test your own plugin, copy
`Host` and `check`, and list your plugin's folder. Pure helpers such as `findNotes` can also be tried on their
own with `nim e`.

### Debugging

- **The log.** `echo` and `log(text)` write in the plugin's log in the Plugins dock. An exception in a callback
  becomes that call's error: it is in the log, and ned shows it in the status line. The plugin goes on running.
- **Compile errors** go to the Problems panel and to their line in the plugin's file. The plugin is left out,
  and the others start without it. Fix it and save.
- **One at a time.** *Plugins: turn one on or off…* sets `plugins.disabled`, and *Plugins: reload one…* restarts
  one. `plugins.alone` (or *Run it in a process of its own* in the dock) gives a NimScript plugin a process of
  its own, so a plugin that hangs or crashes cannot take the others with it.
- **NimScript's limits.** No clock, an error of `readFile` (or `writeFile`) that cannot be caught (check with
  `fileExists` first, or use `shell`), no `return` in a command's body, and some of the standard library
  missing. When you hit one, move the work into `shell`, or make the plugin a `plugin.nim` (step 11).

### Performance

- Each API call is a round trip to ned: about 3–6 ms in `nim e`, about 0.3 ms compiled. Ask for `b.lines` once
  rather than `b.line(i)` in a loop, give `output` all the lines at once, and use `setProblems` (one call) rather
  than many `sign`s.
- ned waits for some calls before it goes on: an `onBeforeSave` event, a NimScript formatter and a text object
  (`plugins.timeoutMs`, 1500 ms), and code actions (1 s). Keep those quick.
- `plugins.native` (`auto` by default) compiles the NimScript plugins with `nim c` in the background once they
  have run unchanged, for a faster start and faster calls the next time. A plugin that uses what only NimScript
  has (`exec`, `listFiles` …) stays with `nim e`; notes compiles either way (the tests' `--native` run checks it).
- A plugin's process starts only when it is needed: ned remembers what the plugins registered, so their commands
  and keys are there at once. A plugin that answers events, keeps time, completes, hovers, lists symbols or shows
  a view starts with ned. The process stops after `plugins.idleStopMinutes` without a call, unless a plugin in it
  keeps time or answers events.

### Sharing

A plugin is shared as a git repository with its `plugin.nims` (or `plugin.nim`) at the top. Others install it
with *Plugins: install from git…* and its address. The plugin is named after the repository, without a
`ned-plugin-` or `ned-` in front, so `ned-plugin-notes` installs as `notes`. *Plugins: update* pulls every plugin
that came from git. A list of plugins to install from is a JSON file, on the web or on disk, that
`plugins.indexUrl` names; *Plugins: browse the plugin list…* shows it:

```json
[{"name": "notes", "url": "https://example.com/you/ned-plugin-notes.git",
  "description": "NOTE, TODO and FIXME: marks, fixes, a view, vim keys, a tool for the assistant"}]
```

Give it a `requiresNed`, say in its `##` comment what it does, and declare its settings with `settingDef`.

### Safety

Plugins run with your rights, like any program you install: a plugin can read and write your files and run
commands. Read a plugin before you install it. A project's plugins (`.ned/plugins/`) run only in a folder you
trust, and a tool that a plugin gives the assistant asks you first unless it is declared read-only, so only
declare a tool read-only when it really only reads. See [safety](../guide/safety.md) for what ned does to protect
your work.

## Where to go next

- [The API reference](api.md): every type and proc of `nedplugin` and `nedlsp`, with its documentation.
- [Plugins](README.md): how plugins are found, run and managed, and their settings.
- The examples in [`examples/plugins/`](../../examples/plugins), each a small plugin around a part of the API:
  [notes](../../examples/plugins/notes/plugin.nims) (this tutorial's),
  [commentary](../../examples/plugins/commentary/plugin.nims) (a vim operator, a text object, a `:` command),
  [ini-tools](../../examples/plugins/ini-tools/plugin.nims) (a language's features, a view, the Output panel, a
  tool for the assistant), [zig-lite](../../examples/plugins/zig-lite/plugin.nims) (a new language, a
  formatter), [wordinfo-lsp](../../examples/plugins/wordinfo-lsp) (a language server in NimScript) and
  [clock-native](../../examples/plugins/clock-native/plugin.nim) (full Nim). *Plugins: add an example…* copies
  one of them — or notes itself, to try it as it is — into your plugins.
