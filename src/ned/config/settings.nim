# ════════════════════════════════════════════════════════════════════════════
#  Config & persistent state
# ════════════════════════════════════════════════════════════════════════════


proc configDir(): string = getEnv("XDG_CONFIG_HOME", getHomeDir() / ".config") / AppName
proc configFile(): string = configDir() / "config.json"
proc spellUserFile(): string = configDir() / "words.txt"     # your own dictionary words (spell check)
proc stateFile(): string = getEnv("XDG_STATE_HOME", getHomeDir() / ".local" / "state") / AppName / "state.json"
proc tmpDir(): string =
  result = getEnv("TMPDIR")
  if result.len == 0 or not dirExists(result): result = "/tmp"
  if not dirExists(result): result = getHomeDir()

# ── settings registry: one table drives the settings file, the settings UI and validation ──

type
  SetKind = enum skBool, skInt, skStr, skEnum, skJson
  SetDef = object
    key, cat, doc: string
    kind: SetKind
    def: JsonNode
    opts: seq[string]

var
  setDefs: seq[SetDef]
  setIndex = initTable[string, int]()
  settingsJ = newJObject()      # effective values: defaults overlaid with the file
  settingsUser = newJObject()   # what the file actually sets

const NlsKeys = ["projectMapping", "workingDirectoryMapping", "checkOnSave", "nimsuggestPath", "timeout",
                 "autoRestart", "autoCheckFile", "autoCheckProject", "logNimsuggest", "inlayHints",
                 "notificationVerbosity", "formatOnSave", "nimsuggestIdleTimeout", "useNimCheck", "nimExpandArc",
                 "nimExpandMacro", "maxNimsuggestProcesses", "nimsuggestTimeout", "nimsuggestMaxMemory",
                 "useNimTrack"]

proc allThemeNames(): seq[string] =
  for t in allThemes(): result.add t.name

proc defS(cat, key: string, def: JsonNode, doc: string, opts: seq[string] = @[]) =
  let kind = if opts.len > 0: skEnum
             else:
               case def.kind
               of JBool: skBool
               of JInt: skInt
               of JString: skStr
               else: skJson
  setIndex[key] = setDefs.len
  setDefs.add SetDef(key: key, cat: cat, doc: doc, kind: kind, def: def, opts: opts)

