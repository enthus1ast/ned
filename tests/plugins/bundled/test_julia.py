"""julia: the language (colours, comments, indentation, F5), its snippets, the outline, a language server and a
formatter only when set (Julia's start slowly)"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from langcheck import check_language

SAMPLE = '''#= a block comment: function nope() end =#
module Shapes

export area

"""
    area(s)
A doc string: function notThis()
"""
function area(s::Square)
    return s.side^2
end

abstract type Shape end

struct Square <: Shape
    side::Float64
end

mutable struct Counter
    n::Int
end

const LIMIT = 10

perimeter(s::Square) = 4 * s.side

macro twice(ex)
    quote
        $(esc(ex)); $(esc(ex))
    end
end

function outer()
    inner(x) = x + 1      # (inside a function: not in the outline)
    map([1, 2]) do v
        v * 2
    end
end

end # module

main() = println(Shapes.area(Shapes.Square(2.0)))'''.split("\n")


def run(factory, tag):
    check_language(
        factory, tag, "julia",
        {"name": "Julia", "extensions": ["jl"], "lineComment": "#", "blockComment": ["#=", "=#"],
         "nestedComments": True, "tripleQuotes": True, "charLiterals": True, "capitalTypes": True,
         "decorators": True, "indentSize": 4,
         "keywords": {"function", "end", "module", "struct", "mutable", "abstract", "begin", "let", "do", "where",
                      "using", "import", "export"},
         "constants": {"true", "false", "nothing", "missing"},
         "dedentWords": ["end", "else", "elseif", "catch", "finally"]},
        ["function", "struct", "for", "if", "module", "test"],
        SAMPLE,
        [("Shapes", "module", 0), ("area", "function", 1), ("Shape", "type", 1), ("Square", "struct", 1),
         ("Counter", "struct", 1), ("LIMIT", "constant", 1), ("perimeter", "function", 1), ("twice", "function", 1),
         ("outer", "function", 1), ("main", "function", 0)],
        ["julia"],
        runs=[("hello.jl", "println(1)\n", {}, "julia $file"),
              ("src/App.jl", "module App end\n", {"Project.toml": "name = \"App\"\n"}, "julia --project $file"),
              ("test/runtests.jl", "using Test\n", {"Project.toml": "name = \"App\"\n"},
               "julia --project test/runtests.jl")],
        server=None, formatter=None)
