"""github: a pretend gh — the dock's view read in the background (pull requests, issues), a pull request's choices
(read it with its reviews and comments in order, its diff, check it out, its checks — still running is no failure —,
comment, the browser, merge in the terminal), an issue's (read, comment, close asked first), a new issue (its title
and text, its address said), a new pull request in the terminal; gh not signed in, gh not installed"""
import json, os, shutil, stat, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tplugins import check
from tbundled import run_jobs

PRS = [{"number": 12, "title": "Faster search", "author": {"login": "ann"}, "headRefName": "fast-search",
        "isDraft": False, "updatedAt": "2026-10-25T10:00:00Z", "url": "https://github.com/o/r/pull/12"},
       {"number": 15, "title": "WIP: themes", "author": {"login": "bob"}, "headRefName": "themes", "isDraft": True,
        "updatedAt": "2026-10-26T10:00:00Z", "url": "https://github.com/o/r/pull/15"}]
ISSUES = [{"number": 3, "title": "Crash on start", "author": {"login": "cy"}, "labels": [{"name": "bug"}],
           "updatedAt": "2026-10-20T10:00:00Z", "url": "https://github.com/o/r/issues/3"}]
PR12 = {"number": 12, "title": "Faster search", "body": "It is faster now.", "author": {"login": "ann"},
        "state": "OPEN", "headRefName": "fast-search", "baseRefName": "main", "url": "https://github.com/o/r/pull/12",
        "labels": [], "additions": 40, "deletions": 7, "changedFiles": 3,
        "comments": [{"author": {"login": "bob"}, "body": "Second, a comment.", "createdAt": "2026-10-25T12:00:00Z"}],
        "reviews": [{"author": {"login": "cy"}, "body": "First, a review.", "state": "CHANGES_REQUESTED",
                     "submittedAt": "2026-10-25T11:00:00Z"}]}
ISSUE3 = {"number": 3, "title": "Crash on start", "body": "", "author": {"login": "cy"}, "state": "OPEN",
          "url": "https://github.com/o/r/issues/3", "labels": [{"name": "bug"}], "comments": []}


def fake_gh(d, data):
    os.makedirs(d, exist_ok=True)
    for name, v in data.items():
        open(os.path.join(d, name), "w").write(json.dumps(v))
    p = os.path.join(d, "gh")
    open(p, "w").write("""#!/bin/sh
D=%s
echo "gh $*" >> "$D/calls.log"
if [ -f "$D/signed-out" ]; then
  echo "To get started with GitHub CLI, please run:  gh auth login" >&2; exit 4
fi
case "$1 $2" in
  "pr list") cat "$D/prs.json" ;;
  "issue list") cat "$D/issues.json" ;;
  "pr view") case "$*" in *--web*) echo "Opening github.com/o/r/pull/$3 in your browser." ;; *) cat "$D/pr$3.json" ;; esac ;;
  "issue view") cat "$D/issue$3.json" ;;
  "pr diff") printf 'diff --git a/x b/x\\n+new\\n' ;;
  "pr checkout") echo "Switched to branch 'fast-search'" ;;
  "pr checks") printf 'build\\tpending\\t0\\ttests\\tpass\\t1m\\n'; exit 8 ;;
  "pr comment"|"issue comment") cp "$5" "$D/comment.txt"; echo "https://github.com/o/r/pull/$3#issuecomment-1" ;;
  "issue close") echo "Closed issue #$3" ;;
  "issue create") cp "$6" "$D/body.txt"; echo "Creating issue in o/r"; echo "https://github.com/o/r/issues/9" ;;
esac
""" % d)
    os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC)


