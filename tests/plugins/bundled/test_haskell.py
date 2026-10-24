"""haskell: the language (colours, comments, indentation, F5), its snippets, the outline without a language server,
the Haskell Language Server and ormolu or fourmolu (pretend ones here), and the plugin's two settings."""
import os, shutil, stat, subprocess, tempfile
from tplugins import check

HASKELL_SAMPLE = r'''{-# LANGUAGE OverloadedStrings #-}
-- | A module comment: notThis :: Int
module Data.Shapes
  ( Shape (..)
  , area
  ) where

import qualified Data.Map as M
import Data.List (foldl')

{- a block {- nested -}
notThisEither :: Int
-}

data Shape
  = Circle Double
  | Square Double
  deriving (Show, Eq)

newtype Name = Name String

type Table = M.Map String Int

class (Show a) => Shaped a where
  area :: a -> Double
  perimeter :: a -> Double
  perimeter _ = 0

instance Shaped Shape where
  area (Circle r) = pi * r * r
  area (Square s) = s * s
  perimeter (Square s) = 4 * s
    where
      helper = 1

instance (Show a) => Show (Tree a) where
  show _ = "tree"

-- | The total
total :: [Shape] -> Double
total = foldl' (\acc s -> acc + area s) 0

classify :: Double -> String
classify x
  | x > 10 = "big"
  | otherwise = "small"

go x = x'
  where x' = x + 1

(<+>) :: Shape -> Shape -> Double
a <+> b = area a + area b

x `near` y = abs (x - y) < 1

x, y :: Int
x = 1
y = 2

main :: IO ()
main = do
  let s = "main :: not this"
  print (total [Circle 1, Square 2])
  print 'x'
'''.split("\n")


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


SERVERS = ["haskell-language-server-wrapper", "haskell-language-server"]


