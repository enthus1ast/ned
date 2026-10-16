proc compIcon(kind: int): (string, Rgb) =
  case kind
  of 2, 3, 4: ("ƒ", theme.syn[tkFunc])
  of 5, 6, 10: ("v", theme.syn[tkProperty])
  of 7, 8, 22, 25: ("T", theme.syn[tkType])
  of 9: ("m", theme.syn[tkKeyword])
  of 13, 20, 21: ("c", theme.syn[tkConst])
  of 14: ("k", theme.syn[tkKeyword])
  of 15: ("s", theme.syn[tkString])
  of 0: ("w", theme.dim)
  else: ("•", theme.dim)

proc drawCompletion() =
  if cursorX < 0 or compShown.len == 0: return
  if not compValid():
    closeComp()
    return
  let n = min(8, compShown.len)
  var lw = 10
  var dw = 0
  for k in 0 ..< min(compShown.len, 60):
    let it = compItems[compShown[k]]
    lw = max(lw, strWidth(it.label))
    dw = max(dw, strWidth(it.detail))
  lw = min(lw, 40)
  dw = min(dw, 30)
  let pw = min(scrW - 2, lw + 4 + (if dw > 0: dw + 2 else: 0))
  let prefixW = strWidth(compPrefix())
  var px = max(0, min(cursorX - prefixW - 2, scrW - pw))
  var py = cursorY + 1
  if py + n > scrH - 1:
    py = cursorY - n
    if py < 1: py = 1
  if compSel < compScroll: compScroll = compSel
  if compSel >= compScroll + n: compScroll = compSel - n + 1
  compRect = (px, py, pw, n)
  for r in 0 ..< n:
    let idx = compScroll + r
    if idx >= compShown.len: break
    let it = compItems[compShown[idx]]
    let sel = idx == compSel
    let bg = if sel: theme.popupSel else: theme.popupBg
    let solid = sel and theme.popupSelFg != theme.fg      # solid selection bar: one contrasting text colour
    let fg = if sel: theme.popupSelFg else: theme.popupFg
    let y = py + r
    fillRect(px, y, pw, 1, fg, bg)
    var (ic, icc) = compIcon(if compFromLsp: it.kind else: 0)
    if solid: icc = fg
    var x = putStr(px + 1, y, ic, icc, bg)
    x += 1
    let hl = if it.filter == it.label: it.hl else: @[]
    discard putHl(x, y, truncTo(it.label, lw), hl, fg, (if solid: fg else: theme.accent), bg, px + 2 + lw + 1)
    if dw > 0 and it.detail.len > 0:
      let d = truncTo(it.detail, min(dw, pw - lw - 5))
      let dfg = if solid: fg elif theme.popupFg != theme.fg: theme.popupFg else: theme.dim
      discard putStr(px + pw - strWidth(d) - 1, y, d, dfg, bg, {}, px + pw)
  if compShown.len > n:
    discard putStr(px + pw - 6, py + n - 1, " " & $(compSel + 1) & "/" & $compShown.len, theme.dim,
                   theme.popupBg, {}, px + pw)
  # documentation of the selected item, beside the list (or above/below it on a narrow screen)
  compDocRect = (0, 0, 0, 0)
  if not cfgCompDocs or compSel >= compShown.len: return
  let ci = compShown[compSel]
  if ci != compDocIdx:
    compDocIdx = ci
    compDocScroll = 0
  let doc = compDocOf(ci)
  if doc.len == 0:
    # a language server may have it: ask once for the item shown
    let it = compItems[ci]
    if it.data != nil and not it.resolveAsked:
      compItems[ci].resolveAsked = true
      let s = lspReady(buf())
      if s != nil and s.caps != nil and s.caps{"completionProvider", "resolveProvider"}.getBool:
        discard s.lspRequest("completionItem/resolve", it.data, LspReq(kind: lrResolve, bufId: buf().id, extra: it.label))
    return
  let dbg = blend(theme.popupBg, theme.fg, 0.04)
  let rightRoom = scrW - (px + pw)
  let leftRoom = px
  var docX, docY, docW, docH: int
  if rightRoom >= 34 or leftRoom >= 34:
    docW = min(64, max(rightRoom, leftRoom) - 1)
    docX = if rightRoom >= 34: px + pw else: px - docW
    let lines = markdownLines(doc, docW - 2, dbg, compact = true)
    docH = clamp(lines.len, 1, max(n, min(16, scrH - 3)))
    docY = py
    if docY + docH > scrH - 1: docY = max(1, scrH - 1 - docH)
    compDocLines = lines.len
    compDocScroll = clamp(compDocScroll, 0, max(0, lines.len - docH))
    drawDocLines(lines, docX + 1, docY, docW - 1, docH, compDocScroll, dbg)
    for yy in docY ..< docY + docH: setCell(docX, yy, Cell(ch: ord(' '), fg: theme.border, bg: dbg))
  else:
    # narrow: a strip on the far side of the list from the cursor
    docW = min(scrW, 80)
    docX = max(0, min(px, scrW - docW))
    let lines = markdownLines(doc, docW - 2, dbg, compact = true)
    let below = py > cursorY
    let room = if below: scrH - 1 - (py + n) else: py - 1
    docH = min(lines.len, min(8, room))
    if docH <= 0: return
    docY = if below: py + n else: py - docH
    compDocLines = lines.len
    compDocScroll = clamp(compDocScroll, 0, max(0, lines.len - docH))
    drawDocLines(lines, docX + 1, docY, docW - 1, docH, compDocScroll, dbg)
    fillRect(docX, docY, 1, docH, theme.fg, dbg)
  compDocRect = (docX, docY, docW, docH)
  if compDocLines > docH:
    let more = if compDocScroll + docH < compDocLines: " Ctrl+↓ more " else: " Ctrl+↑ "
    discard putStr(docX + docW - strWidth(more), docY + docH - 1, more, theme.dim, dbg, {}, docX + docW)

