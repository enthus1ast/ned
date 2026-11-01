## sqlite — an SQLite database beside the code: its tables and columns in the Plugins dock and in completion, the
## query at the cursor run on it, the rows in a tab
##
##   SQLite: open a database…       a .db / .sqlite / .sqlite3 file of the project (or any path): the one queries
##                                  run on (remembered for the project)
##   SQLite: run the query at the cursor   the statement the cursor is in (from the `;` before it to the next), or
##                                  the selection — in a .sql file, or a string of SQL in any file: the rows in a
##                                  tab ("sqlite: name.db"), the next query's rows under them
##   SQLite: show a table…          a table's first rows (plugins.sqlite.rows of them)
##   SQLite: the schema             CREATE statements of every table and index, in a tab
##   The dock's SQLITE view: the tables, each with its columns (type, primary key, not null); a tap on a table
##   shows its rows. In .sql files, completion offers the tables and the columns of the database.
## It needs the sqlite3 program: Termux `pkg install sqlite`, Debian/Ubuntu `apt install sqlite3`, macOS has it.
import nedplugin
import std/[strutils, json]

requiresNed(">= 6.27")
pluginInfo(version = "1.0.0", author = "Sultan Al Isaiee (@foxoman)", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")
permission("shell", "runs sqlite3 on the database you open")

settingDef("rows", 200, "SQLite: show a table — how many of its rows")
settingDef("program", "sqlite3", "The sqlite3 program (its name on PATH, or its path)")

var
  dbPath = ""
  tableCache: seq[(string, seq[(string, string, bool, bool)])]   # table → (column, type, primary key, not null)
  cacheFor = ""
  outTab = Buf(id: -1)

# the text quoted for the shell, in single quotes (a quote inside it written as '\'')
func q(s: string): string = "'" & s.replace("'", "'\\''") & "'"

# the sqlite3 program to run, from the plugin's `program` setting
proc prog(): string = setting("program", "sqlite3")

proc remembered(): string =
  ## the database last opened for this project
  try:
    let j = parseJson(readData("databases.json"))
    result = j{projectRoot()}.getStr
  except CatchableError: discard

proc remember(p: string) =
  ## keeps the database file as the project's in databases.json in the plugin's data folder (one entry for each project
  ## root), to be found again next time
  var j = newJObject()
  try: j = parseJson(readData("databases.json"))
  except CatchableError: discard
  if j.kind != JObject: j = newJObject()
  j[projectRoot()] = %p
  writeData("databases.json", j.pretty & "\n")

proc database(): string =
  ## the database queries run on: the one opened in this session, else the one remembered for the project ("" when there
  ## is none)
  if dbPath.len == 0: dbPath = remembered()
  dbPath

proc runSql(sql: string, mode = "-box"): (string, int) =
  ## sqlite3 on the database with this SQL on its stdin: its output, its exit code
  writeData("query.sql", sql & "\n")
  let f = dataDir() & "/query.sql"
  var r = shell(q(prog()) & " -bail -header " & mode & " " & q(expandTilde(database())) & " < " & q(f) & " 2>&1")
  if r.code != 0 and mode == "-box" and "-box" in r.output:
    # (an sqlite3 older than 3.33: columns without the box)
    r = shell(q(prog()) & " -bail -header -column " & q(expandTilde(database())) & " < " & q(f) & " 2>&1")
  (r.output, r.code)

proc tables(): seq[(string, seq[(string, string, bool, bool)])] =
  ## the tables and their columns (asked of the database once it is opened, and after a query that changes it)
  if cacheFor == database() and tableCache.len > 0: return tableCache
  tableCache.setLen(0)
  cacheFor = database()
  if database().len == 0: return
  let (o, code) = runSql("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name;",
                         "-list -noheader")
  if code != 0: return
  for t in o.splitLines:
    let name = t.strip
    if name.len == 0: continue
    var cols: seq[(string, string, bool, bool)]
    let (c, cc) = runSql("PRAGMA table_info(\"" & name.replace("\"", "\"\"") & "\");", "-list -noheader")
    if cc == 0:
      for row in c.splitLines:
        let f = row.split('|')
        # cid | name | type | notnull | default | pk
        if f.len >= 6: cols.add (f[1], f[2], f[5] != "0", f[3] == "1")
    tableCache.add (name, cols)
  tableCache

proc showRows(title, text: string) =
  ## the rows in the sqlite tab (made once, the newest query on top)
  let t = "sqlite: " & database().split('/')[^1]
  var prev = ""
  if outTab.valid:
    try: prev = outTab.text
    except CatchableError: outTab = Buf(id: -1)
  let body = "-- " & title & "\n" & text.strip(leading = false) & "\n" & (if prev.len > 0: "\n" & prev else: "")
  if outTab.valid:
    try:
      outTab.setText(body)
      outTab.markSaved()
      return
    except CatchableError: outTab = Buf(id: -1)
  outTab = newTab(t, body, "sql")
  outTab.markSaved()

proc needDb(): bool =
  ## whether a database is open; when none is, it warns where to open one and says false
  if database().len > 0: return true
  warn("Open a database first (SQLite: open a database…)")
  false

proc openDb() =
  ## asks which database to use: a pick from the .db, .sqlite and .sqlite3 files of the project (from git, else a find
  ## four folders deep) or a path typed in, a relative one taken from the project root. It makes it the one in use,
  ## remembers it, clears the table cache and refreshes the dock view
  var found: seq[string]
  let (o, code) = shell("git ls-files --cached --others --exclude-standard 2>/dev/null || find . -maxdepth 4 -type f")
  if code == 0:
    for l in o.splitLines:
      let f = l.strip
      if f.endsWith(".db") or f.endsWith(".sqlite") or f.endsWith(".sqlite3"): found.add f
  var path = ""
  if found.len > 0:
    let k = pick("Database", found & @["Another file…"])
    if k < 0: return
    path = if k < found.len: projectRoot() & "/" & found[k].strip(chars = {'.', '/'}, trailing = false) else: ""
  if path.len == 0: path = ask("The database file (a new name makes one)", "")
  if path.len == 0: return
  if not path.startsWith("/") and not path.startsWith("~"): path = projectRoot() & "/" & path
  dbPath = path
  remember(path)
  tableCache.setLen(0)
  let ts = tables()
  refreshView("SQLite")
  message("SQLite: " & path.split('/')[^1] & " — " & $ts.len & (if ts.len == 1: " table" else: " tables"))

func statementAt*(lines: seq[string], line, col: int): string =
  ## the SQL statement a place is in: from the `;` before it to the next one (or the text's ends)
  var off = 0
  var at = 0
  var all = ""
  for i, l in lines:
    if i == line: at = off + min(col, l.len)
    all.add l & "\n"
    off += l.len + 1
  var a = at
  while a > 0 and all[a - 1] != ';': dec a
  # (the cursor just after a `;`: the statement that ends there)
  if a == at and a > 0:
    dec a
    while a > 0 and all[a - 1] != ';': dec a
  var e = at
  while e < all.len and all[e] != ';': inc e
  all[a ..< min(e + 1, all.len)].strip

proc sqlInString(b: Buf): string =
  ## (not a .sql file) the string the cursor is in: "…" or """…"""
  let c = b.cursor
  let s = b.line(c.line)
  var a = c.col
  while a > 0 and s[a - 1] != '"': dec a
  var e = c.col
  while e < s.len and s[e] != '"': inc e
  if a > 0 and e < s.len: return s[a ..< e]
  ""

proc runAtCursor() =
  ## runs the SQL at the cursor on the database and shows the rows in the sqlite tab: the selection, else the statement
  ## the cursor is in (a .sql file) or the string it is in (any other file). A statement that changes the database
  ## (CREATE, DROP, ALTER, INSERT, UPDATE, DELETE, REPLACE) clears the table cache and refreshes the dock; a failure is
  ## also a warning with sqlite3's first line
  if not needDb(): return
  let b = current()
  var sql = ""
  let r = b.selection
  if not r.isEmpty: sql = b.textIn(r)
  elif b.lang == "sql" or b.path.endsWith(".sql"): sql = statementAt(b.lines, b.cursor.line, b.cursor.col)
  else: sql = sqlInString(b)
  if sql.strip.len == 0:
    message("No SQL here — select it, or put the cursor in a statement")
    return
  if not sql.strip.endsWith(";"): sql.add ";"
  let (o, code) = runSql(sql)
  let first = sql.strip.splitWhitespace
  let changes = first.len > 0 and first[0].toUpperAscii in ["CREATE", "DROP", "ALTER", "INSERT", "UPDATE", "DELETE",
                                                          "REPLACE"]
  if changes:
    tableCache.setLen(0)
    refreshView("SQLite")
  showRows(sql.strip.replace("\n", " "), (if o.strip.len == 0: (if code == 0: "(done)" else: "") else: o))
  if code != 0: warn("sqlite3: " & o.strip.splitLines[0])

proc showTable(name: string) =
  ## shows the first rows of the table (as many as plugins.sqlite.rows) in the sqlite tab
  if not needDb(): return
  let (o, _) = runSql("SELECT * FROM \"" & name.replace("\"", "\"\"") & "\" LIMIT " & $setting("rows", 200) & ";")
  showRows("SELECT * FROM " & name, o)

command "SQLite: open a database…":
  openDb()

command "SQLite: run the query at the cursor":
  runAtCursor()

command "SQLite: show a table…":
  if needDb():
    var names: seq[string]
    for (t, _) in tables(): names.add t
    if names.len == 0: message("The database has no tables yet")
    else:
      let k = pick("Table", names)
      if k >= 0: showTable(names[k])

command "SQLite: the schema":
  if needDb():
    let (o, _) = runSql(".schema", "")
    showRows(".schema", o)

proc dockItems(): seq[ViewItem] =
  ## the rows of the SQLITE view in the Plugins dock: the database's file name, under it each table (with its number of
  ## columns) and under each table its columns, a primary key marked with a star and the type with its flags in the
  ## detail
  if database().len == 0:
    return @[ViewItem(text: "no database open", detail: "SQLite: open a database…", icon: "·", color: "hint")]
  result.add ViewItem(text: database().split('/')[^1], detail: database(), icon: "▣", color: "accent")
  for (t, cols) in tables():
    result.add ViewItem(text: t, detail: $cols.len & " columns", icon: "▤", id: "t:" & t, depth: 1)
    for (c, typ, pk, nn) in cols:
      result.add ViewItem(text: c, icon: (if pk: "★" else: "·"), depth: 2, color: (if pk: "accent" else: ""),
                          detail: (typ & (if pk: " · primary key" else: "") & (if nn: " · not null" else: "")).strip)

proc dockClick(id: string) =
  ## a tap on a table in the dock view (its id starts with `t:`) shows that table's rows
  if id.startsWith("t:"): showTable(id[2 .. ^1])

view("SQLite", dockItems, dockClick)

proc sqlItems(b: Buf, p: Pos, prefix: string): seq[CompletionItem] =
  ## the database's tables and columns
  if database().len == 0: return
  for (t, cols) in tables():
    result.add CompletionItem(label: t, kind: "class", detail: "table · " & database().split('/')[^1])
    for (c, typ, pk, _) in cols:
      result.add CompletionItem(label: c, kind: "field", detail: t & "." & c & (if typ.len > 0: " " & typ else: "") &
                                (if pk: " (primary key)" else: ""))

completions("sql", sqlItems)
