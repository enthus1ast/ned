## notes — the notes you leave in your files: NOTE: …, TODO: …, FIXME: … (and TODO(ann): …). It is the plugin the
## tutorial (docs/plugins/tutorial.md) builds step by step.
##
##   Ctrl+Alt+N            Notes: add a TODO (at the end of the cursor's line)
##   Notes: go to a note…, Notes: add a note…, Notes: remove the DONE notes…
##   in every file         each note in Problems (Alt+Enter: mark it done, remove it, make it another kind), a sign
##                         in the gutter, its marker highlighted, the file's count in the status bar
##   Notes: find the project's notes   the Output panel and the Notes view of the Plugins dock
##   completions of the markers in a comment, hover on a marker, the notes as the outline of a text file, a snippet
##   vim                   ]n [n (the next, the previous note), <leader>d (an operator: done), in an (text objects),
##                         :Notes
##   Notes: remind me later; notes_list and notes_add, tools for the assistant
##   settings              plugins.notes.markers, plugins.notes.problems, plugins.notes.reminderMinutes
##
## Copy this folder to ~/.config/ned/plugins/notes/.
import nedplugin

requiresNed(">= 6.26")
permission("shell", "finds the notes in your files with grep")

# ── 2. a first command: reading and changing the text ──

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

# ── 3. talking to you: message, toast, pick, ask, confirm ──

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

# ── 4. events, and the notes marked in the editor ──

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

onOpen("*") do (ev: Event): mark(ev.buf)
onChange("*") do (ev: Event): mark(ev.buf)

onSave("lang:nim") do (ev: Event):
  # a Nim file saved with a FIXME in it: a warning in the status line
  let n = findNotes(ev.buf.lines, @["FIXME"]).len
  if n > 0: warn(extractFilename(ev.path) & " still has " & plural(n, "FIXME"))

# ── 5. settings ──

settingDef("markers", "NOTE TODO FIXME", "The words that start a note, a colon after each (TODO: …, TODO(ann): …)")
settingDef("problems", true, "Show the notes in the Problems panel (Alt+Enter on one: mark it done, remove it)")
settingDef("reminderMinutes", 25, "Notes: remind me later — in how many minutes")

# ── 6. a view in the Plugins dock, the Output panel, progress ──

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

# ── 7. a language's features: completions, hover, code actions, symbols, a snippet ──

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

# ── 8. vim: mappings, an operator, text objects, a : command ──

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

# ── 9. timers, and tools for the assistant ──

# the status bar follows the file you look at: a timer asks each second (onEnter would be called at each change of
# tab; the timer is here to show one)
var shownBuf = -1
discard every(1000) do ():
  let b = current()
  if b.valid and b.id != shownBuf:
    shownBuf = b.id
    showCount(findNotes(b.lines, markers()).len)
    refreshView("Notes")

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
