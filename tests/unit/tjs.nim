## ned's own JavaScript engine: its tokens, where the cursor is, what is offered there, the hover, where a name is
## declared, the problems found (and not found where there are none). Run: nim r tests/unit/tjs.nim

import std/[unittest, strutils, sequtils]
import ../../src/ned/web/[jsengine, jsdata, webcommon]

proc labels(items: seq[WebItem]): seq[string] = items.mapIt(it.label)

proc item(items: seq[WebItem], label: string): WebItem =
  for x in items:
    if x.label == label: return x
  WebItem(rank: -1)

proc at(text: string): (seq[string], int, int) =
  ## the text with a | where the cursor is: (lines, line, column)
  let ls = text.split('\n')
  for l, s in ls:
    let c = s.find('|')
    if c >= 0:
      var ls2 = ls
      ls2[l] = s[0 ..< c] & s[c + 1 .. ^1]
      return (ls2, l, c)
  doAssert false, "no | in the text"

proc complete(text: string): seq[WebItem] =
  let (ls, l, c) = at(text)
  jsComplete(ls, l, c)[1]

proc hover(text: string): string =
  let (ls, l, c) = at(text)
  jsHover(ls, l, c)

proc definition(text: string): (int, int) =
  let (ls, l, c) = at(text)
  jsDefinition(ls, l, c)

proc inCode(text: string): bool =
  let (ls, l, c) = at(text)
  jsInCode(ls, l, c)

proc checks(text: string, fragment = false): seq[WebDiag] = jsChecks(text.split('\n'), fragment)

proc rules(ds: seq[WebDiag]): seq[string] = ds.mapIt(it.rule)

suite "JS data":
  test "lookups":
    check jsGlobal("fetch") >= 0
    check JsGlobals[jsGlobal("Math")].kind == "object"
    check jsGlobal("nothing") < 0
    check jsMembersOf("Math").anyIt(JsMembers[it].name == "floor")
    check jsMembersOf("Array.prototype").anyIt(JsMembers[it].name == "toSorted")
    check jsMembersOf("nobody").len == 0
    check "await" in JsKeywords

suite "JS tokens":
  test "numbers, regexes, templates":
    let ts = jsTokens(@["x = 0x1F + 1_000 + 10n + 1.5e-3 / y / z + /[/]+\\//g.source"])
    check ts.filterIt(it.kind == jtNumber).mapIt(it.text) == @["0x1F", "1_000", "10n", "1.5e-3"]
    check ts.filterIt(it.kind == jtRegex).mapIt(it.text) == @["/[/]+\\//g"]
    check ts.countIt(it.kind == jtPunct and it.text == "/") == 2          # (y / z: divisions)
    let tt = jsTokens(@["s = `a ${`b ${c} d`} e ${ {x: 1}.x }`"])
    check tt.filterIt(it.kind == jtTemplate).mapIt(it.text) == @["`a ${", "`b ${", "} d`", "} e ${", "}`"]
    check tt.anyIt(it.kind == jtIdent and it.text == "c")
    let ops = jsTokens(@["a?.b ?? c; f(...r); (p) => p; x ??= 1; y?.5:0"])
    for p in ["?.", "??", "...", "=>", "??="]: check ops.anyIt(it.kind == jtPunct and it.text == p)
    check ops.anyIt(it.kind == jtNumber and it.text == ".5")             # (y ? .5 : 0 — not y?.5)
    check jsTokens(@["#!/usr/bin/env node", "x"])[0].kind == jtComment
    check jsTokens(@["class A { #n = 1 }"]).anyIt(it.kind == jtPrivate and it.text == "#n")

  test "over lines":
    let ts = jsTokens(@["/* a", "b */ x", "y = `one", "two ${z} three`"])
    check ts[0].kind == jtComment and ts[0].eline == 1
    check ts.filterIt(it.kind == jtTemplate).mapIt(it.text) == @["`one\ntwo ${", "} three`"]
    check jsTokens(@["s = 'open"])[^1].open

  test "where the cursor is":
    check inCode("const x = |")
    check not inCode("const s = 'ab|c'")
    check not inCode("const s = \"ab|")
    check not inCode("// note |")
    check not inCode("/* a\n  b| */")
    check not inCode("const t = `text |`")
    check inCode("const t = `text ${na|}`")
    check inCode("const t = `a ${`b ${c|}`}`")
    check not inCode("const r = /ab|c/")
    check inCode("const s = 'abc'|")

