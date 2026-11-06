"""What the language plugins (zig, julia, ocaml, crystal, dart, clojure) are checked for, the same way for each: the
language's spec, its snippets, the outline from the plugin without a language server, F5's command, and the language
server and formatter — found on PATH (pretend programs here), given by the plugin's settings, or "off"."""
import atexit, os, shutil, stat, subprocess, tempfile
from tplugins import check


def fake_tools(d, names):
    """pretend programs: each prints its name, its arguments and its folder, then what it was given"""
    os.makedirs(d, exist_ok=True)
    for n in names:
        p = os.path.join(d, n)
        with open(p, "w") as f:
            f.write('#!/bin/sh\necho "%s $*"\necho "in $PWD"\ncat\n' % n)
        os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC)


_SYSTEM = {}


def system_dirs(hide=()):
    """/usr/bin and /bin — or, with programs to hide, a folder of links to everything in them but those: a machine that
    has a tool installed (gh, gfortran on GitHub's) still runs the checks of what happens without it"""
    if not hide:
        return ["/usr/bin", "/bin"]
    key = tuple(sorted(hide))
    if key not in _SYSTEM:
        d = tempfile.mkdtemp(prefix="ned-sysbin-")
        atexit.register(shutil.rmtree, d, True)
        for src in ["/usr/bin", "/bin"]:
            if not os.path.isdir(src):
                continue
            for n in os.listdir(src):
                if n in hide or os.path.lexists(os.path.join(d, n)):
                    continue
                try:
                    os.symlink(os.path.join(src, n), os.path.join(d, n))
                except OSError:
                    pass
        _SYSTEM[key] = [d]
    return _SYSTEM[key]


def start(factory, path_dirs=(), settings=None, only_path=False, hide=()):
    old = os.environ.get("PATH", "")
    if path_dirs:
        # (only_path: the pretend programs, nim (it runs the plugin) and the system's own — none of your tools; hide:
        # those left out of the system's too)
        nim = os.path.dirname(shutil.which("nim") or "/usr/bin/nim")
        os.environ["PATH"] = os.pathsep.join(list(path_dirs) + ([nim] + system_dirs(hide) if only_path else [old]))
    try:
        h = factory()
    finally:
        os.environ["PATH"] = old
    h.settings = dict(settings or {})
    ok = h.build_ok and h.pump(lambda j: j.get("t") == "ready", 90)
    return h, ok, (h.build_err if not h.build_ok else "")


def ned_cmd(cmd, path, tmp):
    return (cmd.replace("$file", path).replace("$dir", os.path.dirname(path))
            .replace("$name", os.path.splitext(os.path.basename(path))[0]).replace("$tmp", tmp)
            .replace("$root", os.path.dirname(path)))


def run_sh(cmd, cwd, path_dirs, stdin="", hide=()):
    env = dict(os.environ, PATH=os.pathsep.join(list(path_dirs) + system_dirs(hide)))
    r = subprocess.run(["sh", "-c", cmd], cwd=cwd, input=stdin, capture_output=True, text=True, env=env, timeout=30)
    return r.stdout + r.stderr


def nested(body):
    i = body.find("${")
    while i >= 0:
        e = body.find("}", i)
        if e < 0 or "${" in body[i + 2:e]:
            return True
        i = body.find("${", e)
    return False


def done(h):
    h.close()
    h.close = lambda: None


