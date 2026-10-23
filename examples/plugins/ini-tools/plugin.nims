## ini-tools — what a plugin can give a language: completions, hover, symbols (the outline, Go to symbol), code
## actions (Alt+Enter), snippets; a view in the Plugins dock, progress in the status bar, lines in the Output panel;
## and a tool the assistant may call.
##
## For INI-style files (.ini .cfg .conf .properties .desktop — ned colours them as TOML, so the language is "toml").
## Copy this folder to ~/.config/ned/plugins/ (or Plugins dock › + › an example).
import nedplugin

requiresNed(">= 6.20")

settingDef("sortCaseSensitive", false, "Sort a section's keys with upper case first (A-Z, then a-z)")

type Entry = object
  section, key, value: string
  line: int

proc parse(lines: seq[string]): seq[Entry] =
  ## each key = value (or key: value) with its section; a section's own line as an entry with no key
  var sec = ""
  for i, raw in lines:
    let l = raw.strip
    if l.len == 0 or l[0] in {'#', ';'}: continue
    if l[0] == '[' and l.endsWith("]"):
      sec = l[1 ..< l.high].strip
      result.add Entry(section: sec, line: i)
      continue
    var k = l.find('=')
    let c = l.find(':')
    if k < 0 or (c >= 0 and c < k): k = c
    if k > 0: result.add Entry(section: sec, key: l[0 ..< k].strip, value: l[k + 1 .. ^1].strip, line: i)

proc sectionAt(es: seq[Entry], line: int): string =
  for e in es:
    if e.line > line: break
    if e.key.len == 0: result = e.section

# the outline: sections, their keys under them
symbols("toml") do (b: Buf) -> seq[Symbol]:
  for e in parse(b.lines):
    if e.key.len == 0: result.add Symbol(name: "[" & e.section & "]", kind: "section", line: e.line)
    else: result.add Symbol(name: e.key, kind: "variable", detail: e.value, line: e.line,
                            depth: (if e.section.len > 0: 1 else: 0))

# completions: the keys other sections have (and their values after `=`)
completions("toml") do (b: Buf, p: Pos, prefix: string) -> seq[CompletionItem]:
  let es = parse(b.lines)
  let here = b.line(p.line)
  let eq = here.find('=')
  if eq >= 0 and eq < p.col:
    # a value: the ones this key has elsewhere
    let key = here[0 ..< eq].strip
    for e in es:
      if e.key == key and e.value.len > 0:
        result.add CompletionItem(label: e.value, kind: "value", detail: "[" & e.section & "] " & key)
  else:
    let sec = sectionAt(es, p.line)
    var mine: seq[string]
    for e in es:
      if e.section == sec and e.key.len > 0: mine.add e.key
    for e in es:
      if e.key.len > 0 and e.key notin mine and e.key.startsWith(prefix):
        mine.add e.key
        result.add CompletionItem(label: e.key, insert: e.key & " = ${1:" & e.value & "}", snippet: true,
                                  kind: "field", detail: "as in [" & e.section & "]",
                                  doc: "`" & e.key & " = " & e.value & "` in **[" & e.section & "]**")

# hover: where else the key is, and with what values
hover("toml") do (b: Buf, p: Pos) -> string:
  let w = b.wordAt(p)
  if w.len == 0: return ""
  var rows: seq[string]
  for e in parse(b.lines):
    if e.key == w: rows.add "- **[" & e.section & "]** line " & $(e.line + 1) & ": `" & e.value & "`"
  if rows.len > 1: result = "**" & w & "** — in " & $rows.len & " sections\n\n" & rows.join("\n")

