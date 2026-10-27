"""web-routes: a project with a Jester app (routes:, a router extended under a prefix, re"…", error Http404, a comment)
and a Prologue one (app.get, addRoute with methods, a list of patterns over several lines added under a prefix, one
on a line never added, a string that only looks like a route), handlers found in another file; the list to choose
from (opening the handler), the table, the dock's view and its refresh, the assistant's tool, an open tab read as it
is, a project with none"""
import os
from tplugins import check

APP = """import jester

router api:
  get "/users":
    resp "[]"
  post  "/users/@id":
    resp "ok"

routes:
  get "/":
    resp "home"
  # get "/not-this":
  get re"^/static/(.*)$":
    resp "file"
  error Http404:
    resp "missing"
  extend api, "/api"
"""

PRO = """import prologue
import urls, views

proc hello*(ctx: Context) {.async.} =
  resp "hi"

let app = newApp()
app.get("/", hello)
app.addRoute("/login", views.login,
             @[HttpGet, HttpPost])
app.addRoute(urls.urlPatterns, "/blog")
app.post("/x", submit)
let s = "app.get(\\"/fake\\", nope)"
app.run()
"""

URLS = """import prologue
import views

const urlPatterns* = @[
  pattern("/", index),
  pattern("/post/{id}", post, @[HttpGet], name = "post"),
]
let more = @[pattern("/about", about)]
"""

VIEWS = """import prologue

proc index*(ctx: Context) {.async.} = resp "index"
proc post*(ctx: Context) {.async.} = resp "post"
proc login*(ctx: Context) {.async.} =
  resp "login"
proc submit*(ctx: Context) {.async.} = resp "x"
proc about*(ctx: Context) {.async.} = resp "about"
"""


def run(factory, tag):
    h = factory()
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return
    ok = h.pump(lambda j: j.get("t") == "ready", 90)
    check(tag + "it starts", ok, "" if ok else h.p.stderr.read()[-1500:])
    if not ok:
        return
    lst, tbl = h.reg("command", title="Web routes: list…"), h.reg("command", title="Web routes: as a table")
    view, click = h.reg("view", title="WEB ROUTES"), h.reg("viewClick", title="WEB ROUTES")
    tool = h.reg("aiTool", name="web_routes")
    check(tag + "its commands, a view in the dock, a tool for the assistant (read-only), on save",
          lst and tbl and view and click and tool and tool.get("readOnly") and h.reg("event", event="save"))
    if not (lst and tbl and view):
        return
    # a project with none
    empty = os.path.join(h.tmp, "empty")
    os.makedirs(empty)
    open(os.path.join(empty, "main.nim"), "w").write("let t = {\"a\": 1}.toTable\necho t.get(\"/a\")\n")
    h.root = empty
    h.call(lst["cb"])
    check(tag + "a project with no routes: said", h.messages and "none found" in h.messages[-1], h.messages[-1:])
    proj = os.path.join(h.tmp, "proj")
    for name, text in [("src/app.nim", APP), ("src/pro.nim", PRO), ("src/urls.nim", URLS), ("src/views.nim", VIEWS),
                       ("nimcache/skip.nim", "routes:\n  get \"/cache\":\n    discard\n")]:
        os.makedirs(os.path.dirname(os.path.join(proj, name)), exist_ok=True)
        open(os.path.join(proj, name), "w").write(text)
    h.root = proj
    h.answers["pick"] = -1
    h.asked = []
    h.call(lst["cb"])
    items = h.asked[-1][1]["items"] if h.asked else []
    details = h.asked[-1][1]["details"] if h.asked else []
    got = sorted(" ".join(i.split()) for i in items)
    want = sorted(["GET /api/users", "POST /api/users/@id", "GET /", "GET re\"^/static/(.*)$\"", "ERROR Http404",
                   "GET /", "GET POST /login", "POST /x", "GET /blog", "GET /blog/post/{id}", "GET /about"])
    check(tag + "every route: Jester's (a router under its prefix, re\"…\", error), Prologue's (methods, a list under "
          "its prefix, one never added) — not a comment, a string or nimcache/", got == want, got)
    check(tag + "each with its framework, handler and place",
          "Prologue · login — src/pro.nim:9" in details and "Jester · src/app.nim:4" in details, details)
    # choosing one opens its handler: Prologue's proc in another file, Jester's block
    i = [" ".join(x.split()) for x in items].index("GET POST /login")
    h.answers["pick"] = i
    h.opened = []
    h.call(lst["cb"])
    check(tag + "the one chosen opens at its handler: the proc (in another file)",
          h.opened == [("src/views.nim", 4)], h.opened)
    i = [" ".join(x.split()) for x in items].index("POST /api/users/@id")
    h.answers["pick"] = i
    h.opened = []
    h.call(lst["cb"])
    check(tag + "… Jester's: the block under the route", h.opened == [("src/app.nim", 6)], h.opened)
    # the table
    h.call(tbl["cb"])
    t = h.tabs[-1] if h.tabs else ("", "", "")
    check(tag + "the table in a Markdown tab", t[0] == "Web routes" and t[2] == "markdown" and
          "| GET POST | `/login` | `login` | src/pro.nim:9 |" in t[1] and "| ERROR | `Http404` | (its block) |" in t[1],
          t[1])
    # the dock's view: a refresh row, each file, its routes (a tap opens the handler)
    r = h.call(view["cb"])
    rows = (r or {}).get("value") or []
    texts = [(x["text"], x["depth"]) for x in rows]
    check(tag + "the view: a row to read them again, the files, their routes under them",
          rows and rows[0]["id"] == "refresh" and rows[0]["detail"] == "11 routes" and ("src/app.nim", 0) in texts
          and ("src/urls.nim", 0) in texts and any(x["text"].startswith("GET") and x["text"].endswith("/blog") and
                                                   x["path"] == os.path.join(proj, "src/views.nim") and x["line"] == 2
                                                   for x in rows), texts)
    # an open tab, as it is (not saved): a route added in it
    h.others[7] = {"lines": (APP + "  delete \"/old\":\n    resp \"gone\"\n").split("\n"),
                   "path": os.path.join(proj, "src/app.nim"), "lang": "nim"}
    h.calls_seen = []
    h.call(click["cb"], {"id": "refresh"})
    r = h.call(view["cb"])
    rows = (r or {}).get("value") or []
    check(tag + "↻ reads them again — an open file as its tab has it", "refreshView" in h.calls_seen and
          any(" ".join(x["text"].split()) == "DELETE /old" for x in rows), [x["text"] for x in rows])
    r = h.call(tool["cb"], {})
    v = (r or {}).get("value") or ""
    check(tag + "the assistant's tool: the table", "| DELETE | `/old` |" in v and "| GET | `/blog/post/{id}` | `post` |"
          in v, v)
