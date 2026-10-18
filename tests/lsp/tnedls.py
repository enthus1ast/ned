#!/usr/bin/env python3
"""nedls tests: a self-contained LSP client (Python 3, standard library only).

    python3 tests/lsp/tnedls.py ./nedls                 # the checks, then the stress run
    python3 tests/lsp/tnedls.py ./nedls --edits 500      # a shorter stress run
    python3 tests/lsp/tnedls.py ./nedls --bench FILE     # timings and memory on a big file (no checks)

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
        return None
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


def new_client(nedls, root, encodings=None, log=None, opts=None, config=None):
    c = Client([nedls], root, log=log)
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
            "foldingRangeProvider", "codeActionProvider", "documentHighlightProvider", "typeDefinitionProvider"]
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
    else:
        print("SKIP  diagnostics (no nim on PATH)")

    # wrong params for every method: each one answered (a result or an error), the server still there
    methods = ["textDocument/completion", "completionItem/resolve", "textDocument/hover", "textDocument/signatureHelp",
               "textDocument/definition", "textDocument/declaration", "textDocument/typeDefinition",
               "textDocument/references", "textDocument/documentHighlight", "textDocument/prepareRename",
               "textDocument/rename", "textDocument/documentSymbol", "workspace/symbol",
               "textDocument/semanticTokens/full", "textDocument/semanticTokens/range", "textDocument/inlayHint",
               "textDocument/formatting", "textDocument/rangeFormatting", "textDocument/foldingRange",
               "textDocument/codeAction"]
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


# ── stress: random incremental edits must keep the server's text the client's ──

STRESS_WORDS = ["proc ", "let ", "x", "y", " = ", "1", "(", ")", "\n", "  ", "é", "🎉", "ü", "\"", "#", ".", ", ",
                "Shape", "area", "sq", ":", "\n  ", "result", "echo ", "[", "]", "ñandú", "𝒜"]


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
        if c.p.poll() is not None:
            break
    alive = c.p.poll() is None
    check("stress: %d random incremental edits (UTF-16, multi-line, several per message) — no crash" % n, alive,
          c.p.returncode)
    check("stress: every request answered without an error", errors == 0, errors)
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