proc drawHover() =
  if hoverMd.len == 0: return
  let maxW = min(scrW - 4, 84)
  var lines = markdownLines(hoverMd, maxW - 2, theme.popupBg, compact = true)
  while lines.len > 0 and lines[^1].spans.len == 0: lines.setLen(lines.len - 1)
  if lines.len == 0: return
  var w = 10
  for l in lines: w = max(w, spansWidth(l))
  w = min(w + 1, maxW) + 2
  let cap = if hoverIsAuto: 14 else: max(3, scrH - 4)
  let rows = min(lines.len, min(cap, max(1, scrH - 4)))
  hoverScroll = clamp(hoverScroll, 0, max(0, lines.len - rows))
  let h = rows + 2
  let cx = if cursorX >= 0: cursorX else: scrW div 2
  let cy = if cursorY >= 0: cursorY else: scrH div 2
  let x = max(0, min(cx - 2, scrW - w))
  var y = cy - h
  if y < 1: y = cy + 1
  if y + h > scrH - 1: y = max(1, scrH - 1 - h)
  drawBox(x, y, w, h)
  drawDocLines(lines, x + 1, y + 1, w - 2, rows, hoverScroll, theme.popupBg)
  if lines.len > rows:
    let more = if hoverScroll + rows < lines.len: " ↓ " & $(lines.len - rows - hoverScroll) & " more · Alt+H " else: " ↑ "
    discard putStr(x + w - 1 - strWidth(more), y + h - 1, more, theme.dim, theme.popupBg, {}, x + w - 1)

