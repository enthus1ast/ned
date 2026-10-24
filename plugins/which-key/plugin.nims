## which-key — after a key that waits for more (vim's g, z, d …, your <leader>, emacs's C-x, helix's space), a box of what each next key does
##
## Turn it on in the Plugins dock (AVAILABLE). Type the first key of a sequence and wait a moment: a box above the
## status bar lists the keys that can follow and what each does — ned's own and the plugins' mappings (those that
## say what they do: nmap("<leader>f", "find a file", …)). Type the next key as usual, or tap it in the box; Esc
## leaves. Works with vim mode, emacs keys and helix keys.
##
## Settings: plugins.which-key.delay — how long the keys wait before the box shows (milliseconds, 500).
import nedplugin
import std/strutils

settingDef("delay", 500, "how long keys that wait for more wait before the box of what follows shows (milliseconds)")

const
  # ned's own vim keys after each prefix (what ned does, as its vim guide says)
  vimG = [("g", "first line"), ("d", "go to definition"), ("r", "find references"), ("t", "next tab"),
          ("T", "previous tab"), ("u", "lower case, then a motion"), ("U", "upper case, then a motion"),
          ("c", "comment, then a motion (gcc: the line)"), ("J", "join lines"), ("-", "older text (undo in time)"),
          ("+", "newer text (redo in time)")]
  vimZ = [("z", "this line in the middle"), ("t", "this line at the top"), ("b", "this line at the bottom"),
          ("a", "fold or unfold here"), ("c", "fold"), ("o", "unfold"), ("M", "fold all"), ("R", "unfold all")]
  vimMotions = [("w", "to the next word"), ("b", "back a word"), ("e", "to the end of the word"),
                ("W", "next WORD (to a space)"), ("B", "back a WORD"), ("E", "end of the WORD"),
                ("$", "to the end of the line"), ("0", "to the start of the line"), ("^", "to the first non-blank"),
                ("gg", "to the first line"), ("G", "to the last line"), ("j", "this line and the next"),
                ("k", "this line and the one above"), ("}", "to the next paragraph"), ("{", "back a paragraph"),
                ("%", "to the matching bracket"), ("f", "up to a character (then it)"),
                ("t", "up to before a character"), ("F", "back to a character"), ("T", "back to after a character"),
                ("i", "inside … (then what: w \" ( { …)"), ("a", "around … (then what)")]
  vimObjects = [("w", "a word"), ("W", "a WORD (to the spaces)"), ("\"", "\" … \""), ("'", "' … '"),
                ("`", "` … `"), ("(", "( … )"), ("b", "( … )"), ("[", "[ … ]"), ("{", "{ … }"), ("B", "{ … }"),
                ("<", "< … >")]
  emacsCx = [("C-s", "save"), ("C-f", "open a file"), ("C-w", "save as"), ("C-c", "quit"),
             ("C-x", "the cursor to the mark and back"), ("b", "switch to another tab"), ("k", "close the tab"),
             ("u", "undo"), ("h", "select everything"), ("o", "the other pane"), ("2", "split down"),
             ("3", "split right"), ("1", "close the split"), ("0", "close the split"), ("(", "record a macro"),
             (")", "stop recording"), ("e", "play the macro")]
  emacsMg = [("g", "go to a line"), ("l", "go to a line"), ("n", "next problem"), ("p", "previous problem")]
  helixSpace = [("f", "open a file"), ("b", "switch to another tab"), ("s", "go to a symbol"),
                ("S", "go to a symbol of the project"), ("/", "search the project"), ("k", "what this is (hover)"),
                ("a", "code actions"), ("r", "rename"), ("c", "comment"), ("y", "copy"), ("p", "paste"),
                ("d", "the problems"), ("?", "the command palette")]
  helixG = [("g", "first line"), ("e", "last line"), ("h", "start of the line"), ("l", "end of the line"),
            ("s", "first non-blank"), ("d", "go to definition"), ("r", "find references"),
            ("y", "go to the type's definition"), ("i", "go to the implementation"), ("n", "next tab"),
            ("p", "previous tab")]
  operators = ["d", "c", "y", ">", "<", "gu", "gU", "gc"]

proc tokens(keys: string): seq[string] =
  ## "<leader>fg" → @["<leader>", "f", "g"]
  var i = 0
  while i < keys.len:
    if keys[i] == '<':
      let e = keys.find('>', i)
      if e > i + 1:
        result.add keys[i .. e]
        i = e + 1
        continue
    result.add $keys[i]
    inc i

