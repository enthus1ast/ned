## clojure — Clojure (and ClojureScript, EDN, Babashka): colours, comments, indentation, F5, snippets, an outline;
## clojure-lsp and a formatter
##
## Turn it on in the Plugins dock (AVAILABLE). It teaches ned Clojure's `.clj`, `.cljs`, `.cljc`, `.edn` and `.bb`
## files: their colours (ned's generic lexer with Clojure's words: def, defn, let, fn …, :keywords, names with - ? !
## * in them, Capitalised Java classes as types), `;` comments, indentation inside ( [ {, two spaces, snippets (ns,
## defn, let, fn, cond, test, main) and F5: `bb` for a Babashka script (.bb, or a bb.edn above the file), `lein run`
## in a Leiningen project (project.clj), `clojure -M` on the file otherwise (in its deps.edn project when there is
## one), and `clojure -X:test` / `lein test` for a file of a test folder.
##
## Without a language server, the outline lists the file's namespace and its top-level forms: def, defn, defn-,
## defmacro, defmulti, defmethod, defprotocol, defrecord, deftype, defonce, deftest — from a scan of the brackets.
##
## The tools, when they are on PATH: clojure-lsp (https://clojure-lsp.io) — completion, hover, go to definition,
## problems, and the formatting the project's cljfmt settings ask for; else a formatter: zprint (`zprint`, its text
## on stdin), or cljfmt (`cljfmt fix -`). Clojure itself: https://clojure.org/guides/install_clojure (Termux: `pkg
## install openjdk-21` and the clojure tools' Linux script; Babashka has an aarch64 build).
##
## Settings (the Plugins dock › clojure › its settings; Plugins: reload after a change):
## - plugins.clojure.server — the language server's command, when it is not `clojure-lsp` ("off": none)
## - plugins.clojure.formatter — the formatter's command (the text on its stdin), when it is not zprint or cljfmt
import nedplugin
import std/strutils

requiresNed(">= 6.25")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")

settingDef("server", "", "The language server's command: empty for clojure-lsp (when it is installed), \"off\" " &
           "for none. Plugins: reload after a change")
settingDef("formatter", "", "The formatter's command, which reads the text on its stdin: empty for zprint or " &
           "cljfmt fix - (the first installed), \"off\" for none. Plugins: reload after a change")

const CljDefs = ["def", "defn", "defn-", "defmacro", "defmulti", "defmethod", "defprotocol", "defrecord", "deftype",
                 "defonce", "deftest", "definterface", "defstruct", "s/def", "s/fdef"]

language("clojure", LangSpec(
  name: "Clojure",
  extensions: @["clj", "cljs", "cljc", "edn", "bb"],
  lineComment: ";",
  quotes: "\"",
  capitalTypes: true,
  nameChars: "-?!*+<>=/'.",
  keywords: @CljDefs & @["ns", "let", "fn", "fn*", "if", "if-not", "if-let", "if-some", "when", "when-not",
              "when-let", "when-some", "when-first", "cond", "condp", "cond->", "cond->>", "case", "do", "loop",
              "recur", "try", "catch", "finally", "throw", "quote", "var", "letfn", "binding", "doseq", "dotimes",
              "for", "while", "and", "or", "not", "->", "->>", "as->", "some->", "some->>", "doto", "new", "set!",
              "require", "import", "use", "refer", "in-ns", "reify", "proxy", "extend-type", "extend-protocol",
              "with-open", "with-redefs", "is", "testing", "comment", "declare"],
  constants: @["true", "false", "nil"],
  builtins: @["println", "print", "prn", "str", "map", "filter", "reduce", "first", "rest", "cons", "conj", "assoc",
              "dissoc", "get", "get-in", "update", "update-in", "keys", "vals", "count", "into", "vec", "apply",
              "partial", "comp", "identity", "atom", "swap!", "reset!", "deref", "range", "take", "drop", "seq",
              "concat", "mapv", "some", "every?", "inc", "dec", "nil?", "empty?"],
  functionWords: @["defn", "defn-", "defmacro", "defmethod"],
  classWords: @["defrecord", "deftype", "defprotocol", "ns"],
  indentAfter: @["(", "[", "{"],
  dedent: ")]}",
  indentSize: 2,
  run: "sh -c 'f=\"$file\"; d=\"$dir\"; case \"$f\" in *.bb) exec bb \"$f\" ;; esac; " &
       "while [ ! -f \"$d/deps.edn\" ] && [ ! -f \"$d/project.clj\" ] && [ ! -f \"$d/bb.edn\" ] && [ \"$d\" != / ]; " &
       "do d=$(dirname \"$d\"); done; cd \"$d\" 2>/dev/null; " &
       "if [ -f \"$d/project.clj\" ]; then case \"$f\" in */test/*) exec lein test ;; esac; exec lein run; fi; " &
       "if [ -f \"$d/bb.edn\" ] && [ ! -f \"$d/deps.edn\" ]; then exec bb \"$f\"; fi; " &
       "case \"$f\" in */test/*) [ -f \"$d/deps.edn\" ] && exec clojure -X:test ;; esac; exec clojure -M \"$f\"'",
  pairs: "()[]{}\"\""))

