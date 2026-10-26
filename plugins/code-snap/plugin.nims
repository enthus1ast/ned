## code-snap — the selected code as a picture: an SVG (or an HTML page) of a window with its lines, coloured
##
##   Code snap: selection as SVG     the selected lines (none selected: the whole file) in a window with a title bar
##   Code snap: selection as HTML    (the file's name), line numbers beside them, in a monospace font, coloured by
##                                   their syntax — written to a file, its path in the status line
##   settings   plugins.code-snap.folder       data (the default: the plugin's data folder, snaps/), beside (next to
##                                             the file), or a folder of your own (~/Pictures/snaps)
##              plugins.code-snap.lineNumbers  true · .theme dark or light · .fontSize 14 · .font (the font families,
##                                             a monospace one last) · .background (around the window: a colour, or
##                                             none for no margin)
##
## The colours: ned does not give plugins the colours or tokens of a line, so code-snap colours the code itself —
## keywords, types, strings, numbers, comments, function names, constants, pragmas and decorators of Nim, Python,
## JavaScript and TypeScript, C and C++; the comments, strings and numbers of other languages. It reads the file
## from the top, so a selection that starts inside a block comment or a string of several lines is coloured as one.
## The common indentation of the lines is taken off and tabs become spaces. The file is named after the code's file
## and its lines: plugin.nims-L12-30.svg. Writing it beside your file (or in a folder of yours) is why the plugin asks
## to change files; in its own data folder it needs nothing.
import nedplugin

requiresNed(">= 6.29")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "MIT")
permission("files", "writes the picture beside your file, or in a folder you name, when plugins.code-snap.folder " &
           "says so (in its own data folder it needs no permission)")

settingDef("folder", "data", "Code snap: where the picture goes — data (the plugin's data folder), beside (next to " &
           "the file), or a folder of your own")
settingDef("lineNumbers", true, "Code snap: line numbers beside the code")
settingDef("theme", "dark", "Code snap: the colours — dark or light")
settingDef("fontSize", 14, "Code snap: the size of the code's font, in pixels")
settingDef("font", "JetBrains Mono, Fira Code, Cascadia Code, Menlo, Consolas, DejaVu Sans Mono, monospace",
           "Code snap: the font families of the code, the first one installed is used (a monospace one last)")
settingDef("background", "#d8dee9", "Code snap: the colour around the window (none: no margin, transparent)")

# ── colouring: a small lexer for each family of languages ──

type
  Kind = enum kText, kKeyword, kType, kString, kNumber, kComment, kFunction, kConst, kMeta
  Seg = tuple[text: string, kind: Kind]
  Lexer = object
    fam: string                 # nim python js c other
    lineComment: string         # (other languages: the file's)
    inBlock: int                # inside a block comment: its depth (Nim's nest)
    inStr: string               # inside a string of several lines: its end (""" ''' `)

