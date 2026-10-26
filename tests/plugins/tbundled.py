#!/usr/bin/env python3
"""ned's own plugins (plugins/ in the source: off until turned on in the Plugins dock), each played through the
plugin host as ned runs it — the same Host as tplugins.py, with more of ned's side answered (several buffers, the
selection, the clipboard, new tabs, saving).

  python3 tests/plugins/tbundled.py [--native] [NAME …]     all of them, or the ones named

Each plugin's checks are in tests/plugins/bundled/test_<name>.py: a `run(h_factory, tag)` that makes a host for its
plugin (`h = h_factory()`), drives it, and calls `check`. Also checked here: every plugin of plugins/ is in the
list ned has (src/ned/plugins/host.nim, PlugBundledNames), says what it does on its first line, and has its checks.
"""
import os, sys, json, re, shutil, subprocess, tempfile, time, importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import tplugins                                     # noqa: E402  (Host, check, RESULTS)
from tplugins import check                          # noqa: E402

PLUGINS = os.path.join(REPO, "plugins")
TESTS = os.path.join(HERE, "bundled")


class BHost(tplugins.Host):
    """tplugins' Host, with more of ned's side: buffers (id → lines, path, lang), the selection, the clipboard, new
    tabs, a save. `self.lines` and `self.cursor` are the current buffer's (as in Host)."""

    def __init__(self, plugins, native=False, tmp=None):
        super().__init__(plugins, native, tmp)
        self.sel = None                      # the selection: {"start": pos, "stop": pos}, None = the cursor
        self.clip = ""
        self.tabs = []                       # newTab: (title, text, lang)
        self.saved = 0
        self.dirty_ = False
        self.path_ = os.path.join(tmp, "a.txt")
        self.indent_ = "  "
        self.comment = "#"
        self.commands_run = []
        self.terminal = []
        self.others = {}                     # other buffers: id → {"lines", "path", "lang"} (and "cursor", "sel",
        #                                      "dirty", "title" when they have them)
        self.title_ = ""                     # the current buffer's tab name ("" its file's name)
        self.switch_on_new_tab = False       # newTab makes the new tab the current buffer (as ned does)
        self.saved_ids = []                  # markSaved: the buffers
        self.pending = ("", "")              # pendingKeys: the keys waiting and the mode
        self.hints = None                    # showKeyHints: (title, [[key, what] …]); None: none shown
        self.vim_mode = ""                   # vimMode(): normal, insert, visual, visual line ("" not vim)
        self.closed = []                     # closeTab: the buffers
        self.jobs = []                       # shellAsync: (cmd, dir, cb) — run_jobs() runs them and calls back
        self.allowed = {"shell", "network", "files", "clipboard"}   # (what you allowed: ned's tests allow them all)
        self.clock = None                    # unixTime: this (None: the real clock)
        self.indent_styles = []              # indentStyle: each look the plugin gave, in order

    # (another buffer's call: it is made the current one for the call, then put back)
    def _state(self):
        return {"lines": self.lines, "cursor": self.cursor, "path": self.path_, "lang": self.lang, "sel": self.sel,
                "dirty": self.dirty_, "title": self.title_}

    def _load(self, st):
        self.lines = st.get("lines", [""])
        self.cursor = st.get("cursor", {"line": 0, "col": 0})
        self.path_ = st.get("path", "")
        self.lang = st.get("lang", "plaintext")
        self.sel = st.get("sel")
        self.dirty_ = st.get("dirty", False)
        self.title_ = st.get("title", "")

    def switch_to(self, b):
        """buffer b becomes the current one (what current() names)"""
        if b == self.cur or b not in self.others: return
        self.others[self.cur] = self._state()
        st = self.others.pop(b)
        self.cur = b
        self._load(st)

    def api(self, j):
        fn, a = j["fn"], j.get("args", {})
        b = a.get("buf") if isinstance(a, dict) else None
        if b is not None and b != self.cur and b in self.others:
            mine, cur = self._state(), self.cur
            self.cur = b
            self._load(self.others[b])
            try:
                self.api(dict(j, args=dict(a, buf=b)))
            finally:
                self.others[b] = self._state()
                self.cur = cur
                self._load(mine)
            return
        v = None
        if fn == "path": v = self.path_
        elif fn == "selection":
            v = self.sel or {"start": self.cursor, "stop": self.cursor}
        elif fn == "selections":
            v = [self.sel or {"start": self.cursor, "stop": self.cursor}]
        elif fn == "select":
            self.sel = a["range"]
            self.cursor = a["range"]["stop"]
        elif fn == "setCursor":
            self.cursor = a["pos"]
            self.sel = None
        elif fn == "textIn":
            r = a["range"]
            s, e = r["start"], r["stop"]
            if s["line"] == e["line"]:
                v = self.lines[s["line"]][s["col"]:e["col"]]
            else:
                parts = [self.lines[s["line"]][s["col"]:]] + self.lines[s["line"] + 1:e["line"]] + \
                        [self.lines[e["line"]][:e["col"]]]
                v = "\n".join(parts)
        elif fn == "replace":
            self.replace(a["range"], a["text"])
            self.dirty_ = True
        elif fn == "setText":
            self.set_text(a["text"])
            self.dirty_ = True
        elif fn == "clipboard": v = self.clip
        elif fn == "setClipboard": self.clip = a["text"]
        elif fn == "newTab":
            self.tabs.append((a.get("title", ""), a.get("text", ""), a.get("lang", "")))
            v = 100 + len(self.tabs)
            if self.switch_on_new_tab:
                same = [k for k, st in list(self.others.items()) + [(self.cur, self._state())]
                        if st.get("title") == a.get("title") and not st.get("path")]
                if same:
                    v = same[0]
                    if not (self.others.get(v, {}).get("dirty") if v != self.cur else self.dirty_):
                        if v != self.cur: self.others[v]["lines"] = a.get("text", "").split("\n")
                        else: self.lines = a.get("text", "").split("\n")
                else:
                    self.others[v] = {"lines": a.get("text", "").split("\n"), "path": "", "title": a.get("title", ""),
                                      "lang": a.get("lang") or "plaintext", "cursor": {"line": 0, "col": 0}}
                self.switch_to(v)
        elif fn == "title": v = self.title_ or (os.path.basename(self.path_) if self.path_ else "untitled")
        elif fn == "setTitle": self.title_ = a.get("title", "")
        elif fn == "markSaved":
            self.dirty_ = False
            self.saved_ids.append(a.get("buf", self.cur))
        elif fn == "pendingKeys": v = {"keys": self.pending[0], "mode": self.pending[1]}
        elif fn == "showKeyHints":
            self.hints = (a.get("title", ""), a.get("hints", [])) if self.pending[0] else None
            v = bool(self.pending[0])
        elif fn == "hideKeyHints": self.hints = None
        elif fn == "keyMaps":
            v = []
            for r in self.regs:
                k = r.get("kind")
                if k == "vimMap":
                    v.append({"mode": r.get("mode", "n"), "keys": r.get("keys", ""), "desc": r.get("desc", ""),
                              "lang": r.get("lang", ""), "plugin": r.get("plugin", "")})
                elif k in ("operator", "textObject", "langKey"):
                    v.append({"mode": {"operator": "op", "textObject": "obj", "langKey": "key"}[k],
                              "keys": r.get("keys", ""), "desc": r.get("desc", ""), "lang": r.get("lang", ""),
                              "plugin": r.get("plugin", "")})
                elif k == "command" and r.get("keys"):
                    v.append({"mode": "key", "keys": r["keys"], "desc": r.get("title", ""), "lang": "",
                              "plugin": r.get("plugin", "")})
        elif fn == "vimMode": v = self.vim_mode
        elif fn == "closeTab":
            bid = a.get("buf", self.cur)
            self.closed.append(bid)
            if bid in self.others: del self.others[bid]
        elif fn == "unixTime": v = self.clock if self.clock is not None else time.time()
        elif fn == "localTime":
            v = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(self.clock if self.clock is not None else time.time()))
        elif fn == "shellAsync": self.jobs.append((a.get("cmd", ""), a.get("dir") or self.root, a.get("cb")))
        elif fn == "dataDir":
            v = os.path.join(self.tmp, "data", j.get("plugin", ""))
            os.makedirs(v, exist_ok=True)
        elif fn in ("dataRead", "dataWrite"):
            # (as ned: a file of the plugin's own data folder, by a name relative to it)
            name = a.get("name", "")
            if not name or name.startswith("/") or ".." in name.split("/"):
                self.send({"t": "res", "id": j["id"], "err": "not a file of the plugin's data folder"})
                return
            f = os.path.join(self.tmp, "data", j.get("plugin", ""), name)
            if fn == "dataRead":
                v = open(f).read() if os.path.exists(f) else ""
            else:
                os.makedirs(os.path.dirname(f), exist_ok=True)
                with open(f, "a" if a.get("append") else "w") as fh: fh.write(a.get("text", ""))
        elif fn == "allowed": v = a.get("what") in self.allowed
        elif fn == "dirty": v = self.dirty_
        elif fn == "save":
            self.saved += 1
            self.dirty_ = False
        elif fn == "indent": v = self.indent_
        elif fn == "lineComment": v = self.comment
        elif fn == "buffers": v = [self.cur] + list(self.others.keys())
        elif fn == "pluginDir": v = os.path.join(self.tmp, "plugin")
        elif fn == "runCommand":
            self.commands_run.append(a["name"])
            v = True
        elif fn == "terminal": self.terminal.append(a)
        elif fn == "indentStyle": self.indent_styles.append(a)
        else:
            return super().api(j)
        self.send({"t": "res", "id": j["id"], "value": v})


