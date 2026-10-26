"""db-client: the statement at the cursor (or the selection, or the file) run with psql or mysql — no database needed:
pretend clients record the command line and the script they get and answer with canned output (as psql 16 and
mysql --batch write it). Checked: the connections (chosen per project, a password in a url left out), the splitting
of statements (strings, comments, $$, backticks, DELIMITER), the command line, the parsing of rows, command tags,
notices and errors (their line and column in the file, in Problems), the table and CSV tabs, the troubles said"""
import json
import os
import stat
from tplugins import check
from tbundled import run_jobs

FAKE = r'''#!/usr/bin/env python3
# a pretend psql / mysql: what it was given goes to calls.jsonl, its answer comes from next.json
import json, os, sys
here = os.path.dirname(os.path.abspath(__file__))
args = sys.argv[1:]
script = open(args[args.index("-f") + 1]).read() if "-f" in args else sys.stdin.read()
with open(os.path.join(here, "calls.jsonl"), "a") as f:
    f.write(json.dumps({"prog": os.path.basename(sys.argv[0]), "args": args, "script": script,
                        "timeout": os.environ.get("PGCONNECT_TIMEOUT")}) + "\n")
nxt = json.load(open(os.path.join(here, "next.json")))
sys.stdout.write(nxt["out"])
sys.stderr.write(nxt["err"])
sys.exit(nxt["code"])
'''


def pos(l, c):
    return {"line": l, "col": c}


def rng(l0, c0, l1, c1):
    return {"start": pos(l0, c0), "stop": pos(l1, c1)}


PG_FILE = [
    "-- the users",                                              # 0
    "SELECT 1;",                                                 # 1
    "SELECT name, note",                                         # 2
    "FROM t; -- a ; in a comment",                               # 3
    "INSERT INTO t VALUES ('a;b', $$x;y$$, E'it\\'s;');",        # 4
    "/* block ; */ SELECT * FORM t",                             # 5
    "WHERE id = 1;",                                             # 6
]

MY_FILE = [
    "SELECT 'it\\'s; fine' AS `a;b`, \"x\" # c;",                # 0
    ";",                                                         # 1
    "DELIMITER //",                                              # 2
    "CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END //",     # 3
    "DELIMITER ;",                                               # 4
    "UPDATE t SET a = 1 WHERE b = 2;",                           # 5
    "  SELECT * FORM t;",                                        # 6
]


