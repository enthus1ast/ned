#!/usr/bin/env python3
"""nedls tests: a self-contained LSP client (Python 3, standard library only).

    python3 tests/lsp/tnedls.py ./nedls                 # the checks, then the stress run
    python3 tests/lsp/tnedls.py ./nedls --edits 500      # a shorter stress run
    python3 tests/lsp/tnedls.py ./nedls --bench FILE     # timings and memory on a big file (no checks)
    python3 tests/lsp/tnedls.py ./nedls --only 632 langs # some parts only (actions langs c 628 632 nim3)

It builds nothing: give it a nedls binary. It writes a small Nim project to a temporary folder (two modules, an
object type, procs, a misspelled name, a non-ASCII string in front of names for the UTF-16 columns), talks to
nedls over stdio like an editor does, prints each check as PASS or FAIL and exits non-zero when one fails. The
compiler's diagnostics are checked only when `nim` is on PATH.
"""

import json
import os
import random
import shutil
import subprocess
import sys
import tempfile
import threading
import time

# ── a minimal LSP client ──


class Client:
    def __init__(self, cmd, cwd, env=None, log=None):
        self.p = subprocess.Popen(cmd, cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=log or subprocess.DEVNULL, env=env)
        self.next_id = 0
        self.responses = {}
        self.notes = []
        self.cv = threading.Condition()
        self.closed = False
        self.config = {}                 # what workspace/configuration answers, by section
        self.server_requests = []        # what the server asked (applyEdit, showMessageRequest …), whole
        self.button = None               # the button a showMessageRequest is answered with (its title)
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        f = self.p.stdout
        while True:
            headers = {}
            line = f.readline()
            if not line:
                break
            while line.strip():
                k, _, v = line.decode("latin-1").partition(":")
                headers[k.strip().lower()] = v.strip()
                line = f.readline()
                if not line:
                    break
            n = int(headers.get("content-length", "0"))
            body = f.read(n)
            try:
                msg = json.loads(body)
            except ValueError:
                msg = {"_bad": body}
            with self.cv:
                if "id" in msg and "method" in msg:
                    # a request from the server (registerCapability, refresh …): answered at once
                    res = None
                    if msg["method"] == "workspace/configuration":
                        res = [self.config.get(it.get("section")) for it in msg["params"]["items"]]
                    elif msg["method"] == "workspace/applyEdit":
                        res = {"applied": True}
                    elif msg["method"] == "window/showMessageRequest" and self.button:
                        res = {"title": self.button}
                    self.server_requests.append(msg)
                    self.notes.append({"method": "<request> " + msg["method"]})
                    self._write({"jsonrpc": "2.0", "id": msg["id"], "result": res})
                elif "id" in msg:
                    self.responses[json.dumps(msg["id"])] = msg
                else:
                    self.notes.append(msg)
                self.cv.notify_all()
        with self.cv:
            self.closed = True
            self.cv.notify_all()

    def _write(self, msg):
        body = json.dumps(msg).encode()
        try:
            self.p.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
            self.p.stdin.flush()
        except (BrokenPipeError, OSError):
            pass

    def raw(self, data):
        try:
            self.p.stdin.write(data)
            self.p.stdin.flush()
        except (BrokenPipeError, OSError):
            pass

    def frame(self, msg):
        body = json.dumps(msg).encode()
        return b"Content-Length: %d\r\n\r\n" % len(body) + body

    def send_request(self, method, params):
        self.next_id += 1
        mid = self.next_id
        self._write({"jsonrpc": "2.0", "id": mid, "method": method, "params": params})
        return mid

    def wait(self, mid, timeout=30):
        key = json.dumps(mid)
        end = time.time() + timeout
        with self.cv:
            while key not in self.responses:
                left = end - time.time()
                if left <= 0 or self.closed:
                    return None
                self.cv.wait(left)
            return self.responses.pop(key)

    def request(self, method, params, timeout=30):
        return self.wait(self.send_request(method, params), timeout)

    def notify(self, method, params):
        self._write({"jsonrpc": "2.0", "method": method, "params": params})

    def diagnostics(self, uri):
        """the last diagnostics published for uri (None: none yet)"""
        with self.cv:
            for m in reversed(self.notes):
                if m.get("method") == "textDocument/publishDiagnostics" and m["params"]["uri"] == uri:
                    return m["params"]["diagnostics"]
        return None

    def wait_diagnostics(self, uri, pred, timeout=60):
        end = time.time() + timeout
        while time.time() < end:
            ds = self.diagnostics(uri)
            if ds is not None and pred(ds):
                return ds
            with self.cv:
                self.cv.wait(0.2)
        return self.diagnostics(uri)

    def close(self, timeout=10):
        try:
            return self.p.wait(timeout)
        except subprocess.TimeoutExpired:
            self.p.kill()
            return None


# ── positions: UTF-16 code units (LSP's default) ──


def u16len(s):
    return sum(2 if ord(c) > 0xFFFF else 1 for c in s)


def u16col(line, idx):
    """python index in a line → UTF-16 offset"""
    return u16len(line[:idx])


def idx_of(line, u16):
    """UTF-16 offset → python index"""
    k = 0
    for i, c in enumerate(line):
        if k >= u16:
            return i
        k += 2 if ord(c) > 0xFFFF else 1
    return len(line)


def pos_of(text, needle, nth=0, after=0):
    """{line, character} (UTF-16) of the nth occurrence of needle, `after` characters into it"""
    k = -1
    for _ in range(nth + 1):
        k = text.index(needle, k + 1)
    k += after
    line = text.count("\n", 0, k)
    ls = text.rfind("\n", 0, k) + 1
    return {"line": line, "character": u16len(text[ls:k])}


def apply_edits(text, edits):
    lines = text.split("\n")

    def off(p):
        line = min(p["line"], len(lines) - 1) if p["line"] < len(lines) else len(lines) - 1
        if p["line"] >= len(lines):
            return len(text)
        return sum(len(x) + 1 for x in lines[:line]) + idx_of(lines[line], p["character"])

    es = sorted(edits, key=lambda e: (off(e["range"]["start"]), off(e["range"]["end"])), reverse=True)
    for e in es:
        a, b = off(e["range"]["start"]), off(e["range"]["end"])
        text = text[:a] + e["newText"] + text[b:]
    return text


def range_text(text, r):
    lines = text.split("\n")
    s, e = r["start"], r["end"]
    if s["line"] != e["line"]:
        a, b = lines[s["line"]], lines[min(e["line"], len(lines) - 1)]
        mid = lines[s["line"] + 1:e["line"]]
        return "\n".join([a[idx_of(a, s["character"]):]] + mid + [b[:idx_of(b, e["character"])]])
    ln = lines[s["line"]]
    return ln[idx_of(ln, s["character"]):idx_of(ln, e["character"])]


def uri(path):
    return "file://" + path


# ── the test project ──

SHAPES = '''## Shapes for the tests.

type
  Shape* = object
    name*: string
    width*, height*: int
  Color* = enum
    red, green, blue

proc area*(s: Shape): int =
  ## The area of a shape.
  s.width * s.height

proc newShape*(name: string, w, h: int): Shape =
  ## Makes a shape.
  Shape(name: name, width: w, height: h)
'''

APP = '''import shapes

let greeting = "héllo wörld 🎉 ünïcode"; let sq = newShape("square", 2, 2)

proc describe(s: Shape): string =
  result = s.name & ": " & $s.area

let total = sq.area + 1
let w = sq.width
var c = red
echo describe(sq), total, greeting, w, c
'''

ANIMALS = '''type
  Animal* = ref object of RootObj
    name*: string
  Dog* = ref object of Animal
  Cat* = ref object of Animal

method speak*(a: Animal): string {.base.} = "…"
method speak*(d: Dog): string = "woof"
method speak*(c: Cat): string = "meow"
'''

BAD = '''import std/strutils
import shapes

let s = newShape("x", 1, 2)
echo s.aera
'''

BAD2 = '''let q: int = "text"
'''

HINTS = '''proc total(xs: seq[int]): int =
  var sum = 0
  for x in xs: sum += x
  var limit = 10
  echo limit
  result = sum

echo total(@[1, 2])
'''

FMT = '''proc  f( a:int ):int=a+1
echo   f(2)
'''

RESULTS = []


def check(name, ok, detail=""):
    RESULTS.append((name, bool(ok)))
    print(("PASS  " if ok else "FAIL  ") + name + ("" if ok or not detail else "  — " + str(detail)[:300]))
    sys.stdout.flush()
    return ok


def new_client(nedls, root, encodings=None, log=None, opts=None, config=None, env=None, more_caps=None):
    c = Client([nedls], root, env=env, log=log)
    if config:
        c.config = config
    caps = {"textDocument": {"completion": {"completionItem": {"snippetSupport": True,
                                                               "resolveSupport": {"properties": ["documentation"]}}},
                             "documentSymbol": {"hierarchicalDocumentSymbolSupport": True},
                             "rename": {"prepareSupport": True},
                             "foldingRange": {"lineFoldingOnly": True}},
            "workspace": {"workspaceFolders": True, "configuration": bool(config)}}
    if encodings:
        caps["general"] = {"positionEncodings": encodings}
    for k, v in (more_caps or {}).items():
        caps.setdefault(k, {}).update(v)
    r = c.request("initialize", {"processId": os.getpid(), "rootUri": uri(root), "capabilities": caps,
                                 "workspaceFolders": [{"uri": uri(root), "name": "proj"}],
                                 "initializationOptions": opts or {"nedSettings": False}}, timeout=60)
    c.notify("initialized", {})
    return c, r


def open_doc(c, path, text, version=1):
    c.notify("textDocument/didOpen", {"textDocument": {"uri": uri(path), "languageId": "nim", "version": version,
                                                       "text": text}})


def labels(res):
    items = res["result"]["items"] if isinstance(res.get("result"), dict) else (res.get("result") or [])
    return [i["label"] for i in items]


# ── the checks ──