suite "JS completion":
  test "members of the globals":
    let c = complete("console.|")
    check "log" in c.labels and "table" in c.labels
    check c.item("log").rank == 0
    check c.item("log").snippet == "log($1)$0"
    check "floor" in complete("Math.fl|").labels
    check "PI" in complete("const r = Math.|").labels
    check "querySelector" in complete("document.|").labels
    check "addEventListener" in complete("document.|").labels
    check "stringify" in complete("JSON.|").labels
    check "fromEntries" in complete("Object.|").labels
    check "allSettled" in complete("Promise.|").labels
    check "getItem" in complete("localStorage.|").labels
    check "isInteger" in complete("Number.|").labels
    check "log" in complete("console?.|").labels

  test "members of what a name holds":
    check "padStart" in complete("const s = 'x';\ns.|").labels
    check "toUpperCase" in complete("'abc'.|").labels
    check "push" in complete("const xs = [];\nxs.|").labels
    check "map" in complete("[1, 2].|").labels
    check "toFixed" in complete("const n = 4.5;\nn.|").labels
    check "get" in complete("const m = new Map();\nm.|").labels
    check "add" in complete("const seen = new Set();\nseen.|").labels
    let el = complete("const el = document.querySelector('#a');\nel.|")
    check "classList" in el.labels and "addEventListener" in el.labels and "textContent" in el.labels
    check "toggle" in complete("el.classList.|").labels
    check "json" in complete("async function f() {\n  const res = await fetch(url);\n  res.|\n}").labels
    check "then" in complete("fetch(url).|").labels
    check "port" in complete("const cfg = { port: 80, start() {} };\ncfg.|").labels
    check "start" in complete("const cfg = { port: 80, start() {} };\ncfg.|").labels

  test "a class of the file":
    let src = "class Counter {\n  count = 0;\n  #step = 1;\n  static made = 0;\n" &
              "  inc(by = 1) { return this.count += by }\n  get double() { return this.count * 2 }\n}\n"
    let inst = complete(src & "const c = new Counter();\nc.|")
    check "inc" in inst.labels and "count" in inst.labels and "double" in inst.labels
    check "made" notin inst.labels
    check inst.item("inc").rank == 0
    check inst.item("inc").detail.contains("(by = 1)")
    let stat = complete(src & "Counter.|")
    check "made" in stat.labels and "inc" notin stat.labels
    let this = complete("class A {\n  #secret = 1;\n  constructor() { this.items = []; }\n" &
                        "  run() {\n    this.|\n  }\n}")
    check "#secret" in this.labels and "items" in this.labels and "run" in this.labels
    check "push" in complete("class A {\n  constructor() { this.items = []; }\n  run() { this.items.| }\n}").labels
    let arrow = complete("class A {\n  go() { [1].forEach(x => this.|) }\n  stop() {}\n}")
    check "stop" in arrow.labels                                  # (an arrow function keeps `this`)
    let sub = complete("class A { a() {} }\nclass B extends A { b() {} }\nnew B().|")
    check "a" in sub.labels and "b" in sub.labels
    check sub.item("b").rank < sub.item("a").rank
    let el = complete("class MyEl extends HTMLElement {\n  connectedCallback() { this.| }\n}")
    check "attachShadow" in el.labels and "connectedCallback" in el.labels

  test "what is before the dot does not show":
    let c = complete("function f(thing) {\n  thing.|\n}")
    check c.item("map").rank == 3 and c.item("map").detail.startsWith("maybe")
    check "toUpperCase" in c.labels and "closest" in c.labels

  test "names by scope":
    let src = "const top = 1;\nfunction outer(param) {\n  let mid = 2;\n  function inner() {\n    const deep = 3;\n" &
              "    |\n  }\n}\nfunction other() { let hidden = 4; }"
    let c = complete(src)
    for n in ["top", "outer", "param", "mid", "inner", "deep", "other"]: check n in c.labels
    check "hidden" notin c.labels
    check c.item("deep").rank == 0
    check c.item("mid").rank == 1
    check c.item("deep").kind == KConst and c.item("inner").kind == KFunction
    check "const" in c.labels and c.item("const").kind == KKeyword
    check "fetch" in c.labels and c.item("fetch").rank == 3
    let blk = complete("{\n  let inBlock = 1;\n}\n|")
    check "inBlock" notin blk.labels
    let loop = complete("for (const item of items) {\n  it|\n}")
    check "item" in loop.labels
    let arrow = complete("items.map((value, index) => val|)")
    check "value" in arrow.labels and "index" in arrow.labels
    let destr = complete("const { alpha, beta: renamed = 2, ...others } = obj;\nconst [first, , third] = arr;\n|")
    for n in ["alpha", "renamed", "others", "first", "third"]: check n in destr.labels
    check "beta" notin destr.labels
    let imp = complete("import def, { named as alias } from './m.js';\nimport * as ns from './n.js';\n|")
    for n in ["def", "alias", "ns"]: check n in imp.labels
    check "named" notin imp.labels
    check complete("new |").item("Map").rank == 0

  test "a template's ${…} is code, its text is not":
    check "local" in complete("const local = 1;\nconst s = `value: ${loc|}`;").labels
    check complete("const local = 1;\nconst s = `value: loc|`;").len == 0
    check "local" in complete("const local = 1;\nconst s = `a ${`b ${loc|}`}`;").labels
    check complete("const s = 'con|';").len == 0
    check complete("// con|").len == 0
    check complete("/* con|").len == 0

  test "where the word starts":
    let (ls, l, c) = at("console.lo|")
    check jsComplete(ls, l, c)[0] == 8
    let (ls2, l2, c2) = at("class A { #n = 1; m() { this.#|n } }")
    check jsComplete(ls2, l2, c2)[0] == c2 - 1