const
  NimKeywords = ["addr", "and", "as", "asm", "bind", "block", "break", "case", "cast", "concept", "const", "continue",
                 "converter", "defer", "discard", "distinct", "div", "do", "elif", "else", "end", "enum", "except",
                 "export", "finally", "for", "from", "func", "if", "import", "in", "include", "interface", "is",
                 "isnot", "iterator", "let", "macro", "method", "mixin", "mod", "not", "notin", "object", "of", "or",
                 "out", "proc", "ptr", "raise", "ref", "return", "shl", "shr", "static", "template", "try", "tuple",
                 "type", "using", "var", "when", "while", "xor", "yield"]
  NimTypes = ["int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64", "float",
              "float32", "float64", "bool", "char", "string", "cstring", "pointer", "seq", "array", "set",
              "openArray", "varargs", "void", "auto", "untyped", "typed", "byte", "range", "Natural", "Positive"]
  NimConsts = ["true", "false", "nil", "result"]
  NimProcs = ["echo", "len", "add", "high", "low", "inc", "dec", "assert", "doAssert", "quit", "ord", "chr", "newSeq",
              "items", "pairs", "toSeq", "debugEcho"]
  PyKeywords = ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else",
                "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not",
                "or", "pass", "raise", "return", "try", "while", "with", "yield", "match", "case"]
  PyTypes = ["int", "str", "float", "bool", "list", "dict", "set", "tuple", "bytes", "object", "type"]
  PyConsts = ["True", "False", "None", "self", "cls"]
  JsKeywords = ["break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else",
                "export", "extends", "finally", "for", "function", "if", "import", "in", "instanceof", "let", "new",
                "return", "super", "switch", "throw", "try", "typeof", "var", "void", "while", "with", "yield",
                "async", "await", "of", "static", "get", "set", "from", "as", "interface", "type", "enum",
                "implements", "private", "public", "protected", "readonly", "declare", "namespace", "abstract"]
  JsTypes = ["string", "number", "boolean", "any", "unknown", "never", "object", "bigint", "symbol"]
  JsConsts = ["true", "false", "null", "undefined", "NaN", "Infinity", "this"]
  CKeywords = ["auto", "break", "case", "const", "continue", "default", "do", "else", "enum", "extern", "for", "goto",
               "if", "inline", "register", "restrict", "return", "sizeof", "static", "struct", "switch", "typedef",
               "union", "volatile", "while", "class", "namespace", "template", "typename", "public", "private",
               "protected", "virtual", "override", "new", "delete", "using", "try", "catch", "throw", "constexpr",
               "operator", "friend", "noexcept", "final"]
  CTypes = ["void", "char", "short", "int", "long", "float", "double", "signed", "unsigned", "bool", "size_t",
            "ssize_t", "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t",
            "uintptr_t", "_Bool", "FILE", "wchar_t"]
  CConsts = ["NULL", "true", "false", "nullptr", "this"]

func family(lang: string): string =
  case lang
  of "nim", "nimscript", "nims", "nimble": "nim"
  of "python": "python"
  of "javascript", "typescript", "javascriptreact", "typescriptreact", "json": "js"
  of "c", "cpp", "objective-c", "objc": "c"
  else: "other"

proc newLexer(lang, lineComment: string): Lexer =
  Lexer(fam: family(lang), lineComment: (if family(lang) == "other": lineComment else: ""))

func wordKind(lx: Lexer, w: string, prev: string): Kind =
  ## a name's colour: by the word, and by the word before it (proc f, def f, class C)
  case lx.fam
  of "nim":
    if prev in ["proc", "func", "method", "iterator", "template", "macro", "converter"]: return kFunction
    if w in NimKeywords: return kKeyword
    if w in NimTypes: return kType
    if w in NimConsts: return kConst
    if w in NimProcs: return kFunction
  of "python":
    if prev == "def": return kFunction
    if prev == "class": return kType
    if w in PyKeywords: return kKeyword
    if w in PyTypes: return kType
    if w in PyConsts: return kConst
  of "js":
    if prev == "function": return kFunction
    if prev in ["class", "interface", "extends", "implements"]: return kType
    if w in JsKeywords: return kKeyword
    if w in JsTypes: return kType
    if w in JsConsts: return kConst
  of "c":
    if prev in ["struct", "class", "enum", "union"]: return kType
    if w in CKeywords: return kKeyword
    if w in CTypes: return kType
    if w in CConsts: return kConst
  else: return kText
  if w.len > 1 and w[0] in {'A' .. 'Z'} and lx.fam != "c": return kType
  kText