def run(factory, tag):
    h = factory()
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return
    ok = h.pump(lambda j: j.get("t") == "ready", 60)
    check(tag + "it starts", ok, "" if ok else h.p.stderr.read()[-1500:])
    if not ok:
        return
    titles = ["DB: run the statement at the cursor", "DB: run the whole file", "DB: choose a connection…",
              "DB: cancel the query"]
    c = {t: h.reg("command", title=t) for t in titles}
    key = h.reg("langKey", lang="sql", keys="ctrl+enter")
    sets = {k: (h.reg("setting", key=k) or {}).get("default") for k in ["connections", "format", "maxRows", "psql", "mysql"]}
    check(tag + "its commands, Ctrl+Enter and <leader>r in .sql files, its settings",
          all(c.values()) and key and h.reg("vimMap", mode="n", keys="<leader>r", lang="sql") and
          h.reg("vimMap", mode="v", keys="<leader>r", lang="sql") and
          sets == {"connections": "", "format": "table", "maxRows": 500, "psql": "psql", "mysql": "mysql"}, sets)
    src = open(os.path.join(os.path.dirname(__file__), "..", "..", "..", "plugins", "db-client", "plugin.nims")).read()
    check(tag + "it asks to run programs, saying why", 'permission("shell", "' in src, "")

    bin_ = os.path.join(h.tmp, "bin")
    os.makedirs(bin_)
    for p in ["psql", "mysql"]:
        f = os.path.join(bin_, p)
        open(f, "w").write(FAKE)
        os.chmod(f, os.stat(f).st_mode | stat.S_IEXEC)
    calls = os.path.join(bin_, "calls.jsonl")

    def answer(out="", err="", code=0):
        json.dump({"out": out, "err": err, "code": code}, open(os.path.join(bin_, "next.json"), "w"))

    def last_call():
        if not os.path.exists(calls): return {}
        return [json.loads(l) for l in open(calls)][-1]

    def ncalls():
        return len(open(calls).readlines()) if os.path.exists(calls) else 0

    def run_(t, lines=None, cursor=None, sel=None, lang="sql", path="q.sql"):
        if lines is not None: h.lines = list(lines)
        h.lang = lang
        h.path_ = os.path.join(h.root, path)
        h.cursor = cursor or pos(0, 0)
        h.sel = sel
        h.call(c[t]["cb"])
        run_jobs(h)

    def tab(title):
        ts = [x for x in h.tabs if x[0] == title]
        return ts[-1][1] if ts else ""

    # no connections yet
    run_("DB: run the statement at the cursor", PG_FILE, pos(1, 2))
    check(tag + "no connections: how to add one, and nothing run", "no connections yet" in h.messages[-1] and
          'plugins.db-client.connections: [{"name": "dev"' in h.messages[-1] and ncalls() == 0, h.messages[-1:])
    conns = [{"name": "dev", "url": "postgres://ann:secret@db.example:5433/app?sslmode=require"},
             {"name": "shop", "url": "mysql://bob@127.0.0.1:3307/shop?socket=/tmp/my.sock"},
             {"name": "old", "url": "oracle://x@y/z"}]
    h.settings = {"connections": conns, "psql": os.path.join(bin_, "psql"), "mysql": os.path.join(bin_, "mysql")}
    # several connections, none chosen: asked; the choice kept for the project
    h.answers["pick"] = 0
    answer("\x1e1\nname,note\nann,NULL\n\"bob, \"\"the\"\" builder\",\"two\nlines\"\n")
    run_("DB: run the statement at the cursor", PG_FILE, pos(2, 3))
    a = h.asked[-1][1] if h.asked else {}
    chosen = json.load(open(os.path.join(h.tmp, "data", "db-client", "chosen.json")))
    check(tag + "several connections, none chosen: asked (each with its url, no password); kept for the project",
          a.get("title") == "DB: which connection?" and a.get("items") == ["dev", "shop", "old"] and
          a.get("details", [])[:2] == ["postgres://ann@db.example:5433/app?sslmode=require",
                                       "mysql://bob@127.0.0.1:3307/shop?socket=/tmp/my.sock"] and
          "is not a database this plugin knows" in a.get("details", ["", "", ""])[2] and chosen == {h.root: "dev"} and
          h.status == "DB: dev", (a, chosen))
    call = last_call()
    script_file = os.path.join(h.tmp, "data", "db-client", "run", "query.sql")
    check(tag + "psql's command line: no psqlrc, no password prompt, stop at an error, CSV, NULL, the url without " +
          "its password, the script; a connect timeout",
          call.get("args") == ["-X", "-w", "-v", "ON_ERROR_STOP=1", "--csv", "-P", "null=NULL", "-d",
                               "postgres://ann@db.example:5433/app?sslmode=require", "-f", script_file] and
          call.get("timeout") == "10" and "secret" not in json.dumps(call), call.get("args"))
    check(tag + "… the password in the url: not used, and said so", any("password in dev's url is not used" in m and
          "~/.pgpass or PGPASSWORD" in m for m in h.messages), h.messages[-3:])
    check(tag + "the statement the cursor is in (not at the ; in the comment after it), marked for psql",
          call.get("script") == "\\echo '\\x1e1'\nSELECT name, note\nFROM t\n;\n", call.get("script"))
    t = tab("DB: dev")
    check(tag + "the rows in a tab \"DB: dev\": its line and words, an aligned table, NULL, ↵, how many rows",
          t.split("\n")[0].startswith("-- dev · postgres · ") and
          "\n\n-- line 3: SELECT name, note\n name               | note\n--------------------+-----------\n" +
          " ann                | NULL\n bob, \"the\" builder | two↵lines\n(2 rows)\n" in t and
          h.messages[-1] == "DB: dev — 1 statement, 2 rows" and h.tabs[-1][2] == "sql", t)
    # the whole file: each statement, a command tag, a notice, an error with its line and column
    err = ("psql:%s:10: NOTICE:  a notice\n" % script_file +
           "psql:%s:14: ERROR:  syntax error at or near \"FORM\"\n" % script_file +
           "LINE 1: SELECT * FORM t\n                 ^\n")
    answer("\x1e1\n?column?\n1\n\x1e2\nname,note\nann,NULL\n\x1e3\nINSERT 0 1\n\x1e4\n", err, 3)
    run_("DB: run the whole file", PG_FILE)
    call = last_call()
    check(tag + "the whole file: split at each ; but not in strings, comments, $$…$$ or E'…\\'…'",
          call.get("script") == "\\echo '\\x1e1'\nSELECT 1\n;\n\\echo '\\x1e2'\nSELECT name, note\nFROM t\n;\n" +
          "\\echo '\\x1e3'\nINSERT INTO t VALUES ('a;b', $$x;y$$, E'it\\'s;')\n;\n" +
          "\\echo '\\x1e4'\nSELECT * FORM t\nWHERE id = 1\n;\n", call.get("script"))
    t = tab("DB: dev")
    check(tag + "… each statement's result: rows, INSERT 0 1 with its notice, the error and where it is",
          "-- line 2: SELECT 1\n ?column?\n----------\n        1\n(1 row)" in t and
          "-- line 5: INSERT INTO t VALUES ('a;b', $$x;y$$, E'it\\'s;')\nNOTICE: a notice\nINSERT 0 1" in t and
          "-- line 6: SELECT * FORM t\nERROR:  syntax error at or near \"FORM\"  (line 6, column 24)" in t, t)
    probs = h.problems or []
    check(tag + "… the error in Problems, on FORM; in the status line with its line",
          len(probs) == 1 and probs[0]["range"] == rng(5, 23, 5, 27) and probs[0]["severity"] == 1 and
          h.messages[-1] == "DB: line 6: syntax error at or near \"FORM\"", (probs, h.messages[-1:]))
    # an error on a later line of a statement, a hint; the next statements not run
    err = ("psql:%s:4: ERROR:  column \"nme\" does not exist\n" % script_file +
           "LINE 2: FROM t WHERE nme = 1\n                     ^\nHINT:  Perhaps you meant to reference the column \"t.name\".\n")
    answer("\x1e1\n", err, 3)
    run_("DB: run the statement at the cursor", ["SELECT name", "FROM t WHERE nme = 1;", "SELECT 2;"],
         sel=rng(0, 0, 2, 9))
    t = tab("DB: dev")
    check(tag + "a selection: its statements; an error on the second line of one, with its hint; the rest not run",
          last_call()["script"].count("\\echo") == 2 and
          "ERROR:  column \"nme\" does not exist — Perhaps you meant to reference the column \"t.name\".  (line 2, column 14)"
          in t and "-- line 3: SELECT 2\n(not run: the error before it stopped the rest)" in t and
          h.problems[0]["range"] == rng(1, 13, 1, 16), (t, h.problems))
    answer("\x1e1\nid\n\x1e2\nUPDATE 0\n\x1e3\nCREATE TABLE\n")
    run_("DB: run the whole file", ["SELECT id FROM t WHERE false;", "UPDATE t SET a = 1 WHERE false;",
                                    "CREATE TABLE x (a int);"])
    t = tab("DB: dev")
    check(tag + "no rows: the header and (0 rows); UPDATE 0; CREATE TABLE; the problems cleared",
          " id\n----\n(0 rows)" in t and "\nUPDATE 0\n" in t and t.endswith("CREATE TABLE\n") and h.problems == [], t)
    # maxRows, CSV
    rows = "".join("%d,x\n" % i for i in range(5))
    answer("\x1e1\nn,s\n" + rows)
    h.settings["maxRows"] = 3
    run_("DB: run the statement at the cursor", ["SELECT n, s FROM t;"], pos(0, 1))
    check(tag + "maxRows: the first rows only, said", "(5 rows — the first 3 shown: plugins.db-client.maxRows)" in
          tab("DB: dev") and " 2 | x\n(5" in tab("DB: dev"), tab("DB: dev"))
    del h.settings["maxRows"]
    h.settings["format"] = "csv"
    answer("\x1e1\nname,note\nann,NULL\n\"bob, \"\"the\"\" builder\",\"two\nlines\"\n,\n\x1e2\nb\n2\n")
    run_("DB: run the whole file", ["SELECT name, note FROM t;", "SELECT 2 AS b;"])
    check(tag + "format csv: a tab of CSV for each result (NULL empty, an empty text \"\")",
          tab("DB: dev.csv") == 'name,note\nann,\n"bob, ""the"" builder","two\nlines"\n"",""\n' and
          tab("DB: dev (2).csv") == "b\n2\n" and h.tabs[-1][2] == "csv", h.tabs[-2:])
    del h.settings["format"]
    # troubles: the connection, the password, no client
    answer("", "psql: error: connection to server at \"db.example\" (10.0.0.1), port 5433 failed: FATAL:  " +
           "password authentication failed for user \"ann\"\n", 2)
    n = len(h.tabs)
    run_("DB: run the statement at the cursor", ["SELECT 1;"], pos(0, 1))
    check(tag + "a connection that fails: said, with where the password goes; no tab",
          h.messages[-1].startswith("DB: dev: connection to server at \"db.example\"") and
          "password authentication failed" in h.messages[-1] and "~/.pgpass" in h.messages[-1] and len(h.tabs) == n,
          h.messages[-1:])
    answer("", "sh: 1: psql: not found\n", 127)
    run_("DB: run the statement at the cursor", ["SELECT 1;"], pos(0, 1))
    check(tag + "no psql: how to install it", "is not installed" in h.messages[-1] and "pkg install postgresql" in
          h.messages[-1], h.messages[-1:])
    # where the cursor is
    run_("DB: run the statement at the cursor", ["SELECT 1;", "", "SELECT 2;"], pos(1, 0))
    check(tag + "the cursor between statements: said", h.messages[-1] == "DB: the cursor is not in a statement",
          h.messages[-1:])
    k = ncalls()
    answer("\x1e1\n?column?\n1\n")
    run_("DB: run the statement at the cursor", ["SELECT 1;  ", "SELECT 2;"], pos(0, 11))
    check(tag + "… right after a statement's ; on its line: that one", last_call()["script"].endswith("SELECT 1\n;\n") and
          ncalls() == k + 1, last_call().get("script"))
    run_("DB: run the statement at the cursor", ["x = 'SELECT 1'"], pos(0, 3), lang="python", path="a.py")
    check(tag + "another file, nothing selected: select the SQL, it says", h.messages[-1].startswith("DB: select the SQL"),
          h.messages[-1:])
    answer("\x1e1\nx\n1\n")
    run_("DB: run the statement at the cursor", ["q = '''SELECT 1 AS x'''"], lang="python", path="a.py",
         sel=rng(0, 7, 0, 20))
    check(tag + "… a selection in it: run", last_call()["script"] == "\\echo '\\x1e1'\nSELECT 1 AS x\n;\n",
          last_call()["script"])
    # Ctrl+Enter, vim
    answer("\x1e1\n?column?\n7\n")
    h.lines = ["SELECT 7;"]
    h.cursor = pos(0, 2)
    h.sel = None
    h.lang = "sql"
    h.call(key["cb"], {"buf": 1})
    run_jobs(h)
    check(tag + "Ctrl+Enter in a .sql file: the statement at the cursor", last_call()["script"].endswith("SELECT 7\n;\n"),
          last_call()["script"])
    # one still running; cancel
    h.call(c["DB: run the statement at the cursor"]["cb"])
    h.call(c["DB: run the statement at the cursor"]["cb"])
    check(tag + "a query still running: a second one waits for it (DB: cancel the query)",
          h.messages[-1] == "DB: a query is still running (DB: cancel the query)" and len(h.jobs) == 1, h.messages[-1:])
    h.call(c["DB: cancel the query"]["cb"])
    run_jobs(h)
    check(tag + "… cancelled: said", h.messages[-1] == "DB: the query was cancelled", h.messages[-1:])
    h.call(c["DB: cancel the query"]["cb"])
    check(tag + "… nothing running: said", h.messages[-1] == "DB: no query is running", h.messages[-1:])

    # MySQL: choose it; backslashes, backticks, # comments, DELIMITER; mysql's batch output and its error
    h.answers["pick"] = 1
    h.call(c["DB: choose a connection…"]["cb"])
    check(tag + "choose a connection: the one in use marked; the status bar says it",
          h.asked[-1][1]["items"] == ["dev  ●", "shop", "old"] and h.status == "DB: shop" and
          json.load(open(os.path.join(h.tmp, "data", "db-client", "chosen.json"))) == {h.root: "shop"}, h.asked[-1][1])
    out = ("a;b\tx\nit's\\nfine\tx\nned_marker\tned_rows\n\x1e1\t-1\n" +
           "ned_marker\tned_rows\n\x1e2\t0\nned_marker\tned_rows\n\x1e3\t2\n")
    err = ("ERROR 1064 (42000) at line 11: You have an error in your SQL syntax; check the manual that corresponds to " +
           "your MySQL server version for the right syntax to use near 'FORM t' at line 1\n")
    answer(out, err, 1)
    run_("DB: run the whole file", MY_FILE, path="m.sql")
    call = last_call()
    check(tag + "mysql's command line: batch, the host, port, user, socket and database; the script on its stdin",
          call.get("prog") == "mysql" and call.get("args") == ["--batch", "--connect-timeout=10", "--host=127.0.0.1",
                                                               "--port=3307", "--user=bob", "--socket=/tmp/my.sock",
                                                               "--database=shop"], call.get("args"))
    check(tag + "… split as mysql does (\\' in strings, `a;b`, # comments, DELIMITER //), each followed by its mark",
          call.get("script") == "DELIMITER $$ned$$\n" +
          "SELECT 'it\\'s; fine' AS `a;b`, \"x\" # c;\n$$ned$$\nSELECT '\x1e1' AS ned_marker, ROW_COUNT() AS ned_rows$$ned$$\n" +
          "CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END\n$$ned$$\nSELECT '\x1e2' AS ned_marker, ROW_COUNT() AS ned_rows$$ned$$\n" +
          "UPDATE t SET a = 1 WHERE b = 2\n$$ned$$\nSELECT '\x1e3' AS ned_marker, ROW_COUNT() AS ned_rows$$ned$$\n" +
          "SELECT * FORM t\n$$ned$$\nSELECT '\x1e4' AS ned_marker, ROW_COUNT() AS ned_rows$$ned$$\n", call.get("script"))
    t = tab("DB: shop")
    check(tag + "… its rows (\\n back to a line end), rows affected, the error at its line and column",
          t.split("\n")[0].startswith("-- shop · mysql · ") and
          " a;b       | x\n-----------+---\n it's↵fine | x\n(1 row)" in t and
          "-- line 4: CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END\n0 rows affected" in t and
          "-- line 6: UPDATE t SET a = 1 WHERE b = 2\n2 rows affected" in t and
          "-- line 7: SELECT * FORM t\nERROR:  You have an error in your SQL syntax;" in t and
          "near 'FORM t' at line 1  (line 7, column 12)" in t, t)
    check(tag + "… in Problems: FORM", h.problems and h.problems[0]["range"] == rng(6, 11, 6, 15), h.problems)
    answer("", "ERROR 1045 (28000): Access denied for user 'bob'@'localhost' (using password: NO)\n", 1)
    run_("DB: run the statement at the cursor", ["SELECT 1;"], pos(0, 1))
    check(tag + "… access denied: said, with where the password goes", h.messages[-1].startswith(
          "DB: shop: Access denied for user 'bob'@'localhost'") and "MYSQL_PWD" in h.messages[-1] and
          "~/.my.cnf" in h.messages[-1], h.messages[-1:])
    # a url that is not one; the connections written as a string
    h.answers["pick"] = 2
    h.call(c["DB: choose a connection…"]["cb"])
    run_("DB: run the statement at the cursor", ["SELECT 1;"], pos(0, 1))
    check(tag + "a url of another database: said, nothing run", "old: oracle:// is not a database this plugin knows"
          in h.messages[-1], h.messages[-1:])
    h.settings["connections"] = json.dumps([{"name": "one", "url": "postgresql://me@[::1]:5432/db"}])
    answer("\x1e1\n?column?\n1\n")
    run_("DB: run the statement at the cursor", ["SELECT 1;"], pos(0, 1))
    check(tag + "the connections as a string of JSON; one connection: used without asking (an IPv6 host)",
          last_call()["args"][8] == "postgresql://me@[::1]:5432/db" and h.messages[-1] == "DB: one — 1 statement, 1 row",
          (last_call().get("args"), h.messages[-1:]))
