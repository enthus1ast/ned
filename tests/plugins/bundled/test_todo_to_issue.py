"""todo-to-issue: the TODO comments read (the word, a (who), the text, comment closers); asked first; the issue made
through a pretend gh — its title, its text with the place and the lines around, the labels —, its number written
into the comment; one that names an issue already, a line without one, gh failing, opening an issue."""
import os, tempfile
from tplugins import check
from tbundled import run_jobs, pos

GH = r'''#!/bin/sh
echo "$@" >> "$GH_LOG"
case "$1 $2" in
  "browse --no-browser") echo "https://github.com/me/proj/blob/main/$3"; exit 0;;
  "issue create")
    while [ $# -gt 0 ]; do [ "$1" = "--body-file" ] && cp "$2" "$GH_BODY"; shift; done
    [ -n "$GH_FAIL" ] && { echo "HTTP 401: Bad credentials" >&2; exit 1; }
    echo "Creating issue in me/proj"; echo; echo "https://github.com/me/proj/issues/42"; exit 0;;
  "issue view") exit 0;;
esac
'''


def run(factory, tag):
    base = tempfile.mkdtemp(prefix="todo-to-issue-")
    tools = os.path.join(base, "bin")
    os.makedirs(tools)
    open(os.path.join(tools, "gh"), "w").write(GH)
    os.chmod(os.path.join(tools, "gh"), 0o755)
    os.environ["GH_LOG"] = os.path.join(base, "log.txt")
    os.environ["GH_BODY"] = os.path.join(base, "body.md")
    old = os.environ["PATH"]
    os.environ["PATH"] = tools + ":" + old
    try:
        h = factory()
        if not h.build_ok:
            check(tag + "the host compiles", False, h.build_err)
            return
        if not h.pump(lambda j: j.get("t") == "ready", 90):
            h.p.kill()
            check(tag + "it starts", False, h.p.stderr.read()[-1500:])
            return
        check(tag + "it starts (%s ms)" % h.ready_ms, True)
        make = h.reg("command", title="TODO: make it an issue")["cb"]
        h.path_ = os.path.join(h.root, "src", "app.nim")
        h.lang = "nim"
        h.lines = ["proc main() =", "  let x = 1", "  # TODO(ann): read the size from the config file", "  echo x",
                   "", "main()"]
        h.cursor = pos(2, 0)
        h.settings = {"labels": "todo, tech-debt"}
        h.asked = []
        h.call(make)
        run_jobs(h)
        q = [a for fn, a in h.asked if fn == "confirm"]
        body = open(os.environ["GH_BODY"]).read() if os.path.exists(os.environ["GH_BODY"]) else ""
        log = open(os.environ["GH_LOG"]).read()
        check(tag + "asked first, with the title", q and q[0].get("text") == "Make a GitHub issue of “read the size from "
              "the config file”?", q)
        check(tag + "the issue: the comment's text as its title, the labels; its text the place, a link and the lines "
              "around", "issue create --title read the size from the config file --body-file" in log and
              "--label todo --label tech-debt" in log and
              body.startswith("From a TODO comment in `src/app.nim`, line 3:\n\n```nim\nproc main() =\n") and
              "  echo x\n" in body and "https://github.com/me/proj/blob/main/src/app.nim:3" in body, (log, body))
        check(tag + "its number written into the comment (the (who) replaced)",
              h.lines[2] == "  # TODO(#42): read the size from the config file" and
              h.messages[-1] == "TODO to issue: issue #42 made — the comment says so", (h.lines[2], h.messages[-1:]))
        h.call(make)
        check(tag + "one that names an issue already: not again", h.messages[-1] ==
              "TODO to issue: this one is issue #42 already (TODO: open its issue)", h.messages[-1:])
        h.call(h.reg("command", title="TODO: open its issue")["cb"])
        run_jobs(h)
        check(tag + "open its issue: gh issue view 42 --web", "issue view 42 --web" in open(os.environ["GH_LOG"]).read() and
              h.messages[-1] == "TODO to issue: opening issue #42", h.messages[-1:])
        h.cursor = pos(1, 0)
        h.call(make)
        nothing = h.messages[-1]
        h.lines = ["/* FIXME: leaks when it fails */", "x"]
        h.cursor = pos(0, 0)
        h.answers["confirm"] = False
        n_jobs = len(h.jobs)
        h.call(make)
        declined = len(h.jobs) == n_jobs and h.lines[0] == "/* FIXME: leaks when it fails */"
        h.answers["confirm"] = True
        os.environ["GH_FAIL"] = "1"
        h.call(make)
        run_jobs(h)
        del os.environ["GH_FAIL"]
        check(tag + "a line without one; declined: nothing; gh fails: why, the comment as it was",
              nothing == "TODO to issue: no TODO, FIXME, HACK, BUG or XXX comment on this line" and declined and
              h.messages[-1] == "TODO to issue: HTTP 401: Bad credentials" and
              h.lines[0] == "/* FIXME: leaks when it fails */", (nothing, declined, h.messages[-1:], h.lines[:1]))
    finally:
        os.environ["PATH"] = old