def run_checks(nedls, root, have_nim, log):
    src = os.path.join(root, "src")
    shapes_p = os.path.join(src, "shapes.nim")
    app_p = os.path.join(src, "app.nim")
    bad_p = os.path.join(src, "bad.nim")
    fmt_p = os.path.join(src, "fmt.nim")

    # the command line
    r = subprocess.run([nedls, "--version"], capture_output=True, text=True)
    check("nedls --version", r.returncode == 0 and r.stdout.startswith("nedls "), r.stdout)
    r = subprocess.run([nedls, "--help"], capture_output=True, text=True)
    check("nedls --help", r.returncode == 0 and "inlayHints" in r.stdout, r.stdout[:100])
    r = subprocess.run([nedls, "--frobnicate"], capture_output=True, text=True)
    check("an unknown option → exit code 2", r.returncode == 2, r.returncode)
    r = subprocess.run([nedls], input=b"", capture_output=True, timeout=20)
    check("stdin closed at once → ends (exit code 1), nothing on stdout", r.returncode == 1 and r.stdout == b"",
          (r.returncode, r.stdout[:100]))

    # before initialize: an error, not a crash
    c0 = Client([nedls], root, log=log)
    r = c0.request("textDocument/hover", {"textDocument": {"uri": uri(app_p)}, "position": {"line": 0, "character": 0}})
    check("request before initialize → ServerNotInitialized", r and r.get("error", {}).get("code") == -32002, r)
    c0.notify("exit", {})
    code = c0.close()
    check("exit without shutdown → exit code 1", code == 1, code)

    c, init = new_client(nedls, root, log=log)
    caps = (init or {}).get("result", {}).get("capabilities", {})
    check("initialize: serverInfo is nedls", (init or {}).get("result", {}).get("serverInfo", {}).get("name") == "nedls",
          init)
    want = ["completionProvider", "hoverProvider", "signatureHelpProvider", "definitionProvider", "referencesProvider",
            "renameProvider", "documentSymbolProvider", "workspaceSymbolProvider", "semanticTokensProvider",
            "inlayHintProvider", "documentFormattingProvider", "documentRangeFormattingProvider",
            "foldingRangeProvider", "codeActionProvider", "documentHighlightProvider", "typeDefinitionProvider",
            "callHierarchyProvider", "typeHierarchyProvider", "implementationProvider", "selectionRangeProvider",
            "codeLensProvider", "documentLinkProvider"]
    missing = [k for k in want if k not in caps]
    check("initialize: capabilities", not missing, missing)
    check("initialize: UTF-16 positions when the client offers no other", caps.get("positionEncoding") == "utf-16", caps)
    check("initialize: incremental sync", caps.get("textDocumentSync", {}).get("change") == 2)

    # malformed input: answered, the server goes on
    c.raw(b"Content-Length: 9\r\n\r\n{not json")
    time.sleep(0.3)
    with c.cv:
        bad = [m for m in c.responses.values() if m.get("error", {}).get("code") == -32700]
    check("malformed JSON → ParseError", bad, list(c.responses.values())[:2])
    r = c.request("nedls/noSuchMethod", {})
    check("unknown request → MethodNotFound", r and r.get("error", {}).get("code") == -32601, r)

    shapes, app = SHAPES, APP
    open_doc(c, shapes_p, shapes)
    open_doc(c, app_p, app)

    # completion after `sq.`
    p = pos_of(app, "sq.width", after=3)
    r = c.request("textDocument/completion", {"textDocument": {"uri": uri(app_p)}, "position": p})
    ls = labels(r or {})
    check("completion after `sq.`: fields and procs of Shape", all(x in ls for x in ["width", "height", "name", "area"]),
          ls[:20])
    items = (r or {}).get("result", {}).get("items", [])
    area = [i for i in items if i["label"] == "area"]
    if area:
        rr = c.request("completionItem/resolve", area[0])
        doc = json.dumps((rr or {}).get("result", {}).get("documentation", ""))
        check("completionItem/resolve: documentation", "area of a shape" in doc, rr)
    else:
        check("completionItem/resolve: documentation", False, "no area item")

    # hover on a name after a non-ASCII string (UTF-16 columns)
    p = pos_of(app, "newShape", after=2)
    r = c.request("textDocument/hover", {"textDocument": {"uri": uri(app_p)}, "position": p})
    hv = json.dumps((r or {}).get("result") or {})
    check("hover after a non-ASCII string (UTF-16 column)", "newShape" in hv and "Makes a shape" in hv, hv)
    rng = ((r or {}).get("result") or {}).get("range")
    check("hover range is the name", rng is not None and range_text(app, rng) == "newShape", rng)

    # definition across modules
    r = c.request("textDocument/definition", {"textDocument": {"uri": uri(app_p)}, "position": p})
    locs = (r or {}).get("result") or []
    ok = any(l["uri"] == uri(shapes_p) and l["range"]["start"]["line"] == 13 for l in locs)
    check("definition across modules", ok, locs)
    if locs:
        check("definition range is the name", range_text(shapes, locs[0]["range"]) == "newShape", locs[0])

    # type definition: sq → Shape
    p = pos_of(app, "sq.area", after=0)
    r = c.request("textDocument/typeDefinition", {"textDocument": {"uri": uri(app_p)}, "position": p})
    locs = (r or {}).get("result") or []
    check("typeDefinition of sq → type Shape", any(l["uri"] == uri(shapes_p) and l["range"]["start"]["line"] == 3
                                                   for l in locs), locs)

    # signature help
    p = pos_of(app, 'newShape("square", 2', after=len('newShape("square", '))
    r = c.request("textDocument/signatureHelp", {"textDocument": {"uri": uri(app_p)}, "position": p})
    sh = (r or {}).get("result") or {}
    sigs = sh.get("signatures", [])
    check("signatureHelp: label and active parameter",
          sigs and "newShape(" in sigs[0]["label"] and sh.get("activeParameter") == 1, sh)

    # references of area (from its declaration)
    p = pos_of(shapes, "area*", after=1)
    r = c.request("textDocument/references", {"textDocument": {"uri": uri(shapes_p)}, "position": p,
                                              "context": {"includeDeclaration": True}})
    refs = (r or {}).get("result") or []
    in_app = [x for x in refs if x["uri"] == uri(app_p)]
    check("references across modules (declaration + 2 uses)", len(in_app) == 2 and
          any(x["uri"] == uri(shapes_p) for x in refs), refs)
    check("reference ranges are the name", all(range_text(app, x["range"]) == "area" for x in in_app), in_app)
    r = c.request("textDocument/references", {"textDocument": {"uri": uri(shapes_p)}, "position": p,
                                              "context": {"includeDeclaration": False}})
    refs2 = (r or {}).get("result") or []
    check("references without the declaration", len(refs2) == len(refs) - 1, refs2)

    # document highlight: sq in app
    p = pos_of(app, "sq.area", after=0)
    r = c.request("textDocument/documentHighlight", {"textDocument": {"uri": uri(app_p)}, "position": p})
    hl = (r or {}).get("result") or []
    check("documentHighlight: every use of sq in the file", len(hl) == 4 and
          all(range_text(app, h["range"]) == "sq" for h in hl), hl)

    # rename area → surface
    p = pos_of(shapes, "area*", after=1)
    r = c.request("textDocument/prepareRename", {"textDocument": {"uri": uri(shapes_p)}, "position": p})
    pr = (r or {}).get("result") or {}
    check("prepareRename: the name's range", pr.get("placeholder") == "area", r)
    r = c.request("textDocument/rename", {"textDocument": {"uri": uri(shapes_p)}, "position": p, "newName": "surface"})
    ch = ((r or {}).get("result") or {}).get("changes", {})
    ok = uri(app_p) in ch and uri(shapes_p) in ch
    if ok:
        new_app = apply_edits(app, ch[uri(app_p)])
        new_shapes = apply_edits(shapes, ch[uri(shapes_p)])
        ok = "area" not in new_app and new_app.count("surface") == 2 and "proc surface*" in new_shapes
    check("rename across modules", ok, ch)
    r = c.request("textDocument/rename", {"textDocument": {"uri": uri(shapes_p)}, "position": p, "newName": "proc"})
    check("rename to a keyword is refused", r and "error" in r, r)

    # document symbols
    r = c.request("textDocument/documentSymbol", {"textDocument": {"uri": uri(shapes_p)}})
    syms = (r or {}).get("result") or []
    names = {s["name"]: s for s in syms}
    ok = all(n in names for n in ["Shape", "Color", "area", "newShape"])
    if ok:
        kids = [k["name"] for k in names["Shape"].get("children", [])]
        vals = [k["name"] for k in names["Color"].get("children", [])]
        ok = kids == ["name", "width", "height"] and vals == ["red", "green", "blue"] and names["area"]["kind"] == 12
    check("documentSymbol: hierarchical (types hold fields and values)", ok, syms)

    # workspace symbols
    r = c.request("workspace/symbol", {"query": "newsha"})
    ws = (r or {}).get("result") or []
    check("workspace/symbol", any(s["name"] == "newShape" and s["location"]["uri"] == uri(shapes_p) for s in ws), ws[:5])

    # 6.27: the call hierarchy — area is called by describe and by the module's top level; describe calls area
    p = pos_of(shapes, "area*", after=1)
    r = c.request("textDocument/prepareCallHierarchy", {"textDocument": {"uri": uri(shapes_p)}, "position": p})
    items = (r or {}).get("result") or []
    check("prepareCallHierarchy: the routine (area)", items and items[0]["name"] == "area" and
          items[0]["uri"] == uri(shapes_p), items)
    if items:
        r = c.request("callHierarchy/incomingCalls", {"item": items[0]})
        inc = [x for x in (r or {}).get("result") or [] if x["from"]["uri"] == uri(app_p)]    # (stress.nim too)
        callers = sorted(x["from"]["name"] for x in inc)
        check("callHierarchy/incomingCalls: describe and app's top level, with where they call it",
              callers == ["app", "describe"] and all(x["fromRanges"] for x in inc) and
              all(range_text(app, rr) == "area" for x in inc for rr in x["fromRanges"]), inc)
        d_item = [x["from"] for x in inc if x["from"]["name"] == "describe"]
        if d_item:
            r = c.request("callHierarchy/outgoingCalls", {"item": d_item[0]})
            out = (r or {}).get("result") or []
            check("callHierarchy/outgoingCalls: describe calls area", any(x["to"]["name"] == "area" and
                  x["to"]["uri"] == uri(shapes_p) for x in out), out)
    # the type hierarchy and a method's implementations
    animals_p = os.path.join(src, "animals.nim")
    open_doc(c, animals_p, ANIMALS)
    p = pos_of(ANIMALS, "Dog* =", after=0)
    r = c.request("textDocument/prepareTypeHierarchy", {"textDocument": {"uri": uri(animals_p)}, "position": p})
    items = (r or {}).get("result") or []
    check("prepareTypeHierarchy: the type (Dog)", items and items[0]["name"] == "Dog", items)
    if items:
        r = c.request("typeHierarchy/supertypes", {"item": items[0]})
        sup = (r or {}).get("result") or []
        check("typeHierarchy/supertypes: Dog is made of Animal", [x["name"] for x in sup] == ["Animal"], sup)
        if sup:
            r = c.request("typeHierarchy/subtypes", {"item": sup[0]})
            sub = sorted(x["name"] for x in (r or {}).get("result") or [])
            check("typeHierarchy/subtypes: Animal's are Dog and Cat", sub == ["Cat", "Dog"], sub)
    p = pos_of(ANIMALS, "speak*(a: Animal)", after=1)
    r = c.request("textDocument/implementation", {"textDocument": {"uri": uri(animals_p)}, "position": p})
    impl = sorted(x["range"]["start"]["line"] for x in (r or {}).get("result") or [])
    want_l = [i for i, l in enumerate(ANIMALS.split("\n")) if l.startswith("method speak*(") and "Animal" not in l]
    check("implementation: the base method's overrides (Dog's and Cat's speak)", impl == want_l, (impl, want_l))
    # selection ranges: the name, then bigger pieces, up to the whole file
    p = pos_of(app, "s.name", after=3)
    r = c.request("textDocument/selectionRange", {"textDocument": {"uri": uri(app_p)}, "positions": [p]})
    chain = []
    node = ((r or {}).get("result") or [None])[0]
    while node:
        chain.append(range_text(app, node["range"]))
        node = node.get("parent")
    check("selectionRange: the name, the expression, the statement … the file", len(chain) >= 4 and
          chain[0] == "name" and chain[-1].strip() == app.strip() and
          any("result = s.name" in x for x in chain), chain)
    # document links: the import goes to the module
    r = c.request("textDocument/documentLink", {"textDocument": {"uri": uri(app_p)}})
    links = (r or {}).get("result") or []
    check("documentLink: `import shapes` → shapes.nim", any(l.get("target") == uri(shapes_p) and
          range_text(app, l["range"]) == "shapes" for l in links), links)
    # a module renamed: the imports that name it
    r = c.request("workspace/willRenameFiles", {"files": [{"oldUri": uri(shapes_p),
                                                           "newUri": uri(os.path.join(src, "geometry.nim"))}]})
    ch = ((r or {}).get("result") or {}).get("changes", {})
    check("workspace/willRenameFiles: shapes.nim → geometry.nim, app's import follows",
          uri(app_p) in ch and apply_edits(app, ch[uri(app_p)]).startswith("import geometry"), r)

    # semantic tokens
    r = c.request("textDocument/semanticTokens/full", {"textDocument": {"uri": uri(app_p)}})
    data = ((r or {}).get("result") or {}).get("data", [])
    legend = caps.get("semanticTokensProvider", {}).get("legend", {}).get("tokenTypes", [])
    ok = len(data) > 0 and len(data) % 5 == 0
    toks = []
    if ok:
        lines = app.split("\n")
        line = ch_ = 0
        for k in range(0, len(data), 5):
            dl, dc, ln, tt, mods = data[k:k + 5]
            if dl < 0 or ln <= 0 or tt < 0 or tt >= len(legend) or (dl == 0 and k > 0 and dc < 0):
                ok = False
                break
            line += dl
            ch_ = dc if dl else ch_ + dc
            if line >= len(lines):
                ok = False
                break
            s = lines[line]
            a = idx_of(s, ch_)
            b = idx_of(s, ch_ + ln)
            toks.append((s[a:b], legend[tt]))
    check("semanticTokens: well-formed (multiples of 5, sane deltas, names)", ok and toks and
          all(t[0].replace("_", "").isalnum() for t in toks), data[:30])
    td = dict(toks)
    check("semanticTokens: newShape is a function, Shape a type, s a parameter",
          td.get("newShape") == "function" and td.get("Shape") == "type" and td.get("s") in ("parameter", "variable")
          and ("s", "parameter") in toks, toks)
    r = c.request("textDocument/semanticTokens/range", {"textDocument": {"uri": uri(app_p)},
                                                        "range": {"start": {"line": 4, "character": 0},
                                                                  "end": {"line": 5, "character": 0}}})
    d2 = ((r or {}).get("result") or {}).get("data", [])
    check("semanticTokens/range", len(d2) > 0 and len(d2) % 5 == 0 and d2[0] == 4, d2)

    # inlay hints
    r = c.request("textDocument/inlayHint", {"textDocument": {"uri": uri(app_p)},
                                             "range": {"start": {"line": 0, "character": 0},
                                                       "end": {"line": 12, "character": 0}}})
    hs = (r or {}).get("result") or []
    lab = [(h["position"]["line"], h["label"]) for h in hs]
    check("inlayHint: the types of lets", (7, ": int") in lab and (2, ": Shape") in lab, lab)
    sq_hint = [h for h in hs if h["label"] == ": Shape"]
    if sq_hint:
        p = sq_hint[0]["position"]
        line = app.split("\n")[p["line"]]
        check("inlayHint position after a non-ASCII string (UTF-16)",
              line[:idx_of(line, p["character"])].endswith("let sq"), p)

    # settings: inlay hints off and on again
    rq = {"textDocument": {"uri": uri(app_p)}, "range": {"start": {"line": 0, "character": 0},
                                                         "end": {"line": 12, "character": 0}}}
    c.notify("workspace/didChangeConfiguration", {"settings": {"nedls": {"inlayHints": False}}})
    off = (c.request("textDocument/inlayHint", rq) or {}).get("result")
    c.notify("workspace/didChangeConfiguration", {"settings": {"nedls": {"inlayHints": True}}})
    on = (c.request("textDocument/inlayHint", rq) or {}).get("result")
    check("workspace/didChangeConfiguration: inlayHints off, then on", off == [] and on, (off, on))

    # folding
    r = c.request("textDocument/foldingRange", {"textDocument": {"uri": uri(shapes_p)}})
    fr = [(f["startLine"], f["endLine"]) for f in (r or {}).get("result") or []]
    check("foldingRange: type section, object, enum, procs", (2, 7) in fr and (3, 5) in fr and (6, 7) in fr and
          (9, 11) in fr and (13, 15) in fr, fr)

    # formatting
    open_doc(c, fmt_p, FMT)
    r = c.request("textDocument/formatting", {"textDocument": {"uri": uri(fmt_p)},
                                              "options": {"tabSize": 2, "insertSpaces": True}})
    es = (r or {}).get("result") or []
    got = apply_edits(FMT, es) if es else FMT
    check("formatting: ned's formatter", "proc f(a: int): int =" in got and "echo f(2)" in got, got)
    r = c.request("textDocument/rangeFormatting", {"textDocument": {"uri": uri(fmt_p)},
                                                   "range": {"start": {"line": 1, "character": 0},
                                                             "end": {"line": 2, "character": 0}},
                                                   "options": {"tabSize": 2, "insertSpaces": True}})
    es = (r or {}).get("result") or []
    got = apply_edits(FMT, es) if es else FMT
    check("rangeFormatting: only those lines", got.split("\n")[0] == FMT.split("\n")[0] and "echo f(2)" in got, got)

    # incremental change in one file, completion in another sees the unsaved text
    add = "\nproc perimeter*(s: Shape): int = 2 * (s.width + s.height)\n"
    end_line = shapes.count("\n")
    c.notify("textDocument/didChange", {"textDocument": {"uri": uri(shapes_p), "version": 2},
                                        "contentChanges": [{"range": {"start": {"line": end_line, "character": 0},
                                                                      "end": {"line": end_line, "character": 0}},
                                                            "text": add}]})
    shapes = shapes + add
    ins = "\necho sq.pe"
    lines = app.split("\n")
    last = len(lines) - 1
    c.notify("textDocument/didChange", {"textDocument": {"uri": uri(app_p), "version": 2},
                                        "contentChanges": [{"range": {"start": {"line": last, "character": 0},
                                                                      "end": {"line": last, "character": 0}},
                                                            "text": ins}]})
    app = app + ins
    p = pos_of(app, "sq.pe", after=5)
    r = c.request("textDocument/completion", {"textDocument": {"uri": uri(app_p)}, "position": p})
    check("didChange (incremental): completion sees the new unsaved proc of the other module",
          "perimeter" in labels(r or {}), labels(r or {})[:10])
    # an edit with a range inside a non-ASCII line (UTF-16): replace the word "square" by "box"
    p0 = pos_of(app, '"square"', after=1)
    p1 = {"line": p0["line"], "character": p0["character"] + 6}
    c.notify("textDocument/didChange", {"textDocument": {"uri": uri(app_p), "version": 3},
                                        "contentChanges": [{"range": {"start": p0, "end": p1}, "text": "box"}]})
    app = app.replace('"square"', '"box"')
    p = pos_of(app, "newShape", after=1)
    r = c.request("textDocument/hover", {"textDocument": {"uri": uri(app_p)}, "position": p})
    rng = ((r or {}).get("result") or {}).get("range")
    check("didChange inside a non-ASCII line keeps the columns right", rng and range_text(app, rng) == "newShape", rng)

    # cancel: a request and its cancellation in one write
    c.next_id += 1
    mid = c.next_id
    c.raw(c.frame({"jsonrpc": "2.0", "id": mid, "method": "textDocument/hover",
                   "params": {"textDocument": {"uri": uri(app_p)}, "position": {"line": 2, "character": 2}}}) +
          c.frame({"jsonrpc": "2.0", "method": "$/cancelRequest", "params": {"id": mid}}))
    r = c.wait(mid)
    check("$/cancelRequest → RequestCancelled", r and r.get("error", {}).get("code") == -32800, r)
    # a message in two pieces (a partial read)
    c.next_id += 1
    mid = c.next_id
    fr_ = c.frame({"jsonrpc": "2.0", "id": mid, "method": "textDocument/documentSymbol",
                   "params": {"textDocument": {"uri": uri(app_p)}}})
    c.raw(fr_[:30])
    time.sleep(0.3)
    c.raw(fr_[30:])
    r = c.wait(mid)
    check("a message split over two reads", r and isinstance(r.get("result"), list), r)

    # diagnostics: a misspelled field, an unused import (the compiler's, on save)
    open_doc(c, bad_p, BAD)
    if have_nim:
        c.notify("textDocument/didSave", {"textDocument": {"uri": uri(bad_p)}})
        ds = c.wait_diagnostics(uri(bad_p), lambda ds: any("aera" in d["message"] for d in ds) and
                                any("not used" in d["message"] for d in ds), timeout=90)
        ok = ds and any("aera" in d["message"] and d["severity"] == 1 and range_text(BAD, d["range"]) == "aera"
                        for d in ds)
        check("diagnostics after didSave: nim check's error, on the name", ok, ds)
        un = [d for d in ds or [] if "strutils" in d["message"] and "not used" in d["message"]]
        check("diagnostics: the unused import", un, ds)
        # quick fixes
        err = [d for d in ds or [] if "aera" in d["message"]]
        if err:
            r = c.request("textDocument/codeAction", {"textDocument": {"uri": uri(bad_p)}, "range": err[0]["range"],
                                                      "context": {"diagnostics": err}})
            acts = (r or {}).get("result") or []
            fix = [a for a in acts if a["title"] == "Change to area"]
            ok = fix and apply_edits(BAD, fix[0]["edit"]["changes"][uri(bad_p)]).count("s.area") == 1
            check("codeAction: undeclared field → Change to area", ok, [a["title"] for a in acts])
            check("codeAction: no Fix with AI without a model set up", not any("AI" in a["title"] for a in acts),
                  [a["title"] for a in acts])
        if un:
            r = c.request("textDocument/codeAction", {"textDocument": {"uri": uri(bad_p)}, "range": un[0]["range"],
                                                      "context": {"diagnostics": un}})
            acts = (r or {}).get("result") or []
            fix = [a for a in acts if "Remove unused import" in a["title"]]
            ok = fix and "strutils" not in apply_edits(BAD, fix[0]["edit"]["changes"][uri(bad_p)])
            check("codeAction: remove the unused import", ok, [a["title"] for a in acts])
        # two saves at once: checked one after the other, both answered
        bad2_p = os.path.join(src, "bad2.nim")
        open_doc(c, bad2_p, BAD2)
        c.notify("textDocument/didSave", {"textDocument": {"uri": uri(bad2_p)}})
        c.notify("textDocument/didSave", {"textDocument": {"uri": uri(bad_p)}})
        ds2 = c.wait_diagnostics(uri(bad2_p), lambda ds: any("mismatch" in d["message"] for d in ds), timeout=90)
        ds1 = c.wait_diagnostics(uri(bad_p), lambda ds: any("aera" in d["message"] for d in ds), timeout=90)
        check("two saves at once: both files checked (one after the other)",
              ds2 and any("mismatch" in d["message"] for d in ds2) and ds1 and
              any("aera" in d["message"] for d in ds1), (ds1, ds2))
        c.notify("textDocument/didClose", {"textDocument": {"uri": uri(bad2_p)}})
        ds2 = c.wait_diagnostics(uri(bad2_p), lambda ds: ds == [], timeout=10)
        check("didClose clears the file's problems", ds2 == [], ds2)
        # while typing: the compiler sees the unsaved text
        lines = BAD.split("\n")
        c.notify("textDocument/didChange", {"textDocument": {"uri": uri(bad_p), "version": 2},
                                            "contentChanges": [{"range": {"start": {"line": 4, "character": 7},
                                                                          "end": {"line": 4, "character": 11}},
                                                                "text": "width"}]})
        ds = c.wait_diagnostics(uri(bad_p), lambda ds: not any("aera" in d["message"] for d in ds), timeout=60)
        check("diagnostics while typing: the fixed text has no error", ds is not None and
              not any(d["severity"] == 1 for d in ds), ds)
        # the engine's own hints (no compiler run): a var nothing changes, and its quick fix
        hints_p = os.path.join(src, "hints.nim")
        open_doc(c, hints_p, HINTS)
        ds = c.wait_diagnostics(uri(hints_p), lambda ds: any("is never changed" in d["message"] for d in ds),
                                timeout=60)
        hv = [d for d in ds or [] if "'limit' is never changed" in d["message"]]
        check("engine hint: a var nothing changes can be a let (on its name)",
              hv and hv[0]["severity"] == 4 and range_text(HINTS, hv[0]["range"]) == "limit" and
              not any("'sum'" in d["message"] for d in ds), ds)
        if hv:
            r = c.request("textDocument/codeAction", {"textDocument": {"uri": uri(hints_p)}, "range": hv[0]["range"],
                                                      "context": {"diagnostics": hv}})
            acts = (r or {}).get("result") or []
            fix = [a for a in acts if a["title"] == "Make limit a let"]
            ok = fix and "let limit = 10" in apply_edits(HINTS, fix[0]["edit"]["changes"][uri(hints_p)])
            check("codeAction: var → let", ok, [a["title"] for a in acts])
            check("the hint names its rule (code: var-let)", hv[0].get("code") == "var-let", hv[0])
            sil = [a for a in acts if a["title"] == "Silence var-let on this line"]
            ok = sil and "var limit = 10  # ned: ignore[var-let]" in \
                apply_edits(HINTS, sil[0]["edit"]["changes"][uri(hints_p)])
            check("codeAction: silence the rule on this line", ok, [a["title"] for a in acts])
    else:
        print("SKIP  diagnostics (no nim on PATH)")

    # wrong params for every method: each one answered (a result or an error), the server still there
    methods = ["textDocument/completion", "completionItem/resolve", "textDocument/hover", "textDocument/signatureHelp",
               "textDocument/definition", "textDocument/declaration", "textDocument/typeDefinition",
               "textDocument/references", "textDocument/documentHighlight", "textDocument/prepareRename",
               "textDocument/rename", "textDocument/documentSymbol", "workspace/symbol",
               "textDocument/semanticTokens/full", "textDocument/semanticTokens/range", "textDocument/inlayHint",
               "textDocument/formatting", "textDocument/rangeFormatting", "textDocument/foldingRange",
               "textDocument/codeAction", "textDocument/prepareCallHierarchy", "callHierarchy/incomingCalls",
               "callHierarchy/outgoingCalls", "textDocument/prepareTypeHierarchy", "typeHierarchy/supertypes",
               "typeHierarchy/subtypes", "textDocument/implementation", "textDocument/selectionRange",
               "textDocument/codeLens", "textDocument/documentLink", "workspace/willRenameFiles"]
    junk = [None, [], 5, "x", {}, {"textDocument": 5}, {"textDocument": {"uri": 7}},
            {"textDocument": {"uri": uri(app_p)}, "position": "here"},
            {"textDocument": {"uri": uri(app_p)}, "position": {"line": -1, "character": -5}},
            {"textDocument": {"uri": uri(app_p)}, "position": {"line": 10 ** 9, "character": 10 ** 9},
             "range": {"start": {"line": 10 ** 9, "character": 0}, "end": {"line": -3, "character": 2 ** 40}},
             "newName": "", "query": None, "context": 3},
            {"textDocument": {"uri": "untitled:Untitled-1"}, "position": {"line": 0, "character": 0}},
            {"textDocument": {"uri": uri(app_p)}, "position": {"line": 2, "character": 17},
             "range": {"start": {"line": 2, "character": 17}, "end": {"line": 2, "character": 18}}}]
    answered = 0
    total = 0
    for m in methods:
        for j in junk:
            total += 1
            r = c.request(m, j, timeout=20)
            if r is not None and ("result" in r or "error" in r):
                answered += 1
    for j in junk:                                  # notifications with junk: no answer, no crash
        for m in ["textDocument/didChange", "textDocument/didSave", "textDocument/didClose", "textDocument/didOpen",
                  "workspace/didChangeConfiguration", "workspace/didChangeWatchedFiles", "$/cancelRequest"]:
            if j is not None and m == "textDocument/didClose" and isinstance(j, dict) and \
                    j.get("textDocument", {}) == {"uri": uri(app_p)}:
                continue
            c.notify(m, j)
    c.raw(b"Content-Length: 5\r\n\r\n[1,2]Content-Length: 2\r\n\r\n{}garbage\r\n\r\n")
    r = c.request("textDocument/documentSymbol", {"textDocument": {"uri": uri(shapes_p)}})
    check("wrong params for every method and notification: all answered, still running",
          answered == total and r is not None and c.p.poll() is None, "%d/%d" % (answered, total))

    # shutdown and exit
    r = c.request("shutdown", None)
    check("shutdown → null", r is not None and "result" in r and r["result"] is None, r)
    r = c.request("textDocument/hover", {"textDocument": {"uri": uri(app_p)}, "position": {"line": 0, "character": 0}},
                  timeout=5)
    check("a request after shutdown → InvalidRequest", r and r.get("error", {}).get("code") == -32600, r)
    c.notify("exit", {})
    code = c.close()
    check("exit after shutdown → exit code 0", code == 0, code)

    # UTF-8 positions, when the client offers them
    c, init = new_client(nedls, root, encodings=["utf-8", "utf-16"], log=log,
                         config={"nedls": {"inlayHints": False}})
    caps = (init or {}).get("result", {}).get("capabilities", {})
    check("initialize: UTF-8 positions when the client offers them", caps.get("positionEncoding") == "utf-8", caps)
    open_doc(c, app_p, APP)
    open_doc(c, shapes_p, SHAPES)
    line = APP.split("\n")[2]
    byte_col = len(line[:line.index("newShape") + 2].encode())
    r = c.request("textDocument/hover", {"textDocument": {"uri": uri(app_p)},
                                         "position": {"line": 2, "character": byte_col}})
    hv = json.dumps((r or {}).get("result") or {})
    rng = ((r or {}).get("result") or {}).get("range", {})
    hs = (c.request("textDocument/inlayHint", {"textDocument": {"uri": uri(app_p)},
                                               "range": {"start": {"line": 0, "character": 0},
                                                         "end": {"line": 12, "character": 0}}}) or {}).get("result")
    asked = any(m.get("method") == "<request> workspace/configuration" for m in c.notes)
    check("workspace/configuration: asked for, and followed (inlayHints false)", asked and hs == [], (asked, hs))
    check("hover with UTF-8 columns", "Makes a shape" in hv and rng.get("start", {}).get("character") ==
          len(line[:line.index("newShape")].encode()), rng)
    c.request("shutdown", None)
    c.notify("exit", {})
    c.close()

    if have_nim:
        run_nimscript(nedls, root, log)
        run_effects(nedls, root, log)
        run_nimscript620(nedls, root, log)
        run_nimscript622(nedls, root, log)


