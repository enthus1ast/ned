"""commit-helper: the staged changes read (git diff --cached), the kind and the scope guessed, a draft in a tab, the
commit made with the tab's text (its # lines left out); nothing staged: asked to stage everything"""
import os, subprocess
from tplugins import check


def git(root, *args):
    return subprocess.run(["git", "-C", root] + list(args), capture_output=True, text=True,
                          env=dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@e", GIT_COMMITTER_NAME="t",
                                   GIT_COMMITTER_EMAIL="t@e"))


def write(root, rel, text):
    p = os.path.join(root, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "w").write(text)


def run(factory, tag):
    # (git's name and address before the plugin starts: its git runs with the environment it started with — a machine
    # with no git identity of its own, as GitHub's, would refuse the commit)
    os.environ.update(GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@e", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@e")
    h = factory()
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return
    ok = h.pump(lambda j: j.get("t") == "ready", 60)
    check(tag + "it starts", ok)
    if not ok:
        return
    dr = h.reg("command", title="Git: draft a commit message")
    cm = h.reg("command", title="Git: commit with this message")
    check(tag + "its two commands", dr and cm)
    if not (dr and cm):
        return
    root = os.path.join(h.tmp, "proj")          # (not the folder the plugin's data is in)
    os.makedirs(root, exist_ok=True)
    h.root = root
    git(root, "init", "-q")
    write(root, "src/ned/ui/outline.nim", "a\nb\n")
    write(root, "README.md", "x\n")
    git(root, "add", "-A")
    git(root, "commit", "-qm", "first")
    # a new file and a changed one under src/ned/ui: feat(ui)
    write(root, "src/ned/ui/outline.nim", "a\nb\nc\n")
    write(root, "src/ned/ui/minimap.nim", "m\n" * 5)
    git(root, "add", "-A")
    h.tabs = []
    h.call(dr["cb"])
    t = h.tabs[-1][1] if h.tabs else ""
    first = t.split("\n")[0]
    check(tag + "the draft: feat(ui): add minimap.nim; change outline.nim — in a tab", first ==
          "feat(ui): add minimap.nim; change outline.nim" and h.tabs[-1][0] == "COMMIT message", first)
    check(tag + "… a line for each file, the biggest first, with its + and - counts",
          "- src/ned/ui/minimap.nim (+5 -0, new)\n- src/ned/ui/outline.nim (+1 -0)" in t, t)
    # commit with the tab's text: the # lines left out
    h.lines = ["fix(ui): the outline", "", "# a comment line", "- details"]
    h.title_ = "COMMIT message"
    h.call(cm["cb"])
    log = git(root, "log", "-1", "--format=%B").stdout.strip()
    check(tag + "commit: the message without its # lines; the tab closed", log == "fix(ui): the outline\n\n- details"
          and h.closed, (log, h.closed))
    # only docs: docs; only tests: test(…)
    write(root, "docs/guide.md", "g\n")
    git(root, "add", "-A")
    h.call(dr["cb"])
    check(tag + "docs only: docs(docs): add guide.md", h.tabs[-1][1].split("\n")[0] == "docs(docs): add guide.md",
          h.tabs[-1][1][:60])
    git(root, "commit", "-qm", "d")
    write(root, "tests/engine/test_x.py", "t\n")
    git(root, "add", "-A")
    h.call(dr["cb"])
    check(tag + "tests only: test(engine): add test_x.py", h.tabs[-1][1].split("\n")[0] == "test(engine): add test_x.py",
          h.tabs[-1][1][:60])
    git(root, "commit", "-qm", "t")
    # plain style
    h.settings["style"] = "plain"
    write(root, "src/a.nim", "1\n")
    write(root, "src/b.nim", "1\n")
    git(root, "add", "-A")
    h.call(dr["cb"])
    check(tag + "plain: the summary only", h.tabs[-1][1].split("\n")[0] == "add a.nim and b.nim", h.tabs[-1][1][:60])
    git(root, "commit", "-qm", "p")
    # nothing staged: asked to stage everything
    write(root, "src/c.nim", "1\n")
    h.answers["confirm"] = True
    h.asked = []
    h.call(dr["cb"])
    asked = [a for f, a in h.asked if f == "confirm"]
    check(tag + "nothing staged: asked to stage everything, then the draft", asked and
          "stage every change" in asked[0].get("text", "") and h.tabs[-1][1].startswith("add c.nim"), asked)
