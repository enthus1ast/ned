"""scala: the language (colours, comments, indentation, F5 with sbt, scala-cli or scala), its snippets, the outline
without Metals (in braces and by indentation), Metals and scalafmt when they are installed, the settings"""
import os, shutil, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from langcheck import check_language, done, fake_tools, ned_cmd, run_sh, start
from tplugins import check

SAMPLE = '''package shapes

// a comment: def notThis = 1
/* a block /* nested: def nope = 2 */ still */
sealed trait Shape {
  def area: Double
}

case class Square(side: Double) extends Shape {
  def area: Double = side * side
  private val label = "def fake = 3"
}

object Shapes {
  val limit = 10
  def largest(xs: List[Shape]): Shape = {
    val sorted = xs.sortBy(_.area)   // a local: not in the outline
    sorted.last
  }
  type Area = Double
}

enum Color:
  case Red, Green
  def isRed: Boolean = this == Red

class Counter:
  var count = 0
  def inc(): Unit =
    val next = count + 1
    count = next

extension (s: Square)
  def double: Square = Square(s.side * 2)

val doc = """
def notThis = 4
"""

@main def hello(): Unit = println(Shapes.largest(List(Square(2))))'''.split("\n")


def run(factory, tag):
    check_language(
        factory, tag, "scala",
        {"name": "Scala", "extensions": ["scala", "sc", "sbt"], "lineComment": "//", "blockComment": ["/*", "*/"],
         "nestedComments": True, "docBlockComment": ["/**", "*/"], "quotes": "\"", "tripleQuotes": True,
         "charLiterals": True, "capitalTypes": True, "decorators": True, "indentSize": 2, "dedent": "})]",
         "keywords": {"def", "val", "var", "class", "object", "trait", "case", "match", "given", "using", "enum",
                      "then", "extension", "end"},
         "constants": {"true", "false", "null"}, "indentAfter": {"{", "=", "=>", ":", "then", "do", "match"},
         "dedentWords": ["end", "else", "catch", "finally"]},
        ["def", "class", "caseclass", "object", "trait", "enum", "match", "for", "main", "test"],
        SAMPLE,
        [("shapes", "module", 0), ("Shape", "interface", 0), ("area", "method", 1), ("Square", "class", 0),
         ("area", "method", 1), ("label", "constant", 1), ("Shapes", "object", 0), ("limit", "constant", 1),
         ("largest", "method", 1), ("Area", "type", 1), ("Color", "enum", 0), ("isRed", "method", 1),
         ("Counter", "class", 0), ("count", "variable", 1), ("inc", "method", 1),
         ("extension (s: Square)", "class", 0), ("double", "method", 1), ("doc", "constant", 0),
         ("hello", "function", 0)],
        ["sbt", "scala-cli", "scala", "metals", "scalafmt"],
        runs=[("hello.scala", "@main def hello() = ()\n", {}, "scala-cli run $file"),
              ("hello.test.scala", "class T\n", {}, "scala-cli test $file"),
              ("src/main/scala/App.scala", "object App\n", {"build.sbt": "name := \"app\"\n"}, "sbt run"),
              ("src/test/scala/AppSpec.scala", "class AppSpec\n", {"build.sbt": "name := \"app\"\n"}, "sbt test")],
        server=["metals"], formatter="scalafmt --stdin --assume-filename \"$file\"")

    # without scala-cli: `scala file` (the runner of Scala 2, and of Scala 3 — which is scala-cli since 3.5)
    tmp = tempfile.mkdtemp(prefix="ned-scala-")
    try:
        h, ok, err = start(factory, [os.path.join(tmp, "none")], only_path=True)
        run_cmd = (h.reg("language", id="scala") or {}).get("spec", {}).get("run", "") if ok else ""
        build_cmd = (h.reg("language", id="scala") or {}).get("spec", {}).get("build", "") if ok else ""
        done(h)
        fake = os.path.join(tmp, "bin")
        fake_tools(fake, ["scala", "sbt"])
        f = os.path.join(tmp, "loose", "hello.scala")
        os.makedirs(os.path.dirname(f))
        open(f, "w").write("@main def hello() = ()\n")
        o = run_sh(ned_cmd(run_cmd, f, "/T"), os.path.dirname(f), [fake])
        check(tag + "F5 without scala-cli: scala file", o.split("\n")[0] == "scala " + f, o)
        proj = os.path.join(tmp, "proj")
        g = os.path.join(proj, "src", "main", "scala", "App.scala")
        os.makedirs(os.path.dirname(g))
        open(g, "w").write("object App\n")
        open(os.path.join(proj, "build.sbt"), "w").write("\n")
        o = run_sh(ned_cmd(build_cmd, g, "/T"), os.path.dirname(g), [fake])
        fake_tools(os.path.join(tmp, "bin2"), ["scala-cli"])
        o2 = run_sh(ned_cmd(build_cmd, f, "/T"), os.path.dirname(f), [fake, os.path.join(tmp, "bin2")])
        check(tag + "Build: sbt compile in the folder of build.sbt; scala-cli compile file outside a project",
              o.startswith("sbt compile\nin %s\n" % proj) and o2.startswith("scala-cli compile %s\n" % f), (o, o2))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