suite "JS hover":
  test "globals and members":
    let f = hover("fet|ch(url)")
    check "**fetch**(resource, options?)" in f
    check "https://developer.mozilla.org/docs/Web/API/Window/fetch" in f
    let m = hover("Math.fl|oor(x)")
    check "Math.floor" in m
    check "https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Math/floor" in m
    check "Global_Objects/Map" in hover("new Ma|p()")
    check "Web/API/Document/querySelector" in hover("document.query|Selector('a')")
    check "console/log_static" in hover("console.l|og(1)")
    check "Global_Objects/Array/map" in hover("[1, 2].ma|p(f)")
    check "nodejs.org" in hover("proc|ess.exit(1)")
    check hover("let x = 'fetch|'").len == 0

  test "declarations of the file":
    let fn = hover("function add(a, b = 1) {\n  return a + b;\n}\nad|d(1, 2);")
    check "**add**(a, b = 1)" in fn and "function" in fn and "line 1" in fn
    check "function add(a, b = 1) {" in fn
    let arrow = hover("const mul = (x, y) => x * y;\nmu|l(2, 3);")
    check "**mul**(x, y)" in arrow and "const" in arrow
    check "parameter" in hover("function f(width) {\n  return wid|th * 2;\n}")
    let meth = hover("class Box {\n  size(n) { return n }\n}\nconst b = new Box();\nb.si|ze(2);")
    check "**Box.size**(n)" in meth and "method" in meth and "line 2" in meth
    check "Box" in hover("class Box {}\nconst b = new Box();\n|b;")
    let maybe = hover("function f(x) { return x.incl|udes(1) }")          # (x's type does not show)
    check "Array.prototype.includes" in maybe and "String.prototype.includes" in maybe

suite "JS definition":
  test "names":
    check definition("const value = 1;\nconsole.log(val|ue);") == (0, 6)
    check definition("let x = 1;\nfunction f() {\n  let x = 2;\n  return |x;\n}") == (2, 6)
    check definition("function f(arg) {\n  return ar|g;\n}") == (0, 11)
    check definition("hoisted();\nfunction hoisted() {}".replace("hoisted();", "hoi|sted();")) == (1, 9)
    check definition("import { thing } from './m.js';\nthi|ng();") == (0, 9)
    check definition("console.l|og(1)") == (-1, -1)
    check definition("undeclared|()") == (-1, -1)

  test "members of a class of the file":
    let src = "class Shape {\n  area() { return 0 }\n  describe() { return this.ar|ea() }\n}"
    check definition(src) == (1, 2)
    check definition("class A {\n  #n = 1;\n  get() { return this.#|n }\n}") == (1, 2)
    check definition("class A { go() {} }\nclass B extends A {}\nnew B().g|o();") == (0, 10)

