"""license-audit: the project's .nimble read (its licence, its requires in their forms — versions, URLs, several on a
line, nim left out); each dependency found where it is installed (Atlas's deps/, nimble's pkgs2 — the newest —, pkgs)
with its version and licence, and theirs in turn; the table in a Markdown tab, copyleft under a permissive project,
no licence and not installed marked; no .nimble said plainly."""
import os
from tplugins import check


def nimble(d, name, version, license, requires=()):
    os.makedirs(d, exist_ok=True)
    reqs = "".join('requires "%s"\n' % r for r in requires)
    open(os.path.join(d, name + ".nimble"), "w").write(
        '# Package\n\nversion       = "%s"\nauthor        = "x"\ndescription   = "x"\nlicense       = "%s"\n\n%s' %
        (version, license, reqs))


def run(factory, tag):
    h = factory()
    root = h.root
    nd = os.path.join(h.tmp, "nimblehome")
    open(os.path.join(root, "app.nimble"), "w").write(
        '# Package\nversion = "1.0.0"\nlicense = "MIT"\nsrcDir = "src"\n\n'
        'requires "nim >= 2.0.0", "jsony >= 1.1"\nrequires "https://github.com/treeform/pixie.git#head"\n'
        'requires("results")\nrequires "ghost ~= 0.1"\n')
    nimble(os.path.join(nd, "pkgs2", "jsony-1.1.3-aaaa"), "jsony", "1.1.3", "MIT")
    nimble(os.path.join(nd, "pkgs2", "pixie-5.0.6-bbbb"), "pixie", "5.0.6", "MIT", ["vmath >= 2.0", "zippy"])
    nimble(os.path.join(nd, "pkgs2", "pixie-5.0.10-cccc"), "pixie", "5.0.10", "MIT", ["vmath >= 2.0", "zippy"])
    nimble(os.path.join(nd, "pkgs", "vmath-2.0.0"), "vmath", "2.0.0", "")
    nimble(os.path.join(nd, "pkgs2", "zippy-0.10.16-dddd"), "zippy", "0.10.16", "GPL-3.0-only")
    nimble(os.path.join(root, "deps", "results"), "results", "0.5.1", "Apache-2.0 OR MIT")
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return
    if not h.pump(lambda j: j.get("t") == "ready", 90):
        h.p.kill()
        check(tag + "it starts", False, h.p.stderr.read()[-1500:])
        return
    check(tag + "it starts (%s ms)" % h.ready_ms, True)
    h.settings = {"nimbleDir": nd}
    h.call(h.reg("command", title="Licences: check the dependencies")["cb"])
    tab = h.tabs[-1] if h.tabs else ("", "", "")
    rows = {l.split("|")[1].strip(): [c.strip() for c in l.split("|")[2:-1]] for l in tab[1].split("\n")
            if l.startswith("| ") and not l.startswith("| package")}
    check(tag + "a Markdown tab: the project's licence and how many packages",
          tab[0] == "Licences" and tab[2] == "markdown" and "This project: **MIT** · 6 packages" in tab[1], tab[1][:300])
    check(tag + "each one found where it is: its version and licence, who requires it; pkgs2's newest (5.0.10 over "
          "5.0.6), pkgs, Atlas's deps/; a URL's name; nim left out",
          rows.get("jsony", [])[:3] == ["1.1.3", "MIT", "the project"] and
          rows.get("pixie", [])[:3] == ["5.0.10", "MIT", "the project"] and
          rows.get("results", [])[:3] == ["0.5.1", "Apache-2.0 OR MIT", "the project"] and
          rows.get("vmath", [])[:3] == ["2.0.0", "—", "pixie"] and rows.get("zippy", [])[:3] == ["0.10.16", "GPL-3.0-only", "pixie"]
          and "nim" not in rows, rows)
    check(tag + "marked: copyleft under MIT, no licence given, not installed",
          rows.get("zippy", ["", "", "", ""])[3].startswith("⚠ copyleft, under a MIT") and
          rows.get("vmath", ["", "", "", ""])[3] == "? no licence given" and
          rows.get("ghost", ["", "", "", ""])[3] == "? not installed — `nimble install ghost`" and
          h.messages[-1] == "Licences: 3 to look at — the table is in its tab", (rows, h.messages[-1:]))
    os.remove(os.path.join(root, "app.nimble"))
    h.call(h.reg("command", title="Licences: check the dependencies")["cb"])
    check(tag + "no .nimble: it says so", h.messages[-1] == "Licences: no .nimble file in the project's folder",
          h.messages[-1:])
