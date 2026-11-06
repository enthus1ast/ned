# ════════════════════════════════════════════════════════════════════════════
#  Vim mode's : line — :set for every setting, the line commands with their ranges, Vim's common commands, any of
#  ned's commands by name, and Tab completing all of them (vimEx runs a line, vimExComplete completes one)
# ════════════════════════════════════════════════════════════════════════════

const
  VimOptNames = [
    # Vim's option names (long, short) and the ned setting each stands for; :set also takes ned's own keys
    ("wrap", "", "editor.softWrap"), ("list", "", "editor.showWhitespace"),
    ("cursorline", "cul", "editor.lineHighlight"), ("scrolloff", "so", "editor.scrollOff"),
    ("foldenable", "fen", "editor.folding"), ("undofile", "udf", "editor.persistentUndo"),
    ("autoread", "ar", "files.autoReload"), ("autowrite", "aw", "editor.autoSave"),
    ("autowriteall", "awa", "editor.autoSave"), ("fileencoding", "fenc", "files.encoding"),
    ("encoding", "enc", "files.encoding"), ("spelllang", "spl", "editor.spellLanguage"),
    ("laststatus", "ls", "ui.statusBar"), ("showtabline", "stal", "ui.tabBar"), ("title", "", "ui.terminalTitle")]
  VimOptOwn = ["number", "nu", "relativenumber", "rnu", "tabstop", "ts", "shiftwidth", "sw", "softtabstop", "sts",
    "expandtab", "et", "ignorecase", "ic", "colorcolumn", "cc", "mouse", "clipboard", "background", "bg", "spell",
    "filetype", "ft", "syntax", "syn"]
    # (Vim options :set handles itself: the file's own indent and language, the search's case, …)
  VimOptQuiet = ["hlsearch", "hls", "incsearch", "is", "autoindent", "ai", "smartindent", "si", "cindent", "cin",
    "smartcase", "scs", "showmatch", "sm", "ruler", "ru", "showmode", "smd", "showcmd", "sc", "termguicolors", "tgc",
    "compatible", "cp", "hidden", "hid", "lazyredraw", "lz", "wildmenu", "wmnu", "backspace", "bs", "belloff", "bo",
    "visualbell", "vb", "errorbells", "eb", "magic", "smarttab", "sta", "splitbelow", "sb", "splitright", "spr",
    "timeout", "to", "ttimeout", "timeoutlen", "tm", "ttimeoutlen", "ttm", "updatetime", "ut", "history", "hi",
    "undolevels", "ul", "backup", "bk", "writebackup", "wb", "swapfile", "swf", "modeline", "ml", "textwidth", "tw",
    "fileformat", "ff", "signcolumn", "scl", "cmdheight", "ch", "shortmess", "shm", "completeopt", "cot"]
    # (Vim options with no ned setting: accepted and left alone, so lines from a vimrc work)
  VimExWords = ["write", "quit", "wq", "xit", "wall", "qall", "wqall", "update", "edit", "saveas", "read", "bnext",
    "bprevious", "bdelete", "buffer", "ls", "tabnew", "tabnext", "tabprevious", "tabclose", "new", "vnew", "split",
    "vsplit", "only", "set", "setlocal", "colorscheme", "nohlsearch", "substitute", "global", "vglobal", "sort",
    "delete", "yank", "move", "copy", "join", "undo", "redo", "cnext", "cprevious", "copen", "Explore", "terminal",
    "make", "run", "zen", "pwd", "registers", "help"]

var
  vimCompList: seq[string]  # the : line's completions of what was typed (whole lines), stepped through by Tab
  vimCompAt = -1            # the one in the prompt (-1: their common start)
  vimCompShown = ""         # the text Tab last put in the prompt

proc vimSettingKey(name: string): string =
  ## the setting a name in :set stands for — ned's own key (in any case, or only its last part when one setting ends
  ## so) or a Vim option ned has a setting for; "" when none
  initSettingDefs()
  if name.len == 0: return ""
  if setIndex.hasKey(name): return name
  for (l, s, k) in VimOptNames:
    if name == l or (s.len > 0 and name == s): return k
  for d in setDefs:
    if cmpIgnoreCase(d.key, name) == 0: return d.key
  var n = 0
  for d in setDefs:
    if cmpIgnoreCase(d.key.rsplit('.', 1)[^1], name) == 0:
      result = d.key
      inc n
  if n != 1: result = ""

proc vimSetValue(key, raw: string): (bool, JsonNode, string) =
  ## a value typed for a setting, read the way the setting takes it: (it is one, the value, what it should be)
  let d = setDefs[setIndex[key]]
  let v = raw.strip
  case d.kind
  of skBool:
    case v.toLowerAscii
    of "true", "on", "yes", "1", "2": (true, %true, "")
    of "false", "off", "no", "0": (true, %false, "")
    else: (false, newJNull(), key & " is on or off (true or false)")
  of skInt:
    try: (true, %parseInt(v), "")
    except ValueError: (false, newJNull(), key & " is a whole number")
  of skEnum:
    for o in d.opts:
      if cmpIgnoreCase(o, v) == 0: return (true, %o, "")
    if key.startsWith("theme") and themeAlias(v.toLowerAscii).len > 0: return (true, %v.toLowerAscii, "")
    (false, newJNull(), key & " is one of: " & d.opts[0 ..< min(12, d.opts.len)].join(", ") &
                        (if d.opts.len > 12: " … (Tab lists them)" else: ""))
  of skStr:
    (true, %(if v.len >= 2 and v[0] == v[^1] and v[0] in {'"', '\''}: v[1 .. ^2] else: v), "")
  of skJson:
    try: (true, parseJson(v), "")
    except CatchableError: (true, %v, "")

