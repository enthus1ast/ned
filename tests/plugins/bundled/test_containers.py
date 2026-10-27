"""containers: a pretend docker (and podman) — the dock's view read in the background (containers running and stopped,
images), a container's choices (its logs in a tab, start, stop, restart, a shell and the logs followed in the
terminal, inspect, remove asked first), an image's (run with options, remove), what the program says when its
daemon is down, podman when there is no docker, the cli setting, neither installed"""
import os, shutil, stat, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tplugins import check
from tbundled import run_jobs
from langcheck import start, done

DOCKER = """#!/bin/sh
echo "$(basename "$0") $*" >> "$CONTAINERS_LOG"
if [ -f "$CONTAINERS_LOG.down" ]; then
  echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" >&2
  exit 1
fi
case "$1" in
  ps) printf 'a1b2\\tweb\\tnginx:1.27\\trunning\\tUp 3 hours\\t0.0.0.0:8080->80/tcp\\n'
      printf 'c3d4\\tdb-old\\tpostgres:16\\texited\\tExited (0) 2 days ago\\t\\n' ;;
  images) printf 'nginx\\t1.27\\tsha111\\t188MB\\t2 weeks ago\\n'
          printf '<none>\\t<none>\\tsha222\\t5MB\\t3 months ago\\n' ;;
  logs) echo "line one of $4"; echo "line two" ;;
  inspect) echo '[{"Id": "'$2'"}]' ;;
  start|stop|restart|rm|rmi) echo "$2" ;;
esac
"""


def tools(d, names):
    os.makedirs(d, exist_ok=True)
    for n in names:
        p = os.path.join(d, n)
        open(p, "w").write(DOCKER)
        os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC)


def system_without(tmp, names):
    """a folder with the system's programs (/usr/bin, /bin) but these: a machine without docker"""
    d = os.path.join(tmp, "system")
    if not os.path.exists(d):
        os.makedirs(d)
        for src in ["/usr/bin", "/bin"]:
            for n in os.listdir(src):
                if not any(n.startswith(x) for x in names) and not os.path.exists(os.path.join(d, n)):
                    os.symlink(os.path.join(src, n), os.path.join(d, n))
    return d


def start_with(factory, dirs):
    """a host whose PATH is only these folders (and nim's)"""
    old = os.environ["PATH"]
    nim = os.path.dirname(shutil.which("nim") or "/usr/bin/nim")
    os.environ["PATH"] = os.pathsep.join(list(dirs) + [nim])
    try:
        h = factory()
    finally:
        os.environ["PATH"] = old
    ok = h.build_ok and h.pump(lambda j: j.get("t") == "ready", 90)
    return h, ok, (h.build_err if not h.build_ok else "")