snippet("clojure", "ns", "(ns ${1:app.core}\n  (:require [${2:clojure.string} :as ${3:str}]))\n$0", "a namespace")
snippet("clojure", "defn", "(defn ${1:name}\n  \"${2:What it does.}\"\n  [${3:x}]\n  $0)", "a function")
snippet("clojure", "let", "(let [${1:x} ${2:1}]\n  $0)", "a let")
snippet("clojure", "fn", "(fn [${1:x}] $0)", "an anonymous function")
snippet("clojure", "cond", "(cond\n  ${1:test} ${2:value}\n  :else $0)", "a cond")
snippet("clojure", "test", "(deftest ${1:name}-test\n  (testing \"${2:what}\"\n    (is (= ${3:1} ${4:1}))$0))", "a test (clojure.test)")
snippet("clojure", "main", "(defn -main\n  [& args]\n  $0)", "the -main function")

# ── the outline, when there is no language server ──

func cljSymbols*(lines: seq[string]): seq[Symbol] =
  ## the namespace and the top-level def forms, from the brackets: a form that starts at depth 0 (the defs inside a
  ## (comment …) are left out)
  var depth = 0
  var inStr = false
  for ln, s in lines:
    var i = 0
    while i < s.len:
      let c = s[i]
      if inStr:
        if c == '\\': inc i
        elif c == '"': inStr = false
        inc i
        continue
      case c
      of ';': break
      of '"': inStr = true
      of '\\':
        # a character: \a \( \newline — not a bracket
        inc i
        while i + 1 < s.len and s[i + 1].isAlphaAscii: inc i
      of '(', '[', '{':
        if c == '(' and depth == 0:
          # the form's first word and its name
          var k = i + 1
          while k < s.len and s[k] == ' ': inc k
          var e = k
          while e < s.len and s[e] notin {' ', '\t', ')', '(', '[', '{', '"', ';'}: inc e
          let head = s[k ..< e]
          if head == "ns" or head in CljDefs or head.endsWith("/def") or
             (head.startsWith("def") and head.len > 3 and head notin ["default"]):
            var a = e
            while a < s.len and s[a] == ' ': inc a
            # (defn ^:private name …), (def ^{:doc "…"} name …)
            while a < s.len and s[a] == '^':
              if a + 1 < s.len and s[a + 1] == '{':
                let close = s.find('}', a)
                a = if close > 0: close + 1 else: s.len
              else:
                while a < s.len and s[a] != ' ': inc a
              while a < s.len and s[a] == ' ': inc a
            var b = a
            while b < s.len and s[b] notin {' ', '\t', ')', '(', '[', '{', '"', ';'}: inc b
            var name = s[a ..< b]
            if head == "defmethod":
              # (defmethod area :square [s] …) — the method and its dispatch value
              var c2 = b
              while c2 < s.len and s[c2] == ' ': inc c2
              var d2 = c2
              while d2 < s.len and s[d2] notin {' ', '\t', ')', '(', '[', '{', ';'}: inc d2
              if d2 > c2: name &= " " & s[c2 ..< d2]
            if name.len > 0:
              let kind = case head
                         of "ns": "module"
                         of "def", "defonce": "variable"
                         of "defmacro", "defn", "defn-", "defmethod", "defmulti", "deftest": "function"
                         of "defprotocol", "definterface": "interface"
                         of "defrecord", "deftype", "defstruct": "struct"
                         else: "variable"
              result.add Symbol(name: name, kind: kind, detail: head, line: ln, col: a)
        inc depth
      of ')', ']', '}':
        depth = max(0, depth - 1)
      else: discard
      inc i

# ── the tools ──

proc cljHave(cmd: string): bool =
  ## whether the first word of the command line is a program that can be found (a ~ is expanded) — so a server or
  ## formatter that is set is only used when it is installed
  let w = cmd.splitWhitespace()
  w.len > 0 and findExe(expandTilde(w[0])).len > 0

let cljServerSet = setting("server", "").strip
var cljServer: seq[string]
if cljServerSet == "off": discard
elif cljServerSet.len > 0:
  if cljHave(cljServerSet): cljServer = cljServerSet.splitWhitespace()
  else: echo "clojure: the server " & cljServerSet & " is not installed (plugins.clojure.server)"
elif findExe("clojure-lsp").len > 0: cljServer = @["clojure-lsp"]
if cljServer.len > 0:
  cljServer[0] = expandTilde(cljServer[0])
  languageServer("clojure", cljServer)
else:
  symbols("clojure") do (b: Buf) -> seq[Symbol]:
    cljSymbols(b.lines)

let cljFmtSet = setting("formatter", "").strip
if cljFmtSet == "off": discard
elif cljFmtSet.len > 0:
  if cljHave(cljFmtSet): formatter("clojure", cljFmtSet)
  else: echo "clojure: the formatter " & cljFmtSet & " is not installed (plugins.clojure.formatter)"
elif findExe("zprint").len > 0: formatter("clojure", "zprint")
elif findExe("cljfmt").len > 0: formatter("clojure", "cljfmt fix -")