proc vimSetShow(key: string) =
  ## one setting's value in the status line, with what it is for
  let d = setDefs[setIndex[key]]
  info(key & "=" & $sval(key) & " — " & d.doc)

proc vimSetList(all: bool) =
  ## :set alone (the settings you changed) or :set all (every one), with their values, in a tab of their own
  initSettingDefs()
  var t = "# " & (if all: "Every setting" else: "The settings you changed") & "\n\n" &
          "`:set key=value` changes one, `:set key?` shows it, `:set key&` puts it back as it was.\n\n" &
          "| setting | value | |\n|---|---|---|\n"
  var n = 0
  for d in setDefs:
    if all or settingsUser.hasKey(d.key):
      t.add "| `" & d.key & "` | `" & ($sval(d.key)).replace("|", "\\|") & "` | " & d.doc.replace("|", "\\|") & " |\n"
      inc n
  if n == 0: t.add "| (none: every setting is as ned comes) | | |\n"
  discard openScratch((if all: "settings: all" else: "settings: changed"), t, langByName("Markdown"))

proc vimSetLangOf(b: Buffer, name: string) =
  ## :set filetype=python — the file read as another language
  let l = langByName(name)
  if l == nil:
    error("No language called " & name)
    return
  lspDidClose(b)
  b.lang = l
  b.hlValid = 0
  lspAttach(b)
  info("Language: " & l.name)

proc vimSetOwn(b: Buffer, name, op, val: string): bool =
  ## the Vim options that are not one setting — the file's indent and language, the search's case, the line numbers,
  ## the rulers, the mouse, the clipboard, light or dark, spelling; false when `name` is none of them
  let off = name.startsWith("no") and name[2 .. ^1] in VimOptOwn
  let n = if off: name[2 .. ^1] else: name
  if n notin VimOptOwn: return false
  result = true
  let num = (try: parseInt(val) except ValueError: -1)
  case n
  of "number", "nu":
    let cur = sStr("editor.lineNumbers")
    if op == "?": info("number: " & cur)
    elif off: setSetting("editor.lineNumbers", %(if cur == "relative": "relative" else: "off"))
    elif cur == "off": setSetting("editor.lineNumbers", %"absolute")
  of "relativenumber", "rnu":
    if op == "?": info("relativenumber: " & $(sStr("editor.lineNumbers") == "relative"))
    else: setSetting("editor.lineNumbers", %(if off: "absolute" else: "relative"))
  of "tabstop", "ts", "shiftwidth", "sw", "softtabstop", "sts":
    if op == "?" or val.len == 0:
      info(n & "=" & $(if b.indent == "\t" or n in ["tabstop", "ts"]: b.tabOf else: b.indent.len))
    elif num notin 1 .. 32: error(n & " is a number from 1 to 32")
    elif n in ["tabstop", "ts"] or b.indent == "\t": b.tabSize = num
    else: b.indent = spaces(num)
  of "expandtab", "et":
    if op == "?": info("expandtab: " & $(b.indent != "\t"))
    elif off: b.indent = "\t"
    elif b.indent == "\t": b.indent = spaces(b.tabOf)
  of "ignorecase", "ic":
    if op == "?": info("ignorecase: " & $(not findCase))
    else: findCase = off
  of "colorcolumn", "cc":
    if op == "?": info("colorcolumn: " & $sval("editor.rulers"))
    else:
      var cols = newJArray()
      for w in val.split(','):
        let c = (try: parseInt(w.strip) except ValueError: 0)
        if c > 0: cols.add %c
      setSetting("editor.rulers", (if off: newJArray() else: cols))
  of "mouse":
    if op == "?": info("mouse: " & $sBool("ui.mouse"))
    else: setSetting("ui.mouse", %(not off and (op.len == 0 or val.len > 0)))
  of "clipboard":
    if op == "?": info("clipboard: " & (if sBool("vim.useSystemClipboard"): "unnamedplus" else: ""))
    else: setSetting("vim.useSystemClipboard", %(not off and (op.len == 0 or val.len > 0)))
  of "background", "bg":
    if op == "?" or val.len == 0: info("background: " & (if theme.dark: "dark" else: "light"))
    elif val in ["dark", "light"]: setSetting("theme", sval("theme." & val))
    else: error("background is dark or light")
  of "spell":
    if op == "?": info("spell: " & sStr("editor.spellCheck"))
    else: setSetting("editor.spellCheck", %(if off: "off" else: "on"))
  of "filetype", "ft", "syntax", "syn":
    if op == "?" or val.len == 0: info(n & "=" & b.lang.name)
    elif val notin ["on", "off", "enable"]: vimSetLangOf(b, val)
  else: discard