EFFECTS = '''import std/[asyncdispatch, os, strutils]
proc fetch(): Future[int] {.async.} =
  sleep(10)
  result = 1
proc main() =
  discard fetch()
  let x = await fetch()
  echo x
proc parseIt(s: string): int {.raises: [].} =
  parseInt(s)
var names: seq[string]
proc worker() {.gcsafe.} =
  names.add "x"
main()
echo parseIt("1")
worker()
'''


def run_effects(nedls, root, log):
    """6.20: the engine's async, raises and gcsafe checks"""
    d = os.path.join(root, "fx")
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, "fx.nim")
    with open(p, "w") as f:
        f.write(EFFECTS)
    c, init = new_client(nedls, d, log=log)
    open_doc(c, p, EFFECTS)
    want = lambda ds: all(any(k in x["message"] for x in ds) for k in ("sleepAsync", "asyncCheck", "can raise",
                                                                      "uses the global"))
    ds = c.wait_diagnostics(uri(p), want, timeout=40) or []
    by = {}
    for x in ds:
        by.setdefault(x["range"]["start"]["line"], []).append(x["message"])
    msgs = lambda l: " | ".join(by.get(l, []))
    check("async: sleep in an async proc → await sleepAsync", "sleepAsync" in msgs(2), by)
    check("async: a discarded Future → asyncCheck it", "asyncCheck" in msgs(5), by)
    check("async: await outside an async proc (the engine's word, or the compiler's)",
          "await works in an {.async.} proc only" in msgs(6) or "Can only 'await' inside a proc marked" in msgs(6), by)
    check("raises: the list leaves out ValueError", "can raise ValueError" in msgs(8), by)
    check("gcsafe: a global seq in a {.gcsafe.} proc", "uses the global names" in msgs(12), by)
    c.request("shutdown", None)
    c.notify("exit", {})
    c.close()


def run_nimscript(nedls, root, log):
    """6.19: config.nims and a .nimble are NimScript — their API there, not in a program; switches known"""
    ns = os.path.join(root, "ns")
    os.makedirs(os.path.join(ns, "src"), exist_ok=True)
    files = {
        "src/prog.nim": 'let d = thisDir()\nexec "ls"\necho d\n',
        "config.nims": '--threds:on\n--opt:speed\nswitch("defne", "x")\n--hint[Processing]:off\nlet d = thisDir()\n',
        "x.nimble": 'version = "1.0"\nauthor = "t"\ndescription = "t"\nlicense = "MIT"\n'
                    'namedBin["a"] = "b"\ntaskRequires "test", "unittest2"\nfeature "f":\n  requires "jsony"\n'
                    'requires "jsony >= 1.1"\n',
    }
    for n, t in files.items():
        with open(os.path.join(ns, n), "w") as f:
            f.write(t)
    c, init = new_client(nedls, ns, log=log)
    prog = os.path.join(ns, "src/prog.nim")
    open_doc(c, prog, files["src/prog.nim"])
    r = c.request("textDocument/completion", {"textDocument": {"uri": uri(prog)}, "position": {"line": 0, "character": 13}})
    check("NimScript: thisDir not offered in a program", "thisDir" not in labels(r), labels(r)[:8])
    ds = c.wait_diagnostics(uri(prog), lambda ds: sum("NimScript's" in d["message"] for d in ds) >= 2, timeout=30) or []
    msgs = [d["message"] for d in ds if "NimScript's" in d["message"]]
    check("NimScript: thisDir and exec in a program → what a program uses",
          len(msgs) == 2 and "execCmd" in msgs[1], msgs)
    cfg = os.path.join(ns, "config.nims")
    open_doc(c, cfg, files["config.nims"])
    ds = c.wait_diagnostics(uri(cfg), lambda ds: len(ds) >= 2, timeout=20) or []
    msgs = sorted(d["message"] for d in ds)
    check("NimScript: misspelled switches → the switch meant (and none for hint[…], thisDir)",
          len(msgs) == 2 and "--defne" in msgs[0] and "--define?" in msgs[0] and "--threads?" in msgs[1], msgs)
    r = c.request("textDocument/hover", {"textDocument": {"uri": uri(cfg)}, "position": {"line": 1, "character": 3}})
    hv = json.dumps((r or {}).get("result") or {})
    check("NimScript: hover on a switch → its help", "optimize" in hv, hv[:100])
    r = c.request("textDocument/completion", {"textDocument": {"uri": uri(cfg)}, "position": {"line": 1, "character": 6}})
    check("NimScript: a switch's values completed", "speed" in labels(r) and "size" in labels(r), labels(r)[:8])
    r = c.request("textDocument/completion", {"textDocument": {"uri": uri(cfg)}, "position": {"line": 4, "character": 12}})
    check("NimScript: config.nims sees thisDir", "thisDir" in labels(r), labels(r)[:8])
    nb = os.path.join(ns, "x.nimble")
    open_doc(c, nb, files["x.nimble"])
    for w in ["namedBin", "taskRequires", "feature"]:
        r = c.request("textDocument/hover", {"textDocument": {"uri": uri(nb)}, "position": pos_of(files["x.nimble"], w, after=1)})
        hv = json.dumps((r or {}).get("result") or {})
        check("NimScript: a .nimble knows nimble's " + w, w in hv and "pragma" not in hv, hv[:100])
    ds = c.wait_diagnostics(uri(nb), lambda ds: True, timeout=10) or []
    check("NimScript: a feature's requires is not \"required twice\"",
          not any("twice" in d["message"] for d in ds), [d["message"] for d in ds])
    c.request("shutdown", None)
    c.notify("exit", {})
    c.close()


def run_nimscript620(nedls, root, log):
    """6.20: deprecated switches (with their fix), -d: completed from the project's defined(x), --path: folders"""
    ns = os.path.join(root, "ns620")
    os.makedirs(os.path.join(ns, "src", "inner"), exist_ok=True)
    files = {
        "src/prog.nim": 'when defined(useFancy): echo 1\nconst level {.intdefine.} = 2\nconst tag {.strdefine: "prog.tag".} = ""\n',
        "config.nims": '--gc:orc\n--threads:on\n-d:\n--path:src/\n',
    }
    for n, t in files.items():
        with open(os.path.join(ns, n), "w") as f:
            f.write(t)
    c, init = new_client(nedls, ns, log=log)
    cfg = os.path.join(ns, "config.nims")
    open_doc(c, cfg, files["config.nims"])
    ds = c.wait_diagnostics(uri(cfg), lambda ds: len(ds) >= 2, timeout=20) or []
    msgs = sorted(d["message"] for d in ds)
    check("NimScript 6.20: --gc deprecated (--mm), --threads:on the default",
          len(msgs) == 2 and "--mm:orc says it now" in msgs[0] and "on by default since Nim 2.0" in msgs[1], msgs)
    gc = [d for d in ds if "--gc" in d["message"]]
    if gc:
        r = c.request("textDocument/codeAction", {"textDocument": {"uri": uri(cfg)}, "range": gc[0]["range"],
                                                  "context": {"diagnostics": gc}})
        acts = (r or {}).get("result") or []
        fix = [a for a in acts if a["title"] == "Use --mm:orc"]
        ok = fix and apply_edits(files["config.nims"], fix[0]["edit"]["changes"][uri(cfg)]).startswith("--mm:orc\n")
        check("NimScript 6.20: the fix — Use --mm:orc", ok, [a["title"] for a in acts])
    r = c.request("textDocument/completion", {"textDocument": {"uri": uri(cfg)}, "position": {"line": 2, "character": 3}})
    ls = labels(r)
    check("NimScript 6.20: -d: completes what the project asks about (defined, {.intdefine.}, {.strdefine: name.})",
          "useFancy" in ls and "level" in ls and "prog.tag" in ls and "release" in ls, ls[:12])
    r = c.request("textDocument/completion", {"textDocument": {"uri": uri(cfg)}, "position": {"line": 3, "character": 11}})
    check("NimScript 6.20: --path: completes folders", labels(r) == ["inner"], labels(r)[:8])
    c.request("shutdown", None)
    c.notify("exit", {})
    c.close()


