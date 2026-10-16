import std/[strformat, re, json, pegs]
import db_connector/db_sqlite

{.emit: """
#include <stdio.h>
static int twice(int x) {
  /* a C comment */
  return 2 * x;   // doubled
}
""".}

proc cTwice(x: cint): cint {.importc: "twice", nodecl.}

proc page(title: string, items: seq[string]): string =
  result = """
<!DOCTYPE html>
<html lang="en">
  <head>
    <title>Shop</title>
    <style>
      body { margin: 0; color: #333; }
    </style>
  </head>
  <body class="main">
    <!-- the list -->
    <ul id="items"></ul>
    <script>
      const n = 3; // count
      console.log("ready", n);
    </script>
  </body>
</html>
"""
  let name = "Ann"
  echo fmt"Hello {name}, you have {items.len:>3} items and {{braces}}"
  echo &"{title.toUpper()} — {cTwice(21)}"

let db = open("shop.db", "", "", "")  # nim comment
let rows = db.getAllRows(sql"SELECT id, name FROM items WHERE price > ? ORDER BY name", 10)
let q = sql"""
  SELECT count(*) AS n
  FROM orders   -- all of them
  WHERE paid = 1
"""
let email = re"^[\w.+-]+@([a-z0-9-]+\.)+[a-z]{2,}$"
let grammar = peg"""
  number <- \d+ ('.' \d+)?
  list <- number (',' number)*
"""
let cfg = parseJson("""{"port": 8080, "debug": true, "name": "shop"}""")
let style = #[css]# ".button { padding: 4px 8px; }"
let plain = """
just some text, not code: if x then y
"""
echo "still Nim here: ", plain.len
