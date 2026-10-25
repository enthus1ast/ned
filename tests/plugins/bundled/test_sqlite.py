"""sqlite: a database opened (remembered), the query at the cursor and in a selection run, the rows in a tab, a
table's rows, the schema, the dock's tables and columns, completion in .sql files — with a pretend sqlite3 (Python's
own SQLite behind it) where there is none"""
import os, shutil, stat, tempfile
from tplugins import check

FAKE = r'''#!/usr/bin/env python3
# a pretend sqlite3: -bail -header (-box | -column | -list -noheader | "") DB < sql
import sqlite3, sys
args = sys.argv[1:]
db = [a for a in args if not a.startswith("-")][-1]
listmode = "-list" in args
header = "-noheader" not in args
sql = sys.stdin.read()
con = sqlite3.connect(db)
if sql.strip() == ".schema":
    for (s,) in con.execute("SELECT sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY name"):
        print(s + ";")
    sys.exit(0)
try:
    cur = con.cursor()
    for stmt in [s for s in sql.split(";") if s.strip()]:
        cur.execute(stmt)
        rows = cur.fetchall()
        if cur.description:
            names = [d[0] for d in cur.description]
            if listmode:
                if header: print("|".join(names))
                for r in rows: print("|".join("" if v is None else str(v) for v in r))
            else:
                if header: print(" | ".join(names))
                for r in rows: print(" | ".join("" if v is None else str(v) for v in r))
    con.commit()
except sqlite3.Error as e:
    print("Parse error: " + str(e))
    sys.exit(1)
'''


def pos(l, c):
    return {"line": l, "col": c}


def tabs_kept(h):
    """newTab makes a buffer of its own (setText on it changes it, not the file in front), as in ned"""
    base = h.api

    def api(j, _base=base):
        if j["fn"] == "newTab":
            a = j.get("args", {})
            bid = 100 + len(h.tabs) + 1
            h.tabs.append((a.get("title", ""), a.get("text", ""), a.get("lang", "")))
            h.others[bid] = {"lines": a.get("text", "").split("\n"), "path": "", "title": a.get("title", ""),
                             "lang": a.get("lang") or "plaintext", "cursor": {"line": 0, "col": 0}}
            h.send({"t": "res", "id": j["id"], "value": bid})
            return
        return _base(j)
    h.api = api


def tab_text(h, title):
    for bid, st in h.others.items():
        if st.get("title") == title:
            return "\n".join(st["lines"])
    return ""


def run(factory, tag):
    tmp = tempfile.mkdtemp(prefix="ned-sqlite-")
    try:
        _run(factory, tag, tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _run(factory, tag, tmp):
    import sqlite3
    h = factory()
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return
    ok = h.pump(lambda j: j.get("t") == "ready", 60)
    check(tag + "it starts", ok)
    if not ok:
        return
    tabs_kept(h)
    bin_ = os.path.join(tmp, "bin")
    os.makedirs(bin_)
    fake = os.path.join(bin_, "sqlite3")
    open(fake, "w").write(FAKE)
    os.chmod(fake, os.stat(fake).st_mode | stat.S_IEXEC)
    h.settings["program"] = fake
    db = os.path.join(h.root, "app.db")
    con = sqlite3.connect(db)
    con.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INT)")
    con.executemany("INSERT INTO users (name, age) VALUES (?, ?)", [("ann", 31), ("bob", 4)])
    con.commit()
    con.close()
    titles = ["SQLite: open a database…", "SQLite: run the query at the cursor", "SQLite: show a table…",
              "SQLite: the schema"]
    cmds = {t: h.reg("command", title=t) for t in titles}
    check(tag + "its commands, its dock view, its completions for .sql",
          all(cmds.values()) and h.reg("view", title="SQLite") is not None and
          h.reg("completion", lang="sql") is not None, [t for t, c in cmds.items() if not c])
    if not all(cmds.values()):
        return
    # not opened yet: said
    h.messages = []
    h.call(cmds["SQLite: run the query at the cursor"]["cb"])
    check(tag + "no database yet: said", any("Open a database first" in m for m in h.messages), h.messages)
    # open: the project's .db offered (git ls-files or find), picked
    h.answers["pick"] = 0
    h.call(cmds["SQLite: open a database…"]["cb"])
    check(tag + "open: app.db, its one table said", any("app.db — 1 table" in m for m in h.messages), h.messages)
    # the query at the cursor: the statement between the `;`s, the rows in a tab
    h.lang = "sql"
    h.path_ = os.path.join(h.root, "q.sql")
    h.lines = ["SELECT 1;", "SELECT name, age", "FROM users", "WHERE age > 10;", "SELECT 2;"]
    h.cursor = pos(2, 3)
    h.sel = None
    h.tabs = []
    h.call(cmds["SQLite: run the query at the cursor"]["cb"])
    t = tab_text(h, "sqlite: app.db")
    check(tag + "the statement the cursor is in, its rows in a tab (\"sqlite: app.db\")",
          h.tabs and h.tabs[-1][0] == "sqlite: app.db" and "name | age" in t and "ann | 31" in t and "bob" not in t, t)
    # a selection; a statement that changes the database refreshes the tables
    h.lines = ["CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT);"]
    h.sel = {"start": pos(0, 0), "stop": pos(0, 55)}
    h.call(cmds["SQLite: run the query at the cursor"]["cb"])
    h.sel = None
    items = h.call(h.reg("view", title="SQLite")["cb"], {})
    vi = (items or {}).get("value") or []
    names = [(x.get("text"), x.get("depth")) for x in vi]
    check(tag + "the dock: the database, its tables (the new one too) with their columns",
          ("notes", 1) in names and ("users", 1) in names and ("name", 2) in names, names)
    star = [x for x in vi if x.get("text") == "id" and x.get("icon") == "★"]
    check(tag + "… a primary key starred, not null said", star and any(
        x.get("text") == "name" and "not null" in x.get("detail", "") for x in vi), vi[:6])
    # completion in .sql
    r = h.call(h.reg("completion", lang="sql")["cb"], {"buf": 1, "pos": pos(0, 0), "prefix": "us"})
    labels = [x.get("label") for x in (r or {}).get("value") or []]
    check(tag + "completion: tables and columns", "users" in labels and "age" in labels and "body" in labels, labels)
    # a table's rows, the schema
    h.answers["pick"] = 1
    h.call(cmds["SQLite: show a table…"]["cb"])
    t = tab_text(h, "sqlite: app.db")
    check(tag + "show a table: its rows, over the rows before (one tab)", t.startswith("-- SELECT * FROM users") and
          "ann" in t and "-- SELECT name, age" in t and len(h.tabs) == 1, t[:300])
    h.call(cmds["SQLite: the schema"]["cb"])
    check(tag + "the schema: the CREATE statements", "CREATE TABLE users" in tab_text(h, "sqlite: app.db"),
          tab_text(h, "sqlite: app.db")[:200])
    # remembered for the project
    h2 = factory()
    ok2 = h2.build_ok and h2.pump(lambda j: j.get("t") == "ready", 60)
    if ok2:
        tabs_kept(h2)
        h2.root = h.root
        h2.tmp = h.tmp
        h2.settings["program"] = fake
        h2.lang = "sql"
        h2.lines = ["SELECT count(*) AS n FROM users;"]
        h2.cursor = pos(0, 3)
        h2.tabs = []
        h2.call(h2.reg("command", title="SQLite: run the query at the cursor")["cb"])
        t2 = tab_text(h2, "sqlite: app.db")
        check(tag + "the database is remembered (another session, the same project)", "n" in t2 and "2" in t2, t2)
