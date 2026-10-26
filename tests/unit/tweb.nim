## ned's own CSS, HTML and SQL engines: what the cursor is in, what is offered there, the hover, the problems
## found (and not found where there are none). Run: nim r tests/unit/tweb.nim

import std/[unittest, strutils, sequtils, tables]
import ../../src/ned/web/web

proc labels(items: seq[WebItem]): seq[string] = items.mapIt(it.label)

proc at(text: string): (seq[string], int, int) =
  ## the text with a | where the cursor is: (lines, line, column)
  let ls = text.split('\n')
  for l, s in ls:
    let c = s.find('|')
    if c >= 0:
      var ls2 = ls
      ls2[l] = s[0 ..< c] & s[c + 1 .. ^1]
      return (ls2, l, c)
  doAssert false, "no | in the text"

suite "CSS":
  test "where the cursor is":
    var (ls, l, c) = at("a {\n  colo|\n}")
    check cssContext(ls, l, c).kind == ccProperty
    (ls, l, c) = at("a {\n  display: fl|\n}")
    let cx = cssContext(ls, l, c)
    check cx.kind == ccValue
    check cx.prop == "display"
    check cx.word == "fl"
    (ls, l, c) = at("a:ho| {}")
    check cssContext(ls, l, c).kind == ccPseudo
    (ls, l, c) = at("@me|")
    check cssContext(ls, l, c).kind == ccAtRule
    (ls, l, c) = at("a { width: 10p| }")
    check cssContext(ls, l, c).kind == ccUnit
    (ls, l, c) = at("/* a { colo| */")
    check cssContext(ls, l, c).kind == ccNone
    (ls, l, c) = at("@media (min-width: 1px) {\n  .x|\n}")
    check cssContext(ls, l, c).kind == ccClass
    (ls, l, c) = at("a { color: var(--|) }")
    check cssContext(ls, l, c).kind == ccVar

  test "what fits there":
    var (ls, l, c) = at("a {\n  display: |\n}")
    let vals = cssComplete(ls, l, c)[1].labels
    check "flex" in vals
    check "grid" in vals
    check "inherit" in vals
    (ls, l, c) = at("a {\n  col|\n}")
    let props = cssComplete(ls, l, c)[1]
    check props.anyIt(it.label == "color" and it.snippet == "color: $0")
    (ls, l, c) = at(":root { --gap: 4px; }\na { margin: var(--|) }")
    check "--gap" in cssComplete(ls, l, c)[1].labels
    (ls, l, c) = at("a { color: r| }")
    check "red" in cssComplete(ls, l, c)[1].labels
    (ls, l, c) = at(".|")
    check "card" in cssComplete(ls, l, c, classes = @["card"])[1].labels

  test "hover":
    let (ls, l, c) = at("a {\n  dis|play: flex;\n}")
    check "display" in cssHover(ls, l, c)
    check cssHover(@["a { color: red; }"], 0, 12).contains("named")

  test "problems":
    let ok = cssChecks(@["a {", "  color: red;", "  display: flex;", "}", "@media (max-width: 2px) {", "  a { margin: 0 }",
                         "}"])
    check ok.len == 0
    let typo = cssChecks(@["a {", "  colr: red;", "}"])
    check typo.len == 1
    check typo[0].rule == "css-property"
    check "color" in typo[0].msg
    check typo[0].line == 1 and typo[0].col == 2
    let val = cssChecks(@["a { display: flexx; }"])
    check val.len == 1 and val[0].rule == "css-value" and "flex" in val[0].msg
    let semi = cssChecks(@["a {", "  color: red", "  margin: 0;", "}"])
    check semi.anyIt(it.rule == "css-semicolon" and it.line == 1)
    let brace = cssChecks(@["a { color: red; }", "}"])
    check brace.anyIt(it.rule == "css-brace")
    check cssChecks(@["a { color: red;"]).anyIt(it.rule == "css-brace")
    check cssChecks(@["a { color: red;"], strict = false).len == 0
    check cssChecks(@["a { -webkit-appearance: none; --x: 1; }"]).len == 0
    check cssChecks(@["a {", "  &:hover { color: red; }", "  .b { margin: 0 }", "}"]).len == 0

  test "custom properties: a typo of one the sheet sets":
    let vs = cssChecks(@[":root { --primary: #333; --gap: 4px; }", "a { color: var(--primay); margin: var(--gap); }"])
    check vs.len == 1 and vs[0].rule == "css-var" and "--primary" in vs[0].msg and vs[0].line == 1
    check vs[0].col == "a { color: var(".len
    # (one set nowhere near: another sheet may set it; a sheet that sets none: nothing to compare with)
    check cssChecks(@[":root { --primary: #333; }", "a { color: var(--brand-accent); }"]).len == 0
    check cssChecks(@["a { color: var(--primay); }"]).len == 0
    check cssChecks(@[":root { --_fa-family: x; }", "a { font-family: var(--fa-family, var(--_fa-family)); }"]).len == 0
    check cssChecks(@["/* --primay: x */ :root { --primary: 1; }", "a { color: var(--primary) }"]).len == 0

