#!/usr/bin/env python3
"""nedls against nimlangserver, the same questions to each as an editor asks them: at --n places of each file a
hover, a definition, and completion where a member is written (`x.name`: is `name` offered there?). For each
server: how often it answers, how long it takes (the median, and the first answer's time — a server that reads the
project first: the longest wait, over the files, for its first real answer), and how often the two answer the same
(a definition in the same file and line).

usage: lspversus.py --nedls NEDLS --other NIMLANGSERVER [--n N] [--seed S] [--json OUT] FILE ...

nimlangserver needs nimsuggest on PATH (it runs it). Each file gets servers of its own and stays where it is (nothing is written to them: a
member's name is taken away only in the text sent to the servers)."""
import argparse, json, os, random, statistics, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO, 'tests', 'lsp'))
from tnedls import Client, uri, u16col                         # (the LSP client of nedls' own tests)

KW = set("""addr and as asm bind block break case cast concept const continue converter defer discard distinct div do
elif else end enum except export finally for from func if import in include interface is isnot iterator let macro
method mixin mod nil not notin object of or out proc ptr raise ref return shl shr static template try tuple type
using var when while xor yield true false result""".split())


def places(lines):
    """identifiers in code (not strings or comments): (line, col, word, after a dot)"""
    out = []
    triple = False
    for li, s in enumerate(lines):
        i, n = 0, len(s)
        while i < n:
            if triple:
                e = s.find('"""', i)
                if e < 0: break
                i, triple = e + 3, False
                continue
            c = s[i]
            if s.startswith('"""', i): triple, i = True, i + 3; continue
            if c == '#': break
            if c == '"':
                e = i + 1
                while e < n and s[e] != '"':
                    e += 2 if s[e] == '\\' else 1
                i = e + 1
                continue
            if c == "'" and i + 2 < n and s[i + 2] == "'": i += 3; continue
            if c.isalpha() or c == '_':
                e = i
                while e < n and (s[e].isalnum() or s[e] == '_'): e += 1
                w = s[i:e]
                if w not in KW and not (i > 0 and s[i - 1].isdigit()):
                    out.append((li, i, w, i > 0 and s[i - 1] == '.' and not (i > 1 and s[i - 2] == '.')))
                i = e
                continue
            i += 1
    return out


def start(cmd, root):
    c = Client(cmd, root)
    caps = {"textDocument": {"completion": {"completionItem": {"snippetSupport": False}},
                             "hover": {"contentFormat": ["markdown", "plaintext"]}}}
    c.request("initialize", {"processId": os.getpid(), "rootUri": uri(root), "capabilities": caps,
                             "workspaceFolders": [{"uri": uri(root), "name": "p"}], "initializationOptions": {}},
              timeout=120)
    c.notify("initialized", {})
    return c


def ask(c, method, params, timeout=30):
    t0 = time.time()
    r = c.request(method, params, timeout=timeout)
    return ((r or {}).get("result"), (time.time() - t0) * 1000.0)


def hover_text(h):
    if not h: return ''
    v = h.get("contents")
    if isinstance(v, dict): return v.get("value", '')
    if isinstance(v, list): return ' '.join(x.get("value", '') if isinstance(x, dict) else str(x) for x in v)
    return str(v or '')


