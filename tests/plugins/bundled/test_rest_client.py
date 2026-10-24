"""rest-client: .http files as a language (colours, outline, marks), requests sent with curl to a server of this
test's own (127.0.0.1, never the internet) — the method, the address with ? and & lines, headers, a body, file
variables, {{$guid}} {{$timestamp}}, Basic user:pass, a named request's response used by the next, redirects,
HEAD, HTML and binary responses, the timeout, one request at a time, cancel —, the response in a new tab (JSON
pretty-printed), copy as curl, completion and hover of variables, a request in a Markdown ```http block."""
import base64, http.server, json, os, re, subprocess, threading, time
from tplugins import check
from tbundled import run_jobs


def pos(l, c):
    return {"line": l, "col": c}


def start(factory, tag):
    h = factory()
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return None
    ok = h.pump(lambda j: j.get("t") == "ready", 90)
    if not ok:
        h.p.kill()
        check(tag + "it starts", False, h.p.stderr.read()[-1500:])
        return None
    check(tag + "it starts (%s ms)" % h.ready_ms, True)
    return h


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, body, ctype="application/json", extra=None):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(b)

    def any(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode() if n else ""
        if self.path.startswith("/slow"):
            time.sleep(4)
        if self.path == "/html":
            return self.reply(200, "<p>hi</p>", "text/html; charset=utf-8")
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/users?from=redirect")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path == "/login":
            return self.reply(200, json.dumps({"token": "tok-" + json.loads(body)["user"]}), extra={"X-Session": "s1"})
        if self.path == "/png":
            return self.reply(200, b"\x89PNG\r\n\x1a\n\0\0", "image/png")
        self.reply(201 if self.command == "POST" else 200,
                   json.dumps({"method": self.command, "path": self.path, "headers": dict(self.headers), "body": body}))

    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = do_HEAD = any


def run(factory, tag):
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    port = srv.server_address[1]
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        go(factory, tag, port)
    finally:
        srv.shutdown()


HTTP = """@host = http://127.0.0.1:{port}
@user = ann
@path = /users

### List users
# @name users
GET {{{{host}}}}{{{{path}}}}?page=1
  &size=2
Accept: application/json
X-Trace: {{{{$guid}}}}

### Make one
POST {{{{host}}}}/echo HTTP/1.1
Content-Type: application/json
// a comment, not a header
Authorization: Basic ann:secret

{{
  "name": "{{{{user}}}}",
  "at": {{{{$timestamp}}}}
}}

### Log in
# @name login
POST {{{{host}}}}/login
Content-Type: application/json

{{"user": "{{{{user}}}}"}}

### Use the token
GET {{{{host}}}}/me
Authorization: Bearer {{{{login.response.body.$.token}}}}
X-Session: {{{{login.response.headers.X-Session}}}}

###
{{{{host}}}}/html

###
HEAD {{{{host}}}}/users

###
GET {{{{host}}}}/redirect

###
GET {{{{host}}}}/nope{{{{missing}}}}

###
GET {{{{host}}}}/slow

###
GET {{{{host}}}}/png

###
GET http://127.0.0.1:1/closed"""


def go(factory, tag, port):
    h = start(factory, tag)
    if not h:
        return
    lang = h.reg("language", id="http")
    titles = {r["title"] for r in h.regs if r["kind"] == "command"}
    keys = {(r["lang"], r["keys"]) for r in h.regs if r["kind"] == "langKey"}
    vim = {(r.get("lang"), r["keys"]) for r in h.regs if r["kind"] == "vimMap"}
    check(tag + "the http language (.http .rest, # comments, the methods), its commands, Ctrl+Alt+R and <leader>r "
          "in .http files and Markdown, its settings",
          lang and lang["spec"]["extensions"] == ["http", "rest"] and lang["spec"]["lineComment"] == "#" and
          "POST" in lang["spec"]["keywords"] and
          {"REST: send the request at the cursor", "REST: copy as curl", "REST: cancel the request"} <= titles and
          keys == {("http", "ctrl+alt+r"), ("markdown", "ctrl+alt+r")} and
          vim == {("http", "<leader>r"), ("markdown", "<leader>r")} and
          h.reg("setting", key="timeoutSeconds")["default"] == 30 and
          h.reg("setting", key="followRedirects")["default"] is True and
          h.reg("setting", key="insecure")["default"] is False, (lang, titles, keys, vim))
    h.lang = "http"
    h.path_ = os.path.join(h.tmp, "api.http")
    h.lines = HTTP.format(port=port).split("\n")
    L = lambda text: next(i for i, l in enumerate(h.lines) if l.startswith(text))
    send = h.reg("command", title="REST: send the request at the cursor")["cb"]

    def sent(line):
        """the command at the line, then the command it gave ned to run (shellAsync): the tabs it opened"""
        n = len(h.tabs)
        h.cursor = pos(line, 0)
        h.call(send)
        if not h.jobs:
            return None                          # (no request started)
        run_jobs(h)
        return h.tabs[n:]

    # the outline
    sy = (h.call(h.reg("symbols", lang="http")["cb"], {"buf": 1}) or {}).get("value") or []
    check(tag + "the outline: the variables, then each request (its name, its title, or its method and address)",
          [s["name"] for s in sy][:4] == ["@host", "@user", "@path", "users"] and
          [s["name"] for s in sy][4:7] == ["Make one", "login", "Use the token"] and
          sy[3]["detail"] == "GET {{host}}{{path}}?page=1&size=2" and sy[3]["line"] == L("GET {{host}}{{path}}") and
          sy[7]["name"] == "GET {{host}}/html", sy)
    # a GET: variables, a query on two lines, headers, a GUID; the response in a tab (JSON)
    tabs = sent(L("GET {{host}}{{path}}"))
    t = tabs[0] if tabs else ("", "", "")
    body = "\n".join(l for l in t[1].split("\n") if not l.startswith("//"))
    j = json.loads(body) if body.strip().startswith("{") else {}
    guid = j.get("headers", {}).get("X-Trace", "")
    check(tag + "a GET: the address from the variables (the & line added), the headers, {{$guid}}; the response "
          "in a new tab — JSON, the status and the headers as // lines, the body pretty-printed",
          t[0] == "Response: users" and t[2] == "json" and re.match(r"// HTTP/1\.0 200 OK · \d+ ms · \d+ bytes\n", t[1])
          and "// Content-Type: application/json\n" in t[1] and j.get("method") == "GET" and
          j.get("path") == "/users?page=1&size=2" and j["headers"].get("Accept") == "application/json" and
          re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", guid) and
          '\n  "method": "GET",\n' in t[1] and re.match(r"REST: 200 OK in \d+ ms", h.messages[-1]) and
          h.progress[-1] == ("", -1), (t, h.messages[-1:], h.progress[-2:]))
    # a POST with a body
    tabs = sent(L("POST {{host}}/echo"))
    t = tabs[0] if tabs else ("", "", "")
    j = json.loads("\n".join(l for l in t[1].split("\n") if not l.startswith("//")) or "{}")
    b = json.loads(j.get("body") or "{}")
    check(tag + "a POST: its body (the text after the blank line, variables in it), HTTP/1.1 left out, a // line "
          "not a header, Basic user:pass encoded; 201",
          t[0] == "Response: Make one" and t[1].startswith("// HTTP/1.0 201 Created · ") and
          j.get("method") == "POST" and b.get("name") == "ann" and
          isinstance(b.get("at"), int) and abs(b["at"] - time.time()) < 60 and
          j["headers"].get("Authorization") == "Basic " + base64.b64encode(b"ann:secret").decode() and
          j["headers"].get("Content-Type") == "application/json" and not any(k.startswith("//") for k in j["headers"]),
          (t, j))
    # a named request's response, used by the next one
    tabs1 = sent(L("POST {{host}}/login"))
    tabs2 = sent(L("GET {{host}}/me"))
    t = tabs2[0] if tabs2 else ("", "", "")
    j = json.loads("\n".join(l for l in t[1].split("\n") if not l.startswith("//")) or "{}")
    check(tag + "# @name login: its response's body ($.token) and header in the next request",
          tabs1 and tabs1[0][0] == "Response: login" and j.get("headers", {}).get("Authorization") == "Bearer tok-ann" and
          j["headers"].get("X-Session") == "s1", (tabs1, t))
    # no method: GET; an HTML response
    tabs = sent(L("{{host}}/html"))
    t = tabs[0] if tabs else ("", "", "")
    check(tag + "an address alone is a GET; an HTML response: its language, the headers as they are",
          t[0] == "Response: GET /html" and t[2] == "html" and t[1].startswith("HTTP/1.0 200 OK · ") and
          "\nContent-Type: text/html; charset=utf-8\n" in t[1] and t[1].endswith("\n\n<p>hi</p>"), t)
    tabs = sent(L("HEAD {{host}}/users"))
    t = tabs[0] if tabs else ("", "", "")
    check(tag + "HEAD: the headers, no body", t[0] == "Response: HEAD /users" and "Content-Length:" in t[1] and
          t[1].endswith("\n\n"), t)
    tabs = sent(L("GET {{host}}/redirect"))
    t = tabs[0] if tabs else ("", "", "")
    check(tag + "a redirect followed (followRedirects): the last response, its headers only",
          t[0] == "Response: GET /redirect" and '"path": "/users?from=redirect"' in t[1] and "302" not in t[1], t)
    tabs = sent(L("GET {{host}}/png"))
    t = tabs[0] if tabs else ("", "", "")
    check(tag + "a binary body: not shown, its size and type said", t[1].endswith("\n\n(10 bytes of image/png — not shown)\n"), t)
    # what goes wrong
    n = len(h.tabs)
    r = sent(L("GET {{host}}/nope"))
    check(tag + "a variable that is not defined: a warning, nothing sent",
          r is None and len(h.tabs) == n and h.messages[-1] == "REST: {{missing}} is not defined in this file",
          h.messages[-1:])
    r = sent(0)
    check(tag + "the cursor on the variables: no request there", r is None and
          h.messages[-1] == "REST: there is no request at the cursor", h.messages[-1:])
    r = sent(L("GET http://127.0.0.1:1/closed"))
    check(tag + "nothing answers at the address: a warning that says so", r == [] and
          h.messages[-1] == "REST: nothing answers at http://127.0.0.1:1/closed", h.messages[-1:])
    h.settings = {"timeoutSeconds": 1}
    r = sent(L("GET {{host}}/slow"))
    check(tag + "the timeout (timeoutSeconds): curl gives up, a warning that says so, no tab",
          r == [] and h.messages[-1] == "REST: no answer in 1 s (plugins.rest-client.timeoutSeconds) from "
          "http://127.0.0.1:%d/slow" % port, h.messages[-1:])
    h.settings = {}
    # one at a time; cancel (the job run here in the background, as ned does)
    h.cursor = pos(L("GET {{host}}/slow"), 0)
    t0 = time.time()
    h.call(send)
    ms = (time.time() - t0) * 1000
    queued = len(h.jobs)
    h.call(send)
    busy = h.messages[-1]
    cmd, d, cb = h.jobs.pop(0)
    p = subprocess.Popen(["sh", "-c", cmd], cwd=d, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    end = time.time() + 5
    while time.time() < end and not os.path.exists(os.path.join(d, "pid.out")):
        time.sleep(0.05)
    time.sleep(0.2)
    h.call(h.reg("command", title="REST: cancel the request")["cb"])
    out, _ = p.communicate(timeout=10)
    t1 = time.time()
    h.call(cb, {"output": out.rstrip("\n"), "code": p.returncode})
    check(tag + "curl given to ned to run in the background (the command returns at once: %d ms); one request at "
          "a time; cancelled (curl stopped: %.1f s, not the 4 the server takes)" % (ms, t1 - t0),
          ms < 1500 and queued == 1 and busy == "REST: a request is still running (REST: cancel the request)" and
          t1 - t0 < 3 and h.messages[-1] == "REST: the request was cancelled" and not h.jobs,
          (ms, queued, busy, t1 - t0, h.messages[-1:]))
    h.call(h.reg("command", title="REST: cancel the request")["cb"])
    check(tag + "… cancel with none running", h.messages[-1] == "REST: no request is running", h.messages[-1:])
    # copy as curl
    h.cursor = pos(L("POST {{host}}/echo"), 0)
    h.call(h.reg("command", title="REST: copy as curl")["cb"])
    want = ("curl -X POST http://127.0.0.1:%d/echo -H 'Content-Type: application/json' -H 'Authorization: Basic %s' "
            "--data-raw '{\n  \"name\": \"ann\",\n  \"at\": " % (port, base64.b64encode(b"ann:secret").decode()))
    check(tag + "copy as curl: the command on the clipboard (the variables' values in it)",
          h.clip.startswith(want) and h.clip.endswith("\n}'") and h.messages[-1].startswith("Copied: curl -X POST"),
          (h.clip, h.messages[-1:]))
    # completion and hover of variables
    co = h.reg("completion", lang="http")
    h.lines.append("GET {{ho")
    k = len(h.lines) - 1
    v = (h.call(co["cb"], {"buf": 1, "pos": pos(k, 8), "prefix": "ho"}) or {}).get("value") or []
    h.lines[k] = "GET {{$g"
    v2 = (h.call(co["cb"], {"buf": 1, "pos": pos(k, 8), "prefix": "g"}) or {}).get("value") or []
    h.lines[k] = "GET {{log"
    v3 = (h.call(co["cb"], {"buf": 1, "pos": pos(k, 9), "prefix": "log"}) or {}).get("value") or []
    h.lines[k] = "GET {{host}}/x"
    v4 = (h.call(co["cb"], {"buf": 1, "pos": pos(k, 14), "prefix": "x"}) or {}).get("value")
    check(tag + "completion after {{: the file's variables, $guid (after the $), a named request's response; "
          "none after }}",
          [(x["label"], x["insert"]) for x in v] == [("host", "host")] and
          [(x["label"], x["insert"]) for x in v2] == [("$guid", "guid")] and
          [x["label"] for x in v3] == ["login.response.body.$"] and v4 == [], (v, v2, v3, v4))
    hv = h.reg("hover", lang="http")
    h.lines[k] = "GET {{host}}/{{nope}} {{$guid}}"
    hs = [(h.call(hv["cb"], {"buf": 1, "pos": pos(k, c)}) or {}).get("value") for c in (7, 16, 25, 1)]
    check(tag + "hover on a variable: its value, why there is none, what a $ one is; nothing off one",
          hs == ["**{{host}}** = `http://127.0.0.1:%d`" % port, "**{{nope}}** — {{nope}} is not defined in this file",
                 "**{{$guid}}** — made when the request is sent", ""], hs)
    # marks
    h.decor = []
    h.lines = ["@host = x", "// note", "# @name a", "GET {{host}}/{{p}}"]
    h.call(h.reg("event", event="change", pattern="lang:http")["cb"], {"buf": 1, "path": h.path_, "lang": "http"})
    hl = [(d[1]["range"]["start"]["line"], d[1]["range"]["start"]["col"], d[1]["range"]["stop"]["col"], d[1]["color"])
          for d in h.decor if d[0] == "highlight"]
    check(tag + "marks as you type: a variable's name, a // comment, a request's name, each {{use}}",
          hl == [(0, 0, 6, "info"), (1, 0, 7, "hint"), (2, 8, 9, "accent"), (3, 4, 12, "accent"), (3, 13, 18, "accent")],
          hl)
    # a request in Markdown
    h.lang = "markdown"
    h.path_ = os.path.join(h.tmp, "README.md")
    h.lines = ["# API", "", "```http", "@h = http://127.0.0.1:%d" % port, "```", "", "Text.", "",
               "```http", "PUT {{h}}/items/1", "", "x=1", "```"]
    tabs = sent(9)
    t = tabs[0] if tabs else ("", "", "")
    r = sent(6)
    check(tag + "Markdown: the ```http block at the cursor (a variable from another block); none outside one",
          t[0] == "Response: PUT /items/1" and '"body": "x=1"' in t[1] and r is None and
          h.messages[-1] == "REST: the cursor is not in an ```http block with a request", (t, h.messages[-1:]))
    # one tab for each request: sent again, its tab shows the new response; one you changed is kept, a new one opens
    h.lang = "http"
    h.path_ = os.path.join(h.tmp, "api.http")
    h.lines = ["@host = http://127.0.0.1:%d" % port, "", "# @name when", "GET {{host}}/when",
               "X-At: {{$datetime iso8601}}", "X-Rfc: {{$datetime rfc1123}}", "X-Ts: {{$timestamp}}"]
    h.switch_on_new_tab = True
    h.clock = 1_800_000_000
    hdrs = lambda: json.loads("\n".join(l for l in h.lines if not l.startswith("//")) or "{}").get("headers", {})
    sent(3)
    first, h1 = h.cur, hdrs()
    h.switch_to(1)
    h.clock += 61
    sent(3)
    second, h2 = h.cur, hdrs()
    check(tag + "{{$datetime}} and {{$timestamp}} by ned's clock; sent again, the same tab with the new response",
          first != 1 and second == first and h.title_ == "Response: when" and
          (h1.get("X-At"), h1.get("X-Rfc"), h1.get("X-Ts")) ==
          ("2027-01-15T08:00:00Z", "Fri, 15 Jan 2027 08:00:00 GMT", "1800000000") and
          h2.get("X-At") == "2027-01-15T08:01:01Z", (first, second, h1, h2))
    h.dirty_ = True                          # (you change the response tab)
    h.switch_to(1)
    sent(3)
    check(tag + "… a response tab you have changed is kept: the new response in a tab of its own",
          h.cur not in (1, first) and h.tabs[-1][0] == "Response: when (2)" and first in h.others and
          h.others[first]["dirty"] is True, (h.cur, h.tabs[-1][:1]))
    h.switch_on_new_tab = False
