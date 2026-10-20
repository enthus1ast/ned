## ── ned's own SQL: the tables and columns your project creates (CREATE TABLE in .sql files and in the SQL of Nim
##    strings), completion of tables after FROM / JOIN / INTO / UPDATE and of columns after `t.` (through aliases),
##    what a table, column or function is, and two mistakes: a table or column no CREATE TABLE makes, and a query
##    given more or fewer values than it has `?` (db_connector's exec, getRow, getAllRows …) ──

import std/[strutils, sets, tables, os]
import webdata, webcommon

type
  SqlCol* = object
    name*, typ*: string
  SqlTable* = object
    name*: string              # as written
    cols*: seq[SqlCol]
    path*: string              # where it is created
    line*: int
    view*: bool
  SqlSchema* = object
    tables*: Table[string, SqlTable]     # lower-case name → its table
  SqlTokenKind* = enum stWord, stQuoted, stString, stNumber, stPunct, stPlaceholder, stComment
  SqlToken* = object
    kind*: SqlTokenKind
    text*: string
    line*, col*: int

const
  TableKeywords = ["from", "join", "into", "update", "table", "exists"]
  NotTables = ["select", "where", "set", "values", "lateral", "only", "unnest", "json_each", "json_tree",
               "generate_series", "dual", "pragma_table_info"]

func lowerWord(s: string): string = s.toLowerAscii

proc sqlTokens*(lines: openArray[string], fromLine = 0, toLine = int.high, upto = (int.high, 0)): seq[SqlToken] =
  ## the SQL's tokens (comments kept as one), lines from..to, up to a place
  var inBlock = false
  for l in max(0, fromLine) .. min(toLine, lines.high):
    let s = lines[l]
    var i = 0
    let stop = if l == upto[0]: min(upto[1], s.len) elif l > upto[0]: 0 else: s.len
    while i < stop:
      let c = s[i]
      if inBlock:
        let e = s.find("*/", i)
        if e < 0: break
        inBlock = false
        i = e + 2
        continue
      if c in {' ', '\t', '\r'}:
        inc i
        continue
      if c == '-' and i + 1 < s.len and s[i + 1] == '-':
        result.add SqlToken(kind: stComment, text: s[i .. ^1], line: l, col: i)
        break
      if c == '/' and i + 1 < s.len and s[i + 1] == '*':
        inBlock = true
        i += 2
        continue
      if c in {'\'', '"', '`', '['}:
        let q = if c == '[': ']' else: c
        var e = i + 1
        while e < s.len and s[e] != q:
          if s[e] == '\\' and c != '[': inc e
          inc e
        result.add SqlToken(kind: (if c == '\'': stString else: stQuoted), text: s[i .. min(e, s.high)], line: l, col: i)
        i = e + 1
        continue
      if c in {'a'..'z', 'A'..'Z', '_'} or ord(c) >= 0x80:
        var e = i
        while e < s.len and (s[e] in {'a'..'z', 'A'..'Z', '0'..'9', '_', '$'} or ord(s[e]) >= 0x80): inc e
        result.add SqlToken(kind: stWord, text: s[i ..< e], line: l, col: i)
        i = e
        continue
      if c in Digits:
        var e = i
        while e < s.len and s[e] in {'0'..'9', '.', 'e', 'E', 'x', 'X', 'a'..'f', 'A'..'F'}: inc e
        result.add SqlToken(kind: stNumber, text: s[i ..< e], line: l, col: i)
        i = e
        continue
      if c == '?' or (c in {'$', ':', '@'} and i + 1 < s.len and s[i + 1] in {'0'..'9', 'a'..'z', 'A'..'Z', '_'} and
                      not (c == ':' and i > 0 and s[i - 1] == ':')):
        var e = i + 1
        while e < s.len and s[e] in {'0'..'9', 'a'..'z', 'A'..'Z', '_'}: inc e
        if c == ':' and e < s.len and s[e] == ':':          # (a cast x::int: punctuation)
          result.add SqlToken(kind: stPunct, text: ":", line: l, col: i)
          inc i
          continue
        result.add SqlToken(kind: stPlaceholder, text: s[i ..< e], line: l, col: i)
        i = e
        continue
      result.add SqlToken(kind: stPunct, text: $c, line: l, col: i)
      inc i

