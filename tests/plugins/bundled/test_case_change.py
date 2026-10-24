"""case-change: snake_case, camelCase, PascalCase, UPPER_CASE, kebab-case … — vim-abolish's cr keys, the palette with
selections, acronyms, the cycle, the list to choose from"""
from tplugins import check


def pos(l, c):
    return {"line": l, "col": c}


def rng(l0, c0, l1, c1):
    return {"start": pos(l0, c0), "stop": pos(l1, c1)}


STYLES = ["snake_case", "camelCase", "PascalCase", "UPPER_CASE", "kebab-case", "dot.case", "Title Case", "space case"]


def run(factory, tag):
    h = factory()
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return
    ok = h.pump(lambda j: j.get("t") == "ready", 60)
    check(tag + "it starts", ok, "" if ok else h.p.stderr.read()[-1500:])
    if not ok:
        return
    cmds = {s: h.reg("command", title="Case: to " + s) for s in STYLES}
    nxt = h.reg("command", title="Case: the next case (snake, camel, Pascal, UPPER)")
    cho = h.reg("command", title="Case: choose…")
    vk = ["crs", "crc", "crp", "crm", "cru", "crU", "crk", "cr-", "cr.", "crt", "cr<space>", "crr"]
    maps = {k: h.reg("vimMap", mode="n", keys=k) for k in vk}
    check(tag + "a command for each case, the next case, choose…; vim's cr keys",
          all(cmds.values()) and nxt and cho and all(maps.values()), [k for k, v in maps.items() if not v])

    def cr(k, line, col, lang="plaintext"):
        h.lang = lang
        h.lines = [line]
        h.cursor = pos(0, col)
        h.sel = None
        r = h.call(maps[k]["cb"], {"count": 1})
        h.lang = "plaintext"
        return h.lines[0] if r and "err" not in r else ("error", r)

    check(tag + "user_name: crc userName, crp PascalCase, crm the same, cru USER_NAME, crk user-name, cr. user.name",
          [cr(k, "user_name", 2) for k in ["crc", "crp", "crm", "cru", "crk", "cr."]] ==
          ["userName", "UserName", "UserName", "USER_NAME", "user-name", "user.name"],
          [cr(k, "user_name", 2) for k in ["crc", "crp", "crm", "cru", "crk", "cr."]])
    check(tag + "crt Title Case, cr<space> space case, crU UPPER_CASE, crs back from userName",
          cr("crt", "user_name", 0) == "User Name" and cr("cr<space>", "userName", 0) == "user name" and
          cr("crU", "userName", 0) == "USER_NAME" and cr("crs", "userName", 3) == "user_name",
          (cr("crt", "user_name", 0), cr("cr<space>", "userName", 0)))
    check(tag + "acronyms: HTTPServer → http_server, getHTTPResponse → get_http_response, IOError → io_error, "
          "XMLHttpRequest → xml_http_request",
          cr("crs", "HTTPServer", 0) == "http_server" and cr("crs", "getHTTPResponse", 4) == "get_http_response" and
          cr("crs", "IOError", 0) == "io_error" and cr("crs", "XMLHttpRequest", 0) == "xml_http_request",
          [cr("crs", x, 0) for x in ["HTTPServer", "getHTTPResponse", "IOError", "XMLHttpRequest"]])
    check(tag + "… and back: http_server → httpServer, HTTPServer → httpServer, http_server → HttpServer",
          cr("crc", "http_server", 0) == "httpServer" and cr("crc", "HTTPServer", 0) == "httpServer" and
          cr("crp", "http_server", 0) == "HttpServer", cr("crc", "HTTPServer", 0))
    check(tag + "digits: utf8String → utf8_string, Base64Encode → base64_encode, x86_64 stays itself in camelCase",
          cr("crs", "utf8String", 0) == "utf8_string" and cr("crs", "Base64Encode", 0) == "base64_encode" and
          cr("crc", "x86_64", 0) == "x86_64", (cr("crs", "utf8String", 0), cr("crc", "x86_64", 0)))
    check(tag + "underscores before and after kept: _private_name → _privateName, __init__ → __INIT__",
          cr("crc", "_private_name", 3) == "_privateName" and cr("cru", "__init__", 3) == "__INIT__",
          (cr("crc", "_private_name", 3), cr("cru", "__init__", 3)))
    h.lang = "plaintext"
    r = cr("crs", "let fooBar = 1", 6)
    check(tag + "only the name at the cursor changes, the cursor at its start", r == "let foo_bar = 1" and
          h.cursor == pos(0, 4), (r, h.cursor))
    check(tag + "the cursor before a name: the next one on the line", cr("cru", "  = maxSize", 0) == "  = MAX_SIZE",
          cr("cru", "  = maxSize", 0))
    check(tag + "a - is a minus in Nim (foo-barBaz: only barBaz) and part of the name in CSS (font-size → fontSize)",
          cr("crs", "foo-barBaz", 5, "nim") == "foo-bar_baz" and cr("crc", "a { font-size: 1 }", 6, "css") ==
          "a { fontSize: 1 }", (cr("crs", "foo-barBaz", 5, "nim"), cr("crc", "a { font-size: 1 }", 6, "css")))
    seq_ = []
    t = "foo_bar"
    for _ in range(4):
        t = cr("crr", t, 0)
        seq_.append(t)
    check(tag + "crr goes round: foo_bar → fooBar → FooBar → FOO_BAR → foo_bar",
          seq_ == ["fooBar", "FooBar", "FOO_BAR", "foo_bar"], seq_)
    check(tag + "crr on one word skips what would not change it: foo → Foo; on kebab-case: snake_case",
          cr("crr", "foo", 0) == "Foo" and cr("crr", "a-b", 0, "css") == "a_b", (cr("crr", "foo", 0), cr("crr", "a-b", 0, "css")))
    h.lines = ["  ,,, "]
    h.cursor = pos(0, 0)
    h.call(maps["crs"]["cb"], {"count": 1})
    check(tag + "no name: a message", h.lines == ["  ,,, "] and h.messages[-1] == "Case: no name at the cursor",
          h.messages[-1:])
    cr("crs", "foo_bar", 0)
    check(tag + "already in that case: a message", "written so already" in h.messages[-1], h.messages[-1:])
    # the palette and selections
    h.lines = ["say user name here!"]
    h.sel = rng(0, 4, 0, 18)
    h.call(cmds["snake_case"]["cb"])
    check(tag + "a selected phrase on one line becomes one name", h.lines == ["say user_name_here!"], h.lines)
    h.lines = ["fooBarBaz x"]
    h.sel = rng(0, 0, 0, 8)
    h.call(cmds["kebab-case"]["cb"])
    check(tag + "a selection that ends inside a name takes the whole name",
          h.lines == ["foo-bar-baz x"], h.lines)
    h.lines = ["a = fooBar + bazQux(x)"]
    h.sel = rng(0, 0, 0, 22)
    h.call(cmds["snake_case"]["cb"])
    check(tag + "a selected expression: each name in it", h.lines == ["a = foo_bar + baz_qux(x)"], h.lines)
    h.lines = ["maxSize,", "  minSize", "keep"]
    h.sel = rng(0, 3, 1, 5)
    h.call(cmds["UPPER_CASE"]["cb"])
    check(tag + "a selection on several lines: each name it touches", h.lines == ["MAX_SIZE,", "  MIN_SIZE", "keep"],
          h.lines)
    h.lines = ["userId"]
    h.sel = None
    h.cursor = pos(0, 2)
    h.call(cmds["Title Case"]["cb"])
    check(tag + "the palette without a selection: the name at the cursor", h.lines == ["User Id"], h.lines)
    h.lines = ["my_var"]
    h.call(nxt["cb"])
    check(tag + "Case: the next case", h.lines == ["myVar"], h.lines)
    h.lines = ["my_var = 1"]
    h.cursor = pos(0, 0)
    h.answers["pick"] = 2
    h.call(cho["cb"])
    a = h.asked[-1][1] if h.asked else {}
    check(tag + "Case: choose… — the name in every case (and what each is called); the one picked is written",
          a.get("items") == ["my_var", "myVar", "MyVar", "MY_VAR", "my-var", "my.var", "My Var", "my var"] and
          a.get("details") == STYLES and h.lines == ["MyVar = 1"], (a, h.lines))
    h.answers["pick"] = -1
    h.call(cho["cb"])
    check(tag + "… cancelled: nothing changes", h.lines == ["MyVar = 1"], h.lines)
    h.answers["pick"] = 1
