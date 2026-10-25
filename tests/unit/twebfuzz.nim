# ned's own engines on text cut and mixed at random (JSON, JavaScript, CSS, HTML, SQL, NIF, pnak.nif): every check,
# completion, hover, outline and definition answers — none raises, none hangs. A fixed seed: the same text each run.
# Run: nim r tests/unit/twebfuzz.nim (NED_FUZZ_ROUNDS=5000 for more)

import std/[unittest, random, strutils, os, times]
import ../../src/ned/web/web, ../../src/ned/nim/nifread

const Samples = [
  """{"name": "demo", "version": "1.0.0", "scripts": {"test": "node t.js"}, "dependencies": {"a": "^1"},
  "list": [1, 2.5, -3e2, true, null, "xé"], // a comment
  "nested": {"deep": [{"k": [[]]}]},}""",
  """import { join, split as sp } from './util.js';
export default class Store extends Base { #priv = 1; static n = 2; add(x) { return this.#priv + x?.y ?? 0; } }
const f = async (a, ...rest) => { for await (const v of gen()) { yield* v; } };
let re = /a[/]b/gi, t = `x ${y + `z${1}`} w`; label: while (true) { break label; }""",
  """:root { --primary: #333; --gap: calc(1px + 2em); }
@media (max-width: 600px) and (prefers-color-scheme: dark) { a:hover::before { content: "}"; color: var(--primay, red) } }
.b > .c ~ d + e[data-x="1"] { margin: 0 auto !important; grid-template-areas: "a b" "c d"; }
@keyframes spin { from { transform: rotate(0deg) } to { transform: rotate(360deg) } }""",
  """<!doctype html><html lang="en"><head><style>a { colr: red }</style><script type="module">import x from "./x.js";
if (a < b && c > d) { document.querySelector("</p>") }</script></head>
<body><a href="#top">t</a><img src="a.png" widht=3><ul><li>a<li>b</ul><p>one<p>two<svg><circle r="1"/></svg>
<table><tr><td>1</td></tr></table><input type=text disabled><!-- a comment <div> --></body></html>""",
  """CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email VARCHAR(255));
INSERT INTO users (id, name, email) VALUES (1, 'a''b', "c"), (?, ?, ?);
WITH r AS (SELECT * FROM users u WHERE u.id IN (SELECT id FROM users)) SELECT r.name, count(*) FROM r GROUP BY 1;
UPDATE users SET name = lower(?), email = NULL WHERE id = ? RETURNING *; -- done
DELETE FROM users WHERE name LIKE '%x%' ESCAPE '\';""",
  """(.nif27)
(stmts@,1,app.nim
 (proc 4,2 :foo.0.app . . . (params (param :x.0 . . int .)) int . . (stmts (ret x.0)))
 (type :Obj.0.app . . . (object . (fld :a.0.app . . string .)))
 (requires "https://github.com/a/b.git" "0123abc") (requires "x\20y" "main"))"""]

const Words = ["{", "}", "[", "]", "(", ")", "\"", "'", "`", ",", ":", ";", "<", ">", "/", "\\", "*", "#", "--", "/*",
               "*/", "<!--", "-->", "${", "@", ".", "=", "\n", " ", "\t", "é", "🎉", "\x00", "</script>", "<style>",
               "SELECT", "FROM", "(requires", "function", "=>", "import", "var(", "url(", "&amp;", "\\u12", "0x"]

proc mutate(r: var Rand, text: string): string =
  result = text
  for _ in 0 ..< r.rand(1 .. 8):
    let n = result.len
    case r.rand(3)
    of 0:                                           # (a piece cut out)
      if n > 0:
        let a = r.rand(n - 1)
        result.delete(a .. min(n - 1, a + r.rand(20)))
    of 1:                                           # (a word put in)
      let a = r.rand(n)
      result.insert(Words[r.rand(Words.high)], a)
    of 2:                                           # (another sample's piece put in)
      let o = Samples[r.rand(Samples.high)]
      let a = r.rand(o.len - 1)
      result.insert(o[a .. min(o.high, a + r.rand(40))], r.rand(n))
    else:                                           # (cut short)
      if n > 0: result.setLen(r.rand(n - 1))

proc everything(lines: seq[string], r: var Rand) =
  ## every engine over the text, and at three places in it
  discard jsonChecks(lines)
  discard jsonChecks(lines, jsonSchemaFor("package.json"), comments = true)
  discard jsonOutline(lines)
  discard jsChecks(lines)
  discard jsChecks(lines, fragment = true)
  discard jsOutline(lines)
  discard cssChecks(lines)
  discard cssChecks(lines, strict = false)
  discard htmlChecks(lines)
  discard htmlChecks(lines, fragment = true)
  discard htmlLocalRefs(lines)
  discard htmlClassesAndIds(lines)
  var sc: SqlSchema
  sc.addCreates(lines, "f.sql")
  discard sqlChecks(lines, sc)
  discard sqlArgChecks(lines)
  discard nifOutline(nifParse(lines))
  discard pnakRequires(lines)
  for _ in 0 ..< 3:
    let l = r.rand(lines.high)
    let c = r.rand(lines[l].len)
    discard jsonComplete(lines, l, c, jsonSchemaFor("tsconfig.json"))
    discard jsonHover(lines, l, c, jsonSchemaFor("package.json"))
    discard jsonPathAt(lines, l, c)
    discard jsComplete(lines, l, c)
    discard jsHover(lines, l, c)
    discard jsDefinition(lines, l, c)
    discard jsReferences(lines, l, c)
    discard jsImportAt(lines, l, c)
    discard cssComplete(lines, l, c)
    discard cssHover(lines, l, c)
    discard htmlComplete(lines, l, c)
    discard htmlHover(lines, l, c)
    discard sqlComplete(lines, l, c, sc)
    discard sqlHover(lines, l, c, sc)

suite "the engines on mangled text":
  test "no exception, no hang":
    # (not an argument: unittest takes those for the names of the tests to run)
    let rounds = parseInt(getEnv("NED_FUZZ_ROUNDS", "400"))
    var r = initRand(parseInt(getEnv("NED_FUZZ_SEED", "627")))
    var worst = 0.0
    for i in 0 ..< rounds:
      let base = Samples[i mod Samples.len]
      let text = mutate(r, base)
      let lines = text.split('\n')
      let t0 = epochTime()
      try: everything(lines, r)
      except CatchableError, Defect:
        let keep = getTempDir() / "ned-webfuzz-failed.txt"
        writeFile(keep, text)
        checkpoint("round " & $i & ": " & getCurrentExceptionMsg() & " — the text: " & keep & "\n" &
                   getCurrentException().getStackTrace())
        fail()
        break
      worst = max(worst, epochTime() - t0)
    checkpoint("the slowest round: " & formatFloat(worst * 1000, ffDecimal, 1) & " ms")
    check worst < 2.0