def run_jobs(h, timeout=30):
    """the commands shellAsync gave ned: each run (sh -c, in its folder), then its callback called with the output"""
    while h.jobs:
        cmd, d, cb = h.jobs.pop(0)
        r = subprocess.run(["sh", "-c", cmd], cwd=d, capture_output=True, text=True, timeout=timeout)
        h.call(cb, {"output": (r.stdout + r.stderr).rstrip("\n"), "code": r.returncode})


def pos(l, c):
    return {"line": l, "col": c}


def rng(l0, c0, l1, c1):
    return {"start": pos(l0, c0), "stop": pos(l1, c1)}


def bundled_names():
    """the list ned has (host.nim's PlugBundledNames)"""
    src = open(os.path.join(REPO, "src", "ned", "plugins", "host.nim")).read()
    m = re.search(r"PlugBundledNames = \[(.*?)\]", src, re.S)
    return re.findall(r'"([^"]+)"', m.group(1)) if m else []


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    native = "--native" in sys.argv
    names = bundled_names()
    folders = sorted(d for d in os.listdir(PLUGINS) if os.path.isfile(os.path.join(PLUGINS, d, "plugin.nims")))
    check("every plugin in plugins/ is in ned's list, and every name in the list has its folder",
          sorted(names) == folders, (sorted(set(folders) ^ set(names))))
    for n in folders:
        first = open(os.path.join(PLUGINS, n, "plugin.nims")).readline()
        check(n + ": its first line says what it does (## name — …)",
              first.startswith("## " + n + " — ") and "being written" not in first, first.strip())
        check(n + ": it has its checks (tests/plugins/bundled/test_%s.py)" % n.replace("-", "_"),
              os.path.exists(os.path.join(TESTS, "test_%s.py" % n.replace("-", "_"))))
    tmp = tempfile.mkdtemp(prefix="tbundled-")
    try:
        for n in folders:
            if args and n not in args: continue
            f = os.path.join(TESTS, "test_%s.py" % n.replace("-", "_"))
            if not os.path.exists(f): continue
            spec = importlib.util.spec_from_file_location("test_" + n.replace("-", "_"), f)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            for nat in ([False, True] if native else [False]):
                d = os.path.join(tmp, n + ("-native" if nat else ""))
                os.makedirs(d)
                made = []

                def factory(extra=None, _n=n, _d=d, _nat=nat):
                    k = len(made)
                    t = os.path.join(_d, "h%d" % k)
                    os.makedirs(t)
                    plugs = [(_n, os.path.join(PLUGINS, _n))] + (extra or [])
                    h = BHost(plugs, native=_nat, tmp=t)
                    made.append(h)
                    return h
                tag = n + (" (compiled)" if nat else "") + ": "
                try:
                    mod.run(factory, tag)
                except Exception as e:                       # (a check that broke: counted, the rest go on)
                    import traceback
                    check(tag + "its checks ran to the end", False, traceback.format_exc()[-1600:])
                finally:
                    for h in made: h.close()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    failed = [x for x, ok in tplugins.RESULTS if not ok]
    print("\n%d checks, %d failed" % (len(tplugins.RESULTS), len(failed)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