def run_nimscript622(nedls, root, log):
    """6.22: system's NimScript part on hover and in completion, a task's hover, the tasks among the document's
    and the workspace's symbols, a module the VM cannot run, a doc comment joined by a trailing \\"""
    ns = os.path.join(root, "ns622")
    os.makedirs(ns, exist_ok=True)
    text = ('import std/osproc\nmode = ScriptMode.Verbose\n'
            'proc one(name: string, release = true) = ## builds \\\n  ## one program\n  exec "nim c " & name\n'
            'task build, "build every program":\n  one("app", release = false)\n  cpF\n')
    path = os.path.join(ns, "build.nims")
    with open(path, "w") as f:
        f.write(text)
    c, init = new_client(nedls, ns, log=log)
    open_doc(c, path, text)
    ds = c.wait_diagnostics(uri(path), lambda ds: any("does not run in NimScript" in d["message"] for d in ds),
                            timeout=20) or []
    check("NimScript 6.22: a module the VM cannot run (std/osproc), with what to use instead",
          any("std/osproc does not run in NimScript" in d["message"] and "gorgeEx" in d["message"] for d in ds),
          [d["message"] for d in ds])
    def hover(l, ch):
        r = c.request("textDocument/hover", {"textDocument": {"uri": uri(path)}, "position": {"line": l, "character": ch}})
        v = ((r or {}).get("result") or {}).get("contents") or {}
        return v.get("value", "") if isinstance(v, dict) else str(v)
    h = hover(4, 3)
    check("NimScript 6.22: hover on exec — its doc, system's NimScript part",
          "Executes an external process" in h and "system · NimScript" in h, h[:300])
    check("NimScript 6.22: hover on a task's name", "`nim build` runs it — build every program" in hover(5, 6),
          hover(5, 6))
    check("NimScript 6.22: a doc comment on the header line, joined by \\", "builds one program" in hover(6, 3),
          hover(6, 3))
    r = c.request("textDocument/completion", {"textDocument": {"uri": uri(path)}, "position": {"line": 7, "character": 5}})
    check("NimScript 6.22: completion — cpFile", "cpFile" in labels(r), labels(r)[:10])
    r = c.request("textDocument/documentSymbol", {"textDocument": {"uri": uri(path)}})
    names = [x.get("name") for x in (r or {}).get("result") or []]
    check("NimScript 6.22: the task among the document's symbols", "task build" in names and "one" in names, names)
    r = c.request("workspace/symbol", {"query": "build"})
    names = [x.get("name") for x in (r or {}).get("result") or []]
    check("NimScript 6.22: … and the workspace's", "task build" in names, names)
    c.request("shutdown", None)
    c.notify("exit", {})
    c.close()


# ── 6.27: the other languages — C, JavaScript, JSON, CSS, HTML, SQL — with ned's own engines ──

LX_H = """#ifndef SHAPES_H
#define SHAPES_H
struct Point { int x; int y; };
/* the distance between two points, squared */
int dist2(struct Point *a, struct Point *b);
#endif
"""

LX_C = """#include "shapes.h"
int dist2(struct Point *a, struct Point *b) {
  int dx = a->x - b->x;
  int dy = a->y - b->y;
  return dx * dx + dy * dy;
}
"""

LX_MAIN = """#include <stdio.h>
#include "shapes.h"
int main(void) {
  struct Point p = {1, 2}, q = {4, 6};
  struct Point *pp = &p;
  printf("%d\\n", dist2(pp, &q));
  return pp->x;
}
"""

LX_UTIL = """export function join(...parts) {
  return parts.join("/");
}

export class Store {
  constructor() { this.items = []; }
  add(x) { this.items.push(x); return this; }
}
"""

LX_APP = """import { join, Store } from "./util.js";

const DEFAULTS = { root: "/" };
const s = new Store();
s.add(join(DEFAULTS.root, "a"));
console.log(join("b", "c"));
"""


def lx_lang(path):
    ext = os.path.splitext(path)[1]
    return {".c": "c", ".h": "c", ".js": "javascript", ".json": "json", ".css": "css", ".html": "html",
            ".sql": "sql", ".nif": "nif"}.get(ext, "plaintext")


def run_langs(nedls, log):
    root = tempfile.mkdtemp(prefix="tnedls-lx-")
    files = {"shapes.h": LX_H, "shapes.c": LX_C, "main.c": LX_MAIN, "util.js": LX_UTIL, "app.js": LX_APP,
             "package.json": '{\n  "name": "demo",\n  "nmae": "x",\n  "type": "modul"\n}\n',
             "style.css": "a {\n  colr: red;\n}\n", "page.html": "<!doctype html>\n<html>\n<body>\n<di\n</body>\n</html>\n",
             "q.sql": "CREATE TABLE users (id INTEGER, name TEXT);\nSELECT name FROM us\n",
             "ins.sql": "INSERT INTO users (id, nmae) VALUES (1, 'a', 'b');\n",
             "site.html": '<!doctype html>\n<html>\n<body>\n<a href="#intro">i</a> <a href="gone.html">g</a>\n'
                          '<div clas="x" id="intro"></div>\n</body>\n</html>\n',
             "vars.css": ":root { --primary: #333; }\na { color: var(--primay); }\n",
             "pnak.nif": '(.nif27)\n(stmts\n (requires "https://github.com/a/jsony.git" "0123abcd")\n'
                         ' (requires "https://github.com/b/zippy.git" "main")\n'
                         ' (requires "https://github.com/a/jsony.git" "0123abcd"))\n'}
    for name, text in files.items():
        with open(os.path.join(root, name), "w") as f:
            f.write(text)
    with open(os.path.join(root, "extra.c"), "w") as f:            # (a C file never opened: 6.28's symbols)
        f.write("static int extraHelper(int n) { return n + 1; }\n")
    # (pnak fetched jsony, at another commit; zippy not yet)
    os.makedirs(os.path.join(root, "deps", "jsony", ".git"))
    with open(os.path.join(root, "deps", "jsony", ".git", "HEAD"), "w") as f:
        f.write("ffff0000aaaa\n")
    with open(os.path.join(root, "deps", "jsony", "jsony.nimble"), "w") as f:
        f.write('version = "1.1.5"\n')
    c, init = new_client(nedls, root, log=log)
    try:
        def P(name):
            return os.path.join(root, name)
        for name, text in files.items():
            c.notify("textDocument/didOpen", {"textDocument": {"uri": uri(P(name)), "languageId": lx_lang(name),
                                                               "version": 1, "text": text}})
        def req(m, name, l=None, ch=None, **kw):
            params = {"textDocument": {"uri": uri(P(name))}}
            if l is not None:
                params["position"] = {"line": l, "character": ch}
            params.update(kw)
            return (c.request(m, params) or {}).get("result")
        caps = init["result"]["capabilities"]
        check("6.27 langs: completion triggers for C, HTML, CSS, JSON", all(t in caps["completionProvider"]["triggerCharacters"]
                                                                           for t in [".", ">", "<", ":", "\""]))
        # ── C ──
        ml = LX_MAIN.split("\n")
        r = req("textDocument/completion", "main.c", 6, len("  return pp->"))
        lab = [i["label"] for i in (r or {}).get("items", [])]
        check("6.27 C: completion after -> — the struct's fields", "x" in lab and "y" in lab, lab[:10])
        h = req("textDocument/hover", "main.c", 5, ml[5].index("dist2") + 1)
        hv = ((h or {}).get("contents") or {}).get("value", "")
        check("6.27 C: hover — the declaration and its comment", "dist2" in hv and "distance" in hv, hv[:200])
        r = req("textDocument/definition", "main.c", 5, ml[5].index("dist2") + 1) or []
        check("6.27 C: definition — the body in shapes.c", any(x["uri"].endswith("shapes.c") for x in r), r)
        r = req("textDocument/references", "shapes.h", 4, 5, context={"includeDeclaration": True}) or []
        where = sorted(set(os.path.basename(x["uri"]) for x in r))
        check("6.27 C: references across the project's files", where == ["main.c", "shapes.c", "shapes.h"], where)
        r = req("textDocument/rename", "main.c", 5, ml[5].index("dist2") + 1, newName="distSq") or {}
        ch = r.get("changes", {})
        check("6.27 C: rename — every file", len(ch) == 3 and all(e["newText"] == "distSq" for es in ch.values() for e in es),
              list(ch))
        r = req("textDocument/signatureHelp", "main.c", 5, ml[5].index("(pp") + 4)
        sig = ((r or {}).get("signatures") or [{}])[0]
        check("6.27 C: signature help — the parameters, the second one active",
              "dist2(" in sig.get("label", "") and len(sig.get("parameters", [])) == 2 and r.get("activeParameter") == 1, r)
        r = req("textDocument/documentSymbol", "shapes.c") or []
        check("6.27 C: symbols", any(x["name"] == "dist2" and x["kind"] == 12 for x in r), [x["name"] for x in r])
        # ── JavaScript ──
        al = LX_APP.split("\n")
        r = req("textDocument/definition", "app.js", 5, al[5].index("join") + 1) or []
        check("6.27 JS: definition of an import — in the module it comes from",
              len(r) == 1 and r[0]["uri"].endswith("util.js") and r[0]["range"]["start"]["line"] == 0, r)
        r = req("textDocument/references", "util.js", 0, 17, context={"includeDeclaration": True}) or []
        where = sorted((os.path.basename(x["uri"]), x["range"]["start"]["line"]) for x in r)
        check("6.27 JS: references of an export — the files that import it", where == [
            ("app.js", 0), ("app.js", 4), ("app.js", 5), ("util.js", 0)], where)
        r = req("textDocument/rename", "util.js", 0, 17, newName="joinAll") or {}
        n = sum(len(es) for es in r.get("changes", {}).values())
        check("6.27 JS: rename across modules", n == 4 and len(r.get("changes", {})) == 2, r)
        r = req("textDocument/documentSymbol", "util.js") or []
        store = [x for x in r if x["name"] == "Store"]
        check("6.27 JS: symbols — a class holds its methods", store and any(k["name"] == "add" for k in store[0].get("children", [])),
              r)
        # ── JSON, CSS, HTML, SQL ──
        ds = c.wait_diagnostics(uri(P("package.json")), lambda ds: len(ds) >= 2, timeout=20) or []
        msgs = [d["message"] for d in ds]
        check("6.27 JSON: package.json — a misspelled key, a value it does not take",
              any('"nmae"' in m and '"name"?' in m for m in msgs) and any('"module"?' in m for m in msgs), msgs)
        r = req("textDocument/completion", "package.json", 1, 3)
        lab = [i["label"] for i in (r or {}).get("items", [])]
        check("6.27 JSON: completion — the keys package.json has", "version" in lab and "scripts" in lab, lab[:10])
        h = req("textDocument/hover", "package.json", 3, 4)
        check("6.27 JSON: hover — what a key does", "module" in (((h or {}).get("contents") or {}).get("value", "")), h)
        r = req("textDocument/formatting", "package.json", options={"tabSize": 2, "insertSpaces": True})
        check("6.27 JSON: formatting answers (already formatted: no edits)", r == [], r)
        ds = c.wait_diagnostics(uri(P("style.css")), lambda ds: len(ds) >= 1, timeout=20) or []
        check("6.27 CSS: an unknown property", any("colr" in d["message"] for d in ds), [d["message"] for d in ds])
        r = req("textDocument/completion", "page.html", 3, 3)
        lab = [i["label"] for i in (r or {}).get("items", [])]
        check("6.27 HTML: completion of an element", "div" in lab, lab[:10])
        r = req("textDocument/completion", "q.sql", 1, len("SELECT name FROM us"))
        lab = [i["label"] for i in (r or {}).get("items", [])]
        check("6.27 SQL: completion of a table the project creates", "users" in lab, lab[:10])
        r = req("textDocument/semanticTokens/full", "app.js")
        check("6.27 langs: no Nim colours for another language", (r or {}).get("data") == [], r)
        # ── more of HTML, CSS and SQL ──
        ds = c.wait_diagnostics(uri(P("site.html")), lambda ds: len(ds) >= 2, timeout=20) or []
        msgs = sorted(d["message"] for d in ds)
        check("6.27 HTML: a link to a file not beside the page, an attribute's typo",
              any("gone.html" in m for m in msgs) and any("'class'?" in m for m in msgs) and
              not any("#intro" in m for m in msgs), msgs)
        ds = c.wait_diagnostics(uri(P("vars.css")), lambda ds: len(ds) >= 1, timeout=20) or []
        check("6.27 CSS: var() of a custom property the sheet does not set — a typo",
              any("--primary" in d["message"] for d in ds), [d["message"] for d in ds])
        ds = c.wait_diagnostics(uri(P("ins.sql")), lambda ds: len(ds) >= 2, timeout=20) or []
        msgs = [d["message"] for d in ds]
        check("6.27 SQL: INSERT — a column the table does not have, more values than columns",
              any("'name'" in m for m in msgs) and any("3 values for 2 columns" in m for m in msgs), msgs)
        # ── pnak.nif ──
        ds = c.wait_diagnostics(uri(P("pnak.nif")), lambda ds: len(ds) >= 3, timeout=20) or []
        msgs = [d["message"] for d in ds]
        check("6.27 pnak.nif: twice, a branch for a commit, not fetched, at another commit",
              any("twice" in m for m in msgs) and any("branch or a tag" in m for m in msgs) and
              any("zippy is not in deps" in m for m in msgs) and any("deps/jsony is at ffff0000aa" in m for m in msgs),
              msgs)
        r = req("textDocument/documentSymbol", "pnak.nif") or []
        check("6.27 pnak.nif: the packages in the outline", [x["name"] for x in r] == ["jsony", "zippy", "jsony"],
              [x.get("name") for x in r])
        h = req("textDocument/hover", "pnak.nif", 2, 12)
        hv = ((h or {}).get("contents") or {}).get("value", "")
        check("6.27 pnak.nif: hover — the package, its commit, where it is checked out",
              "jsony" in hv and "0123abcd" in hv and "deps" in hv, hv)
        r = req("textDocument/definition", "pnak.nif", 2, 12) or []
        check("6.27 pnak.nif: definition — the package's .nimble in deps/",
              len(r) == 1 and r[0]["uri"].endswith("deps/jsony/jsony.nimble"), r)
        # ── 6.28: workspace symbols in C, JavaScript and JSON; linked editing of an HTML tag ──
        caps = init["result"]["capabilities"]
        check("6.28 langs: linked editing offered", caps.get("linkedEditingRangeProvider") is True, caps.keys())
        def ws(q):
            return (c.request("workspace/symbol", {"query": q}) or {}).get("result") or []
        r = ws("dist2")
        where = sorted(set(os.path.basename(x["location"]["uri"]) for x in r if x["name"] == "dist2"))
        check("6.28 workspace symbols: a C function, in its header and its file", "shapes.c" in where and
              "shapes.h" in where, [(x["name"], x["location"]["uri"]) for x in r][:8])
        r = ws("extraHelper")
        check("6.28 workspace symbols: a C file not open", any(x["name"] == "extraHelper" and
              x["location"]["uri"].endswith("extra.c") for x in r), [(x["name"], x["location"]["uri"]) for x in r][:8])
        r = ws("Store")
        check("6.28 workspace symbols: a JavaScript class", any(x["name"] == "Store" and
              x["location"]["uri"].endswith("util.js") for x in r), [(x["name"], x["location"]["uri"]) for x in r][:8])
        r = ws("nmae")
        check("6.28 workspace symbols: a JSON key", any(x["name"] == "nmae" and
              x["location"]["uri"].endswith("package.json") for x in r), [(x["name"], x["location"]["uri"]) for x in r][:8])
        with open(P("tags.html"), "w") as f:
            f.write("<div>\n  <span>x</span>\n</div>\n")
        c.notify("textDocument/didOpen", {"textDocument": {"uri": uri(P("tags.html")), "languageId": "html",
                                                           "version": 1, "text": "<div>\n  <span>x</span>\n</div>\n"}})
        r = req("textDocument/linkedEditingRange", "tags.html", 0, 2) or {}
        rs = [(x["start"]["line"], x["start"]["character"], x["end"]["character"]) for x in r.get("ranges", [])]
        check("6.28 HTML: linked editing — an opening tag's name and its closing tag's", rs == [(0, 1, 4), (2, 2, 5)], r)
        r = req("textDocument/linkedEditingRange", "tags.html", 1, 14) or {}
        rs = [(x["start"]["line"], x["start"]["character"], x["end"]["character"]) for x in r.get("ranges", [])]
        check("6.28 HTML: … and from the closing tag", rs == [(1, 11, 15), (1, 3, 7)], r)
    finally:
        c.request("shutdown", None)
        c.notify("exit", {})
        c.close()
        shutil.rmtree(root, ignore_errors=True)