proc vimSet(arg: string) =
  ## :set — each word one setting: name (on, or its value shown), noname (off), invname or name! (the other way),
  ## name? (shown), name& (as ned comes), name=value, name:value, name+=n, name-=n; by ned's key or Vim's name
  let b = buf()
  if arg.strip.len == 0:
    vimSetList(false)
    return
  for w in arg.splitWhitespace:
    if w == "all":
      vimSetList(true)
      continue
    var name = w
    var op, val = ""
    for o in ["+=", "-=", "^=", "=", ":"]:
      let k = name.find(o)
      if k > 0:
        (op, val, name) = (o, name[k + o.len .. ^1], name[0 ..< k])
        break
    if op.len == 0 and name.len > 1 and name[^1] in {'?', '!', '&'}:
      op = $name[^1]
      name = name[0 ..< ^1]
    if vimSetOwn(b, name, op, val): continue
    if name in VimOptQuiet or (name.startsWith("no") and name[2 .. ^1] in VimOptQuiet): continue
    var key = vimSettingKey(name)
    var negate = false
    if key.len == 0:
      for p in ["no", "inv"]:
        if name.startsWith(p) and vimSettingKey(name[p.len .. ^1]).len > 0:
          key = vimSettingKey(name[p.len .. ^1])
          negate = true
          if p == "inv": op = "!"
          break
    if key.len == 0:
      error("Unknown option: " & name & " (Tab after :set lists ned's settings)")
      continue
    let d = setDefs[setIndex[key]]
    case op
    of "?": vimSetShow(key)
    of "&": setSetting(key, d.def)
    of "!":
      if d.kind == skBool: setSetting(key, %(not sBool(key)))
      else: error(key & " is not on or off")
    of "+=", "-=", "^=":
      if d.kind == skInt:
        let n = (try: parseInt(val) except ValueError: 0)
        setSetting(key, %(if op == "+=": sInt(key) + n elif op == "-=": sInt(key) - n else: sInt(key) * max(1, n)))
      elif d.kind == skStr and op != "-=": setSetting(key, %(if op == "+=": sStr(key) & val else: val & sStr(key)))
      else: error(key & ": " & op & " is for numbers and text")
    of "=", ":":
      let (ok, v, why) = vimSetValue(key, val)
      if ok: setSetting(key, v) else: error(why)
    else:
      if d.kind == skBool: setSetting(key, %(not negate))
      elif negate: error(key & " is not on or off")
      else: vimSetShow(key)

proc vimRangeAtom(b: Buffer, s: string, i: var int, ok: var bool): int =
  ## one line address of a : range at s[i] — N, ., $, '< or '> with any +N / -N after it — as a line index
  let cur = b.primary.head.line
  if i < s.len and s[i] in Digits:
    var n = 0
    while i < s.len and s[i] in Digits:
      n = n * 10 + ord(s[i]) - ord('0')
      inc i
    result = n - 1
  elif i < s.len and s[i] == '.': (result = cur; inc i)
  elif i < s.len and s[i] == '$': (result = b.lines.high; inc i)
  elif i + 1 < s.len and s[i] == '\'' and s[i + 1] in {'<', '>'}:
    let (a, e) = b.primary.range
    result = if s[i + 1] == '<': a.line
             elif e.col == 0 and e.line > a.line: e.line - 1
             else: e.line
    i += 2
  elif i < s.len and s[i] in {'+', '-'}: result = cur
  else:
    ok = false
    return
  while i < s.len and s[i] in {'+', '-'}:
    let sign = if s[i] == '+': 1 else: -1
    inc i
    var n = 0
    var any = false
    while i < s.len and s[i] in Digits:
      n = n * 10 + ord(s[i]) - ord('0')
      any = true
      inc i
    result += sign * (if any: n else: 1)
  ok = true

proc vimRange(b: Buffer, c: string): (bool, int, int, string) =
  ## the line range a : command may start with — %, one address, or two with a comma — as (there is one, its first
  ## and last line, the rest of the command)
  if c.startsWith("%"): return (true, 0, b.lines.high, c[1 .. ^1].strip)
  var i = 0
  var ok = false
  let a = vimRangeAtom(b, c, i, ok)
  if not ok: return (false, 0, 0, c)
  var e = a
  if i < c.len and c[i] in {',', ';'}:
    inc i
    var ok2 = false
    let e2 = vimRangeAtom(b, c, i, ok2)
    if ok2: e = e2
  let lo = clamp(min(a, e), 0, b.lines.high)
  let hi = clamp(max(a, e), 0, b.lines.high)
  (true, lo, hi, c[i .. ^1].strip)