func unquote(s: string): string =
  if s.len >= 2 and s[0] in {'"', '`', '['}: s[1 ..< s.high] else: s

proc addCreates*(sc: var SqlSchema, lines: openArray[string], path: string) =
  ## the tables (and views) a text creates or alters
  let ts = sqlTokens(lines)
  var i = 0
  template w(k: int): string = (if k < ts.len and ts[k].kind in {stWord, stQuoted}: ts[k].text.lowerWord else: "")
  while i < ts.len:
    if w(i) == "create":
      var k = i + 1
      while w(k) in ["temp", "temporary", "unlogged", "virtual", "or", "replace", "materialized"]: inc k
      let what = w(k)
      if what notin ["table", "view"]:
        inc i
        continue
      inc k
      if w(k) == "if" and w(k + 1) == "not" and w(k + 2) == "exists": k += 3
      if k >= ts.len or ts[k].kind notin {stWord, stQuoted}:
        inc i
        continue
      var name = ts[k].text.unquote
      let at = ts[k]
      if k + 2 < ts.len and ts[k + 1].text == "." and ts[k + 2].kind in {stWord, stQuoted}:
        name = ts[k + 2].text.unquote                      # (main.users: users)
        k += 2
      var t = SqlTable(name: name, path: path, line: at.line, view: what == "view")
      inc k
      if w(k) == "using":                                   # CREATE VIRTUAL TABLE x USING fts5(a, b)
        k += 2
      if k < ts.len and ts[k].text == "(" and what == "table":
        # the columns: each `name type …` at depth 1, but not a constraint
        var depth = 1
        var startItem = true
        inc k
        while k < ts.len and depth > 0:
          let x = ts[k]
          if x.text == "(": inc depth
          elif x.text == ")": dec depth
          elif x.text == "," and depth == 1: startItem = true
          elif startItem and depth == 1 and x.kind in {stWord, stQuoted}:
            startItem = false
            let lw = x.text.lowerWord
            if x.kind == stQuoted or lw notin ["primary", "foreign", "unique", "check", "constraint", "key", "index",
                                               "exclude", "like", "period"]:
              var typ = ""
              var m = k + 1
              while m < ts.len and ts[m].kind == stWord and ts[m].text.lowerWord notin ["not", "null", "primary",
                    "references", "default", "unique", "check", "collate", "generated", "constraint", "auto_increment",
                    "autoincrement"]:
                typ.add (if typ.len > 0: " " else: "") & ts[m].text
                inc m
              if m < ts.len and ts[m].text == "(" and typ.len > 0:      # varchar(255)
                var e = m
                while e < ts.len and ts[e].text != ")": inc e
                var inner = ""
                for z in m + 1 ..< e: inner.add ts[z].text
                typ.add "(" & inner & ")"
              t.cols.add SqlCol(name: x.text.unquote, typ: typ)
          inc k
      let key = name.lowerWord
      if key notin sc.tables or sc.tables[key].cols.len == 0: sc.tables[key] = t
      i = k
      continue
    if w(i) == "alter" and w(i + 1) == "table":
      var k = i + 2
      if w(k) == "if" and w(k + 1) == "exists": k += 2
      let key = w(k).unquote
      if key in sc.tables and w(k + 1) == "add":
        var m = k + 2
        if w(m) == "column": inc m
        if w(m) == "if" and w(m + 1) == "not": m += 3
        if m < ts.len and ts[m].kind in {stWord, stQuoted}:
          let typ = if m + 1 < ts.len and ts[m + 1].kind == stWord: ts[m + 1].text else: ""
          sc.tables[key].cols.add SqlCol(name: ts[m].text.unquote, typ: typ)
      i = k
      continue
    inc i

