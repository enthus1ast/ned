# ── SQL: each clause of a statement on its own line, lists and conditions broken when long, sub-queries indented;
# keywords in one case, everything else (names, strings, comments, placeholders, templates) as written ──

const
  sqlMaxW = 80
  sqlChanged = "the built-in SQL formatter would change the statement here, so nothing was changed"
  sqlKeywords = ["ADD", "ALL", "ALTER", "AND", "ANY", "AS", "ASC", "AUTOINCREMENT", "AUTO_INCREMENT", "BEGIN",
    "BETWEEN", "BIGINT", "BIGSERIAL", "BOOL", "BOOLEAN", "BY", "CASCADE", "CASE", "CAST", "CHAR", "CHARACTER",
    "CHECK", "COLLATE", "COLUMN", "COMMIT", "CONFLICT", "CONSTRAINT", "CREATE", "CROSS", "CURRENT_DATE",
    "CURRENT_TIME", "CURRENT_TIMESTAMP", "DATABASE", "DATE", "DECIMAL", "DEFAULT", "DELETE", "DESC", "DISTINCT",
    "DO", "DOUBLE", "DROP", "ELSE", "END", "ESCAPE", "EXCEPT", "EXISTS", "EXPLAIN", "FALSE", "FETCH", "FILTER",
    "FIRST", "FLOAT", "FOR", "FOREIGN", "FROM", "FULL", "FUNCTION", "GRANT", "GROUP", "HAVING", "IF", "ILIKE", "IN",
    "INDEX", "INNER", "INSERT", "INT", "INTEGER", "INTERSECT", "INTERVAL", "INTO", "IS", "JOIN", "JSON", "JSONB",
    "KEY", "LAST", "LATERAL", "LEFT", "LIKE", "LIMIT", "MATERIALIZED", "NATURAL", "NEXT", "NOT", "NOTHING", "NULL",
    "NULLS", "NUMERIC", "OFFSET", "ON", "ONLY", "OR", "ORDER", "OUTER", "OVER", "PARTITION", "PRECISION",
    "PRIMARY", "REAL", "RECURSIVE", "REFERENCES", "RENAME", "REPLACE", "RESTRICT", "RETURNING", "REVOKE", "RIGHT",
    "ROLLBACK", "ROW", "ROWS", "SCHEMA", "SELECT", "SERIAL", "SET", "SIMILAR", "SMALLINT", "SOME", "TABLE", "TEMP",
    "TEMPORARY", "TEXT", "THEN", "TIME", "TIMESTAMP", "TIMESTAMPTZ", "TO", "TRANSACTION", "TRIGGER", "TRUE",
    "TRUNCATE", "UNION", "UNIQUE", "UPDATE", "USING", "UUID", "VALUES", "VARCHAR", "VIEW", "WHEN", "WHERE",
    "WINDOW", "WITH", "WITHIN", "ZONE"]
  sqlFuncKw = ["ALL", "ANY", "BIGINT", "CAST", "CHAR", "CHARACTER", "DECIMAL", "DOUBLE", "FLOAT", "IF", "INT",
    "INTEGER", "INTERVAL", "LEFT", "NUMERIC", "REAL", "REPLACE", "RIGHT", "SMALLINT", "SOME", "TIME", "TIMESTAMP",
    "VARCHAR"]                                   # (and a `(` after them as in the source: CAST(…), VARCHAR(20))
  sqlTableAfter = ["FROM", "JOIN", "INTO", "UPDATE", "TABLE", "EXISTS"]   # a table's name comes next: as written…
  sqlNotTable = ["IF", "ONLY", "LATERAL", "SELECT", "VALUES", "NOT", "SET", "NULL", "TRUE", "FALSE", "TEMP",
    "TEMPORARY", "CASCADE", "RESTRICT", "CURRENT_TIMESTAMP"]   # … unless it is one of these
  sqlJoinWords = ["NATURAL", "LEFT", "RIGHT", "FULL", "INNER", "OUTER", "CROSS"]
  sqlOps3 = ["->>", "#>>", "!~*", "<=>", "<<=", ">>="]
  sqlOps2 = ["<=", ">=", "<>", "!=", "==", "||", "&&", "::", ":=", "=>", "->", "#>", "@>", "<@", "~*", "!~", "<<",
    ">>", "?|", "?&", "**", "~~", "@@"]

