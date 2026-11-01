## db-client — SQL run on PostgreSQL or MySQL/MariaDB with their own programs (psql, mysql); the rows in a tab
##
##   DB: run the statement at the cursor   (Ctrl+Enter in .sql files; vim <leader>r there) — the statement the cursor
##                                         is in, or the selection (in any file): each of its statements in turn, in
##                                         one session
##   DB: run the whole file                every statement of the file, in turn
##   DB: choose a connection…              one of plugins.db-client.connections, kept for the project (with one
##                                         connection there is nothing to choose)
##   DB: cancel the query
##   the result    a tab "DB: <connection>": each statement's line and first words, then its rows as a table (numbers
##                 on the right, NULL, ↵ for a line end inside a value) or what it did (INSERT 0 2, 3 rows affected).
##                 With format csv, each result is a tab of its own in CSV ("DB: dev.csv")
##   an error      in the tab, in the status line, and at its line (and column, when the server says) in the file:
##                 the Problems panel
##   settings      plugins.db-client.connections — the list, in your settings file:
##                   [{"name": "dev", "url": "postgres://ann@localhost:5432/app"},
##                    {"name": "shop", "url": "mysql://ann@127.0.0.1:3306/shop"}]
##                 (postgres:// or postgresql://, mysql:// or mariadb://; postgres takes ?sslmode=… and the rest of
##                 libpq's; mysql takes ?socket=/path and ?ssl-mode=…) — it may also be that list written as a string
##                 plugins.db-client.format (table or csv) · .maxRows (500: the rows a table shows) · .psql · .mysql
##                 (the programs: a path, or mariadb)
##
## Passwords are never written into ned's settings: a password in a url is left out (and you are told so). psql
## finds yours in PGPASSWORD or ~/.pgpass (host:port:database:user:password, chmod 600), mysql in MYSQL_PWD or
## ~/.my.cnf ([client] then password=…) — set the variables before ned starts. It needs psql 12 or newer (for its CSV)
## or MySQL's or MariaDB's mysql; on Termux: pkg install postgresql, pkg install mariadb.
##
## The statements are split as the clients do: not at a ; in a string, a quoted name, a comment, PostgreSQL's $$…$$
## or MySQL's `…` — and in MySQL files at the delimiter a DELIMITER line sets (for procedures).
import nedplugin