proc vimSubst(b: Buffer, lo, hi: int, spec: string): int =
  ## :s/old/new/flags on lines lo..hi — the text old (not a pattern) becomes new: the first on each line, every one
  ## with g, in any case with i; how many were replaced (one undo step)
  if spec.len < 2: return 0
  let d = spec[0]
  let f = spec[1 .. ^1].split(d)
  if f.len < 2 or f[0].len == 0: return 0
  let (pat, rep) = (f[0], f[1])
  let flags = if f.len >= 3: f[2] else: ""
  let anyCase = 'i' in flags
  b.beginEdit()
  for l in lo .. min(hi, b.lines.high):
    var s = b.lines[l]
    var i = (if anyCase: s.toLowerAscii.find(pat.toLowerAscii) else: s.find(pat))
    var changed = false
    while i >= 0:
      s = s[0 ..< i] & rep & s[i + pat.len .. ^1]
      inc result
      changed = true
      if 'g' notin flags: break
      i = (if anyCase: s.toLowerAscii.find(pat.toLowerAscii, i + rep.len) else: s.find(pat, i + rep.len))
    if changed: discard b.replaceText(Pos(line: l, col: 0), Pos(line: l, col: b.lines[l].len), s)
  b.endEdit()
  b.normalize()

proc vimPutLines(b: Buffer, after: int, ls: seq[string]) =
  ## whole lines put below line `after` (-1: above the first)
  if after < 0: discard b.replaceText(Pos(line: 0, col: 0), Pos(line: 0, col: 0), ls.join("\n") & "\n")
  else:
    let p = Pos(line: after, col: b.lines[after].len)
    discard b.replaceText(p, p, "\n" & ls.join("\n"))

proc vimDelLines(b: Buffer, lo, hi: int) =
  ## lines lo..hi taken out
  if hi < b.lines.high: discard b.replaceText(Pos(line: lo, col: 0), Pos(line: hi + 1, col: 0), "")
  elif lo > 0: discard b.replaceText(Pos(line: lo - 1, col: b.lines[lo - 1].len), Pos(line: hi, col: b.lines[hi].len), "")
  else: discard b.replaceText(Pos(line: 0, col: 0), Pos(line: hi, col: b.lines[hi].len), "")

proc vimSort(b: Buffer, lo, hi: int, flags: string) =
  ## :sort on lines lo..hi — ! backwards, i in any case, n by the first number on each line, u without repeats
  if hi <= lo or not b.canEdit(): return
  var ls = b.lines[lo .. hi]
  proc firstNum(s: string): float =
    ## the first number on a line (lines without one first)
    result = -Inf
    var i = 0
    while i < s.len and s[i] notin Digits: inc i
    if i < s.len:
      var j = i
      while j < s.len and s[j] in Digits + {'.'}: inc j
      result = (try: parseFloat(s[i ..< j]) except ValueError: -Inf)
  if 'n' in flags: ls.sort(proc(x, y: string): int = cmp(firstNum(x), firstNum(y)))
  elif 'i' in flags: ls.sort(proc(x, y: string): int = cmp(x.toLowerAscii, y.toLowerAscii))
  else: ls.sort()
  if '!' in flags: ls.reverse()
  if 'u' in flags:
    var u: seq[string]
    for l in ls:
      if u.len == 0 or (if 'i' in flags: cmpIgnoreCase(u[^1], l) != 0 else: u[^1] != l): u.add l
    ls = u
  b.beginEdit()
  discard b.replaceText(Pos(line: lo, col: 0), Pos(line: hi, col: b.lines[hi].len), ls.join("\n"))
  b.endEdit()
  b.normalize()
  b.setSingle(b.firstNonBlank(lo))

