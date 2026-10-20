## The built-in HTML and SQL formatters: layouts, what they keep as written, what makes them give up, and a second
## run changing nothing. Run: nim r tests/unit/twebfmt.nim

import std/[strutils, unittest]
import ../../src/ned/format/formatters

proc html(s: string, indent = 2, maxW = 100): string =
  let (r, err) = fmtHtml(s, indent, maxW)
  checkpoint err
  check err.len == 0
  r

proc sql(s: string, indent = 2, upper = true): string =
  let (r, err) = fmtSql(s, indent, upper)
  checkpoint err
  check err.len == 0
  r

proc words(s: string): seq[string] =
  ## the text's words, for "nothing but whitespace changed" checks
  s.splitWhitespace

const htmlInputs = [
  "<!DOCTYPE html>\n<html><head><title>Hi</title><meta charset=utf-8></head><body><p>x</p></body></html>",
  "<div><p>Hello <b>you</b></p></div>",
  "<p>A very long paragraph of text that goes on and on and on, well beyond the width of one hundred columns, " &
    "so it <em>must</em> be filled into several lines without losing a single word.</p>",
  "<div>\n<pre>  keep\n   this </pre>\n<script>\n  if (a < b) { x(); }\n</script><style>a{b:c}</style></div>",
  "<ul>\n  {% for item in items %}\n  <li>{{ item.name }}</li>\n  {% endfor %}\n</ul>",
  "<p>Hello {{ user.name }}, you have {count} messages and ${total  } <%= x %></p>",
  "<input type=\"text\" name=\"username\" id=\"username\" class=\"form-control input-lg\" " &
    "placeholder=\"Enter your name\" required autofocus>",
  "<div><span>unclosed <b>bold</div><p>after</p></b>",
  "<ul>\n<li>one\n<li>two\n</ul>\n<table><tr><td>1<td>2<tr><td>3</table>",
  "<div>\r\n<p>crlf</p>\r\n</div>\r\n",
  "<p>line one<br>\nline two<br/>line three<br /></p>",
  "<div>\n<!-- a comment -->\n<p>x</p>\n\n\n<p>y</p><!-- inline --></div>",
  "<select name=x><option>a<option>b</select> text",
  "<a href=\"x\"><div>block in link</div></a>after",
  "<?php echo $a->b(\"x   y\"); ?>\n<p>z</p>",
  "<x-icon name=\"a\"></x-icon> text <my-el/>",
  "<div><textarea name=t>\n  keep   this\n</textarea></div>",
  "<p title=\"{{ t }}\" {% if x %}hidden{% endif %}>{{  x  }} and {%  y  %}</p>",
  "<div   class=\"a\"    id='b'  data-x=c >x</div>",
  "<p>a</b> b</p></div>",
  "",
  "   \n\n  ",
]

