"""web-preview: the file opened by the browser program, the project served (a terminal with python's http.server) and
the page opened from it, the address at the cursor; a pretend browser here writes down what it was given"""
import os, shutil, stat, tempfile, time
from tplugins import check


def pos(l, c):
    return {"line": l, "col": c}


def run(factory, tag):
    tmp = tempfile.mkdtemp(prefix="ned-webp-")
    try:
        _run(factory, tag, tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def opened(log, timeout=5):
    end = time.time() + timeout
    while time.time() < end:
        if os.path.exists(log) and open(log).read().strip():
            return open(log).read().strip().splitlines()
        time.sleep(0.1)
    return []


def _run(factory, tag, tmp):
    h = factory()
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return
    ok = h.pump(lambda j: j.get("t") == "ready", 60)
    check(tag + "it starts", ok)
    if not ok:
        return
    log = os.path.join(tmp, "opened.txt")
    br = os.path.join(tmp, "browser")
    open(br, "w").write('#!/bin/sh\necho "$1" >> %s\n' % log)
    os.chmod(br, os.stat(br).st_mode | stat.S_IEXEC)
    h.settings["browser"] = br
    titles = ["Web: open this file in the browser", "Web: serve the project and open this page",
              "Web: open the address at the cursor", "Web: stop the server"]
    cmds = {t: h.reg("command", title=t) for t in titles}
    check(tag + "its commands", all(cmds.values()), [t for t, c in cmds.items() if not c])
    if not all(cmds.values()):
        return
    page = os.path.join(h.root, "docs", "index.html")
    os.makedirs(os.path.dirname(page), exist_ok=True)
    open(page, "w").write("<p>hi</p>\n")
    h.path_ = page
    h.lines = ["<p>hi</p>"]
    h.dirty_ = True
    h.saved = 0
    h.call(cmds["Web: open this file in the browser"]["cb"])
    o = opened(log)
    check(tag + "open the file: saved first, the browser given its path", o == [page] and h.saved == 1, (o, h.saved))
    # serve: a terminal with the server in the project's folder, the page from it after a moment
    os.remove(log)
    h.terminal = []
    h.call(cmds["Web: serve the project and open this page"]["cb"])
    term = h.terminal[-1] if h.terminal else {}
    check(tag + "serve: python's http.server on 8000 in a terminal, in the project's folder",
          term.get("cmd", "").endswith("-m http.server 8000 --bind 127.0.0.1") and term.get("dir") == h.root, term)
    tm = [r for r in h.regs if r.get("kind") == "timer"]
    if tm:
        h.call(tm[-1]["cb"], {})
    o = opened(log)
    check(tag + "… then the page opened from it: http://localhost:8000/docs/index.html",
          o == ["http://localhost:8000/docs/index.html"], o)
    h.terminal = []
    h.call(cmds["Web: serve the project and open this page"]["cb"])
    check(tag + "a second time: the same server (no other terminal)", h.terminal == [], h.terminal)
    # the address at the cursor
    os.remove(log)
    h.lines = ['see <a href="https://nim-lang.org/docs/manual.html">the manual</a>.']
    h.cursor = pos(0, 20)
    h.sel = None
    h.call(cmds["Web: open the address at the cursor"]["cb"])
    o = opened(log)
    check(tag + "the address at the cursor (its quotes and the dot after it left out)",
          o == ["https://nim-lang.org/docs/manual.html"], o)
    h.messages = []
    h.lines = ["no address here"]
    h.call(cmds["Web: open the address at the cursor"]["cb"])
    check(tag + "no address: said", any("No address" in m for m in h.messages), h.messages)