proc initSettingDefs() =
  if setDefs.len > 0: return
  # ── Appearance ──
  defS("Appearance", "theme", %"nim-crown", "Colour theme — Alt+T previews them live; auto: theme.light or " &
       "theme.dark, whichever matches the terminal's background", allThemeNames() & @["auto"])
  defS("Appearance", "theme.dark", %"nim-crown", "With \"theme\": \"auto\": the theme on a dark terminal", allThemeNames())
  defS("Appearance", "theme.light", %"github-light", "With \"theme\": \"auto\": the theme on a light terminal", allThemeNames())
  defS("Appearance", "theme.autoBy", %"terminal", "With \"theme\": \"auto\": light or dark as the terminal's background " &
       "is (terminal), or light by day and dark at night (clock: theme.dayStarts, theme.nightStarts)", @["terminal", "clock"])
  defS("Appearance", "theme.dayStarts", %"07:00", "With theme.autoBy \"clock\": when the light theme starts (HH:MM)")
  defS("Appearance", "theme.nightStarts", %"19:00", "With theme.autoBy \"clock\": when the dark theme starts (HH:MM)")
  defS("Appearance", "theme.termuxColors", %false, "Termux: keep ~/.termux/colors.properties matching ned's theme, so the " &
       "whole terminal (the shell after ned too) has its colours. Palette › Theme: put Termux's own colours back")
  defS("Appearance", "theme.colors", newJObject(),
       "Change colours of any theme: {\"comment\": \"#8a8a8a\", \"bg\": \"#101010\"} for all, " &
       "{\"nim-crown\": {…}} for one. Names: " & ThemeKeys.join(", ") & ", " & ChromeKeys.join(", ") & ", ruler")
  defS("Appearance", "ui.themeBeforeAccessible", %"", "(the theme to go back to when accessibility mode is turned off)")
  defS("Appearance", "ui.accessible", %false, "Accessibility mode: plain ASCII for every frame, bar and symbol (screen " &
       "readers read it sensibly), letters beside colours (E/W in the gutter, + ~ _ for git, B for breakpoints), ASCII icons, " &
       "no minimap. Palette › Accessibility mode also picks a high-contrast theme")
  defS("Appearance", "ui.icons", %"unicode", "Icon set. 'nerd' needs a Nerd Font (Termux: ~/.termux/font.ttf)",
       @["unicode", "nerd", "ascii"])
  defS("Appearance", "ui.titleBar", %true, "Title bar with menus, search box and layout buttons")
  defS("Appearance", "ui.menuBar", %true, "Show File/Edit/View… menus in the title bar when there is room (F10 opens them)")
  defS("Appearance", "ui.tabBar", %true, "Tabs above the editor")
  defS("Appearance", "ui.breadcrumbs", %true, "Path › symbol breadcrumbs under the tabs")
  defS("Appearance", "ui.statusBar", %true, "Status bar at the bottom")
  defS("Appearance", "ui.touchBar", %"off",
       "A row of big keys above the status bar for touch (Esc, Tab, arrows, undo, redo, save, find, commands): " &
       "auto = on narrow screens (phones). View › Appearance › Touch bar, or the palette, turns it on and off",
       @["off", "on", "auto"])
  defS("Appearance", "ui.touchBarKeys", %["esc", "tab", "left", "down", "up", "right", "undo", "redo", "save", "find", "palette"],
       "The touch bar's keys, in order: esc tab enter left right up down home end pgup pgdn undo redo save find " &
       "palette copy cut paste, a key like \"ctrl+p\" or \"alt+r\", or \"Label=command\" for any palette command " &
       "(e.g. \"Run=Run file\")")
  defS("Appearance", "ui.minimap", %"auto", "Code minimap at the right edge ('auto' = when the editor is wide)",
       @["auto", "on", "off"])
  defS("Appearance", "ui.scrollbar", %true, "Scrollbar with diagnostic marks (click or drag it to scroll)")
  defS("Appearance", "ui.longPressMenu", %true,
       "Touch: press and hold (about half a second, without moving) opens the context menu, like a right click")
  defS("Appearance", "ui.shadows", %true, "Drop shadows under menus, popups and dialogs")
  defS("Appearance", "ui.italics", %false, "Italic comments, hints and placeholders — off by default because " &
       "many terminals and fonts (Termux included) have no italic face")
  defS("Appearance", "ui.toasts", %true, "Pop-up notifications for warnings, errors and finished jobs")
  defS("Appearance", "ui.messages", %"popup",
       "Where messages (info, warnings, errors) show: \"popup\" — the whole text, wrapped, in a popup — or " &
       "\"statusbar\" (one line, cut to fit). Palette › Show recent messages lists the last 100",
       @["popup", "statusbar"])
  defS("Appearance", "ui.hoverEffects", %true, "Highlight buttons and rows under the mouse pointer (mouse motion tracking)")
  defS("Appearance", "ui.pointerShapes", %true, "The mouse pointer changes like in a desktop app: a hand over what " &
       "can be clicked, an I-beam over text (terminals that support OSC 22: kitty, foot, WezTerm, Ghostty, xterm; " &
       "others ignore it)")
  defS("Appearance", "ui.tooltips", %true, "Tooltips when the pointer rests on a button")
  defS("Appearance", "ui.mouse", %true, "Mouse and touch support (Alt+U toggles it so Termux text selection works)")
  defS("Appearance", "ui.cursorStyle", %"bar", "Text cursor shape", @["bar", "block", "underline"])
  defS("Appearance", "ui.trueColor", %"auto", "24-bit colour ('off' uses the 256-colour palette)", @["auto", "on", "off"])
  defS("Appearance", "ui.leftDockWidth", %0, "Left dock width in columns (0 = automatic)")
  defS("Appearance", "ui.rightDockWidth", %0, "Right dock width in columns (0 = automatic)")
  defS("Appearance", "ui.panelHeight", %0, "Bottom panel height in rows (0 = automatic)")
  defS("Appearance", "ui.restoreLayout", %true, "Reopen docks and panels the way you left them")
  # ── Editor ──
  defS("Editor", "editor.tabSize", %4, "Default indentation width (files keep their own detected indentation)")
  defS("Editor", "editor.keymap", %"default", "Key bindings: default (VS Code-like) · vim · emacs (C-f C-b C-n C-p, " &
       "C-x C-s, C-k / C-y, C-SPC mark, M-x …) · helix (select then act: w x d c y p, space mode, g goto)",
       @["default", "vim", "emacs", "helix"])
  defS("Editor", "editor.softWrap", %true, "Wrap long lines at the window edge (Alt+W)")
  defS("Editor", "editor.largeFileSize", %16,
       "Large-file mode for files of this many MB or more: no soft wrap, language server, Nim engine, minimap or " &
       "word highlight, so scrolling and typing stay instant (palette › Large file mode turns it off for one file)")
  defS("Editor", "editor.longLineLimit", %10000,
       "Large-file mode also for a file with a line this long — minified JSON/JS, one-line logs (0: never)")
  defS("Editor", "editor.lineNumbers", %"absolute", "Line numbers (Alt+L cycles)", @["absolute", "relative", "off"])
  defS("Editor", "editor.scrollOff", %3, "Lines kept visible above and below the cursor")
  defS("Editor", "editor.lineHighlight", %true, "Highlight the line with the cursor")
  defS("Editor", "editor.indentGuides", %true, "Vertical indentation guides")
  defS("Editor", "editor.rulers", newJArray(), "Vertical lines at these columns, like VS Code's rulers: [80] or " &
       "[80, 120] (best per project, in .ned/settings.json) — View › Editor › Rulers hides and shows them")
  defS("Editor", "editor.rulerTint", %true, "With rulers: tint the part of a line that goes past the last one")
  defS("Editor", "editor.languageServerHints", %true, "Opening Python, Rust, Go, C, JS/TS, Lua, Ruby, shell or CSS " &
       "with no language server installed: say once which one to install (with an Install button)")
  defS("Editor", "editor.linkedEditing", %true, "HTML: renaming an opening tag renames its closing tag (and back)")
  defS("Editor", "editor.emmet", %true, "HTML: Tab after an Emmet abbreviation expands it — ul>li.item*3, " &
       "div#main>p{text}+a[href=/], (header>nav)+main, ! for a whole page")
  defS("Editor", "editor.spellCheck", %"markdown", "Spell check: off · markdown (Markdown files and commit messages) · " &
       "on (also comments and strings in code). Misspelled words are underlined; Alt+Enter on one suggests the spelling",
       @["off", "markdown", "on"])
  defS("Editor", "editor.spellLanguage", %"en_US", "The dictionary's language: en_US, en_GB, de_DE, fr_FR … (a hunspell " &
       "dictionary of that name, or palette › Spell check: download a dictionary)")
  defS("Editor", "editor.spellDictionary", %"", "A dictionary file to use instead: hunspell .dic (its .aff beside it) or " &
       "a word list, one word per line")
  defS("Editor", "editor.colorSwatches", %true, "A small block in the colour before #RRGGBB, rgb(…), hsl(…) and Nim's " &
       "0xRRGGBB — click it to copy the colour in another notation or make it lighter or darker")
  defS("Editor", "editor.showWhitespace", %false, "Show spaces and tabs")
  defS("Editor", "editor.stickyScroll", %true, "Keep the enclosing proc/type headers visible while scrolling")
  defS("Editor", "editor.rainbowBrackets", %true, "Colour brackets by nesting depth")
  defS("Editor", "editor.fontLigatures", %"off",
       "Ligatures for operators in code (->, =>, !=, <=, >=, :=). The terminal's font draws ligatures, not ned: font = " &
       "each operator kept in one colour and style so a terminal with a ligature font (Kitty, WezTerm, iTerm2, " &
       "Ghostty, Windows Terminal with Fira Code, JetBrains Mono, Cascadia Code …) joins it · symbols = ned draws " &
       "them itself, in any terminal (Termux too): ─→ ═⇒ ≠ ≤ ≥ ≔ in the same columns, the real text on the line " &
       "with the cursor · off", @["off", "font", "symbols"])
  defS("Editor", "editor.highlightOccurrences", %true, "Highlight other occurrences of the word under the cursor")
  defS("Editor", "editor.autoClosePairs", %true, "Type the closing bracket/quote automatically")
  defS("Editor", "editor.autoComplete", %true, "Show completions while typing (Ctrl+Space always works)")
  defS("Editor", "editor.completionDocs", %true,
       "Documentation of the selected completion beside the list (Ctrl+Space toggles it while the list is open)")
  defS("Editor", "editor.snippets", %true, "Tab after a keyword expands a snippet (proc, for, test, def, fn, html …)")
  defS("Editor", "editor.autoHover", %true, "Show hover info automatically when the cursor rests on a symbol")
  defS("Editor", "editor.hoverDelay", %700, "Milliseconds before automatic hover appears")
  defS("Editor", "editor.inlayHints", %true, "Inline type/parameter hints from the language server (Nim: see nim.typeHints)")
  defS("Nim", "nim.typeHints", %"builtin", "Where the types shown after lets and vars come from: ned's own engine " &
       "(builtin: at once, no nimsuggest needed) or nimsuggest", @["builtin", "nimsuggest"])
  defS("Editor", "editor.codeLens", %true, "▶ run buttons in the gutter for tests, main blocks and nimble tasks")
  defS("Nim", "nim.referenceCounts", %true, "\"3 references\" after each top-level proc and type (built-in engine); " &
       "a click lists them; \"no references\" in yellow for an export nothing uses")
  defS("Editor", "editor.folding", %true, "Code folding by indentation (Ctrl+Shift+[ / ], gutter ▾ ▸, palette)")
  defS("Editor", "editor.formatOnSave", %false, "Run the formatter when saving (for Nim: nim.formatter)")
  defS("Editor", "editor.formatOnPaste", %"indent",
       "Pasted lines of code: indent = they take the indentation of where they go (their own layout kept) · " &
       "format = that, and Nim is formatted too (built-in formatter) · off = pasted exactly as copied",
       @["indent", "format", "off"])
  defS("Editor", "csv.alignColumns", %true, "CSV and TSV files: line their columns up on screen (the file itself is not " &
       "changed) and keep the first row in view")
  defS("Editor", "editor.formatOnSaveScope", %"file",
       "With editor.formatOnSave: the whole file, or only the lines you changed since git last saw it (staged or " &
       "committed) — an old file you touch does not turn into one big diff", @["file", "changed"])
  defS("Editor", "editor.formatOnSaveLanguages", newJArray(), "With editor.formatOnSave: only these languages, " &
       "e.g. [\"nim\", \"json\"] (their ids: nim, json, markdown, css, python …); empty: every language that has a formatter")
  defS("Editor", "editor.persistentUndo", %true,
       "Keep each file's undo history after you close it (and ned): Ctrl+Z works again next time, as long as the " &
       "file was not changed by something else")
  defS("Editor", "editor.renamePreview", %true,
       "F2 rename: first list every change (Space unticks one, Enter applies) — false applies at once")
  defS("Editor", "editor.trimTrailingWhitespace", %true, "Remove trailing spaces when saving, from the lines you changed")
  defS("Editor", "editor.trimAllLines", %false, "With editor.trimTrailingWhitespace: every line of the file, not only the ones you changed")
  defS("Editor", "editor.editorConfig", %true, "Follow a project's .editorconfig: indentation, tab width, line ends of " &
       "new files, trailing whitespace, final newline, max_line_length for the ruler (it wins over these settings)")
  defS("Editor", "editor.autoSave", %false, "Save automatically when you switch tabs or leave ned")
  defS("Editor", "editor.vimMode", %false, "Vim keybindings (normal/insert/visual modes, :w :q …)")
  # ── Zen ──
  defS("Zen mode", "zen.width", %90, "Text column width in zen mode (Alt+Z); the column is centred")
  defS("Zen mode", "zen.hideLineNumbers", %true, "Hide line numbers and the gutter in zen mode")
  defS("Zen mode", "zen.dimOthers", %true, "Dim everything except the block or paragraph you are in")
  defS("Zen mode", "zen.typewriter", %false, "Typewriter scrolling: keep the cursor line in the middle of the screen")
  defS("Zen mode", "zen.gitChanges", %false, "Show git's change marks (added, changed, deleted lines) in the gutter in " &
       "zen mode too")
  defS("Zen mode", "zen.showInfo", %true, "Show a quiet line/word count in the corner")
  defS("TODO comments", "todo.highlight", %true,
       "Colour TODO, FIXME, BUG, HACK and NOTE where a comment starts with them, and mark them on the scrollbar")
  defS("TODO comments", "todo.tags", %*{"FIXME": "red", "BUG": "red", "HACK": "orange", "XXX": "orange",
       "TODO": "yellow", "NOTE": "blue"},
       "Comment tags and their colours: red, orange, yellow, green, blue, purple, accent or #RRGGBB. " &
       "Red ones are counted in the status bar")
  defS("TODO comments", "todo.withName", %false, "TODO: insert a tag comment adds your git user name: TODO(name): …")
  # ── Vim ──
  defS("Vim", "vim.escapeSequence", %"", "Two keys typed quickly in insert mode that act as Esc, e.g. \"jk\"")
  defS("Vim", "vim.useSystemClipboard", %true, "y/d/p use the system clipboard")
  defS("Vim", "vim.relativeNumbers", %false, "Relative line numbers while vim mode is on")
  # ── Files ──
  defS("Files", "files.showHidden", %false, "Show dot-files in the file tree and file finder")
  defS("Files", "security.folderTrust", %"ask",
       "Before ned runs a folder's code — the Nim compiler (its config.nims, .nims files and macros can run " &
       "commands), nimble, nimsuggest, the folder's tests — you trust the folder, once (palette › Workspace: trust " &
       "this folder). Until then the built-in engine still completes, explains and checks the code. off = trust " &
       "every folder", @["ask", "off"])
  defS("Files", "files.exclude", %*["node_modules", "nimcache", "__pycache__", "target", "dist", ".git", ".venv",
       "venv", ".nimble", "zig-cache", "zig-out", ".gradle", ".idea", ".cache", "htmldocs", "testresults"],
       "Folders skipped by the file tree, file finder and built-in search")
  defS("Files", "files.scanLimit", %500000, "Maximum number of files indexed for Ctrl+P")
  defS("Files", "files.protectLibraries", %true, "Files of the Nim toolchain (the standard library, the compiler) " &
       "and of installed nimble packages open read-only — go to definition often lands there, and a stray key " &
       "followed by a save would change them for every project. Palette › File: allow editing this file")
  defS("Files", "files.autoReload", %true, "Reload files changed on disk when they have no unsaved edits")
  defS("Files", "files.restoreSession", %true, "Reopen the files that were open last time in this folder")
  # ── Search ──
  defS("Search", "search.useRipgrep", %true, "Use ripgrep (pkg install ripgrep) for project search when available")
  defS("Search", "search.maxResults", %5000, "Stop project search after this many matches")
  # ── Terminal ──
  defS("Terminal", "terminal.shell", %"", "Shell for the integrated terminal (empty = $SHELL, then bash/sh)")
  defS("Terminal", "terminal.scrollback", %3000, "Lines of scrollback in the integrated terminal")
  defS("Terminal", "terminal.cwd", %"project", "Where new terminals start", @["project", "file"])
  defS("Terminal", "terminal.shellIntegration", %true, "bash, zsh and fish mark each command (OSC 133): Ctrl+↑/↓ " &
       "jumps between them, failed ones are marked, and a command's output can be copied or the command run again")
  # ── Git ──
  defS("Git", "git.gutter", %true, "Added/modified/deleted marks next to line numbers")
  defS("Git", "git.autoRefresh", %true, "Refresh the git panel periodically while it is open")
  defS("Git", "git.inlineBlame", %false, "Show who last changed the current line, and when, at its end")
  # ── Nim ──
  defS("Nim", "nim.ide", %"builtin",
       "Code intelligence: builtin = ned's own Nim index (instant, no compiler needed) plus nimsuggest for what only " &
       "the compiler knows · nimlangserver = the language server · off", @["builtin", "nimlangserver", "off"])
  defS("Nim", "nim.semanticColors", %true,
       "Colour names by what they are (procs, types, constants, fields), as the built-in engine knows them — not by " &
       "whether they start with a capital letter. Other languages get them from their language server")
  defS("Nim", "nim.richColors", %true,
       "With semantic colours: a `var` tinted (a `let` stays plain), the module's own variables in bold, deprecated " &
       "names faded and struck through, cast/addr/unsafeAddr/ptr in the warning colour")
  defS("Nim", "nim.autoImport", %true,
       "Completion also offers standard-library names whose module is not imported yet; choosing one adds the import")
  defS("Nim", "nim.postfixCompletion", %true,
       "After a `.`, completion also offers postfix templates that wrap what is in front of it: xs.for → " &
       "for x in xs:, c.case → a case with every value of its enum, v.if, x.echo, x.let, x.not …")
  defS("Nim", "nim.showCopies", %true,
       "Mark where ARC/ORC copies a value (a string, a seq, an object): after a save the compiler shows ned its " &
       "=copy and =dup calls (nim c --expandArc, in a trusted folder) and ⧉copy appears beside each — hover it " &
       "for why, and how to move instead")
  defS("Git", "git.checksBeforeCommit", %"both",
       "Before a commit: format = the files it takes are formatted (ned's own formatters, on what is staged; the " &
       "languages editor.formatOnSave formats), " &
       "tests = the tests that cover them pass (in a trusted folder) · both · off. One that fails stops the commit " &
       "and says why, with a way to fix it or to commit anyway", @["both", "format", "tests", "off"])
  defS("Editor", "editor.dimInactiveCode", %true,
       "Dim code a compile leaves out here: a Nim `when` branch that is false on this platform (when defined(windows) " &
       "on Linux — hover the `when` for its value), C's #if 0 and #ifdef __cplusplus")
  defS("Nim", "nim.testOnSave", %"related",
       "Run std/unittest tests in the background when you save (in a trusted folder): related = the test file you " &
       "save, or the test files that import the module you save · file = only a test file you save · off. ✓ or ✗ " &
       "shows beside each test, a failed check's message on its line", @["related", "file", "off"])
  defS("Nim", "nim.nimsuggest", %false,
       "builtin engine: also run nimsuggest (if installed) as a second opinion when ned's own index cannot tell what " &
       "a name is. Off by default: the index answers completion, hover, definitions, references and rename itself, " &
       "and `nim check` gives the errors while typing. nimsuggest takes 300 MB–1.5 GB per project")
  defS("Nim", "nim.formatter", %"builtin",
       "Formatter for Nim (Alt+F, editor.formatOnSave): builtin = ned's own, in nph's style, instant and always there " &
       "(it checks its result and leaves the file alone if the code would change) · nph · nimpretty (installed " &
       "separately). A \"formatters\" entry for \"nim\" wins over this", @["builtin", "nph", "nimpretty"])
  defS("Nim", "nim.format.lineLength", %88, "The built-in Nim formatter's line length (nph's is 88; 80 and 100 are " &
       "common)")
  defS("Nim", "nim.format.params", %"fit",
       "How a routine's parameters are laid out (built-in formatter): fit = on one line when it fits, else all on " &
       "the next line or one per line (nph) · onePerLine = one per line when the line is too long · always = one per " &
       "line whenever there are two or more · keep = the line breaks you wrote", @["fit", "onePerLine", "always", "keep"])
  defS("Nim", "nim.format.arguments", %"fit",
       "How a call's arguments are laid out (built-in formatter): fit = on one line when it fits, else packed on the " &
       "next lines · onePerLine = one per line when the line is too long · always = one per line whenever there are " &
       "two or more · keep = the line breaks you wrote", @["fit", "onePerLine", "always", "keep"])
  defS("Nim", "nim.format.collections", %"fit",
       "How array, seq, table, set and tuple literals are laid out (built-in formatter): fit · onePerLine · always · " &
       "keep — as for nim.format.arguments", @["fit", "onePerLine", "always", "keep"])
  defS("Nim", "nim.format.imports", %"keep",
       "The modules of an import (built-in formatter): keep = as written · sort = std/, pkg/, others, ./relative, " &
       "each alphabetical · merge = sorted, and imports that follow each other joined: std/os + std/strutils → " &
       "std/[os, strutils]. (Modules run their top-level code in import order: keep, if that matters to you)",
       @["keep", "sort", "merge"])
  defS("Nim", "nim.format.align", %false, "Built-in formatter: line up the types of an object's fields and the `=` of " &
       "const / let / var section members")
  defS("Nim", "nim.format.reflowDocComments", %false, "Built-in formatter: a ## doc comment paragraph with a line " &
       "longer than nim.format.lineLength is re-wrapped to fit (lists, code and tables stay as they are)")
  defS("Nim", "nim.format.maxBlankLines", %1, "Built-in formatter: empty lines kept in a row (1–3)")
  defS("Nim", "nim.format.verify", %false, "Built-in formatter: check each result with Nim's own parser as well (the " &
       "formatter checks its tokens and blocks anyway). Needs the compiler sources — choosenim and source builds have " &
       "them, or `nimble install compiler`; ned builds a small checker from them once, in the background")
  defS("C", "c.engine", %"auto",
       "What answers in C files: builtin = ned's own engine (completion with struct members, hover with the " &
       "comment above a declaration, F12 through #includes, references, rename, outline, signature help, the C " &
       "compiler's errors while you type — instant, nothing to install) · clangd (more precise with macros and " &
       "C++) · both = ned's answers at once and clangd's errors and fixes · auto = clangd when it is installed, " &
       "else ned's own", @["auto", "builtin", "clangd", "both"])
  defS("Nim", "nim.parameterHints", %"literals", "Parameter names shown before the arguments of a call " &
       "(built-in engine, with the inlay hints): literals = before numbers, strings, true/false/nil — draw(width: 10, " &
       "height: 20) · all = before every argument · off", @["literals", "all", "off"])
  defS("Nim", "nim.cSignatureHints", %true, "After a wrapper that imports C (importc), its C declaration — dimmed, " &
       "from the header or the {.emit.} (int puts(const char *s))")
  defS("Nim", "nim.formatEmitC", %true, "Formatting a Nim file also formats the C in its {.emit: \"\"\"…\"\"\".} blocks: " &
       "with clang-format when it is installed (your .clang-format applies), else with ned's own C formatter")
  defS("Nim", "nim.nimsuggestMaxMB", %1500,
       "Restart a nimsuggest whose memory grows beyond this many MB (0 = no limit; 800 in Termux unless you set it)")
  defS("Nim", "nim.nimsuggestIdleMinutes", %15,
       "Stop nimsuggest after this many minutes without a request, giving its memory back; it starts again when " &
       "needed (0 = keep it running)")
  defS("Nim", "nim.projectFile", %"",
       "Main module of the project, relative to the folder (empty = detect: <pkg>.nim of the .nimble, a bin, <folder>.nim, main.nim …)")
  defS("Nim", "nim.autoProjectMapping", %true,
       "Map the project's sources to its main module so nimlangserver runs ONE nimsuggest (tests share it; raise nim.maxNimsuggestProcesses to 2 to give them their own)")
  defS("Nim", "nim.buildMode", %"debug", "Build mode for Alt+R / Alt+B", @["debug", "release", "danger"])
  defS("Nim", "nim.backend", %"c", "Compiler backend", @["c", "cpp", "js", "objc"])
  defS("Nim", "nim.checkWrappers", %true, "Check importc wrappers against their C headers (or the C in an {.emit.}) when a file is opened " &
       "or saved: the number of parameters, int for C's int (cint), string for char* (cstring), float for C's " &
       "float (cfloat), size_t (csize_t), pointers, varargs — warnings with a fix (Alt+Enter)")
  defS("Nim", "nim.emitClangd", %true, "C in {.emit: \"\"\"…\"\"\".} goes through clangd when it is installed " &
       "(Termux: pkg install clang): its completion, hover, parameter hints and errors while you type. Off: ned's own " &
       "completion from the headers, and the C compiler's errors on save")
  defS("Nim", "nim.embeddedLanguages", newJObject(), "Code inside strings, coloured as its own language, by the " &
       "name before the string: {\"render\": \"html\", \"query\": \"sql\"}. Built in: {.emit.} (C, C++ or " &
       "JavaScript, as the backend), sql\"…\", re\"…\", peg\"…\", fmt\"…\" and &\"…\", parseJson(\"…\"), and " &
       "triple-quoted strings that start with an HTML tag or SQL. Mark any other string with #[html]# " &
       "(#[c]#, #[sql]#, #[css]# …) just before it")
  defS("Nim", "nim.compiler", %"nim", "Compiler used for Alt+R", @["nim", "nimony"])
  defS("Nim", "nim.liveDiagnostics", %true, "Errors while you type, not only on save")
  defS("Nim", "nim.liveDiagnosticsFrom", %"auto", "What checks the text while you type: the compiler (nim check " &
       "on the unsaved text, after a pause), nimsuggest, or auto: the compiler, unless its check of the file takes " &
       "over 10 s and nimsuggest runs", @["auto", "compiler", "nimsuggest"])
  defS("Nim", "nim.compilerAnswers", %true, "With nim.nimsuggest off: where ned's engine has no answer (a hover, Go to " &
       "definition — names a macro makes, say), ask the compiler once — one nimsuggest run for that question, which " &
       "then quits. Kept until the file changes")
  defS("Nim", "nim.engineChecks", %true, "While you type, ned's own engine checks what it can be sure of, at once " &
       "(before the compiler's check): a field name that is a typo of one the object has, a call with the wrong number " &
       "of arguments, code after a return, a local never used. The compiler's word wins on a line where both speak")
  defS("Nim", "nim.extraFlags", %"", "Extra flags for nim c/cpp/js when running or building, e.g. \"--mm:orc -d:ssl\"")
  defS("Nim", "nim.testFlags", %"--hints:off", "Flags used by the test explorer when compiling tests")
  # ── nimlangserver (sent to the server as its \"nim\" configuration section) ──
  defS("nimlangserver", "nim.projectMapping", newJArray(),
       "Map files to nimsuggest projects: [{\"projectFile\": \"src/main.nim\", \"fileRegex\": \".*\\\\.nim\"}]")
  defS("nimlangserver", "nim.workingDirectoryMapping", newJArray(),
       "Working directory per project: [{\"projectFile\": \"main.nim\", \"directory\": \"src\"}]")
  defS("nimlangserver", "nim.checkOnSave", %true, "Check the file when it is saved (`nim check` with the built-in engine)")
  defS("nimlangserver", "nim.nimsuggestPath", %"", "Path to nimsuggest (empty = from PATH)")
  defS("nimlangserver", "nim.timeout", %120000, "Request timeout in ms before nimlangserver restarts nimsuggest")
  defS("nimlangserver", "nim.autoRestart", %false, "Restart nimsuggest once after a crash")
  defS("nimlangserver", "nim.autoCheckFile", %true, "Check the current file while typing")
  defS("nimlangserver", "nim.autoCheckProject", %true, "Check the whole project after saving")
  defS("nimlangserver", "nim.logNimsuggest", %false, "Log nimsuggest traffic (debugging)")
  defS("nimlangserver", "nim.inlayHints", %*{"typeHints": {"enable": true},
       "exceptionHints": {"enable": false, "hintStringLeft": "try ", "hintStringRight": "!"},
       "parameterHints": {"enable": true}},
       "Inlay hints. Exception hints restart nimsuggest with --exceptionInlayHints and slow compiles down")
  defS("nimlangserver", "nim.notificationVerbosity", %"warning", "Which server notifications to show",
       @["none", "error", "warning", "info"])
  defS("nimlangserver", "nim.formatOnSave", %false, "Let the server format on save (needs nph)")
  defS("nimlangserver", "nim.nimsuggestIdleTimeout", %120000, "Stop idle nimsuggest processes after this many ms")
  defS("nimlangserver", "nim.useNimCheck", %false, "Lint with `nim check` instead of nimsuggest")
  defS("nimlangserver", "nim.nimExpandArc", %false, "Enable the server's expandArc command")
  defS("nimlangserver", "nim.nimExpandMacro", %false, "Enable the server's macro expansion command")
  defS("nimlangserver", "nim.maxNimsuggestProcesses", %1, "Live nimsuggest processes at most (0 = unlimited; keep low on phones)")
  defS("nimlangserver", "nim.nimsuggestTimeout", %60000, "Timeout in ms for nimsuggest start-up and first compile")
  defS("nimlangserver", "nim.nimsuggestMaxMemory", %0, "Memory cap per nimsuggest process in MB (0 = unlimited)")
  defS("nimlangserver", "nim.useNimTrack", %false, "Experimental: use nimtrack instead of nimsuggest")
  # ── AI ──
  defS("AI", "ai.provider", %"anthropic", "AI provider for the Assistant",
       @["anthropic", "openai", "openrouter", "ollama", "groq", "deepseek", "gemini", "mistral", "custom"])
  defS("AI", "ai.model", %"", "Model id (empty = provider default; palette › AI: choose model lists them)")
  defS("AI", "ai.apiKey", %"", "API key. Prefer an environment variable — see ai.apiKeyEnv")
  defS("AI", "ai.apiKeyEnv", %"", "Environment variable holding the key (empty = ANTHROPIC_API_KEY, OPENAI_API_KEY, …)")
  defS("AI", "ai.baseUrl", %"", "API base URL (empty = provider default; e.g. http://localhost:11434 for Ollama)")
  defS("AI", "ai.maxTokens", %8192, "Maximum tokens per reply")
  defS("AI", "ai.openaiApi", %"auto", "OpenAI endpoint: chat completions, the Responses API, or auto (switches by itself when a model needs it)",
       @["auto", "chat", "responses"])
  defS("AI", "ai.temperature", %(-1), "Sampling temperature ×100 (e.g. 30 = 0.3; -1 = provider default)")
  defS("AI", "ai.localUrl", %"http://127.0.0.1:11434", "Where Ollama listens (AI › on this device, offline)")
  defS("AI", "ai.agent", %true, "Agent mode: the assistant may read, search, edit files and run commands")
  defS("AI", "ai.autoApprove", %"reads", "Which agent actions run without asking", @["none", "reads", "edits", "all"])
  defS("AI", "ai.maxSteps", %30, "Maximum tool steps per request")
  defS("AI", "ai.checkEdits", %true, "Check the files the assistant edits (nim check; py_compile, node --check, cargo " &
       "check …) and tell it what is wrong, so it fixes its own mistakes before it says it is done")
  defS("AI", "ai.includeFile", %true, "Send the current file (or selection) with each message")
  defS("AI", "ai.systemPrompt", %"", "Extra instructions added to the system prompt")
  defS("AI", "ai.projectInstructions", %true, "Send AGENTS.md / CLAUDE.md / NED.md from the project with each request")
  defS("AI", "ai.promptCaching", %true, "Anthropic prompt caching: repeated context costs ~10% and answers start sooner")
  defS("AI", "ai.inlineCompletion", %false, "Grey inline suggestions while you type (Tab accepts) — sends code on every pause")
  defS("AI", "ai.inlineCompletionDelay", %700, "Pause in ms before an inline suggestion is requested")
  defS("AI", "ai.checkSuggestions", %true,
       "Nim: an inline suggestion that uses a name that does not exist here (a proc, a field the type does not " &
       "have) is not shown — ned's engine checks it first")
  defS("AI", "ai.inlineCompletionModel", %"", "Model for inline suggestions (empty = a fast default for the provider)")
  defS("AI", "ai.mcpServers", newJObject(), "MCP servers whose tools the agent may use (each call asks first, " &
       "unless ai.autoApprove is all): {\"github\": {\"command\": \"npx\", \"args\": [\"-y\", " &
       "\"@modelcontextprotocol/server-github\"], \"env\": {\"GITHUB_TOKEN\": \"…\"}}} — palette › AI: MCP servers")
  defS("AI", "ai.fastModel", %"", "A quicker, cheaper model to switch to (the ⚡ button in the assistant, or " &
       "palette › AI: fast / smart model) — e.g. claude-haiku-5-5 or gpt-5-mini")
  defS("AI", "ai.price", newJObject(), "Dollars per million tokens, to show what a chat costs: " &
       "{\"input\": 3, \"output\": 15, \"cacheRead\": 0.3} — empty shows tokens only")
  defS("AI", "ai.warnTokens", %60000, "Ask before sending a request bigger than this many tokens (0 = never ask)")
  defS("AI", "ai.nimContext", %true, "Nim files: send the definitions of the procs and types your code uses, " &
       "found by the built-in engine, so answers know them")
  # ── Languages ──
  defS("Languages", "lsp", newJObject(), "Language servers per language id, e.g. {\"python\": [\"pyright-langserver\", \"--stdio\"]}")
  defS("Languages", "lsp.alsoRun", newJObject(), "More language servers next to the main one — their problems and " &
       "quick fixes are merged with its: {\"python\": [[\"ruff\", \"server\"]], \"*\": [[\"typos-lsp\"]]} (\"*\": every language)")
  defS("Editor", "editor.formatOnType", %false, "Let the language server tidy the line as you type the characters " &
       "it asks for (a closing }, ;, a new line) — servers that offer it: clangd, gopls, rust-analyzer …")
  defS("Languages", "lsp.linters", %true, "Also run a linter's language server when it is installed — Python: ruff, " &
       "Go: golangci-lint-langserver, Markdown: harper-ls — its problems and fixes next to the main server's")
  defS("Languages", "formatters", newJObject(), "Formatter command per language id (stdin → stdout), e.g. {\"nim\": \"nph -\"}")
  defS("Languages", "run", newJObject(), "Run command per language id ($file, $dir, $name), e.g. {\"python\": \"python3 $file\"}")
  defS("Languages", "languages", newJObject(), "Your own languages (or changes to built-in ones): {\"zig\": " &
       "{\"extensions\": [\"zig\"], \"lineComment\": \"//\", \"blockComment\": [\"/*\", \"*/\"], \"keywords\": " &
       "\"fn const var pub return if else while for\", \"types\": \"u8 i32 usize bool\", \"constants\": \"true false null\", " &
       "\"functionWords\": \"fn\", \"indentSize\": 4, \"run\": \"zig run $file\", \"formatter\": \"zig fmt --stdin\", " &
       "\"languageServer\": [\"zls\"]}} — also files, quotes, builtins, classWords, indentAfter, dedent, tabs, name")
  defS("Languages", "snippets", newJObject(),
       "Your snippets per language id (\"*\" = all): {\"nim\": {\"dbg\": \"echo \\\"${1:x} = \\\", $1\"}} — a body may also be a list of lines")
  defS("Settings sync", "sync.repository", %"", "A git repository of yours for Settings sync: push / pull (settings, key " &
       "bindings, snippets, themes, dictionary words — never API keys or tokens). An ssh URL or one your credential helper knows")
  defS("Remote (SSH)", "remote.exclude", %*[".git", "node_modules", ".venv", "venv", "target", "nimcache", "__pycache__",
       ".mypy_cache", ".pytest_cache"], "Folders left on the server when a remote folder is copied over (Remote: open a folder over SSH)")
  defS("Remote (SSH)", "remote.autoSync", %10, "Every this many seconds, files changed on the server (by a build, " &
       "git, another editor) are copied into the local copy; open tabs without unsaved changes reload (0 = only " &
       "after Run, tasks and the assistant's commands)")
  defS("Run", "repl.commands", newJObject(), "REPLs for Send to REPL (Shift+Enter), per language id, over ned's " &
       "own choice (nim: inim --noAutoIndent or nim secret · python: the project's .venv, ipython or python3 · javascript: node · " &
       "typescript: tsx · ruby: irb · lua: lua): {\"python\": \"python3 -q\"}")
  defS("Run", "debug.adapters", newJObject(), "Debuggers (Debug Adapter Protocol) per language id, over ned's own " &
       "choice (python: debugpy · c, cpp, rust: gdb -i dap or lldb-dap · go: delve): {\"python\": {\"command\": " &
       "[\"python3\", \"-m\", \"debugpy.adapter\"], \"launch\": {\"program\": \"$file\", \"cwd\": \"$dir\"}}} — also " &
       "\"build\" (a command run first), \"connect\": true with $port for TCP adapters, \"request\": \"attach\"")
  defS("Run", "debug.inlineValues", %true, "While stopped: the values of the variables a line uses, at its end")
  defS("Run", "run.configs", newJArray(), "Ways to run this project (best in its .ned/settings.json), picked with the ▶ " &
       "menu or Run › Configurations: [{\"name\": \"server\", \"main\": \"src/app.nim\", \"args\": \"--port 8080\", " &
       "\"env\": {\"DEBUG\": \"1\"}, \"defines\": [\"ssl\"], \"mode\": \"release\", \"backend\": \"c\", " &
       "\"cwd\": \".\"}] — or {\"name\": …, \"command\": \"any shell command\"}")
  # ── Keys ──
  defS("Keys", "keys", newJObject(), "Extra key bindings → command palette names, e.g. {\"alt+z\": \"Toggle soft wrap\", \"ctrl+shift+f\": \"Search in project…\"}")
  defS("Keys", "commands", newJObject(),
       "Your own palette commands: {\"Name\": \"shell command\"} or {\"Name\": {\"run\": \"…\", \"output\": " &
       "\"panel|replace|insert|popup|message|terminal\", \"input\": \"selection|file|none\"}}. In the command: " &
       "$file $dir $root $name $ext $line $col $word $selection. Bind keys to them with \"keys\"")

