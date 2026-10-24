#!/usr/bin/env python3
"""ned's plugins without the editor: the NimScript host (nim e) with the example plugins and an API test plugin,
this script playing ned (JSON lines: registrations, calls, the API); the tutorial's plugin (examples/plugins/notes,
docs/plugins/tutorial.md) in a host of its own; a language server written in NimScript through `ned --lsp-bridge`;
the hosts compiled (plugins.native).

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
            f = os.path.join(d, "plugin.nims")
            if not os.path.exists(f):
                f = os.path.join(d, "plugin.nim")
            src += "import %s as nedPlug%d\n" % (json.dumps(f), i)
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
        self.lang = "plaintext"
        self.calls_seen = []
        self.progress = []
        self.output = []
        self.root = tmp                 # the project's folder (shell commands run there)
        self.cur = 1                    # the buffer current() names
        self.settings = {}              # plugins.<plugin>.<key>: these first
        self.asked = []                 # pick, ask, confirm: (fn, args)
        self.opened = []                # openFile: (path, line)
        self.stopped = []               # stopTimer: the timers' ids

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
        if fn == "current": v = self.cur
        elif fn == "root": v = self.root
        elif fn == "path": v = os.path.join(self.tmp, "a.txt")
        elif fn == "lang": v = self.lang
        elif fn == "lineCount": v = len(self.lines)
        elif fn == "line": v = self.lines[a["line"]] if 0 <= a["line"] < len(self.lines) else ""
        elif fn == "lines":
            last = a.get("last", -1)
            v = self.lines[a.get("first", 0):(None if last < 0 else last + 1)]
        elif fn == "wordAt":
            ln, c = a["pos"]["line"], a["pos"]["col"]
            t = self.lines[ln] if ln < len(self.lines) else ""
            i, e = c, c
            while i > 0 and (t[i - 1].isalnum() or t[i - 1] == "_"): i -= 1
            while e < len(t) and (t[e].isalnum() or t[e] == "_"): e += 1
            v = t[i:e]
        elif fn in ("refreshView", "showOutput"): self.calls_seen.append(fn)
        elif fn == "progress": self.progress.append((a["text"], a["percent"]))
        elif fn == "output": self.output.append(a["text"])
        elif fn == "text": v = self.text()
        elif fn == "setText": self.set_text(a["text"])
        elif fn == "replace": self.replace(a["range"], a["text"])
        elif fn == "cursor": v = self.cursor
        elif fn == "setCursor": self.cursor = a["pos"]
        elif fn == "lineComment": v = "#"
        elif fn == "problems": self.problems = a["problems"]
        elif fn in ("sign", "vtext", "highlight"): self.decor.append((fn, a))
        elif fn == "clearDecorations":
            self.decor = []
            self.calls_seen.append(fn)
        elif fn == "open":
            self.opened.append((a["path"], a["line"]))
            v = self.cur
        elif fn == "stopTimer": self.stopped.append(a["cb"])
        elif fn == "status": self.status = a["text"]
        elif fn in ("message", "toast"): self.messages.append(a["text"])
        elif fn == "log": self.logs.append(a["text"])
        elif fn in self.answers:
            self.asked.append((fn, a))
            v = self.answers[fn]
        elif fn == "setting" and a.get("key") in self.settings: v = self.settings[a["key"]]
        elif fn == "setting": v = 120 if a.get("key") == "width" else (True if a.get("key") == "sortCaseSensitive" else None)
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
               ("commentary", os.path.join(EX, "commentary")), ("apitest", os.path.join(HERE, "fixtures", "apitest")),
               ("ini-tools", os.path.join(EX, "ini-tools"))]
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
          owners == {"zig-lite", "wordinfo-lsp", "commentary", "apitest", "ini-tools"}, owners)
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
    run_ini(h, tag)
    t0 = time.time()
    h.lines = ["abc def", "x"]
    for _ in range(50):
        h.call(up["cb"])
    ms = (time.time() - t0) * 1000 / 50
    check(tag + "a command with two API calls: %.1f ms" % ms, ms < 200, ms)
    h.close()


def run_ini(h, tag):
    """ini-tools: a language's features (symbols, completions, hover, code actions, a snippet), a view, progress and
    the Output panel, the assistant's tool, the plugin's setting and the ned it needs"""
    h.lang = "toml"
    h.lines = ["[server]", "port = 80", "host = a", "[client]", "port = 81", "port = 82", "zeta = 1", "alpha = 2", "ho"]
    reg = h.reg("requires")
    check(tag + "ini-tools: requiresNed (the ned it needs)", reg and reg["spec"] == ">= 6.20", reg)
    sd = h.reg("setting", key="sortCaseSensitive")
    check(tag + "ini-tools: a setting's definition (default, description)",
          sd and sd["default"] is False and "Sort" in sd["description"], sd)
    sy = h.call(h.reg("symbols", lang="toml")["cb"], {"buf": 1})
    v = (sy or {}).get("value") or []
    check(tag + "ini-tools: symbols — sections, their keys under them",
          len(v) == 8 and v[0] == {"name": "[server]", "kind": "section", "detail": "", "line": 0, "col": 0, "depth": 0}
          and v[1]["name"] == "port" and v[1]["depth"] == 1 and v[1]["detail"] == "80", v)
    co = h.call(h.reg("completion", lang="toml")["cb"], {"buf": 1, "pos": {"line": 8, "col": 2}, "prefix": "ho"})
    v = (co or {}).get("value") or []
    check(tag + "ini-tools: completions — a key another section has, as a snippet",
          len(v) == 1 and v[0]["label"] == "host" and v[0]["snippet"] is True and v[0]["insert"] == "host = ${1:a}", v)
    co = h.call(h.reg("completion", lang="toml")["cb"], {"buf": 1, "pos": {"line": 4, "col": 7}, "prefix": ""})
    v = [x["label"] for x in (co or {}).get("value") or []]
    check(tag + "ini-tools: completions after = — the key's values elsewhere", v == ["80", "81", "82"], v)
    hv = h.call(h.reg("hover", lang="toml")["cb"], {"buf": 1, "pos": {"line": 1, "col": 1}})
    v = (hv or {}).get("value") or ""
    check(tag + "ini-tools: hover — the key in each section", "**port** — in 3 sections" in v and "[client]" in v, v)
    ca = h.call(h.reg("codeActions", lang="toml")["cb"],
                {"buf": 1, "range": {"start": {"line": 5, "col": 0}, "stop": {"line": 5, "col": 8}}})
    v = (ca or {}).get("value") or []
    titles = [f["title"] for f in v]
    check(tag + "ini-tools: code actions — sort the section (a setting read), remove a key given twice",
          titles == ["Sort the keys of [client]", "Remove the second port (line 6)"] and
          v[0]["edits"][0]["text"] == "alpha = 2\nport = 81\nport = 82\nzeta = 1", v)
    check(tag + "ini-tools: a snippet", h.reg("snippet", lang="toml", trigger="sec") is not None)
    vw = h.call(h.reg("view", title="INI sections")["cb"], {})
    v = (vw or {}).get("value") or []
    check(tag + "ini-tools: a view's items", [x["text"] for x in v] == ["[server]", "[client]"] and v[1]["id"] == "3", v)
    h.call(h.reg("viewClick", title="INI sections")["cb"], {"id": "3"})
    check(tag + "ini-tools: clicking a view's item (the cursor moved)", h.cursor == {"line": 3, "col": 0}, h.cursor)
    ev = h.reg("event", event="change", pattern="lang:toml")
    h.call(ev["cb"], {"buf": 1, "path": "/x/a.ini", "lang": "toml"})
    check(tag + "ini-tools: an event refreshes the view", "refreshView" in h.calls_seen, h.calls_seen)
    tool = h.reg("aiTool", name="ini_get")
    check(tag + "ini-tools: a tool for the assistant (reads only)", tool and tool["readOnly"] is True and
          "section" in tool["params"], tool)
    d = os.path.join(h.tmp, "cfg")
    os.makedirs(d, exist_ok=True)
    open(os.path.join(d, "app.ini"), "w").write("[db]\nurl = x\nurl = y\n")
    r = h.call(tool["cb"], {"path": "cfg/app.ini", "section": "db", "key": "url"})
    check(tag + "ini-tools: the tool's answer", (r or {}).get("value") == "x", r)
    r = h.call(tool["cb"], {"path": "cfg/app.ini", "section": "db", "key": "nope"})
    check(tag + "ini-tools: the tool's error", (r or {}).get("err") == "no such key", r)
    r = h.call(h.reg("command", title="INI: check the project's config files")["cb"], {}, timeout=30)
    check(tag + "ini-tools: progress, the Output panel (file:line), a message",
          r and h.progress and h.progress[-1][0] == "" and any("app.ini:3:1: url is in [db] twice" in o for o in h.output)
          and "showOutput" in h.calls_seen and h.messages[-1].startswith("INI: 1 key"), (r, h.progress, h.output, h.messages[-1:]))
    h.lang = "plaintext"
    h.cursor = {"line": 0, "col": 1}


def rg(l0, c0, l1, c1):
    return {"start": {"line": l0, "col": c0}, "stop": {"line": l1, "col": c1}}


def run_notes(tmp, native):
    """notes — the plugin docs/plugins/tutorial.md builds, in a host of its own: its commands (the text read and
    changed; pick, ask, confirm), the notes an event marks (problems with fixes, signs, highlights, text after a
    line, the status bar), its settings, a view, the project's notes (grep, progress, the Output panel), a
    language's features for every file, vim, timers, the assistant's tools"""
    tag = ("native: " if native else "") + "notes: "
    h = Host([("notes", os.path.join(EX, "notes"))], native=native, tmp=tmp)
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return
    ok = h.pump(lambda j: j.get("t") == "ready", 60)
    err = ""
    if not ok:
        h.p.kill()
        err = h.p.stderr.read()[-1500:]
    check(tag + "it starts (%s ms)" % h.ready_ms, ok, err)
    if not ok:
        return
    titles = {r["title"] for r in h.regs if r["kind"] == "command"}
    check(tag + "its commands, the ned it needs, three settings",
          {"Notes: add a TODO", "Notes: go to a note…", "Notes: add a note…", "Notes: remove the DONE notes…",
           "Notes: find the project's notes", "Notes: remind me later", "Notes: cancel the reminder"} <= titles and
          h.reg("command", title="Notes: add a TODO")["keys"] == "ctrl+alt+n" and
          h.reg("requires")["spec"] == ">= 6.20" and h.reg("setting", key="markers")["default"] == "NOTE TODO FIXME"
          and h.reg("setting", key="problems")["default"] is True and
          h.reg("setting", key="reminderMinutes")["default"] == 25, (titles, h.regs))
    ev = {"buf": 1, "path": os.path.join(tmp, "a.txt"), "lang": "plaintext"}
    # 2. a first command
    h.lines = ["x = 1", "", "  y = 2"]
    h.cursor = {"line": 0, "col": 0}
    r = h.call(h.reg("command", title="Notes: add a TODO")["cb"])
    check(tag + "add a TODO: at the end of the line (its comment), the cursor after it, a line in the log",
          r and "err" not in r and h.lines[0] == "x = 1  # TODO: " and h.cursor == {"line": 0, "col": 15} and
          any("a TODO at line 1 of " in l for l in h.logs), (r, h.lines, h.cursor, h.logs[-3:]))
    # 3. pick, ask, confirm
    h.cursor = {"line": 1, "col": 0}
    h.call(h.reg("command", title="Notes: add a note…")["cb"])
    check(tag + "add a note…: the kind picked, the text asked, a toast",
          h.lines[1] == "# TODO: Ann" and [f for f, _ in h.asked[-2:]] == ["pick", "ask"] and
          h.asked[-2][1]["items"] == ["NOTE", "TODO", "FIXME"] and h.messages[-1] == "TODO added", (h.lines, h.asked))
    h.lines = ["# NOTE: read me", "x = 1  # TODO: ", "y = 2", "  # FIXME(ann): broken */", "z = 3 # DONE: old"]
    h.call(h.reg("command", title="Notes: go to a note…")["cb"])
    a = h.asked[-1][1]
    check(tag + "go to a note…: the file's notes in a list (a name in brackets, the end of a comment left out)",
          a["items"] == ["NOTE: read me", "TODO: ", "FIXME: broken"] and a["details"] == ["line 1", "line 2", "line 4"]
          and h.cursor == {"line": 1, "col": 9}, (a, h.cursor))
    # 4. events: the notes marked
    h.decor = []
    h.status = ""
    h.calls_seen = []
    h.call(h.reg("event", event="open", pattern="*")["cb"], ev)
    ps = h.problems or []
    check(tag + "an open event: the notes in Problems — one fix marks it done, one removes it",
          len(ps) == 3 and [p["severity"] for p in ps] == [4, 3, 2] and ps[1]["message"] == "TODO: (nothing yet)" and
          ps[2]["message"] == "FIXME: broken" and ps[2]["range"] == rg(3, 4, 3, 22) and
          ps[0]["fixes"][0] == {"title": "Mark it done", "edits": [{"range": rg(0, 2, 0, 6), "text": "DONE"}]} and
          ps[0]["fixes"][1]["edits"][0]["range"] == rg(0, 0, 1, 0) and
          ps[1]["fixes"][1] == {"title": "Remove the note", "edits": [{"range": rg(1, 5, 1, 15), "text": ""}]}, ps)
    kinds = [d[0] for d in h.decor]
    check(tag + "… a sign, the marker highlighted, a word after the empty note, the count in the status bar",
          kinds.count("sign") == 3 and kinds.count("highlight") == 3 and kinds.count("vtext") == 1 and
          h.decor[0][1]["text"] == "✎" and h.status == "✎ 3 notes" and
          h.calls_seen[:1] == ["clearDecorations"] and "refreshView" in h.calls_seen, (h.decor, h.status, h.calls_seen))
    ch = h.reg("event", event="change", pattern="*")
    h.settings = {"problems": False}
    h.call(ch["cb"], ev)
    check(tag + "a change event, the problems setting off: no problems, the marks stay",
          h.problems == [] and len(h.decor) == 7, (h.problems, h.decor))
    h.settings = {"markers": "HACK"}
    h.lines = ["a  # HACK: x", "b  # TODO: y"]
    h.call(ch["cb"], ev)
    check(tag + "the markers setting: words of your own",
          [p["message"] for p in h.problems] == ["HACK: x"] and h.status == "✎ 1 note", (h.problems, h.status))
    h.settings = {}
    h.lines = ["a  # FIXME: x"]
    h.call(h.reg("event", event="save", pattern="lang:nim")["cb"], {"buf": 1, "path": "/x/a.nim", "lang": "nim"})
    check(tag + "a save event for Nim files: a warning", h.messages[-1] == "a.nim still has 1 FIXME", h.messages[-1:])
    h.lines = ["a = 1  # DONE: x", "# DONE: y", "b = 2", "# TODO: z"]
    h.call(h.reg("command", title="Notes: remove the DONE notes…")["cb"])
    check(tag + "remove the DONE notes…: confirmed, each note's comment (or its line) removed",
          h.asked[-1] == ("confirm", {"text": "Remove the 2 DONE notes of this file?"}) and
          h.lines == ["a = 1", "b = 2", "# TODO: z"] and h.messages[-1].startswith("Removed 2 notes"), (h.lines, h.asked[-1:]))
    # 6. the view, the project's notes
    h.lines = ["# NOTE: read me", "x = 1  # TODO: ", "y = 2", "  # FIXME(ann): broken */"]
    vw = h.reg("view", title="Notes")
    v = (h.call(vw["cb"]) or {}).get("value") or []
    check(tag + "the view: the file's notes", [x["text"] for x in v] == ["NOTE: read me", "TODO: ", "FIXME: broken"]
          and v[2]["id"] == "3:4" and v[2]["color"] == "warn" and v[2]["detail"] == "line 4", v)
    h.call(h.reg("viewClick", title="Notes")["cb"], {"id": "3:4"})
    check(tag + "clicking one of them: the cursor there", h.cursor == {"line": 3, "col": 4}, h.cursor)
    proj = os.path.join(tmp, "proj")
    for d in ["sub", ".hidden", "many"]:
        os.makedirs(os.path.join(proj, d), exist_ok=True)
    open(os.path.join(proj, "a.nim"), "w").write("x = 1\n# TODO: write the tests\n")
    open(os.path.join(proj, "sub", "b.txt"), "w").write("FIXME(ann): it breaks\nTODOS: not a note\n")
    open(os.path.join(proj, ".hidden", "c.txt"), "w").write("TODO: hidden\n")
    open(os.path.join(proj, "bin.dat"), "wb").write(b"\0\1TODO: binary\n")
    for i in range(60):
        open(os.path.join(proj, "many", "f%02d.txt" % i), "w").write("nothing\n")
    h.root = proj
    h.progress = []
    h.output = []
    r = h.call(h.reg("command", title="Notes: find the project's notes")["cb"], {}, timeout=30)
    check(tag + "the project's notes: the Output panel (file:line:col), progress, a message",
          r and "err" not in r and h.output == ["a.nim:2:3: TODO: write the tests\nsub/b.txt:1:1: FIXME: it breaks"] and
          "showOutput" in h.calls_seen and any(p > 0 for _, p in h.progress) and h.progress[-1] == ("", -1) and
          h.messages[-1] == "Notes: 2 notes in 63 files", (r, h.output, h.progress, h.messages[-1:]))
    v = (h.call(vw["cb"]) or {}).get("value") or []
    check(tag + "… and in the view, under the file's (a path and a line: ned opens them)",
          [x["text"] for x in v[3:]] == ["In the project: 2 notes", "a.nim", "TODO: write the tests", "sub/b.txt",
                                         "FIXME: it breaks"] and v[5]["path"] == "a.nim" and v[5]["line"] == 1 and
          v[5]["depth"] == 2, v[3:])
    # 9. the assistant's tools (the project's files)
    tl = h.reg("aiTool", name="notes_list")
    r = h.call(tl["cb"], {"path": "a.nim"})
    r2 = h.call(tl["cb"], {"path": ""})
    r3 = h.call(tl["cb"], {"path": "nope.txt"})
    check(tag + "the assistant's notes_list (it only reads): a file, every file, an error",
          tl["readOnly"] is True and (r or {}).get("value") == "a.nim:2: TODO: write the tests" and
          (r2 or {}).get("value") == "a.nim:2: TODO: write the tests\nsub/b.txt:1: FIXME: it breaks" and
          (r3 or {}).get("err") == "no such file: nope.txt", (tl, r, r2, r3))
    ta = h.reg("aiTool", name="notes_add")
    h.lines = ["x = 1", "y = 2"]
    r = h.call(ta["cb"], {"path": "a.nim", "line": 2, "text": "check y"})
    check(tag + "the assistant's notes_add (it asks you first): the file opened, the note added",
          ta["readOnly"] is False and h.opened[-1] == ("a.nim", 1) and h.lines[1] == "y = 2  # TODO: check y" and
          (r or {}).get("value") == "added a TODO at line 2 (not saved yet)", (ta, r, h.lines, h.opened))
    h.root = tmp
    # 7. a language's features
    h.lines = ["x = 1  # TO", "y = 2"]
    co = h.reg("completion", lang="*")
    v = (h.call(co["cb"], {"buf": 1, "pos": {"line": 0, "col": 11}, "prefix": "TO"}) or {}).get("value") or []
    v2 = (h.call(co["cb"], {"buf": 1, "pos": {"line": 1, "col": 5}, "prefix": ""}) or {}).get("value")
    check(tag + "completions for every file: a marker in a comment, as a snippet — none outside one",
          len(v) == 1 and v[0]["label"] == "TODO" and v[0]["insert"] == "TODO: $0" and v[0]["snippet"] is True and
          v2 == [], (v, v2))
    h.lines = ["# TODO: a", "# TODO: b", "x"]
    hv = (h.call(h.reg("hover", lang="*")["cb"], {"buf": 1, "pos": {"line": 0, "col": 3}}) or {}).get("value")
    hv2 = (h.call(h.reg("hover", lang="*")["cb"], {"buf": 1, "pos": {"line": 2, "col": 0}}) or {}).get("value")
    check(tag + "hover on a marker: the file's notes of that kind",
          hv == "**TODO** — 2 notes in this file\n\n- line 1: a\n- line 2: b" and hv2 == "", (hv, hv2))
    ca = h.reg("codeActions", lang="*")
    v = (h.call(ca["cb"], {"buf": 1, "range": rg(0, 0, 0, 9)}) or {}).get("value") or []
    v2 = (h.call(ca["cb"], {"buf": 1, "range": rg(2, 0, 2, 1)}) or {}).get("value") or []
    check(tag + "code actions: a note made another kind, a TODO added to a line",
          [f["title"] for f in v] == ["Make it a NOTE", "Make it a FIXME"] and
          v[1]["edits"] == [{"range": rg(0, 2, 0, 6), "text": "FIXME"}] and
          v2 == [{"title": "Add a TODO to this line", "edits": [{"range": rg(2, 0, 2, 1), "text": "x  # TODO: "}]}],
          (v, v2))
    sy = (h.call(h.reg("symbols", lang="plaintext")["cb"], {"buf": 1}) or {}).get("value") or []
    check(tag + "symbols for text files: the notes as the outline",
          sy == [{"name": "TODO: a", "kind": "section", "detail": "", "line": 0, "col": 2, "depth": 0},
                 {"name": "TODO: b", "kind": "section", "detail": "", "line": 1, "col": 2, "depth": 0}], sy)
    sn = h.reg("snippet", lang="*", trigger="todo")
    check(tag + "a snippet for every file", sn and sn["body"] == "TODO(${1:who}): ${2:what}$0", sn)
    # 8. vim
    h.lines = ["a", "# TODO: 1", "b", "# NOTE: 2", "c", "# FIXME: 3"]
    h.cursor = {"line": 0, "col": 0}
    nx, pv = h.reg("vimMap", keys="]n"), h.reg("vimMap", keys="[n")
    h.call(nx["cb"], {"count": 2})
    c1 = h.cursor
    h.call(pv["cb"], {"count": 1})
    c2 = h.cursor
    h.call(nx["cb"], {"count": 9})
    c3 = h.cursor
    h.cursor = {"line": 0, "col": 0}
    h.call(pv["cb"], {"count": 1})
    check(tag + "vim: ]n and [n with a count (as far as there are notes)",
          c1 == {"line": 3, "col": 2} and c2 == {"line": 1, "col": 2} and c3 == {"line": 5, "col": 2} and
          h.messages[-1] == "No note above", (c1, c2, c3, h.messages[-1:]))
    to = h.reg("textObject", keys="in")
    ta = h.reg("textObject", keys="an")
    t1 = (h.call(to["cb"], {"buf": 1, "pos": {"line": 5, "col": 0}}) or {}).get("value")
    t2 = (h.call(ta["cb"], {"buf": 1, "pos": {"line": 5, "col": 0}}) or {}).get("value")
    t3 = (h.call(to["cb"], {"buf": 1, "pos": {"line": 0, "col": 0}}) or {}).get("value")
    check(tag + "vim: the text objects in (what the note says) and an (the whole note); none on a line without one",
          t1 == rg(5, 9, 5, 10) and t2 == rg(5, 2, 5, 10) and t3 == rg(-1, 0, -1, 0), (t1, t2, t3))
    h.call(h.reg("operator", keys="<leader>d")["cb"], {"buf": 1, "range": rg(1, 0, 3, 9), "linewise": True})
    check(tag + "vim: the <leader>d operator marks the notes it covers done",
          h.lines[1:4] == ["# DONE: 1", "b", "# DONE: 2"] and h.lines[5] == "# FIXME: 3" and
          h.messages[-1] == "2 notes done", (h.lines, h.messages[-1:]))
    h.answers["pick"] = 0
    h.call(h.reg("ex", name="Notes")["cb"], {"args": "fixme"})
    check(tag + "vim: :Notes FIXME — only those, in the list",
          h.asked[-1][1]["items"] == ["FIXME: 3"] and h.cursor == {"line": 5, "col": 2}, (h.asked[-1:], h.cursor))
    h.answers["pick"] = 1
    # 9. timers
    tm = h.reg("timer", repeat=True)
    h.status = "-"
    h.calls_seen = []
    h.call(tm["cb"])
    s1 = h.status
    h.status = "-"
    h.call(tm["cb"])
    s2 = h.status
    h.cur = 2
    h.lines = ["# TODO: x"]
    h.call(tm["cb"])
    s3 = h.status
    h.cur = 1
    check(tag + "a timer: the status bar follows the file you look at (asked once a file)",
          tm["ms"] == 1000 and s1 == "✎ 1 note" and s2 == "-" and s3 == "✎ 1 note" and
          h.calls_seen.count("refreshView") == 2, (tm, s1, s2, s3, h.calls_seen))
    h.settings = {"reminderMinutes": 1}
    later = lambda: [r for r in h.regs if r["kind"] == "timer" and r["repeat"] is False]
    rm = h.reg("command", title="Notes: remind me later")["cb"]
    cancel = h.reg("command", title="Notes: cancel the reminder")["cb"]
    h.call(rm)
    a = later()
    m1 = h.messages[-1]
    h.call(a[-1]["cb"])
    m2 = h.messages[-1]
    h.call(rm)
    h.call(rm)
    h.call(cancel)
    m3 = h.messages[-1]
    h.call(cancel)
    b = later()
    check(tag + "after: a reminder (a timer started by a command); stopTimer when it is set again or cancelled",
          len(a) == 1 and a[0]["ms"] == 60000 and m1 == "A reminder in 1 minute (Notes: cancel the reminder)" and
          m2.startswith("Time for your notes: 1 note") and len(b) == 3 and h.stopped == [b[1]["cb"], b[2]["cb"]] and
          m3 == "The reminder is cancelled" and h.messages[-1] == "No reminder is set",
          (a, b, h.stopped, m1, m2, m3, h.messages[-1:]))
    h.settings = {}
    h.lines = ["x"] * 300 + ["# TODO: %d" % i for i in range(50)]
    t0 = time.time()
    h.call(ch["cb"], ev)
    ms = (time.time() - t0) * 1000
    check(tag + "marking a file of 350 lines and 50 notes: %.0f ms" % ms, ms < 3000 and len(h.problems) == 50, ms)
    h.close()


def run_full(tmp):
    """a plugin in full Nim (plugin.nim): compiled, a process of its own — std/times, a setting, a command"""
    h = Host([("clock-native", os.path.join(EX, "clock-native"))], native=True, tmp=tmp)
    check("full Nim: clock-native compiles", h.build_ok, h.build_err)
    if not h.build_ok:
        return
    ok = h.pump(lambda j: j.get("t") == "ready", 30)
    check("full Nim: it starts (%s ms)" % h.ready_ms, ok, h.p.stderr.read()[-800:] if not ok else "")
    if not ok:
        return
    h.lines = ["x"]
    h.cursor = {"line": 0, "col": 0}
    r = h.call(h.reg("command", title="Clock: insert the date")["cb"])
    import datetime
    check("full Nim: its command (std/times) edits the text", r and h.lines[0] == datetime.date.today().isoformat() + "x",
          (r, h.lines))
    tm = h.reg("timer")
    h.call(tm["cb"])
    check("full Nim: its timer — the status-bar clock", h.status.startswith("⏱ "), h.status)
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
        t1 = os.path.join(tmp, "notes")
        os.makedirs(t1)
        run_notes(t1, False)
        if os.path.exists(ned):
            run_bridge(ned, tmp)
        else:
            print("(no ned binary at %s: the bridge is not tested)" % ned)
        if "--native" in args:
            t2 = os.path.join(tmp, "native")
            os.makedirs(t2)
            run_host(t2, True)
            t4 = os.path.join(tmp, "notes-native")
            os.makedirs(t4)
            run_notes(t4, True)
            t3 = os.path.join(tmp, "full")
            os.makedirs(t3)
            run_full(t3)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    failed = [n for n, ok in RESULTS if not ok]
    print("\n%d checks, %d failed" % (len(RESULTS), len(failed)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