proc vimRangeCmd(b: Buffer, lo0, hi0: int, rest: string, ranged: bool): bool =
  ## the : commands that work on lines — d, y, m, t / co, > <, j, sort, s, g and v — on the range given, else on the
  ## cursor's line (the whole file for sort, g and v); false when `rest` is none of them
  var lo = lo0
  var hi = hi0
  var i = 0
  while i < rest.len and rest[i] in {'a'..'z'}: inc i
  var head = rest[0 ..< i]
  if i == 0:
    while i < rest.len and rest[i] == rest[0] and rest[0] in {'>', '<'}: inc i
    head = rest[0 ..< i]
  var arg = rest[i .. ^1].strip
  if head in ["s", "g", "v"] and i < rest.len and rest[i] in {'/', '#', '|', '!'}:
    if head == "g" and rest[i] == '!':
      head = "v"
      inc i
    arg = rest[i .. ^1]
  elif head in ["s", "g", "v"]: return false
  if head notin ["d", "de", "del", "delete", "y", "ya", "yank", "m", "mo", "move", "t", "co", "copy", "j", "join",
                 "sor", "sort", "s", "g", "global", "v", "vglobal"] and head.len > 0 and head[0] notin {'>', '<'}:
    return false
  if head.len == 0: return false
  case head                                     # (other words after them: one of ned's commands, e.g. "sort lines")
  of "sor", "sort":
    if not arg.allCharsInSet({'!', 'i', 'u', 'n', ' '}): return false
  of "d", "de", "del", "delete", "y", "ya", "yank", "j", "join":
    if arg.len > 0 and not arg.allCharsInSet(Digits) and not (arg.len == 1 and arg[0] in Letters): return false
    if arg.len > 0 and arg.allCharsInSet(Digits):             # (a count: that many lines from the range's end)
      lo = hi
      hi = min(b.lines.high, hi + max(1, parseInt(arg)) - 1)
  else: discard
  if not ranged and head in ["sor", "sort", "g", "global", "v", "vglobal"]: (lo, hi) = (0, b.lines.high)
  result = true
  case head
  of "d", "de", "del", "delete":
    vimApply(b, "d", Pos(line: lo, col: 0), Pos(line: hi, col: 0), true)
  of "y", "ya", "yank":
    vimApply(b, "y", Pos(line: lo, col: 0), Pos(line: hi, col: 0), true)
    b.setSingle(b.firstNonBlank(b.primary.head.line))
    info($(hi - lo + 1) & " line" & (if hi > lo: "s" else: "") & " yanked")
  of "m", "mo", "move", "t", "co", "copy":
    if not b.canEdit(): return
    var j = 0
    var ok = false
    let at = if arg == "0": -1 else: vimRangeAtom(b, arg, j, ok)
    if arg != "0" and not ok:
      error(":" & head & " needs a line to go after (0 for the top)")
      return
    let ls = b.lines[lo .. hi]
    b.beginEdit()
    if head in ["m", "mo", "move"]:
      if at >= lo and at < hi:
        b.endEdit()
        error("Lines cannot move into themselves")
        return
      vimDelLines(b, lo, hi)
      let dest = if at > hi: at - ls.len else: at
      vimPutLines(b, clamp(dest, -1, b.lines.high), ls)
    else: vimPutLines(b, clamp(at, -1, b.lines.high), ls)
    b.endEdit()
    b.normalize()
  of "j", "join":
    if hi == lo: hi = min(lo + 1, b.lines.high)
    b.setSingle(Pos(line: hi, col: b.lines[hi].len), Pos(line: lo, col: 0))
    b.joinLines()
  of "sor", "sort":
    vimSort(b, lo, hi, arg)
  of "s":
    let n = vimSubst(b, lo, hi, arg)
    info($n & " substitution(s)")
  of "g", "global", "v", "vglobal":
    # :g/text/d, :v/text/d — the lines that have (or lack) the text deleted; :g/text/s/a/b/ — replaced on them
    if arg.len < 2: return
    let d = arg[0]
    let e = arg.find(d, 1)
    if e < 0: return
    let pat = arg[1 ..< e]
    let act = arg[e + 1 .. ^1].strip
    let keep = head in ["v", "vglobal"]
    var hits: seq[int]
    for l in lo .. hi:
      if (pat in b.lines[l]) != keep: hits.add l
    if act in ["d", "delete"]:
      if not b.canEdit(): return
      b.beginEdit()
      for k in countdown(hits.high, 0): vimDelLines(b, hits[k], hits[k])
      b.endEdit()
      b.normalize()
      info($hits.len & " line" & (if hits.len == 1: "" else: "s") & " deleted")
    elif act.len > 1 and act[0] == 's':
      var n = 0
      for l in hits: n += vimSubst(b, l, l, act[1 .. ^1])
      info($n & " substitution(s)")
    else: error(":g does d (delete) and s/a/b/ on the lines it finds")
  else:
    # :> :>> :< — the lines in or out, a level for each sign
    for _ in 1 .. head.len:
      vimApply(b, $head[0], Pos(line: lo, col: 0), Pos(line: hi, col: 0), true)