def run(factory, tag):
    tmp = tempfile.mkdtemp(prefix="ned-haskell-")
    try:
        _run(factory, tag, tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _run(factory, tag, tmp):
    h, ok, err = start(factory)
    check(tag + "it starts", ok, err)
    if not ok:
        return
    lang = h.reg("language", id="haskell")
    sp = (lang or {}).get("spec", {})
    check(tag + "the language: .hs, Haskell, -- and {- -} comments (nested; {-| -} the documentation), \" strings, "
          "'c' characters — and ' in a name (foldl', x'); no -- | line (a new line would go on with another)",
          sp.get("extensions") == ["hs"] and sp.get("name") == "Haskell" and sp.get("lineComment") == "--" and
          sp.get("blockComment") == ["{-", "-}"] and sp.get("nestedComments") is True and
          sp.get("docBlockComment") == ["{-|", "-}"] and "docComment" not in sp and sp.get("quotes") == "\"'" and
          sp.get("charLiterals") is True and sp.get("nameChars") == "'", sp)
    check(tag + "its words: keywords, Capitalised names as types (classes, constructors), True False otherwise, "
          "the Prelude's functions",
          {"module", "where", "data", "newtype", "class", "instance", "do", "let", "in", "case", "of", "import",
           "deriving", "qualified"} <= set(sp.get("keywords", [])) and
          sp.get("capitalTypes") is True and "types" not in sp and
          sp.get("constants") == ["True", "False", "otherwise"] and
          {"map", "foldr", "putStrLn", "fmap", "pure"} <= set(sp.get("builtins", [])) and
          {"data", "class", "instance"} <= set(sp.get("classWords", [])), sp)
    check(tag + "indentation: a level after where, do, of, let, =, -> (two spaces)",
          {"where", "do", "of", "let", "=", "->"} <= set(sp.get("indentAfter", [])) and sp.get("indentSize") == 2, sp)
    check(tag + "the ned it needs, its two settings (named as its own when it starts)",
          (h.reg("requires") or {}).get("spec") == ">= 6.25" and h.reg("setting", key="server") is not None and
          h.reg("setting", key="formatter") is not None and
          ("haskell", "server") in h.asked_settings and ("haskell", "formatter") in h.asked_settings,
          (h.reg("requires"), h.asked_settings))
    trig = {r["trigger"] for r in h.regs if r["kind"] == "snippet" and r["lang"] == "haskell"}
    check(tag + "snippets: module, main, data, instance, case",
          trig == {"module", "main", "data", "instance", "case"} and
          h.reg("snippet", lang="haskell", trigger="main")["body"] == "main :: IO ()\nmain = do\n\t$0" and
          not any(nested(r["body"]) for r in h.regs if r["kind"] == "snippet"), trig)
    if any(shutil.which(x) for x in SERVERS + ["ormolu", "fourmolu"]):
        check(tag + "(HLS, ormolu or fourmolu is installed here: the checks without them left out)", True)
    else:
        check(tag + "no HLS installed: the outline from the plugin; no ormolu, no fourmolu: no formatter",
              h.reg("lsp", lang="haskell") is None and h.reg("symbols", lang="haskell") is not None and
              h.reg("formatter", lang="haskell") is None, h.regs[-4:])
        h.lines = HASKELL_SAMPLE
        r = h.call(h.reg("symbols", lang="haskell")["cb"], {"buf": 1})
        v = (r or {}).get("value") or []
        want = [("Data.Shapes", "module", 0), ("Shape", "type", 0), ("Name", "type", 0), ("Table", "type", 0),
                ("Shaped", "class", 0), ("area", "function", 1), ("perimeter", "function", 1),
                ("Shaped Shape", "class", 0), ("area", "function", 1), ("perimeter", "function", 1),
                ("Show (Tree a)", "class", 0), ("show", "function", 1), ("total", "function", 0),
                ("classify", "function", 0), ("go", "function", 0), ("(<+>)", "function", 0),
                ("near", "function", 0), ("x", "function", 0), ("y", "function", 0), ("main", "function", 0)]
        check(tag + "the outline: the module, types, classes and instances with their methods, functions (a "
              "signature and its equations once, guards, operators, infix ones) — pragmas, comments (nested), "
              "strings, the export list, where's bindings left out", names(v) == want, names(v))
        by = {}
        for s in v:
            by.setdefault((s["name"], s["depth"]), s)
        check(tag + "the outline's details and places: a signature's type, data, newtype, instance",
              by.get(("total", 0), {}).get("detail") == "[Shape] -> Double" and
              by.get(("area", 1), {}).get("detail") == "a -> Double" and
              by.get(("(<+>)", 0), {}).get("detail") == "Shape -> Shape -> Double" and
              by.get(("main", 0), {}).get("detail") == "IO ()" and
              by.get(("Shape", 0), {}).get("detail") == "data" and by.get(("Name", 0), {}).get("detail") == "newtype"
              and by.get(("Shaped Shape", 0), {}).get("detail") == "instance" and
              (by.get(("Shaped", 0), {}).get("line"), by.get(("Shaped", 0), {}).get("col")) == (23, 18) and
              (by.get(("near", 0), {}).get("line"), by.get(("near", 0), {}).get("col")) == (53, 3), v)
    # F5: stack run, cabal run (by the project's file above), runghc for a file of its own
    run_cmd = sp.get("run", "")
    fake = os.path.join(tmp, "bin")
    fake_tools(fake, ["stack", "cabal", "runghc", "ghc", "haskell-language-server", "fourmolu", "my-hls", "my-fmt"])
    for kind, marker, want_cmd in (("stack", "stack.yaml", "stack run"), ("cabal", "app.cabal", "cabal run"),
                                   ("cabal.project", "cabal.project", "cabal run")):
        proj = os.path.join(tmp, kind)
        os.makedirs(os.path.join(proj, "src", "App"))
        open(os.path.join(proj, marker), "w").write("\n")
        if kind == "stack":
            open(os.path.join(proj, "app.cabal"), "w").write("\n")      # (Stack's projects have one too)
        f = os.path.join(proj, "src", "App", "Main.hs")
        open(f, "w").write("main = pure ()\n")
        o = run_sh(ned_cmd(run_cmd, f, "/T"), os.path.dirname(f), [fake])
        o2 = run_sh(ned_cmd(sp.get("build", ""), f, "/T"), os.path.dirname(f), [fake])
        o3 = run_sh(ned_cmd(sp.get("check", ""), f, "/T"), os.path.dirname(f), [fake])
        want_build = want_cmd.replace(" run", " build")
        check(tag + "F5 in a project with %s: %s, Build: %s, in its folder; no check of plain ghc's"
              % (marker, want_cmd, want_build),
              o.startswith("%s\nin %s\n" % (want_cmd, proj)) and o2.startswith("%s\nin %s\n" % (want_build, proj))
              and o3 == "", (o, o2, o3))
    loose = os.path.join(tmp, "loose", "Hello.hs")
    os.makedirs(os.path.dirname(loose))
    open(loose, "w").write("main = pure ()\n")
    o = run_sh(ned_cmd(run_cmd, loose, "/T"), os.path.dirname(loose), [fake])
    check(tag + "F5 on a file of its own: runghc file, in its folder",
          o.startswith("runghc %s\nin %s\n" % (loose, os.path.dirname(loose))), o)
    o = run_sh(ned_cmd(sp.get("build", ""), loose, "/T"), os.path.dirname(loose), [fake])
    o2 = run_sh(ned_cmd(sp.get("check", ""), loose, "/T"), os.path.dirname(loose), [fake])
    check(tag + "Build of a file of its own: ghc (its .o and .hi files in ned's temporary folder); the check: "
          "ghc -fno-code", o.startswith("ghc -outputdir /T/ned_ghc %s\n" % loose) and
          o2.startswith("ghc -fno-code %s\n" % loose), (o, o2))
    hosts_done(h)
    # installed (pretend ones): haskell-language-server (no wrapper), fourmolu (no ormolu)
    h, ok, err = start(factory, [fake])
    ls = h.reg("lsp", lang="haskell") if ok else None
    fm = h.reg("formatter", lang="haskell") if ok else None
    check(tag + "haskell-language-server installed (no wrapper): it, with --lsp (no outline of the plugin's)",
          ok and ls and ls["cmd"] == ["haskell-language-server", "--lsp"] and
          h.reg("symbols", lang="haskell") is None, (err, ls))
    out = run_sh(ned_cmd(fm["cmd"], loose, "/T"), os.path.dirname(loose), [fake], "main=pure ()\n") if fm else ""
    check(tag + "fourmolu installed (no ormolu): it formats, the text on its stdin, told the file's path",
          fm and fm.get("cmd") == 'fourmolu --stdin-input-file "$file"' and
          out == "fourmolu --stdin-input-file %s\nin %s\nmain=pure ()\n" % (loose, os.path.dirname(loose)), (fm, out))
    hosts_done(h)
    fake2 = os.path.join(tmp, "bin2")
    fake_tools(fake2, ["haskell-language-server-wrapper", "haskell-language-server", "ormolu", "fourmolu"])
    h, ok, err = start(factory, [fake2])
    ls = h.reg("lsp", lang="haskell") if ok else None
    fm = h.reg("formatter", lang="haskell") if ok else None
    check(tag + "the wrapper and ormolu installed too: the wrapper first, ormolu first",
          ok and ls and ls["cmd"] == ["haskell-language-server-wrapper", "--lsp"] and fm and
          fm.get("cmd") == 'ormolu --stdin-input-file "$file"', (err, ls, fm))
    hosts_done(h)
    h, ok, err = start(factory, [fake], {"server": "my-hls --lsp", "formatter": "off"})
    ls = h.reg("lsp", lang="haskell") if ok else None
    check(tag + "plugins.haskell.server: the command given; plugins.haskell.formatter \"off\": none",
          ok and ls and ls["cmd"] == ["my-hls", "--lsp"] and h.reg("formatter", lang="haskell") is None, (err, ls))
    hosts_done(h)
    h, ok, err = start(factory, [fake], {"server": "off", "formatter": "my-fmt --stdin-input-file \"$file\""})
    fm = h.reg("formatter", lang="haskell") if ok else None
    check(tag + "plugins.haskell.server \"off\": none (the outline from the plugin); another formatter's command",
          ok and h.reg("lsp", lang="haskell") is None and h.reg("symbols", lang="haskell") is not None and
          fm and fm.get("cmd") == 'my-fmt --stdin-input-file "$file"', (err, fm))
    hosts_done(h)