type
  SqlKind = enum skWord, skNum, skStr, skIdent, skParam, skTempl, skOp, skPunct, skComment, skLineComment
  SqlTok = object
    kind: SqlKind
    text: string     # as written (a line comment without the spaces at its end)
    up: string       # a word in upper case
    nl: int          # line breaks before it in the source
    ws: bool         # whitespace before it in the source
    kw: bool         # a keyword: its case is the formatter's
    unary: bool      # a - + ~ before its operand
    star: bool       # a * for all columns
  SqlFmt = object
    t: seq[SqlTok]
    mt: seq[int]     # the matching parenthesis of each ( and ), -1 elsewhere
    lines: seq[string]
    cur: string      # the line being made, its indentation in it
    lvl: int         # … its level
    fresh: bool      # … nothing on it yet
    last: int        # the token put last on it
    brk: bool        # a line comment ended it
    ind: int
    upper: bool

func sqlIsWordChar(c: char): bool = c in {'a'..'z', 'A'..'Z', '0'..'9', '_', '$'} or c.uint8 >= 0x80

func sqlQuoteEnd(s: string, i: int, q: char, backslash: bool): int =
  ## the end (exclusive) of the quoted text at s[i] (q doubled inside stands for itself), -1 when it is not closed
  var j = i + 1
  while j < s.len:
    if backslash and s[j] == '\\': j += 2
    elif s[j] == q:
      if j + 1 < s.len and s[j + 1] == q: j += 2
      else: return j + 1
    else: inc j
  -1

func sqlTemplEnd(s: string, i: int): int =
  ## the end of the template at s[i] ({{ }}, {% %}, {# #}, a strformat {expr}, ${expr}), -1 when there is none
  let b = if s[i] == '$': i + 1 else: i
  if b >= s.len or s[b] != '{': return -1
  if b + 1 < s.len and s[b + 1] in {'{', '%', '#'}:
    let close = if s[b + 1] == '{': "}}" else: s[b + 1] & "}"
    let e = s.find(close, b + 2)
    if e >= 0: return e + 2
  var depth = 0
  for j in b ..< s.len:
    case s[j]
    of '{': inc depth
    of '}':
      dec depth
      if depth == 0: return j + 1
    of '\n': return -1
    else: discard
  -1


