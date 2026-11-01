"""rubber-duck: the routine the cursor is in (or the selection) talked through a line at a time — a question that fits
each line, blank lines and comments passed over —, the talk in a Markdown tab; Enter with nothing stops; outside a
routine it says so; a question to ask yourself."""
from tplugins import check
from tbundled import rng, pos

CODE = ["import std/strutils", "", "proc total(xs: seq[int], limit: int): int =", "  ## adds up the small ones",
        "  for x in xs:", "    if x < limit:", "      result += x", "    else:", "      discard", "  let shown = $result",
        "  echo shown.strip()", "", "echo total(@[1, 2, 30], 10)"]


def start(factory, tag):
    h = factory()
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return None
    if not h.pump(lambda j: j.get("t") == "ready", 90):
        h.p.kill()
        check(tag + "it starts", False, h.p.stderr.read()[-1500:])
        return None
    check(tag + "it starts (%s ms)" % h.ready_ms, True)
    return h


def run(factory, tag):
    h = start(factory, tag)
    if not h:
        return
    titles = {r["title"] for r in h.regs if r["kind"] == "command"}
    check(tag + "its commands", {"Duck: talk it through", "Duck: a question to ask myself"} <= titles, titles)
    talk = h.reg("command", title="Duck: talk it through")["cb"]
    h.lines = list(CODE)
    h.cursor = pos(6, 4)
    h.answers["ask"] = "it adds x"
    h.asked = []
    h.call(talk)
    prompts = [a.get("prompt", "") for fn, a in h.asked if fn == "ask"]
    want = [("3:", "What is `total` for"), ("5:", "how many times"), ("6:", "When is this true"),
            ("7:", "What should the result be"), ("8:", "Which cases end up here"), ("9:", "thrown away"),
            ("10:", "What value do you expect `shown`"), ("11:", "What does `echo` do")]
    got = [(p.split(" ")[1], p) for p in prompts]
    ok = len(prompts) == len(want) and all(p.startswith("🦆 " + n) and q in p for (n, q), p in zip(want, prompts))
    check(tag + "the routine the cursor is in, a line at a time, each with its own question (the doc comment and "
          "the lines outside it passed over)", ok, prompts)
    tab = h.tabs[-1] if h.tabs else ("", "", "")
    check(tag + "the talk in a Markdown tab: each line, its question, the answer",
          tab[0] == "🦆 talk" and tab[2] == "markdown" and "**6** `if x < limit:`" in tab[1] and
          "it adds x" in tab[1] and "lines 3–11" in tab[1] and
          h.messages[-1] == "🦆 8 lines talked through — the talk is in its tab", (tab[1][:400], h.messages[-1:]))
    # Enter with nothing: it stops
    h.answers["ask"] = ""
    h.asked = []
    h.call(talk)
    n = len([1 for fn, a in h.asked if fn == "ask"])
    check(tag + "Enter with nothing stops the talk", n == 1 and "(stopped here)" in h.tabs[-1][1] and
          h.messages[-1].endswith("(stopped) — the talk is in its tab"), (n, h.messages[-1:]))
    # the selection; outside a routine
    h.answers["ask"] = "yes"
    h.asked = []
    h.sel = rng(12, 0, 13, 0)
    h.call(talk)
    h.sel = None
    p = [a.get("prompt", "") for fn, a in h.asked if fn == "ask"]
    check(tag + "the selection's lines (a call: what it does with what it is given)",
          len(p) == 1 and p[0].startswith("🦆 13: echo total(@[1, 2, 30], 10)") and "`echo`" in p[0], p)
    h.cursor = pos(0, 3)
    h.asked = []
    h.call(talk)
    check(tag + "outside any routine, nothing selected: it says so", not h.asked and
          h.messages[-1] == "🦆 Select the lines to talk through, or put the cursor in a routine", h.messages[-1:])
    h.call(h.reg("command", title="Duck: a question to ask myself")["cb"])
    check(tag + "a question to ask myself: in a note", h.messages[-1].startswith("🦆 ") and h.messages[-1].endswith("?"),
          h.messages[-1:])
