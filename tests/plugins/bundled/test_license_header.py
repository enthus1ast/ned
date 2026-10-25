"""license-header: the licence read from LICENSE, the holder from git, the header in the file's own comments (after a
#! line), a file with one left alone, every file of the project (asked first), the list of those without"""
import os, subprocess, time
from tplugins import check

MIT = "MIT License\n\nCopyright (c) 2026 X\n\nPermission is hereby granted, free of charge, to any person obtaining a copy\n"
APACHE = "                                 Apache License\n                           Version 2.0, January 2004\n"


def pos(l, c):
    return {"line": l, "col": c}


def run(factory, tag):
    h = factory()
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return
    ok = h.pump(lambda j: j.get("t") == "ready", 60)
    check(tag + "it starts", ok)
    if not ok:
        return
    one = h.reg("command", title="License: add the header to this file")
    every = h.reg("command", title="License: add the header to every file of the project")
    lst = h.reg("command", title="License: the files without a header")
    check(tag + "its commands", one and every and lst)
    if not (one and every and lst):
        return
    root = os.path.join(h.tmp, "proj")
    os.makedirs(os.path.join(root, "src"), exist_ok=True)
    h.root = root
    open(os.path.join(root, "LICENSE"), "w").write(MIT)
    h.settings["holder"] = "Ada Lovelace"
    year = time.strftime("%Y")
    # a Nim file (# comments) with a #! line
    h.lang = "nim"
    h.comment = "#"
    h.path_ = os.path.join(root, "src", "app.nim")
    h.lines = ["#!/usr/bin/env -S nim r", "echo 1"]
    h.call(one["cb"])
    check(tag + "this file: after its #! line, in # comments, MIT from LICENSE, the holder, this year",
          h.lines == ["#!/usr/bin/env -S nim r", "# Copyright (c) %s Ada Lovelace" % year,
                      "# SPDX-License-Identifier: MIT", "", "echo 1"], h.lines)
    h.messages = []
    h.call(one["cb"])
    check(tag + "a file with a header: left alone, said", len(h.lines) == 5 and
          any("has a header already" in m for m in h.messages), h.messages)
    # C (// comments), HTML (<!-- -->), CSS (/* */)
    h.lang, h.comment, h.path_, h.lines = "c", "//", os.path.join(root, "a.c"), ["int x;"]
    h.call(one["cb"])
    check(tag + "C: // comments", h.lines[:2] == ["// Copyright (c) %s Ada Lovelace" % year,
                                                  "// SPDX-License-Identifier: MIT"], h.lines)
    h.lang, h.comment, h.path_, h.lines = "html", "", os.path.join(root, "a.html"), ["<!doctype html>", "<p>x</p>"]
    h.call(one["cb"])
    check(tag + "HTML: after the doctype, in <!-- -->", h.lines[1].startswith("<!-- Copyright (c)") and
          h.lines[2].strip() == "SPDX-License-Identifier: MIT -->", h.lines)
    h.lang, h.comment, h.path_, h.lines = "css", "", os.path.join(root, "a.css"), ["a { }"]
    h.call(one["cb"])
    check(tag + "CSS: /* */", h.lines[0].startswith("/* Copyright") and h.lines[1].endswith("*/"), h.lines)
    # the licence from another LICENSE; the setting wins
    open(os.path.join(root, "LICENSE"), "w").write(APACHE)
    h.lang, h.comment, h.path_, h.lines = "nim", "#", os.path.join(root, "b.nim"), ["echo 2"]
    h.call(one["cb"])
    check(tag + "Apache-2.0 read from its LICENSE", h.lines[1] == "# SPDX-License-Identifier: Apache-2.0", h.lines)
    h.settings["license"] = "MPL-2.0"
    h.lines = ["echo 3"]
    h.call(one["cb"])
    check(tag + "plugins.license-header.license wins", h.lines[1] == "# SPDX-License-Identifier: MPL-2.0", h.lines)
    # every file of the project git knows: asked first; one with a header left alone
    env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@e", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@e")
    open(os.path.join(root, "src", "a.nim"), "w").write("echo 1\n")
    open(os.path.join(root, "src", "b.py"), "w").write("#!/usr/bin/env python3\nprint(1)\n")
    open(os.path.join(root, "src", "c.js"), "w").write("// Copyright (c) 2020 Old\nlet x\n")
    open(os.path.join(root, "notes.txt"), "w").write("not source\n")
    subprocess.run(["git", "init", "-q"], cwd=root, env=env)
    subprocess.run(["git", "add", "-A"], cwd=root, env=env)
    h.output = []
    h.call(lst["cb"])
    out = "\n".join(h.output)
    check(tag + "the files without a header: listed (not one that has one, not a .txt)",
          "src/a.nim" in out and "src/b.py" in out and "src/c.js" not in out and "notes.txt" not in out, out)
    h.answers["confirm"] = True
    h.asked = []
    h.call(every["cb"])
    conf = [a for f, a in h.asked if f == "confirm"]
    a = open(os.path.join(root, "src", "a.nim")).read()
    b = open(os.path.join(root, "src", "b.py")).read()
    c = open(os.path.join(root, "src", "c.js")).read()
    check(tag + "every file: asked first (2 files), each in its comments, after a #!, others left alone",
          conf and "2 files" in conf[0].get("text", "") and a.startswith("# Copyright (c) %s Ada" % year) and
          b.startswith("#!/usr/bin/env python3\n# Copyright") and c.startswith("// Copyright (c) 2020 Old"),
          (conf, a[:60], b[:80]))