def run(factory, tag):
    tmp = tempfile.mkdtemp(prefix="ned-gh-")
    try:
        go(factory, tag, tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def go(factory, tag, tmp):
    from langcheck import start, done
    d = os.path.join(tmp, "bin")
    fake_gh(d, {"prs.json": PRS, "issues.json": ISSUES, "pr12.json": PR12, "issue3.json": ISSUE3})
    calls_log = os.path.join(d, "calls.log")
    old_path = os.environ["PATH"]
    nim = os.path.dirname(shutil.which("nim") or "/usr/bin/nim")

    def jobs(h):
        os.environ["PATH"] = os.pathsep.join([d, nim, "/usr/bin", "/bin"])
        try:
            run_jobs(h)
        finally:
            os.environ["PATH"] = old_path

    def calls():
        return open(calls_log).read().splitlines() if os.path.exists(calls_log) else []

    h, ok, err = start(factory, [d], only_path=True)
    check(tag + "it starts", ok, err)
    if not ok:
        return
    titles = ["GitHub: pull requests…", "GitHub: issues…", "GitHub: new issue…", "GitHub: new pull request"]
    c = {t: h.reg("command", title=t) for t in titles}
    view, click = h.reg("view", title="GITHUB"), h.reg("viewClick", title="GITHUB")
    check(tag + "its commands, the dock's view, its setting", all(c.values()) and view and click and
          (h.reg("setting", key="limit") or {}).get("default") == 30)
    if not (all(c.values()) and view):
        done(h)
        return
    rows = (h.call(view["cb"]) or {}).get("value") or []
    check(tag + "the view: read in the background", rows and rows[0]["detail"] == "reading…" and len(h.jobs) == 1 and
          "gh pr list --limit 30 --json" in h.jobs[0][0] and "gh issue list" in h.jobs[0][0], h.jobs)
    jobs(h)
    rows = (h.call(view["cb"]) or {}).get("value") or []
    got = [(x["icon"], x["text"], x["detail"], x["depth"]) for x in rows][1:]
    check(tag + "… the pull requests (a draft dimmer) and the issues", got == [
        ("▸", "Pull requests", "2", 0), ("⇄", "#12 Faster search", "@ann · fast-search", 1),
        ("◌", "#15 WIP: themes", "@bob · themes", 1), ("▸", "Issues", "1", 0),
        ("○", "#3 Crash on start", "@cy · bug", 1)], got)
    picks = []
    base = h.api

    def api(j):
        if j["fn"] == "pick" and picks:
            h.asked.append(("pick", j.get("args", {})))
            h.send({"t": "res", "id": j["id"], "value": picks.pop(0)})
        else:
            base(j)
    h.api = api

    def pr(action, answer=None):
        picks[:] = [0, action]
        if answer is not None: h.answers["ask"] = answer
        h.call(c["GitHub: pull requests…"]["cb"])
        jobs(h)

    # read a pull request: its facts, its text, the review and the comment in the order they were written
    pr(0)
    t = h.tabs[-1] if h.tabs else ("", "", "")
    lists = [x[1] for x in h.asked if x[0] == "pick"]
    check(tag + "the pull requests to choose from: number, title, author, branch, draft",
          lists and lists[-2]["items"] == ["#12 Faster search", "#15 WIP: themes"] and
          lists[-2]["details"] == ["@ann · fast-search", "@bob · themes · draft"], lists[-2:])
    check(tag + "read it: a Markdown tab with its facts, text, review and comment in order",
          t[0] == "#12 Faster search" and t[2] == "markdown" and
          "**open** · by @ann · `fast-search` → `main` · +40 −7 in 3 files" in t[1] and "It is faster now." in t[1]
          and t[1].index("review: changes requested") < t[1].index("Second, a comment.") and "## 2 comments" in t[1],
          t[1])
    pr(1)
    check(tag + "its diff in a tab", h.tabs[-1] == ("#12.diff", "diff --git a/x b/x\n+new", "diff"), h.tabs[-1:])
    h.messages = []
    pr(2)
    check(tag + "check it out: gh pr checkout, said", "gh pr checkout 12" in calls() and
          any("on the branch of #12 — fast-search" in m for m in h.messages), h.messages)
    pr(3)
    check(tag + "its checks (some still running: no failure)", h.tabs[-1][0] == "#12 checks" and
          "pending" in h.tabs[-1][1], h.tabs[-1:])
    pr(4, "Looks good to me")
    check(tag + "a comment: one line, sent with --body-file",
          open(os.path.join(d, "comment.txt")).read() == "Looks good to me", calls()[-1:])
    pr(5)
    check(tag + "in the browser: gh pr view --web", "gh pr view 12 --web" in calls(), calls()[-1:])
    h.terminal = []
    h.answers["confirm"] = True
    pr(6)
    check(tag + "merge: asked, then gh pr merge in the terminal", [x["cmd"] for x in h.terminal] == ["gh pr merge 12"],
          h.terminal)
    # an issue: read, close (asked)
    picks[:] = [0, 0]
    h.call(c["GitHub: issues…"]["cb"])
    jobs(h)
    check(tag + "an issue read: no description said", h.tabs[-1][0] == "#3 Crash on start" and
          "*(no description)*" in h.tabs[-1][1] and "labels: bug" in h.tabs[-1][1], h.tabs[-1:])
    picks[:] = [0, 2]
    h.call(c["GitHub: issues…"]["cb"])
    jobs(h)
    check(tag + "close it: asked first, then closed, the lists read again", "gh issue close 3" in calls() and any(
        a[0] == "confirm" and "Close the issue #3" in a[1].get("text", "") for a in h.asked) and
          calls()[-2].startswith("gh pr list"), calls()[-3:])
    # a click in the dock
    picks[:] = [-1]
    h.call(click["cb"], {"id": "p1"})
    check(tag + "a pull request tapped in the dock: its choices", [x for x in h.asked if x[0] == "pick"][-1][1][
        "title"].startswith("#15 WIP: themes"), h.asked[-1:])
    # a new issue
    asks = ["Search is slow", "It takes seconds."]
    base2 = h.api

    def api2(j):
        if j["fn"] == "ask" and asks:
            h.send({"t": "res", "id": j["id"], "value": asks.pop(0)})
        else:
            base2(j)
    h.api = api2
    h.call(c["GitHub: new issue…"]["cb"])
    jobs(h)
    check(tag + "a new issue: its title and text, its address said", "gh issue create --title Search is slow "
          "--body-file " in " ".join(calls()) and open(os.path.join(d, "body.txt")).read() == "It takes seconds." and
          "https://github.com/o/r/issues/9" in h.messages[-1], h.messages[-1:])
    h.terminal = []
    h.call(c["GitHub: new pull request"]["cb"])
    check(tag + "a new pull request: gh pr create in the terminal", [x["cmd"] for x in h.terminal] == ["gh pr create"],
          h.terminal)
    # not signed in: gh's advice
    open(os.path.join(d, "signed-out"), "w").close()
    h.call(c["GitHub: issues…"]["cb"])
    check(tag + "gh not signed in: said what to do", "gh is not signed in: run gh auth login" in h.messages[-1],
          h.messages[-1:])
    h.call(click["cb"], {"id": "refresh"})
    jobs(h)
    rows = (h.call(view["cb"]) or {}).get("value") or []
    check(tag + "… in the dock too, in the error colour", any(x["color"] == "error" and "gh auth login" in x["text"]
                                                             for x in rows), rows)
    done(h)
    bare = os.path.join(tmp, "bare")
    os.makedirs(bare)
    h, ok, err = start(factory, [bare], only_path=True, hide=("gh",))
    if ok:
        h.call(h.reg("command", title="GitHub: pull requests…")["cb"])
        check(tag + "gh not installed: said how to install it", "gh is not installed (Termux: pkg install gh" in
              h.messages[-1], h.messages[-1:])
    done(h)
