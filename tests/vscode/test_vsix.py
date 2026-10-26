#!/usr/bin/env python3
"""What a .vsix of the VS Code extension holds, checked (Python 3, standard library only).

    python3 tests/vscode/test_vsix.py vscode-nedls-<version>.vsix

The OPC parts VS Code reads ([Content_Types].xml, extension.vsixmanifest) parse as XML and say what package.json
says; every asset the manifest names is in the zip; the extension's files are there — every module a shipped .js
requires too — and nothing that should not be (node_modules, a .vsix, .vscodeignore). With node on PATH each .js is
also checked for syntax. Prints PASS or FAIL for each check; exits 1 when one fails. tests/build/vscode.sh runs it.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile

NS = {"v": "http://schemas.microsoft.com/developer/vsx-schema/2011",
      "t": "http://schemas.openxmlformats.org/package/2006/content-types"}

RESULTS = []


def check(name, ok, detail=""):
    RESULTS.append(bool(ok))
    print(("PASS  " if ok else "FAIL  ") + name + ("" if ok or not detail else "  — " + str(detail)[:300]))
    return ok


def main():
    if len(sys.argv) != 2:
        print("usage: python3 tests/vscode/test_vsix.py FILE.vsix")
        sys.exit(2)
    path = sys.argv[1]
    try:
        z = zipfile.ZipFile(path)
    except (OSError, zipfile.BadZipFile) as e:
        check("the .vsix is a zip", False, e)
        sys.exit(1)
    names = z.namelist()
    check("the zip is sound (every entry's CRC)", z.testzip() is None)
    check("no entry twice", len(names) == len(set(names)), [n for n in names if names.count(n) > 1])

    want = ["[Content_Types].xml", "extension.vsixmanifest", "extension/package.json", "extension/extension.js",
            "extension/lsp.js", "extension/client.js", "extension/features.js", "extension/convert.js",
            "extension/language-configuration.json", "extension/syntaxes/nim.tmLanguage.json", "extension/README.md",
            "extension/LICENSE.txt"]
    check("the entries VS Code and the extension need", all(n in names for n in want),
          [n for n in want if n not in names])
    bad = [n for n in names if "node_modules/" in n or n.endswith(".vsix") or n.endswith(".vscodeignore")
           or (not n.startswith("extension/") and n not in ("[Content_Types].xml", "extension.vsixmanifest"))]
    check("nothing else: no node_modules, no .vsix, no .vscodeignore, all files under extension/", not bad, bad)

    pkg = json.loads(z.read("extension/package.json"))
    check("package.json: no npm dependencies", not pkg.get("dependencies") and not pkg.get("devDependencies"),
          {k: pkg.get(k) for k in ("dependencies", "devDependencies")})
    main_js = "extension/" + os.path.normpath(pkg.get("main", "")).replace(os.sep, "/")
    check("package.json's main is in the zip", main_js in names or main_js + ".js" in names, main_js)
    missing = []
    for n in names:
        if n.endswith(".js"):
            for r in re.findall(r"require\('\./([^']+)'\)", z.read(n).decode("utf-8")):
                target = os.path.normpath(os.path.join(os.path.dirname(n), r)).replace(os.sep, "/")
                if target not in names and target + ".js" not in names:
                    missing.append("%s → %s" % (n, r))
    check("every module a shipped .js requires is shipped", not missing, missing)
    js_requires = set()
    for n in names:
        if n.endswith(".js"):
            js_requires.update(re.findall(r"require\('([^'./][^']*)'\)", z.read(n).decode("utf-8")))
    builtin = {"vscode", "child_process", "fs", "path", "os", "util", "events", "stream", "url", "crypto"}
    check("no package outside Node and VS Code is required", js_requires <= builtin, sorted(js_requires - builtin))

    try:
        m = ET.fromstring(z.read("extension.vsixmanifest"))
    except ET.ParseError as e:
        check("extension.vsixmanifest parses as XML", False, e)
        sys.exit(1)
    check("extension.vsixmanifest parses as XML", m.tag == "{%s}PackageManifest" % NS["v"], m.tag)
    ident = m.find("v:Metadata/v:Identity", NS)
    check("Identity: the id, version and publisher of package.json", ident is not None and
          ident.get("Id") == pkg["name"] and ident.get("Version") == pkg["version"] and
          ident.get("Publisher") == pkg["publisher"], ident is not None and ident.attrib)
    meta = {k: (m.findtext("v:Metadata/v:" + k, None, NS) or "") for k in ("DisplayName", "Description", "Tags",
                                                                            "Categories")}
    check("DisplayName, Description, Categories as package.json says",
          meta["DisplayName"] == pkg.get("displayName") and meta["Description"] == pkg.get("description") and
          meta["Categories"].split(",") == pkg.get("categories"), meta)
    check("Tags: the keywords and the languages", all(k in meta["Tags"].split(",") for k in pkg.get("keywords", [])) and
          "__ext_nim" in meta["Tags"], meta["Tags"])
    props = {p.get("Id"): p.get("Value") for p in m.findall("v:Metadata/v:Properties/v:Property", NS)}
    check("the VS Code it needs (Engine)", props.get("Microsoft.VisualStudio.Code.Engine") == pkg["engines"]["vscode"],
          props)
    target = m.find("v:Installation/v:InstallationTarget", NS)
    check("installed into VS Code (InstallationTarget)", target is not None and
          target.get("Id") == "Microsoft.VisualStudio.Code")
    assets = {a.get("Type"): a.get("Path") for a in m.findall("v:Assets/v:Asset", NS)}
    check("assets: the manifest (package.json), the README, the licence",
          assets.get("Microsoft.VisualStudio.Code.Manifest") == "extension/package.json" and
          assets.get("Microsoft.VisualStudio.Services.Content.Details") == "extension/README.md" and
          assets.get("Microsoft.VisualStudio.Services.Content.License") == "extension/LICENSE.txt", assets)
    check("every asset is in the zip", all(p in names for p in assets.values()),
          [p for p in assets.values() if p not in names])
    check("License names the licence file", m.findtext("v:Metadata/v:License", None, NS) == "extension/LICENSE.txt")

    try:
        ct = ET.fromstring(z.read("[Content_Types].xml"))
    except ET.ParseError as e:
        check("[Content_Types].xml parses as XML", False, e)
        sys.exit(1)
    types = {d.get("Extension").lower(): d.get("ContentType") for d in ct.findall("t:Default", NS)}
    # (the content types stream itself is not a part: it has no type of its own)
    exts = {os.path.splitext(n)[1].lower() for n in names if os.path.splitext(n)[1] and n != "[Content_Types].xml"}
    check("[Content_Types].xml: a media type for every file extension in the zip",
          exts <= set(types) and types.get(".json") == "application/json" and types.get(".js") == "application/javascript",
          sorted(exts - set(types)))

    node = shutil.which("node")
    if node:
        tmp = tempfile.mkdtemp(prefix="vsix-check-")
        try:
            bad = []
            for n in names:
                if n.endswith(".js"):
                    p = os.path.join(tmp, n.replace("/", "_"))
                    with open(p, "wb") as f:
                        f.write(z.read(n))
                    r = subprocess.run([node, "--check", p], capture_output=True, text=True)
                    if r.returncode != 0:
                        bad.append(n + ": " + r.stderr.strip()[:200])
            check("node --check: every .js", not bad, bad)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    else:
        print("SKIP  node --check (no node on PATH)")

    print("\n%d passed, %d failed" % (RESULTS.count(True), RESULTS.count(False)))
    sys.exit(0 if all(RESULTS) else 1)


if __name__ == "__main__":
    main()
