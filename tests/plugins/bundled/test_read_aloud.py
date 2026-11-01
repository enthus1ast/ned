"""read-aloud: the selection (or the line) read by the first speaker installed (a pretend espeak-ng on PATH), as
plain words, at the rate set; the file from the cursor; none installed: what to install; your own program; stop ends
the reading that goes on."""
import os, subprocess, tempfile, time
from tplugins import check
from tbundled import run_jobs, rng, pos

FAKE = '#!/bin/sh\nprintf "%s|" "$(basename "$0")" "$@" >> "$SPEAK_LOG"\nfor a in "$@"; do last="$a"; done\ncat "$last" >> "$SPEAK_LOG"; echo >> "$SPEAK_LOG"\n'


def run(factory, tag):
    base = tempfile.mkdtemp(prefix="read-aloud-")
    tools = os.path.join(base, "bin")
    os.makedirs(tools)
    p = os.path.join(tools, "espeak-ng")
    open(p, "w").write(FAKE)
    os.chmod(p, 0o755)
    log = os.path.join(base, "log.txt")
    os.environ["SPEAK_LOG"] = log
    old = os.environ["PATH"]
    os.environ["PATH"] = tools + ":" + old
    try:
        h = factory()
        if not h.build_ok:
            check(tag + "the host compiles", False, h.build_err)
            return
        if not h.pump(lambda j: j.get("t") == "ready", 90):
            h.p.kill()
            check(tag + "it starts", False, h.p.stderr.read()[-1500:])
            return
        check(tag + "it starts (%s ms)" % h.ready_ms, True)
        h.lines = ["let userName = get_value(x)", "echo userName", "", "# the end"]
        h.sel = rng(0, 0, 0, 27)
        h.call(h.reg("command", title="Read aloud: the selection")["cb"])
        h.sel = None
        msg = h.messages[-1]
        run_jobs(h)
        l1 = open(log).read() if os.path.exists(log) else ""
        check(tag + "the selection, read by espeak-ng (the first installed), as words: camelCase and _ apart",
              msg.startswith("🔊 Reading ") and "with espeak-ng" in msg and
              l1.startswith("espeak-ng|-s|175|-f|") and l1.endswith("let user Name get value x\n"), (msg, l1))
        h.settings = {"rate": 2.0, "plain": False}
        h.cursor = pos(1, 5)
        h.call(h.reg("command", title="Read aloud: the file")["cb"])
        run_jobs(h)
        l2 = open(log).read()[len(l1):]
        check(tag + "the file from the cursor on; the rate (2.0: 350 words a minute); plain off: as written",
              l2.startswith("espeak-ng|-s|350|-f|") and "userName\n\n# the end" in l2, l2)
        # stop: the reading going on ends
        sl = subprocess.Popen(["sleep", "30"])
        open(os.path.join(h.tmp, "data", "read-aloud", "speaking.pid"), "w").write(str(sl.pid))
        h.call(h.reg("command", title="Read aloud: stop")["cb"])
        time.sleep(0.3)
        gone = sl.poll() is not None
        if not gone: sl.kill()
        stopped = h.messages[-1]
        h.call(h.reg("command", title="Read aloud: stop")["cb"])
        check(tag + "stop: the reading ends; again: nothing is being read", gone and stopped == "Read aloud: stopped" and
              h.messages[-1] == "Read aloud: nothing is being read", (gone, stopped, h.messages[-1:]))
        # your own program; none at all
        h.settings = {"command": "espeak-ng"}
        h.sel = rng(0, 0, 0, 3)
        h.call(h.reg("command", title="Read aloud: the selection")["cb"])
        run_jobs(h)
        own = h.messages[-1]
        h.settings = {"command": "/nonexistent/none"}
        h.call(h.reg("command", title="Read aloud: the selection")["cb"])
        run_jobs(h)
        h.sel = None
        check(tag + "plugins.read-aloud.command: the program you name", own.endswith("with espeak-ng (Read aloud: stop)"),
              own)
    finally:
        os.environ["PATH"] = old
    h2 = factory()
    if not h2.build_ok or not h2.pump(lambda j: j.get("t") == "ready", 90):
        check(tag + "it starts without a speaker", False)
        return
    os.environ["PATH"] = "/nonexistent-dir:" + old
    try:
        h2.lines = ["hello"]
        h2.call(h2.reg("command", title="Read aloud: the selection")["cb"])
    finally:
        os.environ["PATH"] = old
    import shutil
    if shutil.which("espeak-ng") or shutil.which("espeak") or shutil.which("spd-say") or shutil.which("say") or \
       shutil.which("termux-tts-speak"):
        return                                   # (a real one installed here: nothing to say)
    check(tag + "none installed: what to install", h2.messages[-1].startswith("Read aloud: no program to speak with"),
          h2.messages[-1:])