suite "HTML":
  test "where the cursor is":
    var (ls, l, c) = at("<di|")
    check htmlContext(ls, l, c).kind == hcTagName
    (ls, l, c) = at("<div>\n  <p>hi</|")
    let cx = htmlContext(ls, l, c)
    check cx.kind == hcCloseTag
    (ls, l, c) = at("<a hr|")
    check htmlContext(ls, l, c).kind == hcAttrName
    (ls, l, c) = at("<input type=\"te|\">")
    let v = htmlContext(ls, l, c)
    check v.kind == hcAttrValue
    check v.attr == "type"
    check v.tag == "input"
    (ls, l, c) = at("<p>some text|</p>")
    check htmlContext(ls, l, c).kind == hcText

  test "what fits there":
    var (ls, l, c) = at("<div>\n  <span>x</|")
    check htmlComplete(ls, l, c)[1].labels[0] == "span"
    (ls, l, c) = at("<a |")
    let attrs = htmlComplete(ls, l, c)[1]
    check attrs.anyIt(it.label == "href" and it.rank == 0)
    check attrs.anyIt(it.label == "class")
    (ls, l, c) = at("<input type=\"|\">")
    check "checkbox" in htmlComplete(ls, l, c)[1].labels
    (ls, l, c) = at("<div class=\"|\">")
    check "card" in htmlComplete(ls, l, c, classes = @["card"])[1].labels

  test "hover":
    check "element" in htmlHover(@["<section>"], 0, 3)

  test "problems":
    check htmlChecks(@["<!DOCTYPE html>", "<html><body>", "<ul><li>a<li>b</ul>", "<p>one<p>two", "<img src=a alt=''>",
                       "<br>", "</body></html>"]).len == 0
    let wrong = htmlChecks(@["<div>", "  <span>x</div>"])
    check wrong.anyIt(it.rule == "html-close" and "span" in it.msg)
    check htmlChecks(@["</div>"]).anyIt(it.sev == 1 and "closes nothing" in it.msg)
    check htmlChecks(@["<div>"]).anyIt("never closed" in it.msg)
    check htmlChecks(@["<p id=a></p><p id=a></p>"]).anyIt(it.rule == "html-id")
    check htmlChecks(@["<dvi></dvi>"]).anyIt(it.rule == "html-element" and "div" in it.msg)
    check htmlChecks(@["<my-widget></my-widget>", "<svg><circle/><foo/></svg>"]).len == 0
    check htmlChecks(@["<div>"], fragment = true).len == 0
    check htmlChecks(@["<script>if (a < b) { x = '</p>' }</script>"]).len == 0

  test "links in the page, attributes":
    let a = htmlChecks(@["<!doctype html><a href=\"#intro\">x</a> <a href=\"#intr\">y</a> <a href=\"#top\">t</a> <a href=\"#\">z</a>",
                         "<h2 id=\"intro\">I</h2> <a name=\"old\"></a> <a href=\"#old\">o</a>"])
    check a.len == 1 and a[0].rule == "html-anchor" and "'#intro'?" in a[0].msg and a[0].col == "<!doctype html><a href=\"#intro\">x</a> <a href=\"".len
    # (a piece of a page — no doctype, <html> or <body> —, a page whose script makes ids: its links are not judged)
    check htmlChecks(@["<h2 id=\"a\">A</h2> <a href=\"#MethodName\">m</a>"]).allIt(it.rule != "html-anchor")
    check htmlChecks(@["<!doctype html><body><a href=\"#made\">m</a>",
                       "<script>const h = document.createElement('h2'); h.id = 'made';</script></body>"]).len == 0
    check htmlChecks(@["<!doctype html><body><a href=\"#gone\">m</a>",
                       "<script type=\"application/ld+json\">{\"innerHTML\": 1}</script></body>"]).anyIt(it.rule == "html-anchor")
    let t = htmlChecks(@["<div clas=\"a\" class=\"b\" data-x=1 hx-get=\"/a\" v-if=\"ok\"></div>",
                         "<img src=a.png alt=\"\" widht=3>", "<my-el foo=1></my-el>"])
    check t.len == 2 and t.allIt(it.rule == "html-attribute")
    check "'class'?" in t[0].msg and "'width'?" in t[1].msg
    check htmlChecks(@["<input type=\"text\" placeholder=\"a\" autofocus>"]).len == 0

  test "the files a page links to":
    let rs = htmlLocalRefs(@["<link href=\"style.css?v=2\" rel=stylesheet><script src=\"./js/app.js\"></script>",
                             "<a href=\"https://x.org/a\">x</a> <a href=\"mailto:a@b\">m</a> <a href=\"/root.html\">r</a>",
                             "<img src=\"pics/a%20b.png#x\" alt=\"\"> <a href=\"{{ url }}\">t</a> <a href=\"#id\">i</a>"])
    check rs.len == 3
    check rs[0][3] == "style.css" and rs[0][0] == 0 and rs[0][1] == "<link href=\"".len
    check rs[1][3] == "./js/app.js"
    check rs[2][3] == "pics/a%20b.png" and rs[2][0] == 2

