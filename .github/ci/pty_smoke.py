#!/usr/bin/env python3
"""Runs ned in a real pseudo-terminal, the way a person would, and checks that it works:
   1. it opens a file and draws it;
   2. the built-in terminal starts a shell (the pseudo-terminal code) and runs a command;
   3. piped input (`printf … | ned`) is shown and keys still work;
   4. Ctrl+Q quits cleanly.
Usage: pty_smoke.py path/to/ned"""
import os, pty, re, select, signal, sys, time

NED = os.path.abspath(sys.argv[1])
FAILS = []
ESC = re.compile(rb"\x1b(\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(\x07|\x1b\\\\)|[()][0-9A-Za-z]|[=>78DEHM])")

def plain(b):
    """screen text without escape sequences or spaces (the screen is drawn in pieces with cursor moves)"""
    return re.sub(rb"\s+", b"", ESC.sub(b"", b))

def seen(text, out):
    return re.sub(r"\s+", "", text).encode() in plain(out)

def run(args, stdin_text=None, actions=(), timeout=25):
    """start ned in a pty; actions: (text to wait for, or seconds to wait, keys to send) pairs;
    returns (all output, exit status or None, actions never sent)"""
    rfd = wfd = None
    if stdin_text is not None:
        rfd, wfd = os.pipe()
    pid, fd = pty.fork()
    if pid == 0:
        if rfd is not None:
            os.dup2(rfd, 0)
            os.close(rfd)
            os.close(wfd)
        os.environ["TERM"] = "xterm-256color"
        os.environ["COLORTERM"] = "truecolor"
        os.environ.setdefault("XDG_CONFIG_HOME", "/tmp/ned-smoke-cfg")
        os.environ.setdefault("XDG_STATE_HOME", "/tmp/ned-smoke-state")
        os.execv(NED, [NED] + args)
    if rfd is not None:
        os.close(rfd)
        os.write(wfd, stdin_text.encode())
        os.close(wfd)
    import fcntl, struct, termios
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    out = b""
    end = time.time() + timeout
    steps = list(actions)
    status = None
    since = 0
    sent_at = time.time()
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                chunk = b""
            if not chunk:
                break
            out += chunk
        if steps:
            want = steps[0][0]
            ready = (time.time() - sent_at >= want) if isinstance(want, float) else seen(want, out[since:])
            if ready:
                time.sleep(0.4)
                os.write(fd, steps[0][1])
                out += b"\n<<sent>>\n"
                since = len(out)          # the next marker must appear after this key
                sent_at = time.time()
                steps.pop(0)
        done, st = os.waitpid(pid, os.WNOHANG)
        if done:
            status = st
            break
    if status is None:
        # the pty closes (EOF/EIO) when ned exits: give it a moment to be reaped
        for _ in range(50):
            done, st = os.waitpid(pid, os.WNOHANG)
            if done:
                status = st
                break
            time.sleep(0.1)
    if status is None:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        return out, None, steps
    return out, status, steps

def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name)
    if not ok:
        FAILS.append(name)
        if detail:
            print("     " + detail[-600:].replace("\n", " "))

here = os.path.dirname(os.path.abspath(__file__))
readme = os.path.join(here, "..", "..", "README.md")

# 1 + 4: open a file, quit
out, st, left = run([readme], actions=[("A fast, safe", b"\x11")])
check("opens and draws a file", seen("A fast, safe", out), out.decode("utf-8", "replace"))
check("Ctrl+Q quits", st is not None and os.WIFEXITED(st) and os.WEXITSTATUS(st) == 0 and not left)

# 2: the built-in terminal (pseudo-terminal) runs a command
out, st, left = run([readme], actions=[("A fast, safe", b"\x1b`"), (2.5, b"echo pty-$((40+2))\r"),
                                       ("pty-42", b"exit\r"), (1.5, b"\x11")], timeout=30)
check("built-in terminal runs a shell", seen("pty-42", out), out.decode("utf-8", "replace"))

# 3: piped input, then quit
out, st, left = run([], stdin_text="hello from a pipe\nsecond line\n", actions=[("hello from a pipe", b"\x11")])
check("piped input is shown", seen("hello from a pipe", out), out.decode("utf-8", "replace"))
check("keys work after piped input", st is not None and not left)

sys.exit(1 if FAILS else 0)