requiresNed(">= 6.29")
pluginInfo(version = "1.0.0", author = "Sultan Al Isaiee (@foxoman)", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")
permission("shell", "runs psql or mysql with the SQL you choose to run")

settingDef("connections", "", "DB: the connections — a list of {\"name\": …, \"url\": " &
           "\"postgres://user@host:5432/db\" or \"mysql://user@host:3306/db\"}; no password in it (PGPASSWORD, " &
           "~/.pgpass, MYSQL_PWD, ~/.my.cnf)")
settingDef("format", "table", "DB: the rows as an aligned table (table) or CSV, a tab for each result (csv)")
settingDef("maxRows", 500, "DB: how many rows a table shows (the client still reads them all)")
settingDef("psql", "psql", "DB: the psql program (its name on PATH, or its path)")
settingDef("mysql", "mysql", "DB: the mysql program (its name on PATH, its path, or mariadb)")

const
  Mark = "\x1e"                  # (the start of the line that says which statement's output follows)
  MyDelim = "$$ned$$"            # (the delimiter of the script mysql reads: never in your SQL outside a string)

type
  Conn = object
    name, kind: string          # kind: postgres or mysql ("": not a connection — why says why)
    user, host, port, db: string
    params: seq[(string, string)]
    password: bool              # the url had one: it is not used
    url: string                 # the url without its password
    why: string
  Stmt = object
    text: string
    line, col: int              # where it starts in the file
    stopLine, stopCol: int      # just after it (and its ;)
  Res = object
    columns: seq[string]
    rows: seq[seq[string]]
    hasRows: bool               # a result set (perhaps of no rows)
    tag: string                 # what it did: INSERT 0 2, 3 rows affected
    error: string
    errLine, errCol: int        # where in the file (-1: not known)
    notes: seq[string]          # NOTICE … from the server
    ran: bool                   # (false: an error before it stopped the rest)

# ── connections ──

func unpercent(s: string): string =
  ## s with its %XX escapes (as in a url) turned back into the characters they stand for
  var i = 0
  while i < s.len:
    if s[i] == '%' and i + 2 < s.len and s[i + 1] in HexDigits and s[i + 2] in HexDigits:
      result.add char(parseHexInt(s[i + 1 .. i + 2]))
      i += 3
    else:
      result.add s[i]
      inc i

func parseConn(name, url: string): Conn =
  ## a connection's url: postgres[ql]://user[:password]@host[:port]/database?k=v…, mysql:// (mariadb://) the same
  result = Conn(name: name)
  let s = url.strip
  let k = s.find("://")
  if k < 0:
    result.why = name & ": not a url — postgres://user@host:5432/database or mysql://user@host:3306/database"
    return
  let scheme = s[0 ..< k].toLowerAscii
  case scheme
  of "postgres", "postgresql": result.kind = "postgres"
  of "mysql", "mariadb": result.kind = "mysql"
  else:
    result.why = name & ": " & scheme & ":// is not a database this plugin knows (postgres://, mysql://)"
    return
  var rest = s[k + 3 .. ^1]
  var query = ""
  let q = rest.find('?')
  if q >= 0:
    query = rest[q + 1 .. ^1]
    rest = rest[0 ..< q]
  var auth = rest
  let sl = rest.find('/')
  if sl >= 0:
    result.db = unpercent(rest[sl + 1 .. ^1])
    auth = rest[0 ..< sl]
  var userinfo = ""
  var hostport = auth
  let at = auth.rfind('@')
  if at >= 0:
    userinfo = auth[0 ..< at]
    hostport = auth[at + 1 .. ^1]
  var rawUser = userinfo
  let c = userinfo.find(':')
  if c >= 0:
    result.password = true
    rawUser = userinfo[0 ..< c]
  result.user = unpercent(rawUser)
  if hostport.startsWith("["):                       # [::1]:5432
    let e = hostport.find(']')
    result.host = if e > 0: hostport[1 ..< e] else: hostport
    if e > 0 and e + 1 < hostport.len and hostport[e + 1] == ':': result.port = hostport[e + 2 .. ^1]
  else:
    let p = hostport.rfind(':')
    if p >= 0:
      result.host = hostport[0 ..< p]
      result.port = hostport[p + 1 .. ^1]
    else: result.host = hostport
  result.host = unpercent(result.host)
  for kv in query.split('&'):
    if kv.len == 0: continue
    let e = kv.find('=')
    if e > 0: result.params.add (unpercent(kv[0 ..< e]), unpercent(kv[e + 1 .. ^1]))
    else: result.params.add (unpercent(kv), "")
  result.url = s[0 ..< k] & "://" & (if rawUser.len > 0: rawUser & "@" else: "") & hostport &
               (if sl >= 0: rest[sl .. ^1] else: "") & (if query.len > 0: "?" & query else: "")

proc connsFrom(j: JsonNode): seq[Conn] =
  ## the connections setting: a JSON list of {name, url} — or that list written as a string
  var x = j
  if x != nil and x.kind == JString:
    if x.getStr.strip.len == 0: return
    try: x = parseJson(x.getStr)
    except CatchableError:
      return @[Conn(name: "connections", why: "plugins.db-client.connections is not a JSON list of {name, url}")]
  if x == nil or x.kind != JArray: return
  for i, e in x.getElems:
    if e.kind != JObject: continue
    let name = if e{"name"}.getStr.len > 0: e{"name"}.getStr else: "connection " & $(i + 1)
    result.add parseConn(name, e{"url"}.getStr)

func commandFor(c: Conn, prog, script: string): string =
  ## the client's command line for the script (no password in it: the client finds that itself)
  if c.kind == "postgres":
    "PGCONNECT_TIMEOUT=10 " & quoteShell(prog) & " -X -w -v ON_ERROR_STOP=1 --csv -P null=NULL -d " &
      quoteShell(c.url) & " -f " & quoteShell(script)
  else:
    var s = quoteShell(prog) & " --batch --connect-timeout=10"
    if c.host.len > 0: s.add " --host=" & quoteShell(c.host)
    if c.port.len > 0: s.add " --port=" & quoteShell(c.port)
    if c.user.len > 0: s.add " --user=" & quoteShell(c.user)
    for (k, v) in c.params:
      case k
      of "socket": s.add " --socket=" & quoteShell(v)
      of "ssl-mode", "sslmode", "ssl_mode": s.add " --ssl-mode=" & quoteShell(v)
      of "charset": s.add " --default-character-set=" & quoteShell(v)
      else: discard
    if c.db.len > 0: s.add " --database=" & quoteShell(c.db)
    s & " < " & quoteShell(script)

# ── statements ──

func skipQuoted(t: string, i: int, q: char, backslash: bool): int =
  ## the index after the quoted text that starts at i (its quote doubled inside it; with backslash escapes too)
  var k = i + 1
  while k < t.len:
    if backslash and t[k] == '\\':
      k += 2
      continue
    if t[k] == q:
      if k + 1 < t.len and t[k + 1] == q:
        k += 2
        continue
      return k + 1
    inc k
  t.len

func dollarTag(t: string, i: int): string =
  ## $tag$ or $$ at i (PostgreSQL's quotes) — "" when it is not one ($1 is a parameter)
  if i > 0 and t[i - 1] in IdentChars: return ""
  var k = i + 1
  if k < t.len and t[k] == '$': return "$$"
  if k >= t.len or t[k] notin IdentStartChars: return ""
  while k < t.len and t[k] in IdentChars: inc k
  if k < t.len and t[k] == '$': t[i .. k] else: ""

func splitSql(text, dialect: string, line0 = 0, col0 = 0): seq[Stmt] =
  ## the statements of the text (it starts at line0, col0 of the file), split as psql and mysql split them
  var starts = @[0]                                   # (where each line of the text starts)
  for i, c in text:
    if c == '\n': starts.add i + 1
  template at(off: int): (int, int) =
    ## the file's line and column of byte offset off in the text, found from where each line of the text starts (the
    ## first line's column counts from col0)
    var lo = 0
    for k in countdown(starts.high, 0):
      if starts[k] <= off:
        lo = k
        break
    (line0 + lo, (if lo == 0: col0 + off else: off - starts[lo]))
  let my = dialect == "mysql"
  var delim = ";"
  var st = -1
  var i = 0
  let n = text.len
  template finish(stop, after: int) =
    ## ends the statement that began at st: its text up to stop (trailing blanks taken off) is added to the result, with
    ## where it starts and where it ends after its delimiter; nothing for an empty one; st is reset
    let s = text[st ..< stop].strip(leading = false)
    if s.len > 0:
      let (l, c) = at(st)
      let (l2, c2) = at(after)
      result.add Stmt(text: s, line: l, col: c, stopLine: l2, stopCol: c2)
    st = -1
  while i < n:
    let c = text[i]
    if c in Whitespace:
      inc i
      continue
    if text.continuesWith("--", i) or (my and c == '#'):
      while i < n and text[i] != '\n': inc i
      continue
    if text.continuesWith("/*", i):
      var depth = 1
      var k = i + 2
      while k < n and depth > 0:
        if not my and text.continuesWith("/*", k):
          inc depth
          k += 2
        elif text.continuesWith("*/", k):
          dec depth
          k += 2
        else: inc k
      i = k
      continue
    if my and st < 0 and i + 10 < n and text[i ..< i + 9].toLowerAscii == "delimiter" and text[i + 9] in {' ', '\t'}:
      var e = i
      while e < n and text[e] != '\n': inc e
      let d = text[i + 9 ..< e].strip
      if d.len > 0:
        delim = d
        i = e
        continue
    if text.continuesWith(delim, i):
      if st >= 0: finish(i, i + delim.len)
      i += delim.len
      continue
    if st < 0: st = i
    case c
    of '\'':
      let e = i > 0 and text[i - 1] in {'E', 'e'} and (i < 2 or text[i - 2] notin IdentChars)
      i = skipQuoted(text, i, '\'', my or e)
    of '"': i = skipQuoted(text, i, '"', my)
    of '`':
      if my: i = skipQuoted(text, i, '`', false)
      else: inc i
    of '$':
      let tag = if my: "" else: dollarTag(text, i)
      if tag.len > 0:
        let e = text.find(tag, i + tag.len)
        i = if e < 0: n else: e + tag.len
      else: inc i
    else: inc i
  if st >= 0: finish(n, n)

func stmtAt(stmts: seq[Stmt], line, col: int): int =
  ## the statement the place is in — or the one that ends before it on its line; -1: none
  func le(l1, c1, l2, c2: int): bool = l1 < l2 or (l1 == l2 and c1 <= c2)
  for k, s in stmts:
    if le(s.line, s.col, line, col) and le(line, col, s.stopLine, s.stopCol): return k
  result = -1
  for k, s in stmts:
    if s.stopLine == line and s.stopCol <= col: result = k

func firstWord(s: string): string =
  ## the first word of a statement in capitals (SELECT, INSERT …), after anything that is not the start of a name
  var i = 0
  while i < s.len and s[i] notin IdentStartChars: inc i
  var e = i
  while e < s.len and s[e] in IdentChars: inc e
  s[i ..< e].toUpperAscii

func scriptFor(kind: string, stmts: seq[Stmt]): string =
  ## what the client reads: each statement after a line that marks it (psql's \echo; for mysql a SELECT of the
  ## mark and of ROW_COUNT() after it), each ended on a line of its own (a -- comment at its end cannot hide it)
  if kind == "postgres":
    for k, s in stmts:
      result.add "\\echo '\\x1e" & $(k + 1) & "'\n" & s.text & "\n;\n"
  else:
    result = "DELIMITER " & MyDelim & "\n"
    for k, s in stmts:
      result.add s.text & "\n" & MyDelim & "\nSELECT '" & Mark & $(k + 1) & "' AS ned_marker, ROW_COUNT() AS ned_rows" &
                 MyDelim & "\n"

# ── the clients' output ──

func parseCsv(t: string): seq[seq[string]] =
  ## CSV as psql writes it: , between fields, "…" around those with , " or a line end ("" for a ")
  var row: seq[string]
  var f = ""
  var i = 0
  var quoted = false
  var any = false
  while i < t.len:
    let c = t[i]
    if quoted:
      if c == '"':
        if i + 1 < t.len and t[i + 1] == '"':
          f.add '"'
          inc i
        else: quoted = false
      else: f.add c
    elif c == '"':
      quoted = true
      any = true
    elif c == ',':
      row.add f
      f = ""
      any = true
    elif c == '\n' or c == '\r':
      if c == '\r' and i + 1 < t.len and t[i + 1] == '\n': inc i
      row.add f
      result.add row
      row = @[]
      f = ""
      any = false
    else:
      f.add c
      any = true
    inc i
  if any or row.len > 0:
    row.add f
    result.add row

func isTag(l: string, numeric: bool): bool =
  ## a psql command tag: INSERT 0 2, UPDATE 3 … (numeric) — or CREATE TABLE, SET, BEGIN …
  let w = l.splitWhitespace
  if w.len == 0: return false
  if w[0] in ["INSERT", "UPDATE", "DELETE", "MERGE", "SELECT", "COPY", "FETCH", "MOVE"] and w.len >= 2:
    for x in w[1 .. ^1]:
      for ch in x:
        if ch notin Digits: return false
    return true
  if numeric: return false
  for x in w:
    for ch in x:
      if ch notin {'A' .. 'Z'}: return false
  true

func returnsRows(s: string): bool =
  ## whether a statement gives rows back: it starts with SELECT, WITH, VALUES, TABLE, SHOW or EXPLAIN, or has a
  ## RETURNING
  firstWord(s) in ["SELECT", "WITH", "VALUES", "TABLE", "SHOW", "EXPLAIN"] or "RETURNING" in s.toUpperAscii

func charToByte(line: string, chars: int): int =
  ## the byte offset of the chars-th character of the line
  var k = 0
  for i, c in line:
    if (ord(c) and 0xC0) != 0x80:
      if k == chars: return i
      inc k
  line.len

func placeIn(s: Stmt, n, colChars: int): (int, int) =
  ## the file's line and column of line n (from 1) and column colChars (characters; -1: not known) of the statement
  let lines = s.text.split('\n')
  let l = s.line + max(0, min(n, lines.len) - 1)
  if colChars < 0: return (l, (if n <= 1: s.col else: -1))
  let own = lines[max(0, min(n, lines.len) - 1)]
  let c = charToByte(own, colChars)
  (l, (if n <= 1: s.col + c else: c))

func scriptLines(stmts: seq[Stmt]): seq[(int, int)] =
  ## the lines (from 1) of the psql script each statement has: its text and the ; after it
  var l = 1
  for s in stmts:
    let m = s.text.count('\n') + 1
    result.add (l + 1, l + m + 1)
    l += m + 2

func parsePsql(output, errors: string, stmts: seq[Stmt]): (seq[Res], string) =
  ## psql's output (a mark before each statement, then CSV or a command tag) and its errors: each statement's
  ## result, and an error about the connection or the program ("" none)
  var res = newSeq[Res](stmts.len)
  for r in res.mitems: (r.errLine, r.errCol) = (-1, -1)
  var sections: seq[(int, string)]
  var cur = -1
  var buf = ""
  for l in output.split('\n'):
    if l.startsWith(Mark) and l.len > 1 and l[1 .. ^1].allCharsInSet(Digits):
      if cur >= 0: sections.add (cur, buf)
      cur = parseInt(l[1 .. ^1]) - 1
      buf = ""
    elif cur >= 0: buf.add l & "\n"
  if cur >= 0: sections.add (cur, buf)
  var last = -1                                      # (the last statement psql came to)
  for (k, text) in sections:
    if k < 0 or k >= res.len: continue
    last = max(last, k)
    res[k].ran = true
    var t = text.strip(leading = false, chars = {'\n'})
    let nl = t.rfind('\n')
    let lastLine = if nl < 0: t else: t[nl + 1 .. ^1]
    if t.len > 0 and isTag(lastLine, returnsRows(stmts[k].text)):
      res[k].tag = lastLine
      t = if nl < 0: "" else: t[0 ..< nl]
    if t.len > 0:
      let rows = parseCsv(t & "\n")
      if rows.len > 0:
        res[k].hasRows = true
        res[k].columns = rows[0]
        res[k].rows = rows[1 .. ^1]
  # the errors: psql:FILE:LINE: ERROR:  …, then LINE n: …, the caret under it, HINT:, DETAIL:
  let ranges = scriptLines(stmts)
  proc which(l: string): int =
    ## the statement a psql:FILE:LINE: line is about (by the script's line; else the last one psql came to)
    let p = l.find(": ")
    let head = if p > 0: l[0 ..< p] else: l
    let c = head.rfind(':')
    let n = if c > 0: (try: parseInt(head[c + 1 .. ^1]) except ValueError: -1) else: -1
    for k, (a, e) in ranges:
      if n >= a and n <= e: return k
    last
  var general = ""
  let el = errors.splitLines
  var i = 0
  while i < el.len:
    let l = el[i]
    var kind, msg = ""
    if l.startsWith("psql: error:"):                   # (the connection, before any statement)
      general = l["psql: error:".len .. ^1].strip
      var k = i + 1
      while k < el.len and el[k].len > 0 and el[k][0] in {' ', '\t'}:
        general.add " " & el[k].strip
        inc k
      i = k
      continue
    if l.startsWith("psql:"):
      for w in [": ERROR:", ": FATAL:", ": NOTICE:", ": WARNING:", ": INFO:"]:
        let p = l.find(w)
        if p >= 0:
          kind = w[2 ..< w.high]
          msg = l[p + w.len .. ^1].strip
          break
    let f = if kind.len > 0: which(l) else: -1
    if kind in ["ERROR", "FATAL"] and f >= 0:
      res[f].ran = true
      res[f].error = msg
      (res[f].errLine, res[f].errCol) = (stmts[f].line, stmts[f].col)
      var k = i + 1
      while k < el.len and not el[k].startsWith("psql:"):
        let x = el[k]
        if x.startsWith("LINE "):
          let c = x.find(':')
          let n = try: parseInt(x[5 ..< c]) except ValueError: 1
          let shown = x[c + 2 .. ^1]
          var caret = -1
          if k + 1 < el.len and el[k + 1].strip == "^":
            caret = el[k + 1].find('^') - (c + 2)
            inc k
          if caret >= 0 and shown.startsWith("..."):          # (psql cuts a long line: …the part shown…)
            let lines = stmts[f].text.split('\n')
            let own = lines[max(0, min(n, lines.len) - 1)]
            var core = shown[3 .. ^1]
            if core.endsWith("..."): core = core[0 ..< core.len - 3]
            let off = own.find(core)
            caret = if off >= 0: off + caret - 3 else: -1
          (res[f].errLine, res[f].errCol) = placeIn(stmts[f], n, caret)
        elif x.startsWith("HINT:") or x.startsWith("DETAIL:"):
          res[f].error.add " — " & x[x.find(':') + 1 .. ^1].strip
        inc k
      i = k
      continue
    elif kind in ["NOTICE", "WARNING", "INFO"] and f >= 0:
      res[f].notes.add kind & ": " & msg
    elif kind.len == 0 and general.len == 0 and l.strip.len > 0 and not l.startsWith("HINT:") and
         not l.startsWith("DETAIL:") and not l.startsWith("LINE ") and l.strip != "^":
      general = l.strip                                  # (psql's own trouble: a file it cannot read …)
    inc i
  (res, general)

func unescapeMy(s: string): string =
  ## a field of mysql --batch: \n \t \\ \0 back to what they stand for
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len:
      case s[i + 1]
      of 'n': result.add '\n'
      of 't': result.add '\t'
      of 'r': result.add '\r'
      of '0': result.add '\0'
      of '\\': result.add '\\'
      else: result.add s[i + 1]
      i += 2
    else:
      result.add s[i]
      inc i

func parseMysql(output, errors: string, stmts: seq[Stmt]): (seq[Res], string) =
  ## mysql --batch's output (each statement's rows, tab-separated, then the mark's row: ned_marker, ned_rows) and
  ## its errors (ERROR 1064 (42000) at line 3: … near '…' at line 2)
  var res = newSeq[Res](stmts.len)
  for r in res.mitems: (r.errLine, r.errCol) = (-1, -1)
  var lines = output.split('\n')
  if lines.len > 0 and lines[^1].len == 0: lines.setLen(lines.len - 1)
  var block0: seq[string]
  var done = 0
  var i = 0
  while i < lines.len:
    let l = lines[i]
    if l == "ned_marker\tned_rows" and i + 1 < lines.len and lines[i + 1].startsWith(Mark):
      let f = lines[i + 1][1 .. ^1].split('\t')
      let k = (try: parseInt(f[0]) except ValueError: done + 1) - 1
      if k >= 0 and k < res.len:
        res[k].ran = true
        if block0.len > 0:
          res[k].hasRows = true
          for x in block0[0].split('\t'): res[k].columns.add unescapeMy(x)
          for row in block0[1 .. ^1]:
            var cells: seq[string]
            for x in row.split('\t'): cells.add unescapeMy(x)
            res[k].rows.add cells
        else:
          let n = if f.len > 1: (try: parseInt(f[1]) except ValueError: -1) else: -1
          res[k].tag = if n < 0: "done" elif n == 1: "1 row affected" else: $n & " rows affected"
        done = k + 1
      block0 = @[]
      i += 2
      continue
    block0.add l
    inc i
  var general = ""
  let failed = if done < res.len: done else: -1
  let el = errors.splitLines
  for i, l in el:
    if not l.startsWith("ERROR"): continue
    # ERROR 1064 (42000) at line 3: message … near '…' at line 2  ·  ERROR 2002 (HY000): message (the connection)
    var whole = l
    var k = i + 1
    while " near '" in whole and "' at line " notin whole and k < el.len:
      whole.add "\n" & el[k]
      inc k
    let c = whole.find(": ")
    let msg = if c >= 0: whole[c + 2 .. ^1] else: whole
    if " at line " in whole[0 ..< max(0, c)] and failed >= 0:
      res[failed].ran = true
      res[failed].error = msg.split('\n')[0]
      (res[failed].errLine, res[failed].errCol) = (stmts[failed].line, stmts[failed].col)
      let near = msg.find(" near '")
      let atl = msg.rfind("' at line ")
      if near >= 0 and atl > near:
        let n = try: parseInt(msg[atl + 10 .. ^1].strip) except ValueError: 1
        let what = msg[near + 7 ..< atl].split('\n')[0]
        let lines = stmts[failed].text.split('\n')
        let own = lines[max(0, min(n, lines.len) - 1)]
        let off = if what.len > 0: own.find(what) else: -1
        (res[failed].errLine, res[failed].errCol) = placeIn(stmts[failed], n, -1)
        if off >= 0: res[failed].errCol = (if n <= 1: stmts[failed].col + off else: off)
    else: general = msg.split('\n')[0]
    break
  if general.len == 0 and failed >= 0 and res[failed].error.len == 0:
    for l in el:
      if l.strip.len > 0 and not l.startsWith("mysql: [Warning]") and not l.startsWith("Warning"):
        general = l.strip
        break
  (res, general)

# ── showing the results ──

# a value for one line of a table: a line end becomes ↵ and a tab a space
func cellText(v: string): string = v.replace("\r\n", "↵").replace("\n", "↵").replace("\t", " ")

func width(s: string): int =
  ## how wide s is on the screen: its characters (not its bytes)
  for c in s:
    if (ord(c) and 0xC0) != 0x80: inc result

func isNumber(v: string): bool =
  ## whether the value is written as a number (an optional sign, digits, one dot, an exponent) — a column of such values
  ## is right-aligned
  if v.len == 0: return false
  var i = 0
  if v[0] in {'-', '+'}: inc i
  var digits = false
  var dot, exp = false
  while i < v.len:
    let c = v[i]
    if c in Digits: digits = true
    elif c == '.' and not dot and not exp: dot = true
    elif c in {'e', 'E'} and digits and not exp:
      exp = true
      if i + 1 < v.len and v[i + 1] in {'-', '+'}: inc i
    else: return false
    inc i
  digits

func table(r: Res, maxRows: int): string =
  ## the rows as psql's aligned table: a header, a line under it, numbers on the right; how many rows
  let shown = r.rows[0 ..< min(r.rows.len, max(0, maxRows))]
  var w = newSeq[int](r.columns.len)
  var num = newSeq[bool](r.columns.len)
  for c, h in r.columns:
    w[c] = width(h)
    var any = false
    num[c] = true
    for row in shown:
      if c < row.len:
        let v = cellText(row[c])
        w[c] = max(w[c], width(v))
        if row[c] != "NULL":
          any = true
          if not isNumber(row[c]): num[c] = false
    if not any: num[c] = false
  var lines: seq[string]
  var head, rule: seq[string]
  for c, h in r.columns:
    head.add " " & h & spaces(w[c] - width(h)) & " "
    rule.add repeat('-', w[c] + 2)
  lines.add head.join("|").strip(leading = false)
  lines.add rule.join("+")
  for row in shown:
    var cells: seq[string]
    for c in 0 ..< r.columns.len:
      let v = if c < row.len: cellText(row[c]) else: ""
      let pad = spaces(w[c] - width(v))
      cells.add " " & (if num[c]: pad & v else: v & pad) & " "
    lines.add cells.join("|").strip(leading = false)
  let n = r.rows.len
  lines.add "(" & (if n == 1: "1 row" else: $n & " rows") &
            (if n > shown.len: " — the first " & $shown.len & " shown: plugins.db-client.maxRows" else: "") & ")"
  lines.join("\n")

func csvField(v: string): string =
  ## a value as a CSV field: NULL is an empty field, an empty text is "", and one with a comma, quote, line end or
  ## blanks at its ends is quoted with its quotes doubled
  if v == "NULL": ""
  elif v.len == 0: "\"\""
  elif v.contains({',', '"', '\n', '\r'}) or v.strip != v: "\"" & v.replace("\"", "\"\"") & "\""
  else: v

func csv(r: Res): string =
  ## the rows as CSV (NULL an empty field, an empty text "")
  var lines: seq[string]
  var h: seq[string]
  for c in r.columns: h.add csvField(c)
  lines.add h.join(",")
  for row in r.rows:
    var cells: seq[string]
    for v in row: cells.add csvField(v)
    lines.add cells.join(",")
  lines.join("\n") & "\n"

func headline(s: Stmt): string =
  ## a statement's line in the file and its first line (80 characters at most)
  var t = s.text.split('\n')[0].strip
  if t.len > 80:
    var k = 77
    while k > 0 and (ord(t[k]) and 0xC0) == 0x80: dec k
    t = t[0 ..< k] & "…"
  "-- line " & $(s.line + 1) & ": " & t

func report(conn: Conn, when0: string, stmts: seq[Stmt], res: seq[Res], maxRows: int): string =
  ## the tab's text: each statement, then its rows, what it did, or its error
  var parts = @["-- " & conn.name & " · " & conn.kind & " · " & when0]
  for k, s in stmts:
    var p = headline(s)
    let r = res[k]
    for x in r.notes: p.add "\n" & x
    if r.error.len > 0:
      p.add "\nERROR:  " & r.error
      if r.errLine >= 0:
        p.add "  (line " & $(r.errLine + 1) & (if r.errCol >= 0: ", column " & $(r.errCol + 1) else: "") & ")"
    elif not r.ran: p.add "\n(not run: the error before it stopped the rest)"
    else:
      if r.hasRows: p.add "\n" & table(r, maxRows)
      if r.tag.len > 0: p.add "\n" & r.tag
      if not r.hasRows and r.tag.len == 0: p.add "\ndone"
    parts.add p
  parts.join("\n\n") & "\n"

# ── running ──

var
  running = false
  cancelled = false
  runConn: Conn
  runStmtsSeq: seq[Stmt]
  runBuf = Buf(id: -1)
  runDir = ""

# the connections of the connections setting
proc connsSetting(): seq[Conn] = connsFrom(settingIn("", "connections"))

proc chosenName(): string =
  ## the name of the connection chosen for this project (kept in chosen.json in the data folder, by project folder); ""
  ## when none
  try: parseJson(readData("chosen.json")){projectRoot()}.getStr
  except CatchableError: ""

proc keepChoice(name: string) =
  ## remembers the connection chosen for this project in chosen.json in the data folder
  var j = newJObject()
  try:
    j = parseJson(readData("chosen.json"))
    if j.kind != JObject: j = newJObject()
  except CatchableError: discard
  j[projectRoot()] = %name
  writeData("chosen.json", j.pretty & "\n")

# what to show of a connection: its url (without a password), or why it is not usable
func shownUrl(c: Conn): string = (if c.kind.len > 0: c.url else: c.why)

proc chooseConn(): (bool, Conn) =
  ## DB: choose a connection… — lists the connections of the setting (the chosen one marked ●), remembers the pick for
  ## the project and shows it in the status line; false when there are none or nothing was picked
  let cs = connsSetting()
  if cs.len == 0:
    warn("DB: no connections yet — plugins.db-client.connections: [{\"name\": \"dev\", \"url\": " &
         "\"postgres://you@localhost:5432/app\"}]")
    return
  var items, details: seq[string]
  let now = chosenName()
  for c in cs:
    items.add c.name & (if c.name == now: "  ●" else: "")
    details.add shownUrl(c)
  let k = pick("DB: which connection?", items, details)
  if k < 0: return
  keepChoice(cs[k].name)
  status("DB: " & cs[k].name)
  message("DB: " & cs[k].name & " — " & shownUrl(cs[k]))
  (true, cs[k])

proc currentConn(): (bool, Conn) =
  ## the project's connection (asked for when there are several and none is chosen yet)
  let cs = connsSetting()
  if cs.len == 0: return chooseConn()
  let now = chosenName()
  var c: Conn
  var found = false
  for x in cs:
    if x.name == now:
      c = x
      found = true
  if not found:
    if cs.len == 1: c = cs[0]
    else:
      let (ok, x) = chooseConn()
      if not ok: return
      c = x
  if c.kind.len == 0:
    warn("DB: " & c.why)
    return
  if c.password:
    toast("DB: the password in " & c.name & "'s url is not used — take it out of your settings and put it in " &
          (if c.kind == "postgres": "~/.pgpass or PGPASSWORD" else: "~/.my.cnf or MYSQL_PWD"))
  (true, c)

func hint(kind, general: string): string =
  ## what to do about an error of the connection
  let g = general.toLowerAscii
  if "password" in g or "access denied" in g or "authentication" in g:
    if kind == "postgres": " — the password: PGPASSWORD, or a line host:port:database:user:password in ~/.pgpass"
    else: " — the password: MYSQL_PWD, or password=… under [client] in ~/.my.cnf"
  else: ""

proc problemsOf(b: Buf, res: seq[Res]): seq[Problem] =
  ## the errors of the results as problems of the file, for the Problems panel: at the error's line and column, over the
  ## word there (the whole line when the column is not known)
  for r in res:
    if r.error.len == 0 or r.errLine < 0: continue
    let l = b.line(r.errLine)
    var a = max(0, r.errCol)
    if a > l.len: a = 0
    var e = a
    while e < l.len and l[e] in IdentChars: inc e
    if e == a: e = (if a < l.len: a + 1 else: l.len)
    if r.errCol < 0:
      a = 0
      e = l.len
    result.add Problem(range: rng(pos(r.errLine, a), pos(r.errLine, e)), severity: 1, message: r.error)

proc finish(output: string, code: int) =
  ## what happens when the client ends: reads its output and errors from the run folder, says so if the program is not
  ## installed, parses the results, opens them in a tab (or a CSV tab for each result set), puts the errors in the
  ## Problems panel of the file and says in the message line what was done
  running = false
  progressDone()
  if cancelled:
    message("DB: the query was cancelled")
    return
  let d = runDir
  let o = if fileExists(d / "out.txt"): readFile(d / "out.txt") else: ""
  let e = if fileExists(d / "err.txt"): readFile(d / "err.txt") else: ""
  let c = runConn
  let prog = if c.kind == "postgres": setting("psql", "psql") else: setting("mysql", "mysql")
  # (the shell's "psql: not found" — not psql's own "No such file or directory" about a socket)
  if code == 127 or (o.len == 0 and (": not found" in e or "command not found" in e) and not e.startsWith("psql:") and
                     not e.startsWith("ERROR")):
    let how = if c.kind == "postgres": "Termux: pkg install postgresql; Debian, Ubuntu: apt install postgresql-client"
              else: "Termux: pkg install mariadb; Debian, Ubuntu: apt install mariadb-client"
    warn("DB: " & prog & " is not installed (" & how & ") — or set plugins.db-client." &
         (if c.kind == "postgres": "psql" else: "mysql"))
    return
  let (res, general) = if c.kind == "postgres": parsePsql(o, e, runStmtsSeq) else: parseMysql(o, e, runStmtsSeq)
  var anyRan = false
  for r in res:
    if r.ran: anyRan = true
  if not anyRan and general.len > 0:
    warn("DB: " & c.name & ": " & general & hint(c.kind, general))
    return
  let fmt = setting("format", "table")
  if fmt == "csv":
    var n = 0
    for r in res:
      if r.hasRows:
        inc n
        let t = newTab("DB: " & c.name & (if n > 1: " (" & $n & ")" else: "") & ".csv", csv(r), "csv")
        if t.valid: t.markSaved()
  else:
    let t = newTab("DB: " & c.name, report(c, localTime(), runStmtsSeq, res, setting("maxRows", 500)), "sql")
    if t.valid: t.markSaved()
  var probs: seq[Problem]
  if runBuf.valid:
    try:
      probs = problemsOf(runBuf, res)
      runBuf.setProblems(probs)
    except CatchableError: discard
  var rows = 0
  var failed = -1
  for k, r in res:
    rows += r.rows.len
    if r.error.len > 0 and failed < 0: failed = k
  if failed >= 0:
    let r = res[failed]
    warn("DB: " & (if r.errLine >= 0: "line " & $(r.errLine + 1) & ": " else: "") & r.error)
  elif general.len > 0: warn("DB: " & general)
  else:
    message("DB: " & c.name & " — " & (if res.len == 1: "1 statement" else: $res.len & " statements") & ", " &
            (if rows == 1: "1 row" else: $rows & " rows"))

proc run(b: Buf, stmts: seq[Stmt]) =
  ## runs the statements on the project's connection: writes them as one script to the data folder and starts psql or
  ## mysql on it in the background, its output going to files there and its process number kept so the query can be
  ## cancelled; finish handles the end
  if stmts.len == 0:
    message("DB: no SQL statement here")
    return
  if running:
    message("DB: a query is still running (DB: cancel the query)")
    return
  let (ok, c) = currentConn()
  if not ok: return
  writeData("run/query.sql", scriptFor(c.kind, stmts))
  let d = dataDir() / "run"
  let prog = if c.kind == "postgres": setting("psql", "psql") else: setting("mysql", "mysql")
  let cmd = commandFor(c, prog, d / "query.sql")
  running = true
  cancelled = false
  runConn = c
  runStmtsSeq = stmts
  runBuf = b
  runDir = d
  status("DB: " & c.name)
  progress("DB: " & c.name & " — " & stmts[0].text.split('\n')[0].strip)
  log("DB: " & cmd)
  # (the client's number kept, for DB: cancel the query; its exit code is the command's)
  shellAsync("rm -f out.txt err.txt pid.txt; " & cmd & " > out.txt 2> err.txt & echo $! > pid.txt; wait $!",
             finish, d)

proc dialect(): string =
  ## the dialect statements are split in: the chosen connection's (PostgreSQL's when none is chosen yet)
  let cs = connsSetting()
  let now = chosenName()
  for c in cs:
    if c.name == now or cs.len == 1: return (if c.kind == "mysql": "mysql" else: "postgres")
  "postgres"

func sqlFile(lang, path: string): bool =
  ## whether the file is SQL: its language, or a .sql, .psql, .pgsql or .mysql name
  lang == "sql" or path.endsWith(".sql") or path.endsWith(".psql") or path.endsWith(".pgsql") or path.endsWith(".mysql")

proc runAtCursor(b: Buf) =
  ## DB: run the statement at the cursor — runs the selection (in any file), or the statement the cursor is in or just
  ## after (in a SQL file); says so when there is none
  if not b.valid: return
  let sel = b.selection
  if not sel.isEmpty:
    run(b, splitSql(b.textIn(sel), dialect(), sel.start.line, sel.start.col))
    return
  if not sqlFile(b.lang, b.path):
    message("DB: select the SQL to run (or put the cursor in a statement of a .sql file)")
    return
  let stmts = splitSql(b.text, dialect())
  let p = b.cursor
  let k = stmtAt(stmts, p.line, p.col)
  if k < 0:
    message("DB: the cursor is not in a statement")
    return
  run(b, @[stmts[k]])

command "DB: run the statement at the cursor": runAtCursor(current())
command "DB: run the whole file":
  let b = current()
  if b.valid: run(b, splitSql(b.text, dialect()))
command "DB: choose a connection…": discard chooseConn()
command "DB: cancel the query":
  if not running: message("DB: no query is running")
  else:
    cancelled = true
    if fileExists(runDir / "pid.txt"): discard shell("kill " & readFile(runDir / "pid.txt").strip & " 2>/dev/null")

keyIn("sql", "ctrl+enter", "run the statement at the cursor (or the selection)") do (b: Buf): runAtCursor(b)
nmapIn("sql", "<leader>r", "run the statement at the cursor") do (count: int): runAtCursor(current())
vmapIn("sql", "<leader>r", "run the selected SQL") do (count: int): runAtCursor(current())
