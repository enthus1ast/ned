## the API test plugin (tests/plugins/tplugins.py plays ned)
import nedplugin

command "API: upper-case the line", "Ctrl+Alt+U":
  let b = current()
  let l = b.cursor.line
  b.replace(b.lineRange(l), b.line(l).toUpperAscii)

command "API: problems":
  let b = current()
  var p = Problem(range: rng(pos(0, 0), pos(0, 3)), severity: 2, message: "three letters")
  p.fixes.add Fix(title: "Make it four", edits: @[Edit(range: rng(pos(0, 0), pos(0, 3)), text: "four")])
  b.setProblems([p])
  b.sign(0, "★", "warn")
  b.virtualText(0, "← here")
  status("api: " & $b.lineCount & " lines")

command "API: ask and pick":
  let name = ask("Your name?", "x")
  let i = pick("A colour", ["red", "green"])
  if confirm("Write it?"):
    current().insert(pos(0, 0), name & ":" & $i & "\n")

command "API: settings and shell":
  let w = setting("width", 80)
  let (o, code) = shell("echo hi")
  message("width " & $w & " · " & o & " " & $code & " · " & dataDir())

command "API: its data":
  writeData("notes/a.txt", "one\n")
  appendData("notes/a.txt", "two\n")
  message("read: " & readData("notes/a.txt").replace("\n", "|"))

onSave("*.txt") do (ev: Event):
  log("saved " & ev.path & " (" & ev.lang & ")")

onBeforeSave("*.txt") do (ev: Event):
  let b = ev.buf
  let t = b.text
  if t.endsWith(" "): b.setText(t.strip(leading = false))

nmap("<leader>u") do (count: int):
  message("leader u ×" & $count)

var ticks = 0
discard every(1000) do ():
  inc ticks
  if ticks == 2: echo "two ticks"

command "API: raise":
  raise newException(ValueError, "on purpose")
