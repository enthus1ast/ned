"""nimble-browser: nimble's package lists (packages_official.json and another packages*.json; an alias and a name in
both left out; installed ones marked), browsing them, a search by words (the name first, then the tags, then the
description), a package's README fetched with curl (a pretend one: found on GitHub; a host not found; no README; a
package hosted elsewhere), installing it in the terminal, adding it to the project's .nimble file (and not twice),
nimble refresh, no list at all"""
import json, os, stat
from tplugins import check
from tbundled import run_jobs

OFFICIAL = [
    {"name": "jester", "url": "https://github.com/dom96/jester", "method": "git", "tags": ["web", "http", "framework"],
     "description": "A sinatra-like web framework for Nim.", "license": "MIT", "web": "https://github.com/dom96/jester"},
    {"name": "prologue", "url": "https://github.com/planety/prologue.git", "method": "git", "tags": ["web", "prologue"],
     "description": "Powerful and flexible web framework written in Nim", "license": "Apache-2.0"},
    {"name": "webby", "url": "https://github.com/treeform/webby", "method": "git", "tags": ["web", "url"],
     "description": "Web utilities", "license": "MIT"},
    {"name": "oldweb", "alias": "jester"},
    {"name": "glab", "url": "https://gitlab.com/someone/glab", "method": "git", "tags": ["gitlab"],
     "description": "on gitlab", "license": "MIT"},
    {"name": "elsewhere", "url": "https://example.org/x.git", "method": "git", "tags": [],
     "description": "hosted elsewhere", "license": "BSD"},
]
EXTRA = [{"name": "Jester", "url": "https://github.com/someone-else/jester", "tags": [], "description": "a copy"},
         {"name": "extra", "url": "https://github.com/me/extra", "tags": [], "description": "from another list"}]

CURL = """#!/bin/sh
for a; do u=$a; done
echo "$u" >> "$CURL_LOG"
case "$u" in
  https://raw.githubusercontent.com/dom96/jester/HEAD/README.md) printf '# Jester\\n\\nThe README.\\n'; exit 0 ;;
  *prologue*) echo "curl: (6) Could not resolve host: raw.githubusercontent.com" >&2; exit 6 ;;
  *) echo "curl: (22) The requested URL returned error: 404" >&2; exit 22 ;;
esac
"""


def tool(d, name, text):
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, name)
    open(p, "w").write(text)
    os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC)


