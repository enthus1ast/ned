"""odin: the language (colours, comments, indentation, F5), its snippets, the outline without a language server,
ols and odinfmt when they are installed (pretend ones here), and the plugin's two settings."""
import os, shutil, stat, subprocess, tempfile
from tplugins import check

ODIN_SAMPLE = """package main

import "core:fmt"

// a comment :: not a declaration
/* a block /* nested */
still :: a comment */
Vec2 :: [2]f32
MAX :: 100 // the most
Shape :: union { Circle, Square }
Color :: enum { Red, Green }
Circle :: struct {
\tr: f32,
}
@(private)
helper :: proc(x: int) -> int {
\tinner :: proc() {
\t}
\tN :: 3
\treturn x * N
}
@(require_results) area :: #force_inline proc "contextless" (c: Circle) -> f32 { return c.r }
print :: proc{print_int, print_str}
Callback :: #type proc(x: int)
s := `raw :: not
a decl :: either`
main :: proc() {
\tfmt.println("x :: y")
}
foreign libc {
\tputs :: proc(s: cstring) -> i32 ---
}""".split("\n")


def fake_tools(d, names):
    """pretend programs: each prints its name, its arguments and its folder, then what it was given"""
    os.makedirs(d, exist_ok=True)
    for n in names:
        p = os.path.join(d, n)
        with open(p, "w") as f:
            f.write('#!/bin/sh\necho "%s $*"\necho "in $PWD"\ncat\n' % n)
        os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC)


def start(factory, path_dirs=(), settings=None):
    """a host for the plugin (with these folders first on PATH, these settings of its), started; the settings it
    asked for are kept as (plugin, key)"""
    old = os.environ.get("PATH", "")
    if path_dirs:
        os.environ["PATH"] = os.pathsep.join(list(path_dirs) + [old])
    try:
        h = factory()
    finally:
        os.environ["PATH"] = old
    h.settings = dict(settings or {})
    h.asked_settings = []
    base = h.api

    def api(j, _base=base, _h=h):
        if j["fn"] == "setting":
            _h.asked_settings.append((j.get("plugin"), j.get("args", {}).get("key")))
        return _base(j)
    h.api = api
    ok = h.build_ok and h.pump(lambda j: j.get("t") == "ready", 90)
    return h, ok, (h.build_err if not h.build_ok else "")


def ned_cmd(cmd, path, tmp):
    """a command as ned expands it ($file $dir $name $tmp $root)"""
    return (cmd.replace("$file", path).replace("$dir", os.path.dirname(path))
            .replace("$name", os.path.splitext(os.path.basename(path))[0]).replace("$tmp", tmp)
            .replace("$root", os.path.dirname(path)))


def run_sh(cmd, cwd, path_dirs, stdin=""):
    """the command run as ned runs a formatter or F5's command: sh -c, in the file's folder"""
    env = dict(os.environ, PATH=os.pathsep.join(list(path_dirs) + [os.environ.get("PATH", "")]))
    r = subprocess.run(["sh", "-c", cmd], cwd=cwd, input=stdin, capture_output=True, text=True, env=env, timeout=30)
    return r.stdout + r.stderr


def nested(body):
    """a placeholder inside another (${1:a ${2:b}}): ned's snippets end a placeholder at the first }"""
    i = body.find("${")
    while i >= 0:
        e = body.find("}", i)
        if e < 0 or "${" in body[i + 2:e]:
            return True
        i = body.find("${", e)
    return False


def names(syms):
    return [(s["name"], s["kind"], s["depth"]) for s in syms]


def hosts_done(h):
    """the host stopped now — the runner's close at the end then does nothing (a second quit written to a host
    that has gone would only leave Python a broken pipe to complain of as it exits)"""
    h.close()
    h.close = lambda: None


