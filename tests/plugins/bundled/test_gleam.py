"""gleam: the language (colours, comments, indentation, F5), its snippets, the outline without a language server,
gleam lsp and gleam format when gleam is installed (a pretend one here), and the plugin's two settings."""
import os, shutil, stat, subprocess, tempfile
from tplugins import check

GLEAM_SAMPLE = """//// A module's documentation: pub fn not_this() {
import gleam/io
import gleam/list.{map}

/// A doc comment :: fn nor_this
pub type Shape {
  Circle(radius: Float)
  Square(side: Float)
  Point
}

pub opaque type Counter {
  Counter(value: Int)
}

type Alias =
  List(Int)

pub type Id =
  Int

pub const greeting = "fn hello() {"

const max: Int = 10

@external(erlang, "lists", "reverse")
pub fn reverse(list: List(a)) -> List(a)

pub fn area(shape: Shape) -> Float {
  case shape {
    Circle(r) -> r *. r *. 3.14
    Square(s) -> s *. s
    Point -> 0.0
  }
}

fn helper(
  a: Int,
  b: Int,
) -> Int {
  let s = "a string over two lines
pub fn not_a_fn() {"
  a + b
}

pub fn main() {
  io.println(greeting)
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
    tmp = tempfile.mkdtemp(prefix="ned-gleam-")
    try:
        _run(factory, tag, tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _run(factory, tag, tmp):
    h, ok, err = start(factory)
    check(tag + "it starts", ok, err)
    if not ok:
        return
    lang = h.reg("language", id="gleam")
    sp = (lang or {}).get("spec", {})
    check(tag + "the language: .gleam, Gleam, // comments (/// and //// the documentation), \" strings over lines",
          sp.get("extensions") == ["gleam"] and sp.get("name") == "Gleam" and sp.get("lineComment") == "//" and
          sp.get("docComment") == "///" and sp.get("quotes") == "\"" and sp.get("multilineStrings") is True and
          "blockComment" not in sp, sp)
    check(tag + "its words: keywords, Capitalised names as types (constructors too), True False Nil, "
          "@attributes, a type's name after `type`",
          {"fn", "pub", "case", "let", "use", "type", "opaque", "import", "const", "todo", "panic", "echo"} <=
          set(sp.get("keywords", [])) and sp.get("capitalTypes") is True and "types" not in sp and
          sp.get("constants") == ["True", "False", "Nil"] and sp.get("decorators") is True and
          sp.get("classWords") == ["type"], sp)
    check(tag + "indentation: a level after { ( [ -> = (two spaces), back on } ) ]",
          sp.get("indentAfter") == ["{", "(", "[", "->", "="] and sp.get("dedent") == "})]" and
          sp.get("indentSize") == 2 and not sp.get("tabs"), sp)
    check(tag + "the ned it needs, its two settings (named as its own when it starts)",
          (h.reg("requires") or {}).get("spec") == ">= 6.25" and h.reg("setting", key="server") is not None and
          h.reg("setting", key="formatter") is not None and
          ("gleam", "server") in h.asked_settings and ("gleam", "formatter") in h.asked_settings,
          (h.reg("requires"), h.asked_settings))
    trig = {r["trigger"] for r in h.regs if r["kind"] == "snippet" and r["lang"] == "gleam"}
    check(tag + "snippets: pub (a pub fn), fn, type, case, use",
          trig == {"pub", "fn", "type", "case", "use"} and
          h.reg("snippet", lang="gleam", trigger="pub")["body"].startswith("pub fn ${1:name}(") and
          h.reg("snippet", lang="gleam", trigger="use")["body"].startswith("use ") and
          not any(nested(r["body"]) for r in h.regs if r["kind"] == "snippet"), trig)
    if shutil.which("gleam"):
        check(tag + "(gleam is installed here: the checks without it left out)", True)
    else:
        check(tag + "gleam not installed: no language server, the outline from the plugin, no formatter",
              h.reg("lsp", lang="gleam") is None and h.reg("symbols", lang="gleam") is not None and
              h.reg("formatter", lang="gleam") is None, h.regs[-4:])
        h.lines = GLEAM_SAMPLE
        r = h.call(h.reg("symbols", lang="gleam")["cb"], {"buf": 1})
        v = (r or {}).get("value") or []
        want = [("Shape", "type", 0), ("Circle", "constructor", 1), ("Square", "constructor", 1),
                ("Point", "constructor", 1), ("Counter", "type", 0), ("Counter", "constructor", 1),
                ("Alias", "type", 0), ("Id", "type", 0), ("greeting", "constant", 0), ("max", "constant", 0),
                ("reverse", "function", 0), ("area", "function", 0), ("helper", "function", 0),
                ("main", "function", 0)]
        check(tag + "the outline: functions, types with their constructors, constants — comments, strings (one over "
              "two lines) and the patterns of a case left out", names(v) == want, names(v))
        by = {(s["name"], s["kind"]): s for s in v}
        check(tag + "the outline's details and places: a signature, pub, opaque, a constructor's fields",
              by.get(("area", "function"), {}).get("detail") == "pub (shape: Shape) -> Float" and
              by.get(("reverse", "function"), {}).get("detail") == "pub (list: List(a)) -> List(a)" and
              by.get(("helper", "function"), {}).get("detail") == "(…)" and
              by.get(("Counter", "type"), {}).get("detail") == "pub opaque type" and
              by.get(("Alias", "type"), {}).get("detail") == "type =" and
              by.get(("Circle", "constructor"), {}).get("detail") == "(radius: Float)" and
              by.get(("greeting", "constant"), {}).get("detail") == "pub const" and
              (by.get(("area", "function"), {}).get("line"), by.get(("area", "function"), {}).get("col")) == (28, 7),
              v)
    # F5: gleam run in the project (gleam.toml above the file), gleam test for a file of its test folder
    run_cmd = sp.get("run", "")
    fake = os.path.join(tmp, "bin")
    fake_tools(fake, ["gleam", "my-lsp", "my-fmt"])
    proj = os.path.join(tmp, "app")
    os.makedirs(os.path.join(proj, "src", "app"))
    os.makedirs(os.path.join(proj, "test"))
    open(os.path.join(proj, "gleam.toml"), "w").write('name = "app"\n')
    f = os.path.join(proj, "src", "app", "util.gleam")
    open(f, "w").write("pub fn main() {\n  Nil\n}\n")
    o = run_sh(ned_cmd(run_cmd, f, "/T"), os.path.dirname(f), [fake])
    check(tag + "F5: gleam run, in the project's folder", o.startswith("gleam run\nin %s\n" % proj), o)
    t = os.path.join(proj, "test", "app_test.gleam")
    open(t, "w").write("pub fn main() {\n  Nil\n}\n")
    o = run_sh(ned_cmd(run_cmd, t, "/T"), os.path.dirname(t), [fake])
    check(tag + "F5 on a test: gleam test", o.startswith("gleam test\nin %s\n" % proj), o)
    check(tag + "Build: gleam build; the check: gleam check",
          sp.get("build") == "gleam build" and sp.get("check") == "gleam check", sp)
    hosts_done(h)
    # gleam installed (a pretend one): its language server and its formatter
    h, ok, err = start(factory, [fake])
    ls = h.reg("lsp", lang="gleam") if ok else None
    fm = h.reg("formatter", lang="gleam") if ok else None
    check(tag + "gleam installed: gleam lsp is the language server (and the plugin's outline is not given)",
          ok and ls and ls["cmd"] == ["gleam", "lsp"] and h.reg("symbols", lang="gleam") is None, (err, ls))
    check(tag + "gleam installed: gleam format --stdin formats, the text on its stdin",
          fm and fm.get("cmd") == "gleam format --stdin" and
          run_sh(ned_cmd(fm["cmd"], f, "/T"), os.path.dirname(f), [fake], "pub fn x() { 1 }\n") ==
          "gleam format --stdin\nin %s\npub fn x() { 1 }\n" % os.path.dirname(f), fm)
    hosts_done(h)
    h, ok, err = start(factory, [fake], {"server": "my-lsp --stdio", "formatter": "off"})
    ls = h.reg("lsp", lang="gleam") if ok else None
    check(tag + "plugins.gleam.server: the command given; plugins.gleam.formatter \"off\": none",
          ok and ls and ls["cmd"] == ["my-lsp", "--stdio"] and h.reg("formatter", lang="gleam") is None, (err, ls))
    hosts_done(h)
    h, ok, err = start(factory, [fake], {"server": "off", "formatter": "my-fmt -"})
    fm = h.reg("formatter", lang="gleam") if ok else None
    check(tag + "plugins.gleam.server \"off\": none (the outline from the plugin); another formatter's command",
          ok and h.reg("lsp", lang="gleam") is None and h.reg("symbols", lang="gleam") is not None and
          fm and fm.get("cmd") == "my-fmt -", (err, fm))
    hosts_done(h)
