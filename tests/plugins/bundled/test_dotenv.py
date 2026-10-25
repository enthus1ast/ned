"""dotenv: the language, the problems as you type (a key twice, a bad name, spaces around =, a value with spaces, a
quote not closed, no =) with their fixes, the outline, a ${KEY}'s value on hover, .env.example made, the comparison"""
import os
from tplugins import check

SAMPLE = ["# the app's settings", "export APP_NAME=demo", "PORT=8000", "PORT=9000", "2BAD=x", "HOST = localhost",
          "GREETING=hello world", 'QUOTED="hi there" # a comment', "NOQUOTE='open", "JUSTAWORD",
          "URL=http://${HOST_NAME}:$PORT/x", "HOST_NAME=example.org"]


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
    sp = (h.reg("language", id="dotenv") or {}).get("spec", {})
    check(tag + "the language: .env files by name, *.env, # comments, both quotes",
          ".env" in sp.get("files", []) and ".env.production" in sp.get("files", []) and sp.get("extensions") == ["env"]
          and sp.get("lineComment") == "#" and sp.get("quotes") == "\"'", sp)
    ev = [r for r in h.regs if r.get("kind") == "event" and r.get("pattern") == "lang:dotenv"]
    check(tag + "checked when opened and as you type", len(ev) >= 2, ev)
    h.lines = list(SAMPLE)
    h.lang = "dotenv"
    h.call(ev[0]["cb"], {"buf": 1, "path": "/p/.env", "lang": "dotenv"})
    ps = {p["range"]["start"]["line"]: p for p in h.problems}
    check(tag + "a key set twice (the line before named)", "set twice (line 3 too)" in ps.get(3, {}).get("message", ""),
          ps.get(3))
    check(tag + "a name starting with a digit; spaces around =; a value with spaces; an open quote; no =",
          "not a name" in ps.get(4, {}).get("message", "") and "spaces around" in ps.get(5, {}).get("message", "") and
          "needs quotes" in ps.get(6, {}).get("message", "") and "not closed" in ps.get(8, {}).get("message", "") and
          ps.get(8, {}).get("severity") == 1 and "no =" in ps.get(9, {}).get("message", ""),
          {k: v.get("message") for k, v in ps.items()})
    check(tag + "fine: export KEY=…, a quoted value with a # comment after it, ${…} in a value",
          1 not in ps and 7 not in ps and 10 not in ps and 11 not in ps, sorted(ps))
    fx = ps.get(5, {}).get("fixes", [])
    check(tag + "the fix for spaces around =", fx and fx[0]["edits"][0]["text"] == "=" and
          fx[0]["edits"][0]["range"] == {"start": pos(5, 4), "stop": pos(5, 7)}, fx)
    fq = ps.get(6, {}).get("fixes", [])
    check(tag + "the fix for a value with spaces: quotes", fq and fq[0]["edits"][0]["text"] == '"hello world"' and
          fq[0]["edits"][0]["range"] == {"start": pos(6, 9), "stop": pos(6, 20)}, fq)
    sy = h.call(h.reg("symbols", lang="dotenv")["cb"], {"buf": 1})
    names = [s["name"] for s in (sy or {}).get("value") or []]
    check(tag + "the outline: the keys", names[:3] == ["APP_NAME", "PORT", "PORT"] and "HOST_NAME" in names, names)
    hv = h.call(h.reg("hover", lang="dotenv")["cb"], {"buf": 1, "pos": pos(10, 16)})
    check(tag + "hover on ${HOST_NAME}: its value", (hv or {}).get("value", "").startswith("`HOST_NAME` = `example.org`"),
          hv)
    hv = h.call(h.reg("hover", lang="dotenv")["cb"], {"buf": 1, "pos": pos(10, 26)})
    check(tag + "hover on $PORT: the last value", "`PORT` = `" in (hv or {}).get("value", ""), hv)
    # .env.example next to the file, then compared
    d = os.path.join(h.tmp, "proj")
    os.makedirs(d, exist_ok=True)
    h.path_ = os.path.join(d, ".env")
    h.lines = ["# db", "DB_URL=postgres://x", "SECRET='s3'"]
    h.call(h.reg("command", title="Env: make .env.example")["cb"])
    ex = open(os.path.join(d, ".env.example")).read() if os.path.exists(os.path.join(d, ".env.example")) else ""
    check(tag + "make .env.example: the keys without their values, the comments kept",
          ex == "# db\nDB_URL=\nSECRET=\n", ex)
    h.lines.append("NEW_KEY=1")
    h.output = []
    h.call(h.reg("command", title="Env: compare with .env.example")["cb"])
    check(tag + "compare: the key the example lacks", any("Only in .env: NEW_KEY" in o for o in h.output), h.output)
