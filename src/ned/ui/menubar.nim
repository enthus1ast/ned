# ── menus of the menu bar ──

const MenuNames = ["File", "Edit", "View", "Go", "Run", "Git", "Nim", "AI", "Plugins", "Help"]

const CmdRenamed = {"View: focus other pane": "View: focus next pane",       # (6.31: tiled panes)
                    "View: close split": "View: close this pane"}

proc cmdByName(name: string): int =
  ## the index in `commands` of the command with that name (-1: none); a command that was renamed is found under its old
  ## name too
  for i, c in commands:
    if c.name == name: return i
  for (o, n) in CmdRenamed:
    if o == name: return cmdByName(n)
  -1

proc runCmd(name: string) =
  ## runs the command with that name and counts the use (the palette ranks commands by use); a warning for an unknown
  ## name
  let i = cmdByName(name)
  if i >= 0:
    cmdUses[commands[i].name] = cmdUses.getOrDefault(commands[i].name) + 1
    commands[i].action()
  else: warn("Unknown command: " & name)

proc mc(name: string, label = "", check = -1): MenuItem =
  ## menu item backed by a command-palette command (same action, same shortcut text)
  let i = cmdByName(name)
  let lbl = if label.len > 0: label else: name
  if i < 0: return mi(lbl, "", nil, check, true)
  let n = name
  # (a command's keys — or, for some, a line on what it does: too long beside a menu item, so left out there)
  let k = commands[i].keys
  mi(lbl, (if strWidth(k) <= 24: k else: ""), proc() = runCmd(n), check)

proc mc(name: string, label = "", check = -1, disabled: bool): MenuItem =
  ## the same menu item, but drawn disabled when `disabled` is true
  result = mc(name, label, check)
  if disabled: result.disabled = true

# the tick state of a menu item: 1 ticked, 0 not (-1 is no tick at all)
func chk(b: bool): int = (if b: 1 else: 0)

# the action that opens file `p`
proc openAct(p: string): Action = (proc() = discard openFile(p))

proc recentMenu(): seq[MenuItem] =
  ## the recent files that still exist, at most 12, as menu items that open them
  for r in recentFiles:
    if result.len >= 12: break
    if fileExists(r):
      result.add mi(relPath(r), "", openAct(r))
  if result.len == 0: result.add mi("(no recent files)", disabled = true)

