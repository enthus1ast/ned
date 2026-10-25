"""zig: the language (colours, comments, indentation, F5), its snippets, the outline without zls, zls and zig fmt
when they are installed (pretend ones here), the plugin's two settings"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from langcheck import check_language

SAMPLE = """const std = @import("std");
//! a module's doc: fn notThis() void {}
/// a doc comment
pub const Point = struct {
    x: i32,
    y: i32 = 0,

    pub fn len(self: Point) i32 {
        return self.x + self.y;
    }
    fn hidden() void {}
};

const Color = enum(u8) { red, green };
const Err = error{ Oops, Bad };

var counter: u32 = 0;

pub fn main() !void {
    const s = "fn fake() void {";
    std.debug.print("{s}\\n", .{s});
}

test "point length" {
    try std.testing.expect(true);
}""".split("\n")


def run(factory, tag):
    check_language(
        factory, tag, "zig",
        {"name": "Zig", "extensions": ["zig", "zon"], "lineComment": "//", "docComment": "///", "quotes": "\"",
         "charLiterals": True, "capitalTypes": True, "decorators": True, "indentSize": 4, "dedent": "})]",
         "keywords": {"fn", "pub", "const", "var", "struct", "enum", "union", "comptime", "defer", "errdefer", "try",
                      "catch", "orelse", "test", "switch"},
         "types": {"i32", "u8", "usize", "comptime_int", "anyerror"}, "constants": {"true", "false", "null",
                                                                                    "undefined"},
         "build": "zig build", "check": "zig ast-check \"$file\""},
        ["fn", "pub", "struct", "test", "for", "while", "switch", "defer", "main"],
        SAMPLE,
        [("std", "module", 0), ("Point", "struct", 0), ("len", "method", 1), ("hidden", "method", 1),
         ("Color", "enum", 0), ("Err", "type", 0), ("counter", "constant", 0), ("main", "function", 0),
         ("point length", "function", 0)],
        ["zig", "zls"],
        runs=[("main.zig", "pub fn main() void {}\n", {}, "zig run $file"),
              ("t.zig", "test \"x\" {}\n", {}, "zig test $file"),
              ("src/main.zig", "pub fn main() void {}\n", {"build.zig": "// build\n"}, "zig build run")],
        server=["zls"], formatter="zig fmt --stdin")
