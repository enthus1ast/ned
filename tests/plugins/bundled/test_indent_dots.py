"""indent-dots: the look it gives ned (a dot in the indentation, → for a tab, blank lines, ¬ when asked), sent once and
again only when a setting changed, on/off kept for the next start, the languages setting, its vim key."""
import os
from tplugins import check


def run(factory, tag):
    h = factory()
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return
    ok = h.pump(lambda j: j.get("t") == "ready", 90)
    check(tag + "it starts", ok, "" if ok else h.p.stderr.read()[-1500:])
    if not ok:
        return
    sd = {k: (h.reg("setting", key=k) or {}).get("default")
          for k in ("char", "color", "tabs", "blankLines", "lineEnd", "languages")}
    tog = h.reg("command", title="Indent dots: on/off")
    vk = h.reg("vimMap", mode="n", keys="<leader>id")
    st, en = h.reg("event", event="startup"), h.reg("event", event="enter", pattern="*")
    check(tag + "its command, vim key, settings and events",
          tog and vk and st and en and sd == {"char": "·", "color": "guide", "tabs": "→", "blankLines": True,
                                              "lineEnd": False, "languages": ""}, sd)
    h.call(st["cb"], {"buf": 1})
    s = h.indent_styles[-1] if h.indent_styles else {}
    check(tag + "at start: the dots in the indentation (·, the guides' colour), → for a tab, blank lines; no ¬, every "
          "language, no level colours",
          s.get("dot") == "·" and s.get("dotColor") == "guide" and s.get("tab") == "→" and s.get("blankLines") is True
          and s.get("lineEnd") == "" and s.get("langs") == [] and s.get("levels") == [], s)
    n = len(h.indent_styles)
    h.call(en["cb"], {"buf": 1, "path": "x", "lang": "nim"})
    check(tag + "another tab, nothing changed: nothing sent again", len(h.indent_styles) == n, h.indent_styles[n:])
    h.settings = {"char": "•", "lineEnd": True, "languages": "nim python"}
    h.call(en["cb"], {"buf": 1, "path": "x", "lang": "nim"})
    s = h.indent_styles[-1]
    check(tag + "a setting changed: the new look (•, ¬, only Nim and Python)", len(h.indent_styles) == n + 1 and
          s.get("dot") == "•" and s.get("lineEnd") == "¬" and s.get("langs") == ["nim", "python"], s)
    h.call(tog["cb"])
    s = h.indent_styles[-1]
    data = os.path.join(h.tmp, "data", "indent-dots", "state")
    check(tag + "off: an empty look (ned draws nothing), kept in its data folder, said in the status line",
          s.get("dot") == "" and s.get("tab") == "" and s.get("lineEnd") == "" and
          open(data).read().strip() == "off" and h.messages[-1] == "Indent dots off", (s, h.messages[-1:]))
    h.call(st["cb"], {"buf": 1})
    check(tag + "the next start: still off", h.indent_styles[-1].get("dot") == "", h.indent_styles[-1])
    h.call(vk["cb"], {"count": 1})
    check(tag + "<leader>id: on again", h.indent_styles[-1].get("dot") == "•" and h.messages[-1] == "Indent dots on",
          (h.indent_styles[-1], h.messages[-1:]))
