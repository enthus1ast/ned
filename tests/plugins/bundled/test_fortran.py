"""fortran: the language (its words in any case, comments, indentation, F5 — fpm, or gfortran on the file), its
snippets, the outline without a language server (programs, modules, submodules, their procedures after contains,
derived types, interfaces — not in comments or strings; in fixed form a c in the first column is a comment), fortls
and fprettify when they are installed (pretend ones here), the plugin's two settings"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from langcheck import check_language, start, done
from tplugins import check

SAMPLE = """! subroutine notThis()
MODULE Shapes
   implicit none
   type :: point
      real :: x, y
   end type point
   type, extends(point) :: point3
      real :: z
   end type
   type(point) :: origin
   abstract interface
      function area_fn(s) result(a)
         real :: a
      end function
   end interface
CONTAINS
   pure real(8) function Area(r) result(a)
      real(8), intent(in) :: r
      character(len=*), parameter :: msg = 'function fake(x)'
      a = 3.14d0 * r * r
   end function Area
   subroutine show(p)
      type(point), intent(in) :: p
      do i = 1, 3
      end do
   end subroutine
end module Shapes

submodule (shapes) shapes_impl
end submodule

program main
   use shapes
   call show(origin)
end program main""".split("\n")


def run(factory, tag):
    check_language(
        factory, tag, "fortran",
        {"name": "Fortran", "extensions": ["f90", "f95", "f03", "f08", "f18", "f", "for", "f77", "fpp", "ftn"],
         "lineComment": "!", "quotes": "\"'", "indentSize": 3,
         "keywords": {"program", "PROGRAM", "Program", "subroutine", "SUBROUTINE", "contains", "CONTAINS", "end",
                      "END", "then", "intent", "implicit", "none", "use", "module"},
         "types": {"integer", "INTEGER", "Integer", "real", "REAL", "character", "logical"},
         "constants": {"true", "TRUE", "false"}, "builtins": {"sqrt", "SQRT", "size", "allocated"},
         "dedentWords": ["end", "END", "End", "else", "ELSE", "Else", "contains", "CONTAINS", "Contains"]},
        ["program", "module", "sub", "func", "do", "if", "type", "select"],
        SAMPLE,
        [("Shapes", "module", 0), ("point", "struct", 1), ("point3", "struct", 1), ("interface", "interface", 1),
         ("area_fn", "function", 2), ("Area", "function", 1), ("show", "function", 1), ("shapes_impl", "module", 0),
         ("main", "function", 0)],
        ["gfortran", "fpm", "fortls", "fprettify"],
        runs=[("hello.f90", "program hello\nend program\n", {}, "gfortran -J /T $file -o /T/hello"),
              ("app/main.f90", "program main\nend program\n", {"fpm.toml": "name = \"x\"\n"}, "fpm run")],
        server=["fortls"], formatter="fprettify --silent")
    src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "plugins", "fortran",
                            "plugin.nims")).read()
    check(tag + "it says why it runs programs (permission \"shell\")", 'permission("shell", "' in src)
    # fixed form (.f): a c or * in the first column is a comment; `call` at the start of a free-form line is not
    h, ok, err = start(factory, [])
    sym = h.reg("symbols", lang="fortran") if ok else None
    if sym:
        h.path_ = os.path.join(h.tmp, "old.f")
        h.lines = ["C     SUBROUTINE NOTTHIS", "*     FUNCTION NOR(X)", "      SUBROUTINE OLD(X)", "      END"]
        got = [(s["name"], s["depth"]) for s in (h.call(sym["cb"], {"buf": 1}) or {}).get("value") or []]
        check(tag + "fixed form (.f): c and * in the first column are comments", got == [("OLD", 0)], got)
        h.path_ = os.path.join(h.tmp, "new.f90")
        h.lines = ["subroutine a()", "call b()", "end subroutine", "subroutine c()", "end"]
        got = [(s["name"], s["depth"]) for s in (h.call(sym["cb"], {"buf": 1}) or {}).get("value") or []]
        check(tag + "free form: a line starting with call is code; a bare end closes the unit",
              got == [("a", 0), ("c", 0)], got)
    else:
        check(tag + "the outline for fixed form", False, err)
    done(h)
    # the check on save, as ned runs it: gfortran on the file (one line for each problem), fpm in a project, nothing
    # without them
    import tempfile, shutil
    from langcheck import fake_tools, run_sh
    h, ok, err = start(factory, [])
    sp = (h.reg("language", id="fortran") or {}).get("spec", {}) if ok else {}
    done(h)
    tmp = tempfile.mkdtemp(prefix="ned-f90-")
    try:
        d = os.path.join(tmp, "my code")
        os.makedirs(os.path.join(d, "src"))
        f = os.path.join(d, "src", "a.f90")
        open(f, "w").write("program a\nend program\n")
        cmd = sp.get("check", "").replace("\"$file\"", "'" + f + "'").replace("\"$dir\"", "'" + os.path.dirname(f) + "'") \
            .replace("$tmp", "/T")
        bare, gf = os.path.join(tmp, "bare"), os.path.join(tmp, "gf")
        fake_tools(bare, ["sh-nothing"])
        fake_tools(gf, ["gfortran", "fpm"])
        o = run_sh(cmd, os.path.dirname(f), [bare], hide=("gfortran", "fpm", "flang", "lfortran"))
        check(tag + "the check without gfortran: nothing", o == "", o)
        o = run_sh(cmd, os.path.dirname(f), [gf]).split("\n")
        check(tag + "the check: gfortran -fsyntax-only, one line a problem (a folder with a space)",
              o[0] == "gfortran -fsyntax-only -fdiagnostics-plain-output -Wall -J /T " + f, o)
        open(os.path.join(d, "fpm.toml"), "w").write("name = \"x\"\n")
        o = run_sh(cmd, os.path.dirname(f), [gf]).split("\n")
        check(tag + "the check in an fpm project: fpm build in its folder", o[:2] == ["fpm build", "in " + d], o)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
