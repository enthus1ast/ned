#!/usr/bin/env python3
"""The plugin API reference (docs/plugins/api.md) made from the `##` docs of the API's two modules —
src/ned/plugins/lib/nedplugin.nim and nedlsp.nim — so it is never out of date.

  python3 tests/docs/apiref.py            write docs/plugins/api.md
  python3 tests/docs/apiref.py --check    exit 1 when docs/plugins/api.md is not what the sources make (CI)
"""
import os, re, sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LIB = os.path.join(REPO, "src", "ned", "plugins", "lib")
OUT = os.path.join(REPO, "docs", "plugins", "api.md")
ROUTINE = re.compile(r"^(proc|func|template|macro|iterator|converter)\s+(`[^`]+`|[A-Za-z_][A-Za-z0-9_]*)\*")
TYPEDEF = re.compile(r"^  ([A-Z][A-Za-z0-9_]*)\*\s*=\s*(.*)$")
FIELD = re.compile(r"^    ([a-z][A-Za-z0-9_]*\*(?:\s*,\s*[a-z][A-Za-z0-9_]*\*)*)\s*:\s*([^#]+?)\s*(?:##\s*(.*))?$")
SECTION = re.compile(r"^# ── (.+?) ──\s*$")


def slug(s):
    s = s.lower()
    out = ""
    for ch in s:
        if ch.isalnum() or ch in "-_":
            out += ch
        elif ch == " ":
            out += "-"
    return out


def parse(path):
    lines = open(path, encoding="utf-8").read().split("\n")
    intro = []
    i = 0
    while i < len(lines) and lines[i].startswith("##"):
        intro.append(lines[i][2:][1:] if lines[i].startswith("## ") else lines[i][2:])
        i += 1
    sections = [("", [])]          # (title, items)
    in_type = False
    while i < len(lines):
        l = lines[i]
        m = SECTION.match(l)
        if m:
            sections.append((m.group(1), []))
            in_type = False
            i += 1
            continue
        if l.startswith("type"):
            in_type = True
            i += 1
            continue
        if in_type:
            m = TYPEDEF.match(l)
            if m:
                name = m.group(1)
                rhs = m.group(2)
                doc = []
                if "##" in rhs:
                    rhs, d = rhs.split("##", 1)
                    doc.append(d.strip())
                rhs = rhs.strip()
                fields = []
                j = i + 1
                while j < len(lines) and (lines[j].startswith("    ") or lines[j].strip() == ""):
                    t = lines[j]
                    if t.strip().startswith("##"):
                        doc.append(t.strip()[2:].strip())
                    else:
                        fm = FIELD.match(t)
                        if fm:
                            fields.append((fm.group(1).replace("*", ""), fm.group(2).strip(), (fm.group(3) or "").strip()))
                    if lines[j].strip() == "":
                        break
                    j += 1
                sections[-1][1].append(("type", name, "type " + name + " = " + rhs, " ".join(doc), fields))
                i = j
                continue
            if l and not l.startswith(" "):
                in_type = False
            else:
                i += 1
                continue
        m = ROUTINE.match(l)
        if m:
            kind, name = m.group(1), m.group(2)
            sig = [l]
            j = i
            # the signature goes on to the line ending in `=` (or the one-liner's `= body`)
            while not re.search(r"\)\s*(:[^=]*)?=\s*$|=\s*$", sig[-1]) and " = " not in sig[-1] and j + 1 < len(lines):
                if lines[j + 1].strip().startswith("##") or not lines[j + 1].startswith(" "):
                    break
                j += 1
                sig.append(lines[j])
            text = " ".join(s.strip() for s in sig)
            # the declaration without its body
            depth = 0
            cut = len(text)
            k = 0
            while k < len(text):
                c = text[k]
                if c in "([":
                    depth += 1
                elif c in ")]":
                    depth -= 1
                elif c == "=" and depth == 0 and k > 0 and text[k - 1] == " " and (k + 1 == len(text) or text[k + 1] == " "):
                    cut = k
                    break
                k += 1
            decl = re.sub(r"^(\w+\s+(?:`[^`]+`|[A-Za-z_][A-Za-z0-9_]*))\*", r"\1", text[:cut].strip())
            doc = []
            j += 1
            while j < len(lines) and lines[j].strip().startswith("##"):
                doc.append(lines[j].strip()[2:].strip())
                j += 1
            d = " ".join(doc)
            if not d.startswith("(what ") and name not in ("nedRun", "api"):
                sections[-1][1].append((kind, name.strip("`"), decl, d, []))
            i = j
            continue
        i += 1
    return intro, [s for s in sections if s[1]]


def md(intro):
    """the module's ## doc as Markdown: its ```nim blocks kept"""
    out, code = [], False
    for l in intro:
        if l.strip().startswith("```"):
            code = not code
        out.append(l)
    return "\n".join(out).strip()


def render():
    parts = ["# Plugin API reference", "",
             "Every type and proc a plugin can use, with what it does — made from the `##` docs of "
             "[`nedplugin.nim`](../../src/ned/plugins/lib/nedplugin.nim) and "
             "[`nedlsp.nim`](../../src/ned/plugins/lib/nedlsp.nim) by `tests/docs/apiref.py` (do not edit this "
             "file: change the docs in the sources). New to plugins? Start with the [tutorial](tutorial.md). "
             "In ned, *Plugins: the API* opens the source, and hover and completion know every name.", ""]
    mods = [("nedplugin", "what a plugin imports"), ("nedlsp", "a language server written in NimScript")]
    parsed = []
    for mod, what in mods:
        intro, secs = parse(os.path.join(LIB, mod + ".nim"))
        parsed.append((mod, what, intro, secs))
    parts.append("**Contents**")
    parts.append("")
    for mod, what, intro, secs in parsed:
        parts.append("- [`%s`](#%s) — %s" % (mod, slug(mod), what))
        for title, items in secs:
            if title:
                parts.append("  - [%s](#%s)" % (title, slug(title)))
    parts.append("")
    for mod, what, intro, secs in parsed:
        parts += ["## " + mod, "", md(intro), ""]
        for title, items in secs:
            if title:
                parts += ["### " + title, ""]
            for kind, name, decl, doc, fields in items:
                parts.append("#### `%s`" % name if kind != "type" else "#### type `%s`" % name)
                parts.append("")
                parts.append("```nim")
                parts.append(decl)
                parts.append("```")
                parts.append("")
                if doc:
                    parts.append(doc)
                    parts.append("")
                if fields:
                    parts.append("| field | type | |")
                    parts.append("|---|---|---|")
                    for fn, ft, fd in fields:
                        parts.append("| `%s` | `%s` | %s |" % (fn, ft.replace("|", "\\|"), fd.replace("|", "\\|")))
                    parts.append("")
    return "\n".join(parts).rstrip() + "\n"


def main():
    text = render()
    if "--check" in sys.argv:
        cur = open(OUT, encoding="utf-8").read() if os.path.exists(OUT) else ""
        if cur != text:
            print("docs/plugins/api.md is out of date — run: python3 tests/docs/apiref.py")
            sys.exit(1)
        print("docs/plugins/api.md is up to date")
        return
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    open(OUT, "w", encoding="utf-8").write(text)
    print("wrote", os.path.relpath(OUT, REPO))


main()
