#!/usr/bin/env python3
"""The set-ups of nedls for other editors (editors/), checked (Python 3, standard library only).

    python3 tests/editors/check.py [NEDLS]

Helix's languages.toml and Zed's extension (extension.toml, Cargo.toml, its Rust source) parse and say what nedls
needs; the Zed extension's version is ned's; the settings each one passes to nedls are settings nedls has (the list
in `nedls --help`, from src/ned/nedls/server.nim); the Neovim files name the same settings and, with luac or nvim
on PATH, are valid Lua; the VS Code extension's nedls.* settings are nedls's too; every folder has its README.
With a nedls given, it is started the way each editor starts it and must answer initialize.
Prints PASS, FAIL or SKIP for each check; exits 1 when one fails.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ED = os.path.join(ROOT, "editors")
RESULTS = []


def check(name, ok, detail=""):
    RESULTS.append(bool(ok))
    print(("PASS  " if ok else "FAIL  ") + name + ("" if ok or not detail else "  — " + str(detail)[:300]))
    return ok


def skip(name, why):
    print("SKIP  %s (%s)" % (name, why))


def read(*parts):
    with open(os.path.join(ED, *parts), encoding="utf-8") as f:
        return f.read()


def ned_version():
    with open(os.path.join(ROOT, "src", "ned", "version.nim"), encoding="utf-8") as f:
        return re.search(r'const NedVersion\* = "([^"]+)"', f.read()).group(1)


def nedls_settings():
    """the settings nedls's --help lists (the names in its Settings block)"""
    with open(os.path.join(ROOT, "src", "ned", "nedls", "server.nim"), encoding="utf-8") as f:
        src = f.read()
    block = src[src.index("Settings (initializationOptions"):]
    block = block[:block.index('"""')]
    return set(re.findall(r"^  ([A-Za-z]+) ", block, re.M))


def initialize(cmd, opts):
    """start nedls as an editor would and ask initialize: its serverInfo (None when it did not answer)"""
    root = tempfile.mkdtemp(prefix="teditors-")
    try:
        p = subprocess.Popen(cmd, cwd=root, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "processId": os.getpid(), "rootUri": "file://" + root, "capabilities": {},
            "initializationOptions": opts}}).encode()
        p.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
        p.stdin.flush()
        n = 0
        while True:
            line = p.stdout.readline()
            if not line.strip():
                break
            k, _, v = line.decode().partition(":")
            if k.strip().lower() == "content-length":
                n = int(v)
        msg = json.loads(p.stdout.read(n)) if n else {}
        p.kill()
        p.wait()
        return (msg.get("result") or {}).get("serverInfo")
    finally:
        shutil.rmtree(root, ignore_errors=True)


