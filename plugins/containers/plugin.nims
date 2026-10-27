## containers — Docker or Podman from ned: containers and images in the Plugins dock, their logs, start, stop, a shell in one
##
##   the Plugins dock          CONTAINERS: the containers (● running, ○ stopped) with their image and state, then the
##                             images — tap one for what to do with it; ↻ reads them again
##   Containers: containers…   the containers to choose from, then: its logs (the last lines, in a tab), follow its
##                             logs (in the terminal), start, stop, restart, a shell in it (in the terminal), inspect
##                             (its JSON in a tab), remove (asked first)
##   Containers: images…       the images to choose from, then: run one (in the terminal, its options asked
##                             first), inspect, remove (asked first)
##   Containers: logs…         a container's last lines straight away
##   settings                  plugins.containers.cli — "auto" (docker, else podman) or the program to use
##                             (nerdctl …) · .logLines — how many of the last lines a log shows (200)
##
## It runs the program you have — docker or podman, whichever is on PATH — as you would in a terminal; what it
## says when it cannot (the daemon is not running, no right to its socket) is shown as it says it. Slow work (start,
## stop, logs) goes on in the background.
import nedplugin

requiresNed(">= 6.31")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")
permission("shell", "runs docker or podman to list, start, stop and inspect your containers and images")

settingDef("cli", "auto", "Containers: the program — auto (docker, else podman), or one of your own (nerdctl …)")
settingDef("logLines", 200, "Containers: how many of a container's last lines its log shows")

const
  View = "CONTAINERS"
  PsFormat = "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.State}}\t{{.Status}}\t{{.Ports}}"
  ImagesFormat = "{{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}\t{{.CreatedSince}}"
  ImagesMark = "\x1e images"

type
  Container* = object
    id*, name*, image*, state*, status*, ports*: string
  Image* = object
    repo*, tag*, id*, size*, created*: string

func running*(c: Container): bool = c.state.toLowerAscii == "running" or c.status.startsWith("Up")

func refName*(i: Image): string =
  ## how the image is named in a command: repo:tag, or its id when it has neither
  if i.repo.len > 0 and i.repo != "<none>": i.repo & (if i.tag.len > 0 and i.tag != "<none>": ":" & i.tag else: "")
  else: i.id

func parseContainers*(o: string): seq[Container] =
  for l in o.splitLines:
    let f = l.split('\t')
    if f.len >= 5:
      result.add Container(id: f[0].strip, name: f[1].strip, image: f[2].strip, state: f[3].strip,
                           status: f[4].strip, ports: (if f.len > 5: f[5].strip else: ""))

func parseImages*(o: string): seq[Image] =
  for l in o.splitLines:
    let f = l.split('\t')
    if f.len >= 4:
      result.add Image(repo: f[0].strip, tag: f[1].strip, id: f[2].strip, size: f[3].strip,
                       created: (if f.len > 4: f[4].strip else: ""))

func problemOf*(o: string): string =
  ## what the program said instead of a list (its first line that is not one), "" when it gave one
  for l in o.splitLines:
    let t = l.strip
    if t.len > 0 and '\t' notin t and t != ImagesMark.strip: return t

proc cli(): string =
  ## the program: the setting's, else docker, else podman ("" none)
  let s = setting("cli", "auto").strip
  if s.len > 0 and s != "auto": return s
  for p in ["docker", "podman"]:
    if findExe(p).len > 0: return p
  ""

proc noCli(): bool =
  if cli().len > 0: return false
  message("Containers: neither docker nor podman is installed (plugins.containers.cli names another program)")
  true

# ── what the dock shows: read in the background, kept until read again ──

var
  containers: seq[Container]
  images: seq[Image]
  problem = ""
  state = 0                      # 0 not read · 1 being read · 2 read

proc readAll() =
  let c = cli()
  if c.len == 0:
    problem = "neither docker nor podman is installed"
    state = 2
    refreshView(View)
    return
  if state == 1: return
  state = 1
  shellAsync(c & " ps -a --format " & quoteShell(PsFormat) & " 2>&1; echo " & quoteShell(ImagesMark) & "; " &
             c & " images --format " & quoteShell(ImagesFormat) & " 2>&1") do (o: string, code: int):
    let k = o.find(ImagesMark)
    let ps = if k >= 0: o[0 ..< k] else: o
    let im = if k >= 0: o[k + ImagesMark.len .. ^1] else: ""
    containers = parseContainers(ps)
    images = parseImages(im)
    problem = if containers.len == 0 and images.len == 0: problemOf(o) else: ""
    state = 2
    refreshView(View)

proc again() =
  state = 0
  readAll()

# ── what to do ──

proc inBackground(cmd, what: string, after: proc(o: string) = nil) =
  ## a command run in the background: said when it ends (its words when it fails), the dock read again
  status("⧗ " & what)
  shellAsync(cmd & " 2>&1") do (o: string, code: int):
    status("")
    if code == 0:
      if after != nil: after(o)
      else: toast("Containers: " & what & " — done")
    else:
      let ls = o.strip.splitLines
      warn("Containers: " & what & " failed — " & (if ls.len > 0 and ls[^1].len > 0: ls[^1] else: "exit code " & $code))
    again()

proc showLogs(c: Container) =
  let n = setting("logLines", 200)
  inBackground(cli() & " logs --tail " & $n & " " & quoteShell(c.id), "the logs of " & c.name) do (o: string):
    discard newTab("logs: " & c.name, (if o.strip.len == 0: "(nothing logged)" else: o), "plaintext")

