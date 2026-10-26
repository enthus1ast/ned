"""erlang: the language (colours, comments, indentation, F5 with rebar3, escript or erlc and erl), its snippets, the
outline without a language server (functions as name/arity), ELP (or erlang_ls) and erlfmt when they are installed,
the settings"""
import os, shutil, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from langcheck import check_language, done, fake_tools, ned_cmd, run_sh, start
from tplugins import check

SAMPLE = '''%% a comment: notThis() -> ok.
-module(shapes).
-export([area/1, main/0]).

-record(square, {side = 0 :: number()}).
-type shape() :: #square{} | {circle, number()}.
-define(PI, 3.14159).
-define(SQ(X), (X) * (X)).

-spec area(shape()) -> number().
area(#square{side = S}) ->
    ?SQ(S);
area({circle, R}) ->
    ?PI * R * R.

perimeter(#square{side = S},
          N) ->
    S * N.

size(<<Len:8, _/binary>>) -> Len.

main() ->
    Msg = "fake() -> ok.",
    Doc = """
fake2() -> ok.
""",
    Pct = $%,
    io:format("~s~s~c~n", [Msg, Doc, Pct]),
    receive
        stop -> ok
    after 0 -> ok
    end.'''.split("\n")

PROJ = {"rebar.config": "{erl_opts, []}.\n"}


def run(factory, tag):
    check_language(
        factory, tag, "erlang",
        {"name": "Erlang", "extensions": ["erl", "hrl", "escript"], "files": ["rebar.config"], "lineComment": "%",
         "quotes": "\"'", "tripleQuotes": True, "capitalTypes": True, "indentSize": 4, "dedent": "})]",
         "keywords": {"case", "of", "end", "receive", "after", "fun", "when", "begin", "try", "catch", "if",
                      "andalso", "orelse", "maybe"},
         "constants": {"true", "false", "undefined"}, "indentAfter": {"->", "of", "receive", "begin", "try"},
         "dedentWords": ["end", "after", "catch", "else"]},
        ["fun", "case", "receive", "module", "gen", "test"],
        SAMPLE,
        [("shapes", "module", 0), ("square", "struct", 0), ("shape", "type", 0), ("?PI", "constant", 0),
         ("?SQ", "function", 0), ("area/1", "function", 0), ("perimeter/2", "function", 0), ("size/1", "function", 0),
         ("main/0", "function", 0)],
        ["rebar3", "escript", "erlc", "erl", "elp", "erlang_ls", "erlfmt"],
        runs=[("hello.erl", "-module(hello).\n-export([main/0]).\nmain() -> ok.\n", {}, "erlc -o /T $file"),
              ("tool.erl", "#!/usr/bin/env escript\nmain(_) -> ok.\n", {}, "escript $file"),
              ("src/shapes.erl", "-module(shapes).\n", PROJ, "rebar3 eunit --module=shapes"),
              ("test/shapes_SUITE.erl", "-module(shapes_SUITE).\n", PROJ, "rebar3 ct --suite=$d/test/shapes_SUITE")],
        server=["elp", "server"], formatter="erlfmt -")

    # erlang_ls when ELP is not installed; F5 outside a project: main/0 run after erlc; Build
    tmp = tempfile.mkdtemp(prefix="ned-erlang-")
    try:
        fake = os.path.join(tmp, "bin")
        fake_tools(fake, ["erlang_ls", "erlc", "erl", "rebar3"])
        h, ok, err = start(factory, [fake], only_path=True)
        sp = (h.reg("language", id="erlang") or {}).get("spec", {}) if ok else {}
        ls = h.reg("lsp", lang="erlang") if ok else None
        check(tag + "erlang_ls installed (no ELP): erlang_ls", ok and ls and ls["cmd"] == ["erlang_ls"], (err, ls))
        done(h)
        f = os.path.join(tmp, "loose", "hello.erl")
        os.makedirs(os.path.dirname(f))
        open(f, "w").write("-module(hello).\n")
        o = run_sh(ned_cmd(sp.get("run", ""), f, "/T"), os.path.dirname(f), [fake])
        check(tag + "F5 outside a project: erlc into ned's temporary folder, then erl runs hello:main()",
              o.startswith("erlc -o /T %s\nin %s\nerl -noshell -pa /T -s hello main -s init stop\n"
                           % (f, os.path.dirname(f))), o)
        proj = os.path.join(tmp, "proj")
        g = os.path.join(proj, "src", "app.erl")
        os.makedirs(os.path.dirname(g))
        open(g, "w").write("-module(app).\n")
        open(os.path.join(proj, "rebar.config"), "w").write("{erl_opts, []}.\n")
        o = run_sh(ned_cmd(sp.get("build", ""), g, "/T"), os.path.dirname(g), [fake])
        o2 = run_sh(ned_cmd(sp.get("build", ""), f, "/T"), os.path.dirname(f), [fake])
        check(tag + "Build: rebar3 compile in the project's folder; erlc outside one",
              o.startswith("rebar3 compile\nin %s\n" % proj) and o2.startswith("erlc -o /T %s\n" % f), (o, o2))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
