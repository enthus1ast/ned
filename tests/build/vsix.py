#!/usr/bin/env python3
"""The VS Code extension as a .vsix, made with Python's zipfile alone — no npm, no @vscode/vsce.

    python3 tests/build/vsix.py editors/vscode OUT.vsix

A .vsix is a zip in the Open Packaging Conventions layout that vsce makes and VS Code installs from:

    extension.vsixmanifest   who and what: id, version, publisher, name, description, tags, categories, the VS Code
                             it needs, and its assets (package.json, the README, the licence)
    [Content_Types].xml      the media type of each file extension in the zip
    extension/…              the extension's own files, as they are in its folder

What vsce leaves out by default, and what the folder's .vscodeignore names, is left out here too. A LICENSE without
an extension goes in as extension/LICENSE.txt, as vsce puts it. tests/build/vscode.sh runs this with ned's version
checked; tests/vscode/test_vsix.py checks what comes out.
"""

import json
import os
import re
import sys
import zipfile
from xml.sax.saxutils import escape, quoteattr

# what vsce never packs (its defaultIgnore, the parts that can occur in an extension's folder)
DEFAULT_IGNORE = [
    ".vscodeignore", "package-lock.json", "npm-debug.log", "yarn.lock", "yarn-error.log", "npm-shrinkwrap.json",
    ".editorconfig", ".npmrc", ".yarnrc", ".gitattributes", "*.todo", "tslint.yaml", ".eslintrc*", ".babelrc*",
    ".prettierrc*", ".cz-config.js", ".commitlintrc*", "webpack.config.js", "ISSUE_TEMPLATE.md", "CONTRIBUTING.md",
    "PULL_REQUEST_TEMPLATE.md", "CODE_OF_CONDUCT.md", ".github", ".travis.yml", "appveyor.yml", "**/.git/**",
    "**/*.vsix", "**/.DS_Store", "**/*.vsixmanifest", "**/.vscode-test/**", "**/.vscode-test-web/**",
]

MEDIA_TYPES = {
    ".json": "application/json", ".js": "application/javascript", ".mjs": "application/javascript",
    ".cjs": "application/javascript", ".md": "text/markdown", ".txt": "text/plain", ".xml": "text/xml",
    ".vsixmanifest": "text/xml", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
    ".gif": "image/gif", ".svg": "image/svg+xml", ".css": "text/css", ".html": "text/html", ".wasm": "application/wasm",
}


def glob_regex(pattern):
    """a glob as minimatch reads it with {dot: true}: ** any folders, * and ? within one, {a,b}, [abc]"""
    out, i, group = "", 0, 0
    while i < len(pattern):
        c = pattern[i]
        if c == "*":
            if pattern[i + 1:i + 2] == "*":
                i += 1
                if pattern[i + 1:i + 2] == "/":
                    i += 1
                    out += "(?:.*/)?"
                else:
                    out += ".*"
            else:
                out += "[^/]*"
        elif c == "?":
            out += "[^/]"
        elif c == "{":
            out += "(?:"
            group += 1
        elif c == "}" and group:
            out += ")"
            group -= 1
        elif c == "," and group:
            out += "|"
        elif c == "[" and "]" in pattern[i + 2:]:
            j = pattern.index("]", i + 2)
            cls = pattern[i + 1:j].replace("\\", "\\\\")
            out += "[" + ("^" + cls[1:] if cls.startswith("!") else cls) + "]"
            i = j
        else:
            out += re.escape(c)
        i += 1
    return re.compile(out + r"\Z")


def ignore_rules(folder):
    """(ignored, re-included) patterns: vsce's own, then .vscodeignore's — a pattern that may name a folder covers
    what is in it too, as vsce reads it"""
    lines = list(DEFAULT_IGNORE)
    p = os.path.join(folder, ".vscodeignore")
    if os.path.exists(p):
        with open(p, encoding="utf-8") as f:
            lines += [ln.strip() for ln in f if ln.strip() and not ln.strip().startswith("#")]
    ignored, kept = [], []
    for ln in lines:
        neg = ln.startswith("!")
        pat = ln[1:] if neg else ln
        pat = pat.lstrip("/")
        if pat.endswith("/"):
            pat += "**"
        pats = [pat] if re.search(r"(^|/)[^/]*\*[^/]*$", pat) else [pat, pat.rstrip("/") + "/**"]
        (kept if neg else ignored).extend(glob_regex(x) for x in pats)
    return ignored, kept