const LegacyKeys = [("tabSize", "editor.tabSize"), ("softWrap", "editor.softWrap"),
                    ("lineNumbers", "editor.lineNumbers"), ("autoComplete", "editor.autoComplete"),
                    ("autoSave", "editor.autoSave"), ("checkOnSave", "nim.checkOnSave"),
                    ("trimTrailingWhitespace", "editor.trimTrailingWhitespace"),
                    ("showWhitespace", "editor.showWhitespace"), ("indentGuides", "editor.indentGuides"),
                    ("scrollOff", "editor.scrollOff"), ("autoHover", "editor.autoHover"),
                    ("hoverDelay", "editor.hoverDelay"), ("stickyScroll", "editor.stickyScroll"),
                    ("rainbowBrackets", "editor.rainbowBrackets"), ("liveDiagnostics", "nim.liveDiagnostics"),
                    ("formatOnSave", "editor.formatOnSave"), ("nimIde", "nim.ide"), ("nimMode", "nim.buildMode"),
                    ("nimBackend", "nim.backend"), ("nimCompiler", "nim.compiler"), ("mouse", "ui.mouse")]

proc jsonText(v: JsonNode, indent: int): string =
  ## compact for scalars and short arrays, pretty (indented) for objects
  if v.kind in {JObject, JArray} and v.len > 0 and ($v).len > 70:
    let p = v.pretty(2)
    var lines = p.splitLines
    for i in 1 ..< lines.len: lines[i] = spaces(indent) & lines[i]
    lines.join("\n")
  else: $v