def run(factory, tag):
    tmp = tempfile.mkdtemp(prefix="ned-odin-")
    try:
        _run(factory, tag, tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _run(factory, tag, tmp):
    h, ok, err = start(factory)
    check(tag + "it starts", ok, err)
    if not ok:
        return
    lang = h.reg("language", id="odin")
    sp = (lang or {}).get("spec", {})
    check(tag + "the language: .odin, Odin, // and /* */ comments (nested), \" and ` strings (` ones over lines), "
          "'r' runes",
          sp.get("extensions") == ["odin"] and sp.get("name") == "Odin" and sp.get("lineComment") == "//" and
          sp.get("blockComment") == ["/*", "*/"] and sp.get("nestedComments") is True and
          set(sp.get("quotes", "")) == set("\"'`") and sp.get("multilineStrings") is True and
          sp.get("charLiterals") is True, sp)
    check(tag + "its words: keywords, types (Capitalised ones too), constants, built-ins (the names of #directives "
          "and @(attributes) too), @attributes",
          sp.get("capitalTypes") is True and sp.get("decorators") is True and
          {"proc", "struct", "defer", "or_return", "switch", "when", "using"} <= set(sp.get("keywords", [])) and
          {"int", "f32", "rawptr", "cstring", "typeid", "rune"} <= set(sp.get("types", [])) and
          {"true", "false", "nil"} <= set(sp.get("constants", [])) and
          {"len", "make", "delete", "partial", "require_results"} <= set(sp.get("builtins", [])), sp)
    check(tag + "indentation: a level after { ( [ (tabs, four columns wide), back on } ) ]",
          sp.get("indentAfter") == ["{", "(", "["] and sp.get("dedent") == "})]" and sp.get("tabs") is True and
          sp.get("indentSize") == 4, sp)
    check(tag + "the ned it needs, its two settings (named as its own when it starts)",
          (h.reg("requires") or {}).get("spec") == ">= 6.25" and h.reg("setting", key="server") is not None and
          h.reg("setting", key="formatter") is not None and
          ("odin", "server") in h.asked_settings and ("odin", "formatter") in h.asked_settings,
          (h.reg("requires"), h.asked_settings))
    trig = {r["trigger"] for r in h.regs if r["kind"] == "snippet" and r["lang"] == "odin"}
    sn = h.reg("snippet", lang="odin", trigger="proc")
    check(tag + "snippets: proc, struct, for, switch, if (no placeholder inside another: ned's do not nest)",
          trig == {"proc", "struct", "for", "switch", "if"} and sn["body"].startswith("${1:name} :: proc(") and
          not any(nested(r["body"]) for r in h.regs if r["kind"] == "snippet"), (trig, sn))
    # without ols and odinfmt: the outline from the plugin's scan, no server, no formatter
    if shutil.which("ols") or shutil.which("odinfmt"):
        check(tag + "(ols or odinfmt is installed here: the checks without them left out)", True)
    else:
        check(tag + "ols not installed: no language server, the outline from the plugin; odinfmt not: no formatter",
              h.reg("lsp", lang="odin") is None and h.reg("symbols", lang="odin") is not None and
              h.reg("formatter", lang="odin") is None, h.regs[-4:])
        h.lines = ODIN_SAMPLE
        r = h.call(h.reg("symbols", lang="odin")["cb"], {"buf": 1})
        v = (r or {}).get("value") or []
        want = [("Vec2", "type", 0), ("MAX", "constant", 0), ("Shape", "type", 0), ("Color", "enum", 0),
                ("Circle", "struct", 0), ("helper", "function", 0), ("inner", "function", 1), ("N", "constant", 1),
                ("area", "function", 0), ("print", "function", 0), ("Callback", "type", 0), ("main", "function", 0),
                ("puts", "function", 0)]
        check(tag + "the outline: procedures, types, constants — nested ones under theirs; comments, strings, "
              "a raw string over two lines and an attribute before it on the line left out",
              names(v) == want, names(v))
        by = {s["name"]: s for s in v}
        check(tag + "the outline's details and places: a signature, a group, the value of a constant",
              by.get("helper", {}).get("detail") == "proc(x: int) -> int" and
              by.get("area", {}).get("detail") == '#force_inline proc "contextless" (c: Circle) -> f32' and
              by.get("print", {}).get("detail") == "proc{print_int, print_str}" and
              by.get("MAX", {}).get("detail") == "100" and by.get("puts", {}).get("detail") == "proc(s: cstring) -> i32"
              and by.get("Circle", {}).get("detail") == "struct" and
              (by.get("area", {}).get("line"), by.get("area", {}).get("col")) == (21, 19) and
              (by.get("inner", {}).get("line"), by.get("inner", {}).get("col")) == (16, 1), v)
    # F5: the folder's package, or the file alone when more of the folder's files have a main
    run_cmd = sp.get("run", "")
    fake = os.path.join(tmp, "bin")
    fake_tools(fake, ["odin", "ols", "odinfmt", "my-ols", "my-fmt"])
    proj = os.path.join(tmp, "proj")
    os.makedirs(proj)
    f = os.path.join(proj, "main.odin")
    open(f, "w").write("package main\n\nmain :: proc() {\n}\n")
    open(os.path.join(proj, "util.odin"), "w").write("package main\n\nhelp :: proc() {}\n")
    o = run_sh(ned_cmd(run_cmd, f, "/T"), proj, [fake])
    check(tag + "F5: odin run . — the file's folder, its package", o.startswith("odin run . -out:/T/ned_run"), o)
    open(os.path.join(proj, "other.odin"), "w").write("package main\n\nmain :: proc() {\n}\n")
    o = run_sh(ned_cmd(run_cmd, f, "/T"), proj, [fake])
    check(tag + "F5: odin run file.odin -file — when another file of the folder has a main too",
          o.startswith("odin run %s -file -out:/T/ned_run" % f), o)
    o = run_sh(ned_cmd(sp.get("build", ""), f, "/T"), proj, [fake])
    o2 = run_sh(ned_cmd(sp.get("check", ""), f, "/T"), proj, [fake])
    check(tag + "Build and the check the same way: odin build file.odin -file, odin check (file:line:col)",
          o.startswith("odin build %s -file\n" % f) and
          o2.startswith("odin check %s -file -error-pos-style:unix\n" % f), (o, o2))
    os.remove(os.path.join(proj, "other.odin"))
    o = run_sh(ned_cmd(sp.get("build", ""), f, "/T"), proj, [fake])
    o2 = run_sh(ned_cmd(sp.get("check", ""), f, "/T"), proj, [fake])
    check(tag + "… and for the package: odin build ., odin check . (a package without a main too)",
          o.startswith("odin build .\n") and o2.startswith("odin check . -no-entry-point -error-pos-style:unix\n"),
          (o, o2))
    hosts_done(h)
    # ols and odinfmt installed (pretend ones)
    h, ok, err = start(factory, [fake])
    ls = h.reg("lsp", lang="odin") if ok else None
    fm = h.reg("formatter", lang="odin") if ok else None
    check(tag + "ols installed: it is the language server (and the plugin's outline is not given)",
          ok and ls and ls["cmd"] == ["ols"] and h.reg("symbols", lang="odin") is None, (err, ls))
    check(tag + "odinfmt installed: it formats, the text on its stdin",
          fm and fm.get("cmd") == "odinfmt -stdin" and
          run_sh(ned_cmd(fm["cmd"], f, "/T"), proj, [fake], "x :: 1\n") == "odinfmt -stdin\nin %s\nx :: 1\n" % proj,
          fm)
    hosts_done(h)
    # the settings: another server, no formatter — and no server, another formatter
    h, ok, err = start(factory, [fake], {"server": "my-ols --stdio", "formatter": "off"})
    ls = h.reg("lsp", lang="odin") if ok else None
    check(tag + "plugins.odin.server: the command given; plugins.odin.formatter \"off\": none",
          ok and ls and ls["cmd"] == ["my-ols", "--stdio"] and h.reg("formatter", lang="odin") is None, (err, ls))
    hosts_done(h)
    h, ok, err = start(factory, [fake], {"server": "off", "formatter": "my-fmt --tabs"})
    fm = h.reg("formatter", lang="odin") if ok else None
    check(tag + "plugins.odin.server \"off\": none (the outline from the plugin); another formatter's command",
          ok and h.reg("lsp", lang="odin") is None and h.reg("symbols", lang="odin") is not None and
          fm and fm.get("cmd") == "my-fmt --tabs", (err, fm))
    hosts_done(h)
    h, ok, err = start(factory, [], {"server": "no-such-server", "formatter": "no-such-fmt"})
    check(tag + "a command in the settings that is not installed: left out, and the log says so",
          ok and h.reg("lsp", lang="odin") is None and h.reg("formatter", lang="odin") is None and
          any("no-such-server is not installed" in l for l in h.logs) and
          any("no-such-fmt is not installed" in l for l in h.logs), (err, h.logs[-4:]))
    hosts_done(h)
