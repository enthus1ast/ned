"""which-key: after keys that wait for more (vim's g z d …, a plugin's <leader>, emacs's C-x, helix's space), the box
of what each next key does — ned's own keys, the plugins' mappings (with what they say they do) and your own."""
import os, shutil, tempfile
from tplugins import check

MAPS = """import nedplugin
nmap("<leader>ff", "find a file", proc(count: int) = discard)
nmap("<leader>fg", "grep the project", proc(count: int) = discard)
nmap("<leader>g", "the git log", proc(count: int) = discard)
nmap("gx", "open the link", proc(count: int) = discard)
nmap("zq", proc(count: int) = discard)
nmapIn("markdown", "gm", "a markdown thing", proc(count: int) = discard)
textObject("ie", "the whole file", proc(b: Buf, p: Pos): Range = noRange())
"""


def keys_of(h):
    return dict((k, d) for k, d in (h.hints[1] if h.hints else []))


def ask(h, cb, keys, mode, still=True):
    """keys waited: the event, with them still waiting (or not) when the plugin looks"""
    h.hints = None
    h.pending = (keys, mode) if still else ("", "")
    h.call(cb, {"keys": keys, "mode": mode})
    return keys_of(h)


def run(factory, tag):
    tmp = tempfile.mkdtemp(prefix="ned-which-key-")
    try:
        d = os.path.join(tmp, "maps")
        os.makedirs(d)
        open(os.path.join(d, "plugin.nims"), "w").write(MAPS)
        h = factory([("maps", d)])
        h.settings = {"delay": 100}
        ok = h.build_ok and h.pump(lambda j: j.get("t") == "ready", 90)
        check(tag + "it starts (with a plugin of mappings beside it)", ok, h.build_err if not h.build_ok else "")
        if not ok:
            return
        ev = h.reg("event", event="keys")
        check(tag + "it asks for keys that wait (after 150 ms: its delay setting does the rest)",
              ev is not None and ev.get("pattern") == "150", ev)
        check(tag + "its setting: plugins.which-key.delay (500)",
              h.reg("setting", key="delay") is not None and h.reg("setting", key="delay").get("default") == 500)
        if ev is None:
            return
        cb = ev["cb"]
        g = ask(h, cb, "g", "n")
        check(tag + "g: ned's own (gd go to definition, gg first line, gc comment) and a plugin's (gx)",
              g.get("d") == "go to definition" and g.get("g") == "first line" and g.get("c", "").startswith("comment")
              and g.get("x") == "open the link", g)
        check(tag + "g: its title says the keys", h.hints and h.hints[0] == "g …", h.hints)
        check(tag + "g: a mapping of another language's files is left out (gm: markdown's)", "m" not in g, g)
        h.lang = "markdown"
        gm = ask(h, cb, "g", "n")
        check(tag + "… and in a markdown file it is there", gm.get("m") == "a markdown thing", gm)
        h.lang = "plaintext"
        ld = ask(h, cb, "<leader>", "n")
        check(tag + "<leader>: the next keys of the plugins' mappings (f: two more, g: the git log)",
              ld.get("f") == "+ 2 more keys" and ld.get("g") == "the git log", ld)
        check(tag + "<leader>: the title says it is the space bar", h.hints and "space bar" in h.hints[0], h.hints)
        lf = ask(h, cb, "<leader>f", "n")
        check(tag + "<leader>f: f find a file, g grep the project",
              lf.get("f") == "find a file" and lf.get("g") == "grep the project", lf)
        z = ask(h, cb, "z", "n")
        check(tag + "z: ned's folds and scrolling (zz, za, zM), a plugin's mapping without words (zq: whose it is)",
              z.get("z", "").startswith("this line in the middle") and z.get("a") and z.get("M") == "fold all" and
              z.get("q") == "maps's", z)
        dd = ask(h, cb, "d", "o")
        check(tag + "d (an operator waiting): d the line, s the surroundings, the motions (w, $, i, a)",
              dd.get("d", "").startswith("the line") and "surrounding" in dd.get("s", "") and "w" in dd and "$" in dd
              and "inside" in dd.get("i", ""), dd)
        gc = ask(h, cb, "gc", "o")
        check(tag + "gc: c the line", gc.get("c", "").startswith("the line"), gc)
        di = ask(h, cb, "di", "obj")
        check(tag + "di: the text objects (inside ( … ), inside a word) and a plugin's (ie: the whole file)",
              di.get("(") == "inside ( … )" and di.get("w") == "inside a word" and di.get("e") == "the whole file", di)
        da = ask(h, cb, "da", "obj")
        check(tag + "da: around …, the plugin's ie is not an a-object", da.get("(") == "around ( … )" and "e" not in da,
              da)
        cx = ask(h, cb, "C-x", "emacs")
        check(tag + "emacs C-x: C-s save, C-f open a file, b another tab, 2 split down",
              cx.get("C-s") == "save" and cx.get("C-f") == "open a file" and cx.get("2") == "split down", cx)
        sp = ask(h, cb, "<space>", "helix")
        check(tag + "helix space: f open a file, / search the project, ? the command palette",
              sp.get("f") == "open a file" and sp.get("/") == "search the project" and sp.get("?"), sp)
        h.your_keys = [{"mode": "helix", "keys": "<space>n", "desc": "Next tab", "lang": "", "plugin": ""},
                       {"mode": "n", "keys": "<leader>x", "desc": "Close tab", "lang": "", "plugin": ""}]
        sp = ask(h, cb, "<space>", "helix")
        check(tag + "helix space: your own keys too (helix.keys: <space>n Next tab), and Helix's", sp.get("n") ==
              "Next tab" and sp.get("f") == "open a file", sp)
        ld = ask(h, cb, "<leader>", "n")
        check(tag + "<leader>: your own vim keys too (vim.keys: <leader>x Close tab)", ld.get("x") == "Close tab", ld)
        h.your_keys = []
        gone = ask(h, cb, "g", "n", still=False)
        check(tag + "the keys went on before it looked: no box", h.hints is None and not gone, h.hints)
        none = ask(h, cb, "Q", "n")
        check(tag + "keys with nothing after them: no box", h.hints is None, none)
        # the delay: longer than the event's 150 ms — the rest in a timer, then it looks again
        h.settings = {"delay": 500}
        n0 = len([r for r in h.regs if r["kind"] == "timer"])
        ask(h, cb, "g", "n")
        timers = [r for r in h.regs if r["kind"] == "timer"]
        check(tag + "delay 500: no box yet, a timer for the 350 ms left",
              h.hints is None and len(timers) == n0 + 1 and timers[-1].get("ms") == 350 and not timers[-1].get("repeat"),
              timers[-1:])
        if len(timers) > n0:
            h.call(timers[-1]["cb"])
            check(tag + "… and when it is due, the box", keys_of(h).get("d") == "go to definition", h.hints)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