proc defaultSettingsText(): string =
  ## the full settings file: every option, its default and a comment
  initSettingDefs()
  result = "// ned settings — JSON with comments. Every option is listed with its default value.\n" &
           "// Save this file (Ctrl+S) and the changes apply immediately.\n" &
           "// Palette › \"Settings\" edits the same values with a UI. Delete a line to return to its default.\n{\n"
  var cat = ""
  for i, d in setDefs:
    if d.cat != cat:
      cat = d.cat
      if i > 0: result.add "\n"
      result.add "  // ── " & cat & " " & repeat("─", max(4, 60 - cat.len)) & "\n"
    var doc = d.doc
    if d.opts.len > 0 and d.key != "theme": doc.add "  [" & d.opts.join(" | ") & "]"
    result.add "  // " & doc & "\n"
    if d.key == "theme":
      result.add "  // " & d.opts.join(", ") & "\n"
    result.add "  " & escapeJson(d.key) & ": " & jsonText(d.def, 2) & (if i < setDefs.high: "," else: "") & "\n"
  result.add "}\n"

proc settingNode(key: string): JsonNode =
  if settingsJ == nil or not settingsJ.hasKey(key): nil else: settingsJ[key]

proc sval(key: string): JsonNode =
  result = settingsJ.getOrDefault(key)
  if result.isNil:
    let i = setIndex.getOrDefault(key, -1)
    if i >= 0: result = setDefs[i].def
    else: result = newJNull()

