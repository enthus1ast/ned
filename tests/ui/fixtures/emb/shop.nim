import std/[strformat, strutils]
import db_connector/db_sqlite

{.emit: """
#include <math.h>
static double withVat(double price) {
  return round(price * 105.0) / 100.0;   /* 5% VAT */
}
""".}
proc withVat(price: cdouble): cdouble {.importc, nodecl.}

proc page*(db: DbConn, title: string): string =
  var items = ""
  for r in db.fastRows(sql"SELECT name, price FROM items WHERE stock > 0 ORDER BY name"):
    items.add &"<li>{r[0]} — {withVat(r[1].parseFloat):.2f} OMR</li>\n"
  result = fmt"""
<!DOCTYPE html>
<html>
  <head>
    <title>{title}</title>
    <style>
      li {{ padding: 4px; color: #2a6; }}
    </style>
  </head>
  <body>
    <ul>{items}</ul>
    <script>
      document.title += " ✓";   // ready
    </script>
  </body>
</html>
"""