def run(factory, tag):
    tmp = tempfile.mkdtemp(prefix="ned-containers-")
    try:
        go(factory, tag, tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def go(factory, tag, tmp):
    os.environ["CONTAINERS_LOG"] = log = os.path.join(tmp, "calls.log")
    dk = os.path.join(tmp, "docker-bin")
    tools(dk, ["docker", "podman"])
    old_path = os.environ["PATH"]

    def jobs(h, path_dir):
        nim = os.path.dirname(shutil.which("nim") or "/usr/bin/nim")
        os.environ["PATH"] = os.pathsep.join([path_dir, nim, "/usr/bin", "/bin"])
        try:
            run_jobs(h)
        finally:
            os.environ["PATH"] = old_path

    def calls():
        return open(log).read().splitlines() if os.path.exists(log) else []

    h, ok, err = start(factory, [dk], only_path=True)
    check(tag + "it starts", ok, err)
    if not ok:
        return
    titles = ["Containers: containers…", "Containers: logs…", "Containers: images…"]
    c = {t: h.reg("command", title=t) for t in titles}
    view, click = h.reg("view", title="CONTAINERS"), h.reg("viewClick", title="CONTAINERS")
    sd = {k: (h.reg("setting", key=k) or {}).get("default") for k in ("cli", "logLines")}
    check(tag + "its commands, the dock's view, its settings", all(c.values()) and view and click and
          sd == {"cli": "auto", "logLines": 200}, sd)
    if not (all(c.values()) and view):
        done(h)
        return
    # the view: read in the background the first time it shows
    r = h.call(view["cb"])
    rows = (r or {}).get("value") or []
    check(tag + "the view: reading in the background (one command for both lists)",
          rows and rows[0]["detail"] == "reading…" and len(h.jobs) == 1 and "docker ps -a" in h.jobs[0][0] and
          "docker images" in h.jobs[0][0], (rows, h.jobs))
    h.calls_seen = []
    jobs(h, dk)
    rows = (h.call(view["cb"]) or {}).get("value") or []
    got = [(x["icon"], x["text"], x["detail"], x["depth"]) for x in rows]
    check(tag + "… then the containers (● running, ○ stopped) and the images", "refreshView" in h.calls_seen and got[1:] == [
        ("▸", "Containers", "2", 0), ("●", "web", "nginx:1.27 · Up 3 hours", 1),
        ("○", "db-old", "postgres:16 · Exited (0) 2 days ago", 1), ("▸", "Images", "2", 0),
        ("◆", "nginx:1.27", "188MB", 1), ("◆", "sha222", "5MB", 1)], got)
    picks = []
    base = h.api

    def api(j):
        if j["fn"] == "pick" and picks:
            h.asked.append(("pick", j.get("args", {})))
            h.send({"t": "res", "id": j["id"], "value": picks.pop(0)})
        else:
            base(j)
    h.api = api
    # a running container: its choices; its logs in a tab
    open(log, "w").close()
    picks[:] = [0, 0]
    h.call(c["Containers: containers…"]["cb"])
    ch = [x for x in h.asked if x[0] == "pick"][-1][1]
    check(tag + "a running container's choices", ch.get("items") == [
        "Its logs", "Follow its logs (in the terminal)", "Stop it", "Restart it", "A shell in it (in the terminal)",
        "Inspect it", "Remove it"] and ch.get("title") == "web — nginx:1.27 · Up 3 hours", ch)
    jobs(h, dk)
    t = h.tabs[-1] if h.tabs else ("", "", "")
    check(tag + "its logs: the last 200 lines, in a tab", t[0] == "logs: web" and t[1] == "line one of a1b2\nline two"
          and "docker logs --tail 200 a1b2" in calls(), (t, calls()))
    # stop it (in the background), restart it, a shell, follow the logs, inspect
    open(log, "w").close()
    h.messages = []
    for idx in [2, 3]:
        picks[:] = [0, idx]
        h.call(c["Containers: containers…"]["cb"])
        jobs(h, dk)
    check(tag + "stop and restart: in the background, said, the lists read again",
          "docker stop a1b2" in calls() and "docker restart a1b2" in calls() and
          any("stop web — done" in m for m in h.messages) and calls().count("docker images --format " +
                                                                              "{{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}\t{{.CreatedSince}}") >= 2,
          (calls(), h.messages))
    h.terminal = []
    for idx in [4, 1]:
        picks[:] = [0, idx]
        h.call(c["Containers: containers…"]["cb"])
    check(tag + "a shell in it, its logs followed: in the terminal", [x["cmd"] for x in h.terminal] == [
        "docker exec -it a1b2 sh -c 'command -v bash >/dev/null && exec bash || exec sh'",
        "docker logs -f --tail 50 a1b2"], h.terminal)
    picks[:] = [0, 5]
    h.call(c["Containers: containers…"]["cb"])
    jobs(h, dk)
    check(tag + "inspect: its JSON in a tab", h.tabs[-1] == ("inspect: web", '[{"Id": "a1b2"}]', "json"), h.tabs[-1:])
    # a stopped one: start; remove (asked)
    open(log, "w").close()
    picks[:] = [1, 0]
    h.call(c["Containers: containers…"]["cb"])
    ch = [x for x in h.asked if x[0] == "pick"][-1][1]
    picks[:] = [1, 2]
    h.call(c["Containers: containers…"]["cb"])
    h.answers["confirm"] = True
    picks[:] = [1, 4]
    h.call(c["Containers: containers…"]["cb"])
    jobs(h, dk)
    check(tag + "a stopped one: start it; remove it (asked first)", ch.get("items") == [
        "Its logs", "Follow its logs (in the terminal)", "Start it", "Inspect it", "Remove it"] and
          "docker start c3d4" in calls() and "docker rm c3d4" in calls() and
          any(a[0] == "confirm" and "Remove the container db-old?" in a[1]["text"] for a in h.asked), calls())
    # a click in the dock: the same choices
    picks[:] = [-1]
    h.call(click["cb"], {"id": "c1"})
    check(tag + "a container tapped in the dock: its choices", [x for x in h.asked if x[0] == "pick"][-1][1].get(
        "title", "").startswith("db-old"), h.asked[-1:])
    # images: run one with options (in the terminal), remove one
    h.terminal = []
    picks[:] = [0, 0]
    h.answers["ask"] = "-d -p 8080:80 -- nginx -g 'daemon off;'"
    h.call(c["Containers: images…"]["cb"])
    check(tag + "an image run with the options asked (a command after --), in the terminal",
          [x["cmd"] for x in h.terminal] == ["docker run -d -p 8080:80 nginx:1.27 nginx -g 'daemon off;'"],
          h.terminal)
    picks[:] = [1, 2]
    h.call(c["Containers: images…"]["cb"])
    jobs(h, dk)
    check(tag + "an image without a name removed by its id", "docker rmi sha222" in calls(), calls())
    # the logs straight away
    picks[:] = [0]
    h.call(c["Containers: logs…"]["cb"])
    jobs(h, dk)
    check(tag + "Containers: logs… — a container's logs straight away", h.tabs[-1][0] == "logs: web", h.tabs[-1:])
    # the daemon is not running: its words
    open(log + ".down", "w").close()
    try:
        h.call(c["Containers: containers…"]["cb"])
        check(tag + "the daemon down: what docker says", "Cannot connect to the Docker daemon" in h.messages[-1],
              h.messages[-1:])
        h.call(click["cb"], {"id": "refresh"})
        jobs(h, dk)
        rows = (h.call(view["cb"]) or {}).get("value") or []
        check(tag + "… and in the dock, in the error colour", any(
            x["color"] == "error" and "Cannot connect" in x["text"] for x in rows), rows)
    finally:
        os.remove(log + ".down")
    done(h)
    # podman when there is no docker; the setting; neither
    pm = os.path.join(tmp, "podman-bin")
    tools(pm, ["podman", "nerdctl"])
    system = system_without(tmp, ["docker", "podman", "nerdctl"])
    h, ok, err = start_with(factory, [pm, system])
    if ok:
        h.call(h.reg("view", title="CONTAINERS")["cb"])
        check(tag + "no docker: podman", h.jobs and h.jobs[0][0].startswith("podman ps -a"), h.jobs)
        h.jobs = []
        h.settings["cli"] = "nerdctl"
        h.call(h.reg("viewClick", title="CONTAINERS")["cb"], {"id": "refresh"})
        check(tag + "the cli setting: the program named", h.jobs and h.jobs[0][0].startswith("nerdctl ps -a"), h.jobs)
    done(h)
    bare = os.path.join(tmp, "bare")
    os.makedirs(bare)
    h, ok, err = start_with(factory, [bare, system])
    if ok:
        h.call(h.reg("command", title="Containers: containers…")["cb"])
        check(tag + "neither installed: said", "neither docker nor podman is installed" in h.messages[-1],
              h.messages[-1:])
    done(h)