proc sqlToks(s: string, err: var string): seq[SqlTok] =
  var i = 0
  var nl = 0
  var ws = false
  template add(k: SqlKind, e: int) =
    result.add SqlTok(kind: k, text: s[i ..< e], nl: nl, ws: ws)
    nl = 0
    ws = false
    i = e
  template fail(msg: string) =
    err = msg & " (line " & $(s[0 ..< i].count('\n') + 1) & ")"
    return
  while i < s.len:
    let c = s[i]
    let d = if i + 1 < s.len: s[i + 1] else: '\0'
    if c in {' ', '\t', '\r', '\f', '\v', '\n'}:
      ws = true
      if c == '\n': inc nl
      inc i
    elif c in {'\'', '"', '`'} or c in {'N', 'n', 'E', 'e', 'B', 'b', 'X', 'x'} and d == '\'' and
        (i == 0 or not sqlIsWordChar(s[i - 1])):
      # a string ('…', N'…', E'…') or a quoted name ("…", `…`); where a backslash before a quote decides where
      # it ends, the dialect decides, so the formatter leaves it alone
      let q = if c in {'\'', '"', '`'}: i else: i + 1
      let plain = sqlQuoteEnd(s, q, s[q], false)
      let escaped = sqlQuoteEnd(s, q, s[q], true)
      let e = if s[q] == '`': plain elif c in {'E', 'e'}: escaped else: (if plain == escaped: plain else: -2)
      if e == -2: fail "a string has a backslash before a quote (where it ends depends on the SQL dialect)"
      if e < 0: fail "a string or a quoted name is not closed"
      add((if s[q] == '\'': skStr else: skIdent), e)
    elif c == '-' and d == '-' or c == '#' and (d notin {'>', '-'} or s.continuesWith("#--", i)):
      var j = i
      while j < s.len and s[j] != '\n': inc j
      add(skLineComment, j)
      result[^1].text = result[^1].text.strip(leading = false)
    elif c == '/' and d == '*':
      let e = s.find("*/", i + 2)
      if e < 0: fail "a comment is not closed"
      add(skComment, e + 2)
    elif c in {'$', '?', ':'} and d in Digits:
      var j = i + 1
      while j < s.len and s[j] in Digits: inc j
      add(skParam, j)
    elif c == '$' and d == '{' or c == '{':
      let e = sqlTemplEnd(s, i)
      if e < 0: add(skOp, i + 1)
      else: add(skTempl, e)
    elif c == '$' and (d == '$' or d in Letters + {'_'}):
      # a dollar-quoted string: $$…$$, $tag$…$tag$
      var j = i + 1
      while j < s.len and s[j] in IdentChars: inc j
      if j < s.len and s[j] == '$':
        let tag = s[i .. j]
        let e = s.find(tag, j + 1)
        if e < 0: fail "a dollar-quoted string is not closed"
        add(skStr, e + tag.len)
      else: add(skWord, j)
    elif c in {':', '@'} and d in Letters + {'_'} or c == '@' and d == '@' and i + 2 < s.len and s[i + 2] in Letters:
      # :name, @name, @@name
      var j = i + 1
      if s[j] == '@': inc j
      while j < s.len and sqlIsWordChar(s[j]): inc j
      add(skParam, j)
    elif c == '?' and d notin {'|', '&'}: add(skParam, i + 1)
    elif c in {'(', ')', ',', ';', '[', ']'} or c == '.' and d notin Digits: add(skPunct, i + 1)
    elif c in Digits or c == '.' and d in Digits:
      var j = i + 1
      while j < s.len:
        if s[j] in Digits + {'.'}: inc j
        elif s[j] in {'e', 'E'} and j + 1 < s.len and s[j + 1] in Digits: j += 2
        elif s[j] in {'e', 'E'} and j + 2 < s.len and s[j + 1] in {'+', '-'} and s[j + 2] in Digits: j += 3
        else: break
      if j < s.len and sqlIsWordChar(s[j]):      # 0x1F, 1st_col: a word
        while j < s.len and sqlIsWordChar(s[j]): inc j
        add(skWord, j)
      else: add(skNum, j)
    elif sqlIsWordChar(c):
      var j = i + 1
      while j < s.len and sqlIsWordChar(s[j]): inc j
      add(skWord, j)
    else:
      var e = i + 1
      for op in sqlOps2:
        if s.continuesWith(op, i): e = i + 2
      for op in sqlOps3:
        if s.continuesWith(op, i): e = i + 3
      add(skOp, e)

func sqlIs(t: SqlTok, k: SqlKind, text: string): bool = t.kind == k and t.text == text
func sqlIsKw(t: SqlTok, w: string): bool = t.kw and t.up == w
func sqlComment(t: SqlTok): bool = t.kind in {skComment, skLineComment}
func sqlOpen(t: SqlTok): bool = t.kind == skPunct and t.text in ["(", "["]

proc sqlMark(t: var seq[SqlTok]) =
  ## keywords (not a name next to a dot, nor a table's name after FROM, JOIN…), unary operators, the * of all columns
  var prev = -1                                  # the token before, comments skipped
  for k in 0 ..< t.len:
    if t[k].sqlComment: continue
    if t[k].kind == skWord:
      t[k].up = t[k].text.toUpperAscii
      t[k].kw = t[k].up in sqlKeywords and
        not (prev >= 0 and t[prev].sqlIs(skPunct, ".")) and
        not (k + 1 < t.len and t[k + 1].sqlIs(skPunct, ".")) and
        not (prev >= 0 and t[prev].kw and t[prev].up in sqlTableAfter and t[k].up notin sqlNotTable)
    elif t[k].kind == skOp and t[k].text in ["*", "-", "+", "~"]:
      let operandNext = prev < 0 or t[prev].kind == skOp and not t[prev].star or
        t[prev].kind == skPunct and t[prev].text in ["(", "[", ","] or
        t[prev].kw and t[prev].up notin ["END", "NULL", "TRUE", "FALSE"]
      if t[k].text == "*":
        t[k].star = operandNext and (prev < 0 or t[prev].kind == skPunct or
          t[prev].up in ["SELECT", "DISTINCT", "ALL", "RETURNING"]) or prev >= 0 and t[prev].sqlIs(skPunct, ".")
      else: t[k].unary = operandNext
    prev = k

