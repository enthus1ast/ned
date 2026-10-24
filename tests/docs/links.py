#!/usr/bin/env python3
"""Every relative link in the Markdown files (README, CHANGELOG, docs/, tests/) goes to a file that exists — and,
with a #fragment, to a heading it has (GitHub's anchors). Exit 1 and name the broken ones otherwise.

  python3 tests/docs/links.py
"""
import os, re, sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LINK = re.compile(r"\]\(([^)\s]+)\)")
HEAD = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")


def slug(h):
    h = h.replace("`", "")
    h = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", h)       # (a link in a heading: its text)
    out = ""
    for ch in h.lower():
        if ch.isalnum() or ch in "-_":
            out += ch
        elif ch == " ":
            out += "-"
    return out


def anchors(path, cache={}):
    if path not in cache:
        found = set()
        counts = {}
        code = False
        for l in open(path, encoding="utf-8", errors="replace"):
            if l.strip().startswith("```"):
                code = not code
                continue
            if code:
                continue
            m = HEAD.match(l.rstrip("\n"))
            if m:
                s = slug(m.group(2))
                n = counts.get(s, 0)
                counts[s] = n + 1
                found.add(s if n == 0 else "%s-%d" % (s, n))
        cache[path] = found
    return cache[path]


def files():
    for top in ["README.md", "CHANGELOG.md", "CONTRIBUTING.md", "SECURITY.md"]:
        p = os.path.join(REPO, top)
        if os.path.exists(p):
            yield p
    for d in ["docs", "tests", "examples"]:
        for root, _, names in os.walk(os.path.join(REPO, d)):
            for n in names:
                if n.endswith(".md"):
                    yield os.path.join(root, n)


bad = []
for f in files():
    code = False
    for i, l in enumerate(open(f, encoding="utf-8", errors="replace"), 1):
        if l.strip().startswith("```"):
            code = not code
            continue
        if code:
            continue
        for m in LINK.finditer(l):
            t = m.group(1)
            if re.match(r"^[a-z]+:", t) or t.startswith("<"):
                continue                        # (http:, mailto: …)
            path, _, frag = t.partition("#")
            target = os.path.normpath(os.path.join(os.path.dirname(f), path)) if path else f
            if not os.path.exists(target):
                bad.append("%s:%d: %s — no such file" % (os.path.relpath(f, REPO), i, t))
                continue
            if frag and target.endswith(".md") and frag not in anchors(target):
                bad.append("%s:%d: %s — no such heading in %s" % (os.path.relpath(f, REPO), i, t,
                                                                 os.path.relpath(target, REPO)))
for b in bad:
    print(b)
print("%d broken links" % len(bad) if bad else "every link goes somewhere")
sys.exit(1 if bad else 0)