suite "SQL":
  let schema = block:
    var sc: SqlSchema
    sc.addCreates(@["CREATE TABLE users (", "  id INTEGER PRIMARY KEY,", "  name TEXT NOT NULL,", "  email VARCHAR(255),",
                    "  FOREIGN KEY (id) REFERENCES x(id)", ");",
                    "create table if not exists orders (id integer, user_id integer, total real);",
                    "ALTER TABLE orders ADD COLUMN note TEXT;"], "schema.sql")
    sc

  test "the tables a project creates":
    check "users" in schema.tables
    check schema.tables["users"].cols.mapIt(it.name) == @["id", "name", "email"]
    check schema.tables["users"].cols[2].typ == "VARCHAR(255)"
    check schema.tables["orders"].cols.mapIt(it.name) == @["id", "user_id", "total", "note"]

  test "what fits there":
    var (ls, l, c) = at("SELECT * FROM |")
    check sqlComplete(ls, l, c, schema)[1].labels.toSeq.anyIt(it == "users")
    (ls, l, c) = at("SELECT u.| FROM users u")
    let cols = sqlComplete(ls, l, c, schema)[1].labels
    check "email" in cols
    check "total" notin cols
    (ls, l, c) = at("select na| from users")
    let any = sqlComplete(ls, l, c, schema)[1]
    check any.anyIt(it.label == "name" and it.rank == 0)
    check any.anyIt(it.label == "select")                 # (lower case, as typed)
    (ls, l, c) = at("SELECT 1;\nSELECT u.|\nFROM users u\nWHERE u.id = ?;\nSELECT 2;")
    check "email" in sqlComplete(ls, l, c, schema)[1].labels       # (the alias below the place, over lines)
    (ls, l, c) = at("SELECT 'FROM |'")
    check sqlComplete(ls, l, c, schema)[1].len == 0

  test "hover":
    check "email" in sqlHover(@["SELECT * FROM users"], 0, 16, schema)
    check "VARCHAR" in sqlHover(@["SELECT u.email FROM users u"], 0, 10, schema)
    check "coalesce" in sqlHover(@["SELECT coalesce(a, b)"], 0, 9, schema).toLowerAscii

  test "problems":
    check sqlChecks(@["SELECT u.name FROM users u JOIN orders o ON o.user_id = u.id;"], schema).len == 0
    let t = sqlChecks(@["SELECT * FROM user;"], schema)
    check t.len == 1 and t[0].rule == "sql-table" and "users" in t[0].msg
    let col = sqlChecks(@["SELECT u.nam FROM users u;"], schema)
    check col.len == 1 and col[0].rule == "sql-column" and "name" in col[0].msg
    check sqlChecks(@["WITH recent AS (SELECT * FROM orders) SELECT * FROM recent;"], schema).len == 0
    check sqlChecks(@["SELECT * FROM nothing;"], SqlSchema()).len == 0     # (no tables known: nothing to say)

  test "INSERT and UPDATE: columns and values":
    check sqlChecks(@["INSERT INTO users (id, name, email) VALUES (1, 'a', 'b'), (?, ?, ?);",
                      "INSERT INTO orders VALUES (1, 2, 3.5, 'n');", "UPDATE users SET name = ?, email = lower(?) WHERE id = 1;"],
                    schema).len == 0
    let cols = sqlChecks(@["INSERT INTO users (id, nmae) VALUES (1, 'a');", "UPDATE users SET emal = ? WHERE id = ?;"], schema)
    check cols.len == 2 and cols.allIt(it.rule == "sql-column")
    check "'name'" in cols[0].msg and "'email'" in cols[1].msg
    let vals = sqlChecks(@["INSERT INTO users (id, name) VALUES (1, 'a', 'b');", "INSERT INTO orders VALUES (1, 2);",
                           "INSERT INTO users (id, name) VALUES (1, 'a'), (2);"], schema)
    check vals.len == 3 and vals.allIt(it.rule == "sql-insert")
    check vals[0].sev == 1 and vals[1].sev == 3 and vals[2].sev == 1        # (fewer, no columns named: PostgreSQL takes it)
    check "3 values for 2 columns" in vals[0].msg and "name the columns" in vals[1].msg
    check vals[2].line == 2 and vals[2].col == "INSERT INTO users (id, name) VALUES (1, 'a'), ".len
    check sqlChecks(@["INSERT INTO users (id, name) SELECT id, name FROM users;"], schema).len == 0

  test "values for the `?` of a query":
    check sqlArgChecks(@["db.exec(sql\"INSERT INTO t VALUES (?, ?)\", a, b)"]).len == 0
    let more = sqlArgChecks(@["db.exec(sql\"INSERT INTO t VALUES (?, ?)\", a, b, c)"])
    check more.len == 1 and more[0].sev == 1 and "2 '?'" in more[0].msg
    let fewer = sqlArgChecks(@["let r = db.getRow(sql\"SELECT * FROM t WHERE a = ? AND b = ?\", \"x\")"])
    check fewer.len == 1 and fewer[0].sev == 2
    check sqlArgChecks(@["db.exec(sql\"INSERT INTO t VALUES (?, ?)\", args)"]).len == 0          # (a list)
    check sqlArgChecks(@["db.exec(sql\"\"\"", "  UPDATE t SET a = ?", "  WHERE id = ?\"\"\", v, id)"]).len == 0
    check sqlArgChecks(@["s.insert(\"abc\", 0)"]).len == 0                 # (not a query)
    check sqlArgChecks(@["db.exec(sql\"SELECT '?' FROM t\")"]).len == 0    # (a ? in a string)
    check sqlArgChecks(@["## `db.exec(sql\"INSERT INTO t VALUES (?)\", a, b)`: an example in a doc comment",
                         "#[ db.exec(sql\"SELECT ?\", a, b) ]#"]).len == 0      # (comments: not calls)