suite "HTML":
  test "block elements on their own lines, children indented, short inline content on one line":
    check html("<!DOCTYPE html>\n<html><head><title>Hi</title><meta charset=utf-8></head>" &
      "<body><div class=\"a\"><p>Hello <b>you</b></p><p>Second   para\n with  text</p></div></body></html>") ==
      "<!DOCTYPE html>\n<html>\n  <head>\n    <title>Hi</title>\n    <meta charset=utf-8>\n  </head>\n" &
      "  <body>\n    <div class=\"a\">\n      <p>Hello <b>you</b></p>\n      <p>Second para with text</p>\n" &
      "    </div>\n  </body>\n</html>\n"

  test "the indentation width":
    check html("<div><p>x</p></div>", indent = 4) == "<div>\n    <p>x</p>\n</div>\n"

  test "long inline content: filled in lines up to maxW, broken only at whitespace":
    let src = htmlInputs[2]
    let r = html(src)
    check r.startsWith("<p>\n  A very long paragraph")
    check r.endsWith("\n</p>\n")
    for l in r.splitLines: check l.len <= 100
    check words(r) == words(src.replace("<p>", "<p> ").replace("</p>", " </p>"))

  test "<pre>, <textarea>, <script>, <style> kept byte for byte":
    let r = html(htmlInputs[3])
    check "<pre>  keep\n   this </pre>" in r
    check "<script>\n  if (a < b) { x(); }\n</script>" in r
    check "<style>a{b:c}</style>" in r
    check html(htmlInputs[16]) == "<div>\n  <textarea name=t>\n  keep   this\n</textarea>\n</div>\n"

  test "comments and declarations kept; a comment on its own line keeps it":
    check html(htmlInputs[11]) ==
      "<div>\n  <!-- a comment -->\n  <p>x</p>\n\n  <p>y</p>\n  <!-- inline -->\n</div>\n"
    check html("<p>a <!--  c  --> b</p>") == "<p>a <!--  c  --> b</p>\n"
    check html("<!doctype   html>") == "<!doctype   html>\n"
    check html(htmlInputs[14]) == "<?php echo $a->b(\"x   y\"); ?>\n<p>z</p>\n"

  test "templates survive whole: {{ }}, {% %}, <%= %>, ${}, {expr}":
    check html(htmlInputs[5]) ==
      "<p>Hello {{ user.name }}, you have {count} messages and ${total  } <%= x %></p>\n"
    check html(htmlInputs[17]) ==
      "<p title=\"{{ t }}\" {% if x %}hidden{% endif %}>{{  x  }} and {%  y  %}</p>\n"
    check html("<p>{a + b}  and  {{ c  |  d }}</p>", maxW = 12) == "<p>\n  {a + b}\n  and\n  {{ c  |  d }}\n</p>\n"

  test "a template statement on its own line keeps its line":
    check html(htmlInputs[4]) ==
      "<ul>\n  {% for item in items %}\n  <li>{{ item.name }}</li>\n  {% endfor %}\n</ul>\n"

  test "attributes as written, one space between them; many attributes past maxW: one a line":
    check html(htmlInputs[18]) == "<div class=\"a\" id='b' data-x=c>x</div>\n"
    check html(htmlInputs[6]) == "<input\n  type=\"text\"\n  name=\"username\"\n  id=\"username\"\n" &
      "  class=\"form-control input-lg\"\n  placeholder=\"Enter your name\"\n  required\n  autofocus>\n"
    check html("<div a=\"1\" b=\"2\">x</div>", maxW = 10) == "<div\n  a=\"1\"\n  b=\"2\">\n  x\n</div>\n"
    check html("<a href = \"x\">y</a>") == "<a href = \"x\">y</a>\n"

  test "void elements: no end tag, <br/> and <br /> as written, a line break after a <br> before whitespace":
    check html("<img src=\"a.png\" alt=\"A\"><br/><br /><hr>") == "<img src=\"a.png\" alt=\"A\"><br/><br />\n<hr>\n"
    check html(htmlInputs[10]) == "<p>\n  line one<br>\n  line two<br/>line three<br />\n</p>\n"

  test "whitespace collapsed, one blank line at most, trailing spaces trimmed, one newline at the end":
    check html("<p>  a\n\n\n  b  </p>\n\n\n\n<p>c</p>") == "<p>a b</p>\n\n<p>c</p>\n"
    check html("<div>  \n  <p>x</p>   \n</div>   ") == "<div>\n  <p>x</p>\n</div>\n"

  test "end tags left out: <li>, <td>, <option>":
    check html(htmlInputs[8]) ==
      "<ul>\n  <li>one\n  <li>two\n</ul>\n<table>\n  <tr>\n    <td>1\n    <td>2\n  <tr>\n    <td>3\n</table>\n"
    check html(htmlInputs[12]) == "<select name=x>\n  <option>a\n  <option>b\n</select>\ntext\n"

  test "mismatched and unknown markup: no crash, no text lost":
    check html(htmlInputs[7]) == "<div><span>unclosed <b>bold</div>\n<p>after</p>\n</b>\n"
    check html(htmlInputs[19]) == "<p>a</b> b</p>\n</div>\n"
    check html(htmlInputs[15]) == "<x-icon name=\"a\"></x-icon> text <my-el/>\n"
    check html("<p>1 < 2 and 3 > 2</p>") == "<p>1 < 2 and 3 > 2</p>\n"

  test "markup it cannot read: left alone, with the reason":
    for bad in ["<div class=\"x", "<p>x<!-- open", "<script>x", "</p junk>", "<!DOCTYPE"]:
      let (r, err) = fmtHtml(bad)
      checkpoint bad
      check err.len > 0
      check r == bad

  test "empty input, CRLF input":
    check html("") == "\n"
    check html("   \n\n  ") == "\n"
    check html(htmlInputs[9]) == "<div>\n  <p>crlf</p>\n</div>\n"

  test "a second run changes nothing":
    for src in htmlInputs:
      for w in [20, 60, 100]:
        let (once, err) = fmtHtml(src, 2, w)
        if err.len > 0: continue
        let (twice, err2) = fmtHtml(once, 2, w)
        checkpoint src & " (width " & $w & ")"
        check err2.len == 0
        check twice == once