proc drawPicker() =
  var pw = min(scrW - 2, 96)
  var px = (scrW - pw) div 2
  var py = if scrH > 24: 2 else: 1
  var maxRows = max(1, min(14, scrH - py - 6))
  var n = min(maxRows, max(1, pickShown.len))
  var ph = n + 4
  if pickNear and edCaretX >= 0 and edCaretY >= 0 and scrW >= 60:
    # quick fixes: a box as wide as its items, under the line they fix (or over it), so the problem stays in view
    var w = strWidth(pickTitle) + 8
    for it in pickItems: w = max(w, max(strWidth(it.label) + strWidth(it.detail) + 10, 2 * strWidth(it.detail) + 8))
    pw = min(scrW - 2, max(44, w))
    px = max(0, min(edCaretX - 4, scrW - pw - 1))
    let rows = min(10, max(1, pickShown.len))
    let below = scrH - 2 - (edCaretY + 1)           # rows between the line and the status bar
    let above = edCaretY - 2                        # rows between the title/tab bars and the line
    if below >= rows + 4 or below >= above:
      n = max(1, min(rows, below - 4))
      py = edCaretY + 1
    else:
      n = max(1, min(rows, above - 4))
      py = edCaretY - (n + 4)
    if py < 1 or n < 1:
      py = if scrH > 24: 2 else: 1
      n = min(maxRows, max(1, pickShown.len))
    ph = n + 4
  var title = pickTitle
  if pickKind == pickFile and scanning: title = "Open file — indexing " & $fileCache.len & " files…"
  elif pickKind == pickFile and scanTruncated: title = pickTitle & " — first " & $cfgScanLimit & " files"
  drawBox(px, py, pw, ph, title)
  let lq = pickQueryNorm()
  pickBox = (px, py, pw, ph)
  pickListY = py + 3
  pickListN = n
  let iy = py + 1
  let x = putStr(px + 2, iy, "› ", theme.accent, theme.popupBg, {aBold})
  let cnt = $pickShown.len & "/" & $pickItems.len
  let fieldW = pw - (x - px) - strWidth(cnt) - 4
  let curVis = strWidth(pickQuery[0 ..< pickCur])
  let off = max(0, curVis - fieldW + 1)
  let bi = colAtVis(pickQuery, off)
  discard putStr(x, iy, pickQuery[bi .. ^1], theme.fg, theme.popupBg, {}, x + fieldW)
  cursorX = x + curVis - visColOf(pickQuery, bi)
  cursorY = iy
  discard putStr(px + pw - strWidth(cnt) - 2, iy, cnt, theme.dim, theme.popupBg)
  setCell(px, py + 2, Cell(ch: 0x251C, fg: theme.border, bg: theme.popupBg))
  setCell(px + pw - 1, py + 2, Cell(ch: 0x2524, fg: theme.border, bg: theme.popupBg))
  for xx in px + 1 ..< px + pw - 1: setCell(xx, py + 2, Cell(ch: 0x2500, fg: theme.border, bg: theme.popupBg))
  if pickSel < pickScroll: pickScroll = pickSel
  if pickSel >= pickScroll + n: pickScroll = pickSel - n + 1
  if pickShown.len == 0:
    discard putStr(px + 3, py + 3, (if pickKind == pickFile and pickQuery.len > 0: "Enter creates " & pickQuery
                                    else: "No matches"), theme.dim, theme.popupBg, {aItalic}, px + pw - 1)
    return
  for r in 0 ..< n:
    let idx = pickScroll + r
    if idx >= pickShown.len: break
    let it = pickItems[pickShown[idx]]
    var hl: seq[int]
    if lq.len > 0: discard fuzzyMatch(lq, it.label, hl)
    let sel = idx == pickSel
    let bg = if sel: theme.popupSel else: theme.popupBg
    let solid = sel and theme.popupSelFg != theme.fg      # solid selection bar: one contrasting text colour
    let fg = if solid: theme.popupSelFg else: theme.fg
    let dimC = if solid: theme.popupSelFg else: theme.dim
    let hlC = if solid: theme.popupSelFg else: theme.accent
    let y = py + 3 + r
    fillRect(px + 1, y, pw - 2, 1, fg, bg)
    var xx = px + 2
    if sel: discard putStr(px + 1, y, "▍", hlC, bg)
    if it.icon.len > 0:
      let ic = if solid: fg
        else:
          case it.icon
          of "ƒ": theme.syn[tkFunc]
          of "T": theme.syn[tkType]
          of "●": theme.accent
          of "#": theme.syn[tkHeading]
          else: theme.dim
      xx = putStr(xx, y, it.icon & " ", ic, bg)
    let detailW = if it.detail.len > 0: min(strWidth(it.detail), max(0, (pw - 6) div 2)) else: 0
    let labelMax = px + pw - 2 - (if detailW > 0: detailW + 2 else: 0)
    if pickKind == pickFile:
      let slash = it.label.rfind('/')
      var nameHl: seq[int]
      for h in hl:
        if h > slash: nameHl.add h - slash - 1
      xx = putHl(xx, y, it.label[slash + 1 .. ^1], nameHl, fg, hlC, bg, labelMax)
      if slash >= 0:
        discard putHl(xx + 1, y, it.label[0 ..< slash], hl, dimC, hlC, bg, labelMax)
    else:
      xx = putHl(xx, y, it.label, hl, fg, hlC, bg, labelMax)
    if detailW > 0:
      let d = truncTo(it.detail, detailW)
      discard putStr(px + pw - 2 - strWidth(d), y, d, dimC, bg, {}, px + pw - 1)

