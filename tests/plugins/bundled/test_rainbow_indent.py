"""rainbow-indent: the look it gives ned (a colour for each level — the theme's by default, or yours —, bands, guides or
dots, a red band for wrong indentation), next style, on/off kept for the next start, the languages setting."""
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
    sd = {k: (h.reg("setting", key=k) or {}).get("default") for k in ("colors", "style", "markWrong", "languages")}
    tog, nxt = h.reg("command", title="Rainbow indent: on/off"), h.reg("command", title="Rainbow indent: next style")
    st, en = h.reg("event", event="startup"), h.reg("event", event="enter", pattern="*")
    check(tag + "its commands, settings and events", tog and nxt and st and en and
          sd == {"colors": "warn add info accent mod", "style": "background", "markWrong": True, "languages": ""}, sd)
    h.call(st["cb"], {"buf": 1})
    s = h.indent_styles[-1] if h.indent_styles else {}
    check(tag + "at start: the theme's colours for the levels, as bands, wrong indentation in the error colour; no dots",
          s.get("levels") == ["warn", "add", "info", "accent", "mod"] and s.get("levelStyle") == "background" and
          s.get("wrongColor") == "error" and s.get("dot") == "" and s.get("langs") == [], s)
    styles = []
    for _ in range(3):
        h.call(nxt["cb"])
        styles.append(h.indent_styles[-1].get("levelStyle"))
    check(tag + "next style: guides, dots, bands again — said in the status line",
          styles == ["guides", "dots", "background"] and h.messages[-1].startswith("Rainbow indent: background"),
          (styles, h.messages[-1:]))
    h.call(nxt["cb"])
    h.settings = {"colors": "#e5c07b #98c379", "markWrong": False, "languages": "yaml"}
    h.call(en["cb"], {"buf": 1, "path": "x", "lang": "nim"})
    s = h.indent_styles[-1]
    check(tag + "your colours, no red band, only YAML (the style chosen kept over the setting)",
          s.get("levels") == ["#e5c07b", "#98c379"] and s.get("wrongColor") == "" and s.get("langs") == ["yaml"] and
          s.get("levelStyle") == "guides", s)
    h.call(tog["cb"])
    data = os.path.join(h.tmp, "data", "rainbow-indent", "state")
    check(tag + "off: no levels (ned draws nothing), kept with the style in its data folder",
          h.indent_styles[-1].get("levels") == [] and open(data).read().split() == ["off", "guides"],
          (h.indent_styles[-1], open(data).read() if os.path.exists(data) else ""))
    h.call(st["cb"], {"buf": 1})
    check(tag + "the next start: still off", h.indent_styles[-1].get("levels") == [], h.indent_styles[-1])
    h.call(tog["cb"])
    check(tag + "on again: the style kept", h.indent_styles[-1].get("levelStyle") == "guides", h.indent_styles[-1])
