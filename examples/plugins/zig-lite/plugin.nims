## zig-lite — a language ned does not have, with a formatter.
##
## Copy this folder to ~/.config/ned/plugins/ (or Plugins dock › + › an example). It teaches ned Zig: the files,
## the colours (ned's generic lexer with Zig's words), comments, indentation, F5; formats with `zig fmt` when zig
## is installed, else with the small formatter below (written in NimScript); and opens zls, Zig's language server,
## when it is on PATH.
import nedplugin

requiresNed(">= 6.26")
permission("shell", "runs zig build and zig fmt")
import std/os

language("zig", LangSpec(
  name: "Zig",
  extensions: @["zig", "zon"],
  lineComment: "//",
  quotes: "\"'",
  keywords: @["addrspace", "align", "allowzero", "and", "anyframe", "anytype", "asm", "async", "await", "break",
              "callconv", "catch", "comptime", "const", "continue", "defer", "else", "enum", "errdefer", "error",
              "export", "extern", "fn", "for", "if", "inline", "linksection", "noalias", "noinline", "nosuspend",
              "opaque", "or", "orelse", "packed", "pub", "resume", "return", "struct", "suspend", "switch", "test",
              "threadlocal", "try", "union", "unreachable", "usingnamespace", "var", "volatile", "while"],
  types: @["i8", "u8", "i16", "u16", "i32", "u32", "i64", "u64", "i128", "u128", "isize", "usize", "f16", "f32",
           "f64", "f128", "bool", "void", "noreturn", "type", "anyerror", "comptime_int", "comptime_float"],
  constants: @["true", "false", "null", "undefined"],
  builtins: @["@import", "@as", "@intCast", "@floatCast", "@ptrCast", "@sizeOf", "@typeOf", "@TypeOf", "@panic"],
  functionWords: @["fn"],
  indentAfter: @["{", "(", "["],
  dedent: "})]",
  indentSize: 4,
  run: "zig run $file",
  pairs: "()[]{}\"\""))

proc tidy(text: string): string =
  ## no spaces at the ends of lines, tabs at their starts as four spaces, one blank line at most, one newline at
  ## the end — what this formatter does when zig is not there to do more
  var blank = 0
  for raw in text.split('\n'):
    var l = raw.strip(leading = false)
    var lead = 0
    while lead < l.len and l[lead] in {' ', '\t'}: inc lead
    l = l[0 ..< lead].replace("\t", "    ") & l[lead .. ^1]
    if l.len == 0:
      inc blank
      if blank > 1: continue
    else: blank = 0
    result.add l & "\n"
  while result.endsWith("\n\n"): result.setLen(result.len - 1)

if findExe("zig").len > 0:
  formatter("zig", "zig fmt --stdin")
else:
  formatter("zig") do (text: string) -> string:
    tidy(text)

if findExe("zls").len > 0:
  languageServer("zig", @["zls"])

command "Zig: build the project", "f9":
  let (o, code) = shell("zig build 2>&1")
  if code == 0: message("zig build: done")
  else: warn("zig build failed: " & o.splitLines()[0])
