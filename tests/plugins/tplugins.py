#!/usr/bin/env python3
"""ned's plugins without the editor: the NimScript host (nim e) with the example plugins and an API test plugin,
this script playing ned (JSON lines: registrations, calls, the API); a language server written in NimScript through
`ned --lsp-bridge`; the host compiled (plugins.native).

  python3 tests/plugins/tplugins.py [./ned] [--native]     (nim on PATH)
"""
import json, os, select, shutil, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
LIB = os.path.join(REPO, "src", "ned", "plugins", "lib")
EX = os.path.join(REPO, "examples", "plugins")
RESULTS = []


def check(name, ok, info=""):
    RESULTS.append((name, bool(ok)))
    print(("PASS  " if ok else "FAIL  ") + name + ("" if ok else "  " + str(info)[:500]), flush=True)


class Host:
    """the plugin host as ned runs it: one process, every plugin imported"""

    def __init__(self, plugins, native=False, tmp=None):
        self.tmp = tmp
        src = "import nedplugin\n"
        for i, (pid, d) in enumerate(plugins):
            src += "import %s as nedPlug%d\n" % (json.dumps(os.path.join(d, "plugin.nims")), i)
        src += "nedRun()\n"
        env = dict(os.environ, NED_PLUGIN_DIRS="\n".join("%s=%s" % p for p in plugins))
        if native:
            f = os.path.join(tmp, "host.nim")
            open(f, "w").write(src)
            exe = os.path.join(tmp, "host")
            r = subprocess.run(["nim", "c", "-d:release", "--hints:off", "--warnings:off", "--path:" + LIB,
                                "--nimcache:" + os.path.join(tmp, "nc"), "-o:" + exe, f], capture_output=True, text=True)
            self.build_ok = r.returncode == 0
            self.build_err = r.stderr[-800:]
            argv = [exe]
        else:
            f = os.path.join(tmp, "host.nims")
            open(f, "w").write(src)
            argv = ["nim", "e", "--hints:off", "--warnings:off", "--path:" + LIB, f]
            self.build_ok = True
        self.t0 = time.time()
        self.p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  env=env, cwd=tmp)
        self.buf = b""
        self.logs = []
        self.regs = []
        self.rid = 0
        self.ready_ms = None
        # ned's side: one buffer
        self.lines = ["abc def", "second line "]
        self.cursor = {"line": 0, "col": 1}
        self.problems = None
        self.decor = []
        self.status = ""
        self.messages = []
        self.answers = {"ask": "Ann", "pick": 1, "confirm": True}

    def send(self, j):
        self.p.stdin.write((json.dumps(j) + "\n").encode())
        self.p.stdin.flush()

    def lines_out(self, timeout):
        end = time.time() + timeout
        while time.time() < end:
            if b"\n" in self.buf:
                line, self.buf = self.buf.split(b"\n", 1)
                yield line.decode(errors="replace")
                continue
            r, _, _ = select.select([self.p.stdout], [], [], max(0, end - time.time()))
            if not r:
                return
            chunk = os.read(self.p.stdout.fileno(), 65536)
            if not chunk:
                return
            self.buf += chunk

    def text(self):
        return "\n".join(self.lines)

    def set_text(self, t):
        self.lines = t.split("\n")

    def replace(self, r, s):
        a, e = r["start"], r["stop"]
        t = self.lines
        before = t[a["line"]][:a["col"]]
        after = t[e["line"]][e["col"]:]
        mid = (before + s + after).split("\n")
        self.lines = t[:a["line"]] + mid + t[e["line"] + 1:]

    def api(self, j):
        fn, a = j["fn"], j.get("args", {})
        v = None
        if fn == "current": v = 1
        elif fn == "root": v = self.tmp
        elif fn == "path": v = os.path.join(self.tmp, "a.txt")
        elif fn == "lang": v = "plaintext"
        elif fn == "lineCount": v = len(self.lines)
        elif fn == "line": v = self.lines[a["line"]]
        elif fn == "text": v = self.text()
        elif fn == "setText": self.set_text(a["text"])
        elif fn == "replace": self.replace(a["range"], a["text"])
        elif fn == "cursor": v = self.cursor
        elif fn == "lineComment": v = "#"
        elif fn == "problems": self.problems = a["problems"]
        elif fn in ("sign", "vtext", "highlight"): self.decor.append((fn, a))
        elif fn == "status": self.status = a["text"]
        elif fn in ("message", "toast"): self.messages.append(a["text"])
        elif fn == "log": self.logs.append(a["text"])
        elif fn in self.answers: v = self.answers[fn]
        elif fn == "setting": v = 120 if a.get("key") == "width" else None
        elif fn == "dataDir": v = os.path.join(self.tmp, "data", j.get("plugin", ""))
        else:
            self.send({"t": "res", "id": j["id"], "err": "no " + fn})
            return
        self.send({"t": "res", "id": j["id"], "value": v})

    def pump(self, until, timeout=30):
        """the host's lines until until(msg) (a protocol message); the API answered on the way"""
        for line in self.lines_out(timeout):
            if not line.startswith("\x1e"):
                self.logs.append(line)
                continue
            j = json.loads(line[1:])
            t = j.get("t")
            if t == "reg": self.regs.append(j)
            elif t == "api": self.api(j)
            elif t == "ready" and self.ready_ms is None: self.ready_ms = int((time.time() - self.t0) * 1000)
            if until(j):
                return j
        return None

    def call(self, cb, args=None, timeout=20):
        self.rid += 1
        rid = self.rid
        self.send({"t": "call", "cb": cb, "rid": rid, "args": args or {}})
        return self.pump(lambda j: j.get("t") == "ret" and j.get("rid") == rid, timeout)

    def reg(self, kind, **kw):
        for r in self.regs:
            if r["kind"] == kind and all(r.get(k) == v for k, v in kw.items()):
                return r
        return None

    def close(self):
        try:
            self.send({"t": "quit"})
            self.p.wait(5)
        except Exception:
            self.p.kill()


