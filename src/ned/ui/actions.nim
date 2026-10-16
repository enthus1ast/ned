# ════════════════════════════════════════════════════════════════════════════
#  Nim tooling, nimble/atlas/nimony, git, outline
# ════════════════════════════════════════════════════════════════════════════

var pickActions: seq[Action]

proc act(label, detail: string, a: Action): (string, string, Action) = (label, detail, a)

var
  pickFolderDir = ""             # the folder browser's folder (empty: any other picker)
  pickFolderPaths: seq[string]   # the folder behind each of its lines

proc browseFolder(dir: string)
proc openFolder(d: string)

proc openActions(title: string, items: seq[(string, string, proc() {.closure.})], search: seq[string] = @[]) =
  ## a picker of arbitrary actions (label, detail, action); `search`: extra text per item the query may match
  pickActions.setLen(0)
  var its: seq[PickItem]
  for i, (l, d, a) in items:
    its.add PickItem(label: l, detail: d, idx: i, line: -1,
                     search: (if i < search.len: search[i].toLowerAscii else: ""))
    pickActions.add a
  openPicker(pickAction, title, its)
  pickNear = title == "Quick fixes"