proc menuItems(i: int): seq[MenuItem] =
  ## the items of menu-bar menu number `i` (File, Edit, View, Go, Run, Git, Nim, AI, Plugins, Help), each backed by a
  ## command so it shares the command's keys and action
  case MenuNames[clamp(i, 0, MenuNames.high)]
  of "File":
    # (short: what is used every day at the top level, the rest one level down)
    @[mc("New file"), mc("Nim: new project…", "New Nim project…"), mc("Open file…"), mc("Open folder…"),
      msub("Open recent", recentMenu() & @[msep(), mc("File: open recent project…", "Recent projects…")]),
      msub("Open more", @[mc("Remote: open a folder over SSH…", "A folder over SSH…"),
        mc("File: clone from a link…", "Clone from a link (git)…"), msep(),
        mc("Workspace: open a workspace file…", "A workspace file…"), mc("Workspace: add a folder…", "Add a folder to the workspace…"),
        mc("Workspace: remove a folder…", "Remove a folder from the workspace…"),
        mc("Workspace: save as…", "Save the workspace as…")]), msep(),
      mc("Save"), mc("Save as…"), mc("Save all"),
      msub("This file", @[mc("File: rename or move this file…", "Rename or move…"),
        mc("File: compare with saved", "Compare with saved"), mc("File: compare with another file…", "Compare with another file…"),
        mc("File: local history…", "Local history…"), mc("File: recover unsaved edits…", "Recover unsaved edits…")]), msep(),
      msub("Preferences", @[mc("Settings", "Settings…"), mc("Open settings file", "Settings file (JSON)"),
        mc("Select theme…", "Color theme…"), mc("Theme: edit colours (contrast checked)…", "Edit the theme's colours…"),
        mc("Theme: light by day, dark at night", "Light by day, dark at night"), msep(),
        mc("Keyboard shortcuts…", "Keyboard shortcuts (change keys)…"), mc("Key bindings", "Key bindings (list)"),
        mc("Key bindings: default · vim · emacs · helix…", "Keymap: default · vim · emacs · helix…"), msep(),
        msub("Settings sync", @[mc("Settings sync: export to a file…", "Export to a file…"),
          mc("Settings sync: import from a file…", "Import from a file…"), msep(),
          mc("Settings sync: sync now (both ways)", "Sync now (both ways)"),
          mc("Settings sync: push (save to your settings repository)", "Push to your repository"),
          mc("Settings sync: pull (load from your settings repository)", "Pull from your repository"),
          mc("Settings sync: set the repository…", "Set the repository…"),
          mc("Settings sync: install the other device's plugins", "Install the other device's plugins")]), msep(),
        mc("Settings: reset to defaults", "Reset the settings to their defaults…"),
        mc("Reset everything: remove all settings and state…", "Reset everything (start fresh)…")]), msep(),
      mc("Close tab"), mc("Reopen closed tab"), mc("Quit")]
  of "Edit":
    @[mc("Undo"), mc("Redo"), mc("Undo history…"), msep(), mc("Cut"), mc("Copy"), mc("Paste"), msep(), mc("Find"), mc("Replace"),
      mc("Search in project…", "Find in files…"), mc("Search: replace in files…", "Replace in files…"),
      mc("Open results in a multibuffer (edit many files at once)", "Edit search results together (multibuffer)"),
      msub("Multibuffer", @[mc("Open results in a multibuffer (edit many files at once)", "From the search results"),
        mc("Problems: all of them with their code (multibuffer)", "From the problems"),
        mc("Multibuffer: every TODO of the project", "From the TODOs"),
        mc("Multibuffer: the open files, whole", "From the open files"), msep(),
        mc("Multibuffer: add the selection", "Add the selection"), mc("Multibuffer: show the one in use", "Show it"),
        msep(), mc("Multibuffer: next piece", "Next piece"), mc("Multibuffer: previous piece", "Previous piece"),
        mc("Multibuffer: more lines around this piece", "More lines around the piece"),
        mc("Multibuffer: remove this piece", "Remove the piece"), mc("Multibuffer: open the file here", "Open the file here"),
        mc("Multibuffer: refresh (each piece as its file has it now)", "Refresh")]),
      msep(), mc("Quick fix / code actions…", "Quick fix…"), mc("Toggle comment"),
      mc("TODO: insert a tag comment…", "Insert TODO comment…"), mc("Format document"), mc("Format selection (ned's own for Nim and C, or the language server)", "Format selection"),
      mc("Duplicate line/selection"), mc("Move line up"), mc("Move line down"),
      mc("Indent lines", "Indent"), mc("Unindent lines (outdent, dedent)", "Unindent"), msep(),
      msub("Macros", @[mc("Macro: start or stop recording", (if macroRecording: "Stop recording" else: "Record a macro")),
        mc("Macro: play the last one", "Play the last one"), mc("Macro: play the last one N times…", "Play it N times…"),
        mc("Macro: play on each selected line", "Play on each selected line"),
        mc("Macro: play to the end of the file", "Play to the end of the file"), msep(),
        mc("Macro: save the last one…", "Save the last one…"), mc("Macro: saved macros…", "Saved macros…")]),
      msub("Surround", @[mc("Surround with…"), mc("Change the surrounding pair…", "Change the pair around…"),
        mc("Delete the surrounding pair", "Delete the pair around")]),
      msub("Selection", @[mc("Select all"), mc("Select line"), mc("Expand selection"), mc("Shrink selection"),
        mc("Select next occurrence"), mc("Select all occurrences"), mc("Add cursor above"), mc("Add cursor below")]),
      msub("Transform", @[mc("Sort lines"), mc("Join lines"), mc("Upper case"), mc("Lower case"),
        mc("Trim trailing whitespace"), mc("Indent with 2 spaces"), mc("Indent with 4 spaces"), mc("Indent with tabs"),
        mc("Toggle line endings (LF/CRLF)")]),
      mc("Insert snippet…")]
  of "View":
    @[mc("Command palette"), msep(),
      mc("Files", "Explorer", chk(treeOpen and sideView == svFiles)), mc("Search view", "Search", chk(treeOpen and sideView == svSearch)),
      mc("Git panel", "Source control", chk(treeOpen and sideView == svGit)),
      mc("Nim panel (project, tools, toolchain)", "Nim", chk(treeOpen and sideView == svProject)),
      mc("Test explorer", "Tests", chk(treeOpen and sideView == svTests)), msep(),
      mc("AI assistant", "Assistant", chk(rightOpen and rightView == svAssistant)),
      mc("Outline panel", "Outline", chk(rightOpen and rightView == svOutline)),
      mc("TODOs panel", "TODOs", chk(rightOpen and rightView == svTodos)),
      mc("Plugins panel", "Plugins", chk(rightOpen and rightView == svPlugins)),
      mc("Plugins: run a plugin's command…", "Plugin commands…"),
      mc("Timeline", "Timeline", chk(rightOpen and rightView == svTimeline)), msep(),
      mc("Show problems", "Problems"), mc("Problems: all of them with their code (multibuffer)", "Problems with their code"),
      mc("Toggle output panel", "Output"), mc("Toggle terminal", "Terminal"),
      mc("Debug: show the debug panel", "Debug"), mc("Show recent messages", "Recent messages"),
      mc("Markdown: open preview to the side", "Markdown preview"), msep(),
      msub("Appearance", @[mc("Toggle title bar", "Title bar", chk(cfgTitleBar)), mc("Toggle tab bar", "Tab bar", chk(cfgTabBar)),
        mc("Toggle breadcrumbs", "Breadcrumbs", chk(cfgBreadcrumbs)), mc("Toggle minimap", "Minimap", chk(cfgMinimap != "off")),
        mc("Toggle status bar", "Status bar", chk(cfgStatusBar)), mc("Toggle shadows", "Shadows", chk(cfgShadows)),
        mc("Toggle touch bar", "Touch bar", chk(lay.touchY >= 0)),
        mc("Cycle icon set", "Icons: " & cfgIcons)]),
      msub("Editor", @[mc("Toggle soft wrap", "Soft wrap", chk(cfgWrap)), mc("Cycle line numbers", "Line numbers: " & ["off", "absolute", "relative"][cfgLineNums]),
        mc("Toggle indent guides", "Indent guides", chk(cfgGuides)), mc("Toggle whitespace", "Whitespace", chk(cfgShowWs)),
        mc("View: toggle rulers", "Rulers" & (if rulersSet(): " (" & rulerList() & ")" else: ""),
           chk(rulersSet() and not rulersHidden)),
        mc("View: ligatures (off › font › symbols)", "Ligatures: " & cfgLigatures),
        mc("Toggle sticky scroll", "Sticky scroll", chk(cfgSticky)), mc("Toggle rainbow brackets", "Rainbow brackets", chk(cfgRainbow)),
        mc("Toggle inlay hints", "Inlay hints", chk(cfgInlayHints)),
        mc("Toggle exception hints", "Exception hints", chk(cfgRaisesHints)), mc("Toggle auto hover", "Auto hover", chk(cfgAutoHover)),
        mc("Toggle auto-completion", "Auto completion", chk(cfgAutoComplete)), mc("Toggle code lens", "Run buttons (code lens)", chk(cfgCodeLens))]),
      msub("Folding", @[mc("Fold"), mc("Unfold"), mc("Fold all"), mc("Unfold all"), mc("Fold level 2")]),
      msub("Panes", @[mc("View: split editor right", "Split right"), mc("View: split editor down", "Split down"),
        mc("View: close this pane", "Close this pane"), mc("View: close the other panes", "Close the other panes"),
        msep(), mc("View: focus next pane", "Next pane"), mc("View: focus the pane to the left", "Pane to the left"),
        mc("View: focus the pane to the right", "Pane to the right"), mc("View: focus the pane above", "Pane above"),
        mc("View: focus the pane below", "Pane below"), msep(),
        mc("View: swap with the pane to the right", "Swap with the pane to the right"),
        mc("View: swap with the pane below", "Swap with the pane below"),
        mc("View: show file in other pane", "Show this file in the other pane"),
        mc("View: this pane alone (zoom)", "This pane alone", chk(paneZoom)),
        mc("View: equal pane sizes", "Equal sizes"), msep(),
        mc("View: panes: two columns", "Two columns"), mc("View: panes: three columns", "Three columns"),
        mc("View: panes: grid of four", "Grid of four"), mc("View: panes: one large and three", "One large and three"),
        msep(), mc("View: terminal in a pane", "Terminal in a pane"), mc("View: assistant in a pane", "Assistant in a pane"),
        mc("View: panel in a pane", "Panel in a pane"),
        msep(), mc("View: save this layout as…", "Save this layout as…"), mc("View: layouts…", "Layouts…")]),
      msep(), mc("Toggle zen mode", "Zen mode", chk(zenMode)),
      mc("Toggle vim mode", "Vim mode", chk(cfgVim)), mc("Toggle mouse", "Mouse", chk(cfgMouse)),
      mc("Accessibility mode: on/off (ASCII, letters beside colours, a high-contrast theme)", "Accessibility mode",
         chk(cfgAccessible)),
      msub("Spell check", @[mc("Spell check: where (off · Markdown · also code comments and strings)…", "Where…"),
        mc("Spell check: next misspelled word", "Next misspelled word"),
        mc("Spell check: download a dictionary…", "Download a dictionary…")]),
      mc("Toggle maximized panel", "Maximize panel", chk(panelMax))]
  of "Go":
    @[mc("Open file…", "Go to file…"), mc("Go to symbol…", "Go to symbol in file…"),
      mc("Go to symbol in project…"), mc("Go to symbol in workspace (language server)…", "Go to symbol (language server)…"),
      mc("Go to line…"), mc("Jump to a word on screen (labels)", "Jump to a word on screen"), msep(),
      mc("Go to definition"), mc("Peek definition"), mc("Find references"),
      mc("Peek references"), mc("Go to type definition"), mc("Go to implementation"),
      mc("Call hierarchy (callers and calls)", "Call hierarchy"), mc("Type hierarchy (supertypes and subtypes)", "Type hierarchy"),
      mc("Show hover info"), mc("C: switch between header and source", "Header ⇄ source (C)"), mc("Jump back"),
      mc("Go forward"), msep(), mc("Next problem"), mc("Previous problem"),
      mc("TODO: next in this file", "Next TODO comment"), mc("TODO: previous in this file", "Previous TODO comment"),
      mc("Go to matching bracket"), msep(),
      msub("Bookmarks", @[mc("Bookmarks: toggle", "Toggle"), mc("Bookmarks: next", "Next"),
        mc("Bookmarks: previous", "Previous"), mc("Bookmarks: list…", "List…"), mc("Bookmarks: clear all", "Clear all")]),
      msub("Changes (git)", @[mc("Git: next change", "Next change"), mc("Git: previous change", "Previous change"),
        mc("Git: show this change", "Show this change"), mc("Git: stage this change", "Stage this change"),
        mc("Git: revert this change", "Revert this change"), mc("Git: unstage this file", "Unstage this file"), msep(),
        mc("Git: compare with last commit (side by side)", "Compare with last commit"),
        mc("Git: history of these lines", "History of these lines"),
        mc("Git: toggle inline blame", "Inline blame", chk(cfgBlame))]),
      msub("Merge conflicts", @[mc("Git: next merge conflict", "Next conflict"),
        mc("Git: accept ours (conflict at cursor)", "Accept ours"), mc("Git: accept theirs (conflict at cursor)", "Accept theirs"),
        mc("Git: accept both (conflict at cursor)", "Accept both")]),
      msep(), mc("Switch buffer…")]
  of "Run":
    @[mc("Run current file"), mc("Build current file"), mc("Run: configurations…", "Configurations…" &
      (if activeRunConfig.len > 0: " (" & activeRunConfig & ")" else: "")),
      mc("Run: current file with arguments…", "Run with arguments…"), mc("Run command…"), mc("Stop running process"), msep(),
      mc("Tasks: run a task…", "Run task…"), mc("Tasks: run the last task again", "Run last task again"), msep(),
      mc("Run in terminal (interactive)", "Run in terminal"),
      mc("Run with memory checks", "Run with memory checks (overflows, leaks)"), msep(),
      msub("Debug", @[mc("Debug: start / continue", "Start / continue"), mc("Debug: toggle breakpoint", "Toggle breakpoint"),
        mc("Debug: conditional breakpoint on this line…", "Conditional breakpoint…"),
        mc("Debug: logpoint on this line…", "Logpoint…"), mc("Debug: stop when this changes…", "Stop when it changes…"),
        mc("Debug: run to cursor", "Run to cursor"),
        msep(), mc("Debug: step over", "Step over"), mc("Debug: step into", "Step into"), mc("Debug: step out", "Step out"),
        mc("Debug: stop", "Stop"), msep(), mc("Debug: add a watch expression…", "Add watch…"),
        mc("Debug: remove all watches", "Remove all watches"), mc("Debug: remove all breakpoints", "Remove all breakpoints"),
        mc("Debug: debug the test at the cursor", "Debug the test at the cursor"), mc("Debug: show the debug panel", "Debug panel"),
        msep(), mc("Nim: debug with gdb", "gdb in the terminal")]),
      mc("Nim: test coverage (run, then colour the lines that ran)", "Test coverage"), mc("Nim: hide coverage", "Hide coverage"),
      mc("Nim: profile", "Profile"), mc("Nim: flame graph of the profile", "Flame graph of the profile"),
      mc("Nim: compare with the previous profile", "Compare with the previous profile"),
      mc("Compiler Explorer", "Compiler Explorer (assembly, live)"),
      msub("Decompile", @[mc("Nim: decompile this proc (side by side)", "This proc (side by side)"),
        mc("Decompile a program…", "A program…"), mc("Hex: decompile a function…", "A function of the open binary…")]),
      msep(),
      mc("Nimble: tasks…", "Nimble tasks…"), mc("Run tests in file"), mc("Test explorer", "Test explorer"),
      mc("Test coverage: run and colour the lines that ran", "Test coverage (any language)"),
      mc("Test coverage: summary by file", "Coverage summary"),
      msub("Notebook", @[mc("Notebook: run the cell", "Run the cell (Ctrl+Enter)"),
        mc("Notebook: run the cell and go to the next", "Run the cell, then the next"),
        mc("Notebook: run all the cells", "Run all the cells"), mc("Notebook: run the cells above and this one", "Run the cells above and this one"),
        msep(), mc("Notebook: the cell's whole output", "The cell's whole output"),
        mc("Notebook: clear the outputs", "Clear the outputs"), mc("Notebook: restart the session", "Restart the session")]),
      msub("REPL", @[mc("REPL: send the selection or the statement at the cursor", "Send selection / statement (Shift+Enter)"),
        mc("REPL: send the cell (# %%)", "Send the cell"), mc("REPL: send the whole file", "Send the file"),
        mc("REPL: open the REPL for this language", "Open the REPL"), mc("REPL: restart", "Restart")]),
      msub("Debugger", @[mc("Debug: check the debugger for this file", "Check the debugger"),
        mc("Debug: choose the debugger for this language…", "Choose…"), mc("Debug: install the debugger for this language…", "Install…")]),
      msep(),
      msub("Build mode", @[mc("Nim: build mode debug", "debug", chk(cfgNimMode == "debug")),
        mc("Nim: build mode release", "release", chk(cfgNimMode == "release")),
        mc("Nim: build mode danger", "danger", chk(cfgNimMode == "danger"))]),
      msub("Backend", @[mc("Nim: backend C", "C", chk(cfgNimTarget == "c")), mc("Nim: backend C++", "C++", chk(cfgNimTarget == "cpp")),
        mc("Nim: backend JavaScript", "JavaScript", chk(cfgNimTarget == "js")),
        mc("Nim: backend Objective-C", "Objective-C", chk(cfgNimTarget == "objc"))])]
  of "Git":
    @[mc("Git panel", "Source control"), mc("Git: branches…", "Branches…"), msep(),
      mc("Git: commit (message box)…", "Commit…"), mc("Git: amend the last commit…", "Amend the last commit…"),
      mc("Git: undo…", "Undo… (commit, pull, merge)"), msep(),
      mc("Git: sync (pull, then push)", "Sync"), mc("Git: pull", "Pull"), mc("Git: push", "Push"),
      mc("Git: sign in to GitHub", "Sign in to GitHub…"),
      msub("Pull and fetch", @[mc("Git: pull (rebase)", "Pull (rebase)"), mc("Git: fetch", "Fetch")]), msep(),
      mc("Git: changes (every change, editable)…", "Changes… (every change, editable)"),
      msub("Stage", @[mc("Git: stage this change", "Stage this change"), mc("Git: stage selected lines", "Stage selected lines"),
        mc("Git: stage all", "Stage all"), mc("Git: unstage this change", "Unstage this change"),
        mc("Git: unstage this file", "Unstage this file")]),
      msub("History", @[mc("Git: history…", "History…"), mc("Git: branch graph", "Branch graph"),
        mc("Git: blame this file", "Blame this file"), mc("Git: history of these lines", "History of these lines"),
        mc("Git: find the commit that broke it (bisect)…", "Find the commit that broke it (bisect)…")]),
      msub("Compare", @[mc("Git: compare with last commit (side by side)", "Compare with last commit"),
        mc("Git: compare with a branch…", "Compare with a branch…")]),
      msub("Branches and commits", @[mc("Git: interactive rebase…", "Interactive rebase…"),
        mc("Git: cherry-pick from a branch…", "Cherry-pick from a branch…"), mc("Git: stash…", "Stash…"),
        mc("Git: worktrees…", "Worktrees…"), mc("Git: submodules…", "Submodules…")]),
      msub("Merge", @[mc("Git: merge editor (ours | theirs | result)", "Merge editor (3 panes)"),
        mc("Git: next merge conflict", "Next conflict"),
        mc("Git: accept ours (conflict at cursor)", "Accept ours"), mc("Git: accept theirs (conflict at cursor)", "Accept theirs"),
        mc("Git: accept both (conflict at cursor)", "Accept both"), msep(),
        mc("Git: continue (merge / rebase)", "Continue"), mc("Git: abort (merge / rebase)", "Abort")]),
      mc("Git: GitHub…", "GitHub (pull requests, issues, CI)…"),
      msub("More", @[mc("Git: create a tag…", "Create a tag…"), mc("Git: push tags", "Push tags"),
        mc("Git: copy link to this line", "Copy link to this line"), mc("Git: create a pull request (gh)", "Pull request (gh)"),
        mc("Git: clone a repository…", "Clone a repository…"),
        mc("Git: initialize a repository here", "Initialize a repository here (git init)")])]
  of "Nim":
    # (short enough for a 10-inch tablet: the rest in submenus)
    @[mc("Nim: expand macro/template at cursor", "Expand macro"), mc("Nim: expand macro one level", "Expand one level"),
      mc("Nim: check project", "Check project"), msep(),
      msub("Run", @[mc("Nim: run the selection", "Run the selection"),
        mc("Nim: run the examples at the cursor (runnableExamples)", "Run the examples here"),
        mc("Nim: run all examples in this file", "Run all examples in the file"),
        mc("Nim: benchmark a call…", "Benchmark a call…"), mc("Nim: REPL (inim / nim secret)", "REPL"), msep(),
        mc("Nim: write tests for this proc (from running it)", "Write tests for this proc (from running it)"),
        mc("Notebook: run the cell", "Notebook: run the cell (Ctrl+Enter)"),
        mc("Run with memory checks", "Run with memory checks")]),
      msub("Inspect", @[mc("Nim: why? (where an exception or a side effect comes from)", "Why? (exceptions, side effects)"),
        mc("Nim: expand macro/template in a tab", "Macro expansion in a tab"),
        mc("Nim: ARC/ORC view of current proc (expandArc)", "ARC/ORC view"),
        mc("Nim: show where ARC/ORC copies (⧉copy)", "Where ARC/ORC copies (⧉copy)"),
        mc("Nim: show generated C", "Show generated C"),
        mc("Compiler Explorer", "Compiler Explorer (assembly, live)"),
        mc("Nim: decompile this proc (side by side)", "Decompile this proc"),
        mc("Decompile a program…", "Decompile a program…"),
        mc("Nim: what can this proc raise?", "What can this proc raise?"),
        mc("Call hierarchy (callers and calls)", "Call hierarchy"),
        mc("Type hierarchy (supertypes and subtypes)", "Type hierarchy")]),
      msub("Refactor", @[mc("Nim: extract selection into a proc", "Extract selection into a proc"),
        mc("Refactor: extract into a variable", "Extract into a variable"), mc("Nim: inline variable", "Inline variable"),
        mc("Refactor: object ⇄ ref object", "object ⇄ ref object"),
        mc("Refactor: split the selected declarations into a new module…", "Split into a new module…"),
        mc("Refactor: callback → async", "Callback → async"),
        mc("Refactor: switch call syntax — f(x, y) · x.f(y) · f x, y", "f(x, y) · x.f(y) · f x, y"),
        mc("Nim: use fmt for this string", "\"a\" & x → fmt\"a{x}\""),
        mc("Nim: evaluate at compile time", "Evaluate at compile time"),
        mc("Nim: sort imports", "Sort imports"), mc("Nim: organize imports (remove unused, sort)", "Organize imports"), mc("Nim: toggle proc ⇄ func", "proc ⇄ func"),
        mc("Nim: toggle export marker (*)", "Toggle export (*)"), msep(),
        mc("Nim: add the missing case branches", "Add missing case branches"),
        mc("Nim: generate $, ==, hash and a constructor for this type", "Generate $, ==, hash, constructor"),
        mc("Nim: add a doc comment to this proc", "Add doc comment")]),
      msub("C interop", @[mc("Nim: go to the C declaration (importc)", "Go to the C declaration"),
        mc("Nim: check the importc wrappers against their headers", "Check wrappers against headers"),
        mc("Nim: wrap a C header…", "Wrap a C header…"),
        mc("Nim: write compile_commands.json for clangd", "compile_commands.json for clangd")]),
      msub("Documentation", @[mc("Nim: open documentation for symbol", "Documentation for symbol"),
        mc("Nim: standard library docs browser…", "Standard library docs…"),
        mc("Nim: generate docs", "Generate docs"),
        mc("Nim: share to the Playground (link to the clipboard)", "Share to Playground")]), msep(),
      msub("Nimble", @[mc("Nimble: dependencies and updates…", "dependencies and updates…"),
        mc("Nimble: dependency tree", "dependency tree"),
        mc("Nimble: build", "build"), mc("Nimble: run", "run"), mc("Nimble: test", "test"),
        mc("Nimble: install dependencies", "install dependencies"), mc("Nimble: add a dependency…", "add dependency…"),
        mc("Nimble: search packages…", "search packages…"), mc("Nimble: custom command…", "custom command…"), msep(),
        mc("Nimble: release a new version…", "release a new version (version, commit, tag, push)…")]),
      mc("Atlas…"), msub("Nim 3 (Nimony)", @[mc("Nimony: check file", "check file"), mc("Nimony: run file", "run file"), msep(),
        mc("Nim 3: what this file needs (porting problems)", "What this file needs to be Nim 3"),
        mc("Nim 3: port this file with AI", "Port this file with AI…"),
        mc("Nim 3: the NIF of this file beside it", "The NIF beside it"), msep(),
        mc("Nim 3: pnak fetch (the project's packages, in deps/)", "pnak fetch"),
        mc("Nim 3: pnak pin (write pnak.nif)", "pnak pin"), msep(),
        mc("Nim 3: this project is Nim 3 (nimony)", "This project is Nim 3"),
        mc("Nim 3: this project is Nim 2 (nim)", "This project is Nim 2"),
        mc("Nim 3: decide from the project (auto)", "Decide from the project"), msep(),
        mc("Nim 3: install or update nimony", "Install or update nimony…")]), msep(),
      msub("Toolchain", @[mc("Nim: switch compiler version…", "Switch compiler version…"),
        mc("Nimble: install nimlangserver", "Install nimlangserver"), mc("Nimble: install nph (formatter)", "Install nph")]),
      msub("Language server", @[mc("Nim: language server status", "Status"),
        mc("Restart language server"), mc("Nim: restart nimsuggest", "Restart nimsuggest"),
        mc("Nim: use current file as main module", "Use this file as main module"),
        mc("Nim: language server settings…", "nimlangserver settings…")]),
      mc("Nim panel (project, tools, toolchain)", "Nim panel")]
  of "AI":
    @[mc("AI assistant", "Open assistant"), mc("AI: new chat", "New chat"), mc("AI: chat history…", "Chat history…"),
      mc("AI: regenerate last reply", "Regenerate last reply"), msep(),
      mc("AI: ask about selection", "Ask about selection / file"), mc("AI: edit selection…", "Edit selection with AI…"),
      mc("AI: explain code", "Explain code"), mc("AI: fix problems in file", "Fix problems"),
      mc("AI: write tests", "Write tests"), mc("AI: add doc comments", "Add doc comments"),
      mc("AI: fix problem at cursor", "Fix problem at cursor"), mc("AI: explain problem at cursor", "Explain problem at cursor"),
      mc("AI: review staged changes (findings in Problems)", "Review staged changes"),
      mc("AI: review the assistant's changes…", "Review the assistant's changes…"),
      mc("AI: undo the assistant's changes…", "Undo the assistant's changes…"),
      mc("AI: MCP servers…", "MCP servers…"),
      mc("AI: fast / smart model", (if aiFastOn: "Use the smart model" else: "Use the fast model")),
      mc("Git: generate commit message with AI", "Write commit message"), msep(),
      mc("AI: toggle inline suggestions", "Inline suggestions (Tab)", chk(cfgGhostOn)),
      mc("AI: choose provider…", "Provider: " & cfgAiProvider), mc("AI: choose model…", "Model…"),
      mc("AI: toggle agent mode", "Agent mode (tools)", chk(cfgAiAgent)), mc("AI: settings…", "AI settings…")]
  of "Plugins":
    @[mc("Plugins panel", "Plugins panel", chk(rightOpen and rightView == svPlugins)),
      mc("Plugins: available plugins (ned's own)…", "Available plugins (ned's own)…"),
      mc("Plugins: run a plugin's command…", "Plugin commands…"), msep(),
      mc("Plugins: turn one on or off…", "Turn one on or off…"), mc("Plugins: permissions…", "Permissions…"),
      mc("Plugins: uninstall / remove one…", "Uninstall…"),
      mc("Plugins: reload", "Reload"), mc("Plugins: reload one…", "Reload one…"),
      mc("Plugins: update (git pull)", "Update (git pull)"), msep(),
      mc("Plugins: install from git…", "Install from git…"), mc("Plugins: browse the plugin list…", "Browse the plugin list…"),
      mc("Plugins: add an example…", "Add an example…"), msep(),
      mc("Plugins: new plugin…", "New plugin…"), mc("Plugins: new plugin in full Nim (compiled)…", "New plugin in full Nim…"),
      mc("Plugins: the API (nedplugin.nim)", "The API (nedplugin.nim)")]
  else:
    @[mc("Key bindings"), mc("Keyboard shortcuts…", "Change keyboard shortcuts…"), mc("Show recent messages", "Recent messages"),
      mc("Welcome page"), mc("Tips"),
      msub("Nim tour", @[mc("Nim: tour (lessons in the notebook)", "Start or go on"),
        mc("Nim: tour — next lesson", "Next lesson"), mc("Nim: tour — previous lesson", "Previous lesson"),
        mc("Nim: tour — all the lessons…", "All the lessons…"), msep(),
        mc("Nim: tour — reset this lesson", "Reset this lesson…")]), msep(), mc("Check setup", "Check setup…"),
      mc("Performance report", "Performance…"), mc("Copy info for bug report"), msep(), mc("About ned")]

proc openMenuBar(i: int) =
  ## opens menu-bar menu `i` (wrapping round at both ends) under its title in the title bar, closing any other menu
  let n = MenuNames.len
  let k = (i + n) mod n
  closeMenus()
  var x = 0
  for (a, _, idx) in menuBarRanges:
    if idx == k: x = a
  openMenu(menuItems(k), x, (if lay.titleY >= 0: lay.titleY + 1 else: 0), k)

proc openAppMenu() =
  ## the ≡ button: menu bar entries as submenus (used when the bar does not fit)
  var items: seq[MenuItem]
  for i, n in MenuNames: items.add msub(n, menuItems(i))
  closeMenus()
  openMenu(items, 0, (if lay.titleY >= 0: lay.titleY + 1 else: 0), -1)
