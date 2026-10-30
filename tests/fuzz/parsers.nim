## The parsers fed broken text: ned's own files, C, NIF, JSON, CSS, HTML, SQL, Markdown, YAML and TOML, each mutated
## at random (bytes changed, brackets, quotes and comment markers put in, pieces cut, repeated or dropped) and given to
## the reader or formatter of its kind. Any of them may say it cannot — none may crash: an index out of range, a
## range error, a nil, an assertion is a bug (ned's release builds keep these checks: such a bug closes the editor).
## Run: nim c -d:release --checks:on -r tests/fuzz/parsers.nim [seconds per target] [seed]
##   with sanitizers too: -d:useMalloc --passC:"-fsanitize=address,undefined -fno-sanitize=null -fno-omit-frame-pointer"
##   --passL:"-fsanitize=address,undefined"
## A failing input is written to tests/fuzz/found/<target>-<n>.txt (that folder is not part of the source).

import std/[os, strutils, random, times, monotimes, tables]
import ../../src/ned/format/formatters
import ../../src/ned/nim/index
import ../../src/ned/c/cindex
import ../../src/ned/nim/nifread

const Tokens = ["(", ")", "[", "]", "{", "}", "\"", "\"\"\"", "'", "#", "#[", "]#", "##", "\n", "\t", "  ", "\\",
                "/*", "*/", "//", "{.", ".}", "`", "=", ":", ",", ";", "@", "~", ":sym.0.mod", "é", "⟑", "\xFF",
                "\x00", "<", ">", "</", "/>", "<!--", "-->", "---", "- ", "* ", "```", "[[", "]]", "--", "'''",
                "proc ", "type\n", "of ", "case ", "when ", "#define ", "#if 0\n", "#endif\n", "R\"(", ")\"",
                "\r\n", "\\\n", ". ", "...", "=>"]

proc mutate(r: var Rand, s: string): string =
  ## the text with one to eight random changes
  result = s
  for _ in 0 ..< r.rand(1 .. 8):
    let at = if result.len > 0: r.rand(result.len) else: 0
    case r.rand(5)
    of 0:
      if result.len > 0: result[min(at, result.high)] = char(r.rand(255))
    of 1, 2: result.insert(Tokens[r.rand(Tokens.high)], at)
    of 3:
      if result.len > 0:
        let e = min(result.len, at + r.rand(40))
        result.delete(min(at, result.high) ..< e)
    of 4:
      if result.len > 0 and result.len < 200_000:
        let e = min(result.len, at + r.rand(200))
        result.insert(result[min(at, result.high) ..< e], r.rand(result.len))
    else:
      if result.len > 0: result.setLen(r.rand(result.len))

proc seedsOf(dirs: openArray[string], exts: openArray[string], maxBytes = 30_000, most = 40): seq[string] =
  ## up to `most` files of these kinds under these folders, each at most maxBytes (cut there)
  for d in dirs:
    if not dirExists(d): continue
    for f in walkDirRec(d):
      if result.len >= most: return
      if splitFile(f).ext.toLowerAscii in exts:
        try:
          var t = readFile(f)
          if t.len > maxBytes: t.setLen(maxBytes)
          result.add t
        except CatchableError: discard

let here = currentSourcePath().parentDir
let root = here.parentDir.parentDir
let secs = if paramCount() >= 1: parseFloat(paramStr(1)) else: 20.0
var r = initRand(if paramCount() >= 2: parseInt(paramStr(2)) else: 20261031)
let found = here / "found"

var nimSeeds = seedsOf([root / "src" / "ned" / "nim" / "index", root / "src" / "ned" / "format", root / "plugins"],
                       [".nim", ".nims"])
var nifSeeds: seq[string]
for d in ["/tmp/claude-0/n24/cache", getTempDir()]:
  nifSeeds.add seedsOf([d], [".nif"], most = 10)
if nifSeeds.len == 0:
  nifSeeds.add "(.nif27)\n(stmts@,1,a.nim\n (proc@5 :f.0.amod . . .@6\n  (params@1 (param :x.0 . (pragmas) (i -1) .))\n" &
               "  (i -1) (pragmas) . (stmts (ret x.0))))\n"
let cSeeds = seedsOf([root / "tests"], [".c", ".h", ".cpp"], most = 20) &
             @["#include <stdio.h>\n/* a\n b */\n#define M(a) \\\n (a)\nint f(int x) { return M(x); }\n"]
let jsonSeeds = seedsOf([root / "editors", root / "tests"], [".json"], most = 15)
let cssSeeds = seedsOf([root], [".css"], most = 10) & @["a { color: red; } @media (x) { .b > c { margin: 0 } }"]
let htmlSeeds = seedsOf([root], [".html"], most = 10) & @["<html><body><p class=\"x\">a<br>b</p><!-- c --></body></html>"]
let sqlSeeds = seedsOf([root], [".sql"], most = 10) & @["select a, b from t where x = 'y' and z in (1, 2) order by a;"]
let mdSeeds = seedsOf([root / "docs"], [".md"], most = 20)
let ymlSeeds = seedsOf([root / ".github"], [".yml", ".yaml"], most = 10)
let tomlSeeds = seedsOf([root / "editors"], [".toml"], most = 10) & @["[a]\nb = 1\nc = \"x\"\n[[d]]\ne = [1, 2]\n"]

var failures = 0
var runs = 0
var saved: Table[string, int]

proc keep(target, input, what: string) =
  ## a crash: said, and its input written to the found folder
  inc failures
  let n = saved.getOrDefault(target) + 1
  saved[target] = n
  if n > 3: return                     # (three inputs a target: the rest are likely the same bug)
  createDir(found)
  let p = found / (target & "-" & $n & ".txt")
  writeFile(p, input)
  echo "CRASH ", target, ": ", what.splitLines[0][0 ..< min(160, what.splitLines[0].len)], "  (", p, ")"

template fuzz(target: string, seeds: seq[string], body: untyped) =
  ## feeds mutated seeds to `body` (the text is `input`) for `secs` seconds; a Defect is a crash
  block:
    if seeds.len > 0:
      let t0 = getMonoTime()
      var n = 0
      while (getMonoTime() - t0).inMilliseconds.float < secs * 1000:
        let input {.inject.} = mutate(r, seeds[r.rand(seeds.high)])
        try:
          body
        except Defect as e:
          keep(target, input, $e.name & ": " & e.msg)
        except CatchableError: discard
        inc n
      runs += n
      echo target, ": ", n, " inputs"

nxInitDefines()
fuzz("nifParse", nifSeeds):
  let ls = input.splitLines
  discard nifOutline(nifParse(ls))
  discard nifParse(ls, before = true)
fuzz("nim-index", nimSeeds):
  discard nxParse(input.splitLines, "/fuzz/x.nim")
fuzz("nim-format", nimSeeds):
  var err = ""
  discard fFormat(input, err)
fuzz("c-index", cSeeds):
  discard cxParse(input, "/fuzz/x.c")
fuzz("c-format", cSeeds):
  discard fmtC(input)
fuzz("json", jsonSeeds):
  discard fmtJson(input)
fuzz("css", cssSeeds):
  discard fmtCss(input)
fuzz("html", htmlSeeds):
  discard fmtHtml(input)
fuzz("sql", sqlSeeds):
  discard fmtSql(input)
fuzz("markdown", mdSeeds):
  discard fmtMarkdown(input)
fuzz("yaml", ymlSeeds):
  discard fmtYaml(input)
fuzz("toml", tomlSeeds):
  discard fmtToml(input)
echo runs, " inputs, ", failures, " crashes"
if failures > 0: quit 1