func sqlOperand(t: SqlTok): bool =
  t.kind in {skWord, skNum, skStr, skIdent, skParam, skTempl} or t.star

proc sqlSep(t: seq[SqlTok], p, k: int): string =
  ## the space between t[p] and t[k] on a line: none inside ( ) and [ ], before , ; and around . ::, after a unary
  ## operator, between a function's name and its ( when the source had none; else one
  let a = t[p]
  let b = t[k]
  if b.sqlComment: return " "
  if b.kind == skPunct and b.text in [",", ";", ")", "]", "."] or a.sqlIs(skPunct, ".") or
      a.kind == skPunct and a.text in ["(", "["] or a.sqlIs(skOp, "::") or b.sqlIs(skOp, "::"):
    return ""
  if a.unary: return (if b.kind == skOp and not b.star: " " else: "")
  if b.sqlIs(skPunct, "["):
    return (if a.sqlOperand and not a.kw or a.kind == skPunct and a.text in [")", "]"]: "" else: " ")
  if b.sqlIs(skPunct, "(") and a.kind in {skWord, skIdent, skParam, skTempl} and (not a.kw or a.up in sqlFuncKw):
    return (if b.ws: " " else: "")
  " "

proc sqlText(f: SqlFmt, k: int): string =
  let t = f.t[k]
  if not t.kw: t.text
  elif f.upper: t.up
  else: t.up.toLowerAscii

proc sqlSub(f: SqlFmt, k: int): bool =
  ## the ( at k opens a sub-query
  if not f.t[k].sqlIs(skPunct, "("): return false
  var n = k + 1
  while n < f.mt[k] and f.t[n].sqlComment: inc n
  n < f.mt[k] and (f.t[n].sqlIsKw("SELECT") or f.t[n].sqlIsKw("WITH"))

proc sqlFlat(f: SqlFmt, a, b: int, ok: var bool): string =
  ## t[a ..< b] on one line (ok false when it cannot be: a comment or a sub-query in it)
  for k in a ..< b:
    if f.t[k].sqlComment or f.sqlSub(k): ok = false
    if k > a: result.add sqlSep(f.t, k - 1, k)
    result.add f.sqlText(k)

proc sqlFits(f: SqlFmt, a, b, L: int): bool =
  ## t[a ..< b] fits on one line at level L
  var ok = true
  let flat = f.sqlFlat(a, b, ok)
  ok and L * f.ind + strWidth(flat) <= sqlMaxW

proc sqlNl(f: var SqlFmt, lvl: int) =
  ## ends the line (when something is on it) and starts one at level lvl
  if not f.fresh: f.lines.add f.cur
  f.cur = spaces(lvl * f.ind)
  f.lvl = lvl
  f.fresh = true
  f.brk = false

proc sqlBlank(f: var SqlFmt) =
  if not f.fresh: f.sqlNl(f.lvl)
  if f.lines.len > 0 and f.lines[^1].len > 0: f.lines.add ""

proc sqlPut(f: var SqlFmt, k: int) =
  ## puts t[k] on the line: a comment that had a line of its own starts a line, a line comment ends one
  if f.brk or f.t[k].sqlComment and f.t[k].nl > 0 and not f.fresh: f.sqlNl(f.lvl)
  if not f.fresh: f.cur.add sqlSep(f.t, f.last, k)
  f.cur.add f.sqlText(k)
  f.fresh = false
  f.last = k
  f.brk = f.t[k].kind == skLineComment