def check_language(factory, tag, lang, spec, snippets, sample, symbols, tools, runs=(), server=None, formatter=None):
    """lang: its id · spec: the LangSpec fields that must be so (a set: those words among them) · snippets: their
    triggers · sample, symbols: the outline of the sample, as (name, kind, depth) · tools: the programs ned may find
    (pretend ones) · runs: (file name, its text, the files beside it, what F5 runs first: its output's first line) ·
    server, formatter: the commands used when their programs are found (None: none by default)"""
    tmp = tempfile.mkdtemp(prefix="ned-lang-")
    try:
        _check(factory, tag, tmp, lang, spec, snippets, sample, symbols, tools, runs, server, formatter)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _check(factory, tag, tmp, lang, spec, snippets, sample, symbols, tools, runs, server, formatter):
    bare = os.path.join(tmp, "bare")
    os.makedirs(bare)
    h, ok, err = start(factory, [bare], only_path=True)
    check(tag + "it starts", ok, err)
    if not ok:
        return
    sp = (h.reg("language", id=lang) or {}).get("spec", {})
    bad = []
    for k, v in spec.items():
        got = sp.get(k)
        if isinstance(v, set):
            if not v <= set(got or []): bad.append((k, sorted(v - set(got or []))))
        elif got != v: bad.append((k, got))
    check(tag + "the language: " + ", ".join(sorted(spec)), not bad, bad)
    trig = {r["trigger"] for r in h.regs if r["kind"] == "snippet" and r["lang"] == lang}
    check(tag + "snippets: " + " ".join(sorted(snippets)), trig == set(snippets) and
          not any(nested(r["body"]) for r in h.regs if r["kind"] == "snippet"), sorted(trig))
    check(tag + "its programs not installed: no language server, the outline from the plugin, no formatter",
          h.reg("lsp", lang=lang) is None and h.reg("symbols", lang=lang) is not None and
          h.reg("formatter", lang=lang) is None, [r for r in h.regs if r["kind"] in ("lsp", "formatter")])
    if h.reg("symbols", lang=lang):
        h.lines = sample
        r = h.call(h.reg("symbols", lang=lang)["cb"], {"buf": 1})
        got = [(s["name"], s["kind"], s["depth"]) for s in (r or {}).get("value") or []]
        check(tag + "the outline of a sample (comments and strings left out)", got == symbols, got)
    run_cmd = sp.get("run", "")
    fake = os.path.join(tmp, "bin")
    fake_tools(fake, list(tools) + ["my-lsp", "my-fmt"])
    for (name, text, beside, want) in runs:
        d = os.path.join(tmp, "proj-" + name.replace("/", "_"))
        f = os.path.join(d, name)
        os.makedirs(os.path.dirname(f), exist_ok=True)
        open(f, "w").write(text)
        for b, t in beside.items():
            os.makedirs(os.path.dirname(os.path.join(d, b)), exist_ok=True)
            open(os.path.join(d, b), "w").write(t)
        o = run_sh(ned_cmd(run_cmd, f, "/T"), os.path.dirname(f), [fake])
        first = o.split("\n")[0]
        check(tag + "F5 on " + name + (" (with " + ", ".join(beside) + ")" if beside else "") + ": " + want,
              first == want.replace("$file", f).replace("$d", d), o)
    done(h)
    # the programs installed (pretend ones): their server and formatter
    h, ok, err = start(factory, [fake], only_path=True)
    ls = h.reg("lsp", lang=lang) if ok else None
    fm = h.reg("formatter", lang=lang) if ok else None
    if server:
        check(tag + "installed: " + " ".join(server) + " is the language server (no outline of the plugin's)",
              ok and ls and ls["cmd"] == server and h.reg("symbols", lang=lang) is None, (err, ls))
    else:
        check(tag + "no language server unless one is set", ok and ls is None, ls)
    if formatter:
        check(tag + "installed: " + formatter + " formats", fm and fm.get("cmd") == formatter, fm)
    else:
        check(tag + "no formatter unless one is set", ok and fm is None, fm)
    done(h)
    # the settings: another command; "off"
    h, ok, err = start(factory, [fake], {"server": "my-lsp --stdio", "formatter": "off"}, only_path=True)
    ls = h.reg("lsp", lang=lang) if ok else None
    check(tag + "its server setting: the command given; formatter \"off\": none",
          ok and ls and ls["cmd"] == ["my-lsp", "--stdio"] and h.reg("formatter", lang=lang) is None, (err, ls))
    done(h)
    h, ok, err = start(factory, [fake], {"server": "off", "formatter": "my-fmt -"}, only_path=True)
    fm = h.reg("formatter", lang=lang) if ok else None
    check(tag + "server \"off\": none (the plugin's outline); another formatter's command",
          ok and h.reg("lsp", lang=lang) is None and h.reg("symbols", lang=lang) is not None and fm and
          fm.get("cmd") == "my-fmt -", (err, fm))
    done(h)