type SqlStmt = object
  toks: seq[SqlToken]
  aliases: Table[string, string]        # alias (lower case) → table (lower case)
  tables: seq[string]                   # the tables it names (lower case)
  ctes: HashSet[string]                 # WITH x AS (…): x

proc stmtAround(lines: openArray[string], line, col: int, all = false): SqlStmt =
  ## the statement the place is in (from the `;` before it), up to the place (all: to its end)
  var ts = sqlTokens(lines, max(0, line - 200), (if all: lines.high else: line), (if all: (int.high, 0) else: (line, col)))
  var a = 0
  for k in countdown(ts.high, 0):
    if ts[k].text == ";" and posLess(ts[k].line, ts[k].col, line, col):     # (the `;` before the place)
      a = k + 1
      break
  result.toks = ts[a .. ^1]
  if all:
    # to the statement's end
    var e = result.toks.len
    for k, t in result.toks:
      if t.text == ";" and (t.line > line or (t.line == line and t.col >= col)):
        e = k
        break
    result.toks.setLen(e)

proc readNames(st: var SqlStmt) =
  let ts = st.toks
  template w(k: int): string = (if k >= 0 and k < ts.len and ts[k].kind in {stWord, stQuoted}: ts[k].text.unquote.lowerWord else: "")
  for k in 0 ..< ts.len:
    if w(k) == "as" and k > 0 and ts[k - 1].kind in {stWord, stQuoted} and k + 1 < ts.len and ts[k + 1].text == "(":
      st.ctes.incl w(k - 1)
  for k in 0 ..< ts.len:
    let kw = w(k)
    if kw notin TableKeywords: continue
    if kw == "exists" and not (w(k - 1) == "not" and w(k - 2) == "if"): continue
    var m = k + 1
    while m < ts.len:
      if ts[m].kind notin {stWord, stQuoted}: break
      var name = w(m)
      if name in NotTables or name in ["if", "not", "exists", "only"]: break
      if m + 2 < ts.len and ts[m + 1].text == "." and ts[m + 2].kind in {stWord, stQuoted}:
        name = w(m + 2)
        m += 2
      st.tables.add name
      # an alias: `users u`, `users AS u`
      var n = m + 1
      if w(n) == "as": inc n
      let al = w(n)
      if al.len > 0 and n < ts.len and ts[n].kind in {stWord, stQuoted} and
         al notin ["on", "where", "join", "left", "right", "inner", "outer", "full", "cross", "natural", "using", "set",
                   "group", "order", "limit", "values", "select", "union", "returning", "having", "window", "default",
                   "natural", "lateral", "offset", "fetch", "for", "except", "intersect"]:
        st.aliases[al] = name
        m = n
      # FROM a, b: the next one
      if m + 1 < ts.len and ts[m + 1].text == "," and kw == "from":
        m += 2
        continue
      break