proc sqlSplits(f: SqlFmt, a, b: int, words: openArray[string]): seq[int] =
  ## where the keywords `words` are in t[a ..< b], outside parentheses and nested CASEs (the AND of a BETWEEN skipped)
  var k = a
  var cases = 0
  var between = false
  while k < b:
    let t = f.t[k]
    if t.sqlOpen: k = f.mt[k]
    elif t.sqlIsKw("CASE"): inc cases
    elif t.sqlIsKw("END") and cases > 0: dec cases
    elif cases == 0 and t.kw:
      if t.up == "BETWEEN": between = true
      elif t.up == "AND" and between: between = false
      elif t.up in words: result.add k
    inc k

proc sqlItems(f: SqlFmt, a, b: int): seq[(int, int)] =
  ## the items of the comma list t[a ..< b], each with its comma and the comments after it on its line
  var s = a
  var k = a
  while k < b:
    if f.t[k].sqlOpen: k = f.mt[k]
    elif f.t[k].sqlIs(skPunct, ","):
      var e = k + 1
      while e < b and f.t[e].sqlComment and f.t[e].nl == 0: inc e
      result.add (s, e)
      s = e
      k = e
      continue
    inc k
  if s < b: result.add (s, b)

proc sqlCaseEnd(f: SqlFmt, k, b: int): int =
  ## the END of the CASE at k (-1 when there is none before b)
  var depth = 0
  var j = k
  while j < b:
    if f.t[j].sqlOpen: j = f.mt[j]
    elif f.t[j].sqlIsKw("CASE"): inc depth
    elif f.t[j].sqlIsKw("END"):
      dec depth
      if depth == 0: return j
    inc j
  -1

proc sqlQuery(f: var SqlFmt, a, b, L: int, cont: bool)

proc sqlInline(f: var SqlFmt, a, b: int)

proc sqlCase(f: var SqlFmt, k, e: int) =
  ## CASE … END: along the line when it fits, else each WHEN and the ELSE on a line one level in, END under them
  var ok = true
  let flat = f.sqlFlat(k, e + 1, ok)
  if ok and strWidth(f.cur) + 1 + strWidth(flat) <= sqlMaxW:
    for j in k .. e: f.sqlPut(j)
    return
  let base = f.lvl
  let cuts = f.sqlSplits(k + 1, e, ["WHEN", "ELSE"])
  f.sqlPut(k)
  f.sqlInline(k + 1, if cuts.len > 0: cuts[0] else: e)
  for i, c in cuts:
    f.sqlNl(base + 1)
    f.sqlInline(c, if i + 1 < cuts.len: cuts[i + 1] else: e)
  f.sqlNl(base)
  f.sqlPut(e)

proc sqlInline(f: var SqlFmt, a, b: int) =
  ## t[a ..< b] along the line, but a sub-query in parentheses on its own lines one level in, a long CASE broken
  var k = a
  while k < b:
    if f.sqlSub(k):
      let base = f.lvl
      f.sqlPut(k)
      f.sqlQuery(k + 1, f.mt[k], base + 1, false)
      f.sqlNl(base)
      f.sqlPut(f.mt[k])
      k = f.mt[k] + 1
    elif f.t[k].sqlIsKw("CASE") and (let e = f.sqlCaseEnd(k, b); e > 0):
      f.sqlCase(k, e)
      k = e + 1
    else:
      f.sqlPut(k)
      inc k

proc sqlCond(f: var SqlFmt, a, b, L: int) =
  ## a condition: each AND and OR (outside parentheses) starting a line one level in
  let cuts = f.sqlSplits(a, b, ["AND", "OR"])
  f.sqlInline(a, if cuts.len > 0: cuts[0] else: b)
  for i, c in cuts:
    f.sqlNl(L + 1)
    f.sqlInline(c, if i + 1 < cuts.len: cuts[i + 1] else: b)

proc sqlList(f: var SqlFmt, kw, a, b, L: int) =
  ## the comma list of a clause: on the clause's line when it fits (or has one item), else one item a line
  let items = f.sqlItems(a, b)
  if items.len <= 1 or f.sqlFits(kw, b, L): f.sqlInline(a, b)
  else:
    for (s, e) in items:
      f.sqlNl(L + 1)
      f.sqlInline(s, e)