# ── 6.29: ned's C engine — by symbol, call snippets, a missing #include, calls over several lines, highlights,
#    semantic tokens, refactors, type definition, range formatting, C++'s type hierarchy and implementations ──

CE_FIELDS = """struct a { int x; };
struct b { int x; };
static int helper(int n) { return n; }
int use(struct a *p, struct b *q) {
  int x = p->x + q->x;
  return x + helper(1);
}
"""

CE_OTHER = """static int helper(int n) { return n * 2; }
int more(void) { return helper(3); }
"""

CE_UTIL_H = """#ifndef UTIL_H
#define UTIL_H
/* adds two numbers */
int util_sum(int first, int second);
#endif
"""

CE_COMP = """#include "fields.h"
enum color { RED, GREEN, BLUE };
int area(int width, int height);
int f(enum color c, struct a *p, int n) {
  int k = area(3,
               4);
  switch (c) {
  case RED:
    break;
  }
  if (n > 0) {
    k = 1;
  } else {
    k = 2;
  }
  int s = util_sum(1, 2);
  return k + p->x * n + s;
}
"""

CE_FMT = """int g(int a,int b){
int c=a+b;
int d=a*b;
return c+d;}
"""

CE_CPP = """class Shape {
public:
  virtual double area() const = 0;
};
class Circle : public Shape {
public:
  double area() const override;
};
class Ring : public Circle {
public:
  double area() const override;
};
double Circle::area() const { return 3.14; }
double Ring::area() const { return 1.0; }
double total(const Shape &s) { return s.area(); }
"""


def run_c_engine(nedls, log):
    root = tempfile.mkdtemp(prefix="tnedls-ce-")
    files = {"fields.c": CE_FIELDS, "other.c": CE_OTHER, "util.h": CE_UTIL_H, "comp.c": CE_COMP, "fmt.c": CE_FMT,
             "shapes.cpp": CE_CPP,
             "fields.h": "struct a { int x; };\n"}
    for name, text in files.items():
        with open(os.path.join(root, name), "w") as f:
            f.write(text)
    c, init = new_client(nedls, root, log=log)
    try:
        def P(name):
            return os.path.join(root, name)
        for name, text in files.items():
            lang = "cpp" if name.endswith(".cpp") else "c"
            c.notify("textDocument/didOpen", {"textDocument": {"uri": uri(P(name)), "languageId": lang,
                                                               "version": 1, "text": text}})
        def req(m, name, l=None, ch=None, **kw):
            params = {"textDocument": {"uri": uri(P(name))}}
            if l is not None:
                params["position"] = {"line": l, "character": ch}
            params.update(kw)
            return (c.request(m, params) or {}).get("result")
        fl = CE_FIELDS.split("\n")
        # ── by symbol, not by name ──
        r = req("textDocument/references", "fields.c", 4, fl[4].index("p->x") + 3, context={"includeDeclaration": True}) or []
        where = sorted((os.path.basename(x["uri"]), x["range"]["start"]["line"], x["range"]["start"]["character"]) for x in r)
        check("6.29 C references: a field — its struct's, not another struct's of that name, not a local",
              where == [("fields.c", 0, fl[0].index("x")), ("fields.c", 4, fl[4].index("p->x") + 3)], where)
        r = req("textDocument/rename", "fields.c", 4, fl[4].index("int x") + 4, newName="sum") or {}
        es = sorted((e["range"]["start"]["line"], e["range"]["start"]["character"]) for es in r.get("changes", {}).values() for e in es)
        check("6.29 C rename: a local — its uses only, not the fields of that name",
              es == [(4, fl[4].index("int x") + 4), (5, fl[5].index("x +"))], es)
        r = req("textDocument/references", "fields.c", 5, fl[5].index("helper"), context={"includeDeclaration": True}) or []
        where = sorted(set(os.path.basename(x["uri"]) for x in r))
        check("6.29 C references: a static function — its file's, not another file's static of that name",
              where == ["fields.c"] and len(r) == 2, [(os.path.basename(x["uri"]), x["range"]["start"]["line"]) for x in r])
        r = req("textDocument/documentHighlight", "fields.c", 4, fl[4].index("q->x") + 3) or []
        hl = sorted((x["range"]["start"]["line"], x["range"]["start"]["character"]) for x in r)
        check("6.29 C highlights: the uses of what the name names in the file",
              hl == [(1, fl[1].index("x")), (4, fl[4].index("q->x") + 3)], hl)
        # ── completion: a call's arguments to fill in; a name a header the file does not include declares ──
        cl = CE_COMP.split("\n")
        c.notify("textDocument/didChange", {"textDocument": {"uri": uri(P("comp.c")), "version": 2},
                                           "contentChanges": [{"text": CE_COMP.replace("  int s = util_sum(1, 2);",
                                                                                       "  int s = ar\n  prin\n  util_s")}]})
        r = req("textDocument/completion", "comp.c", 15, len("  int s = ar"))
        it = [i for i in (r or {}).get("items", []) if i["label"] == "area"]
        check("6.29 C completion: a function with its parameters to fill in",
              it and it[0].get("insertTextFormat") == 2 and it[0]["textEdit"]["newText"] == "area(${1:width}, ${2:height})$0",
              it[:1])
        r = req("textDocument/completion", "comp.c", 16, len("  prin"))
        it = [i for i in (r or {}).get("items", []) if i["label"] == "printf"]
        ed = (it[0].get("additionalTextEdits") or [{}])[0] if it else {}
        check("6.29 C completion: printf from <stdio.h>, which the file does not include — the #include added",
              ed.get("newText") == "#include <stdio.h>\n" and ed["range"]["start"]["line"] == 1, it[:1])
        r = req("textDocument/completion", "comp.c", 17, len("  util_s"))
        it = [i for i in (r or {}).get("items", []) if i["label"] == "util_sum"]
        ed = (it[0].get("additionalTextEdits") or [{}])[0] if it else {}
        check("6.29 C completion: a project header's function — its #include \"util.h\" added",
              ed.get("newText") == '#include "util.h"\n', it[:1])
        c.notify("textDocument/didChange", {"textDocument": {"uri": uri(P("comp.c")), "version": 3},
                                           "contentChanges": [{"text": CE_COMP}]})
        # ── quick fixes and refactors ──
        def actions(l, ch, l2=None, ch2=None):
            rng = {"start": {"line": l, "character": ch}, "end": {"line": l if l2 is None else l2,
                                                                  "character": ch if ch2 is None else ch2}}
            return req("textDocument/codeAction", "comp.c", range=rng, context={"diagnostics": []}) or []
        acts = actions(15, cl[15].index("util_sum") + 2)
        check("6.29 C quick fix: an unknown name — the #include of the header that declares it",
              any(a["title"] == '#include "util.h"' for a in acts), [a["title"] for a in acts])
        acts = actions(6, 3)
        sw = [a for a in acts if a["title"].startswith("Add the 2 missing cases")]
        new = sw[0]["edit"]["changes"][uri(P("comp.c"))][0]["newText"] if sw else ""
        check("6.29 C refactor: a switch's missing cases", new == "  case GREEN:\n    break;\n  case BLUE:\n    break;\n",
              [a["title"] for a in acts])
        acts = actions(10, 3)
        check("6.29 C refactor: an if/else inverted", any(a["title"].startswith("Invert the if") for a in acts),
              [a["title"] for a in acts])
        acts = actions(16, cl[16].index("p->x"), 16, cl[16].index(" * n"))
        check("6.29 C refactor: a selection into a variable of its type",
              any(a["title"] == "Extract into a variable: int x = p->x;" for a in acts), [a["title"] for a in acts])
        # ── a call over several lines: signature help, the parameters' names ──
        r = req("textDocument/signatureHelp", "comp.c", 5, cl[5].index("4") + 1)
        check("6.29 C signature help: a call over two lines — its second parameter",
              r and "area(" in r["signatures"][0]["label"] and r.get("activeParameter") == 1, r)
        r = req("textDocument/inlayHint", "comp.c", range={"start": {"line": 0, "character": 0},
                                                           "end": {"line": 17, "character": 0}}) or []
        hs = sorted((h["position"]["line"], h["label"]) for h in r)
        check("6.29 C parameter names: on both lines of the call", (4, "width:") in hs and (5, "height:") in hs, hs)
        # ── type definition, semantic tokens ──
        r = req("textDocument/typeDefinition", "comp.c", 16, cl[16].index("p->"))
        check("6.29 C type definition: a parameter's struct", r and r[0]["uri"].endswith("fields.h") and
              r[0]["range"]["start"]["line"] == 0, r)
        r = req("textDocument/semanticTokens/full", "comp.c") or {}
        data = r.get("data", [])
        toks, l0, c0 = {}, 0, 0
        for i in range(0, len(data), 5):
            dl, dc, n, t, m = data[i:i + 5]
            l0 = l0 + dl
            c0 = c0 + dc if dl == 0 else dc
            toks[(l0, cl[l0][c0:c0 + n])] = t
        types = init["result"]["capabilities"]["semanticTokensProvider"]["legend"]["tokenTypes"]
        want = {(4, "area"): "function", (16, "p"): "parameter", (16, "x"): "property", (16, "k"): "variable",
                (7, "RED"): "enumMember", (3, "color"): "type"}
        got = {k: types[toks[k]] if k in toks else None for k in want}
        check("6.29 C semantic tokens: functions, parameters, fields, locals, enum constants, types", got == want, got)
        # ── formatting a range ──
        r = req("textDocument/rangeFormatting", "fmt.c", range={"start": {"line": 1, "character": 0},
                                                                "end": {"line": 1, "character": 5}},
                options={"tabSize": 2, "insertSpaces": True}) or []
        lines = sorted(set(l for e in r for l in range(e["range"]["start"]["line"], e["range"]["end"]["line"] + 1)))
        check("6.29 C range formatting: the lines of the range only",
              lines == [1] and r[0]["newText"].strip() == "int c = a + b;", r)
        # ── C++: the type hierarchy, implementations ──
        pl = CE_CPP.split("\n")
        r = req("textDocument/prepareTypeHierarchy", "shapes.cpp", 4, pl[4].index("Circle")) or []
        check("6.29 C++ type hierarchy: a class", len(r) == 1 and r[0]["name"] == "Circle", r)
        if r:
            sup = (c.request("typeHierarchy/supertypes", {"item": r[0]}) or {}).get("result") or []
            sub = (c.request("typeHierarchy/subtypes", {"item": r[0]}) or {}).get("result") or []
            check("6.29 C++ type hierarchy: its base and the class derived from it",
                  [x["name"] for x in sup] == ["Shape"] and [x["name"] for x in sub] == ["Ring"],
                  ([x["name"] for x in sup], [x["name"] for x in sub]))
        r = req("textDocument/implementation", "shapes.cpp", 2, pl[2].index("area")) or []
        where = sorted(x["range"]["start"]["line"] for x in r)
        check("6.29 C++ implementation: a virtual method's overrides (their bodies)", where == [12, 13], r)
    finally:
        c.request("shutdown", None)
        c.notify("exit", {})
        c.close()
        shutil.rmtree(root, ignore_errors=True)


def run_628(nedls, log):
    """6.28: problems the client asks for (pull diagnostics), Enter formatting the statement before it"""
    root = tempfile.mkdtemp(prefix="tnedls-628-")
    with open(os.path.join(root, "p.nimble"), "w") as f:
        f.write('version = "0.1.0"\nauthor = "t"\ndescription = "t"\nlicense = "MIT"\n')
    a_p = os.path.join(root, "a.nim")
    text = 'proc greet(name: string): string = name\necho gret("x")\n'
    with open(a_p, "w") as f:
        f.write(text)
    c, init = new_client(nedls, root, log=log, more_caps={"textDocument": {"diagnostic": {}},
                                                          "workspace": {"diagnostics": {"refreshSupport": True}}})
    try:
        caps = init["result"]["capabilities"]
        check("6.28 pull diagnostics: offered to a client that asks", isinstance(caps.get("diagnosticProvider"), dict),
              caps.get("diagnosticProvider"))
        check("6.28 on-type formatting: offered, on Enter", (caps.get("documentOnTypeFormattingProvider") or {})
              .get("firstTriggerCharacter") == "\n", caps.get("documentOnTypeFormattingProvider"))
        open_doc(c, a_p, text)
        items, res = [], {}
        end = time.time() + 20
        while time.time() < end:
            res = (c.request("textDocument/diagnostic", {"textDocument": {"uri": uri(a_p)}}) or {}).get("result") or {}
            items = res.get("items") or []
            if any("gret" in d["message"] for d in items):
                break
            time.sleep(0.4)
        check("6.28 pull diagnostics: the misspelled name, when asked", res.get("kind") == "full" and
              any("gret" in d["message"] for d in items), res)
        again = (c.request("textDocument/diagnostic", {"textDocument": {"uri": uri(a_p)},
                                                       "previousResultId": res.get("resultId")}) or {}).get("result")
        check("6.28 pull diagnostics: unchanged since the last answer", (again or {}).get("kind") == "unchanged", again)
        pushed = c.diagnostics(uri(a_p))
        check("6.28 pull diagnostics: not also sent for the open document", not pushed, pushed)
        # Enter after a statement: it is formatted; the new line, and a statement going on, are not touched
        f_p = os.path.join(root, "f.nim")
        ftext = "proc f() =\n  let x=f( 1,2)\n  \n"
        with open(f_p, "w") as f:
            f.write(ftext)
        open_doc(c, f_p, ftext)
        r = (c.request("textDocument/onTypeFormatting", {"textDocument": {"uri": uri(f_p)},
             "position": {"line": 2, "character": 2}, "ch": "\n",
             "options": {"tabSize": 2, "insertSpaces": True}}) or {}).get("result") or []
        after = apply_edits(ftext, r)
        check("6.28 on-type formatting: Enter formats the statement before it", after == "proc f() =\n  let x = f(1, 2)\n  \n",
              (r, after))
        gtext = "proc g() =\n  let y = g(1,\n    \n"
        c.notify("textDocument/didChange", {"textDocument": {"uri": uri(f_p), "version": 2},
                                            "contentChanges": [{"text": gtext}]})
        r = (c.request("textDocument/onTypeFormatting", {"textDocument": {"uri": uri(f_p)},
             "position": {"line": 2, "character": 4}, "ch": "\n",
             "options": {"tabSize": 2, "insertSpaces": True}}) or {}).get("result")
        check("6.28 on-type formatting: not a statement that goes on", r == [], r)
    finally:
        c.request("shutdown", None)
        c.notify("exit", {})
        c.close()
        shutil.rmtree(root, ignore_errors=True)


# ── 6.32: the workspace's problems when asked (workspace/diagnostic), semantic token deltas, workspace symbols ──