proc sqlComplete*(lines: openArray[string], line, col: int, sc: SqlSchema): (int, seq[WebItem]) =
  ## what fits at (line, col): (where the word starts, the items)
  let s = lines[line]
  let c = min(col, s.len)
  var a = c
  while a > 0 and s[a - 1] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}: dec a
  result[0] = a
  let typed = s[a ..< c]
  let lower = typed.len > 0 and typed == typed.toLowerAscii
  var st = stmtAround(lines, line, a)
  readNames(st)
  var full = stmtAround(lines, line, a, all = true)
  readNames(full)
  for k, v in full.aliases: st.aliases[k] = v
  for t in full.tables:
    if t notin st.tables: st.tables.add t
  for x in full.ctes: st.ctes.incl x
  let ts = st.toks
  # in a string or a comment: nothing
  if ts.len > 0:
    let t = ts[^1]
    if t.kind == stComment and t.line == line: return
    if t.kind == stString and t.line == line and t.col < a and
       (t.col + t.text.len > a or t.text.len == 1 or t.text[^1] != '\''):
      return
  var items: seq[WebItem]
  proc colItems(items: var seq[WebItem], t: SqlTable, rank: int) =
    for cl in t.cols:
      items.add WebItem(label: cl.name, insert: cl.name, detail: t.name & (if cl.typ.len > 0: " · " & cl.typ else: ""),
                        kind: KField, rank: rank)
  # t.col
  if a > 0 and s[a - 1] == '.':
    var b0 = a - 1
    while b0 > 0 and s[b0 - 1] in {'a'..'z', 'A'..'Z', '0'..'9', '_', '"', '`'}: dec b0
    let q = s[b0 ..< a - 1].unquote.lowerWord
    let tn = st.aliases.getOrDefault(q, q)
    if tn in sc.tables: items.colItems(sc.tables[tn], 0)
    result[1] = items
    return
  # after FROM / JOIN / INTO / UPDATE / TABLE: tables
  var prevKw = ""
  for k in countdown(ts.high, 0):
    if ts[k].line == line and ts[k].col >= a: continue
    if ts[k].kind == stWord:
      prevKw = ts[k].text.lowerWord
      break
    if ts[k].kind == stComment: continue
    break
  if prevKw in ["from", "join", "into", "update", "table"]:
    for k, t in sc.tables:
      var cs: seq[string]
      for cl in t.cols: cs.add cl.name & (if cl.typ.len > 0: " " & cl.typ else: "")
      items.add WebItem(label: t.name, insert: t.name, detail: (if t.view: "view" else: "table") & " · " & $t.cols.len &
                        " columns", kind: KStruct, rank: 0, doc: "```sql\n" & t.name & "(" & cs.join(", ") & ")\n```")
    for x in st.ctes: items.add WebItem(label: x, insert: x, detail: "WITH", kind: KStruct, rank: 0)
    result[1] = items
    return
  # anywhere else: the columns of the tables it names, the functions, the keywords
  for tn in st.tables:
    if tn in sc.tables: items.colItems(sc.tables[tn], 0)
  for al, tn in st.aliases:
    items.add WebItem(label: al, insert: al, detail: "alias of " & tn, kind: KVariable, rank: 1)
  for f in SqlFunctions:
    items.add WebItem(label: f[0], insert: (if lower: f[0] else: f[0].toUpperAscii) & "(",
                      snippet: (if lower: f[0] else: f[0].toUpperAscii) & "($1)$0", detail: f[1] &
                      (if f[2] != "all": "  · " & f[2] else: ""), doc: f[3], kind: KFunction, rank: 2)
  for kw in SqlKeywords:
    let x = if lower: kw.toLowerAscii else: kw
    items.add WebItem(label: x, insert: x, detail: "keyword", kind: KKeyword, rank: 3)
  for k, t in sc.tables:
    items.add WebItem(label: t.name, insert: t.name, detail: "table", kind: KStruct, rank: 3)
  result[1] = items

