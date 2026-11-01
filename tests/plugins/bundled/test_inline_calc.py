"""inline-calc: a selected sum replaced with its result; a line ending in = answered; the result shown and copied;
what the sums understand (precedence, power from the right, percents, bases, functions, ans), and the mistakes said
plainly."""
from tplugins import check
from tbundled import rng, pos


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
    check(tag + "its commands", {"Calc: work it out", "Calc: show the result"} <= titles, titles)
    work = h.reg("command", title="Calc: work it out")["cb"]
    show = h.reg("command", title="Calc: show the result")["cb"]

    def calc(sumtext):
        h.lines = ["x " + sumtext + " y"]
        h.sel = rng(0, 2, 0, 2 + len(sumtext))            # (the test host counts characters)
        h.call(work)
        h.sel = None
        line = h.lines[0]
        return line[2:-2] if line.startswith("x ") and line.endswith(" y") else line

    cases = [("12*(3+4)", "84"), ("2 + 3 * 4", "14"), ("(2 + 3) * 4", "20"), ("2^3^2", "512"), ("2**10", "1024"),
             ("-2^2", "-4"), ("7 % 3", "1"), ("-7 % 3", "2"), ("7 // 2", "3"), ("1/4", "0.25"),
             ("1/3", "0.3333333333"), ("1_000 * 3", "3000"), ("2.5e3", "2500"), ("0x1F + 0b101 + 0o17", "51"),
             ("200 * 15%", "30"), ("50% + 1", "1.5"), ("sqrt(16) + abs(-2)", "6"), ("max(3, 9, 4) - min(5, 2)", "7"),
             ("round(pi * 100)", "314"), ("floor(2.7) + ceil(2.1)", "5"), ("log(1000) + ln(e)", "4"),
             ("log2(8)", "3"), ("6 × 7", "42"), ("10 ÷ 4", "2.5"), ("3 − 5", "-2"), ("0.1 + 0.2", "0.3")]
    bad = []
    for s, want in cases:
        got = calc(s)
        if got != want: bad.append((s, want, got))
    check(tag + "sums worked out as written: precedence, a power from the right, %%, //, bases, percents, functions, "
          "× ÷ − (%d sums)" % len(cases), not bad, bad)
    got = calc("ans * 2")
    check(tag + "ans: the last result", got == "0.6", got)
    # a line ending in =, the cursor at its end: the result after it
    h.lines = ["total = 3*4 + 2 ="]
    h.cursor = pos(0, len(h.lines[0]))
    h.call(work)
    a = h.lines[0]
    h.lines = ["width: 80 - 2*4"]
    h.cursor = pos(0, len(h.lines[0]))
    h.call(work)
    b = h.lines[0]
    check(tag + "no selection: the sum before the cursor, after its last = or :; a line ending in = answered",
          a == "total = 3*4 + 2 = 14" and b == "width: 80 - 2*4 = 72", (a, b))
    # shown, not written
    h.lines = ["2^16"]
    h.sel = rng(0, 0, 0, 4)
    h.call(show)
    h.sel = None
    check(tag + "Calc: show the result: in the status line and on the clipboard, the text as it was",
          h.lines == ["2^16"] and h.clip == "65536" and h.messages[-1].startswith("2^16 = 65536"),
          (h.lines, h.clip, h.messages[-1:]))
    # the mistakes
    msgs = []
    for s in ["1/0", "2 +", "(3", "foo(2)", "sqrt(-1)", "0x", "3 4"]:
        h.lines = ["[" + s + "]"]
        h.sel = rng(0, 1, 0, 1 + len(s))
        h.call(work)
        msgs.append((s, h.lines[0], h.messages[-1] if h.messages else ""))
    h.sel = None
    h.lines = ["abc"]
    h.cursor = pos(0, 0)
    h.call(work)
    msgs.append(("", h.lines[0], h.messages[-1]))
    ok = all(line == ("[" + s + "]" if s else "abc") and m.startswith("Calc: ") for s, line, m in msgs)
    check(tag + "a sum that cannot be worked out: the text left alone, what is wrong in the status line",
          ok and msgs[0][2] == "Calc: a division by 0" and "no function foo" in msgs[3][2] and
          "a ) expected at the end" in msgs[2][2] and msgs[-1][2] == "Calc: nothing to work out at the end", msgs)
    h.settings = {"decimals": 3}
    got = calc("2/3")
    check(tag + "plugins.inline-calc.decimals", got == "0.667", got)
