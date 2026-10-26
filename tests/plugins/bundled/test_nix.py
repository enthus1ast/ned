"""nix: the language (colours, comments, indentation, F5, Build), its snippets, the outline without a language
server (bindings under the binding whose value holds them), nixd or nil, nixfmt or alejandra, the settings"""
import os, shutil, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from langcheck import check_language, done, fake_tools, ned_cmd, run_sh, start
from tplugins import check

SAMPLE = """# a comment: notThis = 1;
{ pkgs ? import <nixpkgs> { }, lib ? pkgs.lib }:

let
  version = "1.0";
  mkGreeting = name: "Hello, ${name}";
  /* a block comment: nope = 2; */
  script = ''
    fake = 3;
    echo ''${HOME}
  '';
in
{
  package = pkgs.stdenv.mkDerivation {
    pname = "hello";
    inherit version;
    buildInputs = with pkgs; [ nim ];
    meta.description = "a = b; not a binding";
  };
  shell = pkgs.mkShell { packages = [ pkgs.nim ]; };
  lib.helpers = rec {
    double = x: x * 2;
    four = double 2;
  };
  outputs = { self, nixpkgs }:
    let
      sys = "x86_64-linux";
    in {
      packages.${sys}.default = pkgs.hello;
      checks = { };
    };
}""".split("\n")


def run(factory, tag):
    check_language(
        factory, tag, "nix",
        {"name": "Nix", "extensions": ["nix"], "lineComment": "#", "blockComment": ["/*", "*/"], "quotes": "\"",
         "multilineStrings": True, "nameChars": "-'", "indentSize": 2, "dedent": "})]", "dedentWords": ["in"],
         "keywords": {"let", "in", "with", "rec", "inherit", "if", "then", "else", "assert"},
         "constants": {"true", "false", "null"}, "builtins": {"import", "builtins", "toString"},
         "indentAfter": {"{", "=", "let", "then", "else"}},
        ["let", "if", "fn", "drv", "shell", "flake"],
        SAMPLE,
        [("version", "variable", 0), ("mkGreeting", "function", 0), ("script", "variable", 0),
         ("package", "variable", 0), ("pname", "variable", 1), ("buildInputs", "variable", 1),
         ("meta.description", "variable", 1), ("shell", "variable", 0), ("lib.helpers", "object", 0),
         ("double", "function", 1), ("four", "variable", 1), ("outputs", "function", 0), ("sys", "variable", 1),
         ("packages.${sys}.default", "variable", 1), ("checks", "object", 1)],
        ["nix", "nix-instantiate", "nix-build", "nixd", "nil", "nixfmt", "alejandra"],
        runs=[("default.nix", "{ a = 1; }\n", {}, "nix-instantiate --eval --strict $file"),
              ("flake.nix", "{ outputs = { self }: { }; }\n", {}, "nix flake check")],
        server=["nixd"], formatter="nixfmt")

    # Build: nix build in a flake, nix-build outside one; nil and alejandra when nixd and nixfmt are not installed
    tmp = tempfile.mkdtemp(prefix="ned-nix-")
    try:
        fake = os.path.join(tmp, "bin")
        fake_tools(fake, ["nix", "nix-build", "nil", "alejandra"])
        h, ok, err = start(factory, [fake], only_path=True)
        sp = (h.reg("language", id="nix") or {}).get("spec", {}) if ok else {}
        ls = h.reg("lsp", lang="nix") if ok else None
        fm = h.reg("formatter", lang="nix") if ok else None
        check(tag + "nil and alejandra installed (no nixd, no nixfmt): nil, alejandra --quiet -",
              ok and ls and ls["cmd"] == ["nil"] and fm and fm.get("cmd") == "alejandra --quiet -", (err, ls, fm))
        done(h)
        proj = os.path.join(tmp, "proj")
        f = os.path.join(proj, "pkgs", "hello.nix")
        os.makedirs(os.path.dirname(f))
        open(f, "w").write("{ }\n")
        open(os.path.join(proj, "flake.nix"), "w").write("{ }\n")
        g = os.path.join(tmp, "loose", "default.nix")
        os.makedirs(os.path.dirname(g))
        open(g, "w").write("{ }\n")
        o = run_sh(ned_cmd(sp.get("build", ""), f, "/T"), os.path.dirname(f), [fake])
        o2 = run_sh(ned_cmd(sp.get("build", ""), g, "/T"), os.path.dirname(g), [fake])
        check(tag + "Build: nix build in the flake's folder; nix-build file outside a flake",
              o.startswith("nix build\nin %s\n" % proj) and o2.startswith("nix-build %s\n" % g), (o, o2))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