GEO632 = """import std/strutils

type
  Shape* = object
    width*, height*: int
  Kind* = enum
    kRound, kSquare

proc area*(s: Shape): int = s.width * s.height
proc joinAll*(xs: seq[string]): string = xs.join(",")
proc oldWay*() {.deprecated: "use area".} = discard
proc newShapeValue*(w, h: int): Shape = Shape(width: w, height: h)
"""

LINTME632 = """import std/strutils
import geo

echo area(newShapeValue(1, 2))
"""

MAIN632 = """import geo

let first = area(newShapeValue(2, 3))
echo first
"""


def tokens_after(old, edits):
    """semantic token data with a delta's edits applied (each edit's start is in the old data)"""
    data = list(old)
    for e in sorted(edits, key=lambda e: e["start"], reverse=True):
        data[e["start"]:e["start"] + e["deleteCount"]] = e.get("data") or []
    return data


def run_632(nedls, log):
    """6.32: pull diagnostics for the whole workspace, semantic token deltas, workspace symbols"""
    root = tempfile.mkdtemp(prefix="tnedls-632-")
    src = os.path.join(root, "src")
    os.makedirs(src)
    with open(os.path.join(root, "p632.nimble"), "w") as f:
        f.write('version = "0.1.0"\nauthor = "t"\ndescription = "t"\nlicense = "MIT"\nsrcDir = "src"\n')
    geo_p, lint_p, main_p = (os.path.join(src, n) for n in ("geo.nim", "lint_me.nim", "main.nim"))
    for path, text in ((geo_p, GEO632), (lint_p, LINTME632), (main_p, MAIN632)):
        with open(path, "w") as f:
            f.write(text)
    c, init = new_client(nedls, root, log=log, more_caps={
        "textDocument": {"diagnostic": {}},
        "workspace": {"diagnostics": {"refreshSupport": True}, "symbol": {"tagSupport": {"valueSet": [1]}}}})
    try:
        caps = init["result"]["capabilities"]
        check("6.32 pull diagnostics: the workspace's too (workspaceDiagnostics)",
              (caps.get("diagnosticProvider") or {}).get("workspaceDiagnostics") is True, caps.get("diagnosticProvider"))
        check("6.32 semantic tokens: deltas offered", (caps.get("semanticTokensProvider") or {}).get("full") ==
              {"delta": True}, caps.get("semanticTokensProvider"))
        open_doc(c, main_p, MAIN632)

        # ── workspace symbols ──
        def ws(q):
            return (c.request("workspace/symbol", {"query": q}) or {}).get("result") or []

        def names(rs):
            return [(x["name"], x.get("containerName"), os.path.basename(x["location"]["uri"])) for x in rs][:8]
        r = ws("area")
        check("6.32 workspace symbols: the name itself first", r and r[0]["name"] == "area" and
              r[0]["location"]["uri"] == uri(geo_p), names(r))
        r = ws("nsv")
        check("6.32 workspace symbols: the starts of a name's words (nsv: newShapeValue)",
              r and r[0]["name"] == "newShapeValue", names(r))
        r = ws("Shape.wid")
        check("6.32 workspace symbols: Type.field — a field of the type", r and r[0]["name"] == "width" and
              r[0]["containerName"] == "Shape", names(r))
        r = ws("Shape.ar")
        check("6.32 workspace symbols: Type.name — a routine whose first parameter is the type", r and
              r[0]["name"] == "area", names(r))
        r = ws("Kind.kr")
        check("6.32 workspace symbols: Type.value — an enum's value", r and r[0]["name"] == "kRound" and
              r[0]["containerName"] == "Kind", names(r))
        r = ws("join")
        at_own = next((i for i, x in enumerate(r) if x["name"] == "joinAll"), None)
        at_dep = next((i for i, x in enumerate(r) if x["name"] == "join" and x.get("containerName") == "strutils"),
                      None)
        check("6.32 workspace symbols: a dependency's exported names for a longer query, after the project's own",
              at_own is not None and at_dep is not None and at_own < at_dep, names(r))
        r = ws("jo")
        check("6.32 workspace symbols: a short query — the project's names only",
              any(x["name"] == "joinAll" for x in r) and not any(x.get("containerName") == "strutils" for x in r),
              names(r))
        r = ws("oldWay")
        check("6.32 workspace symbols: a deprecated name tagged so", r and r[0]["name"] == "oldWay" and
              r[0].get("tags") == [1], r[:1])
        # kept up to date: an edit of an open document, a file created and deleted on disk
        c.notify("textDocument/didChange", {"textDocument": {"uri": uri(main_p), "version": 2}, "contentChanges": [
            {"range": {"start": {"line": 4, "character": 0}, "end": {"line": 4, "character": 0}},
             "text": "proc brandNewThing*() = discard\n"}]})
        main_text = MAIN632 + "proc brandNewThing*() = discard\n"
        r = ws("brandNew")
        check("6.32 workspace symbols: a name just typed into an open document (on its last, empty line)",
              r and r[0]["name"] == "brandNewThing" and r[0]["location"]["uri"] == uri(main_p) and
              r[0]["location"]["range"]["start"]["line"] == 4, names(r))
        # (the line taken out again, up to the end of the text: the text is the client's, line ends and all)
        c.notify("textDocument/didChange", {"textDocument": {"uri": uri(main_p), "version": 2}, "contentChanges": [
            {"range": {"start": {"line": 4, "character": 0}, "end": {"line": 5, "character": 0}}, "text": ""}]})
        r = (c.request("textDocument/formatting", {"textDocument": {"uri": uri(main_p)},
                                                   "options": {"tabSize": 2, "insertSpaces": True}}) or {}).get("result")
        check("6.32 sync: a line deleted up to the end of the text", r == [] and not any(
            x["name"] == "brandNewThing" for x in ws("brandNew")), r)
        c.notify("textDocument/didChange", {"textDocument": {"uri": uri(main_p), "version": 2}, "contentChanges": [
            {"range": {"start": {"line": 4, "character": 0}, "end": {"line": 4, "character": 0}},
             "text": "proc brandNewThing*() = discard\n"}]})
        fresh_p = os.path.join(src, "fresh.nim")
        with open(fresh_p, "w") as f:
            f.write("proc freshlyMade*() = discard\n")
        c.notify("workspace/didChangeWatchedFiles", {"changes": [{"uri": uri(fresh_p), "type": 1}]})
        r = ws("freshlyMade")
        check("6.32 workspace symbols: a file created on disk", r and r[0]["location"]["uri"] == uri(fresh_p), names(r))
        os.remove(fresh_p)
        c.notify("workspace/didChangeWatchedFiles", {"changes": [{"uri": uri(fresh_p), "type": 3}]})
        r = ws("freshlyMade")
        check("6.32 workspace symbols: … and gone when it is deleted", not any(x["name"] == "freshlyMade" for x in r),
              names(r))

        # ── semantic tokens: deltas ──
        def full():
            return (c.request("textDocument/semanticTokens/full", {"textDocument": {"uri": uri(main_p)}}) or {}).get(
                "result") or {}

        def delta(prev):
            return (c.request("textDocument/semanticTokens/full/delta", {"textDocument": {"uri": uri(main_p)},
                                                                         "previousResultId": prev}) or {}).get(
                "result") or {}
        t1 = full()
        check("6.32 semantic tokens: a whole answer has a result id", t1.get("resultId") and len(t1.get("data", [])) > 0,
              t1)
        d0 = delta(t1.get("resultId"))
        check("6.32 semantic tokens: nothing changed — a delta without edits", d0.get("edits") == [] and
              d0.get("resultId") not in (None, t1.get("resultId")), d0)
        c.notify("textDocument/didChange", {"textDocument": {"uri": uri(main_p), "version": 3}, "contentChanges": [
            {"range": {"start": {"line": 1, "character": 0}, "end": {"line": 1, "character": 0}},
             "text": "let extra = area(newShapeValue(3, 4))\n"}]})
        main_text = main_text.replace("\n\n", "\nlet extra = area(newShapeValue(3, 4))\n\n", 1)
        d1 = delta(d0.get("resultId"))
        t2 = full()
        edits = d1.get("edits")
        ok = isinstance(edits, list) and len(edits) >= 1 and tokens_after(t1["data"], edits) == t2.get("data")
        check("6.32 semantic tokens: an edit — the delta's edits make the new tokens", ok, (d1, t2.get("data")))
        check("6.32 semantic tokens: … and the delta is smaller than the whole",
              ok and sum(len(e.get("data") or []) for e in edits) < len(t2["data"]), d1)
        d2 = delta("no-such-id")
        check("6.32 semantic tokens: a delta from an answer nedls no longer has — the whole tokens",
              d2.get("data") == t2.get("data") and d2.get("resultId"), d2)
        r = (c.request("textDocument/semanticTokens/range", {"textDocument": {"uri": uri(main_p)}, "range": {
            "start": {"line": 1, "character": 0}, "end": {"line": 2, "character": 0}}}) or {}).get("result") or {}
        check("6.32 semantic tokens: a range still", len(r.get("data", [])) > 0 and len(r["data"]) % 5 == 0 and
              r["data"][0] == 1, r)

        # ── the workspace's problems ──
        def ws_diag(prev, timeout=30):
            ids = [{"uri": u, "value": v} for u, v in prev.items()]
            return c.request("workspace/diagnostic", {"previousResultIds": ids}, timeout=timeout)

        def remember(prev, res):
            for it in (res or {}).get("result", {}).get("items", []):
                prev[it["uri"]] = it["resultId"]
        prev = {}
        t0 = time.time()
        a = ws_diag(prev, timeout=10)
        check("6.32 workspace/diagnostic: the first is answered at once", a and "items" in a.get("result", {}) and
              time.time() - t0 < 8, a)
        remember(prev, a)
        found = None
        end = time.time() + 60
        while time.time() < end and not found:
            a = ws_diag(prev, timeout=max(1, end - time.time()))
            remember(prev, a)
            for it in (a or {}).get("result", {}).get("items", []):
                if it["uri"] == uri(lint_p) and it["kind"] == "full" and any(
                        d.get("code") == "unused-import" for d in it["items"]):
                    found = it
        check("6.32 workspace/diagnostic: a file not open — ned's checks of it (an unused import)", found, a)
        check("6.32 workspace/diagnostic: … not also sent (publishDiagnostics)", not c.diagnostics(uri(lint_p)),
              c.diagnostics(uri(lint_p)))
        # held while nothing changes (once the checks of the edits above are in); answered when something does —
        # the others "unchanged"
        mid = None
        for _ in range(12):
            m = c.send_request("workspace/diagnostic", {"previousResultIds": [{"uri": u, "value": v}
                                                                              for u, v in prev.items()]})
            a = c.wait(m, timeout=4)
            if a is None:
                mid = m
                break
            remember(prev, a)
        check("6.32 workspace/diagnostic: held while nothing changes", mid is not None, a)
        c.notify("textDocument/didChange", {"textDocument": {"uri": uri(main_p), "version": 4}, "contentChanges": [
            {"range": {"start": {"line": 1, "character": 0}, "end": {"line": 1, "character": 0}},
             "text": "echo aera(newShapeValue(1, 1))\n"}]})
        a = c.wait(mid, timeout=40)
        items = {it["uri"]: it for it in (a or {}).get("result", {}).get("items", [])}
        check("6.32 workspace/diagnostic: answered when an open document's problems change",
              (items.get(uri(main_p)) or {}).get("kind") == "full", a)
        check("6.32 workspace/diagnostic: … the others unchanged", (items.get(uri(lint_p)) or {}).get("kind") ==
              "unchanged", items.get(uri(lint_p)))
        remember(prev, a)
        typo = None
        end = time.time() + 40
        while time.time() < end and not typo:
            if any("aera" in d["message"] for d in (items.get(uri(main_p)) or {}).get("items", [])):
                typo = items[uri(main_p)]
                break
            a = ws_diag(prev, timeout=max(1, end - time.time()))
            remember(prev, a)
            items = {it["uri"]: it for it in (a or {}).get("result", {}).get("items", [])}
        check("6.32 workspace/diagnostic: … with the misspelled name typed", typo, a)
        # the file fixed on disk: told so
        with open(lint_p, "w") as f:
            f.write(LINTME632.replace("import std/strutils\n", ""))
        c.notify("workspace/didChangeWatchedFiles", {"changes": [{"uri": uri(lint_p), "type": 2}]})
        fixed = None
        end = time.time() + 40
        while time.time() < end and not fixed:
            a = ws_diag(prev, timeout=max(1, end - time.time()))
            remember(prev, a)
            for it in (a or {}).get("result", {}).get("items", []):
                if it["uri"] == uri(lint_p) and it["kind"] == "full" and not any(
                        d.get("code") == "unused-import" for d in it["items"]):
                    fixed = it
        check("6.32 workspace/diagnostic: a file mended on disk — its problem gone", fixed, a)
        # a held one cancelled: answered as cancelled
        mid = c.send_request("workspace/diagnostic", {"previousResultIds": [{"uri": u, "value": v}
                                                                            for u, v in prev.items()]})
        time.sleep(0.5)
        c.notify("$/cancelRequest", {"id": mid})
        a = c.wait(mid, timeout=10)
        check("6.32 workspace/diagnostic: a held request cancelled → RequestCancelled",
              a and a.get("error", {}).get("code") == -32800, a)
        # and one held at shutdown: answered before it
        mid = c.send_request("workspace/diagnostic", {"previousResultIds": [{"uri": u, "value": v}
                                                                            for u, v in prev.items()]})
        time.sleep(0.5)
        s = c.request("shutdown", None)
        a = c.wait(mid, timeout=5)
        check("6.32 workspace/diagnostic: one held at shutdown is answered", a and "result" in a and s, (a, s))
    finally:
        c.request("shutdown", None, timeout=5)
        c.notify("exit", {})
        c.close()
        shutil.rmtree(root, ignore_errors=True)

    # a client that does not pull: the problems of a file not open come as before, pushed — none of the workspace's
    # checks run for it
    root = tempfile.mkdtemp(prefix="tnedls-632p-")
    try:
        with open(os.path.join(root, "a.nim"), "w") as f:
            f.write("proc greet(name: string): string = name\necho gret(\"x\")\n")
        c, init = new_client(nedls, root, log=log)
        caps = init["result"]["capabilities"]
        check("6.32 a client that does not pull: no diagnosticProvider, deltas still offered",
              "diagnosticProvider" not in caps and (caps.get("semanticTokensProvider") or {}).get("full") ==
              {"delta": True}, caps.get("diagnosticProvider"))
        a_p = os.path.join(root, "a.nim")
        open_doc(c, a_p, "proc greet(name: string): string = name\necho gret(\"x\")\n")
        ds = c.wait_diagnostics(uri(a_p), lambda ds: any("gret" in d["message"] for d in ds), timeout=20)
        check("6.32 a client that does not pull: its problems pushed", ds and any("gret" in d["message"] for d in ds), ds)
    finally:
        c.request("shutdown", None, timeout=5)
        c.notify("exit", {})
        c.close()
        shutil.rmtree(root, ignore_errors=True)


# ── Nim 3 (when nimony is installed): contracts and passive procs, as nimony would say ──

N3_APP = """import std/syncio

proc needsPositive(x: int) {.requires: x > 0.} =
  echo x

proc between(a, b: int) {.requires: a < b and b <= 100.} =
  echo a

proc handle(c: var int) {.passive.} =
  inc c

proc take(c: sink int) {.passive.} =
  echo c

needsPositive(5)
needsPositive(0)
between(1, 2)
between(b = 1, a = 3)
between(1, 200)
var c = 1
var n = 2
needsPositive(n)
discard delay(handle(c))
discard delay(take(c))

const Zero = 0
let one = 1
needsPositive(Zero)
needsPositive(one)
for i in 0 ..< 3:
  needsPositive(i)
for j in 1 .. 3:
  needsPositive(j)

proc half(x: int): int {.ensures: result >= 0.} =
  if x < 0:
    return -1
  result = x div 2
"""