proc sBool(key: string): bool = sval(key).getBool
proc sInt(key: string): int =
  let v = sval(key)
  if v.kind == JFloat: int(v.getFloat) else: v.getInt
proc sStr(key: string): string = sval(key).getStr

var
  nlsAutoMap = newJArray()   # projectMapping ned computed (prepareNimMapping) — one nimsuggest per project
  nlsMain = ""               # the main module it points at
  nlsStatus: JsonNode        # last extension/statusUpdate from nimlangserver (nimsuggest instances …)

proc nimSection(): JsonNode =
  ## the "nim" configuration section nimlangserver asks for
  result = newJObject()
  for k in NlsKeys:
    let v = sval("nim." & k)
    if v.kind == JNull: continue
    if k == "nimsuggestPath" and v.getStr.len == 0:
      # Always name the nimsuggest to use. Otherwise, inside a nimble project, nimlangserver takes the
      # "nimDir" that `nimble dump` reports and runs <nimDir>/nimsuggest — on Termux and with nimble-
      # installed compilers that file often does not exist, and nothing works in nimble projects.
      # The same nimsuggest that works for loose files: the PATH entry (not its symlink target), next to
      # which nimlangserver also finds `nim` for nim check
      let ns = findExe("nimsuggest", followSymlinks = false)
      if ns.len > 0: result[k] = %absolutePath(ns)
      continue
    if k == "projectMapping" and v.kind == JArray and v.len == 0: continue
    result[k] = v
  if not result.hasKey("projectMapping") and nlsAutoMap.len > 0 and sBool("nim.autoProjectMapping"):
    result["projectMapping"] = nlsAutoMap

proc sectionFor(section: string): JsonNode =
  if section == "nim": return nimSection()
  if section.len == 0: return newJNull()
  result = newJObject()
  let pre = section & "."
  for k, v in settingsJ:
    if k.startsWith(pre): result[k[pre.len .. ^1]] = v
  # nothing set: an empty object, not null (vscode-html-language-server stops validating CSS on a null "css")

proc validSetting(d: SetDef, v: JsonNode): bool =
  case d.kind
  of skBool: v.kind == JBool
  of skInt: v.kind in {JInt, JFloat}
  of skStr: v.kind == JString
  of skEnum: v.kind == JString and v.getStr in d.opts
  of skJson: v.kind == d.def.kind or (d.def.kind == JArray and v.kind == JArray)

const SettingSections = ["editor", "ui", "nim", "ai", "terminal", "files", "git", "search", "vim", "zen", "todo"]

proc unknownSettingNote(k: string): string =
  ## a key ned does not know: "did you mean …" for a near miss (wrong case, a typo, the wrong section),
  ## a plain note for keys in ned's own sections, nothing for other tools' keys
  for (old, _) in LegacyKeys:
    if k == old: return ""
  let lk = k.toLowerAscii
  let tail = lk[lk.rfind('.') + 1 .. ^1]
  var best, sameTail = ""
  var bestD = if lk.len >= 6: 3 else: 2
  for d in setDefs:
    let dk = d.key.toLowerAscii
    if dk == lk: return "\"" & k & "\" → \"" & d.key & "\"?"
    let e = editDistanceAscii(lk, dk)
    if e < bestD:
      bestD = e
      best = d.key
    if sameTail.len == 0 and tail.len >= 5 and dk[dk.rfind('.') + 1 .. ^1] == tail: sameTail = d.key
  if best.len == 0: best = sameTail
  if best.len > 0: return "\"" & k & "\" → \"" & best & "\"?"
  let dot = k.find('.')
  if dot > 0 and k[0 ..< dot] in SettingSections: return "\"" & k & "\" is not a setting"
  ""