proc sqlClause(f: var SqlFmt, name: string, kw, a, b, L: int) =
  ## the body t[a ..< b] of the clause `name` (its keywords at kw ..< a, on the line)
  case name
  of "SELECT":
    var m = a                                    # DISTINCT, DISTINCT ON (…), ALL: on SELECT's line
    if m < b and f.t[m].kw and f.t[m].up in ["DISTINCT", "ALL"]:
      inc m
      if m + 1 < b and f.t[m].sqlIsKw("ON") and f.t[m + 1].sqlIs(skPunct, "("): m = f.mt[m + 1] + 1
    f.sqlInline(a, m)
    f.sqlList(kw, m, b, L)
  of "FROM", "GROUP BY", "ORDER BY", "RETURNING", "SET", "VALUES": f.sqlList(kw, a, b, L)
  of "WHERE", "HAVING":
    if f.sqlFits(kw, b, L): f.sqlInline(a, b) else: f.sqlCond(a, b, L)
  of "JOIN":
    let on = f.sqlSplits(a, b, ["ON"])
    if on.len == 0 or f.sqlFits(kw, b, L): f.sqlInline(a, b)
    else:
      f.sqlInline(a, on[0] + 1)
      f.sqlCond(on[0] + 1, b, L)
  of "WITH":
    for i, (s, e) in f.sqlItems(a, b):
      if i > 0: f.sqlNl(L)
      f.sqlInline(s, e)
  else: f.sqlInline(a, b)

proc sqlStarter(f: SqlFmt, k, b: int, first: bool, prev: string): (int, string) =
  ## the clause keywords at t[k]: how many tokens, the clause's name ((0, "") when none)
  let t = f.t[k]
  if not t.kw: return (0, "")
  let next = if k + 1 < b and f.t[k + 1].kw: f.t[k + 1].up else: ""
  case t.up
  of "SELECT", "WHERE", "HAVING", "LIMIT", "OFFSET", "VALUES", "RETURNING", "INTERSECT": (1, t.up)
  of "FROM": (if k > 0 and f.t[k - 1].sqlIsKw("DISTINCT"): (0, "") else: (1, "FROM"))
  of "GROUP", "ORDER": (if next == "BY": (2, t.up & " BY") else: (0, ""))
  of "UNION", "EXCEPT": (if next in ["ALL", "DISTINCT"]: (2, t.up) else: (1, t.up))
  of "WITH": (if first: (1, "WITH") else: (0, ""))
  of "INSERT", "UPDATE": (if first or prev == "WITH": (1, t.up) else: (0, ""))
  of "DELETE":
    if (first or prev == "WITH") and next == "FROM": (2, "DELETE FROM")
    elif first: (1, "DELETE")
    else: (0, "")
  of "SET": (if first or prev in ["UPDATE", "ON CONFLICT"]: (1, "SET") else: (0, ""))
  of "ON": (if next == "CONFLICT": (2, "ON CONFLICT") else: (0, ""))
  of "JOIN", "NATURAL", "LEFT", "RIGHT", "FULL", "INNER", "OUTER", "CROSS":
    var j = k
    while j < b and f.t[j].kw and f.t[j].up in sqlJoinWords: inc j
    if j < b and f.t[j].sqlIsKw("JOIN"): (j - k + 1, "JOIN") else: (0, "")
  else: (0, "")

proc sqlQuery(f: var SqlFmt, a, b, L: int, cont: bool) =
  ## the query (or any statement) t[a ..< b] at level L: each clause starting a line (the first one goes on the
  ## current line when cont); comments on their own lines just before a clause go with it
  var cs = @[(s: a, kw: a, body: a, name: "")]
  var first = a
  while first < b and f.t[first].sqlComment: inc first
  var k = a
  while k < b:
    if f.t[k].sqlOpen:
      k = f.mt[k] + 1
      continue
    let (n, name) = f.sqlStarter(k, b, k == first, cs[^1].name)
    if n == 0:
      inc k
      continue
    var s = k
    while s > cs[^1].body and f.t[s - 1].sqlComment: dec s
    while s < k and f.t[s].nl == 0: inc s
    cs.add (s: s, kw: k, body: k + n, name: name)
    k += n
  for i, c in cs:
    let e = if i + 1 < cs.len: cs[i + 1].s else: b
    if e <= c.s: continue
    if not (cont and i == 0): f.sqlNl(L)
    for j in c.s ..< c.body: f.sqlPut(j)
    f.sqlClause(c.name, c.kw, c.body, e, L)