const HelpLines = [
  "WINDOW & LAYOUT",
  "F10                  Menu bar (File · Edit · View · Go · Run · Nim · AI · Help)",
  "Ctrl+E / Alt+X       Command palette — every feature, most used first",
  "Ctrl+B               Left dock: Files · Search · Git · Nim · Tests (Tab cycles views)",
  "Alt+C                AI assistant (right dock)    Alt+I  Outline",
  "Ctrl+\\ / Alt+`       Integrated terminal          Alt+O  bottom panel",
  "In the terminal      Ctrl+↑/↓ the commands you ran (● failed in red) · Alt+Enter its menu: output, run again",
  "                     ◫ in the panel header: two terminals side by side · Ctrl+PgUp/PgDn the other one",
  "F6                   Move focus: editor → docks → panel",
  "Alt+Z                Zen mode: no chrome, centred column, focus dimming (Esc Esc leaves; vim: :zen)",
  "Alt+\\                Split the editor / switch panes   Alt+|  close the split",
  "Ctrl+Alt+← / →       Make the split or the focused dock narrower / wider",
  "Ctrl+Alt+↑ / ↓       Make the bottom panel taller / shorter (panes one above the other: move the divider)",
  "Panel ⤢ button       Maximize the bottom panel (palette › Toggle maximized panel)",
  "Drag                 Split divider, dock edges, panel header, scrollbar, minimap, a tab (to reorder it)",
  "Right click          Context menus (editor, files, tabs, git, terminal) — on touch: press and hold",
  "Palette ›            Keyboard shortcuts… (change keys) · Show recent messages · Toggle touch bar",
  "Palette ›            Key bindings: default · vim · emacs · helix   ·   Accessibility mode (ASCII, letters, contrast)",
  "",
  "FILES & NAVIGATION",
  "Ctrl+P / Ctrl+O      Find file  (: line · @ symbol · # project symbol · > command)",
  "File › Open folder…  Tap through folders (◆ = a project) · Enter goes in · ⌫ up · Alt+Enter opens it",
  "Ctrl+N / Ctrl+W      New file / close tab        Ctrl+S / Ctrl+Q  save / quit",
  "Alt+← Alt+→ Alt+1..9 Switch tabs (also Ctrl+PgUp/PgDn)",
  "Ctrl+G               Go to line[:col]            Ctrl+T  symbol in file",
  "Alt+. / F12          Go to definition (also Ctrl+click)   Alt+,  jump back   Alt+<  go forward",
  "Alt+F12              Peek definition (a popup)   Alt+Shift+F12  peek references",
  "Go menu              Type definition · implementation · type hierarchy (with a language server; Nim: built in)",
  "Alt+Shift+T          Reopen the last closed tab",
  "Palette ›            Call hierarchy · Go to symbol (language server) · File: rename or move (imports follow)",
  "Alt+Q / Shift+F12    Find all references",
  "Alt+H                Hover info (also automatic — settings › editor.autoHover)",
  "Alt+'                Bookmark the line    Alt+; / Alt+:  next / previous bookmark",
  "Alt+V / Alt+Shift+V  Next / previous TODO · FIXME · BUG · HACK · NOTE comment (View › TODOs: list and count)",
  "F7 / Shift+F7        Next / previous git change — click its mark (▎) to stage, revert or show it",
  "Git menu            Branches (or click the branch in the title bar) · commit box · amend · sync · pull ·",
  "                     push (a login opens the terminal) · stage selected lines · history · blame · stash",
  "Git menu            Interactive rebase (edit the plan, Ctrl+S) · branch graph · compare with a branch ·",
  "                     cherry-pick · GitHub: pull requests, issues, CI (✓ in the status bar)",
  "Git menu            History of these lines (selection or proc) · find the commit that broke it (bisect:",
  "                     Good / Bad / Skip in the Git dock, or a command) · worktrees · submodules",
  "Palette › File:      compare with saved · compare with another file  (in a diff: F7 next, r reverts)",
  "Palette › Workspace: add a folder · remove one · save as (.ned-workspace; .code-workspace opens too)",
  "Palette › Remote:    open a folder over SSH (user@host:/path) — saves go to the server, Run and terminal run there;",
  "                     changes made there come back by themselves (remote.autoSync), any login shell (fish …)",
  "Git: merge editor    Ours | theirs above the result — ✓ Accept on either side, ◀ ▶ between conflicts",
  "Large files          Very big files or very long lines: no wrap, language server or minimap (palette turns it off)",
  "",
  "EDITING",
  "Ctrl+Z / Ctrl+Y      Undo / redo",
  "Ctrl+C / X / V       Copy / cut / paste (whole line when nothing selected)",
  "Ctrl+A / Ctrl+L      Select all / select line",
  "Ctrl+D / Alt+A       Next occurrence / all occurrences (multi-cursor)",
  "Alt+J / Alt+K        Add cursor below / above (also Alt+Shift+↑/↓)    Esc  single cursor",
  "Alt+click / Alt+drag Add a cursor / box (column) selection",
  "Alt+Shift+→ / ←      Expand / shrink selection",
  "Alt+↑ / Alt+↓        Move line(s)        Alt+D  duplicate line/selection",
  "Ctrl+K               Delete line(s)      Ctrl+/  toggle comment",
  "Alt+Shift+R / M      Record a keyboard macro (again: stop) / play it · Edit › Macros: N times, each line, save",
  "Alt+- / Alt+=        Fold / unfold block (or click ▾ ▸ in the gutter)",
  "View › Rulers        A line at column 80 (settings › editor.rulers: [80, 120]); text past the last is tinted",
  "■ before a colour    #RRGGBB, rgb(), hsl(), Nim's 0xRRGGBB — click it: copy as hex/rgb/hsl, lighter, darker",
  "Tab (HTML)           Expands Emmet: ul>li.item*3 · div#main>p{text} · ! — renaming <tag> renames its </tag>",
  "Tab (CSS)            In a rule: m10-20 · w100p · df · posr · jcsb · c#333 · bd1-s-#ccc · fz14! (!important)",
  "Underlined word      Misspelled (Markdown; settings › editor.spellCheck \"on\": comments, strings) — Alt+Enter",
  "Alt+Enter            Extract into a variable (selection) · inline a variable · \"a\" & x → fmt · evaluate a const",
  "Alt+Enter on a proc  Change its signature (every call follows) · inline it · move it to another module",
  "N references         After each Nim proc and type: a click lists them (yellow: an export nothing uses)",
  ".editorconfig        Followed (indentation, tab width, whitespace) — palette › File: EditorConfig for this file",
  "Tab after keyword    Snippet (proc, type, for, test, def, fn, main, html …)",
  "Ctrl+Space           Completion (Tab/Enter accepts) · list open: docs beside it on/off, Ctrl+↑/↓ scroll them",
  "",
  "SEARCH",
  "Ctrl+F               Find (Enter next · Shift+Enter prev · Alt+C case · Alt+W word · Alt+R regex)",
  "Ctrl+R               Replace  (Yes · No · All · Done) — with regex: $1 … groups",
  "Alt+S                Search the project in the Search dock (Aa · W · .* · files…)",
  "Alt+H (Search dock)  Replace in files: preview inline, Alt+Enter replaces all, undo restores",
  "Palette ›            Open results in a multibuffer — edit every hit at once, Ctrl+S writes them back",
  "",
  "RUN, TEST, DEBUG",
  "Alt+R / F5           Run current file    Alt+B  build / check",
  "▶ in the gutter      Run a test, a suite or `when isMainModule`",
  "Alt+N / Alt+P / F8   Next / previous problem",
  "Alt+F                Format document (lines selected: just those)   F2  rename (a preview first)",
  "F9                   Toggle a breakpoint (or click the gutter's left edge) — conditional: palette",
  "F5, other languages  Python (debugpy), C/C++/Rust (gdb, lldb-dap, codelldb), Go (delve), JS/TS (js-debug)",
  "Palette › Debug:     check the debugger for this file · choose it · install it (in the terminal)",
  "Shift+Enter          Send the selection / statement / # %% cell to the REPL (inim, python, node …) · ▶ on a cell",
  "F5                   Debug when the file has breakpoints (else run) · while debugging: continue",
  "F10 / F11            Step over / into while debugging    Shift+F11  step out    Shift+F5  stop",
  "Ctrl+F10             Run to the cursor (starts debugging if needed)",
  "Debug panel          Enter on ▸ shows fields/items · + add a watch · Alt+Enter on a test: debug it",
  "Palette ›            Run tests in file · Run all tests · Nim: test coverage · Nim: profile",
  "▶ by a test          Nim unittest and testament, pytest, go test, cargo test, PHPUnit, dotnet test, Gradle/Maven",
  "Palette ›            Test coverage: run (Nim, Python, Go, Rust, JS/TS) · load an lcov file · hide",
  "Palette ›            Problems: all of them with their code — one editable multibuffer",
  "Run › Configurations Ways to run the project (main, arguments, env, defines) — Alt+R runs the chosen one",
  "F4 / Shift+F4        The last task again / pick a task: Makefile, package.json, justfile, Taskfile, cargo, go, nimble",
  "Palette › Nim:       what can this proc raise? · benchmark a call · Nimble: release a new version",
  "",
  "NIM",
  "Alt+M                Expand the macro / template call under the cursor",
  "Alt+Y                Nimble tasks       Alt+E  Nim dock (project, tools, Atlas, Nimony)",
  "Palette › Nim:       ARC/ORC view · generated C · build mode · backend · nimony",
  "F12 on importc       its C declaration in the header (hover shows it) · wrappers are checked against the header",
  "Palette › Nim:       wrap a C header (c2nim) · compile_commands.json for clangd",
  "Alt+Enter            Quick fixes: imports, missing case branches, generate $ == hash init, doc comment,",
  "                     run the selection, debug this test, AI fix",
  "Alt+H on a selection Its type        Nim › Refactor: extract proc · sort imports · proc ⇄ func",
  "Alt+H on an error    A type mismatch as a table: what you gave, what the closest overload wants (✗ the misfit)",
  "▶ by runnableExamples  Runs that proc's examples (✓/✗ after) · Nim › Run all examples in the file",
  "Palette › Nim:       docs browser · switch compiler version · share to Playground · REPL · export (*)",
  "Palette › Nimble:    dependencies and updates · newer versions of the dependencies · add · search",
  "",
  "AI",
  "Alt+C                Chat. Enter sends, Alt+Enter new line, @ attaches a file, Esc stops",
  "Alt+Shift+C          Edit the selection (or the enclosing block) with an instruction",
  "/explain /fix /tests /doc /review /commit /regen /new /history   ·   @file @selection @diff",
  "@staged @problems @terminal @tree @path — context for the message (Tab completes)",
  "y / a / n            Allow · always allow · deny an agent action (edits, commands)",
  "Settings › ai.provider, ai.model, ai.apiKeyEnv — Anthropic, OpenAI, OpenRouter, Ollama …",
  "Palette › AI:        undo the assistant's changes · review staged changes (findings in Problems) · fast / smart",
  "Palette › AI:        review the assistant's changes (side by side, r undoes one) · MCP servers (ai.mcpServers)",
  "/server:prompt       An MCP server's prompt · @server:uri attaches one of its resources (@ lists them)",
  "Settings › ai.price  what a chat costs ($ per million tokens) · ai.warnTokens asks before a big request",
  "Agent edits          Checked (nim check, py_compile, node --check, cargo check …): errors go back to it (ai.checkEdits)",
  "Palette › AI:        write tests — Nim: compiled and run first; only the ones that pass are kept",
  "",
  "VIM MODE  (View › Vim mode, or settings › editor.vimMode)",
  "hjkl w b e 0 ^ $ gg G { } % f t ; ,   ·   d c y > < gu gU gc + motion or text object",
  "iw aw i( a( i\" a\" i{ …   ·   x X s S C D Y p P J r R ~ . u Ctrl+R   ·   v V   ·   / ? n N * #",
  ":w :q :wq :e file :s/a/b/g :%s/a/b/g :set wrap :term :zen   ·   zz zt zb za zc zo zM zR",
  "",
  "SAFETY",
  "Saves are atomic (temp file + fsync + rename); unsaved edits survive crashes and closed sessions",
  "File › Local history: every save keeps the previous version — diff it or restore it",
  "Undo history is kept when you close a file (or ned): Ctrl+Z works next time too (editor.persistentUndo)",
  "",
  "Alt+T themes (auto: follows the terminal) · palette › Theme: import / make my own copy · Alt+W soft wrap · Alt+L line numbers · Alt+U mouse",
  "Your own commands: settings › commands (shell commands in the palette, with $file $line $selection …)",
  "Settings: palette › Settings (UI) or › Open settings file  (~/.config/ned/config.json)",
  "Settings sync: export / import a file, or push / pull a git repository of yours (never API keys or tokens)",
]

