"""ocaml — the language (colours, (* *) comments, indentation, F5 with dune or ocaml), its snippets, the outline,
ocamllsp and ocamlformat when they are installed, the settings"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from langcheck import check_language

SAMPLE = '''(* a comment: let nope = 1 (* nested: let nope2 = 2 *) still *)
open Printf

type shape =
  | Square of float
  | Circle of float
and point = { x : float; y : float }

exception Bad_shape of string

external time : unit -> float = "caml_sys_time"

let pi = 3.14159

let area s =
  let sq x = x *. x in      (* a local let: not in the outline *)
  match s with
  | Square a -> sq a
  | Circle r -> pi *. sq r

let rec fact n = if n = 0 then 1 else n * fact (n - 1)
and other n = n

let s = "let fake = 1"
let q = {|let fake2 = 2|}

module Geometry = struct
  let double x = 2. *. x
  module Inner = struct
    let deep = 1
  end
  type t = int
end

module type SHOW = sig
  val show : int -> string
end

let () = printf "%f\\n" (area (Square 2.))'''.split("\n")


def run(factory, tag):
    check_language(
        factory, tag, "ocaml",
        {"name": "OCaml", "extensions": ["ml", "mli", "mll", "mly"], "blockComment": ["(*", "*)"],
         "nestedComments": True, "charLiterals": True, "capitalTypes": True, "indentSize": 2, "dedent": ")]}",
         "keywords": {"let", "rec", "in", "match", "with", "module", "struct", "sig", "end", "type", "fun",
                      "function", "begin", "open"},
         "types": {"int", "float", "string", "list", "option"}, "constants": {"true", "false", "None", "Some"},
         "build": "dune build"},
        ["let", "letrec", "match", "type", "module", "sig", "test"],
        SAMPLE,
        [("shape", "type", 0), ("point", "type", 0), ("Bad_shape", "struct", 0), ("time", "function", 0),
         ("pi", "variable", 0), ("area", "function", 0), ("fact", "function", 0), ("other", "function", 0),
         ("s", "variable", 0), ("q", "variable", 0), ("Geometry", "module", 0), ("double", "function", 1),
         ("Inner", "module", 1), ("deep", "variable", 2), ("t", "type", 1), ("SHOW", "module", 0),
         ("show", "function", 1)],
        ["ocaml", "dune", "ocamllsp", "ocamlformat"],
        runs=[("hello.ml", "let () = print_endline \"hi\"\n", {}, "ocaml $file"),
              ("bin/main.ml", "let () = ()\n", {"dune-project": "(lang dune 3.0)\n"}, "dune exec ./bin/main.exe"),
              ("main.ml", "let () = ()\n", {"dune-project": "(lang dune 3.0)\n"}, "dune exec ./main.exe"),
              ("test/test_app.ml", "let () = ()\n", {"dune-project": "(lang dune 3.0)\n"}, "dune test")],
        server=["ocamllsp"], formatter="ocamlformat --enable-outside-detected-project --name \"$file\" -")
