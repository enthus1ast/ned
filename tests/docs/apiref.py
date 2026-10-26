#!/usr/bin/env python3
"""The plugin API reference (docs/plugins/api.md) made from the `##` docs of the API's two modules —
src/ned/plugins/lib/nedplugin.nim and nedlsp.nim — so it is never out of date.

  python3 tests/docs/apiref.py            write docs/plugins/api.md
  python3 tests/docs/apiref.py --check    exit 1 when docs/plugins/api.md is not what the sources make (CI)

What a `##` doc may hold (the same text shows in ned's hover):

  - paragraphs: lines one after another are one paragraph; an empty `##` line ends it
  - a list: lines that start with `- ` (a line indented by two spaces goes on with the item above)
  - an example: lines indented by four spaces after an empty `##` line — a ```nim block in the page
"""
import os, re, sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LIB = os.path.join(REPO, "src", "ned", "plugins", "lib")
OUT = os.path.join(REPO, "docs", "plugins", "api.md")
ROUTINE = re.compile(r"^(proc|func|template|macro|iterator|converter)\s+(`[^`]+`|[A-Za-z_][A-Za-z0-9_]*)\*")
TYPEDEF = re.compile(r"^  ([A-Z][A-Za-z0-9_]*)\*\s*=\s*(.*)$")
TYPELINE = re.compile(r"^type\s+([A-Z][A-Za-z0-9_]*)\*\s*=\s*(.*)$")      # (type X* = object, on one line)
FIELD = re.compile(r"^(\s+)([a-z][A-Za-z0-9_]*\*(?:\s*,\s*[a-z][A-Za-z0-9_]*\*)*)\s*:\s*([^#]+?)\s*(?:##\s*(.*))?$")
VARDEF = re.compile(r"^  ([A-Za-z_][A-Za-z0-9_]*)\*\s*(?::\s*([^=#]+?))?\s*(?:=\s*([^#]+?))?\s*(?:##\s*(.*))?$")
SECTION = re.compile(r"^# ── (.+?) ──\s*$")
HIDDEN = ("nedRun", "api", "curPlugin")      # (what ned's own host uses: not for plugins)


def slug(s):
    s = s.lower()
    out = ""
    for ch in s:
        if ch.isalnum() or ch in "-_":
            out += ch
        elif ch == " ":
            out += "-"
    return out


def doc_line(src):
    """a source line's `##` doc: what follows `## ` — its own indentation kept (an example's four spaces)"""
    t = src.strip()[2:]
    return t[1:] if t.startswith(" ") else t


def doc_md(lines):
    """`##` doc lines → Markdown: paragraphs joined into one line each, `- ` items, four-space examples as ```nim"""
    out = []            # blocks: ("p", text) ("li", text) ("code", [lines])
    para = None
    i = 0
    while i < len(lines):
        l = lines[i]
        if l.strip() == "":
            para = None
            i += 1
            continue
        if l.startswith("    ") and (para is None or para[0] == "code"):
            # an example: this line and the ones after it that are indented (or blank between them)
            code = []
            while i < len(lines) and (lines[i].startswith("    ") or lines[i].strip() == ""):
                code.append(lines[i][4:])
                i += 1
            while code and code[-1].strip() == "":
                code.pop()
            out.append(("code", code))
            para = None
            continue
        if l.startswith("- "):
            para = ["li", l[2:].strip()]
            out.append(para)
        elif para is not None and para[0] == "li" and l.startswith("  "):
            para[1] += " " + l.strip()
        elif para is not None and para[0] == "p":
            para[1] += " " + l.strip()
        else:
            para = ["p", l.strip()]
            out.append(para)
        i += 1
    parts = []
    for b in out:
        if b[0] == "code":
            parts.append("```nim\n" + "\n".join(b[1]) + "\n```")
        elif b[0] == "li" and parts and parts[-1].startswith("- "):
            parts[-1] += "\n- " + b[1]
        elif b[0] == "li":
            parts.append("- " + b[1])
        else:
            parts.append(b[1])
    return "\n\n".join(parts)