proc helpRows(w: int): seq[(int, string, string)] =
  ## the key list as rows that fit the box: (0 heading · 1 key and text · 2 plain text, key, text) —
  ## long descriptions wrap under their own column
  for l in HelpLines:
    if l.len == 0:
      result.add (2, "", "")
      continue
    if l == l.toUpperAscii and l[0] in {'A'..'Z'}:
      result.add (0, "", l)
      continue
    var key = ""
    var text = l
    var keyed = false
    if l[0] != ' ':
      let k = l.find("  ")
      if k > 0 and strWidth(l[0 ..< k]) <= 21:
        key = l[0 ..< k]
        text = l[k .. ^1].strip(trailing = false)
        keyed = true
    else:
      text = l.strip
      keyed = true
    let tw = max(10, w - 4 - (if keyed: 21 else: 0))
    for i, part in wrapText(text, tw):
      result.add ((if keyed: 1 else: 2), (if i == 0: key else: ""), part)

proc drawHelp() =
  let w = min(scrW - 2, 110)
  let h = scrH - 2
  let x = (scrW - w) div 2
  let y = 1
  drawBox(x, y, w, h, "Key bindings — Esc to close · ↑↓ PgUp PgDn scroll")
  let rows = h - 2
  let hr = helpRows(w)
  helpScroll = clamp(helpScroll, 0, max(0, hr.len - rows))
  for r in 0 ..< rows:
    let i = helpScroll + r
    if i >= hr.len: break
    let (kind, key, text) = hr[i]
    case kind
    of 0: discard putStr(x + 2, y + 1 + r, text, theme.accent, theme.popupBg, {aBold}, x + w - 1)
    of 1:
      if key.len > 0:
        discard putStr(x + 2, y + 1 + r, key, (if key.startsWith("Palette"): theme.dim else: theme.syn[tkFunc]),
                       theme.popupBg, {}, x + w - 1)
      discard putStr(x + 2 + 21, y + 1 + r, text, theme.fg, theme.popupBg, {}, x + w - 1)
    else: discard putStr(x + 2, y + 1 + r, text, theme.dim, theme.popupBg, {}, x + w - 1)
  cursorX = -1