def run_host(tmp, native):
    tag = "native: " if native else ""
    plugins = [("zig-lite", os.path.join(EX, "zig-lite")), ("wordinfo-lsp", os.path.join(EX, "wordinfo-lsp")),
               ("commentary", os.path.join(EX, "commentary")), ("apitest", os.path.join(HERE, "fixtures", "apitest"))]
    h = Host(plugins, native=native, tmp=tmp)
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return
    ok = h.pump(lambda j: j.get("t") == "ready", 60)
    err = ""
    if not ok:
        h.p.kill()
        err = h.p.stderr.read()[-1500:]
    check(tag + "the host starts: every plugin registered, then ready (%s ms)" % h.ready_ms, ok, err)
    if not ok:
        return
    owners = {r["plugin"] for r in h.regs}
    check(tag + "each registration names its plugin (the folder's name)",
          owners == {"zig-lite", "wordinfo-lsp", "commentary", "apitest"}, owners)
    zig = h.reg("language", id="zig")
    check(tag + "zig-lite: a language (extensions, comment, keywords)",
          zig and zig["spec"]["extensions"] == ["zig", "zon"] and "fn" in zig["spec"]["keywords"], zig)
    check(tag + "zig-lite: a formatter (zig fmt, or one in NimScript)",
          h.reg("formatter", lang="zig") is not None, h.regs)
    check(tag + "wordinfo-lsp: a language server script for text files",
          h.reg("lsp", lang="plaintext", script="server.nims") is not None)
    check(tag + "commentary: the gc operator, the ie text object, :Comment",
          h.reg("operator", keys="gc") and h.reg("textObject", keys="ie") and h.reg("ex", name="Comment"))
    up = h.reg("command", title="API: upper-case the line")
    check(tag + "a command with its keys", up and up["keys"] == "Ctrl+Alt+U", up)
    # calls
    r = h.call(up["cb"])
    check(tag + "the command ran: the line read and replaced through the API",
          r and "err" not in r and h.lines[0] == "ABC DEF", (r, h.lines))
    pr = h.call(h.reg("command", title="API: problems")["cb"])
    p = (h.problems or [{}])[0]
    check(tag + "problems with a fix, a sign, text after the line, a status item",
          pr and p.get("message") == "three letters" and p["fixes"][0]["edits"][0]["text"] == "four" and
          len(h.decor) == 2 and h.status == "api: 2 lines", (pr, h.problems, h.decor, h.status))
    ap = h.call(h.reg("command", title="API: ask and pick")["cb"])
    check(tag + "ask, pick, confirm: the answers used", ap and h.lines[0] == "Ann:1", (ap, h.lines))
    st = h.call(h.reg("command", title="API: settings and shell")["cb"])
    msg = h.messages[-1] if h.messages else ""
    check(tag + "a setting, a shell command, the data folder", st and msg.startswith("width 120 · hi 0 · "), msg)
    h.lines = ["x", "trailing   "]
    bs = h.reg("event", event="beforeSave")
    h.call(bs["cb"], {"buf": 1, "path": os.path.join(tmp, "a.txt"), "lang": "plaintext"})
    check(tag + "an event before saving changes the text", h.lines == ["x", "trailing"], h.lines)
    sv = h.reg("event", event="save", pattern="*.txt")
    h.call(sv["cb"], {"buf": 1, "path": "/x/a.txt", "lang": "plaintext"})
    check(tag + "an event after saving: its log line", any("saved /x/a.txt (plaintext)" in l for l in h.logs), h.logs)
    er = h.call(h.reg("command", title="API: raise")["cb"])
    check(tag + "a plugin's exception comes back as the call's error (the host goes on)",
          er and er.get("err") == "on purpose" and h.call(up["cb"]) is not None, er)
    nm = h.reg("vimMap", keys="<leader>u")
    h.call(nm["cb"], {"count": 3})
    check(tag + "a vim mapping with its count", h.messages[-1] == "leader u ×3", h.messages[-1:])
    # vim: the operator and the text object
    h.lines = ["a = 1", "b = 2", "", "c = 3"]
    op = h.reg("operator", keys="gc")
    h.call(op["cb"], {"buf": 1, "range": {"start": {"line": 0, "col": 0}, "stop": {"line": 1, "col": 5}},
                      "linewise": True})
    check(tag + "commentary: gc comments the lines", h.lines[:2] == ["# a = 1", "# b = 2"], h.lines)
    h.call(op["cb"], {"buf": 1, "range": {"start": {"line": 0, "col": 0}, "stop": {"line": 1, "col": 7}},
                      "linewise": True})
    check(tag + "commentary: gc again uncomments them", h.lines[:2] == ["a = 1", "b = 2"], h.lines)
    to = h.call(h.reg("textObject", keys="ie")["cb"], {"buf": 1, "pos": {"line": 1, "col": 0}})
    check(tag + "commentary: ie is the whole text",
          to and to.get("value") == {"start": {"line": 0, "col": 0}, "stop": {"line": 3, "col": 5}}, to)
    # a NimScript formatter (zig-lite's, when zig is not installed)
    fm = h.reg("formatter", lang="zig")
    if "cb" in fm:
        f = h.call(fm["cb"], {"text": "const x = 1;   \n\n\n\n\tconst y = 2;\n"})
        check(tag + "zig-lite: the NimScript formatter", f and f.get("value") == "const x = 1;\n\n    const y = 2;\n", f)
    # a timer: ned keeps the time, the host runs the callback
    tm = h.reg("timer")
    if tm:
        h.call(tm["cb"])
        h.call(tm["cb"])
        check(tag + "a timer's callback (echo goes to the log)", any("two ticks" in l for l in h.logs), h.logs[-5:])
    t0 = time.time()
    for _ in range(50):
        h.call(up["cb"])
    ms = (time.time() - t0) * 1000 / 50
    check(tag + "a command with two API calls: %.1f ms" % ms, ms < 200, ms)
    h.close()