proc lexLine(lx: var Lexer, s: string): seq[Seg] =
  ## one line's pieces and their colours (the lexer carries a comment or a string of several lines to the next)
  var i = 0
  var prevWord = ""
  template add(a, e: int, k: Kind) =
    if e > a:
      if result.len > 0 and result[^1].kind == k: result[^1].text.add s[a ..< e]
      else: result.add (s[a ..< e], k)
  let n = s.len
  while i < n:
    # (a comment or a string still open from the lines before)
    if lx.inBlock > 0:
      var e = i
      var depth = lx.inBlock
      let (open, close) = if lx.fam == "nim": ("#[", "]#") else: ("/*", "*/")
      while e < n and depth > 0:
        if lx.fam == "nim" and s.continuesWith(open, e):
          inc depth
          e += 2
        elif s.continuesWith(close, e):
          dec depth
          e += 2
        else: inc e
      lx.inBlock = depth
      add(i, e, kComment)
      i = e
      continue
    if lx.inStr.len > 0:
      var e = i
      var closed = false
      while e < n:
        if s[e] == '\\' and lx.fam != "nim":
          e += 2
          continue
        if s.continuesWith(lx.inStr, e):
          e += lx.inStr.len
          closed = true
          break
        inc e
      e = min(e, n)
      add(i, e, kString)
      if closed: lx.inStr = ""
      i = e
      continue
    let c = s[i]
    let prevC = if i > 0: s[i - 1] else: ' '
    # comments
    if lx.fam == "nim" and c == '#':
      if i + 1 < n and s[i + 1] == '[' or (i + 2 < n and s[i + 1] == '#' and s[i + 2] == '['):
        lx.inBlock = 1
        let st = i
        i += (if s[i + 1] == '[': 2 else: 3)
        var e = i
        while e < n and lx.inBlock > 0:
          if s.continuesWith("#[", e):
            inc lx.inBlock
            e += 2
          elif s.continuesWith("]#", e):
            dec lx.inBlock
            e += 2
          else: inc e
        add(st, e, kComment)
        i = e
        continue
      add(i, n, kComment)
      break
    if lx.fam == "python" and c == '#':
      add(i, n, kComment)
      break
    if lx.fam in ["js", "c"] and c == '/' and i + 1 < n and s[i + 1] == '/':
      add(i, n, kComment)
      break
    if lx.fam in ["js", "c"] and c == '/' and i + 1 < n and s[i + 1] == '*':
      let k = s.find("*/", i + 2)
      if k < 0:
        lx.inBlock = 1
        add(i, n, kComment)
        break
      add(i, k + 2, kComment)
      i = k + 2
      continue
    if lx.fam == "other" and lx.lineComment.len > 0 and s.continuesWith(lx.lineComment, i):
      add(i, n, kComment)
      break
    # C's preprocessor: the whole line
    if lx.fam == "c" and c == '#' and s[0 ..< i].strip.len == 0:
      let k = s.find("//", i)
      add(i, (if k < 0: n else: k), kMeta)
      i = if k < 0: n else: k
      continue
    # pragmas, decorators
    if lx.fam == "nim" and c == '{' and i + 1 < n and s[i + 1] == '.':
      let k = s.find(".}", i + 2)
      let e = if k < 0: n else: k + 2
      add(i, e, kMeta)
      i = e
      continue
    if lx.fam in ["python", "js"] and c == '@' and i + 1 < n and s[i + 1] in IdentStartChars:
      var e = i + 1
      while e < n and s[e] in IdentChars + {'.'}: inc e
      add(i, e, kMeta)
      i = e
      continue
    # strings
    let triple = (lx.fam == "nim" and s.continuesWith("\"\"\"", i)) or
                 (lx.fam == "python" and (s.continuesWith("\"\"\"", i) or s.continuesWith("'''", i)))
    if triple:
      let q = s[i ..< i + 3]
      let k = s.find(q, i + 3)
      if k < 0:
        lx.inStr = q
        add(i, n, kString)
        break
      var e = k + 3
      while e < n and s[e] == '"' and lx.fam == "nim": inc e
      add(i, e, kString)
      i = e
      continue
    if lx.fam == "js" and c == '`':
      let k = s.find('`', i + 1)
      if k < 0:
        lx.inStr = "`"
        add(i, n, kString)
        break
      add(i, k + 1, kString)
      i = k + 1
      continue
    let isChar = c == '\'' and (lx.fam != "nim" or prevC notin IdentChars)
    if c == '"' or isChar:
      let raw = lx.fam == "nim" and c == '"' and prevC in {'r', 'R'} and (i < 2 or s[i - 2] notin IdentChars)
      var e = i + 1
      while e < n:
        if s[e] == '\\' and not raw:
          e += 2
          continue
        if s[e] == c:
          if raw and e + 1 < n and s[e + 1] == '"':
            e += 2
            continue
          inc e
          break
        inc e
      e = min(e, n)
      # (the prefix of r"…", f"…", b'…' is part of the string)
      if result.len > 0 and result[^1].kind in {kText, kFunction, kType} and i > 0 and prevC in Letters:
        var a = i
        while a > 0 and s[a - 1] in Letters and i - a < 3: dec a
        if a == 0 or s[a - 1] notin IdentChars:
          let pre = s[a ..< i]
          if result[^1].text.endsWith(pre):
            result[^1].text.setLen(result[^1].text.len - pre.len)
            if result[^1].text.len == 0: result.setLen(result.len - 1)
            add(a, e, kString)
            i = e
            continue
      add(i, e, kString)
      i = e
      continue
    # numbers
    if c in Digits and prevC notin IdentChars:
      var e = i + 1
      while e < n and (s[e] in IdentChars + {'\''} or (s[e] == '.' and e + 1 < n and s[e + 1] in Digits)): inc e
      add(i, e, kNumber)
      i = e
      continue
    # names
    if c in IdentStartChars or ord(c) >= 0x80:
      var e = i + 1
      while e < n and (s[e] in IdentChars or ord(s[e]) >= 0x80): inc e
      let w = s[i ..< e]
      var k = wordKind(lx, w, prevWord)
      if k == kText and lx.fam != "other":
        var a = e
        if a < n and s[a] == '*' and lx.fam == "nim": inc a          # (proc f*( — exported)
        if a < n and s[a] == '(': k = kFunction
      add(i, e, k)
      prevWord = w
      i = e
      continue
    if c notin {' ', '\t'}: prevWord = ""
    add(i, i + 1, kText)
    inc i

