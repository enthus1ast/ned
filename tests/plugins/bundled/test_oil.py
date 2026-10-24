"""oil: a folder as text — the listing (folders first, hidden files left out), a line changed, gone or added is a
rename, a delete (to the trash) or a new file or folder once saved and confirmed; Enter / - to go in and up."""
import os, shutil, tempfile
from tplugins import check


def mk(root, files):
    for f in files:
        p = os.path.join(root, f)
        if f.endswith("/"):
            os.makedirs(p, exist_ok=True)
        else:
            os.makedirs(os.path.dirname(p), exist_ok=True)
            open(p, "w").write("text of " + f)


def cmd(h, title):
    r = h.reg("command", title=title)
    return r["cb"] if r else None


def run(factory, tag):
    tmp = tempfile.mkdtemp(prefix="ned-oil-")
    try:
        _run(factory, tag, tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _run(factory, tag, tmp):
    proj = os.path.join(tmp, "proj")
    mk(proj, ["a.txt", "b.nim", "Readme.md", "sub/", "sub/inner.txt", ".hidden", ".git/"])
    h = factory()
    h.switch_on_new_tab = True
    h.root = proj
    h.path_ = os.path.join(proj, "b.nim")
    h.lines = ["echo 1"]
    ok = h.build_ok and h.pump(lambda j: j.get("t") == "ready", 90)
    check(tag + "it starts", ok, h.build_err if not h.build_ok else "")
    if not ok:
        return
    lang = h.reg("language", id="oil")
    check(tag + "its language: oil (the folder's tabs)", lang is not None and lang["spec"].get("name") == "Oil", lang)
    writer = h.reg("writer", lang="oil")
    check(tag + "saving a tab of it is the plugin's", writer is not None)
    check(tag + "keys in its tabs: Alt+Enter and Alt+Up, vim's Enter and -",
          h.reg("langKey", lang="oil", keys="alt+enter") and h.reg("langKey", lang="oil", keys="alt+up") and
          h.reg("vimMap", lang="oil", keys="<CR>") and h.reg("vimMap", lang="oil", keys="-"))
    check(tag + "vim: <leader>- opens the folder from anywhere (not vim's own -)",
          h.reg("vimMap", keys="<leader>-", lang="") is not None and h.reg("vimMap", keys="-", lang="") is None)
    edit = cmd(h, "Oil: edit this file's folder as text")
    check(tag + "the command is there", edit is not None)
    if edit is None or writer is None:
        return
    first = h.cur
    h.call(edit)
    oil = h.cur
    check(tag + "a tab of its own, of the language oil", oil != first and h.lang == "oil", (h.cur, h.lang))
    check(tag + "it lists the folder: folders first with a /, then the files, the hidden ones left out",
          h.lines == ["sub/", "a.txt", "b.nim", "Readme.md"], h.lines)
    check(tag + "the tab is named by the folder (ending with /)", h.title_ == proj + "/", h.title_)
    check(tag + "the cursor on the file it came from (b.nim)", h.cursor == {"line": 2, "col": 0}, h.cursor)
    check(tag + "the tab counts as saved", not h.dirty_ and oil in h.saved_ids)
    check(tag + "a folder's line has a sign", any(f == "sign" and a.get("line") == 0 for f, a in h.decor), h.decor)
    # edits: b.nim → c.nim, a.txt gone, a new folder and a new file, Readme.md moved into sub/
    h.lines = ["sub/", "c.nim", "docs/new/", "notes.md", "sub/Readme.md"]
    h.dirty_ = True
    h.answers["confirm"] = True
    h.asked = []
    h.call(writer["cb"], {"buf": oil, "path": "", "lang": "oil"})
    q = [a.get("text", "") for f, a in h.asked if f == "confirm"]
    plan = q[0] if q else ""
    check(tag + "saving: it says what will happen and asks first",
          "Rename b.nim → c.nim" in plan and "Delete a.txt (to the trash)" in plan and
          "Make docs/new/ (a folder)" in plan and "Make notes.md" in plan and "Rename Readme.md → sub/Readme.md" in plan,
          plan)
    check(tag + "b.nim renamed c.nim (its text kept)",
          not os.path.exists(os.path.join(proj, "b.nim")) and
          open(os.path.join(proj, "c.nim")).read() == "text of b.nim")
    check(tag + "Readme.md moved into sub/", os.path.isfile(os.path.join(proj, "sub", "Readme.md")) and
          not os.path.exists(os.path.join(proj, "Readme.md")))
    check(tag + "the new folder (and the folder it is in) and the new empty file",
          os.path.isdir(os.path.join(proj, "docs", "new")) and open(os.path.join(proj, "notes.md")).read() == "")
    data = os.path.join(h.tmp, "data", "oil")
    trash = os.path.join(data, "trash")
    check(tag + "a.txt is in the trash, and the trash knows where it came from",
          not os.path.exists(os.path.join(proj, "a.txt")) and os.path.isfile(os.path.join(trash, "a.txt")) and
          (os.path.join(proj, "a.txt") in open(os.path.join(trash, ".where")).read()),
          os.listdir(trash) if os.path.isdir(trash) else "no trash")
    check(tag + "the tab lists the folder again, saved",
          h.cur == oil and h.lines == ["docs/", "sub/", "c.nim", "notes.md"] and not h.dirty_, (h.lines, h.dirty_))
    # a whole rename in place (nothing alike), and two names swapped
    h.lines = ["docs/", "sub/", "main.nim", "todo.md"]
    h.asked = []
    h.call(writer["cb"], {"buf": oil, "path": "", "lang": "oil"})
    check(tag + "lines changed in place: renames, however different the names",
          open(os.path.join(proj, "main.nim")).read() == "text of b.nim" and os.path.isfile(os.path.join(proj, "todo.md"))
          and not os.path.exists(os.path.join(proj, "notes.md")), h.lines)
    open(os.path.join(proj, "todo.md"), "w").write("todo")
    h.lines = ["docs/", "sub/", "todo.md", "main.nim"]
    h.asked = []
    h.call(writer["cb"], {"buf": oil, "path": "", "lang": "oil"})
    check(tag + "a line moved is no change: nothing asked, the files as they were, the listing again",
          not h.asked and open(os.path.join(proj, "todo.md")).read() == "todo" and
          open(os.path.join(proj, "main.nim")).read() == "text of b.nim" and
          any("Nothing to change" in m for m in h.messages) and h.lines == ["docs/", "sub/", "main.nim", "todo.md"],
          (h.messages[-1:], h.lines))
    h.lines = ["docs/", "sub/", "main.nim", "todo.md", "a/b/c.txt"]
    h.call(writer["cb"], {"buf": oil, "path": "", "lang": "oil"})
    check(tag + "a new file in folders not there yet: they are made",
          os.path.isfile(os.path.join(proj, "a", "b", "c.txt")) and "a/" in h.lines, h.lines)
    # what is wrong: nothing done
    h.lines = ["a/", "docs/", "sub/", "main.nim", "main.nim"]
    h.asked = []
    h.call(writer["cb"], {"buf": oil, "path": "", "lang": "oil"})
    check(tag + "two lines of one name: it says so, asks nothing, changes nothing",
          not h.asked and any("Two lines name main.nim" in m for m in h.messages) and
          os.path.isfile(os.path.join(proj, "todo.md")), h.messages[-1:])
    h.lines = ["a/", "docs/", "sub/", "main.nim", "todo.md", "sub/inner.txt"]
    h.call(writer["cb"], {"buf": oil, "path": "", "lang": "oil"})
    check(tag + "a new line naming a file that is there: it says so",
          any("sub/inner.txt is there already" in m for m in h.messages), h.messages[-1:])
    # cancelled: nothing
    h.lines = ["a/", "docs/", "main.nim", "todo.md"]
    h.answers["confirm"] = False
    h.call(writer["cb"], {"buf": oil, "path": "", "lang": "oil"})
    check(tag + "cancelled: the folder sub/ is still there", os.path.isdir(os.path.join(proj, "sub")))
    h.answers["confirm"] = True
    # going in and up
    h.lines = ["a/", "docs/", "sub/", "main.nim", "todo.md"]
    h.dirty_ = False
    h.cursor = {"line": 2, "col": 0}
    enter = h.reg("langKey", lang="oil", keys="alt+enter")
    h.call(enter["cb"], {"buf": oil})
    check(tag + "Alt+Enter on sub/: the tab lists sub/", h.lines == ["inner.txt", "Readme.md"] and
          h.title_ == proj + "/sub/", (h.lines, h.title_))
    up = h.reg("vimMap", lang="oil", keys="-")
    h.call(up["cb"], {"count": 1})
    check(tag + "vim's - : the folder above, the cursor on sub/",
          h.title_ == proj + "/" and h.lines[h.cursor["line"]] == "sub/", (h.title_, h.cursor))
    h.cursor = {"line": 3, "col": 0}
    h.opened = []
    cr = h.reg("vimMap", lang="oil", keys="<CR>")
    h.call(cr["cb"], {"count": 1})
    check(tag + "Enter on a file opens it", h.opened and h.opened[-1][0] == os.path.join(proj, "main.nim"), h.opened)
    # hidden files
    hid = cmd(h, "Oil: show or hide hidden files")
    h.call(hid)
    check(tag + "hidden files shown when asked (.git/ with the folders, .hidden with the files)",
          ".git/" in h.lines and ".hidden" in h.lines and h.lines.index(".git/") < h.lines.index("main.nim"), h.lines)
    # the trash: its tab says where each came from
    tr = cmd(h, "Oil: open the trash")
    h.decor = []
    h.call(tr)
    check(tag + "the trash: a.txt, and where it came from after it",
          "a.txt" in h.lines and any(f == "vtext" and proj in a.get("text", "") for f, a in h.decor), (h.lines, h.decor))
    # not a folder's tab
    h.switch_to(first)
    h.messages = []
    h.call(enter["cb"], {"buf": first})
    check(tag + "Alt+Enter elsewhere: it says what the command is for", any("Not a folder" in m for m in h.messages),
          h.messages)
