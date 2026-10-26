"""cmake: the language (CMakeLists.txt by its name and .cmake; colours, comments, indentation, F5), its snippets, the
outline without a language server, neocmakelsp (or cmake-language-server) and gersemi (or cmake-format) when they
are installed, the settings"""
import os, shutil, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from langcheck import check_language, done, fake_tools, ned_cmd, run_sh, start
from tplugins import check

SAMPLE = '''cmake_minimum_required(VERSION 3.20)
# project(notThis)
project(shapes LANGUAGES CXX)

option(SHAPES_TESTS "build the tests: add_executable(fake)" ON)

#[[ a bracket comment:
add_library(nope STATIC x.cpp)
]]

add_library(shapes STATIC
    src/area.cpp
    src/perimeter.cpp)

add_executable(
    shapes_demo
    src/main.cpp)
target_link_libraries(shapes_demo PRIVATE shapes)

function(shapes_add_test name)
    add_executable(${name} tests/${name}.cpp)
    add_test(NAME ${name} COMMAND ${name})
endfunction()

MACRO(shapes_warn)
    message(WARNING "careful:
    add_library(nope2)")
ENDMACRO()

add_custom_target(docs COMMAND doxygen)'''.split("\n")


def run(factory, tag):
    check_language(
        factory, tag, "cmake",
        {"name": "CMake", "extensions": ["cmake"], "files": ["CMakeLists.txt"], "lineComment": "#",
         "blockComment": ["#[[", "]]"], "quotes": "\"", "multilineStrings": True, "capitalTypes": True,
         "indentSize": 4, "dedent": ")", "indentAfter": ["("],
         "keywords": {"if", "elseif", "else", "endif", "foreach", "endforeach", "function", "endfunction", "macro",
                      "endmacro", "while", "endwhile"},
         "builtins": {"set", "project", "add_executable", "add_library", "target_link_libraries", "find_package"},
         "dedentWords": ["endif", "else", "elseif", "endforeach", "endwhile", "endfunction", "endmacro",
                         "endblock"]},
        ["project", "exe", "lib", "link", "find", "if", "foreach", "function"],
        SAMPLE,
        [("shapes", "module", 0), ("SHAPES_TESTS", "constant", 0), ("shapes", "class", 0),
         ("shapes_demo", "class", 0), ("shapes_add_test", "function", 0), ("shapes_warn", "function", 0),
         ("docs", "class", 0)],
        ["cmake", "neocmakelsp", "cmake-language-server", "gersemi", "cmake-format"],
        runs=[("CMakeLists.txt", "project(x)\n", {}, "cmake -S . -B build"),
              ("cmake/tools.cmake", "message(hi)\n", {}, "cmake -P $file")],
        server=["neocmakelsp", "stdio"], formatter="gersemi -")

    # F5 and Build in a sub-folder's CMakeLists.txt: in the project's top folder; the second tools when the first
    # are not installed
    tmp = tempfile.mkdtemp(prefix="ned-cmake-")
    try:
        fake = os.path.join(tmp, "bin")
        fake_tools(fake, ["cmake", "cmake-language-server", "cmake-format"])
        h, ok, err = start(factory, [fake], only_path=True)
        sp = (h.reg("language", id="cmake") or {}).get("spec", {}) if ok else {}
        ls = h.reg("lsp", lang="cmake") if ok else None
        fm = h.reg("formatter", lang="cmake") if ok else None
        check(tag + "cmake-language-server and cmake-format installed (not the others): they",
              ok and ls and ls["cmd"] == ["cmake-language-server"] and fm and fm.get("cmd") == "cmake-format -",
              (err, ls, fm))
        done(h)
        proj = os.path.join(tmp, "proj")
        f = os.path.join(proj, "src", "lib", "CMakeLists.txt")
        os.makedirs(os.path.dirname(f))
        open(f, "w").write("add_library(x x.c)\n")
        open(os.path.join(proj, "src", "CMakeLists.txt"), "w").write("add_subdirectory(lib)\n")
        open(os.path.join(proj, "CMakeLists.txt"), "w").write("project(x)\n")
        g = os.path.join(proj, "cmake", "Helpers.cmake")
        os.makedirs(os.path.dirname(g))
        open(g, "w").write("function(h)\nendfunction()\n")
        o = run_sh(ned_cmd(sp.get("run", ""), f, "/T"), os.path.dirname(f), [fake])
        o2 = run_sh(ned_cmd(sp.get("build", ""), g, "/T"), os.path.dirname(g), [fake])
        want = "cmake -S . -B build\nin %s\ncmake --build build\nin %s\n" % (proj, proj)
        check(tag + "F5 on a sub-folder's CMakeLists.txt, Build on a .cmake module: configured and built in the "
              "project's top folder", o == want and o2 == want, (o, o2))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