suite "JS problems":
  test "brackets":
    check checks("function f() {\n  if (x) {\n    g(;\n}").rules.count("js-brace") == 2
    check checks("a.b(c]").anyIt(it.rule == "js-brace" and "closes nothing" in it.msg)
    check checks("}").anyIt(it.rule == "js-brace" and it.sev == 1)
    check checks("f(() => {\n  return [1, 2];\n});").len == 0
    check checks("const s = `a ${ {b: [1]}.b } c`;\nconst r = /[(]/;").len == 0
    check checks("if (x) {", fragment = true).len == 0

  test "declared twice":
    let d = checks("let a = 1;\nlet a = 2;\nconsole.log(a);")
    check d.len == 1 and d[0].rule == "js-redeclare" and d[0].line == 1 and d[0].sev == 1
    check checks("function f(a) { let a = 1; return a }\nf();").rules == @["js-redeclare"]
    check checks("var v = 1;\nvar v = 2;\nconsole.log(v);").len == 0                   # (var may)
    check checks("for (let i = 0; i < 3; i++) {}\nfor (let i = 0; i < 3; i++) {}").len == 0
    check checks("let x = 1;\n{\n  let x = 2;\n  console.log(x);\n}\nconsole.log(x);").len == 0
    check checks("switch (k) {\n  case 1: { const v = 1; f(v); break; }\n  case 2: { const v = 2; f(v); }\n}").len == 0
    check checks("try { f() } catch (e) { g(e) }\ntry { f() } catch (e) { g(e) }").len == 0
    check checks("class A {}\nlet A = 1;").anyIt(it.rule == "js-redeclare")
    check checks("let a = 1;\nlet a = 2;", fragment = true).len == 0          # (pieces: scripts of their own)

  test "a constant assigned":
    let d = checks("const k = 1;\nk = 2;\nk++;\n++k;\nk += 1;\nconsole.log(k);")
    check d.rules == @["js-const-assign", "js-const-assign", "js-const-assign", "js-const-assign"]
    check d[0].line == 1 and d[0].col == 0
    check checks("import { n } from './m.js';\nn = 1;").anyIt(it.rule == "js-const-assign")
    check checks("const o = { a: 1 };\no.a = 2;\nconst arr = [];\narr.push(1);\narr[0] = 3;").len == 0
    check checks("const k = 1;\nfunction f() {\n  let k = 2;\n  k = 3;\n  return k;\n}\nf(k);").len == 0
    check checks("const total = 1;\nconst x = total === 1 ? total : -total;\nconsole.log(x);").len == 0
    check checks("for (const x of xs) {\n  console.log(x);\n}").len == 0

  test "never used":
    let d = checks("import { x } from './m.js';\nfunction helper() {}\nexport function main() {\n" &
                   "  let unused = 1;\n  const y = 2;\n  return y;\n}")
    check d.rules == @["js-unused", "js-unused", "js-unused"]
    check d.allIt(it.sev == 4)
    check "helper" in d[1].msg
    check checks("function f() {\n  const _skip = 1;\n  const { a, ...rest } = obj;\n  return rest;\n}\nf();").len == 0
    check checks("function onClick() {}\nconst config = {};").len == 0      # (a script's top level: maybe used)
    check checks("export const a = 1;\nexport function b() {}\nconst c = 2;\nexport { c };\nexport default c;").len == 0
    check checks("const util = require('util');\nconst other = 1;").rules == @["js-unused", "js-unused"]
    check checks("function fact(n) { return n <= 1 ? 1 : n * fact(n - 1) }\nexport { fact };").len == 0
    check checks("export function f(unusedParam) {}").len == 0                # (parameters: not reported)
    check checks("export const f = function named() {};").len == 0

  test "== with a literal":
    let d = checks("if (a == 1 || b != 'x' || c == null || typeof d == 'string' || e == undefined) {}")
    check d.rules == @["js-eqeq", "js-eqeq"]
    check d[0].sev == 4 and "===" in d[0].msg and "compares without converting" in d[0].msg
    check checks("if (1 == a) {}").len == 1
    check checks("if (a == -1) {}").len == 1
    check checks("if (a === 1 && b !== 'x' && c == d) {}").len == 0

  test "misspelled names":
    let d = checks("const userName = 'a';\nconsole.log(usrName);\ndocment.title = 'x';\nconsole.log(Promis.all);")
    check d.rules == @["js-typo", "js-typo", "js-typo"]
    check d[0].sev == 2 and "'userName'" in d[0].msg
    check "'document'" in d[1].msg and "'Promise'" in d[2].msg
    check checks("const obj = { valeu: 1 };\nobj.valeu;\nconst { valeu } = obj;\nconsole.log(valeu);").len == 0
    check checks("const items = [];\nconsole.log(itemz.length, $('a'), jQuery, describe, it, myLib);").len == 1
    check checks("const value = 1;\nconsole.log(typeof valeu === 'undefined');").len == 0
    check checks("function f(e) { return e.target }\nwindow.onload = f;").len == 0
    check checks("const data = 1;\nconst o = { date: 2, dat: data };\nconsole.log(o);").len == 0
    check checks("outer: for (const a of [1]) { for (const b of [2]) { if (a < b) continue outer; } }").len == 0
    check checks("const counter = 1;\nconsole.log(countr, countr, countr);").len == 0   # (used often: someone's)

  test "modern syntax: no problems":
    let src = """
class Account {
  #balance = 0;
  static #count = 0;
  static create(owner) { return new Account(owner); }
  constructor(owner, { limit = 100, currency = "EUR" } = {}) {
    this.owner = owner;
    this.limit = limit;
    this.currency = currency;
    Account.#count++;
  }
  get balance() { return this.#balance; }
  set balance(v) { this.#balance = v; }
  #check(amount) { return amount <= this.#balance + this.limit; }
  withdraw(amount) {
    if (!this.#check(amount)) throw new RangeError(`over the limit by ${amount - this.#balance}`);
    this.#balance -= amount;
    return this;
  }
  static [Symbol.hasInstance](x) { return #balance in x; }
  static parse(text) { return text.split(/[/,]\s*/).map((part) => Number(part) / 100 / 1); }
}

async function* pages(url, { size = 10 } = {}) {
  let next = url;
  while (next) {
    const res = await fetch(`${next}?size=${size}`);
    const { items = [], links: { next: after } = {} } = await res.json();
    yield* items;
    next = after;
  }
}

const sum = (...nums) => nums.reduce((a, b) => a + b, 0);
const pick = ({ id, name: label = "?" }) => ({ id, label });
const re = /\/(?<year>\d{4})\/[^/]+\//u;
const half = sum(1, 2) / 2 / 1;
const nested = `a ${`b ${`c ${half}`}`} d`;
const obj = { re, nested, get size() { return 1; }, async load() { return null; }, *gen() { yield 1; } };
const value = obj?.size ?? 0;
let flag = false;
flag ||= value > 0;
const big = 1_000_000n;

export async function main() {
  const acc = Account.create("me");
  console.log(Account.parse("1/2, 3"));
  for await (const item of pages("/api")) console.log(item, pick(item));
  const { year } = re.exec("/2024/x/")?.groups ?? {};
  label: {
    if (!year) break label;
    console.log(year);
  }
  try {
    acc.withdraw(10);
  } catch {
    console.warn("no");
  } finally {
    console.log(acc.balance, nested, flag, big, sum(...[1, 2]));
  }
  return [obj, value];
}
"""
    let d = checks(src)
    for x in d: echo "  unexpected: ", x
    check d.len == 0

  test "found on real code":
    # (minified: a for's body is a statement — `let $` after it is not in the loop)
    check checks("export function f(z, H) {let $;for(let O in z)if(!H.has(O)){$=$??[];$.push(O)}let y=$;return y}")
      .len == 0
    check checks("const keys = [\n  'a',\n]\nclass Profile {}\nmodule.exports = { Profile, keys }").len == 0  # (ASI)
    check checks("const st = f()\nPOSITION: for (;;) { break POSITION }").len == 0               # (a label)
    check checks("const state = { index: 0 };\nconst next = () => ++state.index;\nnext();").len == 0
    check checks("const a = typeof Float16Array > 'u' ? 0 : Float16Array;\nconsole.log(a);").len == 0
    check checks("var BigInteger = jsbn.BigInteger;").len == 0          # (jsbn: a script's global, not JSON)
    check checks("const AVA = 1;\nconsole.log(AVA, java.lang);").len == 0
    check checks("const myVar = 1;\nconsole.log(myvar);").anyIt(it.rule == "js-typo")  # (case counts: a typo)

  test "completion while typing":
    check "classList" in complete("function f() {\n  const el = document.querySelector('a');\n  el.cl|")
      .labels
    check complete("function f(items) {\n  for (const item of items) {\n    if (item.ok) {\n      ite|")
      .item("item").rank == 0
    check "resolve" in complete("const p = new Promise((resolve, reject) => {\n  res|").labels
    check "json" in complete("async function f() {\n  const r = await fetch('/x');\n  if (r.ok) {\n    await r.|")
      .labels
    check "#n" in complete("class A {\n  #n = 0;\n  inc() {\n    this.|\n").labels
    check "filter" in complete("const xs = [1, 2, 3];\nxs.map(n => n * 2).|").labels

  test "realistic scripts: no problems at all":
    let todo = """
// A small DOM to-do app: add, toggle, filter, remove, kept in localStorage
const STORAGE_KEY = "todos-v1";
const form = document.querySelector("#new-todo");
const input = form.querySelector("input[name=title]");
const list = document.getElementById("todo-list");
const counter = document.querySelector(".count");
let filter = location.hash.slice(1) || "all";

function load() {
  try {
    return JSON.parse(localStorage.getItem(STORAGE_KEY)) ?? [];
  } catch {
    return [];
  }
}

let todos = load();

function save() {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(todos));
}

const visible = () => todos.filter((t) =>
  filter === "all" ? true : filter === "done" ? t.done : !t.done);

function render() {
  list.replaceChildren();
  for (const todo of visible()) {
    const li = document.createElement("li");
    li.dataset.id = todo.id;
    li.classList.toggle("done", todo.done);
    li.innerHTML = `
      <input type="checkbox" ${todo.done ? "checked" : ""}>
      <span>${escapeHtml(todo.title)}</span>
      <button class="remove" aria-label="Remove ${escapeHtml(todo.title)}">×</button>`;
    list.append(li);
  }
  const left = todos.filter(({ done }) => !done).length;
  counter.textContent = `${left} item${left === 1 ? "" : "s"} left`;
}

function escapeHtml(s) {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}

form.addEventListener("submit", (event) => {
  event.preventDefault();
  const title = input.value.trim();
  if (!title) return;
  todos.push({ id: crypto.randomUUID(), title, done: false });
  input.value = "";
  save();
  render();
});

list.addEventListener("click", (e) => {
  const li = e.target.closest("li");
  if (!li) return;
  const id = li.dataset.id;
  if (e.target.matches(".remove")) {
    todos = todos.filter((t) => t.id !== id);
  } else if (e.target.matches("input[type=checkbox]")) {
    const todo = todos.find((t) => t.id === id);
    todo.done = !todo.done;
  }
  save();
  render();
});

window.addEventListener("hashchange", () => {
  filter = location.hash.slice(1) || "all";
  render();
});

let timer;
input.addEventListener("input", () => {
  clearTimeout(timer);
  timer = setTimeout(() => console.debug("typing", input.value.length), 300);
});

render();
"""
    let node = """
#!/usr/bin/env node
"use strict";
// A node module: reads a JSON config, merges defaults, retries
const fs = require("node:fs/promises");
const path = require("node:path");
const { EventEmitter } = require("node:events");

const DEFAULTS = Object.freeze({ port: 8080, host: "localhost", retries: 3, verbose: false });

class ConfigError extends Error {
  constructor(message, { cause, file } = {}) {
    super(message, { cause });
    this.name = "ConfigError";
    this.file = file;
  }
}

async function readConfig(file, { encoding = "utf8", ...rest } = {}) {
  let text;
  try {
    text = await fs.readFile(path.resolve(file), { encoding, ...rest });
  } catch (err) {
    throw new ConfigError(`cannot read ${file}`, { cause: err, file });
  }
  try {
    return { ...DEFAULTS, ...JSON.parse(text) };
  } catch (err) {
    throw new ConfigError(`bad JSON in ${path.basename(file)}: ${err.message}`, { cause: err, file });
  }
}

function* retries(n = DEFAULTS.retries) {
  for (let i = 0; i < n; i++) yield 2 ** i * 100;
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

class Watcher extends EventEmitter {
  #file;
  #config = null;
  static instances = 0;

  constructor(file) {
    super();
    this.#file = file;
    Watcher.instances += 1;
  }

  get config() {
    return this.#config;
  }

  async start() {
    for (const delay of retries()) {
      try {
        this.#config = await readConfig(this.#file);
        this.emit("ready", this.#config);
        return this;
      } catch (err) {
        if (!(err instanceof ConfigError)) throw err;
        this.emit("retry", err, delay);
        await sleep(delay);
      }
    }
    throw new ConfigError("giving up", { file: this.#file });
  }
}

const port = Number.parseInt(process.env.PORT ?? "", 10) || DEFAULTS.port;
const verbose = process.argv.includes("--verbose");
const log = (...args) => verbose && console.error("[config]", ...args);
log("port", port, typeof port == "number");

if (require.main === module) {
  new Watcher(process.argv[2] ?? "config.json")
    .start()
    .then((w) => console.log(JSON.stringify(w.config, null, 2)))
    .catch((err) => {
      console.error(err.message);
      process.exitCode = 1;
    });
}

module.exports = { readConfig, Watcher, ConfigError, DEFAULTS };
"""
    let classes = """
// A class-based module: a small store with an undoable history
import { EventEmitter } from "./emitter.js";
import * as util from "./util.js";
import defaultFormat, { format as fmt } from "./format.js";

export const VERSION = "2.1.0";
const SEP = /\s*[,/]\s*/u;

export class Store extends EventEmitter {
  #state;
  #history = [];
  #future = [];
  static #count = 0;
  static get count() { return Store.#count; }

  constructor(initial = {}) {
    super();
    this.#state = structuredClone(initial);
    Store.#count++;
  }

  get state() { return this.#state; }

  dispatch(action, payload = {}) {
    const next = this.#reduce(this.#state, action, payload);
    if (next === this.#state) return false;
    this.#history.push(this.#state);
    this.#future.length = 0;
    this.#state = next;
    this.emit("change", { action, state: next });
    return true;
  }

  undo() {
    if (!this.#history.length) return;
    this.#future.push(this.#state);
    this.#state = this.#history.pop();
  }

  redo() {
    const next = this.#future.pop();
    if (next !== undefined) {
      this.#history.push(this.#state);
      this.#state = next;
    }
  }

  #reduce(state, action, { id, value, tags = "" } = {}) {
    switch (action) {
      case "set": {
        const items = { ...state.items, [id]: { value, tags: tags.split(SEP).filter(Boolean) } };
        return { ...state, items };
      }
      case "remove": {
        const { [id]: _removed, ...items } = state.items ?? {};
        return { ...state, items };
      }
      default:
        return state;
    }
  }

  *entries() {
    for (const [id, item] of Object.entries(this.#state.items ?? {})) yield [id, item];
  }

  async toJSON() {
    const out = [];
    for (const [id, { value }] of this.entries()) out.push(`${id}=${fmt(value)}`);
    return util.join(out, defaultFormat);
  }
}

export default function createStore(initial) {
  const store = new Store(initial);
  store.on?.("change", ({ action }) => console.info(`store: ${action}`));
  return store;
}

export const isStore = (x) => x instanceof Store;
export { SEP as separator };
"""
    for src in [todo, node, classes]:
      let d = checks(src)
      for x in d: echo "  unexpected: ", x
      check d.len == 0
    # (and the same, hinted at when broken)
    check checks(todo.replace("list.append(li)", "lst.append(li)")).anyIt(it.rule == "js-typo")
    check checks(classes.replace("const out = [];", "const out = [];\n    const out = 1;")).anyIt(
      it.rule == "js-redeclare")
    check checks(node.replace("text = await", "DEFAULTS = await")).anyIt(it.rule == "js-const-assign")