# ── the picture ──

type Theme = object
  bg, fg, bar, title, lineNo: string
  kinds: array[Kind, string]

func theme(name: string): Theme =
  if name == "light":
    Theme(bg: "#fafafa", fg: "#383a42", bar: "#eaeaeb", title: "#696c77", lineNo: "#a0a1a7",
          kinds: ["#383a42", "#a626a4", "#c18401", "#50a14f", "#986801", "#a0a1a7", "#4078f2", "#0184bc", "#e45649"])
  else:
    Theme(bg: "#282c34", fg: "#abb2bf", bar: "#21252b", title: "#9da5b4", lineNo: "#636d83",
          kinds: ["#abb2bf", "#c678dd", "#e5c07b", "#98c379", "#d19a66", "#7f848e", "#61afef", "#56b6c2", "#e06c75"])

func esc(s: string): string =
  for c in s:
    case c
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '"': result.add "&quot;"
    else: result.add c

func cellWidth(cp: int): int =
  ## columns a character takes in a monospace font (East Asian wide ones and emoji: two)
  if cp in 0x1100 .. 0x115F or cp in 0x2E80 .. 0xA4CF or cp in 0xAC00 .. 0xD7A3 or cp in 0xF900 .. 0xFAFF or
     cp in 0xFE30 .. 0xFE4F or cp in 0xFF00 .. 0xFF60 or cp in 0xFFE0 .. 0xFFE6 or cp in 0x1F300 .. 0x1FAFF or
     cp in 0x20000 .. 0x3FFFD: 2
  else: 1

func columns(s: string): int =
  ## how wide the text is, in columns
  var i = 0
  while i < s.len:
    let b = ord(s[i])
    var n = 1
    var cp = b
    if b >= 0xF0: (n, cp) = (4, b and 0x07)
    elif b >= 0xE0: (n, cp) = (3, b and 0x0F)
    elif b >= 0xC0: (n, cp) = (2, b and 0x1F)
    for k in 1 ..< n:
      if i + k < s.len: cp = (cp shl 6) or (ord(s[i + k]) and 0x3F)
    if (b and 0xC0) != 0x80: result += cellWidth(cp)
    i += n