def main():
    nedls = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else None
    known = nedls_settings()
    check("nedls --help lists its settings (workspaceDiagnostics among them)", "workspaceDiagnostics" in known and
          "inlayHints" in known, sorted(known))
    for d in ("vscode", "nvim", "helix", "zed"):
        check("editors/%s: a README" % d, os.path.isfile(os.path.join(ED, d, "README.md")))

    # ── Helix ──
    hx = tomllib.loads(read("helix", "languages.toml"))
    srv = hx.get("language-server", {}).get("nedls", {})
    check("Helix: [language-server.nedls] runs nedls", srv.get("command") == "nedls", srv)
    check("Helix: its config names nedls's settings", set(srv.get("config", {})) <= known,
          set(srv.get("config", {})) - known)
    nim = [x for x in hx.get("language", []) if x.get("name") == "nim"]
    check("Helix: Nim's language servers: nedls", nim and "nedls" in nim[0].get("language-servers", []), nim)

    # ── Zed ──
    v = ned_version()
    ext = tomllib.loads(read("zed", "extension.toml"))
    cargo = tomllib.loads(read("zed", "Cargo.toml"))
    check("Zed: extension.toml — id, schema, the language server for Nim", ext.get("id") == "nedls-language-server" and
          ext.get("schema_version") == 1 and "Nim" in ext.get("language_servers", {}).get("nedls", {}).get("languages", []),
          ext)
    eid = ext.get("id", "")
    check("Zed: an id its registry takes (kebab-case, says it is a language server, no \"zed\" or \"extension\" in it)",
          re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", eid) is not None and eid.endswith(("-language-server", "-lsp")) and
          "zed" not in eid and "extension" not in eid, eid)
    check("Zed: a licence Zed accepts beside the extension (LICENSE: the GPL 3)",
          os.path.isfile(os.path.join(ED, "zed", "LICENSE")) and "GNU GENERAL PUBLIC LICENSE" in read("zed", "LICENSE"))
    check("Zed: Nim documents go to nedls as languageId nim",
          ext["language_servers"]["nedls"].get("language_ids", {}).get("Nim") == "nim", ext["language_servers"])
    check("Zed: the extension's version is ned's (extension.toml, Cargo.toml)", ext.get("version") == v and
          cargo["package"]["version"] == v, (ext.get("version"), cargo["package"]["version"], v))
    lib = cargo.get("lib", {})
    check("Zed: Cargo.toml — a cdylib of zed_extension_api, its source there", lib.get("crate-type") == ["cdylib"] and
          "zed_extension_api" in cargo.get("dependencies", {}) and
          os.path.isfile(os.path.join(ED, "zed", lib.get("path", "src/lib.rs"))), cargo)
    rs = read("zed", lib.get("path", "src/lib.rs"))
    check("Zed: the Rust source registers the extension and starts nedls",
          "register_extension!" in rs and "language_server_command" in rs and '"nedls"' in rs and '"--stdio"' in rs)
    rustc = shutil.which("rustc")
    if rustc:
        targets = subprocess.run([rustc, "--print", "target-list"], capture_output=True, text=True).stdout
        sysroot = subprocess.run([rustc, "--print", "sysroot"], capture_output=True, text=True).stdout.strip()
        have = [t for t in ("wasm32-wasip2", "wasm32-wasip1") if t in targets and
                os.path.isdir(os.path.join(sysroot, "lib", "rustlib", t))]
        if not have:
            skip("Zed: building the extension", "no WebAssembly target installed for rustc (rustup target add "
                 "wasm32-wasip2); Zed builds it itself when you install it as a dev extension")
        else:
            skip("Zed: building the extension", "it needs zed_extension_api from crates.io: cargo build --target %s "
                 "in editors/zed" % have[0])
    else:
        skip("Zed: building the extension", "no rustc on PATH")

    # ── Neovim ──
    lua_cfg = read("nvim", "lsp", "nedls.lua")
    lua_mod = read("nvim", "lua", "nedls.lua")
    check("Neovim: lsp/nedls.lua starts nedls for Nim", "cmd = { 'nedls' }" in lua_cfg and "'nim'" in lua_cfg)
    block = lua_cfg[lua_cfg.index("nedls = {") + len("nedls = {"):]
    block = block[:block.index("}")]
    keys = set(re.findall(r"(\w+) =", block)) | set(re.findall(r"(\w+) =", lua_cfg[lua_cfg.index("init_options"):
                                                                                    lua_cfg.index("settings =")]))
    keys.discard("init_options")
    check("Neovim: its settings are nedls's", keys and keys <= known, keys - known)
    check("Neovim: lua/nedls.lua — setup for 0.11 (vim.lsp.config) and 0.10 (vim.lsp.start)",
          "vim.lsp.config('nedls'" in lua_mod and "vim.lsp.enable('nedls')" in lua_mod and "vim.lsp.start" in lua_mod)
    luac = shutil.which("luac") or shutil.which("luac5.4") or shutil.which("luac5.1")
    nvim = shutil.which("nvim")
    if luac:
        for f in (("lsp", "nedls.lua"), ("lua", "nedls.lua")):
            r = subprocess.run([luac, "-p", os.path.join(ED, "nvim", *f)], capture_output=True, text=True)
            check("Neovim: %s is valid Lua (luac -p)" % "/".join(f), r.returncode == 0, r.stderr)
    elif nvim:
        for f in (("lsp", "nedls.lua"), ("lua", "nedls.lua")):
            r = subprocess.run([nvim, "--headless", "--clean", "-c",
                                "lua assert(loadfile('%s'))" % os.path.join(ED, "nvim", *f), "-c", "qa!"],
                               capture_output=True, text=True, timeout=30)
            check("Neovim: %s is valid Lua (nvim)" % "/".join(f), r.returncode == 0 and not r.stderr.strip(), r.stderr)
    else:
        skip("Neovim: the Lua files compile", "no luac or nvim on PATH")

    # ── VS Code ──
    pkg = json.loads(read("vscode", "package.json"))
    props = set(k.split(".", 1)[1] for k in pkg["contributes"]["configuration"]["properties"])
    own = {"path", "languages", "trace.server"}           # (the extension's own: which program, which languages, its log)
    check("VS Code: its nedls.* settings are nedls's (and its own: path, languages, trace.server)",
          props - own <= known, (props - own) - known)

    # ── nedls, started as each editor starts it ──
    if nedls:
        info = initialize([nedls, "--stdio"], dict(srv.get("config", {})))
        check("Helix's command and config: nedls answers initialize", (info or {}).get("name") == "nedls", info)
        info = initialize([nedls], {"nedSettings": True})
        check("Neovim's cmd: nedls answers initialize", (info or {}).get("name") == "nedls", info)
    else:
        skip("nedls started as the editors start it", "give a nedls: python3 tests/editors/check.py ./nedls")

    print("\n%d passed, %d failed" % (RESULTS.count(True), RESULTS.count(False)))
    return 0 if all(RESULTS) else 1


if __name__ == "__main__":
    sys.exit(main())
