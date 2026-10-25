"""crystal — the language (colours, comments, indentation, F5: crystal run or crystal spec), its snippets, the
outline, crystalline and crystal tool format when they are installed, the settings"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from langcheck import check_language

SAMPLE = '''# a comment: def nope; end
require "json"

VERSION = "1.0"

alias Num = Int32 | Float64

module Shapes
  PI = 3.14

  abstract class Shape
    abstract def area : Float64

    def describe
      "def fake(x) — a string"
    end
  end

  class Square < Shape
    property side : Float64

    def initialize(@side : Float64)
    end

    def area : Float64
      if side > 0
        side * side
      else
        0.0
      end
    end
  end

  enum Color
    Red
    Green
  end

  struct Point
    getter x : Int32
    def initialize(@x); end
    def self.origin
      new(0)
    end
  end
end

lib LibC
  fun getpid : Int32
end

def main
  [1, 2].each do |v|
    puts v
  end
  text = <<-TXT
    def heredoc_fake
    TXT
  x = if true
        1
      else
        2
      end
end

macro twice(x)
  {{x}}; {{x}}
end'''.split("\n")


def run(factory, tag):
    check_language(
        factory, tag, "crystal",
        {"name": "Crystal", "extensions": ["cr"], "lineComment": "#", "charLiterals": True, "capitalTypes": True,
         "decorators": True, "indentSize": 2, "nameChars": "?!",
         "keywords": {"def", "class", "module", "struct", "enum", "lib", "end", "if", "elsif", "unless", "case",
                      "when", "do", "require", "property"},
         "types": {"Int32", "Float64", "String", "Array", "Hash"}, "constants": {"true", "false", "nil"},
         "dedentWords": ["end", "else", "elsif", "when", "in", "rescue", "ensure"], "build": "shards build"},
        ["def", "class", "struct", "module", "spec", "case", "each", "property"],
        SAMPLE,
        [("VERSION", "constant", 0), ("Num", "type", 0), ("Shapes", "module", 0), ("PI", "constant", 1),
         ("Shape", "class", 1), ("area", "method", 2), ("describe", "method", 2), ("Square", "class", 1),
         ("initialize", "method", 2), ("area", "method", 2), ("Color", "enum", 1), ("Point", "struct", 1),
         ("initialize", "method", 2), ("origin", "method", 2), ("LibC", "class", 0), ("getpid", "method", 1),
         ("main", "function", 0), ("twice", "function", 0)],
        ["crystal", "shards", "crystalline"],
        runs=[("hello.cr", "puts 1\n", {}, "crystal run $file"),
              ("src/app.cr", "puts 1\n", {"shard.yml": "name: app\n"}, "crystal run $file"),
              ("spec/app_spec.cr", "require \"spec\"\n", {"shard.yml": "name: app\n"}, "crystal spec $file")],
        server=["crystalline"], formatter="crystal tool format -")
