"""elixir: the language (colours, comments, indentation, F5), its snippets, the outline without a language server,
the first language server installed and mix format (pretend ones here), and the plugin's two settings."""
import os, shutil, stat, subprocess, tempfile
from tplugins import check

ELIXIR_SAMPLE = '''defmodule MyApp.Shapes do
  @moduledoc """
  Shapes. An example:

      defmodule Not.This do
        def nor_this, do: 1
      end
  """

  # def commented_out(x)
  defstruct [:name, sides: 0]

  @doc "The area"
  @spec area(t()) :: number()
  def area(%{sides: 0}), do: 0
  def area(shape) do
    shape.sides * 2
  end

  defp helper(a, b \\\\ 1), do: a + b

  def valid?(x) when is_map(x), do: true
  def valid?(_), do: false

  defmacro my_macro(ast) do
    quote do
      unquote(ast)
    end
  end

  defguard is_even(n) when rem(n, 2) == 0

  defdelegate size(s), to: MyApp.Size

  def long(
        a,
        {b, c}
      ) do
    {a, b, c}
  end

  defmodule Inner do
    def run, do: :ok
  end

  def after_inner, do: :ok
end

defprotocol MyApp.Describe do
  def describe(x)
end

defimpl MyApp.Describe, for: MyApp.Shapes do
  def describe(_), do: "shape"
end

defmodule MyApp.Error do
  defexception message: "oops"
end

defmodule MyApp.ShapesTest do
  use ExUnit.Case

  describe "area/1" do
    test "a square" do
      assert 1 == 1
    end
  end

  test "valid?" do
    assert true
  end
end'''.split("\n")


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


SERVERS = ["expert", "nextls", "lexical", "start_lexical.sh", "elixir-ls", "language_server.sh"]