def files_of(folder):
    """the extension's files to pack, relative to its folder, with / between parts, sorted"""
    ignored, kept = ignore_rules(folder)
    out = []
    for dirpath, dirnames, filenames in os.walk(folder):
        dirnames.sort()
        for n in sorted(filenames):
            rel = os.path.relpath(os.path.join(dirpath, n), folder).replace(os.sep, "/")
            if any(r.match(rel) for r in ignored) and not any(r.match(rel) for r in kept):
                continue
            out.append(rel)
    return out


def tags_of(pkg):
    """the Marketplace's tags as vsce makes them: the keywords, then what the extension contributes"""
    c = pkg.get("contributes", {})
    tags = list(pkg.get("keywords", []))
    for lang in c.get("languages", []):
        tags.append(lang.get("id"))
        tags += lang.get("aliases", [])
        tags += ["__ext_" + e.replace(".", "") for e in lang.get("extensions", [])]
    for e in pkg.get("activationEvents", []):
        if e.startswith("onLanguage:"):
            tags.append(e[len("onLanguage:"):])
    tags += [g.get("language") for g in c.get("grammars", [])]
    if c.get("snippets"):
        tags.append("snippet")
    if c.get("themes"):
        tags += ["theme", "color-theme"]
    if c.get("debuggers"):
        tags.append("debuggers")
    if c.get("jsonValidation"):
        tags.append("json")
    if c.get("keybindings"):
        tags.append("keybindings")
    seen, out = set(), []
    for t in tags:
        if t and t not in seen:
            seen.add(t)
            out.append(t)
    return out


def repository_url(pkg):
    r = pkg.get("repository")
    url = r.get("url") if isinstance(r, dict) else r
    if not url:
        return None
    url = re.sub(r"^git\+", "", url)
    m = re.match(r"^(?:github:)?([\w.-]+)/([\w.-]+)$", url)
    return "https://github.com/%s/%s" % m.groups() if m else url


def manifest(pkg, assets, license_path, icon_path):
    """extension.vsixmanifest, laid out as vsce's template lays it out"""
    a = quoteattr
    repo = repository_url(pkg)
    github = repo if repo and "github.com" in repo else None
    plain = repo[:-4] if github and repo.endswith(".git") else repo
    bugs = pkg.get("bugs", {})
    bugs = bugs.get("url") if isinstance(bugs, dict) else bugs
    if not bugs and github:
        bugs = plain + "/issues"
    homepage = pkg.get("homepage") or (plain + "#readme" if github else None)
    kind = pkg.get("extensionKind") or (["workspace"] if pkg.get("main") else ["ui", "workspace"])
    props = [
        ("Microsoft.VisualStudio.Code.Engine", pkg["engines"]["vscode"]),
        ("Microsoft.VisualStudio.Code.ExtensionDependencies", ",".join(pkg.get("extensionDependencies", []))),
        ("Microsoft.VisualStudio.Code.ExtensionPack", ",".join(pkg.get("extensionPack", []))),
        ("Microsoft.VisualStudio.Code.ExtensionKind", ",".join(kind if isinstance(kind, list) else [kind])),
        ("Microsoft.VisualStudio.Code.LocalizedLanguages", ""),
        ("Microsoft.VisualStudio.Code.EnabledApiProposals", ",".join(pkg.get("enabledApiProposals", []))),
    ]
    if pkg.get("main") or pkg.get("browser"):
        props.append(("Microsoft.VisualStudio.Code.ExecutesCode", "true"))
    if repo:
        props += [("Microsoft.VisualStudio.Services.Links.Source", repo),
                  ("Microsoft.VisualStudio.Services.Links.Getstarted", repo),
                  ("Microsoft.VisualStudio.Services.Links.GitHub" if github
                   else "Microsoft.VisualStudio.Services.Links.Repository", repo)]
    if bugs:
        props.append(("Microsoft.VisualStudio.Services.Links.Support", bugs))
    if homepage:
        props.append(("Microsoft.VisualStudio.Services.Links.Learn", homepage))
    props += [("Microsoft.VisualStudio.Services.GitHubFlavoredMarkdown",
               "false" if pkg.get("markdown") == "standard" else "true"),
              ("Microsoft.VisualStudio.Services.Content.Pricing", pkg.get("pricing", "Free"))]
    flags = "Public Preview" if pkg.get("preview") else "Public"
    lines = [
        '<?xml version="1.0" encoding="utf-8"?>',
        '<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011" '
        'xmlns:d="http://schemas.microsoft.com/developer/vsx-schema-design/2011">',
        "  <Metadata>",
        '    <Identity Language="en-US" Id=%s Version=%s Publisher=%s />' % (
            a(pkg["name"]), a(pkg["version"]), a(pkg["publisher"])),
        "    <DisplayName>%s</DisplayName>" % escape(pkg.get("displayName") or pkg["name"]),
        '    <Description xml:space="preserve">%s</Description>' % escape(pkg.get("description", "")),
        "    <Tags>%s</Tags>" % escape(",".join(tags_of(pkg))),
        "    <Categories>%s</Categories>" % escape(",".join(pkg.get("categories", []))),
        "    <GalleryFlags>%s</GalleryFlags>" % flags,
        "    <Properties>",
    ]
    lines += ['      <Property Id=%s Value=%s />' % (a(k), a(v)) for k, v in props]
    lines.append("    </Properties>")
    if license_path:
        lines.append("    <License>%s</License>" % escape(license_path))
    if icon_path:
        lines.append("    <Icon>%s</Icon>" % escape(icon_path))
    lines += [
        "  </Metadata>",
        "  <Installation>",
        '    <InstallationTarget Id="Microsoft.VisualStudio.Code"/>',
        "  </Installation>",
        "  <Dependencies/>",
        "  <Assets>",
        '    <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true" />',
    ]
    lines += ['    <Asset Type=%s Path=%s Addressable="true" />' % (a(t), a(p)) for t, p in assets]
    lines += ["  </Assets>", "</PackageManifest>", ""]
    return "\n".join(lines)


