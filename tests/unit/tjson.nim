# ned's own JSON engine: the mistakes it finds, the schemas' keys and values, the outline, the path to the cursor

import std/[unittest, strutils, json]
import ../../src/ned/web/jsonengine, ../../src/ned/web/webcommon

proc msgs(ds: seq[WebDiag]): seq[string] =
  ## each problem as 'line:column message', counted from 1, to compare with what is expected
  for d in ds: result.add $(d.line + 1) & ":" & $(d.col + 1) & " " & d.msg

suite "reading":
  test "a valid file has nothing to say":
    check jsonChecks(@["{", "  \"a\": [1, 2.5, -3e2, true, null],", "  \"b\": {\"c\": \"\\u00e9\\n\"}", "}"]).len == 0
    check jsonChecks(@[""]).len == 0

  test "a comma missing, a comma too many":
    let ds = jsonChecks(@["{", "  \"a\": 1", "  \"b\": [1, 2,]", "}"])
    check ds.len == 2
    check ds[0].line == 1 and "comma is missing" in ds[0].msg
    check ds[1].line == 2 and "comma before the ]" in ds[1].msg
    # (JSONC takes the comma before the ])
    check jsonChecks(@["{\"a\": [1, 2,],}"], comments = true).len == 0

  test "comments: only where the file takes them":
    check "comments are not allowed" in jsonChecks(@["{ // x", "}"])[0].msg
    check jsonChecks(@["{ // x", "  /* y", "  */ \"a\": 1", "}"], comments = true).len == 0

  test "a key twice, an unquoted key, Python's words":
    let ds = jsonChecks(@["{\"a\": 1, \"a\": 2, b: True, \"c\": None, \"d\": 'x'}"])
    let m = msgs(ds).join("\n")
    check "\"a\" is here twice" in m
    check "a key needs \"…\": \"b\"" in m
    check "true and false in small letters" in m
    check "JSON writes null" in m
    check "strings take \"" in m

  test "not closed":
    check "is not closed" in jsonChecks(@["{\"a\": [1, 2"])[0].msg
    check "string is not closed" in jsonChecks(@["{\"a\": \"x", "}"])[0].msg

  test "numbers":
    check jsonChecks(@["[01]"]).len == 1
    check jsonChecks(@["[1.]"]).len == 1
    check jsonChecks(@["[-0.5e-3]"]).len == 0

  test "what std/json would read":
    let d = jsonRead(@["{\"a\": [1, \"x\\ty\"], \"b\": {\"c\": false}}"])
    check $jsonToNode(d.root) == $parseJson("{\"a\": [1, \"x\\ty\"], \"b\": {\"c\": false}}")

suite "schemas":
  let pkg = jsonSchemaFor("/p/package.json")
  let ts = jsonSchemaFor("/p/tsconfig.json")

  test "known files":
    check pkg != nil and ts != nil
    check jsonSchemaFor("/p/atlas.config") != nil
    check jsonSchemaFor("/p/nimble.lock") != nil
    check jsonSchemaFor("/p/data.json") == nil
    check jsonComments("/p/tsconfig.json") and not jsonComments("/p/package.json")

  test "a misspelled key, a value it does not take":
    let ds = jsonChecks(@["{", "  \"nmae\": \"x\",", "  \"type\": \"modul\",", "  \"private\": \"yes\"", "}"], pkg)
    let m = msgs(ds).join("\n")
    check "\"nmae\" is not a key of package.json — \"name\"?" in m
    check "\"module\"? not one of" in m
    check "\"private\" takes true or false" in m

  test "nested keys and other keys":
    let ds = jsonChecks(@["{\"compilerOptions\": {\"stric\": true, \"target\": \"es2022\"}}"], ts, comments = true)
    check ds.len == 1
    check "\"stric\" is not a key of compilerOptions (tsconfig.json) — \"strict\"?" in ds[0].msg
    # (any name in dependencies: a version, as a string)
    let d2 = jsonChecks(@["{\"dependencies\": {\"left-pad\": \"^1.3.0\", \"x\": 2}}"], pkg)
    check d2.len == 1 and "takes a string" in d2[0].msg

  test "completion: the keys not there yet, then a key's values":
    let lines = @["{", "  \"name\": \"x\",", "  \"\"", "}"]
    let (a, items) = jsonComplete(lines, 2, 3, pkg)
    check a == 3
    check items[0].insert == items[0].label and items[0].snippet == ""      # (inside "…": the key only)
    let (b, keys2) = jsonComplete(@["{", "  ", "}"], 1, 2, pkg)
    check b == 2 and keys2[0].insert == "\"" & keys2[0].label & "\"" and keys2[0].snippet.startsWith(keys2[0].insert & ": ")
    var labels: seq[string]
    for it in items: labels.add it.label
    check "version" in labels and "name" notin labels
    let (_, vals) = jsonComplete(@["{", "  \"type\": \"\"", "}"], 1, 11, pkg)
    var vl: seq[string]
    for it in vals: vl.add it.label
    check vl == @["module", "commonjs"]
    let (_, opts) = jsonComplete(@["{\"compilerOptions\": {\"", "}}"], 0, 21, ts, true)
    var ol: seq[string]
    for it in opts: ol.add it.label
    check "strict" in ol and "target" in ol

  test "hover: the key's path and meaning":
    let h = jsonHover(@["{\"compilerOptions\": {\"strict\": true}}"], 0, 23, ts)
    check "`compilerOptions.strict`" in h and "boolean" in h and "strict check" in h

suite "outline and path":
  test "the keys, nested":
    let o = jsonOutline(@["{", "  \"scripts\": {", "    \"build\": \"nim c x\"", "  },", "  \"files\": [\"a\", \"b\"]", "}"])
    check o.len == 5
    check o[0].name == "scripts" and o[0].depth == 0 and o[0].detail == "{1}"
    check o[1].name == "build" and o[1].depth == 1 and o[1].line == 2
    check o[2].name == "files" and o[3].name == "[0]"

  test "the path at the cursor":
    let lines = @["{", "  \"scripts\": {", "    \"build\": \"nim c x\"", "  },", "  \"files\": [\"a\", \"b\"]", "}"]
    check jsonPathAt(lines, 2, 15) == "scripts.build"
    check jsonPathAt(lines, 4, 19) == "files[1]"
    check jsonPathAt(lines, 0, 0) == ""

  test "random text never fails":
    var seed = 7
    let pieces = ["{", "}", "[", "]", ",", ":", "\"a\"", "\"", "1", "-", "true", "nul", "/*", "//", " ", "\\", "e"]
    for n in 0 ..< 3000:
      var s = ""
      for k in 0 ..< 12:
        seed = (seed * 1103515245 + 12345) and 0x7fffffff
        s.add pieces[seed mod pieces.len]
      let lines = s.split(' ')
      discard jsonChecks(lines, jsonSchemaFor("package.json"), comments = n mod 2 == 0)
      discard jsonOutline(lines)
      for l in 0 ..< lines.len:
        for c in 0 .. lines[l].len:
          discard jsonComplete(lines, l, c, jsonSchemaFor("tsconfig.json"))
          discard jsonHover(lines, l, c, jsonSchemaFor("package.json"))