proc mergeSettingsFile(j: JsonNode) =
  ## file values → settingsJ; accepts legacy flat keys and nested {"nim": {...}} objects
  settingsUser = newJObject()
  var flat = newJObject()
  var notes: seq[string]
  for k, v in j:
    if k in SettingSections and v.kind == JObject:
      for k2, v2 in v: flat[k & "." & k2] = v2
    else: flat[k] = v
  for (old, nw) in LegacyKeys:
    if flat.hasKey(old) and not flat.hasKey(nw): flat[nw] = flat[old]
  if flat.hasKey("nim.ide") and flat["nim.ide"].kind == JString and flat["nim.ide"].getStr in ["auto", "nimsuggest"]:
    flat["nim.ide"] = %"builtin"           # ned 4's values: the built-in engine replaces both
  for k, v in flat:
    let i = setIndex.getOrDefault(k, -1)
    if i < 0:
      if k notin ["editor", "ui"]: settingsUser[k] = v      # unknown keys are kept (other tools' sections)
      let n = unknownSettingNote(k)
      if n.len > 0: notes.add n
      continue
    if validSetting(setDefs[i], v):
      settingsJ[k] = v
      settingsUser[k] = v
    else:
      warn("settings: \"" & k & "\" has an invalid value — using the default")
  if notes.len > 0:
    warn("settings: unknown " & (if notes.len == 1: "key " else: "keys ") & notes.join(", ") &
         " — fix the name in " & configFile())

var stateOverrides = newJObject()   # values remembered in state.json (theme, build mode …) — the file wins

proc applySettings() =
  ## settingsJ → the cfg* globals the rest of the editor reads
  cfgThemeName = sStr("theme")
  cfgIcons = if sBool("ui.accessible"): "ascii" else: sStr("ui.icons")
  cfgTitleBar = sBool("ui.titleBar")
  cfgMenuBar = sBool("ui.menuBar")
  cfgTabBar = sBool("ui.tabBar")
  cfgBreadcrumbs = sBool("ui.breadcrumbs")
  cfgStatusBar = sBool("ui.statusBar")
  cfgTouchBar = sStr("ui.touchBar")
  cfgTouchKeys.setLen(0)
  for x in jitems(sval("ui.touchBarKeys")): cfgTouchKeys.add x.getStr
  cfgAutoImport = sBool("nim.autoImport")
  cfgPostfix = sBool("nim.postfixCompletion")
  cfgShowCopies = sBool("nim.showCopies")
  cfgTestOnSave = sStr("nim.testOnSave")
  cfgDimInactive = sBool("editor.dimInactiveCode")
  cfgCommitChecks = sStr("git.checksBeforeCommit")
  cfgSemColors = sBool("nim.semanticColors")
  cfgRichColors = sBool("nim.richColors")
  cfgMinimap = sStr("ui.minimap")
  cfgScrollbar = sBool("ui.scrollbar")
  cfgTodoHl = sBool("todo.highlight")
  cfgTodoName = sBool("todo.withName")
  setTodoTags(sval("todo.tags"))
  cfgLongPress = sBool("ui.longPressMenu")
  cfgShadows = sBool("ui.shadows")
  let ital = sBool("ui.italics")
  if ital != cfgItalics: prevGrid.setLen(0)      # repaint everything with or without italics
  cfgItalics = ital
  cfgToasts = sBool("ui.toasts")
  cfgMessages = sStr("ui.messages")
  cfgRenamePreview = sBool("editor.renamePreview")
  cfgPersistentUndo = sBool("editor.persistentUndo")
  cfgHoverFx = sBool("ui.hoverEffects")
  cfgPointer = sBool("ui.pointerShapes")
  cfgTooltips = sBool("ui.tooltips")
  cfgMouse = sBool("ui.mouse")
  cfgCursorStyle = sStr("ui.cursorStyle")
  cfgLeftW = sInt("ui.leftDockWidth")
  cfgRightW = sInt("ui.rightDockWidth")
  cfgPanelH = sInt("ui.panelHeight")
  cfgTabSize = max(1, sInt("editor.tabSize"))
  tabW = cfgTabSize
  cfgWrapUser = sBool("editor.softWrap")
  cfgWrap = cfgWrapUser
  cfgLargeMB = max(1, sInt("editor.largeFileSize"))
  cfgLongLine = max(0, sInt("editor.longLineLimit"))
  cfgLineNums = case sStr("editor.lineNumbers")
    of "off": 0
    of "relative": 2
    else: 1
  cfgScrollOff = clamp(sInt("editor.scrollOff"), 0, 20)
  cfgLineHl = sBool("editor.lineHighlight")
  cfgGuides = sBool("editor.indentGuides")
  cfgRulers.setLen(0)
  for r in jitems(settingNode("editor.rulers")):
    let c = if r.kind == JInt: r.getInt elif r.kind == JFloat: int(r.getFloat) else: 0
    if c in 1 .. 2000 and c notin cfgRulers: cfgRulers.add c
  cfgRulers.sort()
  cfgRulerTint = sBool("editor.rulerTint")
  cfgSwatches = sBool("editor.colorSwatches")
  if cfgAccessible != sBool("ui.accessible"): prevGrid.setLen(0)      # repaint everything in the other glyphs
  cfgAccessible = sBool("ui.accessible")
  let sp0 = (cfgSpell, cfgSpellDict, cfgSpellLang)
  cfgSpell = sStr("editor.spellCheck")
  cfgSpellDict = sStr("editor.spellDictionary").expandTilde
  cfgSpellLang = sStr("editor.spellLanguage")
  if sp0[1] != cfgSpellDict or sp0[2] != cfgSpellLang: spellReset()
  cfgInlineValues = sBool("debug.inlineValues")
  applyUserLanguages()
  cfgLinkedEditing = sBool("editor.linkedEditing")
  cfgEmmet = sBool("editor.emmet")
  cfgLspHints = sBool("editor.languageServerHints")
  cfgShowWs = sBool("editor.showWhitespace")
  cfgSticky = sBool("editor.stickyScroll")
  cfgRainbow = sBool("editor.rainbowBrackets")
  block:
    let v = sval("editor.fontLigatures")          # (true / false as in VS Code: font / off)
    cfgLigatures = if v.kind == JBool: (if v.getBool: "font" else: "off")
                   elif v.getStr in ["font", "symbols"]: v.getStr else: "off"
  cfgHighlightOcc = sBool("editor.highlightOccurrences")
  cfgAutoPairs = sBool("editor.autoClosePairs")
  cfgAutoComplete = sBool("editor.autoComplete")
  cfgSnippets = sBool("editor.snippets")
  cfgAutoHover = sBool("editor.autoHover")
  cfgHoverDelay = clamp(sInt("editor.hoverDelay"), 150, 10000)
  cfgInlayHints = sBool("editor.inlayHints")
  cfgCodeLens = sBool("editor.codeLens")
  cfgRefCounts = sBool("nim.referenceCounts")
  cfgAiCheckEdits = sBool("ai.checkEdits")
  cfgFolding = sBool("editor.folding")
  cfgFormatOnSave = sBool("editor.formatOnSave")
  cfgFormatScope = sStr("editor.formatOnSaveScope")
  cfgCsvAlign = sBool("csv.alignColumns")
  cfgFormatOnSaveLangs.setLen(0)
  for x in jitems(settingNode("editor.formatOnSaveLanguages")):
    if x.kind == JString and x.getStr.strip.len > 0: cfgFormatOnSaveLangs.add x.getStr.strip.toLowerAscii
  cfgTrimOnSave = sBool("editor.trimTrailingWhitespace")
  let ecWas = cfgEditorConfig
  cfgEditorConfig = sBool("editor.editorConfig")
  if ecWas != cfgEditorConfig: refreshEditorConfig()
  cfgTrimAll = sBool("editor.trimAllLines")
  cfgAutoSave = sBool("editor.autoSave")
  cfgKeymap = sStr("editor.keymap")
  cfgVim = cfgKeymap == "vim" or (cfgKeymap == "default" and sBool("editor.vimMode"))
  cfgZenWidth = clamp(sInt("zen.width"), 30, 400)
  cfgZenHideNums = sBool("zen.hideLineNumbers")
  cfgZenDim = sBool("zen.dimOthers")
  cfgZenTypewriter = sBool("zen.typewriter")
  cfgZenGit = sBool("zen.gitChanges")
  cfgZenInfo = sBool("zen.showInfo")
  cfgVimEscape = sStr("vim.escapeSequence")
  cfgVimClipboard = sBool("vim.useSystemClipboard")
  cfgVimRelative = sBool("vim.relativeNumbers")
  showHidden = sBool("files.showHidden")
  cfgExclude.setLen(0)
  for x in sval("files.exclude"): cfgExclude.add x.getStr
  cfgScanLimit = max(1000, sInt("files.scanLimit"))
  cfgAutoReload = sBool("files.autoReload")
  cfgRestoreSession = sBool("files.restoreSession")
  cfgUseRg = sBool("search.useRipgrep")
  cfgSearchMax = max(100, sInt("search.maxResults"))
  cfgTermShell = sStr("terminal.shell")
  cfgTermScrollback = clamp(sInt("terminal.scrollback"), 100, 100000)
  cfgTermCwd = sStr("terminal.cwd")
  cfgTermIntegration = sBool("terminal.shellIntegration")
  cfgGitGutter = sBool("git.gutter")
  cfgGitAutoRefresh = sBool("git.autoRefresh")
  cfgBlame = sBool("git.inlineBlame")
  cfgGhostOn = sBool("ai.inlineCompletion")
  cfgNimIde = sStr("nim.ide")
  cfgNimSuggest = sBool("nim.nimsuggest")
  cfgNimFormatter = sStr("nim.formatter")
  cfgNsMaxMB = max(0, sInt("nim.nimsuggestMaxMB"))
  # phones: a lower ceiling unless you chose one
  if not settingsUser.hasKey("nim.nimsuggestMaxMB") and getEnv("PREFIX").contains("com.termux"): cfgNsMaxMB = 800
  cfgNsIdleMin = max(0, sInt("nim.nimsuggestIdleMinutes"))
  cfgCompDocs = sBool("editor.completionDocs")
  cfgNimMode = sStr("nim.buildMode")
  cfgNimTarget = sStr("nim.backend")
  cfgNimCompiler = sStr("nim.compiler")
  block:
    # code inside strings: which names mean which language (and emit's language follows the backend)
    var m = initTable[string, string]()
    let ej = settingNode("nim.embeddedLanguages")
    if ej != nil and ej.kind == JObject:
      for k, v in ej:
        if v.kind == JString and k.len > 0: m[k] = v.getStr
    let sig = $m & "|" & cfgNimTarget
    if sig != embedSig:
      embedSig = sig
      cfgEmbedded = m
      for b in bufs:
        if b.lang != nil and b.lang.mode in {lmNim, lmMarkdown, lmNimf}: b.hlValid = 0
  cfgLiveCheck = sBool("nim.liveDiagnostics")
  cfgCheckOnSave = sBool("nim.checkOnSave")
  cfgFolderTrust = sStr("security.folderTrust")
  cfgCheckWrappers = sBool("nim.checkWrappers")
  cfgEmitClangd = sBool("nim.emitClangd")
  cfgFormatEmitC = sBool("nim.formatEmitC")
  cfgFormatVerify = sBool("nim.format.verify")
  cfgEngineChecks = sBool("nim.engineChecks")
  cfgCompilerAnswers = sBool("nim.compilerAnswers")
  cfgCSigHints = sBool("nim.cSignatureHints")
  cfgParamHints = sStr("nim.parameterHints")
  cfgCEngine = sStr("c.engine")
  if not cfgCSigHints: cSigHints.clear()
  cSigHintsAt.clear()
  cfgPasteFmt = sStr("editor.formatOnPaste")
  FmtWidth = clamp(sInt("nim.format.lineLength"), 40, 240)
  FmtMax = FmtWidth
  FmtParams = parseEnum[FWrap](sStr("nim.format.params"), fwFit)
  FmtArgs = parseEnum[FWrap](sStr("nim.format.arguments"), fwFit)
  FmtColl = parseEnum[FWrap](sStr("nim.format.collections"), fwFit)
  FmtImports = case sStr("nim.format.imports")
               of "sort": 1
               of "merge": 2
               else: 0
  FmtAlign = sBool("nim.format.align")
  FmtReflow = sBool("nim.format.reflowDocComments")
  FmtBlank = clamp(sInt("nim.format.maxBlankLines"), 1, 3)
  cfgNimFlags = sStr("nim.extraFlags")
  cfgNimTestFlags = sStr("nim.testFlags")
  cfgAiProvider = sStr("ai.provider")
  cfgAiModel = sStr("ai.model")
  cfgAiKey = sStr("ai.apiKey")
  cfgAiKeyEnv = sStr("ai.apiKeyEnv")
  cfgAiBase = sStr("ai.baseUrl")
  cfgAiMaxTokens = clamp(sInt("ai.maxTokens"), 256, 200000)
  cfgAiTemp = sInt("ai.temperature")
  cfgAiAgent = sBool("ai.agent")
  cfgAiApprove = sStr("ai.autoApprove")
  cfgAiMaxSteps = clamp(sInt("ai.maxSteps"), 1, 200)
  cfgAiIncludeFile = sBool("ai.includeFile")
  cfgAiFastModel = sStr("ai.fastModel")
  cfgAiWarnTokens = sInt("ai.warnTokens")
  cfgAiNimContext = sBool("ai.nimContext")
  cfgAiSystem = sStr("ai.systemPrompt")
  cfgUserLsp.clear()
  for k, v in sval("lsp"):
    var cmd: seq[string]
    if v.kind == JArray:
      for x in v: cmd.add x.getStr
    elif v.kind == JString: cmd = v.getStr.splitWhitespace
    if cmd.len > 0: cfgUserLsp[k] = cmd
  cfgLspAlso.clear()
  for k, v in sval("lsp.alsoRun"):
    var cmds: seq[seq[string]]
    if v.kind == JArray:
      for c in v:
        var cmd: seq[string]
        if c.kind == JArray:
          for x in c: cmd.add x.getStr
        elif c.kind == JString: cmd = c.getStr.splitWhitespace
        if cmd.len > 0: cmds.add cmd
    elif v.kind == JString and v.getStr.strip.len > 0: cmds.add v.getStr.splitWhitespace
    if cmds.len > 0: cfgLspAlso[k] = cmds
  cfgLspLinters = sBool("lsp.linters")
  cfgFormatOnType = sBool("editor.formatOnType")
  cfgUserFmt.clear()
  for k, v in sval("formatters"): cfgUserFmt[k] = v.getStr
  cfgUserRun.clear()
  for k, v in sval("run"): cfgUserRun[k] = v.getStr
  cfgUserSnippets.setLen(0)
  for lang, defs in sval("snippets"):
    if defs.kind != JObject: continue
    for key, v in defs:
      var body, desc = ""
      case v.kind
      of JString: body = v.getStr
      of JArray:
        var ls: seq[string]
        for x in v: ls.add x.getStr
        body = ls.join("\n")
      of JObject:
        desc = v{"description"}.getStr
        let bd = v{"body"}
        if bd != nil and bd.kind == JArray:
          var ls: seq[string]
          for x in bd: ls.add x.getStr
          body = ls.join("\n")
        elif bd != nil: body = bd.getStr
      else: discard
      if body.len > 0: cfgUserSnippets.add (lang, key, (if desc.len > 0: desc else: "your snippet"), body)
  cfgKeys.clear()
  for k, v in sval("keys"): cfgKeys[k.toLowerAscii.replace(" ", "")] = v.getStr

