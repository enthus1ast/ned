"""notify-done: a run that ended quickly says nothing; a long one a note (✓ done in …, ✗ failed (exit code …) after …)
and the system's notification — Termux:API's, with a buzz when it failed — through pretend notifiers on PATH;
notify-send where there is no Termux; the system's off by a setting; Notify: test it says what reached you."""
import os, tempfile
from tplugins import check
from tbundled import run_jobs

FAKE = '#!/bin/sh\nprintf "%s|" "$(basename "$0")" "$@" >> "$NOTIFY_LOG"; echo >> "$NOTIFY_LOG"\n'


def fake_tools(d, names):
    os.makedirs(d, exist_ok=True)
    for n in names:
        p = os.path.join(d, n)
        open(p, "w").write(FAKE)
        os.chmod(p, 0o755)


def start(factory, tag, path, settings=None):
    old = os.environ.get("PATH", "")
    os.environ["PATH"] = path + ":" + old           # (the pretend notifiers first; nim stays on it for the host)
    try:
        h = factory()
    finally:
        os.environ["PATH"] = old
    if settings: h.settings = settings
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
    base = tempfile.mkdtemp(prefix="notify-done-")
    termux, desk = os.path.join(base, "termux"), os.path.join(base, "desk")
    fake_tools(termux, ["termux-notification", "termux-vibrate"])
    fake_tools(desk, ["notify-send"])
    log = os.path.join(base, "log.txt")
    os.environ["NOTIFY_LOG"] = log
    h = start(factory, tag, termux)
    if not h:
        return
    done = h.reg("event", event="jobDone")
    check(tag + "it listens for runs that end", done is not None, [r["kind"] for r in h.regs])
    n0 = len(h.messages)
    h.call(done["cb"], {"title": "nim c -r app.nim", "code": 0, "seconds": 3.0})
    check(tag + "a quick one (3 s): nothing", len(h.messages) == n0 and not h.jobs, h.messages[n0:])
    old = os.environ["PATH"]
    os.environ["PATH"] = termux + ":" + old
    h.call(done["cb"], {"title": "nimble test", "code": 0, "seconds": 42.4})
    ok_note = h.messages[-1]
    run_jobs(h)
    l1 = open(log).read() if os.path.exists(log) else ""
    h.call(done["cb"], {"title": "nimble build", "code": 1, "seconds": 185.0})
    bad_note = h.messages[-1]
    run_jobs(h)
    l2 = open(log).read()[len(l1):] if os.path.exists(log) else ""
    os.environ["PATH"] = old
    check(tag + "a long one: a note (✓ done in 42 s), Termux's notification with it",
          ok_note == "✓ nimble test — done in 42 s" and
          l1.strip() == "termux-notification|--id|ned-notify-done|--title|ned: done|--content|✓ nimble test — done in 42 s|",
          (ok_note, l1))
    check(tag + "one that failed: ✗ … (exit code 1) after 3 min 5 s, a notification and a buzz",
          bad_note == "✗ nimble build — failed (exit code 1) after 3 min 5 s" and
          "termux-notification|--id|ned-notify-done|--title|ned: failed|" in l2 and "termux-vibrate|-d|400|" in l2,
          (bad_note, l2))
    h.call(h.reg("command", title="Notify: test it")["cb"])
    check(tag + "Notify: test it — a note, and what the notification went through",
          h.messages[-1] == "Notify: a note, and a notification through termux-notification", h.messages[-2:])
    # a desktop: notify-send; the system's off; minSeconds
    h2 = start(factory, tag + "desktop: ", desk, {"minSeconds": 5})
    if not h2:
        return
    os.environ["PATH"] = desk + ":" + old
    d2 = h2.reg("event", event="jobDone")["cb"]
    h2.call(d2, {"title": "make", "code": 2, "seconds": 6.0})
    run_jobs(h2)
    l3 = open(log).read()[len(l1) + len(l2):]
    h2.settings = {"minSeconds": 5, "system": False}
    h2.call(d2, {"title": "make", "code": 0, "seconds": 9.0})
    n_jobs = len(h2.jobs)
    h2.call(h2.reg("command", title="Notify: test it")["cb"])
    os.environ["PATH"] = old
    check(tag + "a desktop: notify-send (urgent when it failed); minSeconds 5; the system's off: the note alone",
          l3.strip() == "notify-send|-u|critical|ned: failed|✗ make — failed (exit code 2) after 6 s|" and
          n_jobs == 0 and h2.messages[-1].startswith("Notify: a note (the system's notifications are off"),
          (l3, n_jobs, h2.messages[-1:]))