func untab(segs: seq[Seg], tabWidth: int): seq[Seg] =
  ## the tabs as spaces, to the next tab stop
  var col = 0
  for (t, k) in segs:
    var o = ""
    for ch in t:
      if ch == '\t':
        let w = tabWidth - col mod tabWidth
        o.add spaces(w)
        col += w
      else:
        o.add ch
        if (ord(ch) and 0xC0) != 0x80: inc col
    result.add (o, k)

func indentOf(segs: seq[Seg]): int =
  ## the spaces a line starts with (-1: a blank line)
  var n = 0
  for (t, _) in segs:
    for ch in t:
      if ch == ' ': inc n
      else: return n
  -1

func dedent(segs: seq[Seg], k: int): seq[Seg] =
  ## the first k spaces of the line taken off
  var left = k
  for (t, kind) in segs:
    var a = 0
    while left > 0 and a < t.len and t[a] == ' ':
      inc a
      dec left
    if a < t.len: result.add (t[a .. ^1], kind)

type Snap = object
  title: string
  first: int                    # the first line's number in the file (from 1)
  lines: seq[seq[Seg]]
  numbers: bool
  theme: string
  fontSize: int
  font, background: string

func fmtNum(x: float): string =
  let t = int(x * 10.0 + 0.5)
  $(t div 10) & (if t mod 10 != 0: "." & $(t mod 10) else: "")

func svgOf(sn: Snap): string =
  ## the picture: a window (title bar, three dots, the title), the lines and their numbers
  let th = theme(sn.theme)
  let fs = max(6, sn.fontSize).float
  let cw = fs * 0.6                                # (a monospace font's character is about 0.6 of its size wide)
  let lh = float(int(fs * 1.5 + 0.5))
  let margin = if sn.background in ["", "none", "transparent"]: 0.0 else: 32.0
  let pad = 16.0
  let barH = 32.0
  let last = sn.first + sn.lines.len - 1
  let digits = len($last)
  let gutter = if sn.numbers: (digits.float + 2.0) * cw else: 0.0
  var widest = 0
  for segs in sn.lines:
    var w = 0
    for (t, _) in segs: w += columns(t)
    widest = max(widest, w)
  let winW = max(320.0, pad * 2.0 + gutter + widest.float * cw)
  let winH = barH + pad * 2.0 + sn.lines.len.float * lh
  let w = winW + margin * 2.0
  let h = winH + margin * 2.0
  var o = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"" & fmtNum(w) & "\" height=\"" & fmtNum(h) &
          "\" viewBox=\"0 0 " & fmtNum(w) & " " & fmtNum(h) & "\">\n"
  o.add "  <title>" & esc(sn.title) & "</title>\n"
  if margin > 0:
    o.add "  <defs><filter id=\"shadow\" x=\"-10%\" y=\"-10%\" width=\"120%\" height=\"130%\">" &
          "<feDropShadow dx=\"0\" dy=\"8\" stdDeviation=\"10\" flood-opacity=\"0.35\"/></filter></defs>\n"
    o.add "  <rect width=\"100%\" height=\"100%\" fill=\"" & esc(sn.background) & "\"/>\n"
  let x0 = margin
  let y0 = margin
  o.add "  <rect x=\"" & fmtNum(x0) & "\" y=\"" & fmtNum(y0) & "\" width=\"" & fmtNum(winW) & "\" height=\"" &
        fmtNum(winH) & "\" rx=\"10\" fill=\"" & th.bg & "\"" & (if margin > 0: " filter=\"url(#shadow)\"" else: "") &
        "/>\n"
  o.add "  <path d=\"M" & fmtNum(x0) & " " & fmtNum(y0 + barH) & " V" & fmtNum(y0 + 10.0) & " a10 10 0 0 1 10 -10 H" &
        fmtNum(x0 + winW - 10.0) & " a10 10 0 0 1 10 10 V" & fmtNum(y0 + barH) & " Z\" fill=\"" & th.bar & "\"/>\n"
  for k, col in ["#ff5f57", "#febc2e", "#28c840"]:
    o.add "  <circle cx=\"" & fmtNum(x0 + 20.0 + k.float * 20.0) & "\" cy=\"" & fmtNum(y0 + barH / 2.0) &
          "\" r=\"6\" fill=\"" & col & "\"/>\n"
  o.add "  <text x=\"" & fmtNum(x0 + winW / 2.0) & "\" y=\"" & fmtNum(y0 + barH / 2.0 + 4.5) &
        "\" text-anchor=\"middle\" font-family=\"" & esc(sn.font) & "\" font-size=\"12\" fill=\"" & th.title & "\">" &
        esc(sn.title) & "</text>\n"
  o.add "  <g font-family=\"" & esc(sn.font) & "\" font-size=\"" & fmtNum(fs) &
        "\" xml:space=\"preserve\" style=\"white-space: pre\">\n"
  for i, segs in sn.lines:
    let y = y0 + barH + pad + i.float * lh + (lh + fs) / 2.0 - fs * 0.2
    if sn.numbers:
      o.add "    <text x=\"" & fmtNum(x0 + pad + digits.float * cw) & "\" y=\"" & fmtNum(y) &
            "\" text-anchor=\"end\" fill=\"" & th.lineNo & "\">" & $(sn.first + i) & "</text>\n"
    if segs.len == 0: continue
    o.add "    <text x=\"" & fmtNum(x0 + pad + gutter) & "\" y=\"" & fmtNum(y) & "\" fill=\"" & th.fg & "\">"
    for (t, k) in segs:
      if k == kText: o.add esc(t)
      else:
        o.add "<tspan fill=\"" & th.kinds[k] & "\"" & (if k == kComment: " font-style=\"italic\"" else: "") & ">" &
              esc(t) & "</tspan>"
    o.add "</text>\n"
  o.add "  </g>\n</svg>\n"
  o

