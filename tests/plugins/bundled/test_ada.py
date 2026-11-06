"""ada: the language (its words in any case, -- comments, indentation and the words that go a level out, F5 — alr in
an Alire crate, else gnatmake on the file), its snippets, the outline without a language server (packages, their
procedures, functions, tasks, protected objects and entries nested as their ends say — a signature over several
lines, a declare block, an instantiation, a separate body —, types and subtypes; not in comments or strings), the Ada
Language Server and gnatpp when they are installed (pretend ones here), the plugin's two settings, and the check on
save run the way ned runs it (with GNAT missing: nothing)"""
import os, shutil, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from langcheck import check_language, start, done, fake_tools, ned_cmd, run_sh
from tplugins import check

SAMPLE = """with Ada.Text_IO; use Ada.Text_IO;
-- procedure Not_This is
package body Shapes is

   type Color is (Red, Green);
   type Point is record
      X, Y : Integer := 0;
   end record;
   type Shape is tagged null record;
   subtype Small is Integer range 1 .. 10;
   package Int_IO is new Ada.Text_IO.Integer_IO (Integer);

   function Area (R : Float) return Float is
      Msg : constant String := "procedure Fake is";
   begin
      return 3.14 * R * R;
   end Area;

   procedure Show
     (P : Point)
   is
      procedure Line is
      begin
         Put_Line ("-");
      end Line;
   begin
      declare
         N : Integer := 0;
      begin
         if N = 0 then
            Line;
         end if;
      end;
      for I in 1 .. 3 loop
         Line;
      end loop;
   end Show;

   task Worker is
      entry Start;
   end Worker;

   task body Worker is
   begin
      accept Start do
         null;
      end Start;
   end Worker;

   procedure Later is separate;
   function Twice (X : Integer) return Integer is (2 * X);

end Shapes;""".split("\n")


def run(factory, tag):
    check_language(
        factory, tag, "ada",
        {"name": "Ada", "extensions": ["adb", "ads", "ada", "gpr"], "lineComment": "--", "quotes": "\"",
         "charLiterals": True, "indentSize": 3, "pairs": "()[]\"\"",
         "keywords": {"procedure", "PROCEDURE", "Procedure", "package", "body", "is", "begin", "end", "loop",
                      "record", "tagged", "task", "entry", "declare", "exception", "generic"},
         "types": {"Integer", "integer", "INTEGER", "Natural", "String", "Boolean"},
         "constants": {"True", "true", "FALSE"}, "builtins": {"Put_Line", "put_line", "PUT_LINE"},
         "indentAfter": {"is", "IS", "begin", "then", "loop", "record", "=>"},
         "dedentWords": {"end", "End", "begin", "else", "elsif", "exception", "private"}},
        ["proc", "func", "spec", "body", "if", "case", "loop", "for", "while", "declare", "record", "task", "main"],
        SAMPLE,
        [("Shapes", "module", 0), ("Color", "enum", 1), ("Point", "struct", 1), ("Shape", "struct", 1),
         ("Small", "type", 1), ("Int_IO", "module", 1), ("Area", "function", 1), ("Show", "function", 1),
         ("Line", "function", 2), ("Worker", "class", 1), ("Start", "method", 2), ("Worker", "class", 1),
         ("Later", "function", 1), ("Twice", "function", 1)],
        ["alr", "gnatmake", "gprbuild", "ada_language_server", "gnatpp"],
        runs=[("hello.adb", "procedure Hello is begin null; end Hello;\n", {}, "gnatmake -q -D /T $file -o /T/hello"),
              ("src/main.adb", "procedure Main is begin null; end Main;\n", {"alire.toml": "name = \"x\"\n"},
               "alr run")],
        server=["ada_language_server"], formatter="gnatpp --pipe $in > $out")
    src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "plugins", "ada",
                            "plugin.nims")).read()
    check(tag + "it says why it runs programs (permission \"shell\"), and asks for nothing else",
          'permission("shell", "' in src and 'permission("files"' not in src and 'permission("clipboard"' not in src)
    # the check on save, as ned runs it: with GNAT, gcc -gnatc on the file (in ned's own folder); without, nothing
    h, ok, err = start(factory, [])
    sp = (h.reg("language", id="ada") or {}).get("spec", {}) if ok else {}
    done(h)
    tmp = tempfile.mkdtemp(prefix="ned-ada-")
    try:
        d = os.path.join(tmp, "my project")
        os.makedirs(d)
        f = os.path.join(d, "app.adb")
        open(f, "w").write("procedure App is begin null; end App;\n")
        t = os.path.join(tmp, "T")
        os.makedirs(t)
        # (ned puts "$file" and "$dir" quoted: a folder with a space in its name)
        cmd = sp.get("check", "").replace("\"$file\"", "'" + f + "'").replace("\"$dir\"", "'" + d + "'") \
            .replace("$tmp", t)
        bare = os.path.join(tmp, "bare")
        fake_tools(bare, ["gcc"])
        o = run_sh(cmd, d, [bare], hide=("gnat", "gnatmake", "gprbuild", "alr"))
        check(tag + "the check without GNAT: nothing (no error from a gcc without Ada)", o == "", o)
        withg = os.path.join(tmp, "gnat")
        fake_tools(withg, ["gcc", "gnat"])
        o = run_sh(cmd, d, [withg])
        check(tag + "the check with GNAT: gcc -c -gnatc on the file, in ned's folder (a path with a space)",
              o.split("\n")[0] == "gcc -c -gnatc -gnatf -I" + d + " " + f and o.split("\n")[1] == "in " + t, o)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
