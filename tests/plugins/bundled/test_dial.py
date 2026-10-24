"""dial: Ctrl+A / Ctrl+X on numbers, dates, times and words — the palette, vim's keys with a count, visual mode"""
from tplugins import check


def pos(l, c):
    return {"line": l, "col": c}


def rng(l0, c0, l1, c1):
    return {"start": pos(l0, c0), "stop": pos(l1, c1)}


def run(factory, tag):
    h = factory()
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return
    ok = h.pump(lambda j: j.get("t") == "ready", 60)
    check(tag + "it starts", ok, "" if ok else h.p.stderr.read()[-1500:])
    if not ok:
        return
    inc, dec = h.reg("command", title="Dial: increment"), h.reg("command", title="Dial: decrement")
    prog = h.reg("command", title="Dial: add 1, 2, 3 … to the selected lines' numbers")
    keys = {k: h.reg("vimMap", mode="n", keys=k) for k in ["<C-a>", "<C-x>", "g<C-a>", "g<C-x>"]}
    vis = {k: h.reg("vimMap", mode="v", keys=k) for k in ["<C-a>", "<C-x>", "g<C-a>", "g<C-x>"]}
    check(tag + "its commands (Ctrl+Alt+A, Ctrl+Alt+X), vim's <C-a> <C-x> g<C-a> g<C-x> in normal and visual mode, "
          "a setting", inc and inc["keys"] == "ctrl+alt+a" and dec and dec["keys"] == "ctrl+alt+x" and prog and
          all(keys.values()) and all(vis.values()) and not h.reg("operator") and
          h.reg("setting", key="cycles")["default"] == "" and
          h.reg("requires")["spec"] == ">= 6.25", (h.regs,))

    def nm(k, line, col, count=1):
        """a vim mapping on a line of its own: the line after it, the cursor's column, the call's answer"""
        h.lines = [line]
        h.cursor = pos(0, col)
        h.sel = None
        r = h.call(keys[k]["cb"], {"count": count})
        return h.lines[0], h.cursor["col"], r

    def up(line, col, count=1):
        return nm("<C-a>", line, col, count)

    def down(line, col, count=1):
        return nm("<C-x>", line, col, count)

    # numbers
    r = up("x = 5;", 0)
    check(tag + "a number after the cursor: +1, the cursor on its last digit", r[:2] == ("x = 6;", 4) and "err" not in r[2], r)
    check(tag + "a count: 5<C-a>, 12<C-x>", up("x = 5", 4, 5)[0] == "x = 10" and down("x = 5", 4, 12)[0] == "x = -7",
          (up("x = 5", 4, 5), down("x = 5", 4, 12)))
    check(tag + "negative numbers: -3 + 5, -1 + 1, [-2]",
          up("y = -3", 0, 5)[0] == "y = 2" and up("f(-1)", 2)[0] == "f(0)" and up("[-2]", 0)[0] == "[-1]",
          (up("y = -3", 0, 5), up("f(-1)", 2), up("[-2]", 0)))
    check(tag + "a - after a name or a number is not a sign: item-1 → item-2, a-1 → a-0",
          up("item-1", 0)[0] == "item-2" and down("a-1", 0)[0] == "a-0", (up("item-1", 0), down("a-1", 0)))
    check(tag + "under the cursor before after it: the second number when the cursor is on it",
          up("a 1 b 20 c", 6)[0] == "a 1 b 21 c" and up("a 1 b 20 c", 3)[0] == "a 1 b 21 c", up("a 1 b 20 c", 3))
    check(tag + "Nim's underscores kept: 1_000 → 1_001, 9_999 → 10_000, 999_999 → 1_000_000, 1_2345 (other groups)",
          up("1_000", 0)[0] == "1_001" and up("9_999", 0)[0] == "10_000" and up("999_999", 0)[0] == "1_000_000" and
          up("1_2345", 0)[0] == "1_2346", (up("9_999", 0), up("999_999", 0), up("1_2345", 0)))
    check(tag + "leading zeros kept: 007 → 008, 010 → 009; 10 - 1 is 9",
          up("007", 0)[0] == "008" and down("010", 0)[0] == "009" and down("10", 0)[0] == "9",
          (up("007", 0), down("010", 0)))
    check(tag + "Nim's type suffix stays: 100'i32 → 101'i32", up("x = 100'i32", 0)[0] == "x = 101'i32", up("x = 100'i32", 0))
    big = up("99999999999999999999", 0)
    check(tag + "a number too large: unchanged, and a message", big[0] == "99999999999999999999" and
          "too large" in h.messages[-1], (big, h.messages[-1:]))
    # hex, binary, octal
    check(tag + "hex: 0x1F → 0x20, 0xff → 0x100, 0x0e → 0x0f, 0xFE → 0xFF (the case kept), 0X0F → 0X10",
          up("0x1F", 0)[0] == "0x20" and up("0xff", 0)[0] == "0x100" and up("0x0e", 0)[0] == "0x0f" and
          up("0xFE", 0)[0] == "0xFF" and up("0X0F", 0)[0] == "0X10", [up(x, 0)[0] for x in ["0x1F", "0xff", "0x0e", "0xFE", "0X0F"]])
    check(tag + "hex keeps its digits: 0x10 - 1 → 0x0f, 0x0100 - 1 → 0x00ff; never below 0x00; 0xFF_FF + 1 → 0x1_00_00",
          down("0x10", 0)[0] == "0x0f" and down("0x0100", 0)[0] == "0x00ff" and down("0x00", 0)[0] == "0x00" and
          up("0xFF_FF", 0)[0] == "0x1_00_00", [down(x, 0)[0] for x in ["0x10", "0x0100", "0x00"]] + [up("0xFF_FF", 0)[0]])
    check(tag + "binary and octal: 0b101 → 0b110, 0b0011 → 0b0100, 0o17 → 0o20, 0b1 × 3 → 0b100",
          up("0b101", 0)[0] == "0b110" and up("0b0011", 0)[0] == "0b0100" and up("0o17", 0)[0] == "0o20" and
          up("0b1", 0, 3)[0] == "0b100", [up(x, 0)[0] for x in ["0b101", "0b0011", "0o17"]])
    # dates
    d = "due 2026-10-24 ok"
    check(tag + "a date: the day under the cursor, +8 rolls into November; the cursor stays on the day",
          up(d, 13, 8)[:2] == ("due 2026-11-01 ok", 13), up(d, 13, 8))
    check(tag + "the month: 2026-01-31 + 1 month → 2026-02-28; 2026-12-15 + 1 → 2027-01-15",
          up("2026-01-31", 6)[:2] == ("2026-02-28", 6) and up("2026-12-15", 5)[0] == "2027-01-15",
          (up("2026-01-31", 6), up("2026-12-15", 5)))
    check(tag + "the year: 2024-02-29 + 1 year → 2025-02-28; − 4 years → 2020-02-29",
          up("2024-02-29", 1)[:2] == ("2025-02-28", 3) and down("2024-02-29", 0, 4)[0] == "2020-02-29",
          (up("2024-02-29", 1), down("2024-02-29", 0, 4)))
    check(tag + "the day back over a month and a year: 2026-03-01 − 1 → 2026-02-28, 2026-01-01 − 1 → 2025-12-31",
          down("2026-03-01", 9)[0] == "2026-02-28" and down("2026-01-01", 8)[0] == "2025-12-31" and
          up("2024-02-28", 9)[0] == "2024-02-29", (down("2026-03-01", 9), down("2026-01-01", 8)))
    check(tag + "the cursor before a date: its day; 2026/10/24 too",
          up(d, 0)[:2] == ("due 2026-10-25 ok", 13) and up("2026/10/31", 9)[0] == "2026/11/01", (up(d, 0), up("2026/10/31", 9)))
    check(tag + "not a date (2026-13-45): its numbers", up("2026-13-45", 6)[0] == "2026-14-45", up("2026-13-45", 6))
    # times
    check(tag + "a time: 09:59 + 1 minute → 10:00, 23:30 + 1 hour → 00:30, 9:05 − 10 hours → 23:05",
          up("at 09:59", 7)[0] == "at 10:00" and up("23:30", 0)[:2] == ("00:30", 1) and
          down("9:05", 0, 10)[0] == "23:05", (up("at 09:59", 7), up("23:30", 0), down("9:05", 0, 10)))
    check(tag + "seconds: 12:00:59 + 1 → 12:01:00; the cursor before a time: its minutes",
          up("12:00:59", 7)[:2] == ("12:01:00", 7) and up("x 9:30", 0)[:2] == ("x 9:31", 5),
          (up("12:00:59", 7), up("x 9:30", 0)))
    # words
    check(tag + "words: true → false, True → False, TRUE → FALSE, let → var, and → or, on → off, inc → dec",
          up("x = true", 5)[0] == "x = false" and up("True", 0)[0] == "False" and up("TRUE", 2)[0] == "FALSE" and
          up("let x = 1", 0)[0] == "var x = 1" and up("a and b", 2)[0] == "a or b" and up("on", 0)[0] == "off" and
          down("inc(x)", 1)[0] == "dec(x)", [up("x = true", 5), up("let x = 1", 0)])
    check(tag + "weekdays and months go round: Monday + 2 → Wednesday, sunday → monday, December → January, may − 5 → december",
          up("Monday", 0, 2)[0] == "Wednesday" and up("sunday", 3)[0] == "monday" and
          up("December", 0)[0] == "January" and down("may", 1, 5)[0] == "december", [up("Monday", 0, 2), down("may", 1, 5)])
    check(tag + "a whole word only: onboard is not on/off (the number after it instead)",
          up("onboard 3", 1)[0] == "onboard 4" and up("onboard", 1)[0] == "onboard" and
          h.messages[-1] == "Dial: nothing to change at the cursor or after it on the line", (up("onboard 3", 1), h.messages[-1:]))
    check(tag + "a word after the cursor is left alone: the number after it is changed",
          up("x true 1", 0)[0] == "x true 2", up("x true 1", 0))
    h.settings = {"cycles": "red,green,blue; low , high ;single"}
    check(tag + "the cycles setting: red → green, blue → red, LOW → HIGH (the case kept); a list of one word is left out",
          up("red", 0)[0] == "green" and up("blue", 0)[0] == "red" and up("LOW", 0)[0] == "HIGH" and
          up("single", 0)[0] == "single", (up("red", 0), up("blue", 0), up("LOW", 0)))
    h.settings = {"cycles": "&&,||;==,!="}
    check(tag + "the cycles setting with symbols: && → ||, == → != (no word edges needed)",
          up("a && b", 3)[0] == "a || b" and up("if x==y", 5)[0] == "if x!=y", (up("a && b", 3), up("if x==y", 5)))
    h.settings = {}
    # the palette, with a selection or not
    h.lines = ["a = 1", "b = 2", "c", "d = 0x09"]
    h.cursor = pos(0, 0)
    h.sel = rng(0, 0, 3, 3)
    h.call(inc["cb"])
    check(tag + "Dial: increment with a selection: each line's first number (none on c), the cursor at the start",
          h.lines == ["a = 2", "b = 3", "c", "d = 0x09"] and h.cursor == pos(0, 0), (h.lines, h.cursor))
    h.sel = rng(0, 0, 3, 8)
    h.call(dec["cb"])
    check(tag + "… Dial: decrement, the selection to the end of the last line", h.lines == ["a = 1", "b = 2", "c", "d = 0x08"],
          h.lines)
    h.lines = ["x 5"]
    h.cursor = pos(0, 0)
    h.sel = None
    h.call(inc["cb"])
    check(tag + "Dial: increment without a selection: at the cursor", h.lines == ["x 6"] and h.cursor == pos(0, 2),
          (h.lines, h.cursor))
    h.lines = ["v[0] = 0", "b = 0", "", "c = 0 + 9"]
    h.sel = rng(0, 5, 3, 5)
    h.call(prog["cb"])
    check(tag + "Dial: add 1, 2, 3 … — from the selection's start on its first line; a line without a number is not counted",
          h.lines == ["v[0] = 1", "b = 2", "", "c = 3 + 9"], h.lines)
    h.sel = None
    h.call(prog["cb"])
    check(tag + "… without a selection: it says to select the lines", "select the lines" in h.messages[-1], h.messages[-1:])
    # vim's visual mode: the selection as ned gives it (the character under the cursor in it, whole lines in V)

    def vm(k, lines, sel, count=1, mode="visual line"):
        """a visual-mode mapping: the lines after it, and the cursor (left alone: ned puts it back itself)"""
        h.vim_mode = mode
        h.lines = list(lines)
        h.sel = sel
        h.cursor = sel["stop"]
        r = h.call(vis[k]["cb"], {"count": count})
        h.vim_mode = ""
        return h.lines if r and "err" not in r else ("error", r), h.cursor

    r = vm("<C-a>", ["a 1", "b 2", "c x", "d 3"], rng(0, 0, 3, 3))
    check(tag + "visual <C-a> (V): the first number of each line; the cursor not moved (ned goes back to normal mode)",
          r == (["a 2", "b 3", "c x", "d 4"], pos(3, 3)), r)
    check(tag + "visual 5<C-a> and 3<C-x>: the count typed in visual mode",
          vm("<C-a>", ["a 1", "b 2"], rng(0, 0, 1, 3), 5)[0] == ["a 6", "b 7"] and
          vm("<C-x>", ["a 1", "b 2"], rng(0, 0, 1, 3), 3)[0] == ["a -2", "b -1"],
          (vm("<C-a>", ["a 1", "b 2"], rng(0, 0, 1, 3), 5), vm("<C-x>", ["a 1", "b 2"], rng(0, 0, 1, 3), 3)))
    check(tag + "visual g<C-a>: one more each line (1, 2, 3, 4); 2g<C-a>: 2, 4, 6, 8",
          vm("g<C-a>", ["0", "0", "0", "0"], rng(0, 0, 3, 1))[0] == ["1", "2", "3", "4"] and
          vm("g<C-a>", ["0", "0", "0", "0"], rng(0, 0, 3, 1), 2)[0] == ["2", "4", "6", "8"],
          vm("g<C-a>", ["0", "0", "0", "0"], rng(0, 0, 3, 1), 2))
    check(tag + "visual g<C-x>: one less each line", vm("g<C-x>", ["5", "5", "5"], rng(0, 0, 2, 1))[0] == ["4", "3", "2"],
          vm("g<C-x>", ["5", "5", "5"], rng(0, 0, 2, 1)))
    r = vm("<C-x>", ["1 5", "7 9"], rng(0, 2, 1, 1), 1, "visual")
    check(tag + "visual <C-x> (v): only what is selected — from column 2 on the first line, up to column 1 on the last",
          r == (["1 4", "6 9"], pos(1, 1)), r)
    r = vm("<C-a>", ["x", "y"], rng(0, 0, 1, 1))
    check(tag + "no number in the selection: a message", r[0] == ["x", "y"] and h.messages[-1] == "Dial: no number in the selection",
          (r, h.messages[-1:]))
    # g<C-a> in normal mode is <C-a>
    check(tag + "g<C-a> and g<C-x> in normal mode: as <C-a> and <C-x>",
          nm("g<C-a>", "x 1", 0, 2)[0] == "x 3" and nm("g<C-x>", "x 1", 0)[0] == "x 0", nm("g<C-a>", "x 1", 0, 2))
