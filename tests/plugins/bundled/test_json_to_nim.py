"""json-to-nim: Nim types from JSON — where the JSON comes from (the selection, the clipboard, a .json file, a
project's file picked), where the code goes (a new tab, the cursor of a .nim file), the types themselves (nested
arrays, nulls and missing keys, mixed values, keywords and keys that are not names, shapes reused, tables), and the
code checked by nim: it reads the sample with std/json's `to`."""
import json, os, shutil, subprocess
from tplugins import check

SAMPLE = {
    "id": 7, "name": "Ann", "score": 9.5, "active": True, "type": "admin",
    "first-name": "Ann", "_id": "abc", "2fa": False, "userName": "ann", "username": "ann2",
    "tags": ["a", "b"], "matrix": [[1, 2], [3, 4.5]],
    "home_address": {"street": "Main", "city": "Sohar"},
    "billing": {"street": "x", "city": "y"},
    "orders": [
        {"id": 1, "total": 10, "note": None, "items": [{"sku": "A", "qty": 1}]},
        {"id": 2, "total": 12.5, "items": [], "coupon": "X"},
        {"id": 3, "total": 3, "note": "fast", "items": [{"sku": "B", "qty": 2, "gift": True}]},
    ],
    "mixed": [1, "two", None], "extra": None, "meta": {},
    "byId": {"1": {"n": 1}, "2": {"n": 2}},
    "nested": {"deeper": {"deepest": {"x": 1}}},
}


def rng(l0, c0, l1, c1):
    return {"start": {"line": l0, "col": c0}, "stop": {"line": l1, "col": c1}}


def start(factory, tag):
    h = factory()
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return None
    ok = h.pump(lambda j: j.get("t") == "ready", 90)
    if not ok:
        h.p.kill()
        check(tag + "it starts", False, h.p.stderr.read()[-1500:])
        return None
    check(tag + "it starts (%s ms)" % h.ready_ms, True)
    return h


def field(code, typ, name):
    """the declaration of a field of a type in the code ("" when it has none)"""
    inside = False
    for l in code.split("\n"):
        if l.startswith("  ") and not l.startswith("    "):
            inside = l.strip().startswith(typ + "* = object")
            continue
        if inside and l.strip().split("*:")[0] in (name, "`%s`" % name):
            return l.strip()
    return ""


