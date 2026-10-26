"""r: the language (colours, comments, indentation, F5), its snippets, the outline (code sections, functions,
classes), R's languageserver (when the package is installed, from the first save) and styler, the settings"""
import os, shutil, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from langcheck import check_language, done, fake_tools, start
from tplugins import check

SAMPLE = '''# Shapes ----
library(stats)

#' The area of a square
#' area <- function(notThis) {}
area <- function(side) {
  inner <- function(x) x * x   # a local function: not in the outline
  inner(side)
}

perimeter = function(side, n = 4) side * n
limit <- 10

## Helpers ----
describe <<- function(s) {
  msg <- "fake <- function() {
  still the string: nope <- function() 1"
  cat(msg, "\\n")
}

Point <- setRefClass("Point", fields = list(x = "numeric"))
Square <- R6::R6Class("Square")
setClass("Circle", representation(r = "numeric"))
setGeneric("size", function(obj) standardGeneric("size"))
`%+%` <- function(a, b) paste(a, b)
compose <- \\(f, g) \\(x) f(g(x))'''.split("\n")


def run(factory, tag):
    check_language(
        factory, tag, "r",
        {"name": "R", "extensions": ["r"], "files": [".Rprofile"], "lineComment": "#", "docComment": "#'",
         "quotes": "\"'", "nameChars": ".", "indentSize": 2, "dedent": "})]",
         "keywords": {"if", "else", "for", "while", "repeat", "function", "in", "next", "break"},
         "constants": {"TRUE", "FALSE", "NULL", "NA", "Inf", "NaN"}, "builtins": {"library", "c", "list", "paste"}},
        ["fun", "if", "for", "lapply", "section", "test"],
        SAMPLE,
        [("Shapes", "section", 0), ("area", "function", 1), ("perimeter", "function", 1), ("Helpers", "section", 1),
         ("describe", "function", 2), ("Point", "class", 2), ("Square", "class", 2), ("Circle", "class", 2),
         ("size", "function", 2), ("%+%", "function", 2), ("compose", "function", 2)],
        ["R", "Rscript"],
        runs=[("hello.R", "print(1)\n", {}, "Rscript $file"),
              ("tests/testthat/test-area.R", "test_that('a', {})\n", {"DESCRIPTION": "Package: shapes\n"},
               "Rscript -e testthat::test_file(\"$file\")")],
        server=None, formatter=None)

    # the packages installed (in a library R_LIBS_USER names): languageserver — started after the first save — and
    # styler; a server command with quotes split as a shell splits it; one that is not R's starts with the file
    tmp = tempfile.mkdtemp(prefix="ned-r-")
    old = os.environ.get("R_LIBS_USER")
    try:
        fake = os.path.join(tmp, "bin")
        fake_tools(fake, ["R", "Rscript", "air"])
        lib = os.path.join(tmp, "lib")
        for pkg in ("languageserver", "styler"):
            os.makedirs(os.path.join(lib, pkg))
            open(os.path.join(lib, pkg, "DESCRIPTION"), "w").write("Package: %s\n" % pkg)
        os.environ["R_LIBS_USER"] = lib
        h, ok, err = start(factory, [fake], only_path=True)
        ls = h.reg("lsp", lang="r") if ok else None
        fm = h.reg("formatter", lang="r") if ok else None
        check(tag + "languageserver installed: R's server, started after the first save (the outline the scan's)",
              ok and ls and ls["cmd"] == ["R", "--slave", "-e", "languageserver::run()"] and
              ls.get("afterSave") is True and h.reg("symbols", lang="r") is not None, (err, ls))
        check(tag + "styler installed: it formats, the text on its stdin",
              fm and fm.get("cmd") == "Rscript -e 'writeLines(styler::style_text(readLines(file(\"stdin\"), "
                                      "warn = FALSE)))'", fm)
        done(h)
        h, ok, err = start(factory, [fake], {"server": 'R --no-echo -e "languageserver::run()"'}, only_path=True)
        ls = h.reg("lsp", lang="r") if ok else None
        check(tag + "a server command with quotes: its words as a shell splits them, after the first save (R's)",
              ok and ls and ls["cmd"] == ["R", "--no-echo", "-e", "languageserver::run()"] and
              ls.get("afterSave") is True, (err, ls))
        done(h)
        h, ok, err = start(factory, [fake], {"server": "air language-server"}, only_path=True)
        ls = h.reg("lsp", lang="r") if ok else None
        check(tag + "a server that is not R: it starts with the file",
              ok and ls and ls["cmd"] == ["air", "language-server"] and ls.get("afterSave") is False, (err, ls))
        done(h)
        os.environ["R_LIBS_USER"] = os.path.join(tmp, "empty")
        h, ok, err = start(factory, [fake], only_path=True)
        check(tag + "R without the packages: no server, no formatter",
              ok and h.reg("lsp", lang="r") is None and h.reg("formatter", lang="r") is None, err)
        done(h)
    finally:
        if old is None:
            os.environ.pop("R_LIBS_USER", None)
        else:
            os.environ["R_LIBS_USER"] = old
        shutil.rmtree(tmp, ignore_errors=True)
