# ── plugins: what they put in the editor (gutter signs, text after a line, highlights, status-bar items) and
#    what they declare that the editor's own parts read (languages, formatters). The plugin host is plugins/host ──

type
  PlugDecor = object
    plugin: string
    kind: int                     # 0 a sign in the gutter, 1 text after the line, 2 a highlight
    line, col, eline, ecol: int
    text, color: string
  PlugAiTool = object
    name, desc, plugin, key: string     # name: plugin__<plugin>__<tool> (what the model calls)
    schema: JsonNode
    readOnly: bool

var
  plugDecor: Table[string, seq[PlugDecor]]      # a file's path (or "#<buffer id>") → what plugins put on it
  plugStatusItems: seq[(string, string)]        # plugin, its status-bar text
  plugLangSpecs: seq[(string, string, JsonNode)] # plugin, language id, its spec ("languages" setting's fields)
  plugFmtCmd: Table[string, string]             # language id → a plugin's formatter command
  plugFmtCb: Table[string, (string, int)]       # language id → a plugin's NimScript formatter (plugin, callback)
  plugKeys: Table[string, string]               # key name ("ctrl+alt+u") → a plugin's command
  plugTextObjKeys: HashSet[string]              # vim: the text objects plugins have ("ie" …)
  plugSnippets: seq[(string, string, string, string)]   # language id ("*" any), trigger, description, body
  plugAiTools: seq[PlugAiTool]                  # tools the assistant may call
  plugProgress: seq[(string, string, int)]      # plugin, what it is doing, percent (-1 not known)

proc plugDecorKey(b: Buffer): string = (if b.path.len > 0: b.path else: "#" & $b.id)

proc plugColor(name: string): Rgb =
  ## error warn info hint accent add del (or "#rrggbb")
  case name
  of "error", "err": theme.err
  of "warn", "warning": theme.warn
  of "info": theme.info
  of "hint", "dim": theme.inlay
  of "add", "ok", "green": theme.gitAdd
  of "del", "red": theme.gitDel
  of "mod", "change": theme.gitMod
  else:
    if name.len == 7 and name[0] == '#':
      try: Rgb(parseHexInt(name[1 .. ^1]))
      except ValueError: theme.accent
    else: theme.accent

proc plugSignAt(b: Buffer, line: int): (string, Rgb) =
  if plugDecor.len == 0: return
  for d in plugDecor.getOrDefault(plugDecorKey(b)):
    if d.kind == 0 and d.line == line: return (d.text, plugColor(d.color))

proc plugTextAfter(b: Buffer, line: int): (string, Rgb) =
  if plugDecor.len == 0: return
  for d in plugDecor.getOrDefault(plugDecorKey(b)):
    if d.kind == 1 and d.line == line:
      if result[0].len > 0: result[0].add "  "
      result[0].add d.text
      result[1] = plugColor(d.color)

proc plugHighlights(b: Buffer, line: int): seq[(int, int, Rgb)] =
  ## the byte ranges of the line plugins highlight
  if plugDecor.len == 0: return
  for d in plugDecor.getOrDefault(plugDecorKey(b)):
    if d.kind != 2 or line < d.line or line > d.eline: continue
    let a = if line == d.line: d.col else: 0
    let e = if line == d.eline: d.ecol else: int.high
    if e > a: result.add (a, e, plugColor(d.color))