proc inspect(id, name: string) =
  inBackground(cli() & " inspect " & quoteShell(id), "inspect " & name) do (o: string):
    discard newTab("inspect: " & name, o, "json")

proc containerActions(c: Container) =
  let x = cli()
  var items = @["Its logs", "Follow its logs (in the terminal)"]
  var dets = @["the last " & $setting("logLines", 200) & " lines", "logs -f"]
  if c.running:
    items.add @["Stop it", "Restart it", "A shell in it (in the terminal)"]
    dets.add @["stop", "restart", "exec -it … sh"]
  else:
    items.add "Start it"
    dets.add "start"
  items.add @["Inspect it", "Remove it"]
  dets.add @["its JSON in a tab", (if c.running: "rm -f — it is running" else: "rm")]
  let i = pick(c.name & " — " & c.image & " · " & c.status, items, dets)
  if i < 0: return
  let q = quoteShell(c.id)
  case items[i]
  of "Its logs": showLogs(c)
  of "Follow its logs (in the terminal)": runInTerminal(x & " logs -f --tail 50 " & q)
  of "Stop it": inBackground(x & " stop " & q, "stop " & c.name)
  of "Restart it": inBackground(x & " restart " & q, "restart " & c.name)
  of "Start it": inBackground(x & " start " & q, "start " & c.name)
  of "A shell in it (in the terminal)":
    runInTerminal(x & " exec -it " & q & " sh -c 'command -v bash >/dev/null && exec bash || exec sh'")
  of "Inspect it": inspect(c.id, c.name)
  of "Remove it":
    if confirm("Remove the container " & c.name & (if c.running: " (it is running: it is stopped first)" else: "") &
               "?"):
      inBackground(x & " rm " & (if c.running: "-f " else: "") & q, "remove " & c.name)
  else: discard

proc imageActions(im: Image) =
  let x = cli()
  let i = pick(im.refName & " — " & im.size & (if im.created.len > 0: " · " & im.created else: ""),
               ["Run it (in the terminal)", "Inspect it", "Remove it"], ["run …", "its JSON in a tab", "rmi"])
  case i
  of 0:
    # (Esc: not run; a command for it after --)
    let opts = ask("Run " & im.refName & " with (a command for it after --):", "-it --rm")
    if opts.strip.len > 0:
      let parts = (" " & opts.strip & " ").split(" -- ", maxsplit = 1)
      runInTerminal(x & " run " & parts[0].strip & " " & quoteShell(im.refName) &
                    (if parts.len > 1: " " & parts[1].strip else: ""))
  of 1: inspect(im.id, im.refName)
  of 2:
    if confirm("Remove the image " & im.refName & "?"):
      inBackground(x & " rmi " & quoteShell(im.refName), "remove " & im.refName)
  else: discard

proc listNow(): bool =
  ## the containers and images read now (a list is chosen from them at once); false, said, when they cannot be
  let x = cli()
  let (o, code) = shell(x & " ps -a --format " & quoteShell(PsFormat) & " 2>&1")
  containers = parseContainers(o)
  if code != 0:
    warn("Containers: " & x & " ps failed — " & problemOf(o))
    return false
  let (oi, _) = shell(x & " images --format " & quoteShell(ImagesFormat) & " 2>&1")
  images = parseImages(oi)
  state = 2
  true

proc chooseContainer(then: proc(c: Container)) =
  if noCli() or not listNow(): return
  if containers.len == 0:
    message("Containers: there are none (" & cli() & " ps -a lists none)")
    return
  var items, dets: seq[string]
  for c in containers:
    items.add (if c.running: "● " else: "○ ") & c.name
    dets.add c.image & " · " & c.status & (if c.ports.len > 0: " · " & c.ports else: "")
  let i = pick("Containers (" & cli() & ")", items, dets)
  if i >= 0: then(containers[i])

command "Containers: containers…":
  chooseContainer(containerActions)

command "Containers: logs…":
  chooseContainer(showLogs)

command "Containers: images…":
  if not noCli() and listNow():
    if images.len == 0: message("Containers: there are no images")
    else:
      var items, dets: seq[string]
      for im in images:
        items.add im.refName
        dets.add im.size & (if im.created.len > 0: " · " & im.created else: "") & " · " & im.id
      let i = pick("Images (" & cli() & ")", items, dets)
      if i >= 0: imageActions(images[i])

view(View) do () -> seq[ViewItem]:
  if state == 0: readAll()
  result.add ViewItem(text: "Read them again", icon: "↻", color: "accent", id: "refresh",
                      detail: (if state == 1: "reading…" else: cli()))
  if problem.len > 0:
    result.add ViewItem(text: problem, icon: "!", color: "error")
    return
  if state == 2:
    result.add ViewItem(text: "Containers", icon: "▸", detail: $containers.len)
    for k, c in containers:
      result.add ViewItem(text: c.name, detail: c.image & " · " & c.status, icon: (if c.running: "●" else: "○"),
                          color: (if c.running: "add" else: ""), id: "c" & $k, depth: 1)
    result.add ViewItem(text: "Images", icon: "▸", detail: $images.len)
    for k, im in images:
      result.add ViewItem(text: im.refName, detail: im.size, icon: "◆", id: "i" & $k, depth: 1)
do (id: string):
  if id == "refresh": again()
  elif id.len > 1:
    let k = try: parseInt(id[1 .. ^1]) except ValueError: -1
    if id[0] == 'c' and k in 0 ..< containers.len: containerActions(containers[k])
    elif id[0] == 'i' and k in 0 ..< images.len: imageActions(images[k])