proc vimHelp(topic: string) =
  ## :help — with a setting or command name, what it is; else what the : line understands, in a tab of its own
  let t = topic.strip
  if t.len > 0:
    let key = vimSettingKey(t)
    if key.len > 0:
      vimSetShow(key)
      return
    for c in commands:
      if cmpIgnoreCase(c.name, t) == 0:
        info(c.name & (if c.keys.len > 0: " — " & c.keys else: "") & " (run it with :" & c.name & ")")
        return
  var s = "# The : command line (Vim mode)\n\n" &
    "Every command of ned runs from here by its name, in any case, or by enough of its start to be the only one: " &
    "`:Files`, `:sort lines`, `:git: commit`. **Tab** completes command names, settings and their values, themes, " &
    "files and tabs; Tab again steps through the choices.\n\n" &
    "## Settings\n\n| | |\n|---|---|\n" &
    "| `:set key=value` · `:set key:value` | any of ned's settings by its key (`editor.tabSize`), or only its last part " &
    "when one setting ends so (`tabSize`) |\n" &
    "| `:set key` · `:set nokey` · `:set key!` | on · off · the other way (on-or-off settings); a setting with a value " &
    "is shown |\n| `:set key?` · `:set key&` | shows it · back as ned comes |\n" &
    "| `:set key+=2` · `:set key-=2` | a number up or down |\n| `:set` · `:set all` | the settings you changed · " &
    "every setting, in a tab |\n" &
    "| Vim's names | `wrap` `list` `cursorline` `scrolloff` `foldenable` `undofile` `autoread` `autowrite` `encoding` " &
    "`spelllang` `laststatus` `showtabline` `title` `number` `relativenumber` `colorcolumn=80,120` `mouse` " &
    "`clipboard` `background=light` `spell` `ignorecase` |\n" &
    "| this file only | `tabstop` `shiftwidth` `expandtab` `filetype=python` |\n" &
    "| `:colorscheme NAME` | the theme |\n\n" &
    "Other Vim options (`hlsearch`, `incsearch`, `autoindent` …) are accepted and left alone, so lines from a vimrc " &
    "work. A setting changed with `:set` is kept in your settings, as the Settings window keeps it.\n\n" &
    "## Files and tabs\n\n| | |\n|---|---|\n" &
    "| `:w` `:w file` `:up` `:sav file` | save · save as · save if changed · save under another name |\n" &
    "| `:q` `:q!` `:wq` `:x` `:wa` `:qa` `:wqa` | quit and write, one file or all |\n" &
    "| `:e file` `:e!` `:r file` | open · read from disk again · put a file's lines below the cursor |\n" &
    "| `:tabnew [file]` `:tabn` `:tabp` `:tabc` `:bn` `:bp` `:bd` | tabs |\n" &
    "| `:ls` · `:b 3` · `:b name` | the tabs · the third · the one whose name has that in it |\n" &
    "| `:sp` `:vs` `:new` `:vnew` `:only` | panes |\n| `:Explore` | the files |\n\n" &
    "## Lines\n\nA range comes first: `%` (the file), `.` (this line), `$` (the last), `N`, `N,M`, `'<,'>` (the " &
    "selection), each with `+N` or `-N` after it if you like.\n\n| | |\n|---|---|\n" &
    "| `:N` `:$` | go to that line |\n| `:s/old/new/gi` | replace (the text, not a pattern): every one with g, any case " &
    "with i |\n| `:d` `:y` `:m N` `:t N` `:j` `:>` `:<` | delete, yank, move or copy below line N (0: the top), " &
    "join, indent |\n| `:sort` `:sort! i n u` | sort (backwards, any case, by number, without repeats) |\n" &
    "| `:g/text/d` `:v/text/d` `:g/text/s/a/b/` | the lines that have (or lack) the text: delete them, or replace " &
    "on them |\n| `:!cmd` `:%!cmd` | run a command · put the lines through one |\n\n" &
    "## The rest\n\n`:noh` `:u` `:redo` `:cn` `:cp` `:copen` (problems) `:term` `:make` `:run` `:zen` `:pwd` " &
    "`:registers` `:help setting` and `:help command name`.\n"
  discard openScratch("vim: the : line", s, langByName("Markdown"))

proc vimCmdMatches(t: string): seq[string] =
  ## the names of ned's commands that start with t, in any case (only that one when one is t exactly)
  let lt = t.toLowerAscii
  for c in commands:
    if c.name.toLowerAscii == lt: return @[c.name]
  for c in commands:
    if c.name.toLowerAscii.startsWith(lt): result.add c.name

proc vimExCandidates(t: string): seq[string] =
  ## whole : lines that complete t — after :set a setting or Vim option (after = its values), after :colorscheme a
  ## theme, after :e :w :sp :vs :r :tabnew :sav a file, after :b a tab, after :help a setting or a command; else ned's
  ## commands and Vim's : words
  let sp = t.find(' ')
  let head = if sp < 0: t else: t[0 ..< sp]
  let arg = if sp < 0: "" else: t[sp + 1 .. ^1]
  initSettingDefs()
  if sp >= 0:
    case head
    of "set", "se", "setlocal", "setl", "setglobal", "setg":
      let ws = arg.rfind(' ')
      let w = arg[ws + 1 .. ^1]
      let before = t[0 ..< t.len - w.len]
      let eq = w.find('=')
      if eq > 0:
        let key = vimSettingKey(w[0 ..< eq])
        if key.len > 0:
          let d = setDefs[setIndex[key]]
          let v = w[eq + 1 .. ^1].toLowerAscii
          let vals = if d.kind == skBool: @["true", "false"] elif d.kind == skEnum: d.opts else: @[($sval(key)).strip(chars = {'"'})]
          for o in vals:
            if o.toLowerAscii.startsWith(v): result.add before & w[0 .. eq] & o
        return
      let lw = w.toLowerAscii
      for d in setDefs:
        if d.key.toLowerAscii.startsWith(lw): result.add before & d.key
      for (l, _, _) in VimOptNames:
        if l.startsWith(lw): result.add before & l
      for l in VimOptOwn:
        if l.len > 3 and l.startsWith(lw): result.add before & l
      return
    of "colo", "colorscheme":
      for n in allThemeNames():
        if n.startsWith(arg.toLowerAscii): result.add head & " " & n
      return
    of "e", "edit", "w", "write", "sp", "split", "vs", "vsplit", "r", "read", "tabnew", "tabe", "tabedit", "sav",
       "saveas", "new", "vnew":
      let p = completePath(arg)
      if p != arg: result.add head & " " & p
      return
    of "b", "buffer":
      for x in bufs:
        if x.name.toLowerAscii.startsWith(arg.toLowerAscii): result.add head & " " & x.name
      return
    of "h", "help":
      for d in setDefs:
        if d.key.toLowerAscii.startsWith(arg.toLowerAscii): result.add head & " " & d.key
      for c in vimCmdMatches(arg): result.add head & " " & c
      return
    else: discard
  for w in VimExWords:
    if w.startsWith(t): result.add w
  for c in vimCmdMatches(t):
    if c notin result: result.add c