proc sqlHover*(lines: openArray[string], line, col: int, sc: SqlSchema): string =
  ## what the name at (line, col) is: a table, a column, a function
  let s = lines[line]
  var a = min(col, s.len)
  var e = a
  while a > 0 and s[a - 1] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}: dec a
  while e < s.len and s[e] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}: inc e
  if a >= e: return
  let w = s[a ..< e]
  let lw = w.lowerWord
  var st = stmtAround(lines, line, a, all = true)
  readNames(st)
  proc tableDoc(t: SqlTable): string =
    result = "**" & t.name & "** — " & (if t.view: "view" else: "table") &
             (if t.path.len > 0: " (" & t.path.splitPath.tail & ":" & $(t.line + 1) & ")" else: "") & "\n```sql\n"
    for cl in t.cols: result.add cl.name & (if cl.typ.len > 0: "  " & cl.typ else: "") & "\n"
    result.add "```"
  # t.col
  if a >= 2 and s[a - 1] == '.':
    var b0 = a - 1
    while b0 > 0 and s[b0 - 1] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}: dec b0
    let q = s[b0 ..< a - 1].lowerWord
    let tn = st.aliases.getOrDefault(q, q)
    if tn in sc.tables:
      for cl in sc.tables[tn].cols:
        if cl.name.lowerWord == lw:
          return "**" & sc.tables[tn].name & "." & cl.name & "** — column" & (if cl.typ.len > 0: " · " & cl.typ else: "")
  if e < s.len and s[e] == '(':
    let i = sqlFunction(lw)
    if i >= 0:
      let f = SqlFunctions[i]
      return "**" & f[0] & f[1] & "** — SQL function" & (if f[2] != "all": " (" & f[2] & ")" else: "") & "\n\n" & f[3]
  if lw in st.aliases and st.aliases[lw] in sc.tables:
    return "**" & w & "** — alias of " & tableDoc(sc.tables[st.aliases[lw]])[2 .. ^1]
  if lw in sc.tables: return tableDoc(sc.tables[lw])
  for tn in st.tables:
    if tn in sc.tables:
      for cl in sc.tables[tn].cols:
        if cl.name.lowerWord == lw:
          return "**" & sc.tables[tn].name & "." & cl.name & "** — column" & (if cl.typ.len > 0: " · " & cl.typ else: "")

proc sqlChecks*(lines: openArray[string], sc: SqlSchema): seq[WebDiag] =
  ## a table no CREATE TABLE of the project makes, a column its table does not have (`t.col`) — only when the
  ## project creates some tables (else nothing is known to compare with)
  if sc.tables.len == 0: return
  let ts = sqlTokens(lines)
  var a = 0
  while a < ts.len:
    var e = a
    while e < ts.len and ts[e].text != ";": inc e
    var st = SqlStmt(toks: ts[a ..< e])
    readNames(st)
    var isCreate = false
    for t in st.toks:
      if t.kind == stWord:
        isCreate = t.text.lowerWord in ["create", "drop", "alter", "pragma", "attach", "detach"]
        break
    if not isCreate:
      let tks = st.toks
      for k in 0 ..< tks.len:
        let kw = if tks[k].kind == stWord: tks[k].text.lowerWord else: ""
        if kw notin ["from", "join", "into", "update"] or k + 1 >= tks.len: continue
        let t = tks[k + 1]
        if t.kind notin {stWord, stQuoted}: continue
        if k + 2 < tks.len and tks[k + 2].text == ".": continue       # schema.table: another database's
        let n = t.text.unquote.lowerWord
        if n in NotTables or n in st.ctes or n in sc.tables or n.startsWith("sqlite_") or n.startsWith("pg_") or
           n == "information_schema" or n in ["if", "not", "only"]:
          continue
        var names: seq[string]
        for _, x in sc.tables: names.add x.name
        let near = closest(n, names)
        result.add WebDiag(line: t.line, col: t.col, eline: t.line, ecol: t.col + t.text.len, sev: 2, rule: "sql-table",
                           msg: "no table '" & t.text.unquote & "' is created in this project" &
                           (if near.len > 0: " — did you mean '" & near & "'?" else: ""))
      # alias.column
      for k in 0 ..< tks.len - 2:
        if tks[k].kind notin {stWord, stQuoted} or tks[k + 1].text != "." or tks[k + 2].kind notin {stWord, stQuoted}:
          continue
        if tks[k + 1].col != tks[k].col + tks[k].text.len or tks[k + 2].col != tks[k + 1].col + 1 or
           tks[k + 2].line != tks[k].line:
          continue
        let q = tks[k].text.unquote.lowerWord
        let tn = st.aliases.getOrDefault(q, (if q in st.tables: q else: ""))
        if tn.len == 0 or tn notin sc.tables or sc.tables[tn].cols.len == 0: continue
        let cn = tks[k + 2].text.unquote
        var found = false
        var names: seq[string]
        for cl in sc.tables[tn].cols:
          names.add cl.name
          if cl.name.lowerWord == cn.lowerWord: found = true
        if not found and cn != "*" and cn.lowerWord notin ["rowid", "oid", "_rowid_", "ctid"]:
          let near = closest(cn, names)
          let x = tks[k + 2]
          result.add WebDiag(line: x.line, col: x.col, eline: x.line, ecol: x.col + x.text.len, sev: 2,
                             rule: "sql-column", msg: "table '" & sc.tables[tn].name & "' has no column '" & cn & "'" &
                             (if near.len > 0: " — did you mean '" & near & "'?" else: ""))
    a = e + 1
  sortDiags(result)