def run_nim3(nedls, log):
    nimony = shutil.which("nimony")
    if not nimony:
        print("SKIP  6.27 Nim 3: nimony is not on PATH")
        return
    root = tempfile.mkdtemp(prefix="tnedls-n3-")
    # (ned's settings, read by nedls: a config folder of the test's own that makes it Nim 3)
    cfg = os.path.join(root, ".cfg")
    os.makedirs(os.path.join(cfg, "ned"))
    with open(os.path.join(cfg, "ned", "config.json"), "w") as f:
        f.write('{"nim.compiler": "nimony"}\n')
    path = os.path.join(root, "app.nim")
    with open(path, "w") as f:
        f.write(N3_APP)
    c, _ = new_client(nedls, root, log=log, opts={"nedSettings": True},
                      env=dict(os.environ, XDG_CONFIG_HOME=cfg))
    try:
        open_doc(c, path, N3_APP)
        ds = c.wait_diagnostics(uri(path), lambda ds: sum("contract" in d["message"] for d in ds) >= 6 and
                                any("delay" in d["message"] for d in ds), timeout=60) or []
        mine = sorted((d["range"]["start"]["line"], d["message"]) for d in ds
                      if "contract" in d["message"] or "delay" in d["message"])
        lines = N3_APP.split("\n")
        want = {lines.index("needsPositive(0)"), lines.index("between(b = 1, a = 3)"), lines.index("between(1, 200)"),
                lines.index("discard delay(handle(c))")}
        check("6.27 Nim 3: contract violated (literal arguments, named ones), delay of a passive proc with a var",
              want <= {l for l, _ in mine} and any("requires x > 0 (x = 0)" in m for _, m in mine) and
              any("`c: var int`" in m and "sink" in m for _, m in mine), mine)
        more = {lines.index("needsPositive(Zero)"), lines.index("  needsPositive(i)"), lines.index("    return -1")}
        check("6.28 Nim 3: contracts — a constant's value, a loop's first value, an ensures a return breaks",
              {l for l, _ in mine} == want | more and any("Zero = 0" in m for _, m in mine) and
              any("when i = 0 (the loop's first value)" in m for _, m in mine) and
              any("half ensures result >= 0 (result = -1)" in m for _, m in mine), mine)
    finally:
        c.request("shutdown", None)
        c.notify("exit", {})
        c.close()
        shutil.rmtree(root, ignore_errors=True)


# ── stress: random incremental edits must keep the server's text the client's ──

STRESS_WORDS = ["proc ", "let ", "x", "y", " = ", "1", "(", ")", "\n", "  ", "é", "🎉", "ü", "\"", "#", ".", ", ",
                "Shape", "area", "sq", ":", "\n  ", "result", "echo ", "[", "]", "ñandú", "𝒜"]


# ── code actions: the editor's refactorings, source actions, commands, Fix with AI ──

ACT = '''type
  Point* = object
    x*, y*: int
    tag*: string

  Mood = enum
    happy, sad, angry

proc feel(m: Mood): string =
  case m
  of happy: "yay"

proc double(x: int): int = x * 2

let total = double(3) + double(4)
let msg = "total: " & $total
let p = Point(x: 1)
echo msg, p, feel(happy)
'''

IMPS = '''import std/strutils
import std/os

echo "a".toUpperAscii, getCurrentDir()
'''

AISTUCK = '''proc f(): int =
  let y = 1
  y = 2
  y

echo f()
'''

AIFIX = '''proc total(xs: seq[int]): int =
  let sum = 0
  for x in xs:
    sum += x
  sum

echo total(@[1, 2])
'''


def free_port():
    import socket
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def code_actions(c, path, rng, only=None):
    ctx = {"diagnostics": []}
    if only is not None:
        ctx["only"] = only
    r = c.request("textDocument/codeAction", {"textDocument": {"uri": uri(path)}, "range": rng, "context": ctx},
                  timeout=60)
    return (r or {}).get("result") or []


def edits_of(ed, path):
    if not ed:
        return []
    if "documentChanges" in ed:
        return [e for dc in ed["documentChanges"] if dc["textDocument"]["uri"] == uri(path) for e in dc["edits"]]
    return (ed.get("changes") or {}).get(uri(path), [])


def after_action(c, text, path, act):
    """the text once the action's edit is applied (resolved first when it was listed without one)"""
    if act is None:
        return None
    if "edit" not in act:
        r = c.request("codeAction/resolve", act, timeout=60)
        act = (r or {}).get("result") or {}
    es = edits_of(act.get("edit"), path)
    return apply_edits(text, es) if es else None


def at(text, needle, after=0, length=0):
    p = pos_of(text, needle, after=after)
    e = dict(p)
    e["character"] += length
    return {"start": p, "end": e}


def named(acts, title):
    for a in acts:
        if a["title"] == title:
            return a
    return None


def run_actions(nedls, have_nim, log):
    root = tempfile.mkdtemp(prefix="tnedls-act-")
    mock = None
    try:
        src = os.path.join(root, "src")
        os.makedirs(src)
        files = {"act.nim": ACT, "imps.nim": IMPS, "hints.nim": HINTS, "aifix.nim": AIFIX, "aistuck.nim": AISTUCK}
        for name, text in files.items():
            with open(os.path.join(src, name), "w") as f:
                f.write(text)
        with open(os.path.join(root, "act.nimble"), "w") as f:
            f.write('version = "0.1.0"\nauthor = "t"\ndescription = "t"\nlicense = "MIT"\nsrcDir = "src"\n')
        os.makedirs(os.path.join(root, ".git"))           # (the project's top: .ned/lint.json goes here)
        act_p, imps_p, hints_p, ai_p = [os.path.join(src, n) for n in ("act.nim", "imps.nim", "hints.nim", "aifix.nim")]
        # a model to ask (the UI tests' mock of the OpenAI API) in ned's own settings, which nedls reads
        port = free_port()
        mock_log = os.path.join(root, "mock.log")
        here = os.path.dirname(os.path.abspath(__file__))
        mock = subprocess.Popen([sys.executable, "-I", os.path.join(here, "..", "ui", "mocks", "mockai.py"), str(port)],
                                env=dict(os.environ, NED_TEST_MOCK_LOG=mock_log), stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL)
        cfg = os.path.join(root, "cfg")
        os.makedirs(os.path.join(cfg, "ned"))
        with open(os.path.join(cfg, "ned", "config.json"), "w") as f:
            json.dump({"ai.provider": "openai", "ai.baseUrl": "http://127.0.0.1:%d/v1" % port, "ai.apiKey": "sk-test",
                       "ai.model": "gpt-6", "security.folderTrust": "off"}, f)
        env = dict(os.environ, XDG_CONFIG_HOME=cfg, XDG_STATE_HOME=os.path.join(root, "state"),
                   XDG_CACHE_HOME=os.path.join(root, "cache"))
        more = {"textDocument": {"codeAction": {"resolveSupport": {"properties": ["edit"]},
                                                "codeActionLiteralSupport": {"codeActionKind": {"valueSet": [
                                                    "", "quickfix", "refactor", "source"]}}}},
                "workspace": {"applyEdit": True, "workspaceEdit": {"documentChanges": True},
                              "executeCommand": {}},
                "window": {"workDoneProgress": True, "showMessage": {}}}
        c, init = new_client(nedls, root, log=log, opts={"nedSettings": True}, env=env, more_caps=more)
        caps = (init or {}).get("result", {}).get("capabilities", {})
        cap = caps.get("codeActionProvider") or {}
        check("actions: resolveProvider, the kinds, the commands",
              isinstance(cap, dict) and cap.get("resolveProvider") is True and "refactor.rewrite" in cap.get(
                  "codeActionKinds", []) and "source.organizeImports" in cap.get("codeActionKinds", []) and
              "nedls.aiFix" in (caps.get("executeCommandProvider") or {}).get("commands", []), caps)
        open_doc(c, act_p, ACT)
        # an object type: generate (worked out when chosen: the client resolves it)
        acts = code_actions(c, act_p, at(ACT, "Point* = object", after=1))
        g = named(acts, "Generate `$`")
        check("refactor: Generate `$` on an object type, listed without its edit (resolved later)",
              g and g.get("kind") == "refactor.rewrite" and "edit" not in g and "data" in g, [a["title"] for a in acts])
        t = after_action(c, ACT, act_p, g)
        check("codeAction/resolve: Generate `$` → a `$` for Point", t and "proc `$`" in t and "Point" in t, t)
        acts = code_actions(c, act_p, at(ACT, "Point* = object", after=1), only=["quickfix"])
        check("only: [quickfix] → no refactorings", not any(a["kind"].startswith("refactor") for a in acts),
              [a["title"] for a in acts])
        acts = code_actions(c, act_p, at(ACT, "Point* = object", after=1), only=["refactor.rewrite"])
        check("only: [refactor.rewrite] → the generators", named(acts, "Generate hash") is not None,
              [a["title"] for a in acts])
        # a case without every value
        t = after_action(c, ACT, act_p, named(code_actions(c, act_p, at(ACT, "case m", after=2)),
                                              "Add the missing case branches"))
        check("refactor: Add the missing case branches", t and "of sad" in t and "of angry" in t, t)
        # a constructor without every field
        t = after_action(c, ACT, act_p, named(code_actions(c, act_p, at(ACT, "Point(x: 1)", after=7)),
                                              "Fill in the missing fields"))
        check("refactor: Fill in the missing fields", t and "Point(x: 1, y:" in t and "tag:" in t, t)
        # a selection into a variable: the name it would propose, no question asked
        acts = code_actions(c, act_p, at(ACT, "double(3)", length=9))
        x = named(acts, "Extract into a variable")
        t = after_action(c, ACT, act_p, x)
        check("refactor.extract: the selection into a variable (the proposed name)",
              x and x["kind"] == "refactor.extract" and t and "let doubleResult = double(3)\n" in t and
              "let total = doubleResult + double(4)" in t, (x, t))
        t = after_action(c, ACT, act_p, named(code_actions(c, act_p, at(ACT, '"total: "', after=2)),
                                              "Use fmt for this string"))
        check("refactor: Use fmt for this string", t and 'fmt"total: {total}"' in t, t)
        acts = code_actions(c, act_p, at(ACT, "proc double", after=6))
        x = named(acts, "Inline double")
        t = after_action(c, ACT, act_p, x)
        check("refactor.inline: Inline a one-expression proc into its calls",
              x and x["kind"] == "refactor.inline" and t and "double(3)" not in t, (x and x["kind"], t))
        # 6.23: rewrites learned from other servers — the type written out, f(x) → x.f, the arguments named
        t = after_action(c, ACT, act_p, named(code_actions(c, act_p, at(ACT, "msg = ", after=1)),
                                              "Write the type: string"))
        check("refactor (6.23): Write the type", t and 'let msg: string = "total: "' in t, t)
        x = named(code_actions(c, act_p, at(ACT, "double(4)", after=2)), "Write as 4.double")
        t = after_action(c, ACT, act_p, x)
        check("refactor (6.23): f(x) → x.f", t and "double(3) + 4.double" in t, t)
        x = named(code_actions(c, act_p, at(ACT, "Point(x: 1)", after=9)), "Write 1 as 0x1")
        check("refactor (6.23): an integer literal in another base", x is not None,
              [a["title"] for a in code_actions(c, act_p, at(ACT, "Point(x: 1)", after=9))])
        check("refactor: nothing that runs or asks (Run the selection, Change signature …)",
              not any(a["title"].startswith(("Run the", "Change signature", "Move ", "Evaluate", "Debug"))
                      for a in acts + code_actions(c, act_p, at(ACT, "double(3)", length=9))),
              [a["title"] for a in acts])
        # source: organize imports
        open_doc(c, imps_p, IMPS)
        acts = code_actions(c, imps_p, at(IMPS, "import std/os", after=2), only=["source.organizeImports"])
        o = named(acts, "Organize imports")
        t = after_action(c, IMPS, imps_p, o)
        check("source.organizeImports: the imports sorted into one", o and o["kind"] == "source.organizeImports" and
              t and t.startswith("import std/[os, strutils]\n"), t)
        check("no `only` on an import line: Organize imports is there too",
              named(code_actions(c, imps_p, at(IMPS, "import std/os", after=2)), "Organize imports") is not None)
        check("… and not on other lines", named(code_actions(c, imps_p, at(IMPS, "echo", after=1)),
                                                "Organize imports") is None)
        # source.fixAll, and a rule turned off for the project (a command nedls carries out)
        open_doc(c, hints_p, HINTS)
        ds = c.wait_diagnostics(uri(hints_p), lambda ds: any("is never changed" in d["message"] for d in ds),
                                timeout=60)
        hv = [d for d in ds or [] if "'limit' is never changed" in d["message"]]
        acts = code_actions(c, hints_p, at(HINTS, "echo total", after=1), only=["source.fixAll"])
        fa = [a for a in acts if a["kind"] == "source.fixAll"]
        t = after_action(c, HINTS, hints_p, fa[0] if fa else None)
        check("source.fixAll: every problem ned can fix in the file", t and "let limit = 10" in t,
              ([a["title"] for a in acts], t))
        if hv:
            acts = code_actions(c, hints_p, hv[0]["range"])
            off = named(acts, "Turn off var-let for this project")
            cmd = (off or {}).get("command") or {}
            check("quick fix: turn the rule off — a command nedls runs (it writes .ned/lint.json)",
                  cmd.get("command") == "nedls.lintRuleOff", off)
            if cmd:
                r = c.request("workspace/executeCommand", {"command": cmd["command"], "arguments": cmd["arguments"]})
                lj = os.path.join(root, ".ned", "lint.json")
                ok = r is not None and "error" not in r and os.path.exists(lj) and \
                    json.load(open(lj)).get("rules", {}).get("var-let") == "off"
                check("workspace/executeCommand nedls.lintRuleOff → .ned/lint.json says var-let: off", ok, r)
                ds = c.wait_diagnostics(uri(hints_p), lambda ds: not any("is never changed" in d["message"]
                                                                        for d in ds), timeout=30)
                check("… and the hint is gone from the problems", ds is not None and
                      not any("is never changed" in d["message"] for d in ds), ds)
        else:
            check("engine hint for source.fixAll and the rule", False, ds)
        r = c.request("workspace/executeCommand", {"command": "nedls.nothing", "arguments": []})
        check("an unknown command → an error", r and "error" in r, r)
        # Fix with AI: the model's first answer does not compile — nim check says so, the model is asked again
        # with the error, and only the answer that compiles is sent to the client to apply
        if have_nim:
            open_doc(c, ai_p, AIFIX)
            c.notify("textDocument/didSave", {"textDocument": {"uri": uri(ai_p)}})
            ds = c.wait_diagnostics(uri(ai_p), lambda ds: any(d["severity"] == 1 for d in ds), timeout=90)
            err = [d for d in ds or [] if d["severity"] == 1]
            acts = code_actions(c, ai_p, err[0]["range"]) if err else []
            ai = named(acts, "Fix with AI (checked with nim check)")
            cmd = (ai or {}).get("command") or {}
            check("quick fix: Fix with AI, a command (a model is set up)", cmd.get("command") == "nedls.aiFix",
                  [a["title"] for a in acts])
            if cmd:
                n0 = len(c.server_requests)
                r = c.request("workspace/executeCommand", {"command": cmd["command"], "arguments": cmd["arguments"]})
                check("nedls.aiFix answers at once (the work goes on)", r is not None and "error" not in r, r)
                end = time.time() + 120
                edit = None
                while time.time() < end and edit is None:
                    for m in c.server_requests[n0:]:
                        if m["method"] == "workspace/applyEdit":
                            edit = m["params"]["edit"]
                    time.sleep(0.2)
                t = apply_edits(AIFIX, edits_of(edit, ai_p)) if edit else None
                check("Fix with AI: the edit sent is the answer that compiles (the second)",
                      t and "var sum = 0" in t and "sum += x +" not in t, (edit, t))
                asks = []
                try:
                    for ln in open(mock_log):
                        b = json.loads(ln).get("body") or {}
                        txt = json.dumps(b)
                        if "Fix this compiler error" in txt:
                            asks.append(txt)
                except OSError:
                    pass
                check("… the model was asked twice, the second time with nim check's error",
                      len(asks) == 2 and "Your previous answer was" in asks[1] and "still reports" in asks[1],
                      len(asks))
                prog = [m for m in c.server_requests[n0:] if m["method"] == "window/workDoneProgress/create"]
                check("… with progress in the client", prog, [m["method"] for m in c.server_requests[n0:]])
                time.sleep(0.5)
                msgs = [m["params"]["message"] for m in c.notes if m.get("method") == "window/showMessage"]
                check("… and a message that it was applied", any("nim check passes" in m for m in msgs), msgs[-3:])
            # answers that never compile: after the second, the user is asked — "Apply anyway" applies it
            stuck_p = os.path.join(src, "aistuck.nim")
            open_doc(c, stuck_p, AISTUCK)
            c.notify("textDocument/didSave", {"textDocument": {"uri": uri(stuck_p)}})
            ds = c.wait_diagnostics(uri(stuck_p), lambda ds: any(d["severity"] == 1 for d in ds), timeout=90)
            err = [d for d in ds or [] if d["severity"] == 1]
            ai = named(code_actions(c, stuck_p, err[0]["range"]), "Fix with AI (checked with nim check)") if err else None
            if ai:
                c.button = "Apply anyway"
                n0 = len(c.server_requests)
                c.request("workspace/executeCommand", ai["command"])
                end = time.time() + 120
                got = []
                while time.time() < end and "workspace/applyEdit" not in got:
                    got = [m["method"] for m in c.server_requests[n0:]]
                    time.sleep(0.2)
                asked = [m for m in c.server_requests[n0:] if m["method"] == "window/showMessageRequest"]
                check("Fix with AI that never compiles: the user is asked (Apply anyway / Leave it), then it is applied",
                      asked and "still does not compile" in asked[0]["params"]["message"] and
                      "workspace/applyEdit" in got and got.index("window/showMessageRequest") <
                      got.index("workspace/applyEdit"), got)
                c.button = None
            else:
                check("Fix with AI offered on a second error", False, ds)
        else:
            print("SKIP  Fix with AI (no nim on PATH)")
        c.request("shutdown", None)
        c.notify("exit", {})
        c.close()
        # a client that cannot resolve: the edit comes with the action
        c, init = new_client(nedls, root, log=log, env=env)
        open_doc(c, act_p, ACT)
        acts = code_actions(c, act_p, at(ACT, "Point* = object", after=1))
        g = named(acts, "Generate `$`")
        check("a client without resolve: the refactoring's edit is in the list", g and "edit" in g,
              [a["title"] for a in acts])
        check("… and no Fix with AI where edits cannot be sent (no workspace/applyEdit)",
              not any("AI" in a["title"] for a in acts))
        c.request("shutdown", None)
        c.notify("exit", {})
        c.close()
    finally:
        if mock:
            mock.kill()
        shutil.rmtree(root, ignore_errors=True)


