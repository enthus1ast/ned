"""nim-playground: the playground played by a server of the test's own (127.0.0.1, never the internet) — the
selection shared (its JSON as the playground takes it; the link on the clipboard), the whole file when nothing is
selected, run there (what it printed; an error marked on its line in the file); and when it cannot be reached — the
connection refused (as with no network), a server error, curl not installed —, said in words, the request kept"""
import http.server, json, os, threading
from tplugins import check
from tbundled import run_jobs

SEEN = []


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, body, ctype="text/plain"):
        b = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        try:
            req = json.loads(self.rfile.read(n).decode())
        except ValueError:
            return self.reply(400, "")
        SEEN.append((self.path, req, self.headers.get("Content-Type")))
        if self.path == "/broken/pasty":
            return self.reply(500, "Something went wrong while uploading, please try again")
        if self.path.endswith("/pasty"):
            return self.reply(200, "https://pasty.ee/abc123")
        if self.path.endswith("/compile"):
            code = req.get("code", "")
            if "undeclared" in code:
                return self.reply(200, json.dumps({"compileLog": "Hint: used config file\n/usercode/in.nim(2, 6) "
                                                   "Error: undeclared identifier: 'undeclared'", "log": ""}))
            return self.reply(200, json.dumps({"compileLog": "Hint: [SuccessX]", "log": "hello\nworld\n"}))
        self.reply(404, "")


def run(factory, tag):
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    port = srv.server_address[1]
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        go(factory, tag, port)
    finally:
        srv.shutdown()


def go(factory, tag, port):
    h = factory()
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return
    ok = h.pump(lambda j: j.get("t") == "ready", 90)
    check(tag + "it starts", ok, "" if ok else h.p.stderr.read()[-1500:])
    if not ok:
        return
    share, runc = h.reg("command", title="Playground: share the selection"), \
        h.reg("command", title="Playground: run the selection there")
    sd = {k: (h.reg("setting", key=k) or {}).get("default") for k in ("server", "version", "target", "timeoutSeconds")}
    check(tag + "its commands and settings (the real playground by default)", share and runc and sd == {
        "server": "https://play.nim-lang.org", "version": "latest", "target": "c", "timeoutSeconds": 30}, sd)
    if not (share and runc):
        return
    server = "http://127.0.0.1:%d" % port
    h.settings["server"] = server + "/"
    h.lines = ["import std/strutils", "echo \"hello\".toUpperAscii", "echo 1"]
    h.sel = {"start": {"line": 1, "col": 0}, "stop": {"line": 2, "col": 6}}
    del SEEN[:]
    h.call(share["cb"])
    check(tag + "share: curl in the background", len(h.jobs) == 1 and h.jobs[0][0].startswith("curl -sS"), h.jobs)
    run_jobs(h)
    check(tag + "share: the selection sent as the playground takes it (POST /pasty, JSON)", SEEN == [
        ("/pasty", {"code": "echo \"hello\".toUpperAscii\necho 1", "compilationTarget": "c"}, "application/json")],
          SEEN)
    link = server + "/#pasty=abc123"
    check(tag + "the link on the clipboard, in the status line and the Output panel",
          h.clip == link and link in h.messages[-1] and "on the clipboard" in h.messages[-1] and
          any(link in o for o in h.output), (h.clip, h.messages[-1:]))
    # nothing selected: the whole file
    h.sel = None
    del SEEN[:]
    h.call(share["cb"])
    run_jobs(h)
    check(tag + "nothing selected: the whole file", SEEN and SEEN[0][1]["code"] == "\n".join(h.lines), SEEN)
    # run there: what it printed
    h.settings["version"] = "2.2.4"
    del SEEN[:]
    h.output = []
    h.call(runc["cb"])
    run_jobs(h)
    check(tag + "run there: POST /compile with the version and the target, raw output",
          SEEN and SEEN[0][0] == "/compile" and SEEN[0][1] == {"code": "\n".join(h.lines), "compilationTarget": "c",
                                                               "outputFormat": "raw", "version": "2.2.4"}, SEEN)
    check(tag + "… what it printed in the Output panel, its first line in the status line",
          h.output and "hello\nworld" in h.output[-1] and "Nim 2.2.4" in h.output[-1] and
          h.messages[-1].startswith("Playground: ran — hello") and "showOutput" in h.calls_seen, h.output[-1:])
    # an error: on its line of the file (the selection's line 2 is the file's line 4)
    h.lines = ["# a", "# b", "block:", "  echo undeclared", "  echo 2"]
    h.sel = {"start": {"line": 2, "col": 0}, "stop": {"line": 4, "col": 8}}
    h.decor = []
    h.call(runc["cb"])
    run_jobs(h)
    vt = [(a["line"], a["text"]) for fn, a in h.decor if fn == "vtext"]
    check(tag + "an error: marked on its line in the file, said", vt == [
        (3, "✗ Error: undeclared identifier: 'undeclared'")] and "(line 4)" in h.messages[-1], (vt, h.messages[-1:]))
    # the playground cannot be reached: a port nothing listens on (as without a network)
    h.settings["server"] = "http://127.0.0.1:9"
    h.messages = []
    h.call(share["cb"])
    run_jobs(h)
    req = os.path.join(h.tmp, "data", "nim-playground", "request.json")
    check(tag + "not reached: said in words (could not connect — the network?), the request kept",
          h.messages and "could not be reached: it could not connect — is the network on" in h.messages[-1] and
          req in h.messages[-1] and os.path.exists(req), h.messages[-1:])
    h.settings["server"] = server + "/broken"
    h.call(share["cb"])
    run_jobs(h)
    check(tag + "the playground answers an error: its status and words", "answered 500: Something went wrong" in
          h.messages[-1], h.messages[-1:])
    # curl not installed
    nocurl = os.path.join(h.tmp, "nocurl")
    os.makedirs(nocurl)
    os.symlink("/bin/sh", os.path.join(nocurl, "sh"))
    old = os.environ["PATH"]
    os.environ["PATH"] = nocurl
    try:
        h.call(share["cb"])
        run_jobs(h)
    finally:
        os.environ["PATH"] = old
    check(tag + "curl not installed: said", "curl is not installed" in h.messages[-1], h.messages[-1:])
    h.lines = ["", "  "]
    h.sel = None
    h.jobs = []
    h.call(runc["cb"])
    check(tag + "nothing to run: said, nothing sent", h.jobs == [] and "nothing to run" in h.messages[-1],
          h.messages[-1:])
