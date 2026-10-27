"""kotlin: the language (colours, comments, indentation, F5 — Gradle's wrapper, gradle, kotlinc for a script or a
file), its snippets, the outline without a language server (classes, objects, interfaces with what is in them,
functions, properties, aliases — not in comments, strings or raw strings), kotlin-lsp (before kotlin-language-server)
and ktfmt when they are installed (pretend ones here), the plugin's two settings"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from langcheck import check_language
from tplugins import check

SAMPLE = '''package demo

import kotlin.math.max

/* fun notThis() {} /* nested */ class NotThis */
typealias Names = List<String>

const val LIMIT = 10
var counter = 0

@Serializable
data class Point(val x: Int, val y: Int = 0) {
    fun len(): Int = x + y
    private val hidden = """
        fun fake() {
    """
    companion object {
        fun origin() = Point(0, 0)
    }
}

sealed interface Shape {
    fun area(): Double
}

enum class Color { RED, GREEN }

object Registry {
    val items = mutableListOf<String>()
}

fun <T> List<T>.second(): T = this[1]

suspend fun main(args: Array<String>) {
    val local = "fun fake() {"
    println(local)
}'''.split("\n")


def run(factory, tag):
    check_language(
        factory, tag, "kotlin",
        {"name": "Kotlin", "extensions": ["kt", "kts"], "lineComment": "//", "blockComment": ["/*", "*/"],
         "docBlockComment": ["/**", "*/"], "nestedComments": True, "quotes": "\"'", "charLiterals": True,
         "tripleQuotes": True, "capitalTypes": True, "decorators": True, "indentSize": 4, "dedent": "})]",
         "keywords": {"fun", "val", "var", "class", "object", "interface", "when", "data", "sealed", "suspend",
                      "companion", "override", "typealias"},
         "constants": {"true", "false", "null"}, "functionWords": ["fun"],
         "classWords": ["class", "interface", "object"]},
        ["fun", "main", "class", "data", "when", "for", "test"],
        SAMPLE,
        [("Names", "type", 0), ("LIMIT", "constant", 0), ("counter", "variable", 0), ("Point", "class", 0),
         ("len", "method", 1), ("hidden", "field", 1), ("Companion", "class", 1), ("origin", "method", 2),
         ("Shape", "interface", 0), ("area", "method", 1), ("Color", "enum", 0), ("Registry", "class", 0),
         ("items", "field", 1), ("second", "function", 0), ("main", "function", 0)],
        ["kotlinc", "gradle", "kotlin-lsp", "kotlin-language-server", "ktfmt"],
        runs=[("Main.kt", "fun main() {}\n", {}, "kotlinc $file -include-runtime -d /T/Main.jar"),
              ("script.main.kts", "println(1)\n", {}, "kotlinc -script $file"),
              ("src/main/kotlin/App.kt", "fun main() {}\n", {"build.gradle.kts": "plugins {}\n"}, "gradle run"),
              ("app/src/App.kt", "fun main() {}\n",
               {"gradlew": "#!/bin/sh\necho \"gradlew $*\"\n", "settings.gradle.kts": ""}, "gradlew run")],
        server=["kotlin-lsp", "--stdio"], formatter="ktfmt --kotlinlang-style -")
    src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "plugins", "kotlin",
                            "plugin.nims")).read()
    check(tag + "it says why it runs programs (permission \"shell\")", 'permission("shell", "' in src)
    # kotlin-language-server when kotlin-lsp is not there
    import tempfile, shutil
    from langcheck import start, done, fake_tools
    tmp = tempfile.mkdtemp(prefix="ned-kt-")
    try:
        fake_tools(tmp, ["kotlin-language-server"])
        h, ok, err = start(factory, [tmp], only_path=True)
        ls = h.reg("lsp", lang="kotlin") if ok else None
        check(tag + "without kotlin-lsp: kotlin-language-server", ls and ls["cmd"] == ["kotlin-language-server"], (err, ls))
        done(h)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