func htmlOf(sn: Snap): string =
  ## the same as a page of its own: the window drawn with CSS, the code in a <pre>
  let th = theme(sn.theme)
  let margin = if sn.background in ["", "none", "transparent"]: "0" else: "32px"
  let back = if margin == "0": "transparent" else: sn.background
  let digits = len($(sn.first + sn.lines.len - 1))
  const Cls: array[Kind, string] = ["", "k", "t", "s", "n", "c", "f", "o", "m"]
  var o = "<!doctype html>\n<html><head><meta charset=\"utf-8\"><title>" & esc(sn.title) & "</title>\n<style>\n"
  o.add "body { margin: 0; padding: " & margin & "; background: " & esc(back) & "; display: inline-block; }\n"
  o.add ".win { background: " & th.bg & "; border-radius: 10px; overflow: hidden; display: inline-block; " &
        "min-width: 320px;" &
        (if margin == "0": "" else: " box-shadow: 0 8px 20px rgba(0, 0, 0, 0.35);") & " }\n"
  o.add ".bar { background: " & th.bar & "; height: 32px; position: relative; text-align: center; " &
        "font: 12px/32px " & sn.font & "; color: " & th.title & "; }\n"
  o.add ".dots { position: absolute; left: 14px; top: 10px; display: flex; gap: 8px; }\n"
  o.add ".dots i { width: 12px; height: 12px; border-radius: 50%; display: block; }\n"
  o.add "pre { margin: 0; padding: 16px; font: " & $max(6, sn.fontSize) & "px/1.5 " & sn.font & "; color: " & th.fg &
        "; tab-size: 4; }\n"
  o.add ".ln { color: " & th.lineNo & "; display: inline-block; width: " & $digits & "ch; text-align: right; " &
        "margin-right: 2ch; user-select: none; }\n"
  for k in Kind:
    if Cls[k].len > 0:
      o.add "." & Cls[k] & " { color: " & th.kinds[k] & ";" & (if k == kComment: " font-style: italic;" else: "") &
            " }\n"
  o.add "</style></head>\n<body><div class=\"win\"><div class=\"bar\"><span class=\"dots\"><i style=\"background: " &
        "#ff5f57\"></i><i style=\"background: #febc2e\"></i><i style=\"background: #28c840\"></i></span>" &
        esc(sn.title) & "</div><pre>"
  for i, segs in sn.lines:
    if i > 0: o.add "\n"
    if sn.numbers: o.add "<span class=\"ln\">" & $(sn.first + i) & "</span>"
    for (t, k) in segs:
      if k == kText: o.add esc(t)
      else: o.add "<span class=\"" & Cls[k] & "\">" & esc(t) & "</span>"
  o.add "</pre></div></body></html>\n"
  o