def first_def(d):
    if not d: return None
    x = d[0] if isinstance(d, list) else d
    u = x.get("uri") or x.get("targetUri")
    r = x.get("range") or x.get("targetSelectionRange") or {}
    return (os.path.realpath(u[7:]) if u and u.startswith("file://") else u, r.get("start", {}).get("line"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('files', nargs='+')
    ap.add_argument('--nedls', required=True)
    ap.add_argument('--other', required=True)
    ap.add_argument('--n', type=int, default=25)
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--json', default='')
    a = ap.parse_args()
    rnd = random.Random(a.seed)
    stats = {s: {"hover": 0, "def": 0, "member": 0, "ms": [], "first_ms": None} for s in ("nedls", "other")}
    same_def = both_def = members = 0
    if True:
        # (each file where it is — a standard-library module copied elsewhere loses its includes, and nimsuggest
        # with it — with servers of its own: nimlangserver takes the first file opened as the project of the others)
        for p in [os.path.realpath(f) for f in a.files]:
            root = os.path.dirname(p)
            servers = {"nedls": start([os.path.abspath(a.nedls)], root), "other": start([os.path.abspath(a.other)], root)}
            text = open(p, encoding='utf-8', errors='replace').read()
            lines = text.split('\n')
            for c in servers.values():
                c.notify("textDocument/didOpen", {"textDocument": {"uri": uri(p), "languageId": "nim", "version": 1,
                                                                   "text": text}})
            # (each server ready for the file first — nimlangserver starts a nimsuggest for it, which answers nothing
            # until it has read the project: the first answer's time says how long that takes)
            ps = places(lines)
            pick = rnd.sample(ps, min(a.n, len(ps)))
            warm = [x for x in ps if not x[3] and x[2] in ("result", "len", "add", "string", "int")][:6] or pick[:6]
            for name, c in servers.items():
                t0 = time.time()
                k = 0
                while time.time() - t0 < 60:
                    l, col = warm[k % len(warm)][:2]
                    k += 1
                    h, _ = ask(c, "textDocument/hover", {"textDocument": {"uri": uri(p)},
                                                         "position": {"line": l, "character": col + 1}}, 60)
                    if hover_text(h).strip(): break
                    if k % len(warm) == 0: time.sleep(0.5)
                ready = round((time.time() - t0) * 1000)
                print("  %s ready for %s after %d ms" % (name, os.path.basename(p), ready), flush=True)
                st = stats[name]
                st["first_ms"] = ready if st["first_ms"] is None else max(st["first_ms"], ready)
            mem = [x for x in ps if x[3]]
            mpick = rnd.sample(mem, min(a.n // 2, len(mem)))
            for (l, col, w, _) in pick:
                pos = {"line": l, "character": u16col(lines[l], col + 1)}
                defs = {}
                for name, c in servers.items():
                    h, ms = ask(c, "textDocument/hover", {"textDocument": {"uri": uri(p)}, "position": pos}, 60)
                    st = stats[name]
                    st["ms"].append(ms)
                    if hover_text(h).strip(): st["hover"] += 1
                    d, ms = ask(c, "textDocument/definition", {"textDocument": {"uri": uri(p)}, "position": pos}, 60)
                    st["ms"].append(ms)
                    defs[name] = first_def(d)
                    if defs[name]: st["def"] += 1
                if defs["nedls"] and defs["other"]:
                    both_def += 1
                    if defs["nedls"] == defs["other"]: same_def += 1
            for (l, col, w, _) in mpick:
                members += 1
                # (the member's name taken away: what is offered right after the dot)
                edited = lines[:]
                edited[l] = lines[l][:col] + lines[l][col + len(w):]
                for name, c in servers.items():
                    c.notify("textDocument/didChange", {"textDocument": {"uri": uri(p), "version": 2 + members},
                                                        "contentChanges": [{"text": '\n'.join(edited)}]})
                    r, ms = ask(c, "textDocument/completion", {"textDocument": {"uri": uri(p)},
                                "position": {"line": l, "character": u16col(edited[l], col)}}, 60)
                    stats[name]["ms"].append(ms)
                    items = r.get("items", []) if isinstance(r, dict) else (r or [])
                    if any(i.get("label", '').split('(')[0].strip() == w for i in items): stats[name]["member"] += 1
                    c.notify("textDocument/didChange", {"textDocument": {"uri": uri(p), "version": 1000 + members},
                                                        "contentChanges": [{"text": text}]})
            for c in servers.values():
                try:
                    c.request("shutdown", None, timeout=10)
                    c.notify("exit", {})
                    c.close()
                except Exception:
                    pass
    n = sum(min(a.n, 10 ** 9) for _ in a.files)
    res = {}
    for name in ("nedls", "other"):
        st = stats[name]
        res[name] = {"hover": st["hover"], "def": st["def"], "member": st["member"],
                     "median_ms": round(statistics.median(st["ms"]), 1) if st["ms"] else None,
                     "first_ms": st["first_ms"]}
    res["places"] = n
    res["members"] = members
    res["def_both"] = both_def
    res["def_same"] = same_def
    for name, label in (("nedls", "nedls"), ("other", "nimlangserver")):
        r = res[name]
        print("%-14s hover %d · definition %d · member offered %d/%d · median %s ms · ready after %s ms" % (
            label, r["hover"], r["def"], r["member"], members, r["median_ms"], r["first_ms"]))
    print("definitions both give: %d, the same place: %d" % (both_def, same_def))
    if a.json: json.dump(res, open(a.json, 'w'), indent=1)
    return 0


if __name__ == '__main__':
    sys.exit(main())
