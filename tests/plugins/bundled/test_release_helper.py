"""release-helper: a Nim package in a git repository — the version bumped (patch, minor, major, one typed, one that
is not a version) in the .nimble and src/…/version.nim, through ned's tabs and saved, back to the file you were in;
a CHANGELOG entry (the commits since the last tag, merges left out; dated; before the first section; a new file; a
version that has its section already; nothing to add); the tag (the commands in the Output panel, asked first;
its message the CHANGELOG's section; tag only, or the push in the terminal; a tag there already; cancelled)."""
import os, subprocess, time
from tplugins import check

ENV = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@e", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@e")


def git(root, *args):
    return subprocess.run(["git", "-C", root] + list(args), capture_output=True, text=True, env=ENV)


def write(root, rel, text):
    p = os.path.join(root, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "w").write(text)


def read(root, rel):
    return open(os.path.join(root, rel)).read()


def drive(h):
    """ned's side for files: openFile makes the file a tab (its text from the disk) and the current one; save writes
    the tab to its file; pick answers from h.picks one after the other"""
    base = h.api
    h.picks = []
    h.next_id = 200

    def api(j):
        fn, a = j["fn"], j.get("args", {})
        if fn == "open":
            p = a["path"] if os.path.isabs(a["path"]) else os.path.join(h.root, a["path"])
            h.opened.append((p, a.get("line", -1)))
            if h.path_ == p:
                bid = h.cur
            else:
                bid = next((k for k, st in h.others.items() if st.get("path") == p), None)
                if bid is None:
                    h.next_id += 1
                    bid = h.next_id
                    lines = open(p).read().split("\n") if os.path.exists(p) else [""]
                    h.others[bid] = {"lines": lines, "path": p, "lang": "plaintext", "cursor": {"line": 0, "col": 0}}
                h.switch_to(bid)
            if a.get("line", -1) >= 0:
                h.cursor = {"line": a["line"], "col": max(0, a.get("col", 0))}
            h.send({"t": "res", "id": j["id"], "value": bid})
        elif fn == "save" and a.get("buf", h.cur) == h.cur:
            open(h.path_, "w").write("\n".join(h.lines))
            h.saved += 1
            h.dirty_ = False
            h.send({"t": "res", "id": j["id"], "value": None})
        elif fn == "pick" and h.picks:
            h.asked.append((fn, a))
            h.send({"t": "res", "id": j["id"], "value": h.picks.pop(0)})
        else:
            base(j)
    h.api = api


