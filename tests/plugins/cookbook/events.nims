## file-stats — events: a text file's lines and words in the status bar, spaces at the ends of lines removed
## before saving, a log of what you save, and the files that were open when ned last quit
import nedplugin

requiresNed(">= 6.31")

func words(lines: seq[string]): int =
  ## the number of words in the lines (runs of text between whitespace)
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
