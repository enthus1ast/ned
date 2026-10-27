# ════════════════════════════════════════════════════════════════════════════
#  The code in a Nim file's triple-quoted strings — SQL, HTML, JSON (and CSS) — formatted with ned's own formatter
#  for that language when the Nim is formatted (nim.format.embedded), each line kept at the string's indentation.
#  Which language a string holds: its prefix (sql"""…""", html"""…"""), a #[sql]# marker just before it, the
#  routine it is given to (parseJson("""…"""), a database's exec/getRow… with SQL in it, a name of yours in
#  nim.embeddedLanguages), or — like the colours — a string that starts with an HTML tag or an SQL statement.
#  Only strings whose text starts on the line after the opening quotes; a string the formatter is not sure of
#  (its check fails, or the result would hold `"""`) stays as it is.
# ════════════════════════════════════════════════════════════════════════════

var FmtEmbedded* = true    # nim.format.embedded: the SQL, HTML and JSON in triple-quoted strings formatted too

const
  FEmbedNames = [("sql", "sql"), ("html", "html"), ("css", "css"), ("json", "json"), ("parseJson", "json"),
                 ("parseHtml", "html"), ("parseXml", "html")]
  # (a database library's routines: their string is SQL when it reads as SQL)
  FSqlCalls = ["exec", "execAffectedRows", "tryExec", "getRow", "getAllRows", "getValue", "rows", "fastRows",
               "instantRows", "insertID", "tryInsertID", "insert", "tryInsert", "prepare", "query", "all", "one",
               "iterate", "value", "execScript"]

func fSniffEmbedded(body: string): string =
  ## "sql" or "html" when the string's text starts like it (as the colours judge it), else ""
  let s = body.strip(trailing = false)
  if s.len >= 2 and s[0] == '<' and s[1] in {'a'..'z', 'A'..'Z', '!'}: return "html"
  var w = 0
  while w < s.len and s[w] in {'A'..'Z'}: inc w             # (in capitals: `select the file` is prose)
  if w >= 4 and (w == s.len or s[w] in {' ', '\t', '\n', '\r'}) and
     s[0 ..< w] in ["SELECT", "INSERT", "UPDATE", "DELETE", "CREATE", "DROP", "ALTER", "WITH", "PRAGMA", "REPLACE"]:
    return "sql"
  ""

proc fEmbeddedLang*(toks: seq[FTok], k: int, names: Table[string, string]): string =
  ## the language of the triple-quoted string toks[k] ("sql", "html", "json", "css"), or "" — not one to format
  let t = toks[k]
  let q = t.text.find("\"\"\"")
  if q < 0 or not t.text.endsWith("\"\"\"") or t.text.len < q + 6: return ""
  let body = t.text[q + 3 ..< t.text.len - 3]
  var word = ""
  if q > 0:
    let prefix = t.text[0 ..< q]
    if prefix notin ["r", "R"]: word = names.getOrDefault(prefix, "")
    if word.len == 0:
      for (n, l) in FEmbedNames:
        if n == prefix: word = l
    if word.len == 0 and prefix notin ["r", "R"]: return ""     # (fmt"""…""" and other names: not code)
  # a #[sql]# marker just before it
  if word.len == 0 and k > 0 and toks[k - 1].kind == fkComment and toks[k - 1].text.startsWith("#[") and
     toks[k - 1].text.endsWith("]#") and not toks[k - 1].nl:
    word = toks[k - 1].text[2 .. ^3].strip.toLowerAscii
    if word == "sql" or word == "html" or word == "json" or word == "css": return word
    return ""
  # the routine it is given to: `name("""…"""`, `name """…"""`, `x.name("""…"""`
  if word.len == 0 and k > 0:
    var p = k - 1
    if toks[p].kind == fkOpen and toks[p].text == "(": dec p
    if p >= 0 and toks[p].kind == fkIdent and (p < k - 1 or t.sp):
      let n = toks[p].text
      word = names.getOrDefault(n, "")
      if word.len == 0:
        for (nm, l) in FEmbedNames:
          if nm == n: word = l
      if word.len == 0 and n in FSqlCalls and fSniffEmbedded(body) == "sql": word = "sql"
  if word.len == 0: word = fSniffEmbedded(body)
  if word in ["sql", "html", "json", "css"]: word else: ""

proc fFormatEmbedded*(text: string, names = initTable[string, string]()): (string, int) =
  ## the text with the code in its triple-quoted strings formatted — (new text, strings changed)
  result = (text, 0)
  if "\"\"\"" notin text: return
  var ok = true
  let toks = fLex(text, ok)
  if not ok: return
  var outp = ""
  var at = 0
  for k in 0 ..< toks.len:
    let t = toks[k]
    if t.kind != fkStr or not t.multi: continue
    # (not the C of an {.emit: """…""".}: nim.formatEmitC's)
    if k >= 2 and toks[k - 1].kind == fkColon and toks[k - 2].kind == fkIdent and toks[k - 2].text in ["emit", "asm"]:
      continue
    let lang = fEmbeddedLang(toks, k, names)
    if lang.len == 0: continue
    let q = t.text.find("\"\"\"")
    let body = t.text[q + 3 ..< t.text.len - 3]
    if not body.startsWith("\n"): continue
    var ls = body[1 .. ^1].split('\n')
    # the closing quotes on a line of their own: that line stays as it is; else they stay after the last line
    var closing = ""
    var lastInline = true
    if ls.len > 0 and ls[^1].strip.len == 0:
      closing = ls[^1]
      ls.setLen(ls.len - 1)
      lastInline = false
    var base = high(int)
    for l in ls:
      if l.strip.len > 0: base = min(base, l.len - l.strip(trailing = false).len)
    if base == high(int): continue
    var plain = ""
    for l in ls: plain.add (if l.strip.len == 0: "" else: l[min(base, l.len) .. ^1].strip(leading = false)) & "\n"
    let width = max(40, (if FmtWidth > 0: FmtWidth else: 88) - base)
    let (res, err) =
      case lang
      of "sql": fmtSql(plain, 2)
      of "html": fmtHtml(plain, 2, width)
      of "json": fmtJson(plain, 2, width)
      else: fmtCss(plain, 2)
    if err.len > 0 or "\"\"\"" in res: continue
    # (JSON: only text that is JSON — its formatter would lay out a piece of it too)
    if lang == "json":
      try: discard parseJson(plain)
      except CatchableError: continue
    let r = res.strip(chars = {'\n'})
    if r.len == 0 or r == plain.strip(chars = {'\n'}) or (lastInline and r.endsWith("\"")): continue
    var nb = t.text[0 ..< q] & "\"\"\"\n"
    let rl = r.split('\n')
    for i, l in rl:
      nb.add (if l.strip.len == 0: "" else: spaces(base) & l.strip(leading = false))
      if i < rl.high or not lastInline: nb.add "\n"
    nb.add closing & "\"\"\""
    if nb == t.text: continue
    outp.add text[at ..< t.pos]
    outp.add nb
    at = t.pos + t.text.len
    inc result[1]
  if result[1] == 0: return
  outp.add text[at .. ^1]
  result[0] = outp