# ── the values a query is given: db_connector's procs take the query, then one value for each `?` ──

const DbProcs = ["exec", "tryExec", "execAffectedRows", "getRow", "getAllRows", "getValue", "tryInsertID", "insertID",
                 "tryInsert", "insert", "rows", "fastRows", "instantRows", "getAllRowsAsync", "execAsync"]

func placeholders(sqlText: string): int =
  ## the `?` of a query, outside its strings and comments
  var i = 0
  var q = '\0'
  while i < sqlText.len:
    let c = sqlText[i]
    if q != '\0':
      if c == q: q = '\0'
    elif c in {'\'', '"', '`'}: q = c
    elif c == '-' and i + 1 < sqlText.len and sqlText[i + 1] == '-':
      let e = sqlText.find('\n', i)
      if e < 0: break
      i = e
    elif c == '?': inc result
    inc i

proc nimCodeOnly(lines: openArray[string]): seq[string] =
  ## Nim lines with their comments blanked (`#`, `##`, `#[ … ]#`), strings kept — the calls a doc comment shows as
  ## an example are not calls
  var triple = false
  var blockDepth = 0
  for s0 in lines:
    var s = s0
    var i = 0
    var q = false
    while i < s.len:
      if blockDepth > 0:
        if s.continuesWith("]#", i):
          dec blockDepth
          s[i] = ' '
          s[i + 1] = ' '
          i += 2
          continue
        if s.continuesWith("#[", i): inc blockDepth
        s[i] = ' '
        inc i
        continue
      if triple:
        if s.continuesWith("\"\"\"", i):
          triple = false
          i += 3
          continue
        inc i
        continue
      let c = s[i]
      if q:
        if c == '\\': inc i
        elif c == '"': q = false
      elif s.continuesWith("\"\"\"", i):
        triple = true
        i += 3
        continue
      elif c == '"': q = true
      elif c == '\'' and i + 2 < s.len and (s[i + 2] == '\'' or s[i + 1] == '\\'):
        i += (if s[i + 1] == '\\': 4 else: 3)
        continue
      elif c == '#':
        if s.continuesWith("#[", i) or s.continuesWith("##[", i):
          inc blockDepth
          for k in i ..< min(s.len, i + 3): s[k] = ' '
          i += 2
          continue
        for k in i ..< s.len: s[k] = ' '
        break
      inc i
    result.add s