def content_types(names):
    exts = {".vsixmanifest": "text/xml"}
    for n in names:
        e = os.path.splitext(n)[1].lower()
        if e and e not in exts:
            exts[e] = MEDIA_TYPES.get(e, "application/octet-stream")
    return ('<?xml version="1.0" encoding="utf-8"?>\n'
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
            "".join("<Default Extension=%s ContentType=%s/>" % (quoteattr(e), quoteattr(t)) for e, t in exts.items()) +
            "</Types>\n")


def fail(msg):
    print("vsix.py: " + msg, file=sys.stderr)
    sys.exit(1)


def build(folder, out):
    with open(os.path.join(folder, "package.json"), encoding="utf-8") as f:
        pkg = json.load(f)
    for k in ("name", "publisher", "version"):
        if not pkg.get(k):
            fail("package.json has no %s" % k)
    if not pkg.get("engines", {}).get("vscode"):
        fail("package.json has no engines.vscode")
    if pkg.get("dependencies"):
        fail("package.json has dependencies: this packs no node_modules (the extension needs none)")
    files = files_of(folder)
    main = pkg.get("main")
    if main:
        m = os.path.normpath(main).replace(os.sep, "/")
        if m not in files and m + ".js" not in files:
            fail("package.json's main (%s) is not among the files" % main)
    # (where each file goes in the zip: under extension/, a LICENSE given .txt)
    entries = []
    assets = []
    license_path = icon_path = None
    for rel in files:
        arc = "extension/" + rel
        if license_path is None and re.match(r"^licen[cs]e(\.(md|txt))?$", rel, re.I):
            if not os.path.splitext(rel)[1]:
                arc += ".txt"
            license_path = arc
            assets.append(("Microsoft.VisualStudio.Services.Content.License", arc))
        elif re.match(r"^readme\.md$", rel, re.I):
            assets.append(("Microsoft.VisualStudio.Services.Content.Details", arc))
        elif re.match(r"^changelog\.md$", rel, re.I):
            assets.append(("Microsoft.VisualStudio.Services.Content.Changelog", arc))
        if pkg.get("icon") and rel == os.path.normpath(pkg["icon"]).replace(os.sep, "/"):
            icon_path = arc
            assets.append(("Microsoft.VisualStudio.Services.Icons.Default", arc))
        entries.append((rel, arc))
    tmp = out + ".tmp"
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("extension.vsixmanifest", manifest(pkg, assets, license_path, icon_path))
        z.writestr("[Content_Types].xml", content_types([a for _, a in entries]))
        for rel, arc in entries:
            z.write(os.path.join(folder, rel), arc)
    os.replace(tmp, out)
    print("%s: %s %s, %d files" % (out, pkg["name"], pkg["version"], len(entries)))


def main():
    if len(sys.argv) != 3:
        print(__doc__.strip().split("\n\n")[1] if "\n\n" in __doc__ else __doc__)
        sys.exit(2)
    build(sys.argv[1], sys.argv[2])


if __name__ == "__main__":
    main()
