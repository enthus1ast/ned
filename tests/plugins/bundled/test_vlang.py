"""vlang: the V language (colours, comments, tabs, F5 — v test for a _test.v file, v run . in a module's folder, else
v run on the file), its snippets, the outline without a language server (the module, functions, methods with their
receiver, structs, unions, interfaces with their methods, enums, types, constants — not in comments, nested comments
or strings), v-analyzer and v fmt when they are installed (pretend ones here), the plugin's two settings, and the
check on save run the way ned runs it"""
import os, shutil, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from langcheck import check_language, start, done, fake_tools, run_sh
from tplugins import check

SAMPLE = """module geometry

import math

/* fn not_this() {} /* nested */ struct NotThis {} */
// fn nor_this() {}
pub const pi2 = math.pi * 2

const (
\tlimit = 10
\tname  = 'fn fake() {'
)

pub struct Point {
pub mut:
\tx f64
\ty f64
}

union Bits {
\ti int
\tf f32
}

interface Shape {
\tarea() f64
\tname() string
}

enum Color {
\tred
\tgreen
}

type Number = int | f64

@[inline]
pub fn (p Point) dist(q Point) f64 {
\ts := 'a string that
goes on fn fake2() {'
\treturn math.sqrt(p.x * q.x)
}

fn C.puts(&char) int

fn main() {
\tprintln('hello')
}""".split("\n")


def run(factory, tag):
    check_language(
        factory, tag, "v",
        {"name": "V", "extensions": ["v", "vsh", "vv"], "files": ["v.mod"], "lineComment": "//",
         "blockComment": ["/*", "*/"], "nestedComments": True, "quotes": "'\"`", "multilineStrings": True,
         "capitalTypes": True, "decorators": True, "indentSize": 4, "tabs": True, "dedent": "})]",
         "keywords": {"fn", "mut", "pub", "struct", "interface", "enum", "match", "or", "module", "import", "spawn",
                      "defer", "unsafe"},
         "types": {"int", "u8", "string", "rune", "f64", "voidptr"}, "constants": {"true", "false", "none"},
         "functionWords": ["fn"]},
        ["fn", "main", "struct", "method", "if", "for", "match", "or", "test", "mod"],
        SAMPLE,
        [("geometry", "module", 0), ("pi2", "constant", 0), ("limit", "constant", 1), ("name", "constant", 1),
         ("Point", "struct", 0), ("Bits", "struct", 0), ("Shape", "interface", 0), ("area", "method", 1),
         ("name", "method", 1), ("Color", "enum", 0), ("Number", "type", 0), ("dist", "method", 0),
         ("C.puts", "function", 0), ("main", "function", 0)],
        ["v", "v-analyzer"],
        runs=[("hello.v", "fn main() {}\n", {}, "v run $file"),
              ("calc_test.v", "fn test_x() {}\n", {}, "v test $file"),
              ("app/main.v", "fn main() {}\n", {"app/v.mod": "Module {}\n"}, "v run ."),
              ("tool.vsh", "println(1)\n", {"v.mod": "Module {}\n"}, "v run $file")],
        server=["v-analyzer"], formatter="v fmt $in > $out")
    src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "plugins", "vlang",
                            "plugin.nims")).read()
    check(tag + "it says why it runs programs (permission \"shell\"), and asks for nothing else",
          'permission("shell", "' in src and 'permission("files"' not in src and 'permission("clipboard"' not in src)
    h, ok, err = start(factory, [])
    sp = (h.reg("language", id="v") or {}).get("spec", {}) if ok else {}
    done(h)
    tmp = tempfile.mkdtemp(prefix="ned-v-")
    try:
        fake = os.path.join(tmp, "bin")
        fake_tools(fake, ["v"])
        for sub, mod, want in [("one file", False, "v -check {f}"), ("a module", True, "v -check .")]:
            d = os.path.join(tmp, sub)
            os.makedirs(d)
            f = os.path.join(d, "main.v")
            open(f, "w").write("fn main() {}\n")
            if mod: open(os.path.join(d, "v.mod"), "w").write("Module {}\n")
            cmd = sp.get("check", "").replace("\"$file\"", "'" + f + "'").replace("\"$dir\"", "'" + d + "'")
            o = run_sh(cmd, d, [fake]).split("\n")
            check(tag + "the check on save, " + sub + " (its folder has a space): " + want.replace("{f}", "the file"),
                  o[0] == want.replace("{f}", f) and o[1] == "in " + d, o)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