def run(factory, tag):
    h = start(factory, tag)
    if not h:
        return
    cmd = h.reg("command", title="JSON → Nim types")
    check(tag + "its command, the ned it needs, its setting",
          cmd is not None and h.reg("requires")["spec"] == ">= 6.25" and
          h.reg("setting", key="rootName")["default"] == "Root", h.regs)
    # the selection, in a text file: a new tab
    text = json.dumps(SAMPLE, indent=2)
    h.lines = text.split("\n")
    h.path_ = os.path.join(h.tmp, "notes.txt")
    h.lang = "plaintext"
    h.sel = rng(0, 0, len(h.lines) - 1, len(h.lines[-1]))
    h.clip = "not json"
    r = h.call(cmd["cb"])
    tab = h.tabs[-1] if h.tabs else ("", "", "")
    code = tab[1]
    check(tag + "the selection: the types in a tab (Root.nim, Nim), the text left as it was",
          r and "err" not in r and tab[0] == "Root.nim" and tab[2] == "nim" and h.lines == text.split("\n") and
          h.messages[-1] == "Nim types from the selection are in Root.nim", (r, tab[0], tab[2], h.messages[-1:]))
    check(tag + "the imports it needs, then `type Root* = object`",
          code.startswith("import std/[json, options, tables]\n\ntype\n  Root* = object\n"), code[:200])
    want = {"id": "id*: int", "score": "score*: float", "active": "active*: bool", "name": "name*: string",
            "tags": "tags*: seq[string]", "matrix": "matrix*: seq[seq[float]]", "mixed": "mixed*: seq[JsonNode]",
            "extra": "extra*: JsonNode", "meta": "meta*: JsonNode", "byId": "byId*: Table[string, ByIdItem]"}
    got = {k: field(code, "Root", k) for k in want}
    check(tag + "fields typed from the values: int, float, bool, string, seq[seq[float]] (ints and floats merged), "
          "mixed values and null as JsonNode, a table for keys that are not names", got == want, (got, code))
    check(tag + "a keyword as a key: in backticks", field(code, "Root", "type") == "`type`*: string", code)
    renamed = [field(code, "Root", f) for f in ("firstName", "id2", "n2fa", "username2")]
    check(tag + "keys that are not Nim names (first-name, _id, 2fa) and one Nim takes for another (username "
          "beside userName): fields of other names, each with the key in a comment",
          renamed[0].startswith("firstName*: string") and renamed[0].endswith('# the key "first-name"') and
          renamed[1].endswith('# the key "_id"') and renamed[2].startswith("n2fa*: bool") and
          renamed[3].endswith('# the key "username"') and field(code, "Root", "userName") == "userName*: string",
          (renamed, code))
    check(tag + "… and a renameHook for jsony that maps them",
          '#   proc renameHook*(v: var Root, fieldName: var string) =' in code and
          '#     of "first-name": fieldName = "firstName"' in code and '#     of "_id": fieldName = "id2"' in code, code)
    check(tag + "nested objects: types of their own, named from the key (home_address → HomeAddress), "
          "the same shape reused (billing)",
          field(code, "Root", "home_address") == "home_address*: HomeAddress" and
          field(code, "Root", "billing") == "billing*: HomeAddress" and code.count("HomeAddress* = object") == 1 and
          field(code, "Root", "nested") == "nested*: Nested" and field(code, "Deeper", "deepest") == "deepest*: Deepest",
          code)
    check(tag + "an array of objects: seq of one type from all the elements (orders → Order); a key missing in "
          "some or null is an Option",
          field(code, "Root", "orders") == "orders*: seq[Order]" and field(code, "Order", "total") == "total*: float"
          and field(code, "Order", "note").startswith("note*: Option[string]") and
          field(code, "Order", "coupon").startswith("coupon*: Option[string]") and
          field(code, "Order", "items") == "items*: seq[Item]" and
          field(code, "Item", "gift").startswith("gift*: Option[bool]") and field(code, "Item", "qty") == "qty*: int",
          code)
    check(tag + "it ends with the example: parseJson(text).to(Root)",
          code.rstrip().endswith("# let data = text.fromJson(Root)         # jsony") and
          "# let data = parseJson(text).to(Root)" in code, code[-200:])
    # the code, checked by nim: the sample read with std/json's `to` (the keys renamed as the comment says)
    d = os.path.join(h.tmp, "nimcheck")
    os.makedirs(d, exist_ok=True)
    open(os.path.join(d, "sample.json"), "w").write(text)
    prog = code + '''
let j = parseJson(readFile("sample.json"))
for (k, f) in [("first-name", "firstName"), ("_id", "id2"), ("2fa", "n2fa"), ("username", "username2")]: j[f] = j[k]
let data = j.to(Root)
echo data.orders[1].note.isNone, " ", data.orders[2].items[0].gift.get, " ", data.matrix[1][1], " ",
  data.byId["2"].n, " ", data.nested.deeper.deepest.x, " ", data.billing.city, " ", data.`type`, " ",
  data.firstName, " ", data.mixed[1], " ", data.extra.kind
'''
    open(os.path.join(d, "check.nims"), "w").write(prog)
    p = subprocess.run(["nim", "e", "--hints:off", "check.nims"], cwd=d, capture_output=True, text=True, timeout=120)
    check(tag + "nim takes the code, and std/json's `to` reads the sample into it",
          p.returncode == 0 and p.stdout.strip() == 'true true 4.5 2 1 y admin Ann "two" JNull',
          (p.stdout + p.stderr)[-600:])
    # the clipboard, in a .nim file: at the cursor, without the imports the file has
    h.sel = None
    h.path_ = os.path.join(h.tmp, "app.nim")
    h.lang = "nim"
    h.lines = ["import std/json", "", "proc main() = discard"]
    h.cursor = {"line": 1, "col": 0}
    h.clip = '{"name": "x", "port": null, "hosts": [{"addr": "a", "up": true}, {"addr": "b"}]}'
    n = len(h.tabs)
    h.call(cmd["cb"])
    t = "\n".join(h.lines)
    check(tag + "the clipboard, in a .nim file: inserted at the cursor (a blank line), only the import it lacks",
          len(h.tabs) == n and h.lines[0] == "import std/json" and h.lines[1] == "import std/options" and
          "  Root* = object" in t and "    port*: Option[JsonNode]" not in t and "    port*: JsonNode" in t and
          "    hosts*: seq[Host]" in t and "    `addr`*: string" in t and "    up*: Option[bool]" in t and
          h.lines[-1] == "proc main() = discard" and h.messages[-1] == "Nim types from the clipboard added at line 2",
          (h.lines, h.messages[-1:]))
    h.lines = ["let x = 1"]
    h.cursor = {"line": 0, "col": 3}
    h.clip = '[1, 2]'
    h.settings = {"rootName": "Numbers"}
    h.call(cmd["cb"])
    check(tag + "on a line with text: on the next line; the rootName setting names the top-level type",
          h.lines[:5] == ["let x = 1", "import std/json", "", "type", "  Numbers* = seq[int]"] and
          "# let data = parseJson(text).to(Numbers)" in "\n".join(h.lines), h.lines)
    h.settings = {}
    # the .json file you are in (the clipboard is not JSON): a new tab; an array at the top
    h.path_ = os.path.join(h.tmp, "list.json")
    h.lang = "json"
    h.lines = ['[{"x": 1, "tags": []}, {"x": 2, "y": "a", "tags": ["t"]}]']
    h.clip = "hello"
    h.call(cmd["cb"])
    code = h.tabs[-1][1] if len(h.tabs) > n else ""
    check(tag + "a .json file: the whole file; an array at the top is a seq of its elements' type",
          "  Root* = seq[RootItem]\n  RootItem* = object\n    x*: int\n" in code and
          "    y*: Option[string]  # not in every object" in code and "    tags*: seq[string]" in code and
          h.messages[-1] == "Nim types from list.json are in Root.nim", (code, h.messages[-1:]))
    # not JSON
    h.path_ = os.path.join(h.tmp, "notes.txt")
    h.lang = "plaintext"
    h.lines = ['{"a": 1,,}']
    h.sel = rng(0, 0, 0, 10)
    k = len(h.tabs)
    h.call(cmd["cb"])
    check(tag + "a selection that is not JSON: a warning that says why, no tab",
          len(h.tabs) == k and h.messages[-1].startswith("JSON → Nim types: the selection is not JSON ("), h.messages[-1:])
    h.sel = None
    h.clip = ""
    h.call(cmd["cb"])
    check(tag + "nothing to read: it says what to do",
          h.messages[-1] == "JSON → Nim types: select some JSON, copy it, or open a .json file first", h.messages[-1:])
    # a .nim file with nothing selected and no JSON copied: a .json file of the project, picked
    proj = os.path.join(h.tmp, "proj")
    os.makedirs(os.path.join(proj, "cfg"), exist_ok=True)
    open(os.path.join(proj, "cfg", "app settings.json"), "w").write('{"debug": false, "level": 3}')
    open(os.path.join(proj, "readme.md"), "w").write("x")
    h.root = proj
    h.path_ = os.path.join(proj, "src.nim")
    h.lang = "nim"
    h.lines = [""]
    h.cursor = {"line": 0, "col": 0}
    h.answers["pick"] = 0
    h.call(cmd["cb"])
    a = h.asked[-1] if h.asked else ("", {})
    check(tag + "a .nim file, nothing selected or copied: the project's .json files to pick from (a space in the "
          "name), the types at the cursor",
          a[0] == "pick" and a[1]["items"] == ["cfg/app settings.json"] and "    debug*: bool" in "\n".join(h.lines) and
          h.messages[-1] == "Nim types from cfg/app settings.json added at line 1", (a, h.lines, h.messages[-1:]))
    h.root = h.tmp
    # the assistant's tool
    tool = h.reg("aiTool", name="json_to_nim")
    r = h.call(tool["cb"], {"json": '{"ok": true}', "name": "Reply"})
    r2 = h.call(tool["cb"], {"json": "nope", "name": ""})
    check(tag + "the assistant's json_to_nim (it only reads): the code, an error for what is not JSON",
          tool["readOnly"] is True and "  Reply* = object\n    ok*: bool" in ((r or {}).get("value") or "") and
          ((r2 or {}).get("err") or "").startswith("not JSON"), (tool, r, r2))
    # the tab again: the same one, its text replaced — unless you have changed it
    h.path_ = os.path.join(h.tmp, "notes.txt")
    h.lang = "plaintext"
    h.switch_on_new_tab = True
    h.lines = ['{"a": 1}']
    h.sel = rng(0, 0, 0, 8)
    h.call(cmd["cb"])
    first = h.cur
    h.switch_to(1)
    h.lines = ['{"b": "x"}']
    h.sel = rng(0, 0, 0, 10)
    h.call(cmd["cb"])
    second, text2 = h.cur, "\n".join(h.lines)
    h.dirty_ = True
    h.switch_to(1)
    h.call(cmd["cb"])
    check(tag + "again: the same tab, the new types in it; a tab of types you changed is kept, the new ones in "
          "Root (2).nim",
          first != 1 and second == first and "    b*: string" in text2 and "    a*: int" not in text2 and
          h.cur not in (1, first) and h.tabs[-1][0] == "Root (2).nim" and
          h.messages[-1] == "Nim types from the selection are in Root (2).nim", (first, second, h.cur, h.tabs[-1][:1]))
    h.switch_on_new_tab = False