def run(factory, tag):
    tmp = tempfile.mkdtemp(prefix="ned-elixir-")
    try:
        _run(factory, tag, tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _run(factory, tag, tmp):
    h, ok, err = start(factory)
    check(tag + "it starts", ok, err)
    if not ok:
        return
    lang = h.reg("language", id="elixir")
    sp = (lang or {}).get("spec", {})
    check(tag + "the language: .ex and .exs (mix.exs too), Elixir, # comments, \" and ' strings, \"\"\" heredocs, "
          "strings over lines",
          sp.get("extensions") == ["ex", "exs"] and sp.get("name") == "Elixir" and sp.get("lineComment") == "#" and
          sp.get("quotes") == "\"'" and sp.get("tripleQuotes") is True and sp.get("multilineStrings") is True and
          "blockComment" not in sp, sp)
    check(tag + "its words: keywords, modules (Capitalised) as types, valid? and save! as names, @attributes, "
          "built-ins, ExUnit's",
          {"def", "defp", "defmodule", "do", "end", "fn", "case", "cond", "with", "when", "receive", "quote"} <=
          set(sp.get("keywords", [])) and sp.get("capitalTypes") is True and "types" not in sp and
          sp.get("nameChars") == "?!" and sp.get("decorators") is True and
          {"true", "false", "nil", "__MODULE__"} <= set(sp.get("constants", [])) and
          {"is_atom", "inspect", "assert", "test", "describe"} <= set(sp.get("builtins", [])) and
          "def" in sp.get("functionWords", []) and "defmodule" in sp.get("classWords", []), sp)
    check(tag + "indentation: a level after do, fn, ->, else … and brackets (two spaces); end, else, rescue, catch "
          "and after typed alone go back one",
          {"do", "fn", "->", "else", "rescue", "after"} <= set(sp.get("indentAfter", [])) and
          sp.get("dedent") == "})]" and sp.get("indentSize") == 2 and
          sp.get("dedentWords") == ["end", "else", "rescue", "catch", "after"], sp)
    check(tag + "the ned it needs, its two settings (named as its own when it starts)",
          (h.reg("requires") or {}).get("spec") == ">= 6.25" and h.reg("setting", key="server") is not None and
          h.reg("setting", key="formatter") is not None and
          ("elixir", "server") in h.asked_settings and ("elixir", "formatter") in h.asked_settings,
          (h.reg("requires"), h.asked_settings))
    trig = {r["trigger"] for r in h.regs if r["kind"] == "snippet" and r["lang"] == "elixir"}
    check(tag + "snippets: defmodule, def, defp, case, test",
          trig == {"defmodule", "def", "defp", "case", "test"} and
          h.reg("snippet", lang="elixir", trigger="defmodule")["body"] == "defmodule ${1:Name} do\n\t$0\nend" and
          not any(nested(r["body"]) for r in h.regs if r["kind"] == "snippet"), trig)
    if any(shutil.which(x) for x in SERVERS + ["mix"]):
        check(tag + "(an Elixir language server or mix is installed here: the checks without them left out)", True)
    else:
        check(tag + "no language server installed: the outline from the plugin; no mix: no formatter",
              h.reg("lsp", lang="elixir") is None and h.reg("symbols", lang="elixir") is not None and
              h.reg("formatter", lang="elixir") is None, h.regs[-4:])
        h.lines = ELIXIR_SAMPLE
        r = h.call(h.reg("symbols", lang="elixir")["cb"], {"buf": 1})
        v = (r or {}).get("value") or []
        want = [("MyApp.Shapes", "module", 0), ("%MyApp.Shapes{}", "struct", 1), ("area/1", "function", 1),
                ("helper/2", "function", 1), ("valid?/1", "function", 1), ("my_macro/1", "function", 1),
                ("is_even/1", "function", 1), ("size/1", "function", 1), ("long/2", "function", 1),
                ("Inner", "module", 1), ("run/0", "function", 2), ("after_inner/0", "function", 1),
                ("MyApp.Describe", "interface", 0), ("describe/1", "function", 1),
                ("MyApp.Describe for MyApp.Shapes", "module", 0), ("describe/1", "function", 1),
                ("MyApp.Error", "module", 0), ("%MyApp.Error{}", "struct", 1), ("MyApp.ShapesTest", "module", 0),
                ("area/1", "section", 1), ("a square", "function", 2), ("valid?", "function", 1)]
        check(tag + "the outline: modules, a protocol and its implementation, structs, functions as name/arity "
              "(their clauses once, arguments over lines counted), describe and test — the heredoc, comments "
              "and quote's code left out", names(v) == want, names(v))
        by = {(s["name"], s["kind"]): s for s in v}
        check(tag + "the outline's details and places: def, defp, defmacro, defguard, test",
              by.get(("helper/2", "function"), {}).get("detail") == "defp" and
              by.get(("my_macro/1", "function"), {}).get("detail") == "defmacro" and
              by.get(("is_even/1", "function"), {}).get("detail") == "defguard" and
              by.get(("a square", "function"), {}).get("detail") == "test" and
              (by.get(("area/1", "function"), {}).get("line"), by.get(("area/1", "function"), {}).get("col")) ==
              (14, 6), v)
    # F5: mix test for a test, mix run file.exs for a script, mix run for the rest, elixir outside a project
    run_cmd = sp.get("run", "")
    fake = os.path.join(tmp, "bin")
    fake_tools(fake, ["elixir", "elixirc", "mix", "nextls", "elixir-ls", "my-ls", "my-fmt"])
    proj = os.path.join(tmp, "app")
    os.makedirs(os.path.join(proj, "lib", "app"))
    os.makedirs(os.path.join(proj, "test"))
    os.makedirs(os.path.join(proj, "priv"))
    open(os.path.join(proj, "mix.exs"), "w").write("defmodule App.MixProject do\nend\n")
    lib = os.path.join(proj, "lib", "app", "util.ex")
    tst = os.path.join(proj, "test", "util_test.exs")
    seeds = os.path.join(proj, "priv", "seeds.exs")
    loose = os.path.join(tmp, "loose", "hello.exs")
    os.makedirs(os.path.dirname(loose))
    for p in (lib, tst, seeds, loose):
        open(p, "w").write("IO.puts(1)\n")
    o = run_sh(ned_cmd(run_cmd, tst, "/T"), os.path.dirname(tst), [fake])
    check(tag + "F5 on a test: mix test file, in the project's folder",
          o.startswith("mix test %s\nin %s\n" % (tst, proj)), o)
    o = run_sh(ned_cmd(run_cmd, seeds, "/T"), os.path.dirname(seeds), [fake])
    check(tag + "F5 on a script of the project: mix run file", o.startswith("mix run %s\nin %s\n" % (seeds, proj)), o)
    o = run_sh(ned_cmd(run_cmd, lib, "/T"), os.path.dirname(lib), [fake])
    check(tag + "F5 on the project's code: mix run", o.startswith("mix run\nin %s\n" % proj), o)
    o = run_sh(ned_cmd(run_cmd, loose, "/T"), os.path.dirname(loose), [fake])
    check(tag + "F5 outside a project: elixir file, in its folder",
          o.startswith("elixir %s\nin %s\n" % (loose, os.path.dirname(loose))), o)
    o = run_sh(ned_cmd(sp.get("build", ""), lib, "/T"), os.path.dirname(lib), [fake])
    o2 = run_sh(ned_cmd(sp.get("build", ""), loose, "/T"), os.path.dirname(loose), [fake])
    check(tag + "Build: mix compile in the project's folder; elixirc for a file of its own (its .beam files in "
          "ned's temporary folder)", o.startswith("mix compile\nin %s\n" % proj) and
          o2.startswith("elixirc -o /T/ned_beam %s\nin %s\n" % (loose, os.path.dirname(loose))), (o, o2))
    hosts_done(h)
    # installed (pretend ones): the first language server of the list, mix format in the project's folder
    h, ok, err = start(factory, [fake])
    ls = h.reg("lsp", lang="elixir") if ok else None
    fm = h.reg("formatter", lang="elixir") if ok else None
    check(tag + "next-ls and elixir-ls installed: the first of the list, nextls --stdio (no outline of the plugin's)",
          ok and ls and ls["cmd"] == ["nextls", "--stdio"] and h.reg("symbols", lang="elixir") is None, (err, ls))
    ok2 = fm and "mix format -" in fm.get("cmd", "")
    o1 = run_sh(ned_cmd(fm["cmd"], lib, "/T"), os.path.dirname(lib), [fake], "x  = 1\n") if ok2 else ""
    o2 = run_sh(ned_cmd(fm["cmd"], loose, "/T"), os.path.dirname(loose), [fake], "y = 2\n") if ok2 else ""
    check(tag + "mix installed: mix format - formats (the text on its stdin) in the project's folder — in the "
          "file's own outside one", ok2 and o1 == "mix format -\nin %s\nx  = 1\n" % proj and
          o2 == "mix format -\nin %s\ny = 2\n" % os.path.dirname(loose), (fm, o1, o2))
    hosts_done(h)
    fake2 = os.path.join(tmp, "bin2")
    fake_tools(fake2, ["expert", "lexical", "mix"])
    h, ok, err = start(factory, [fake2])
    ls = h.reg("lsp", lang="elixir") if ok else None
    check(tag + "Expert installed (and Lexical): expert --stdio", ok and ls and ls["cmd"] == ["expert", "--stdio"],
          (err, ls))
    hosts_done(h)
    h, ok, err = start(factory, [fake], {"server": "my-ls --stdio", "formatter": "off"})
    ls = h.reg("lsp", lang="elixir") if ok else None
    check(tag + "plugins.elixir.server: the command given; plugins.elixir.formatter \"off\": none",
          ok and ls and ls["cmd"] == ["my-ls", "--stdio"] and h.reg("formatter", lang="elixir") is None, (err, ls))
    hosts_done(h)
    h, ok, err = start(factory, [fake], {"server": "off", "formatter": "my-fmt -"})
    fm = h.reg("formatter", lang="elixir") if ok else None
    check(tag + "plugins.elixir.server \"off\": none (the outline from the plugin); another formatter's command",
          ok and h.reg("lsp", lang="elixir") is None and h.reg("symbols", lang="elixir") is not None and
          fm and fm.get("cmd") == "my-fmt -", (err, fm))
    hosts_done(h)