proc norm(keys: string): string =
  ## the way ned writes waiting keys: <Leader> and <Space> as <leader>, <c-a> as <C-a>, <cr> as <CR>
  for t in tokens(keys):
    let l = t.toLowerAscii
    if l in ["<leader>", "<space>"]: result.add "<leader>"
    elif l in ["<cr>", "<enter>"]: result.add "<CR>"
    elif l == "<tab>": result.add "<Tab>"
    elif l.len == 5 and l.startsWith("<c-"): result.add "<C-" & l[3] & ">"
    else: result.add t

proc addOnce(hints: var seq[(string, string)], k, d: string) =
  for i, (hk, _) in hints:
    if hk == k:
      hints[i] = (k, d)              # (a plugin's mapping of the key: it, not ned's own)
      return
  hints.add (k, d)

proc mappingsAfter(hints: var seq[(string, string)], keys, mode: string, lang: string) =
  ## the plugins' mappings that go on from `keys`: their next key and what they do (or how many go on from it)
  var more: seq[(string, int)]
  for m in keyMaps():
    if m.mode != mode: continue
    if m.lang.len > 0 and m.lang.toLowerAscii != lang: continue
    let mk = norm(m.keys)
    if not mk.startsWith(keys) or mk.len == keys.len: continue
    let rest = tokens(mk[keys.len .. ^1])
    if rest.len == 1:
      hints.addOnce(rest[0], (if m.desc.len > 0: m.desc else: m.plugin & "'s"))
    else:
      var found = false
      for i, (k, n) in more:
        if k == rest[0]:
          more[i] = (k, n + 1)
          found = true
      if not found: more.add (rest[0], 1)
  for (k, n) in more:
    var has = false
    for (hk, _) in hints:
      if hk == k: has = true
    if not has: hints.add (k, "+ " & $n & (if n == 1: " more key" else: " more keys"))

proc hintsFor(keys, mode: string): (string, seq[(string, string)]) =
  var h: seq[(string, string)]
  let b = current()
  let lang = if b.valid: b.lang.toLowerAscii else: ""
  case mode
  of "emacs":
    if keys == "C-x": h = @emacsCx
    elif keys == "M-g": h = @emacsMg
  of "helix":
    case keys
    of "<space>": h = @helixSpace
    of "g": h = @helixG
    of "r": h = @[("…", "a character: it replaces every one of the selection")]
    else: discard
  of "obj":
    let last = keys[^1]
    for (k, d) in vimObjects: h.add (k, (if last == 'i': "inside " else: "around ") & d)
    for m in keyMaps():
      if m.mode == "obj" and m.keys.len == 2 and m.keys[0] == last:
        h.addOnce($m.keys[1], (if m.desc.len > 0: m.desc else: m.plugin & "'s text object"))
  of "o":
    block:
      let op = keys
      if op in operators:
        let twice = if op == "gc": "c" elif op in ["gu", "gU"]: $op[1] else: op
        h.add (twice, "the line (a count before: that many)")
      if op in ["d", "c", "y"]:
        h.add ("s", (case op
                     of "y": "surround with … (ys{motion}{character})"
                     of "d": "delete the surrounding … (ds{character})"
                     else: "change the surrounding … (cs{old}{new})"))
      if op == "ys": h.add ("s", "the line (yss{character})")
      for (k, d) in vimMotions: h.add (k, d)
  of "n", "v":
    case keys
    of "g": h = @vimG
    of "z": h = @vimZ
    of "r": h = @[("…", "a character: it replaces the one under the cursor")]
    of "f", "t", "F", "T": h = @[("…", "the character to go to")]
    of "q": h = @[("a … z", "record into that register (q again stops)")]
    of "@": h = @[("a … z", "play that register"), ("@", "play the one played last")]
    else: discard
    h.mappingsAfter(keys, mode, lang)
  else: discard
  let title = (if mode == "emacs": keys & " …" elif keys == "<leader>": "<leader> (the space bar) …" else: keys & " …")
  (title, h)

proc show(keys, mode: string) =
  let (k, m) = pendingKeys()
  if k != keys or m != mode: return       # (the keys went on meanwhile)
  let (title, h) = hintsFor(keys, mode)
  if h.len > 0: discard showKeyHints(title, h)

onKeysWaiting(150, proc(keys, mode: string) =
  let d = setting("delay", 500)
  if d <= 150: show(keys, mode)
  else:
    let (k, m) = (keys, mode)
    discard after(d - 150, proc() = show(k, m)))
