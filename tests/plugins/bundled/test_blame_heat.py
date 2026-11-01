"""blame-heat: git blame's porcelain read (times, a line not committed yet); the file tinted a run of lines at a
time by age — hot, warm, mild, old untinted — with the counts; following the files you go to and save while on; off
clears; the ages counted without tinting; a file git does not know."""
import os, subprocess, time
from tplugins import check
from tbundled import run_jobs


def git(d, *a, env=None):
    e = dict(os.environ, **(env or {}))
    subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *a], cwd=d, capture_output=True, check=True,
                   env=e)


def run(factory, tag):
    h = factory()
    root = h.tmp
    f = os.path.join(root, "a.txt")
    now = int(time.time())
    git(root, "init", "-q")
    # lines 1-2 a year old, 3 twenty days old, 4-5 three days old, 6 an hour old, 7 not committed
    for lines, age in [(["old one", "old two"], 365), (["twenty"], 20), (["three a", "three b"], 3), (["hour"], 0.04)]:
        with open(f, "a") as fh:
            for l in lines: fh.write(l + "\n")
        when = "%d +0000" % (now - int(age * 86400))
        git(root, "add", "a.txt")
        git(root, "commit", "-qm", "x", env={"GIT_AUTHOR_DATE": when, "GIT_COMMITTER_DATE": when})
    with open(f, "a") as fh: fh.write("new\n")
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return
    if not h.pump(lambda j: j.get("t") == "ready", 90):
        h.p.kill()
        check(tag + "it starts", False, h.p.stderr.read()[-1500:])
        return
    check(tag + "it starts (%s ms)" % h.ready_ms, True)
    h.clock = now
    h.path_ = f
    h.lines = open(f).read().rstrip("\n").split("\n")
    toggle = h.reg("command", title="Blame heat: on/off")["cb"]
    h.call(toggle)
    run_jobs(h)
    hl = [(a["range"]["start"]["line"], a["range"]["stop"]["line"], a["color"]) for k, a in h.decor if k == "highlight"]
    check(tag + "on: the lines tinted by age, a run at a time — this week warm (3-4), today and not committed hot "
          "(5-6), this month mild (2); a year old untinted",
          sorted(hl) == [(2, 2, "info"), (3, 4, "warn"), (5, 6, "del")] and
          h.messages[-1] == "Blame heat: 2 hot · 2 warm · 1 mild · 2 older", (hl, h.messages[-1:]))
    h.settings = {"days": 400, "hotDays": 5}
    h.call(h.reg("event", event="save")["cb"], {"buf": h.cur, "path": f, "lang": "plaintext"})
    run_jobs(h)
    hl2 = [(a["range"]["start"]["line"], a["range"]["stop"]["line"], a["color"]) for k, a in h.decor if k == "highlight"]
    check(tag + "on save, again (cleared first); the settings: days 400, hotDays 5",
          "clearDecorations" in h.calls_seen and sorted(hl2) == [(0, 2, "info"), (3, 6, "del")], hl2)
    h.call(toggle)
    check(tag + "off: cleared, it says so", h.decor == [] and h.messages[-1] == "Blame heat off", (h.decor, h.messages[-1:]))
    h.call(h.reg("event", event="enter")["cb"], {"buf": h.cur, "path": f, "lang": "plaintext"})
    check(tag + "off: going to a file does nothing", not h.jobs, h.jobs)
    h.settings = {}
    h.call(h.reg("command", title="Blame heat: the file's ages")["cb"])
    run_jobs(h)
    check(tag + "the file's ages: counted, nothing tinted", h.decor == [] and
          h.messages[-1] == "Blame heat: 2 hot · 2 warm · 1 mild · 2 older", (h.decor, h.messages[-1:]))
    other = os.path.join(root + "-elsewhere", "b.txt")
    os.makedirs(os.path.dirname(other), exist_ok=True)
    open(other, "w").write("x\n")
    h.path_ = other
    h.call(h.reg("command", title="Blame heat: the file's ages")["cb"])
    run_jobs(h)
    check(tag + "a file git does not know: it says so", h.messages[-1] == "Blame heat: git does not know b.txt",
          h.messages[-1:])