def frame(j):
    b = json.dumps(j).encode()
    return b"Content-Length: %d\r\n\r\n" % len(b) + b


def read_frames(p, until, timeout=30):
    buf = b""
    end = time.time() + timeout
    got = []
    while time.time() < end:
        while b"\r\n\r\n" in buf:
            head, rest = buf.split(b"\r\n\r\n", 1)
            n = int([l for l in head.split(b"\r\n") if l.lower().startswith(b"content-length:")][0].split(b":")[1])
            if len(rest) < n:
                break
            j = json.loads(rest[:n])
            buf = rest[n:]
            got.append(j)
            if until(j):
                return j, got
        r, _, _ = select.select([p.stdout], [], [], max(0, end - time.time()))
        if not r:
            break
        c = os.read(p.stdout.fileno(), 65536)
        if not c:
            break
        buf += c
    return None, got


def run_bridge(ned, tmp):
    server = os.path.join(EX, "wordinfo-lsp", "server.nims")
    p = subprocess.Popen([ned, "--lsp-bridge", server], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, cwd=tmp)
    def req(i, m, params):
        p.stdin.write(frame({"jsonrpc": "2.0", "id": i, "method": m, "params": params}))
        p.stdin.flush()
        return read_frames(p, lambda j: j.get("id") == i)
    def note(m, params):
        p.stdin.write(frame({"jsonrpc": "2.0", "method": m, "params": params}))
        p.stdin.flush()
    t0 = time.time()
    r, _ = req(1, "initialize", {"processId": None, "rootUri": None, "capabilities": {}})
    caps = (r or {}).get("result", {}).get("capabilities", {})
    check("lsp bridge: initialize (%d ms)" % ((time.time() - t0) * 1000), caps.get("hoverProvider") is True, r)
    note("initialized", {})
    uri = "file:///tmp/x.txt"
    text = "apple banana apple\nTODO: more apples\n" + "x" * 120 + "\n"
    note("textDocument/didOpen", {"textDocument": {"uri": uri, "languageId": "plaintext", "version": 1, "text": text}})
    d, _ = read_frames(p, lambda j: j.get("method") == "textDocument/publishDiagnostics")
    ds = (d or {}).get("params", {}).get("diagnostics", [])
    check("lsp bridge: diagnostics (a TODO, a long line)",
          len(ds) == 2 and ds[0]["severity"] == 3 and ds[1]["range"]["start"]["character"] == 100, ds)
    r, _ = req(2, "textDocument/hover", {"textDocument": {"uri": uri}, "position": {"line": 0, "character": 2}})
    hv = (r or {}).get("result", {}).get("contents", {}).get("value", "")
    check("lsp bridge: hover — the word and how often", "**apple** — 2 times" in hv, r)
    note("textDocument/didChange", {"textDocument": {"uri": uri, "version": 2},
                                    "contentChanges": [{"range": {"start": {"line": 0, "character": 0},
                                                                  "end": {"line": 0, "character": 5}},
                                                        "text": "cherry"}]})
    r, _ = req(3, "textDocument/hover", {"textDocument": {"uri": uri}, "position": {"line": 0, "character": 2}})
    hv = (r or {}).get("result", {}).get("contents", {}).get("value", "")
    check("lsp bridge: an incremental change kept", "**cherry** — 1 time" in hv, r)
    r, _ = req(4, "textDocument/completion", {"textDocument": {"uri": uri}, "position": {"line": 1, "character": 0}})
    labels = [i["label"] for i in (r or {}).get("result", {}).get("items", [])]
    check("lsp bridge: completion of the text's words", "banana" in labels and "apples" in labels, labels)
    r, _ = req(5, "textDocument/definition", {"textDocument": {"uri": uri}, "position": {"line": 0, "character": 0}})
    check("lsp bridge: what it does not do → MethodNotFound", (r or {}).get("error", {}).get("code") == -32601, r)
    req(6, "shutdown", None)
    note("exit", None)
    try:
        code = p.wait(10)
    except subprocess.TimeoutExpired:
        p.kill()
        code = None
    check("lsp bridge: shutdown, exit → exit code 0", code == 0, code)


def main():
    args = sys.argv[1:]
    ned = next((os.path.abspath(a) for a in args if not a.startswith("-")), os.path.join(REPO, "ned"))
    if shutil.which("nim") is None:
        print("nim is needed on PATH")
        return 2
    tmp = tempfile.mkdtemp(prefix="tplugins-")
    try:
        run_host(tmp, False)
        if os.path.exists(ned):
            run_bridge(ned, tmp)
        else:
            print("(no ned binary at %s: the bridge is not tested)" % ned)
        if "--native" in args:
            t2 = os.path.join(tmp, "native")
            os.makedirs(t2)
            run_host(t2, True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    failed = [n for n, ok in RESULTS if not ok]
    print("\n%d checks, %d failed" % (len(RESULTS), len(failed)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