def parse_type(lines, i, name, rhs, field_ind):
    """a type's doc and its fields (each with its doc: a `##` on its line, and `##` lines under it at that column)"""
    doc = []
    if "##" in rhs:
        rhs, d = rhs.split("##", 1)
        doc.append(d.strip())
    rhs = rhs.strip()
    fields = []
    j = i + 1
    while j < len(lines) and (lines[j].startswith(" " * field_ind) or lines[j].strip() == ""):
        t = lines[j]
        if t.strip() == "":
            break
        ind = len(t) - len(t.lstrip())
        if t.strip().startswith("##"):
            if ind > field_ind and fields:
                fields[-1][2] = (fields[-1][2] + " " + doc_line(t).strip()).strip()   # (the field's doc goes on)
            else:
                doc.append(doc_line(t))
        else:
            fm = FIELD.match(t)
            if fm and len(fm.group(1)) == field_ind:
                fields.append([fm.group(2).replace("*", ""), fm.group(3).strip(), (fm.group(4) or "").strip()])
        j += 1
    return j, ("type", name, "type " + name + " = " + rhs, doc_md(doc), [tuple(f) for f in fields])


def parse(path):
    lines = open(path, encoding="utf-8").read().split("\n")
    intro = []
    i = 0
    while i < len(lines) and lines[i].startswith("##"):
        intro.append(lines[i][2:][1:] if lines[i].startswith("## ") else lines[i][2:])
        i += 1
    sections = [("", [])]          # (title, items)
    in_type = False
    in_var = False
    while i < len(lines):
        l = lines[i]
        m = SECTION.match(l)
        if m:
            sections.append((m.group(1), []))
            in_type = in_var = False
            i += 1
            continue
        m = TYPELINE.match(l)
        if m:
            i, item = parse_type(lines, i, m.group(1), m.group(2), 2)
            sections[-1][1].append(item)
            in_type = in_var = False
            continue
        if l.strip() == "type":
            in_type, in_var = True, False
            i += 1
            continue
        if l.strip() == "var":
            in_var, in_type = True, False
            i += 1
            continue
        if in_type:
            m = TYPEDEF.match(l)
            if m:
                i, item = parse_type(lines, i, m.group(1), m.group(2), 4)
                sections[-1][1].append(item)
                continue
            if l and not l.startswith(" "):
                in_type = False
            else:
                i += 1
                continue
        if in_var:
            m = VARDEF.match(l)
            if m:
                name = m.group(1)
                typ = (m.group(2) or "").strip()
                val = (m.group(3) or "").strip()
                doc = [m.group(4).strip()] if m.group(4) else []
                j = i + 1
                while j < len(lines) and lines[j].strip().startswith("##") and lines[j].startswith("   "):
                    doc.append(doc_line(lines[j]))
                    j += 1
                if name not in HIDDEN:
                    decl = "var " + name + (": " + typ if typ else "") + (" = " + val if val else "")
                    sections[-1][1].append(("var", name, decl, doc_md(doc), []))
                i = j
                continue
            if l and not l.startswith(" "):
                in_var = False
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
                doc.append(doc_line(lines[j]))
                j += 1
            d = doc_md(doc)
            if not d.startswith("(what ") and name not in HIDDEN:
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
             "file: change the docs in the sources). New to plugins? Start with the [tutorial](tutorial.md); "
             "[Plugins](README.md) says what plugins can do, area by area, and the [cookbook](cookbook.md) has a "
             "whole plugin for each. In ned, *Plugins: the API* opens the source, and hover and completion know "
             "every name.", ""]
    mods = [("nedplugin", "what a plugin imports"), ("nedlsp", "a language server written in NimScript")]
    parsed = []
    for mod, what in mods:
        intro, secs = parse(os.path.join(LIB, mod + ".nim"))
        # (the types at the top of nedplugin, before its first section: a section of their own)
        if mod == "nedplugin" and secs and not secs[0][0]:
            secs[0] = ("the basic types", secs[0][1])
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
                parts.append({"type": "#### type `%s`", "var": "#### var `%s`"}.get(kind, "#### `%s`") % name)
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