proc drawSignature() =
  if not (sigOpen and focus == fEditor and promptKind == pNone and cursorY >= 0 and buf().primary.head.line == sigLine):
    return
  # the signature with the parameter being typed highlighted, its documentation under it
  let more = if sigMore.len > 0: "  " & sigMore else: ""
  let maxW = min(scrW - 2, 84)
  let w = min(maxW, strWidth(sigLabel) + strWidth(more) + 2)
  var docs: seq[ChatLine]
  if cfgCompDocs and sigDoc.len > 0 and not compOpen:
    docs = markdownLines(sigDoc, max(w, min(maxW, 60)) - 2, theme.menuBg, compact = true)
    while docs.len > 0 and docs[^1].spans.len == 0: docs.setLen(docs.len - 1)
  let bw = if docs.len > 0: max(w, min(maxW, 60)) else: w
  var dh = min(docs.len, 6)
  let sx = max(0, min(cursorX - 4, scrW - bw))
  var sy = cursorY - 1 - dh
  var docY = sy + 1
  if sy < 1:
    # no room above: below the cursor line
    sy = cursorY + 1
    docY = sy + 1
    dh = min(dh, max(0, scrH - 2 - docY))
  fillRect(sx, sy, bw, 1, theme.fg, theme.menuBg)
  var x = sx + 1
  let lbl = truncTo(sigLabel, bw - 2 - strWidth(more))
  let (ha, he) = sigHl
  x = putStr(x, sy, lbl[0 ..< min(ha, lbl.len)], theme.fg, theme.menuBg, {}, sx + bw)
  if he > ha and ha < lbl.len:
    x = putStr(x, sy, lbl[ha ..< min(he, lbl.len)], theme.accent, theme.menuBg, {aBold, aUnder}, sx + bw)
  if he < lbl.len: x = putStr(x, sy, lbl[max(he, ha) .. ^1], theme.fg, theme.menuBg, {}, sx + bw)
  if more.len > 0: discard putStr(x, sy, more, theme.dim, theme.menuBg, {}, sx + bw)
  if dh > 0: drawDocLines(docs, sx, docY, bw, dh, 0, theme.menuBg)
  dropShadow(sx, sy, bw, 1 + dh)