proc vimExComplete(text: string): string =
  ## Tab on the : line: what was typed completed — to the longest start its completions share, the number of them in
  ## the status line; Tab again then steps through them, round
  if text == vimCompShown and vimCompList.len > 1:
    vimCompAt = (vimCompAt + 1) mod vimCompList.len
    vimCompShown = vimCompList[vimCompAt]
    info($(vimCompAt + 1) & " of " & $vimCompList.len)
    return vimCompShown
  let cands = vimExCandidates(text)
  vimCompList = cands
  vimCompAt = -1
  if cands.len == 0:
    vimCompShown = ""
    info("Nothing to complete")
    return text
  if cands.len == 1:
    vimCompShown = cands[0]
    return cands[0]
  var p = cands[0]
  for c in cands:
    while p.len > 0 and not c.toLowerAscii.startsWith(p.toLowerAscii): p.setLen(p.len - 1)
  info($cands.len & " matches: " & cands[0 ..< min(6, cands.len)].join(" · ") & (if cands.len > 6: " …" else: "") &
       " — Tab steps through them")
  if p.len > text.len: vimCompShown = p
  else:
    vimCompAt = 0
    vimCompShown = cands[0]
  vimCompShown

proc vimColo(name: string) =
  ## :colorscheme NAME — the theme (any of ned's, or a name that stands for one); alone, the theme in use
  let n = name.strip
  if n.len == 0:
    info("Theme: " & sStr("theme"))
    return
  for t in allThemeNames():
    if cmpIgnoreCase(t, n) == 0:
      setSetting("theme", %t)
      return
  if themeAlias(n.toLowerAscii).len > 0: setSetting("theme", %n.toLowerAscii)
  else: error("No theme called " & n & " (Tab after :colorscheme lists them)")

proc vimBuffer(arg: string) =
  ## :b N (the Nth tab) or :b name (the tab whose name starts with it, else has it in it)
  let a = arg.strip
  var k = -1
  if a.len > 0 and a.allCharsInSet(Digits): k = parseInt(a) - 1
  else:
    for i, x in bufs:
      if x.name.toLowerAscii.startsWith(a.toLowerAscii):
        k = i
        break
    if k < 0:
      for i, x in bufs:
        if a.toLowerAscii in x.name.toLowerAscii:
          k = i
          break
  if k in 0 .. bufs.high:
    curBuf = k
    focus = fEditor
  else: error("No tab " & a)

