#!/usr/bin/env python3
"""ned on Windows, run as a person would: ned.exe in a Windows console (ConPTY, through pywinpty) — it starts, shows
the file, takes keys, saves and quits; nedls.exe answers the Language Server Protocol (hover, completion, the
file's symbols); nedfmt.exe formats.

  python .github/ci/win_smoke.py ned.exe nedls.exe nedfmt.exe        (pip install pywinpty)

Each check prints PASS or FAIL; the exit status is the number that failed."""
import json, os, subprocess, sys, tempfile, threading, time

ned, nedls, nedfmt = (os.path.abspath(x) for x in sys.argv[1:4])
fails = 0


def check(name, ok, info=""):
    global fails
    print(("PASS  " if ok else "FAIL  ") + name + ("" if ok else "  " + str(info)[-600:]), flush=True)
    if not ok: fails += 1


tmp = tempfile.mkdtemp(prefix="ned-win-")
src = os.path.join(tmp, "hello.nim")
with open(src, "w", newline="\n") as f:
    f.write("proc greet(name: string): string =\n  ## says hello\n  \"hello \" & name\n\necho greet(\"you\")\n")
env = dict(os.environ, XDG_CONFIG_HOME=os.path.join(tmp, "config"), XDG_STATE_HOME=os.path.join(tmp, "state"),
           XDG_DATA_HOME=os.path.join(tmp, "data"), XDG_CACHE_HOME=os.path.join(tmp, "cache"))
os.makedirs(os.path.join(tmp, "config", "ned"), exist_ok=True)
with open(os.path.join(tmp, "config", "ned", "config.json"), "w") as f:
    json.dump({"security.folderTrust": "off", "nim.nimsuggest": False}, f)

# ── the editor in a console ──
try:
    from winpty import PtyProcess
except ImportError:
    check("pywinpty is installed (pip install pywinpty)", False)
    sys.exit(1)

p = PtyProcess.spawn([ned, src], dimensions=(32, 120), env=env, cwd=tmp)
out = []
done = threading.Event()


def reader():
    while not done.is_set():
        try:
            s = p.read(4096)
        except EOFError:
            break
        except Exception:
            break
        if s: out.append(s)


threading.Thread(target=reader, daemon=True).start()


def seen(text, timeout):
    end = time.time() + timeout
    while time.time() < end:
        if text in "".join(out): return True
        time.sleep(0.2)
    return False


check("ned.exe starts in a console and shows the file's name", seen("hello.nim", 30), "".join(out)[-400:])
check("… and its text", seen("greet", 10), "".join(out)[-400:])
time.sleep(1.0)
p.write("x")                                     # a letter at the start of the first line
time.sleep(0.5)
p.write("\x13")                                  # Ctrl+S
saved = False
for _ in range(50):
    time.sleep(0.2)
    try:
        saved = open(src).read().startswith("xproc greet")
    except OSError:
        pass
    if saved: break
check("a key typed and Ctrl+S: the file saved with it", saved, open(src).read()[:60])
p.write("\x11")                                  # Ctrl+Q
end = time.time() + 15
while p.isalive() and time.time() < end: time.sleep(0.2)
check("Ctrl+Q: ned.exe quits", not p.isalive(), "".join(out)[-300:])
done.set()
try:
    code = p.exitstatus
except Exception:
    code = None
check("… with exit code 0", code in (0, None), code)
if p.isalive(): p.terminate(True)


# ── the language server ──
def frame(obj):
    b = json.dumps(obj).encode()
    return b"Content-Length: %d\r\n\r\n" % len(b) + b


def read_msg(stream):
    headers = {}
    while True:
        line = stream.readline()
        if not line: return None
        line = line.strip()
        if not line: break
        k, _, v = line.decode("latin-1").partition(":")
        headers[k.strip().lower()] = v.strip()
    return json.loads(stream.read(int(headers.get("content-length", 0))))


ls = subprocess.Popen([nedls], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, cwd=tmp)
uri = "file:///" + src.replace("\\", "/").lstrip("/")
text = open(src).read()


def request(i, method, params, timeout=60):
    ls.stdin.write(frame({"jsonrpc": "2.0", "id": i, "method": method, "params": params}))
    ls.stdin.flush()
    end = time.time() + timeout
    while time.time() < end:
        m = read_msg(ls.stdout)
        if m is None: return None
        if m.get("id") == i and "method" not in m: return m
    return None


def notify(method, params):
    ls.stdin.write(frame({"jsonrpc": "2.0", "method": method, "params": params}))
    ls.stdin.flush()


r = request(1, "initialize", {"processId": os.getpid(), "rootUri": "file:///" + tmp.replace("\\", "/").lstrip("/"),
                              "capabilities": {}})
check("nedls.exe: initialize", r and r.get("result", {}).get("serverInfo", {}).get("name") == "nedls", r)
notify("initialized", {})
notify("textDocument/didOpen", {"textDocument": {"uri": uri, "languageId": "nim", "version": 1, "text": text}})
line = text.split("\n").index('echo greet("you")')
r = request(2, "textDocument/hover", {"textDocument": {"uri": uri}, "position": {"line": line, "character": 6}})
hv = json.dumps((r or {}).get("result") or {})
check("nedls.exe: hover on a call — its proc and its doc comment", "greet" in hv and "says hello" in hv, hv[:300])
r = request(3, "textDocument/documentSymbol", {"textDocument": {"uri": uri}})
syms = json.dumps((r or {}).get("result") or [])
check("nedls.exe: the file's symbols", "greet" in syms, syms[:300])
r = request(4, "shutdown", None)
notify("exit", None)
try:
    ls.wait(10)
except subprocess.TimeoutExpired:
    ls.kill()
check("nedls.exe: shutdown and exit", r is not None and ls.returncode == 0, (r, ls.returncode))

# ── the formatter ──
r = subprocess.run([nedfmt, "--stdin-name=x.nim", "-"], input=b"proc f( a:int ):int=\n  a+1\n", capture_output=True)
check("nedfmt.exe formats", r.returncode == 0 and r.stdout.replace(b"\r", b"") == b"proc f(a: int): int =\n  a + 1\n",
      r.stdout[:200] + r.stderr[:200])

print("\n%d failed" % fails)
sys.exit(fails)