def run(factory, tag):
    h = factory()
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return
    ok = h.pump(lambda j: j.get("t") == "ready", 90)
    check(tag + "it starts", ok, "" if ok else h.p.stderr.read()[-1500:])
    if not ok:
        return
    titles = ["Nimble: browse packages…", "Nimble: search packages…", "Nimble: refresh the package list"]
    c = {t: h.reg("command", title=t) for t in titles}
    check(tag + "its commands and its setting", all(c.values()) and h.reg("setting", key="nimbleDir"))
    if not all(c.values()):
        return
    picks, asks = [], []
    base = h.api

    def api(j):
        fn = j["fn"]
        if fn == "pick" and picks:
            h.asked.append((fn, j.get("args", {})))
            h.send({"t": "res", "id": j["id"], "value": picks.pop(0)})
        elif fn == "ask" and asks:
            h.asked.append((fn, j.get("args", {})))
            h.send({"t": "res", "id": j["id"], "value": asks.pop(0)})
        else:
            base(j)
    h.api = api
    # no list yet
    empty = os.path.join(h.tmp, "empty")
    os.makedirs(empty)
    h.settings["nimbleDir"] = empty
    h.call(c["Nimble: browse packages…"]["cb"])
    check(tag + "no package list: said (nimble refresh makes it)", "no package list in " + empty in h.messages[-1],
          h.messages[-1:])
    nd = os.path.join(h.tmp, "nimble")
    os.makedirs(os.path.join(nd, "pkgs2", "jester-0.6.0-0123abcd"))
    json.dump(OFFICIAL, open(os.path.join(nd, "packages_official.json"), "w"))
    json.dump(EXTRA, open(os.path.join(nd, "packages_extra.json"), "w"))
    h.settings["nimbleDir"] = nd
    bin_ = os.path.join(h.tmp, "bin")
    tool(bin_, "curl", CURL)
    tool(bin_, "nimble", "#!/bin/sh\necho \"Downloading Official package list\"\necho done\n")
    os.environ["CURL_LOG"] = os.path.join(h.tmp, "curl.log")
    old_path = os.environ["PATH"]

    def jobs():
        os.environ["PATH"] = bin_ + os.pathsep + old_path
        try:
            run_jobs(h)
        finally:
            os.environ["PATH"] = old_path

    # browse: every package, by name, installed ones marked; an alias and a second Jester left out
    h.asked = []
    picks[:] = [-1]
    h.call(c["Nimble: browse packages…"]["cb"])
    a = h.asked[-1][1] if h.asked else {}
    check(tag + "browse: every package by name — an alias and the same name in another list left out; installed: ✓",
          a.get("items") == ["  elsewhere", "  extra", "  glab", "✓ jester", "  prologue", "  webby"] and
          a.get("details", [None] * 4)[3] == "A sinatra-like web framework for Nim. (0.6.0)" and
          a.get("title") == "Nimble packages (6)", a)
    # jester → its README (fetched from GitHub), what the list says above it
    picks[:] = [3, 0]
    h.tabs = []
    h.call(c["Nimble: browse packages…"]["cb"])
    acts = h.asked[-1][1] if h.asked else {}
    check(tag + "a package's choices: its README, install it (installed: said); no .nimble file: not offered",
          acts.get("items") == ["Its README", "Install it (nimble install jester)"] and
          acts.get("details") == ["https://github.com/dom96/jester", "installed: 0.6.0"], acts)
    jobs()
    t = h.tabs[-1] if h.tabs else ("", "", "")
    check(tag + "its README in a Markdown tab, under what the list says of it",
          t[0] == "nimble: jester" and t[2] == "markdown" and t[1].startswith("# jester\n\n> A sinatra-like") and
          "- **installed:** 0.6.0" in t[1] and "- **tags:** web, http, framework" in t[1] and
          t[1].rstrip().endswith("The README."), t[1])
    # a search: the words in the name, tags or description, the name's first
    asks[:] = ["web framework"]
    picks[:] = [-1]
    h.call(c["Nimble: search packages…"]["cb"])
    a = h.asked[-1][1] if h.asked else {}
    check(tag + "a search: the packages with all the words, the tags before the description",
          a.get("items") == ["✓ jester", "  prologue"] and "2 for “web framework”" in a.get("title", ""), a)
    asks[:] = ["web"]
    picks[:] = [-1]
    h.call(c["Nimble: search packages…"]["cb"])
    a = h.asked[-1][1] if h.asked else {}
    check(tag + "… a word in a name before the same word as a tag", a.get("items", [""])[0] == "  webby", a)
    asks[:] = ["nothing-like-this"]
    h.call(c["Nimble: search packages…"]["cb"])
    check(tag + "… none: said", "no package has all of “nothing-like-this”" in h.messages[-1], h.messages[-1:])
    # READMEs that cannot be fetched: the host not found (the network), none at the addresses, elsewhere
    for idx, want in [(4, "the host could not be found — is the network on?"),
                      (2, "no README at the addresses tried"), (0, "this package lives elsewhere")]:
        picks[:] = [idx, 0]
        h.tabs = []
        h.call(c["Nimble: browse packages…"]["cb"])
        jobs()
        t = h.tabs[-1] if h.tabs else ("", "", "")
        check(tag + "a README that cannot be fetched: what the list says, and why — " + want,
              want in t[1] and t[1].startswith("# "), t[1])
    log = open(os.environ["CURL_LOG"]).read().split()
    check(tag + "GitLab's address for a package there; after a missing README the next name, after a host not found "
          "no more", "https://gitlab.com/someone/glab/-/raw/HEAD/README.md" in log and
          sum("prologue" in u for u in log) == 1 and sum("glab" in u for u in log) > 3, log)
    # install it: in the terminal, after asking
    h.terminal = []
    picks[:] = [5, 1]
    h.call(c["Nimble: browse packages…"]["cb"])
    check(tag + "install it: asked, then nimble install in the terminal",
          [x.get("cmd") for x in h.terminal] == ["nimble install webby"], h.terminal)
    # add it to the project's .nimble file: after its last requires, left for you to save
    proj = os.path.join(h.tmp, "proj")
    os.makedirs(proj)
    nf = os.path.join(proj, "app.nimble")
    text = "version = \"0.1.0\"\n\nrequires \"nim >= 2.0\"\nrequires \"jester >= 0.6\"\n\ntask hi, \"x\":\n  echo 1"
    open(nf, "w").write(text)
    h.root = proj
    h.path_ = nf
    h.lines = text.split("\n")
    h.saved = 0
    picks[:] = [5, 2]
    h.call(c["Nimble: browse packages…"]["cb"])
    check(tag + "add it to the .nimble file: after its last requires, not saved",
          h.lines[3:5] == ["requires \"jester >= 0.6\"", "requires \"webby\""] and h.saved == 0 and
          "save it to keep it" in h.messages[-1], (h.lines, h.messages[-1:]))
    picks[:] = [3, 2]
    h.call(c["Nimble: browse packages…"]["cb"])
    check(tag + "… one it requires already: said, not added", "requires jester already (line 4)" in h.messages[-1]
          and h.lines.count("requires \"webby\"") == 1 and len(h.lines) == 8, h.messages[-1:])
    # nimble refresh: in the background, then the list read again
    h.messages = []
    h.call(c["Nimble: refresh the package list"]["cb"])
    check(tag + "refresh: nimble refresh in the background", h.jobs and h.jobs[0][0].startswith("nimble refresh"),
          h.jobs)
    jobs()
    check(tag + "… then the list read again", any("refreshed — 6 packages" in m for m in h.messages), h.messages)