proc projectSettingsFile(): string = rootDir / ".ned" / "settings.json"

var
  trustedDirs: seq[string]          # folders you trusted: their settings may run programs, ned may run their code
  trustAsked: HashSet[string]       # folders this session already said are not trusted

proc trustKey(d: string): string =
  ## a folder as trust compares it: absolute, normalised, no trailing /
  result = d
  try: result = absolutePath(d)
  except CatchableError: discard
  result = normalizedPath(result)
  while result.len > 1 and result.endsWith("/"): result.setLen(result.len - 1)

proc nimLibDir(): string

proc folderTrusted(dir: string): bool =
  ## did you trust this folder (or one around it)?
  if dir.len == 0: return false
  let d = trustKey(dir)
  for t in trustedDirs:
    let k = trustKey(t)
    if d == k or d.startsWith(k & "/") or k == "/": return true

proc codeTrusted(dir: string): bool =
  ## may ned run this folder's code — the Nim compiler (config.nims, .nims files and macros run commands), nimble
  ## (a .nimble file is a script), nimsuggest, its tests? Yes with security.folderTrust off, in a folder you trusted
  ## (or one inside it), in the Nim toolchain's library and in installed nimble packages
  if cfgFolderTrust != "ask" or dir.len == 0: return true
  if folderTrusted(dir): return true
  let d = trustKey(dir)
  let lib = nimLibDir()
  if lib.len > 0:
    let k = trustKey(lib)
    if d == k or d.startsWith(k & "/"): return true
  let nb = trustKey(getHomeDir() / ".nimble")
  d.startsWith(nb & "/")

var
  projectSettingKeys: seq[string]   # keys the project file set (settings UI marks them)
  projectSettingsBlocked: seq[string]

var userLangIds: seq[string]           # languages that come from the "languages" setting

proc applyUserLanguages() =
  ## the "languages" setting: new languages (coloured by the generic lexer) or changes to built-in ones
  embedLangCache.clear()
  let j = settingNode("languages")
  for id in userLangIds:                     # the ones from last time go (they may have changed)
    for i in countdown(langs.high, 0):
      if langs[i].id == id: langs.delete(i)
  userLangIds.setLen(0)
  if j == nil or j.kind != JObject: return
  proc words(n: JsonNode): seq[string] =
    if n == nil: return
    if n.kind == JString: return n.getStr.splitWhitespace()
    for x in jitems(n): result.add x.getStr
  for id0, d in j:
    if d.kind != JObject: continue
    let id = id0.toLowerAscii
    var l: Lang = nil
    for x in langs:
      if x.id == id or cmpIgnoreCase(x.name, id0) == 0: l = x
    if l == nil:
      l = Lang(name: d{"name"}.getStr(id0), id: id, mode: lmGeneric, quotes: {'"', '\''}, indentWidth: 2,
               pairs: "()[]{}\"\"''")
      langs.insert(l, max(0, langs.high))       # before "Text"
      userLangIds.add id
    if d{"name"} != nil: l.name = d{"name"}.getStr(l.name)
    for e in words(d{"extensions"}): (let x = e.strip(chars = {'.'}).toLowerAscii; if x notin l.exts: l.exts.add x)
    for f in words(d{"files"}): (if f notin l.files: l.files.add f)
    if d{"lineComment"} != nil: l.lineComment = d{"lineComment"}.getStr
    let bc = words(d{"blockComment"})
    if bc.len == 2: (l.blockStart = bc[0]; l.blockEnd = bc[1])
    if d{"quotes"} != nil:
      l.quotes = {}
      for c in d{"quotes"}.getStr: l.quotes.incl c
    for w in words(d{"keywords"}): l.keywords.incl w
    for w in words(d{"types"}): l.types.incl w
    for w in words(d{"constants"}): l.consts.incl w
    for w in words(d{"builtins"}): l.builtins.incl w
    for w in words(d{"functionWords"}): l.defWords.incl w
    for w in words(d{"classWords"}): l.classWords.incl w
    for w in words(d{"indentAfter"}):
      if w.len == 1 and w[0] in {'{', '(', '[', ':', '='}: l.indentChars.incl w[0]
      elif w notin l.indentWords: l.indentWords.add w
    if d{"dedent"} != nil:
      for c in d{"dedent"}.getStr: l.dedentChars.incl c
    if d{"indentSize"} != nil: l.indentWidth = max(1, d{"indentSize"}.getInt(l.indentWidth))
    if d{"tabs"} != nil: l.useTabs = d{"tabs"}.getBool
    if d{"run"} != nil: l.run = d{"run"}.getStr
    if d{"formatter"} != nil: l.fmt = @[d{"formatter"}.getStr]
    let ls = words(d{"languageServer"})
    if ls.len > 0: l.lsp = @[ls]
    if d{"pairs"} != nil: l.pairs = d{"pairs"}.getStr
  # open files of these languages: coloured again
  for b in bufs:
    if b.path.len == 0: continue
    let nl = detectLang(b.path, b.lines[0])
    if nl != b.lang and (nl.id in userLangIds or b.lang.id in userLangIds or b.lang.id == "plaintext"):
      b.lang = nl
      b.hlValid = 0