def run(factory, tag):
    h = factory()
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return
    ok = h.pump(lambda j: j.get("t") == "ready", 60)
    check(tag + "it starts", ok, "" if ok else h.p.stderr.read()[-1500:])
    if not ok:
        return
    titles = ["Release: bump the version…", "Release: add a CHANGELOG entry", "Release: tag it…"]
    c = {t: h.reg("command", title=t) for t in titles}
    check(tag + "its three commands, its settings, the ned it needs",
          all(c.values()) and h.reg("setting", key="tagPrefix")["default"] == "v" and
          h.reg("setting", key="push")["default"] is True and
          h.reg("setting", key="changelog")["default"] == "CHANGELOG.md" and h.reg("requires")["spec"] == ">= 6.29",
          [t for t, v in c.items() if not v])
    if not all(c.values()):
        return

    def run_(t):
        r = h.call(c[t]["cb"], timeout=60)
        return r and "err" not in r

    root = os.path.join(h.tmp, "shop")
    os.makedirs(root)
    h.root = root
    drive(h)
    write(root, "shop.nimble", '# Package\n\nversion       = "1.2.3"\nauthor        = "t"\nsrcDir        = "src"\n')
    write(root, "src/shop/version.nim", '## the version\nconst ShopVersion* = "1.2.3"\nconst Api = "2.0.0"\n')
    write(root, "src/shop.nim", "import shop/version\necho ShopVersion\n")
    write(root, "CHANGELOG.md", "# Changelog\n\nWhat changed in each release.\n\n## 1.2.3 — 2026-01-01\n\n- first\n")
    git(root, "init", "-q", "-b", "main")
    git(root, "add", "-A")
    git(root, "commit", "-qm", "first")
    git(root, "tag", "v1.2.3")
    write(root, "src/shop.nim", "import shop/version\necho ShopVersion, 1\n")
    git(root, "commit", "-qam", "fix: the greeting")
    git(root, "checkout", "-qb", "side")
    write(root, "README.md", "x\n")
    git(root, "add", "-A")
    git(root, "commit", "-qm", "docs: a README")
    git(root, "checkout", "-q", "main")
    git(root, "merge", "-q", "--no-ff", "-m", "Merge branch side", "side")

    # bump
    h.path_ = os.path.join(root, "src", "shop.nim")
    h.lines = read(root, "src/shop.nim").split("\n")
    h.cursor = {"line": 1, "col": 4}
    h.picks = [1]
    run_("Release: bump the version…")
    a = h.asked[-1][1] if h.asked else {}
    check(tag + "bump: patch, minor, major (what each makes) or one you type",
          a.get("items") == ["patch    1.2.3 → 1.2.4", "minor    1.2.3 → 1.3.0", "major    1.2.3 → 2.0.0",
                             "another version…"] and a.get("title") == "Release: the version after 1.2.3", a)
    check(tag + "minor: the .nimble's version and version.nim's const (not another const), saved",
          'version       = "1.3.0"' in read(root, "shop.nimble") and
          read(root, "src/shop/version.nim") == '## the version\nconst ShopVersion* = "1.3.0"\nconst Api = "2.0.0"\n'
          and h.messages[-1] == "Release: 1.2.3 → 1.3.0 in shop.nimble and src/shop/version.nim (saved)",
          (read(root, "shop.nimble"), read(root, "src/shop/version.nim"), h.messages[-1:]))
    check(tag + "… then back to the file you were in, where you were",
          h.path_ == os.path.join(root, "src", "shop.nim") and h.cursor == {"line": 1, "col": 4}, (h.path_, h.cursor))
    h.picks = [3]
    h.answers["ask"] = "nope"
    run_("Release: bump the version…")
    check(tag + "a version typed that is not one: a warning, nothing changed",
          h.messages[-1] == "Release: nope is not a version (1.2.3)" and '"1.3.0"' in read(root, "shop.nimble"),
          h.messages[-1:])
    h.picks = [3]
    h.answers["ask"] = "1.2.4"
    run_("Release: bump the version…")
    check(tag + "a version typed (1.2.4)", '"1.2.4"' in read(root, "shop.nimble") and
          '"1.2.4"' in read(root, "src/shop/version.nim"), read(root, "shop.nimble"))
    git(root, "commit", "-qam", "Version 1.2.4")

    # the CHANGELOG
    run_("Release: add a CHANGELOG entry")
    day = time.strftime("%Y-%m-%d")
    text = "\n".join(h.lines)
    # (git's order of two commits made in the same second is its own: the lines compared as a set)
    check(tag + "the CHANGELOG: a dated section for 1.2.4 before the first one, a line a commit since v1.2.3 (no "
          "merge), the cursor on its heading, not saved",
          h.path_ == os.path.join(root, "CHANGELOG.md") and
          h.lines[:6] == ["# Changelog", "", "What changed in each release.", "", "## 1.2.4 — " + day, ""] and
          sorted(h.lines[6:9]) == ["- Version 1.2.4", "- docs: a README", "- fix: the greeting"] and
          h.lines[9:] == ["", "## 1.2.3 — 2026-01-01", "", "- first", ""] and
          h.cursor == {"line": 4, "col": 0} and h.dirty_ and
          h.messages[-1] == "Release: 3 commits since v1.2.3 in a section for 1.2.4 — edit it, then save",
          (text, h.cursor, h.messages[-1:]))
    k = h.lines.index("- Version 1.2.4") if "- Version 1.2.4" in h.lines else 6
    h.lines[k] = "- The version, 1.2.4"
    h.call(h.reg("command", title="Release: add a CHANGELOG entry")["cb"])
    check(tag + "again: a section for 1.2.4 is there — nothing added, the cursor on it",
          h.lines[k] == "- The version, 1.2.4" and "\n".join(h.lines).count("## 1.2.4") == 1 and
          h.messages[-1].startswith("Release: CHANGELOG.md has a section for 1.2.4 already (line 5)"), h.messages[-1:])
    open(h.path_, "w").write("\n".join(h.lines))
    git(root, "commit", "-qam", "The CHANGELOG")

    # the tag: asked first, the commands in the Output panel (no remote: run it, or cancel)
    h.picks = [1]
    h.terminal = []
    run_("Release: tag it…")
    out = "\n".join(h.output)
    a = h.asked[-1][1]
    check(tag + "tag it: the commands and the tag's message (the CHANGELOG's section) in the Output panel, asked",
          "Release: the commands for v1.2.4" in out and "  git tag -a 'v1.2.4' -F '" in out and
          "the tag's message:\n  Release 1.2.4\n  \n  - " in out and "\n  - The version, 1.2.4" in out and
          "\n  - docs: a README" in out and
          "showOutput" in h.calls_seen and a.get("title") == "Release: tag v1.2.4? (the commands are in the Output panel)"
          and a.get("items", [""])[-1] == "Cancel" and len(a.get("items", [])) == 2, (out, a))
    check(tag + "… cancelled: no tag", git(root, "tag").stdout.split() == ["v1.2.3"], git(root, "tag").stdout)
    # a remote: tag and push (the push in the terminal)
    bare = os.path.join(h.tmp, "origin.git")
    subprocess.run(["git", "init", "-q", "--bare", bare], capture_output=True)
    git(root, "remote", "add", "origin", bare)
    write(root, "src/shop.nim", "changed, not committed\n")
    h.picks = [0]
    run_("Release: tag it…")
    a = h.asked[-1][1]
    msg = git(root, "tag", "-l", "--format=%(contents)", "v1.2.4").stdout
    check(tag + "with origin: run (tag, then push), tag only, cancel; a file not committed said",
          a.get("items", [""])[0].endswith(" — then git push origin 'v1.2.4' in the terminal") and
          a.get("items", ["", ""])[1].startswith("Tag only: git tag -a 'v1.2.4'") and
          a.get("title") == "Release: tag v1.2.4? (the commands are in the Output panel; 1 file not committed)", a)
    check(tag + "… run: the annotated tag (its message from the CHANGELOG), the push in the terminal",
          "v1.2.4" in git(root, "tag").stdout.split() and msg.startswith("Release 1.2.4\n\n- ") and
          "- The version, 1.2.4\n" in msg and
          h.terminal[-1:] == [{"cmd": "git push origin 'v1.2.4'", "dir": ""}] and
          h.messages[-1] == "Release: tagged v1.2.4 — pushing it in the terminal", (msg, h.terminal, h.messages[-1:]))
    run_("Release: tag it…")
    check(tag + "again: the tag is there already — a warning", h.messages[-1] == "Release: the tag v1.2.4 is there "
          "already — bump the version first?", h.messages[-1:])
    git(root, "checkout", "-q", "--", "src/shop.nim")

    # tag only; the prefix setting; no CHANGELOG section: "Release x"
    h.answers["ask"] = "1.3.0"
    h.picks = [3]
    run_("Release: bump the version…")
    git(root, "commit", "-qam", "1.3.0")
    h.settings = {"tagPrefix": "release-"}
    h.picks = [1]
    h.terminal = []
    run_("Release: tag it…")
    msg = git(root, "tag", "-l", "--format=%(contents)", "release-1.3.0").stdout.strip()
    check(tag + "tag only, the tagPrefix setting, no section for the version: its message is Release 1.3.0",
          msg == "Release 1.3.0" and h.terminal == [] and h.messages[-1] == "Release: tagged release-1.3.0", (msg, h.terminal))
    h.settings = {}

    # a CHANGELOG that is not there yet; nothing since the last tag
    os.remove(os.path.join(root, "CHANGELOG.md"))
    git(root, "commit", "-qam", "no changelog")
    h.closed = []
    h.others = {k: v for k, v in h.others.items() if not v.get("path", "").endswith("CHANGELOG.md")}
    if h.path_.endswith("CHANGELOG.md"):
        h.path_ = os.path.join(root, "src", "shop.nim")
        h.lines = [""]
    git(root, "tag", "-d", "release-1.3.0")
    h.settings = {"changelog": "docs/CHANGES.md"}
    run_("Release: add a CHANGELOG entry")
    check(tag + "a CHANGELOG not there yet (the changelog setting): made, with its title",
          h.path_ == os.path.join(root, "docs", "CHANGES.md") and
          h.lines[:5] == ["# Changelog", "", "## 1.3.0 — " + day, "", "- no changelog"], h.lines[:8])
    git(root, "tag", "v1.3.0")
    h.settings = {}
    run_("Release: add a CHANGELOG entry")
    check(tag + "nothing since the last tag: it says so", h.messages[-1] == "Release: no commits since v1.3.0",
          h.messages[-1:])
    # no .nimble
    h.root = h.tmp
    run_("Release: bump the version…")
    check(tag + "no .nimble file: it says so", h.messages[-1].startswith("Release: no .nimble file in "), h.messages[-1:])