# ── the commands ──

proc snapOf(b: Buf): (bool, Snap) =
  ## the selected lines (none selected: the whole file), coloured, the indentation they share taken off
  let sel = b.selection
  var first, last: int
  if sel.isEmpty:
    first = 0
    last = b.lineCount - 1
  else:
    first = sel.start.line
    last = sel.stop.line
    if sel.stop.col == 0 and last > first: dec last         # (a selection of whole lines ends at the next line)
  let from0 = max(0, first - 5000)                          # (the lexer reads from the top: up to 5000 lines before)
  let all = b.lines(from0, last)
  var lx = newLexer(b.lang, b.lineComment)
  var rows: seq[seq[Seg]]
  let unit = b.indentUnit
  let tabW = if unit == "\t" or unit.len == 0: 4 else: unit.len
  for i, l in all:
    let segs = lexLine(lx, l)
    if from0 + i >= first: rows.add untab(segs, tabW)
  while rows.len > 0 and indentOf(rows[^1]) < 0:            # (blank lines at the ends left out)
    rows.setLen(rows.len - 1)
  while rows.len > 0 and indentOf(rows[0]) < 0:
    rows.delete(0)
    inc first
  if rows.len == 0: return (false, Snap())
  var common = -1
  for r in rows:
    let k = indentOf(r)
    if k >= 0 and (common < 0 or k < common): common = k
  var sn = Snap(first: first + 1, numbers: setting("lineNumbers", true), theme: setting("theme", "dark"),
                fontSize: setting("fontSize", 14), font: setting("font", "JetBrains Mono, Fira Code, Cascadia Code, " &
                "Menlo, Consolas, DejaVu Sans Mono, monospace"), background: setting("background", "#d8dee9"))
  for r in rows: sn.lines.add dedent(r, max(0, common))
  let p = b.path
  sn.title = if p.len > 0: extractFilename(p) else: b.title
  (true, sn)

proc snap(ext: string) =
  let b = current()
  if not b.valid:
    message("Code snap: open a file first")
    return
  let (ok, sn) = snapOf(b)
  if not ok:
    message("Code snap: nothing to draw — the lines are empty")
    return
  let text = if ext == "svg": svgOf(sn) else: htmlOf(sn)
  let last = sn.first + sn.lines.len - 1
  var base = sn.title
  for ch in ['/', '\\', ':', '*', '?', '"', '<', '>', '|']: base = base.replace($ch, "_")
  let name = base & "-L" & $sn.first & (if last > sn.first: "-" & $last else: "") & "." & ext
  let where = setting("folder", "data").strip
  let p = b.path
  var path = ""
  if where == "beside" and p.len > 0: path = p.parentDir / name
  elif where notin ["", "data", "beside"]:
    let d = expandTilde(where)
    if not dirExists(d):
      warn("Code snap: there is no folder " & d & " (plugins.code-snap.folder)")
      return
    path = d / name
  if path.len > 0:
    writeFile(path, text)
  else:
    writeData("snaps/" & name, text)
    path = dataDir() / "snaps" / name
  message("Code snap: " & path)

command "Code snap: selection as SVG": snap("svg")
command "Code snap: selection as HTML": snap("html")
