"""clojure — the language (colours, ; comments, indentation, F5: bb, lein or clojure), its snippets, the outline,
clojure-lsp and zprint or cljfmt when they are installed, the settings"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from langcheck import check_language

SAMPLE = r'''; a comment: (defn nope [] 1)
(ns app.core
  (:require [clojure.string :as str]))

(def limit 10)
(defonce state (atom {}))
(def ^:private secret "(defn fake [] 2)")
(def ^{:doc "a map"} table {:a 1})

(defn greet
  "Says hello. (defn not-this [])"
  [name]
  (str "Hello, " name \( \)))

(defn- helper [x] (inc x))

(defmacro unless [c & body] `(if ~c nil (do ~@body)))

(defprotocol Shape
  (area [s]))

(defrecord Square [side]
  Shape
  (area [_] (* side side)))

(defmulti describe :kind)
(defmethod describe :square [s] "a square")

(comment
  (defn scratch [] 1))

(deftest greet-test
  (is (= "Hello, a" (greet "a"))))

(defn -main [& args]
  (println (greet "you")))'''.split("\n")


def run(factory, tag):
    check_language(
        factory, tag, "clojure",
        {"name": "Clojure", "extensions": ["clj", "cljs", "cljc", "edn", "bb"], "lineComment": ";", "quotes": "\"",
         "capitalTypes": True, "indentSize": 2, "dedent": ")]}", "nameChars": "-?!*+<>=/'.",
         "keywords": {"ns", "def", "defn", "defn-", "let", "fn", "if", "when", "cond", "loop", "recur", "->", "->>"},
         "constants": {"true", "false", "nil"}},
        ["ns", "defn", "let", "fn", "cond", "test", "main"],
        SAMPLE,
        [("app.core", "module", 0), ("limit", "variable", 0), ("state", "variable", 0), ("secret", "variable", 0),
         ("table", "variable", 0), ("greet", "function", 0), ("helper", "function", 0), ("unless", "function", 0),
         ("Shape", "interface", 0), ("Square", "struct", 0), ("describe", "function", 0),
         ("describe :square", "function", 0), ("greet-test", "function", 0), ("-main", "function", 0)],
        ["clojure", "lein", "bb", "clojure-lsp", "zprint"],
        runs=[("hello.clj", "(println 1)\n", {}, "clojure -M $file"),
              ("script.bb", "(println 1)\n", {}, "bb $file"),
              ("src/app/core.clj", "(ns app.core)\n", {"deps.edn": "{}\n"}, "clojure -M $file"),
              ("test/app/core_test.clj", "(ns app.core-test)\n", {"deps.edn": "{}\n"}, "clojure -X:test"),
              ("src/app/main.clj", "(ns app.main)\n", {"project.clj": "(defproject app \"0.1\")\n"}, "lein run"),
              ("tasks.clj", "(println 1)\n", {"bb.edn": "{}\n"}, "bb $file")],
        server=["clojure-lsp"], formatter="zprint")