proc sqlCreateTable(f: var SqlFmt, a, b: int): bool =
  ## CREATE TABLE name (…): one column or constraint a line, `)` on a line of its own
  if not f.t[a].sqlIsKw("CREATE"): return false
  var k = a
  var table = false
  while k < b and not f.t[k].sqlIs(skPunct, "("):
    if f.t[k].sqlIsKw("TABLE"): table = true
    if f.t[k].sqlIsKw("AS") or f.t[k].sqlIsKw("SELECT") or f.t[k].sqlOpen: return false
    inc k
  if not table or k >= b or f.sqlSub(k): return false
  f.sqlNl(0)
  f.sqlInline(a, k + 1)
  for (s, e) in f.sqlItems(k + 1, f.mt[k]):
    f.sqlNl(1)
    f.sqlInline(s, e)
  f.sqlNl(0)
  f.sqlPut(f.mt[k])
  f.sqlQuery(f.mt[k] + 1, b, 0, true)
  true

proc sqlMatch(f: var SqlFmt, err: var string) =
  ## the matching ( ) and [ ]
  f.mt = newSeq[int](f.t.len)
  var open: seq[int]
  for k, t in f.t:
    f.mt[k] = -1
    if t.sqlOpen: open.add k
    elif t.kind == skPunct and t.text in [")", "]"]:
      if open.len == 0 or f.t[open[^1]].text != (if t.text == ")": "(" else: "["):
        var line = 1
        for j in 0 .. k: line += f.t[j].nl + f.t[j].text.count('\n')
        err = "the parentheses do not match (line " & $line & ")"
        return
      f.mt[k] = open.pop
      f.mt[f.mt[k]] = k
  if open.len > 0: err = "a parenthesis is not closed"

proc sqlSig(t: seq[SqlTok]): seq[string] =
  ## what must not change: every token, a keyword in any case
  for x in t: result.add $x.kind & " " & (if x.kw: x.up else: x.text)

proc fmtSql*(s: string, indent = 2, upper = true): (string, string) =
  ## (formatted text, error): each statement's clauses on lines of their own, long lists one item a line, long
  ## conditions one AND / OR a line, sub-queries indented, CREATE TABLE one column a line; keywords in upper (or
  ## lower) case; names, strings, comments, placeholders and templates as written
  let src = s.replace("\r\n", "\n")
  var err = ""
  var f = SqlFmt(t: sqlToks(src, err), ind: max(1, indent), upper: upper, fresh: true)
  if err.len > 0: return (s, err)
  sqlMark(f.t)
  f.sqlMatch(err)
  if err.len > 0: return (s, err)
  var k = 0
  var n = 0
  while k < f.t.len:
    var e = k                                    # the statement: t[k ..< e], its ; at e
    while e < f.t.len and not f.t[e].sqlIs(skPunct, ";"):
      if f.t[e].sqlOpen: e = f.mt[e]
      inc e
    if n > 0 and f.t[k].nl >= 2: f.sqlBlank()
    var a = k
    while a < e and f.t[a].sqlComment:           # the comments before it: on their own lines
      if a > k and f.t[a].nl >= 2: f.sqlBlank()
      if a == k or f.t[a].nl > 0: f.sqlNl(0)
      f.sqlPut(a)
      inc a
    if a < e:
      if a > k and f.t[a].nl >= 2: f.sqlBlank()
      if not f.sqlCreateTable(a, e): f.sqlQuery(a, e, 0, false)
    k = e
    if e < f.t.len:
      if a == e: f.sqlNl(0)
      f.sqlPut(e)
      k = e + 1
      while k < f.t.len and f.t[k].sqlComment and f.t[k].nl == 0:   # comments after it on its line
        f.sqlPut(k)
        inc k
    inc n
  f.sqlNl(0)
  let res = f.lines.join("\n") & "\n"
  # safety: the same tokens (keywords in any case)
  var err2 = ""
  var t2 = sqlToks(res, err2)
  sqlMark(t2)
  if err2.len > 0 or sqlSig(t2) != sqlSig(f.t): return (s, sqlChanged)
  (res, "")
