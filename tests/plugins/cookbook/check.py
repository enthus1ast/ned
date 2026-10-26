#!/usr/bin/env python3
"""The plugin cookbook — docs/plugins/cookbook.md — and its plugins, the .nims files of this folder: each plugin
compiles (as NimScript, as ned runs it with `nim e`, and as Nim, as `plugins.native` compiles it), and the page
shows each file whole, the same text as here, so the two never drift apart.

  python3 tests/plugins/cookbook/check.py          (nim on PATH)
  python3 tests/plugins/cookbook/check.py --run    … and each plugin started in the plugin host, as ned starts it

On the page, each plugin is a ```nim block right after a line `<!-- file: NAME.nims -->`. A change to a plugin
goes in both places: the file here and its block on the page.
"""
import json, os, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
LIB = os.path.join(REPO, "src", "ned", "plugins", "lib")
PAGE = os.path.join(REPO, "docs", "plugins", "cookbook.md")
MARK = re.compile(r"^<!-- file: ([A-Za-z0-9_]+\.nims) -->\s*$")
SERVERS = ["lsp_server.nims"]                 # (language servers: nedlsp, not the plugin host)
failed = []


def check(name, ok, info=""):
    print(("PASS  " if ok else "FAIL  ") + name + ("" if ok else "\n      " + str(info).strip()[:1500].replace("\n", "\n      ")),
          flush=True)
    if not ok:
        failed.append(name)


def nim_check(path):
    r = subprocess.run(["nim", "check", "--hints:off", "--path:" + LIB, path], capture_output=True, text=True)
    out = (r.stdout + r.stderr).strip()
    return r.returncode == 0 and "Error:" not in out, out


def page_blocks():
    """the page's plugins: file name → the text of its ```nim block"""
    blocks, dup = {}, []
    lines = open(PAGE, encoding="utf-8").read().split("\n")
    i = 0
    while i < len(lines):
        m = MARK.match(lines[i])
        if not m:
            i += 1
            continue
        name = m.group(1)
        j = i + 1
        while j < len(lines) and lines[j].strip() == "":
            j += 1
        if j >= len(lines) or lines[j].strip() != "```nim":
            blocks[name] = None                   # (no ```nim block after the mark)
            i = j
            continue
        k = j + 1
        while k < len(lines) and lines[k].strip() != "```":
            k += 1
        if name in blocks:
            dup.append(name)
        blocks[name] = "\n".join(lines[j + 1:k]) + "\n"
        i = k + 1
    return blocks, dup


def start_plugin(path, tmp):
    """the plugin started in a host as ned makes one (nim e): (it said ready, its log)"""
    sys.path.insert(0, os.path.dirname(HERE))
    import tplugins
    name = os.path.splitext(os.path.basename(path))[0].replace("_", "-")
    d = os.path.join(tmp, name)
    os.makedirs(d)
    shutil.copy(path, os.path.join(d, "plugin.nims"))
    t = os.path.join(tmp, name + "-host")
    os.makedirs(t)
    h = tplugins.Host([(name, d)], tmp=t)
    try:
        ok = h.pump(lambda j: j.get("t") == "ready", 90) is not None
        return ok, h.logs
    finally:
        h.close()


def start_server(path, tmp):
    """the language server answers initialize and shutdown, and exits with 0"""
    d = os.path.join(tmp, "server")
    os.makedirs(d)
    f = os.path.join(d, os.path.basename(path))
    shutil.copy(path, f)
    msgs = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"capabilities": {}}},
            {"jsonrpc": "2.0", "id": 2, "method": "shutdown"}, {"jsonrpc": "2.0", "method": "exit"}]
    r = subprocess.run(["nim", "e", "--hints:off", "--warnings:off", "--path:" + LIB, f], cwd=d, timeout=120,
                       input="".join(json.dumps(m) + "\n" for m in msgs), capture_output=True, text=True)
    answers = [json.loads(l) for l in r.stdout.splitlines() if l.startswith("{")]
    ok = r.returncode == 0 and any(a.get("id") == 1 and "capabilities" in a.get("result", {}) for a in answers)
    return ok, r.stdout + r.stderr


def main():
    if shutil.which("nim") is None:
        print("nim is not on PATH")
        return 1
    files = sorted(f for f in os.listdir(HERE) if f.endswith(".nims"))
    tmp = tempfile.mkdtemp(prefix="cookbook-")
    try:
        for f in files:
            path = os.path.join(HERE, f)
            first = open(path, encoding="utf-8").readline()
            check(f + ": its first line says what it is (## name — …)", re.match(r"^## \S.* — ", first), first)
            ok, out = nim_check(path)
            check(f + ": compiles as NimScript (nim e)", ok, out)
            native = os.path.join(tmp, f[:-len(".nims")] + ".nim")
            shutil.copy(path, native)
            ok, out = nim_check(native)
            check(f + ": compiles as Nim (plugins.native)", ok, out)
            if "--run" in sys.argv:
                if f in SERVERS:
                    ok, out = start_server(path, tmp)
                    check(f + ": the server answers initialize and shutdown", ok, out[-1500:])
                else:
                    ok, logs = start_plugin(path, tmp)
                    bad = [l for l in logs if "Error" in l]
                    check(f + ": starts in the plugin host", ok and not bad, "\n".join(logs[-20:]))
        if not os.path.exists(PAGE):
            check("docs/plugins/cookbook.md is there", False)
        else:
            blocks, dup = page_blocks()
            check("the page shows each plugin once", not dup, dup)
            check("each plugin of this folder is on the page", not [f for f in files if f not in blocks],
                  [f for f in files if f not in blocks])
            check("each plugin on the page is a file of this folder", not [b for b in blocks if b not in files],
                  [b for b in blocks if b not in files])
            for f in files:
                if f not in blocks:
                    continue
                text = open(os.path.join(HERE, f), encoding="utf-8").read()
                same = blocks[f] == text
                info = ""
                if not same:
                    import difflib
                    info = "\n".join(difflib.unified_diff((blocks[f] or "").split("\n"), text.split("\n"),
                                                          "the page", f, lineterm="", n=1))
                check(f + ": the page shows it as it is", same, info or "no ```nim block after its mark")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("\n%d failed" % len(failed) if failed else "\nthe cookbook is right")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