proc sqlArgChecks*(lines: openArray[string]): seq[WebDiag] =
  ## `db.exec(sql"INSERT … VALUES (?, ?)", a, b, c)`: three values for two `?` — on the call's line
  let (text, starts) = joinLines(nimCodeOnly(lines))
  for p in DbProcs:
    var i = text.find(p & "(")
    while i >= 0:
      let ok = (i == 0 or text[i - 1] in {'.', ' ', '\t', '('}) and
               not (i > 0 and text[i - 1] in {'a'..'z', 'A'..'Z', '0'..'9', '_'})
      var j = i + p.len + 1
      if ok:
        # (the receiver, when called as db.exec(…): its first argument is the connection — skip it)
        var k = j
        while k < text.len and text[k] in {' ', '\t', '\n'}: inc k
        var args: seq[(int, int)]                 # each argument's span
        var depth = 0
        var a0 = k
        var q = '\0'
        var triple = false
        var m = k
        var closed = false
        while m < text.len:
          let c = text[m]
          if q != '\0':
            if triple:
              if text.continuesWith("\"\"\"", m):
                q = '\0'
                triple = false
                m += 3
                continue
            elif c == '\\' and q == '"': inc m
            elif c == q: q = '\0'
            elif c == '\n' and not triple: q = '\0'
          elif c == '"':
            if text.continuesWith("\"\"\"", m):
              q = '"'
              triple = true
              m += 3
              continue
            q = '"'
          elif c == '\'' and m + 2 < text.len and (text[m + 2] == '\'' or text[m + 1] == '\\'): q = '\''
          elif c in {'(', '[', '{'}: inc depth
          elif c in {')', ']', '}'}:
            if depth == 0:
              args.add (a0, m)
              closed = true
              break
            dec depth
          elif c == ',' and depth == 0:
            args.add (a0, m)
            a0 = m + 1
          elif c == '#' and depth >= 0:
            let e = text.find('\n', m)
            if e < 0: break
            m = e
            continue
          inc m
        if closed:
          # the query: the first argument that is a sql"…" / sql("…") / string literal; the values after it
          var qi = -1
          var qtext = ""
          for n, (x, y) in args:
            let t = text[x ..< y].strip
            var lit = t
            var tagged = false                   # sql"…": a query for sure; a plain string only when it reads as one
            if lit.startsWith("sql(") and lit.endsWith(")"):
              lit = lit[4 ..< ^1].strip
              tagged = true
            elif lit.startsWith("sql\""):
              lit = lit[3 .. ^1]
              tagged = true
            var body = ""
            if lit.startsWith("\"\"\"") and lit.endsWith("\"\"\"") and lit.len >= 6: body = lit[3 ..< ^3]
            elif (lit.startsWith("r\"") or lit.startsWith("\"")) and lit.endsWith("\"") and lit.len >= 2 and
                 '&' notin lit:
              body = lit[(if lit[0] == 'r': 2 else: 1) ..< ^1]
            else: continue
            let head = body.strip.toLowerAscii
            if tagged or head.startsWith("select ") or head.startsWith("insert ") or head.startsWith("update ") or
               head.startsWith("delete ") or head.startsWith("replace ") or head.startsWith("with "):
              qi = n
              qtext = body
            break
          if qi >= 0 and '{' notin qtext and "%" notin qtext:
            let want = placeholders(qtext)
            var vals = args.len - qi - 1
            if vals == 1 and text[args[qi + 1][0] ..< args[qi + 1][1]].strip.len == 0: vals = 0
            var listy = false                    # an argument that may be a whole list of values (varargs)
            for n in qi + 1 ..< args.len:
              let t = text[args[n][0] ..< args[n][1]].strip
              if t.startsWith("@[") or t.startsWith("[") or t.endsWith("]") or t.startsWith("toSeq") or
                 (t.len > 0 and t.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '_', '.'}) and not t[0].isDigit and
                  t notin ["true", "false", "nil"]):
                listy = true
            if (vals > want) or (vals < want and not listy and want > 0) or (want == 0 and vals > 0 and not listy):
              let (l, c) = lineCol(starts, i)
              result.add WebDiag(line: l, col: c, eline: l, ecol: c + p.len, sev: (if vals > want: 1 else: 2),
                                 rule: "sql-args", msg: p & ": " & $vals & " value" & (if vals == 1: "" else: "s") &
                                 " for the query's " & $want & " '?'")
      i = text.find(p & "(", j)
  sortDiags(result)