# code actions: the cursor's section sorted, a key that appears twice in a section removed
codeActions("toml") do (b: Buf, r: Range) -> seq[Fix]:
  let es = parse(b.lines)
  let sec = sectionAt(es, r.start.line)
  var first = -1
  var last = -1
  var keys: seq[(string, string)]
  for e in es:
    if e.section == sec and e.key.len > 0:
      if first < 0: first = e.line
      last = e.line
      keys.add (e.key, b.line(e.line))
  if keys.len >= 2:
    var ok = true
    for i in first .. last:
      if b.line(i).strip.len == 0 or b.line(i).strip[0] in {'#', ';'}: ok = false     # (only a plain run of keys)
    if ok:
      let cs = setting("sortCaseSensitive", false)
      var sorted = keys
      for i in 1 ..< sorted.len:        # (insertion sort: NimScript has no algorithm.sort of a closure)
        var j = i
        while j > 0 and (if cs: sorted[j][0] < sorted[j - 1][0]
                         else: sorted[j][0].toLowerAscii < sorted[j - 1][0].toLowerAscii):
          swap(sorted[j], sorted[j - 1])
          dec j
      var lines: seq[string]
      for (_, l) in sorted: lines.add l
      if sorted != keys:
        result.add Fix(title: "Sort the keys of [" & sec & "]",
                       edits: @[Edit(range: rng(pos(first, 0), pos(last, b.line(last).len)), text: lines.join("\n"))])
  var seen: seq[string]
  for e in es:
    if e.section == sec and e.key.len > 0:
      if e.key in seen and e.line >= r.start.line and e.line <= r.stop.line:
        result.add Fix(title: "Remove the second " & e.key & " (line " & $(e.line + 1) & ")",
                       edits: @[Edit(range: b.wholeLines(e.line, e.line), text: "")])
      seen.add e.key

snippet("toml", "sec", "[${1:section}]\n${2:key} = ${3:value}\n$0", "a section with a key")

# a view in the Plugins dock: the sections of the file shown (click: go there)
var shown = -1
view("INI sections") do () -> seq[ViewItem]:
  let b = current()
  if not b.valid or b.lang != "toml": return @[ViewItem(text: "(not an INI file)", color: "hint")]
  shown = b.id
  for e in parse(b.lines):
    if e.key.len == 0: result.add ViewItem(text: "[" & e.section & "]", icon: "§", id: $e.line, color: "accent")
do (id: string):
  let b = current()
  if b.valid and b.id == shown: b.setCursor(pos(parseInt(id), 0))

onOpen("lang:toml") do (ev: Event): refreshView("INI sections")
onChange("lang:toml") do (ev: Event): refreshView("INI sections")

# a command with progress and the Output panel: every INI file of the project, a key twice in a section
command "INI: check the project's config files":
  let (o, _) = shell("find . -name '*.ini' -o -name '*.cfg' -o -name '*.conf' | grep -v '/\\.' | head -200")
  let files = o.splitLines
  var found = 0
  for i, f in files:
    if f.len == 0: continue
    progress("Checking " & f, (i + 1) * 100 div max(1, files.len))
    let (text, code) = shell("cat " & quoteShell(f))
    if code != 0: continue
    var seen: seq[string]
    for e in parse(text.splitLines):
      let k = e.section & "\x00" & e.key
      if e.key.len > 0:
        if k in seen:
          output(f & ":" & $(e.line + 1) & ":1: " & e.key & " is in [" & e.section & "] twice")
          inc found
        seen.add k
  progressDone()
  if found > 0: showOutput()
  message("INI: " & $found & " key" & (if found == 1: "" else: "s") & " twice in a section")

# a tool the assistant may call (it only reads: it runs without asking)
aiToolReadOnly("ini_get", "The value of a key in an INI-style config file (section and key)",
               %*{"path": {"type": "string", "description": "the file, from the project's folder"},
                  "section": {"type": "string", "description": "the section's name (\"\" for keys before any)"},
                  "key": {"type": "string"}}) do (args: JsonNode) -> string:
  let (text, code) = shell("cat " & quoteShell(args["path"].getStr))
  if code != 0: raise newException(ValueError, "cannot read " & args["path"].getStr)
  for e in parse(text.splitLines):
    if e.section == args["section"].getStr and e.key == args["key"].getStr: return e.value
  raise newException(ValueError, "no such key")