const sqlInputs = [
  "select a, b, count(*) from users u left join orders o on o.user_id = u.id where u.active = 1 and o.total > -5 " &
    "group by a, b order by a desc limit 10 offset 5;",
  "SELECT u.id, u.name, u.email, u.created_at, o.id AS order_id, o.total, o.status, o.created_at AS ordered " &
    "FROM users u INNER JOIN orders o ON o.user_id = u.id AND o.status <> 'cancelled' AND o.total >= 100 " &
    "WHERE u.created_at BETWEEN '2020-01-01' AND '2021-01-01' AND (u.country = 'OM' OR u.country = 'AE') " &
    "AND u.deleted_at IS NULL",
  "create table if not exists users (id serial primary key, name varchar(100) not null, email text unique, " &
    "created_at timestamp default now(), constraint fk foreign key (org_id) references orgs(id) on delete cascade);",
  "select * from t where id in (select user_id from orders where total > 100);",
  "-- leading comment\nselect a, -- the a\n  b /* block */ from t; -- trailing\n\n\n/* between */\n" &
    "insert into t (a, b) values (?, ?), ($1, :name), (@v, ?2);",
  "SeLeCt DiStInCt a FrOm T wHeRe X = 1",
  "insert into t (a, b) values (1, 2) on conflict (a) do update set b = excluded.b returning *;",
  "update t set a = 1, b = 'x' where id = {id} and name = '{{ name }}' and k = ${key};",
  "with recursive r as (select 1 as n union all select n + 1 from r where n < 10), s as (select * from r) " &
    "select n from s;",
  "select case when status = 'active' and created_at > now() - interval '30 days' then 'new active user' " &
    "when status = 'inactive' then 'dormant' else 'other' end as kind from users",
  "delete from t where a is distinct from null;",
  "select 1;\nselect 2;\n\nselect 3",
  "SELECT\r\n  a\r\nFROM t\r\n",
  "select 'it''s', \"Quoted  Name\", `bt`, E'a\\'b', $$ body;  $$ from t",
  "select a from t where a=b and c<>d or e>=f and g||h = 'x' and k::text = $1 and m = -1 and n = 2 - -3",
  "select t.*, count(*), x[1], sum(a*b) from t",
  "",
]