proc vimEx(cmd: string) =
  ## the ':' command line: a line number or range, :!cmd and range!cmd, the line commands (:s :d :y :m :t :> :< :j
  ## :sort :g :v), Vim's common ones (:w :q :e :set :colorscheme :sp :ls :b :cn :help …), a plugin's, and any of
  ## ned's commands by its name or enough of its start
  let b = buf()
  let c = cmd.strip
  if c.len == 0: return
  if plugExCommand(c): return                       # (a plugin's :Name)
  if c.allCharsInSet(Digits):
    b.centerOn(b.firstNonBlank(clamp(parseInt(c) - 1, 0, b.lines.high)))
    return
  # :!cmd runs a command (% is the file), its output in the panel · :%!cmd, :'<,'>!cmd, :.!cmd, :N,M!cmd put those
  # lines through it (sort, jq ., column -t …)
  let bang = c.find('!')
  if bang >= 0 and bang + 1 < c.len:
    let rng = c[0 ..< bang].strip
    let sh = c[bang + 1 .. ^1].strip
    var lo, hi = -1
    if rng == "%": (lo, hi) = (0, b.lines.high)
    elif rng == ".": (lo, hi) = (b.primary.head.line, b.primary.head.line)
    elif rng == "'<,'>":
      let (a, e) = b.primary.range
      (lo, hi) = (a.line, (if e.col == 0 and e.line > a.line: e.line - 1 else: e.line))
    elif rng.split(',').len == 2 and rng.split(',')[0].strip.allDigits and rng.split(',')[1].strip.allDigits and
         rng.split(',')[0].strip.len > 0 and rng.split(',')[1].strip.len > 0:
      lo = clamp(parseInt(rng.split(',')[0].strip) - 1, 0, b.lines.high)
      hi = clamp(parseInt(rng.split(',')[1].strip) - 1, lo, b.lines.high)
    if sh.len > 0 and rng.len == 0:
      var cmdl = ""
      for w in sh.split(' '):
        cmdl.add (if cmdl.len > 0: " " else: "") & (if w == "%" and b.path.len > 0: quoteShell(b.path) else: w)
      runCommand(cmdl, (if b.path.len > 0: parentDir(b.path) else: rootDir))
      return
    if sh.len > 0 and lo >= 0:
      b.setSingle(Pos(line: hi, col: b.lines[hi].len), Pos(line: lo, col: 0))
      pipeThroughCommand(sh)
      vimSetMode(vmNormal)
      return
  if cmdByName(c) >= 0:                             # (one of ned's commands, named in full)
    runCmd(c)
    return
  let (ranged, lo, hi, rest) = vimRange(b, c)
  if ranged and rest.len == 0:                      # (:$, :'<, :.+3 — go there)
    b.centerOn(b.firstNonBlank(hi))
    return
  let cur = b.primary.head.line
  if vimRangeCmd(b, (if ranged: lo else: cur), (if ranged: hi else: cur), (if ranged: rest else: c), ranged): return
  if ranged:
    error("Not a command for lines: " & rest)
    return
  let parts = c.splitWhitespace
  let head = parts[0]
  let arg = if parts.len > 1: c[head.len .. ^1].strip else: ""
  case head
  of "w", "write":
    if arg.len > 0: discard b.saveBuffer(absProjectPath(arg)) else: discard b.saveBuffer()
  of "up", "update":
    if b.dirty: discard b.saveBuffer()
  of "sav", "saveas":
    if arg.len > 0: discard b.saveBuffer(absProjectPath(arg)) else: runCmd("Save as…")
  of "q", "quit", "close", "clo":
    if splitOn: closeActivePane()             # (as vim's: with panes, the pane closes — the file stays open)
    elif head == "close" or head == "clo": info("One pane only")
    elif bufs.len > 1: closeBuffer(curBuf)
    else: requestQuit()
  of "q!", "quit!":
    if bufs.len > 1: closeBufferAt(curBuf) else: quitting = true
  of "wq", "x", "xit":
    if b.saveBuffer():
      if bufs.len > 1: closeBuffer(curBuf) else: requestQuit()
  of "wa", "wall": discard saveAll()
  of "qa", "qall", "qa!": (if head == "qa!": quitting = true else: requestQuit())
  of "wqa", "xa": (if saveAll(): quitting = true)
  of "e", "edit":
    if arg.len > 0: discard openFile(absProjectPath(arg)) else: b.reloadBuffer()
  of "e!", "edit!": b.reloadBuffer()
  of "r", "read":
    let p = absProjectPath(arg)
    if arg.len == 0 or not fileExists(p): error("No such file: " & arg)
    elif b.canEdit():
      var ls = readFile(p).splitLines
      if ls.len > 1 and ls[^1].len == 0: ls.setLen(ls.len - 1)
      b.beginEdit()
      vimPutLines(b, b.primary.head.line, ls)
      b.endEdit()
      b.normalize()
  of "tabnew", "tabe", "tabedit":
    if arg.len > 0: discard openFile(absProjectPath(arg)) else: newFile()
  of "new", "vnew":
    splitEditor(down = head == "new")
    if arg.len > 0: discard openFile(absProjectPath(arg)) else: newFile()
  of "bn", "bnext", "tabn", "tabnext": switchTab(1)
  of "bp", "bprev", "bprevious", "tabp", "tabprevious", "tabN", "tabNext": switchTab(-1)
  of "bd", "bdelete", "tabc", "tabclose": closeBuffer(curBuf)
  of "ls", "buffers", "files": cmdBuffers()
  of "b", "buffer": vimBuffer(arg)
  of "zen": toggleZen()
  of "noh", "nohlsearch": findQuery = ""
  of "set", "se", "setlocal", "setl", "setglobal", "setg": vimSet(arg)
  of "colo", "colorscheme": vimColo(arg)
  of "sp", "split": splitEditor(down = true)          # (one pane above the other, as vim's)
  of "vs", "vsplit": splitEditor(down = false)       # (side by side)
  of "on", "only": closeSplit()
  of "term", "terminal": toggleTerminal()
  of "make": runCurrent(true)
  of "run": runCurrent()
  of "cn", "cnext": gotoDiag(1)
  of "cp", "cprevious", "cN", "cNext": gotoDiag(-1)
  of "copen", "cope", "cw", "cwindow", "cl", "clist": showProblems()
  of "u", "undo": b.undo()
  of "red", "redo": b.redo()
  of "h", "help": vimHelp(arg)
  of "pwd": info(rootDir)
  of "Ex", "Explore", "Lex", "Lexplore", "Sex", "Sexplore", "Vex", "Vexplore": showSide(svFiles)
  of "reg", "registers", "di", "display":
    info(if vimReg.len == 0: "The register is empty"
         else: "\"\" " & vimReg[0 ..< min(100, vimReg.len)].replace("\n", "⏎"))
  else:
    let m = vimCmdMatches(c)
    if m.len == 1: runCmd(m[0])
    elif m.len > 1:
      info($m.len & " commands start so: " & m[0 ..< min(4, m.len)].join(" · ") & (if m.len > 4: " …" else: "") &
           " — Tab completes")
    else: error("Not an editor command: " & c & " (:help lists what the : line takes)")
