"""pascal: the language (its words in any case, // and { } comments, indentation and the words that go a level out,
F5 — lazbuild beside a .lpi, else fpc on the file), its snippets, the outline without a language server (the unit,
its sections, classes with their methods and properties, records, enumerations, a method's body as TFoo.Bar, nested
routines — not in comments or strings), pasls when it is installed (a pretend one here), no formatter unless one is
set, the plugin's two settings"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from langcheck import check_language, start, done
from tplugins import check

SAMPLE = """unit Shapes;

{$mode objfpc}{$H+}
// procedure NotThis;
{ function NorThis: Integer;
  type TNo = class }

interface

uses
  SysUtils;

type
  TColor = (clRed, clGreen);
  TPoint = record
    X, Y: Integer;
    Inner: record
      A: Byte;
    end;
  end;
  EShape = class(Exception);
  TShape = class(TObject)
  private
    FName: String;
  public
    constructor Create(const AName: String);
    function Area: Double; virtual; abstract;
    class function Count: Integer;
    property Name: String read FName write FName;
  end;
  TProc = procedure(X: Integer);

procedure Show(S: TShape);

implementation

const
  Msg = 'procedure Fake;';

constructor TShape.Create(const AName: String);
begin
  FName := AName;
end;

procedure Show(S: TShape);
  procedure Line;
  begin
    WriteLn('-');
  end;
var
  I: Integer;
begin
  try
    if S <> nil then begin
      Line;
    end else begin
      WriteLn('none');
    end;
  finally
    Line;
  end;
  case I of
    1: Line;
  end;
end;

class function TShape.Count: Integer;
begin
  Result := 0;
end;

end.""".split("\n")


def run(factory, tag):
    check_language(
        factory, tag, "pascal",
        {"name": "Pascal", "extensions": ["pas", "pp", "lpr", "dpr", "dpk"], "lineComment": "//",
         "blockComment": ["{", "}"], "quotes": "'", "indentSize": 2, "pairs": "()[]''",
         "keywords": {"begin", "BEGIN", "Begin", "end", "procedure", "function", "class", "record", "then", "until",
                      "uses", "unit", "program", "var", "const", "type", "property", "inherited"},
         "types": {"Integer", "integer", "INTEGER", "String", "Boolean", "TObject", "Double"},
         "constants": {"True", "true", "False", "nil", "NIL"}, "builtins": {"WriteLn", "writeln", "Inc", "Length"},
         "dedentWords": {"end", "End", "END", "begin", "until", "else", "except", "finally"},
         "check": "fpc -s -vew -FE\"$tmp\" -FU\"$tmp\" \"$file\""},
        ["program", "unit", "proc", "func", "class", "begin", "for", "if", "case", "try", "repeat", "while"],
        SAMPLE,
        [("Shapes", "module", 0), ("interface", "section", 0), ("TColor", "enum", 1), ("TPoint", "struct", 1),
         ("EShape", "class", 1), ("TShape", "class", 1), ("Create", "method", 2), ("Area", "method", 2),
         ("Count", "method", 2), ("Name", "field", 2), ("TProc", "type", 1), ("Show", "function", 1),
         ("implementation", "section", 0), ("TShape.Create", "method", 1), ("Show", "function", 1),
         ("Line", "function", 2), ("TShape.Count", "method", 1)],
        ["fpc", "lazbuild", "pasls"],
        runs=[("hello.pas", "program Hello;\nbegin\nend.\n", {}, "fpc -vew -FE/T -FU/T $file"),
              ("app/main.lpr", "program Main;\nbegin\nend.\n", {"app/main.lpi": "<?xml version=\"1.0\"?>\n"},
               "lazbuild -q $d/app/main.lpi")],
        server=["pasls"], formatter=None)
    src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "plugins", "pascal",
                            "plugin.nims")).read()
    check(tag + "it says why it runs programs (permission \"shell\"), and asks for nothing else",
          'permission("shell", "' in src and 'permission("files"' not in src and 'permission("clipboard"' not in src)
    # a program (no sections): its routines at the top, a forward declaration has no body
    h, ok, err = start(factory, [])
    sym = h.reg("symbols", lang="pascal") if ok else None
    if sym:
        h.lines = ["program Demo;", "procedure Later; forward;", "function Twice(X: Integer): Integer;", "begin",
                   "  Result := 2 * X;", "end;", "procedure Later;", "begin", "end;", "begin", "  Later;", "end."]
        got = [(s["name"], s["kind"], s["depth"]) for s in (h.call(sym["cb"], {"buf": 1}) or {}).get("value") or []]
        check(tag + "a program: its routines at the top level, a forward one too",
              got == [("Demo", "module", 0), ("Later", "function", 0), ("Twice", "function", 0),
                      ("Later", "function", 0)], got)
    else:
        check(tag + "the outline of a program", False, err)
    done(h)