suite "SQL":
  test "each clause on its own line, short lists and conditions on it, JOIN … ON on one line":
    check sql(sqlInputs[0]) == "SELECT a, b, count(*)\nFROM users u\nLEFT JOIN orders o ON o.user_id = u.id\n" &
      "WHERE u.active = 1 AND o.total > -5\nGROUP BY a, b\nORDER BY a DESC\nLIMIT 10\nOFFSET 5;\n"

  test "long lists: one item a line; long conditions: one AND / OR a line (the AND of BETWEEN stays)":
    check sql(sqlInputs[1]) == "SELECT\n  u.id,\n  u.name,\n  u.email,\n  u.created_at,\n  o.id AS order_id,\n" &
      "  o.total,\n  o.status,\n  o.created_at AS ordered\nFROM users u\n" &
      "INNER JOIN orders o ON o.user_id = u.id\n  AND o.status <> 'cancelled'\n  AND o.total >= 100\n" &
      "WHERE u.created_at BETWEEN '2020-01-01' AND '2021-01-01'\n  AND (u.country = 'OM' OR u.country = 'AE')\n" &
      "  AND u.deleted_at IS NULL\n"

  test "CREATE TABLE: one column or constraint a line, `);` on its own line":
    check sql(sqlInputs[2]) == "CREATE TABLE IF NOT EXISTS users (\n  id SERIAL PRIMARY KEY,\n" &
      "  name VARCHAR(100) NOT NULL,\n  email TEXT UNIQUE,\n  created_at TIMESTAMP DEFAULT now(),\n" &
      "  CONSTRAINT fk FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE CASCADE\n);\n"
    check sql("create table t (a int)", indent = 4) == "CREATE TABLE t (\n    a INT\n)\n"

  test "sub-queries indented one level":
    check sql(sqlInputs[3]) ==
      "SELECT *\nFROM t\nWHERE id IN (\n  SELECT user_id\n  FROM orders\n  WHERE total > 100\n);\n"
    check sql(sqlInputs[8]) == "WITH RECURSIVE r AS (\n  SELECT 1 AS n\n  UNION ALL\n  SELECT n + 1\n  FROM r\n" &
      "  WHERE n < 10\n),\ns AS (\n  SELECT *\n  FROM r\n)\nSELECT n\nFROM s;\n"

  test "INSERT … VALUES … ON CONFLICT … RETURNING, UPDATE … SET, DELETE FROM":
    check sql(sqlInputs[6]) ==
      "INSERT INTO t (a, b)\nVALUES (1, 2)\nON CONFLICT (a) DO UPDATE\nSET b = excluded.b\nRETURNING *;\n"
    check sql(sqlInputs[10]) == "DELETE FROM t\nWHERE a IS DISTINCT FROM NULL;\n"

  test "a long CASE: one WHEN a line":
    check sql(sqlInputs[9]) == "SELECT CASE\n" &
      "  WHEN status = 'active' AND created_at > now() - INTERVAL '30 days' THEN 'new active user'\n" &
      "  WHEN status = 'inactive' THEN 'dormant'\n  ELSE 'other'\nEND AS kind\nFROM users\n"

  test "comments, placeholders, blank lines between statements":
    check sql(sqlInputs[4]) == "-- leading comment\nSELECT\n  a, -- the a\n  b /* block */\nFROM t; -- trailing\n\n" &
      "/* between */\nINSERT INTO t (a, b)\nVALUES (?, ?), ($1, :name), (@v, ?2);\n"
    check sql(sqlInputs[11]) == "SELECT 1;\nSELECT 2;\n\nSELECT 3\n"
    # a line comment never swallows what came after it
    check sql("SELECT a FROM t WHERE x = 'a  b' -- note\nAND y = 2") ==
      "SELECT a\nFROM t\nWHERE x = 'a  b' -- note\n  AND y = 2\n"

  test "keywords in one case, names as written; upper = false":
    check sql(sqlInputs[5]) == "SELECT DISTINCT a\nFROM T\nWHERE X = 1\n"
    check sql(sqlInputs[5], upper = false) == "select distinct a\nfrom T\nwhere X = 1\n"
    check sql("select t.date, date from date") == "SELECT t.date, DATE\nFROM date\n"

  test "strings, quoted names, templates kept whole":
    check sql(sqlInputs[13]) == "SELECT 'it''s', \"Quoted  Name\", `bt`, E'a\\'b', $$ body;  $$\nFROM t\n"
    check sql(sqlInputs[7]) == "UPDATE t\nSET a = 1, b = 'x'\nWHERE id = {id} AND name = '{{ name }}' AND k = ${key};\n"

  test "spaces around operators, none in x::int, -1, count(*), t.*, a[1]":
    check sql(sqlInputs[14]) == "SELECT a\nFROM t\nWHERE a = b\n  AND c <> d\n  OR e >= f\n  AND g || h = 'x'\n" &
      "  AND k::TEXT = $1\n  AND m = -1\n  AND n = 2 - -3\n"
    check sql(sqlInputs[15]) == "SELECT t.*, count(*), x[1], sum(a * b)\nFROM t\n"

  test "SQL it cannot read: left alone, with the reason":
    for bad in ["select 1 from t where (a = 1", "select 'abc", "select a) from t", "select 'it\\'s' from t",
        "select /* open"]:
      let (r, err) = fmtSql(bad)
      checkpoint bad
      check err.len > 0
      check r == bad

  test "empty input, CRLF input":
    check sql("") == "\n"
    check sql(sqlInputs[12]) == "SELECT a\nFROM t\n"

  test "a second run changes nothing":
    for src in sqlInputs:
      for up in [true, false]:
        let (once, err) = fmtSql(src, 2, up)
        if err.len > 0: continue
        let (twice, err2) = fmtSql(once, 2, up)
        checkpoint src
        check err2.len == 0
        check twice == once
