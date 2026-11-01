"""code-pet: a new pet at start (a name, full, in the status bar); hungry when it has not eaten for long, asleep after
twenty minutes without typing and awake again; a save feeds it, commits make it grow (the first count only noted),
a level's note; naming it, a treat once an hour, what it is like; its kinds; kept in the data folder."""
import json, os, subprocess
from tplugins import check
from tbundled import run_jobs


def git(d, *a):
    subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *a], cwd=d, capture_output=True, check=True)


def run(factory, tag):
    h = factory()
    root = h.tmp
    git(root, "init", "-q")
    for i in range(2):
        open(os.path.join(root, "f.txt"), "a").write("%d\n" % i)
        git(root, "add", "f.txt")
        git(root, "commit", "-qm", "c%d" % i)
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return
    if not h.pump(lambda j: j.get("t") == "ready", 90):
        h.p.kill()
        check(tag + "it starts", False, h.p.stderr.read()[-1500:])
        return
    check(tag + "it starts (%s ms)" % h.ready_ms, True)
    T = 1_800_000_000
    h.clock = T
    ev = {"buf": h.cur, "path": h.path_, "lang": "plaintext"}
    h.call(h.reg("event", event="startup")["cb"], ev)
    run_jobs(h)
    data = os.path.join(h.tmp, "data", "code-pet", "pet.json")
    pet = json.load(open(data)) if os.path.exists(data) else {}
    name = pet.get("name", "?")
    check(tag + "at start: a pet of its own, full, in the status bar; the project's commits counted, none eaten",
          h.status == "=^.^= " + name + " · lv 1" and pet.get("food") == 100 and
          pet.get("commits", {}).get(root) == 2 and pet.get("xp") == 0, (h.status, pet))
    minute = [r for r in h.regs if r["kind"] == "timer" and r.get("ms") == 60000][0]["cb"]
    # 4 hours without a save: hungry; 21 minutes without typing: asleep
    h.clock = T + 4 * 3600
    h.call(h.reg("event", event="change")["cb"], ev)
    h.call(minute)
    hungry = h.status
    h.clock = T + 4 * 3600 + 21 * 60
    h.call(minute)
    asleep = h.status
    h.call(h.reg("event", event="change")["cb"], ev)
    check(tag + "hungry after hours without a save; asleep after twenty minutes without typing; typing wakes it",
          hungry == "=;.;= " + name + " · lv 1" and asleep == "=-.-= zZ " + name + " · lv 1" and
          h.messages[-1] == name + " woke up", (hungry, asleep, h.messages[-1:]))
    h.call(h.reg("event", event="save")["cb"], ev)
    pet = json.load(open(data))
    check(tag + "a save: fed a little (13 → 18), a point", pet["xp"] == 1 and pet["food"] == 18, pet)
    # a new commit: eaten, it grows (5 points: level 2)
    open(os.path.join(root, "f.txt"), "a").write("x\n")
    git(root, "commit", "-qam", "c2")
    for _ in range(10): h.call(minute)
    run_jobs(h)
    pet = json.load(open(data))
    check(tag + "a new commit: eaten (5 points, fed), a note, and a level's note",
          pet["xp"] == 6 and pet["eaten"] == 1 and pet["commits"][root] == 3 and
          any(m.endswith(name + " ate 1 commit — yum!") for m in h.messages[-3:]) and
          any(m.endswith(name + " grew to level 2!") for m in h.messages[-3:]) and h.status.endswith("· lv 2"),
          (pet, h.messages[-3:], h.status))
    # a name, a treat (once an hour), what it is like
    h.answers["ask"] = "Kiwi"
    h.call(h.reg("command", title="Pet: name it…")["cb"])
    named = h.messages[-1]
    h.call(h.reg("command", title="Pet: feed it")["cb"])
    fed = h.messages[-1]
    h.call(h.reg("command", title="Pet: feed it")["cb"])
    again = h.messages[-1]
    h.call(h.reg("command", title="Pet: how is it?")["cb"])
    how = h.messages[-1]
    check(tag + "name it, a treat, not two in an hour, how it is",
          named == "=^.^= Hello, Kiwi!" and fed == "=^.^= Kiwi loved it" and
          again.startswith("Kiwi is still full — the next treat in ") and
          how.startswith("=^.^= Kiwi — level 2 (7 points), happy, fed ") and "1 commit eaten, here since " in how,
          (named, fed, again, how))
    h.settings = {"kind": "bear"}
    h.call(minute)
    check(tag + "another kind: a bear", h.status.startswith("ʕ•ᴥ•ʔ Kiwi"), h.status)