def random_edit(rnd, text):
    lines = text.split("\n")
    l0 = rnd.randrange(len(lines))
    c0 = rnd.randrange(len(lines[l0]) + 1)
    if rnd.random() < 0.4:
        l1 = min(len(lines) - 1, l0 + rnd.choice([0, 0, 0, 1, 2]))
        c1 = rnd.randrange(len(lines[l1]) + 1) if l1 != l0 else min(len(lines[l0]), c0 + rnd.randrange(6))
    else:
        l1, c1 = l0, c0
    ins = "".join(rnd.choice(STRESS_WORDS) for _ in range(rnd.randrange(0, 5)))
    a = sum(len(x) + 1 for x in lines[:l0]) + c0
    b = sum(len(x) + 1 for x in lines[:l1]) + c1
    if b < a:
        a, b = b, a
        l0, c0, l1, c1 = l1, c1, l0, c0
    new = text[:a] + ins + text[b:]
    rng = {"start": {"line": l0, "character": u16col(lines[l0], c0)},
           "end": {"line": l1, "character": u16col(lines[l1], c1)}}
    return new, {"range": rng, "text": ins}


def run_stress(nedls, root, n, log):
    rnd = random.Random(20261017)
    c, _ = new_client(nedls, root, log=log)
    src = os.path.join(root, "src")
    shapes_p = os.path.join(src, "shapes.nim")
    p = os.path.join(src, "stress.nim")
    open_doc(c, shapes_p, SHAPES)
    text = APP
    open_doc(c, p, text)
    errors = 0
    version = 1
    t0 = time.time()
    tok = (c.request("textDocument/semanticTokens/full", {"textDocument": {"uri": uri(p)}}, timeout=60) or {}).get(
        "result") or {}
    tok_id, tok_data, tok_bad = tok.get("resultId"), tok.get("data") or [], []
    reqs = ["textDocument/completion", "textDocument/hover", "textDocument/semanticTokens/full",
            "textDocument/documentSymbol", "textDocument/foldingRange", "textDocument/inlayHint",
            "textDocument/signatureHelp", "textDocument/documentHighlight", "textDocument/definition"]
    for i in range(n):
        text, change = random_edit(rnd, text)
        version += 1
        changes = [change]
        if rnd.random() < 0.1:                       # (several changes in one notification)
            text, ch2 = random_edit(rnd, text)
            changes.append(ch2)
        c.notify("textDocument/didChange", {"textDocument": {"uri": uri(p), "version": version},
                                            "contentChanges": changes})
        if i % 20 == 0:
            lines = text.split("\n")
            ln = rnd.randrange(len(lines))
            pos = {"line": ln, "character": u16col(lines[ln], rnd.randrange(len(lines[ln]) + 1))}
            m = rnd.choice(reqs)
            params = {"textDocument": {"uri": uri(p)}, "position": pos}
            if m == "textDocument/inlayHint":
                params = {"textDocument": {"uri": uri(p)}, "range": {"start": {"line": 0, "character": 0},
                                                                    "end": {"line": len(lines), "character": 0}}}
            r = c.request(m, params, timeout=60)
            if r is None or "error" in r:
                errors += 1
                if errors < 5:
                    print("      ", m, "→", r)
        if i % 20 == 10:
            # (the colours as a delta of the last answer: the edits applied to it must give the whole tokens)
            r = (c.request("textDocument/semanticTokens/full/delta", {"textDocument": {"uri": uri(p)},
                                                                      "previousResultId": tok_id}, timeout=60) or {}).get(
                "result") or {}
            tok_data = tokens_after(tok_data, r["edits"]) if "edits" in r else r.get("data") or []
            tok_id = r.get("resultId")
            if i % 100 == 10:
                full = (c.request("textDocument/semanticTokens/full", {"textDocument": {"uri": uri(p)}},
                                  timeout=60) or {}).get("result") or {}
                if full.get("data") != tok_data:
                    tok_bad.append(i)
                tok_id, tok_data = full.get("resultId"), full.get("data") or []
        if c.p.poll() is not None:
            break
    alive = c.p.poll() is None
    check("stress: %d random incremental edits (UTF-16, multi-line, several per message) — no crash" % n, alive,
          c.p.returncode)
    check("stress: every request answered without an error", errors == 0, errors)
    check("stress: semantic token deltas follow the edits (applied, they are the whole tokens)", not tok_bad, tok_bad)
    # the server's text is the client's: the same answers as for the text opened afresh
    p2 = os.path.join(src, "stress2.nim")
    open_doc(c, p2, text)
    same = True
    for m in ["textDocument/documentSymbol", "textDocument/foldingRange", "textDocument/semanticTokens/full",
              "textDocument/formatting"]:
        params = {"textDocument": {"uri": uri(p)}}
        if m == "textDocument/formatting":
            params["options"] = {"tabSize": 2, "insertSpaces": True}
        a = c.request(m, params, timeout=60)
        params["textDocument"]["uri"] = uri(p2)
        b = c.request(m, params, timeout=60)
        for x in (a, b):              # (each whole answer has an id of its own, for the deltas after it)
            if isinstance((x or {}).get("result"), dict):
                x["result"].pop("resultId", None)
        ra = json.dumps((a or {}).get("result"), sort_keys=True).replace(uri(p), "U")
        rb = json.dumps((b or {}).get("result"), sort_keys=True).replace(uri(p2), "U")
        if ra != rb or a is None:
            same = False
            print("      differs:", m, ra[:200], "|", rb[:200])
    check("stress: no desync (symbols, folding, colours and formatting equal a fresh open)", same)
    # one more check: the server's text through a whole-document edit from formatting a known-good text
    c.notify("textDocument/didChange", {"textDocument": {"uri": uri(p), "version": version + 1},
                                        "contentChanges": [{"text": FMT}]})
    r = c.request("textDocument/formatting", {"textDocument": {"uri": uri(p)}, "options": {"tabSize": 2,
                                                                                         "insertSpaces": True}})
    check("stress: full-text change after the edits", "proc f(a: int)" in apply_edits(FMT, (r or {}).get("result") or []))
    print("      (%.1f s, %.1f edits/s)" % (time.time() - t0, n / max(0.001, time.time() - t0)))
    c.request("shutdown", None)
    c.notify("exit", {})
    check("stress: exit code 0", c.close() == 0)


# ── bench: a big file ──


def rss_mb(pid):
    try:
        for l in open("/proc/%d/status" % pid):
            if l.startswith("VmRSS:"):
                return int(l.split()[1]) / 1024.0
    except OSError:
        pass
    return 0.0


def run_bench(nedls, path, log):
    path = os.path.abspath(path)
    root = os.path.dirname(path)
    c, _ = new_client(nedls, root, log=log, opts={"nedSettings": False})
    print("rss after initialize: %.1f MB" % rss_mb(c.p.pid))
    text = open(path, encoding="utf-8", errors="replace").read()
    t = time.time()
    open_doc(c, path, text)
    lines = text.split("\n")

    def timed(m, params, label=None):
        t = time.time()
        r = c.request(m, params, timeout=120)
        ms = (time.time() - t) * 1000
        ok = r is not None and "error" not in r
        return ms, ok, r

    tu = {"textDocument": {"uri": uri(path)}}
    ms, ok, r = timed("textDocument/documentSymbol", tu)
    print("first request (documentSymbol, reads the file): %.1f ms" % ms)
    ms, ok, r = timed("textDocument/hover", dict(tu, position={"line": 0, "character": 0}))
    time.sleep(1.5)                                          # (idle: nedls reads the imports meanwhile)
    print("rss with the file open and its imports read: %.1f MB" % rss_mb(c.p.pid))
    ms, ok, r = timed("textDocument/semanticTokens/full", tu)
    print("semanticTokens/full, first: %.1f ms, %d tokens" %
          (ms, len((r or {}).get("result", {}).get("data", [])) // 5))
    ms, ok, r = timed("textDocument/semanticTokens/full", tu)
    print("semanticTokens/full, again: %.1f ms" % ms)
    print("rss after semantic tokens: %.1f MB" % rss_mb(c.p.pid))
    # completions after dots, hovers on names
    rnd = random.Random(7)
    dots = [(i, k + 1) for i, l in enumerate(lines) for k, ch in enumerate(l)
            if ch == "." and k > 0 and l[k - 1].isalnum() and k + 1 < len(l) and l[k + 1].isalpha()]
    rnd.shuffle(dots)
    times = []
    for (i, k) in dots[:40]:
        ms, ok, r = timed("textDocument/completion", dict(tu, position={"line": i, "character": u16col(lines[i], k)}))
        times.append(ms)
    times.sort()
    if times:
        print("completion after a dot ×%d: median %.1f ms, max %.1f ms  (rss %.1f MB)" %
              (len(times), times[len(times) // 2], times[-1], rss_mb(c.p.pid)))
    names = [(i, k) for i, l in enumerate(lines) for k, ch in enumerate(l)
             if ch.isalpha() and (k == 0 or not (l[k - 1].isalnum() or l[k - 1] == "_"))]
    rnd.shuffle(names)
    for m in ["textDocument/hover", "textDocument/definition", "textDocument/signatureHelp",
              "textDocument/documentHighlight"]:
        times = []
        for (i, k) in names[:40]:
            ms, ok, r = timed(m, dict(tu, position={"line": i, "character": u16col(lines[i], k)}))
            times.append(ms)
        times.sort()
        print("%s ×%d: median %.1f ms, max %.1f ms  (rss %.1f MB)" % (m.split("/")[1], len(times), times[len(times) // 2],
                                                                    times[-1], rss_mb(c.p.pid)))
    ms, ok, r = timed("textDocument/inlayHint", dict(tu, range={"start": {"line": 0, "character": 0},
                                                                "end": {"line": 80, "character": 0}}))
    print("inlayHint (80 lines): %.1f ms, %d hints" % (ms, len((r or {}).get("result") or [])))
    ms, ok, r = timed("textDocument/foldingRange", tu)
    print("foldingRange: %.1f ms" % ms)
    ms, ok, r = timed("textDocument/formatting", dict(tu, options={"tabSize": 2, "insertSpaces": True}))
    print("formatting: %.1f ms, %d edits  (rss %.1f MB)" % (ms, len((r or {}).get("result") or []), rss_mb(c.p.pid)))
    # typing: an edit, then completion
    times = []
    for k in range(20):
        ln = len(lines) - 1
        c.notify("textDocument/didChange", {"textDocument": {"uri": uri(path), "version": 2 + k},
                                            "contentChanges": [{"range": {"start": {"line": ln, "character": 0},
                                                                          "end": {"line": ln, "character": 0}},
                                                                "text": "x"}]})
        ms, ok, r = timed("textDocument/completion", dict(tu, position={"line": ln, "character": 1}))
        times.append(ms)
    times.sort()
    print("edit + completion ×20: median %.1f ms, max %.1f ms" % (times[len(times) // 2], times[-1]))
    print("rss now: %.1f MB" % rss_mb(c.p.pid))
    c.request("shutdown", None)
    c.notify("exit", {})
    c.close()


def main():
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        print(__doc__)
        return 2
    nedls = os.path.abspath(args[0])
    log = open(os.environ.get("NEDLS_TEST_LOG", os.devnull), "ab")
    if "--bench" in args:
        run_bench(nedls, args[args.index("--bench") + 1], log)
        return 0
    edits = 2000
    if "--edits" in args:
        edits = int(args[args.index("--edits") + 1])
    have_nim = shutil.which("nim") is not None
    if "--only" in args:
        # (a part on its own while working on it: --only 632, --only checks langs …)
        only = args[args.index("--only") + 1:]
        suites = {"actions": lambda: run_actions(nedls, have_nim, log), "langs": lambda: run_langs(nedls, log),
                  "c": lambda: run_c_engine(nedls, log), "628": lambda: run_628(nedls, log),
                  "632": lambda: run_632(nedls, log), "nim3": lambda: run_nim3(nedls, log)}
        for name in only:
            if name not in suites:
                print("unknown suite %s (%s)" % (name, ", ".join(suites)))
                return 2
            suites[name]()
        failed = [n for n, ok in RESULTS if not ok]
        print("\n%d checks, %d failed" % (len(RESULTS), len(failed)))
        return 1 if failed else 0
    root = tempfile.mkdtemp(prefix="tnedls-")
    try:
        os.makedirs(os.path.join(root, "src"))
        for name, text in [("shapes.nim", SHAPES), ("app.nim", APP), ("bad.nim", BAD), ("bad2.nim", BAD2),
                           ("fmt.nim", FMT),
                           ("stress.nim", APP), ("stress2.nim", "")]:
            with open(os.path.join(root, "src", name), "w", encoding="utf-8") as f:
                f.write(text)
        with open(os.path.join(root, "proj.nimble"), "w") as f:
            f.write('version = "0.1.0"\nauthor = "t"\ndescription = "t"\nlicense = "MIT"\nsrcDir = "src"\n')
        run_checks(nedls, root, have_nim, log)
        run_actions(nedls, have_nim, log)
        run_langs(nedls, log)
        run_c_engine(nedls, log)
        run_628(nedls, log)
        run_632(nedls, log)
        run_nim3(nedls, log)
        if edits > 0:
            run_stress(nedls, root, edits, log)
    finally:
        if "--keep" in args:
            print("kept", root)
        else:
            shutil.rmtree(root, ignore_errors=True)
    failed = [n for n, ok in RESULTS if not ok]
    print("\n%d checks, %d failed" % (len(RESULTS), len(failed)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