proc riskyProjectKey(k: string): bool =
  ## settings that start programs or send code somewhere: a cloned repository must not set them
  ## until you trust the folder
  k in ["lsp", "lsp.alsoRun", "formatters", "run", "run.configs", "terminal.shell", "nim.nimsuggestPath", "nim.ide", "keys", "commands",
        "languages", "debug.adapters", "repl.commands", "sync.repository", "editor.spellDictionary", "editor.keymap"] or
    k.startsWith("ai.")

proc mergeProjectSettings(j: JsonNode) =
  projectSettingKeys.setLen(0)
  projectSettingsBlocked.setLen(0)
  var flat = newJObject()
  for k, v in j:
    if k in SettingSections and v.kind == JObject:
      for k2, v2 in v: flat[k & "." & k2] = v2
    else: flat[k] = v
  let trusted = folderTrusted(rootDir)
  var notes: seq[string]
  for k, v in flat:
    let i = setIndex.getOrDefault(k, -1)
    if i < 0:
      let n = unknownSettingNote(k)
      if n.len > 0: notes.add n
      continue
    if not validSetting(setDefs[i], v):
      notes.add "\"" & k & "\" has an invalid value"
      continue
    if riskyProjectKey(k) and not trusted:
      projectSettingsBlocked.add k
      continue
    settingsJ[k] = v
    projectSettingKeys.add k
  if notes.len > 0:
    warn("project settings: " & notes.join(", ") & " — in " & projectSettingsFile())

proc loadConfig() =
  initSettingDefs()
  settingsJ = newJObject()
  for d in setDefs: settingsJ[d.key] = d.def
  for k, v in stateOverrides: settingsJ[k] = v
  let p = configFile()
  if fileExists(p):
    try:
      let j = parseFile(p)
      if j.kind == JObject: mergeSettingsFile(j)
    except CatchableError as e:
      warn("settings file: " & e.msg)
  # project settings (.ned/settings.json in the folder) override the user's for this folder
  let pp = projectSettingsFile()
  projectSettingKeys.setLen(0)
  projectSettingsBlocked.setLen(0)
  if rootDir.len > 0 and fileExists(pp):
    try:
      let j = parseFile(pp)
      if j.kind == JObject: mergeProjectSettings(j)
    except CatchableError as e:
      warn("project settings: " & e.msg)
  applySettings()

proc jsonValueEnd(s: string, i0: int): int =
  var i = i0
  while i < s.len and s[i] in Whitespace: inc i
  if i >= s.len: return i
  case s[i]
  of '"':
    inc i
    while i < s.len and s[i] != '"':
      if s[i] == '\\': inc i
      inc i
    return min(s.len, i + 1)
  of '{', '[':
    var depth = 0
    while i < s.len:
      case s[i]
      of '"':
        inc i
        while i < s.len and s[i] != '"':
          if s[i] == '\\': inc i
          inc i
      of '{', '[': inc depth
      of '}', ']':
        dec depth
        if depth == 0: return i + 1
      of '/':
        if i + 1 < s.len and s[i + 1] == '/':
          while i < s.len and s[i] != '\n': inc i
        elif i + 1 < s.len and s[i + 1] == '*':
          let e = s.find("*/", i + 2)
          i = if e < 0: s.len else: e + 1
      else: discard
      inc i
    return i
  else:
    while i < s.len and s[i] notin {',', '}', ']', '\n', '\r', '/'}: inc i
    while i > i0 and s[i - 1] in {' ', '\t'}: dec i
    return i

proc updateSettingsText(text, key: string, val: JsonNode): string =
  ## replace one value in the settings file, keeping every comment and the layout
  let needle = escapeJson(key)
  var i = text.find(needle)
  while i >= 0:
    var ls = i
    while ls > 0 and text[ls - 1] notin {'\n', '\r'}: dec ls
    let before = text[ls ..< i].strip
    var j = i + needle.len
    while j < text.len and text[j] in {' ', '\t'}: inc j
    if (before.len == 0 or before == "{" or before.endsWith(",")) and j < text.len and text[j] == ':':
      let vs = j + 1
      let ve = jsonValueEnd(text, vs)
      return text[0 ..< vs] & " " & jsonText(val, 2) & text[ve .. ^1]
    i = text.find(needle, i + 1)
  # not present yet: add it as the first entry of the root object
  let b = text.find('{')
  if b < 0: return "{\n  " & needle & ": " & jsonText(val, 2) & "\n}\n"
  let rest = text[b + 1 .. ^1]
  text[0 .. b] & "\n  " & needle & ": " & jsonText(val, 2) & "," &
    (if rest.len > 0 and rest[0] notin {'\n', '\r'}: "\n  " else: "") & rest

proc lspConfigChanged()
proc reloadBuffer(b: Buffer)

proc restartLangServer(langId: string)
proc nsShutdown()

proc refreshUserCommands()

proc reloadSettings(fromFile = true) =
  let oldMouse = cfgMouse
  let oldHover = cfgHoverFx
  let oldMain = sStr("nim.projectFile")
  let oldAuto = sBool("nim.autoProjectMapping")
  let oldMap = $sval("nim.projectMapping")
  let oldBlocked = projectSettingsBlocked
  let oldIde = cfgNimIde
  let oldNs = cfgNimSuggest
  if fromFile: loadConfig() else: applySettings()
  if oldIde != cfgNimIde:
    # switching the Nim engine: stop what the old one ran, start what the new one needs
    nsShutdown()
    lspFailed.excl "nim"
    restartLangServer("nim")
    for b in bufs:
      b.inlays.clear()
      b.inlayAt = -1
      b.outlineAt = -1
      if b.lang.id == "nim" and b.path.len > 0 and b.title.len == 0: lspAttach(b)
    info("Nim: " & (case cfgNimIde
                    of "builtin": "ned's built-in engine"
                    of "nimlangserver": "nimlangserver"
                    else: "code intelligence off"))
  elif oldNs and not cfgNimSuggest: nsShutdown()
  if oldMain != sStr("nim.projectFile") or oldAuto != sBool("nim.autoProjectMapping") or
     oldMap != $sval("nim.projectMapping"):
    restartLangServer("nim")     # the project mapping is decided when the server starts
  if projectSettingsBlocked.len > 0 and projectSettingsBlocked != oldBlocked:
    toast("Project settings ignored until you trust this folder: " & projectSettingsBlocked.join(", "), 2,
          "Trust", proc() = runCmd("Workspace: trust this folder"), 12000)
  applyTheme(cfgThemeName)
  themeFollowers()
  if gRaw and (oldMouse != cfgMouse or oldHover != cfgHoverFx): setMouseMode()
  if gRaw: applyCursorStyle()
  lspConfigChanged()
  refreshUserCommands()
  for b in bufs: b.lastChange = -1
  needRender = true

proc setSetting(key: string, val: JsonNode) =
  ## change one setting: applies it now and writes it into the settings file (comments preserved)
  initSettingDefs()
  settingsJ[key] = val
  settingsUser[key] = val
  let p = configFile()
  try:
    let text = if fileExists(p): readFile(p) else: defaultSettingsText()
    createDir(parentDir(p))
    writeFileSafe(p, updateSettingsText(text, key, val))
    for b in bufs:
      if b.path == p and not b.dirty: reloadBuffer(b)
  except CatchableError as e:
    warn("Could not write settings: " & e.msg)
  reloadSettings(false)

proc resetSettings() =
  ## every setting (key bindings included) back to its default; the old file stays next to it as a backup
  askConfirm("Reset ALL settings (and key bindings) to their defaults? Your settings file is kept as a backup. " &
             "(y)es (c)ancel", proc(c: char) =
    if c != 'y': return
    let p = configFile()
    var backup = ""
    try:
      createDir(parentDir(p))
      if fileExists(p):
        backup = p & ".bak-" & now().format("yyyyMMdd-HHmmss")
        copyFile(p, backup)
      writeFileSafe(p, defaultSettingsText())
    except CatchableError as e:
      error("Could not reset settings: " & e.msg)
      return
    for b in bufs:
      if b.path == p and not b.dirty: reloadBuffer(b)
    reloadSettings(true)
    info("Settings reset to defaults" & (if backup.len > 0: " — your old file is " & backup.extractFilename else: "")))

proc setProjectSetting(key: string, val: JsonNode) =
  ## change one setting for this folder only (.ned/settings.json, comments preserved)
  initSettingDefs()
  let p = projectSettingsFile()
  try:
    let text = if fileExists(p): readFile(p)
               else: "// ned project settings: they override your settings inside this folder.\n{\n}\n"
    createDir(parentDir(p))
    writeFileSafe(p, updateSettingsText(text, key, val))
    for b in bufs:
      if b.path == p and not b.dirty: reloadBuffer(b)
  except CatchableError as e:
    warn("Could not write project settings: " & e.msg)
  reloadSettings(true)

proc toggleSetting(key, label: string) =
  setSetting(key, %(not sBool(key)))
  info(label & (if sBool(key): " on" else: " off"))

proc rulerList(): string =
  for i, c in cfgRulers: result.add (if i > 0: ", " else: "") & $c

proc toggleRulers() =
  ## View › Rulers: hide or show them; with none set yet, one at column 80
  if cfgRulers.len == 0:
    rulersHidden = false
    setSetting("editor.rulers", %[80])
    info("Ruler at column 80 — other columns: settings › editor.rulers, e.g. [80, 120]")
  else:
    rulersHidden = not rulersHidden
    info(if rulersHidden: "Rulers hidden (View › Editor › Rulers shows them again)"
         else: "Rulers at column " & rulerList())
