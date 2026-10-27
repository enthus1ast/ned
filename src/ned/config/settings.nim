# ════════════════════════════════════════════════════════════════════════════
#  Config & persistent state
# ════════════════════════════════════════════════════════════════════════════


proc configDir(): string = getEnv("XDG_CONFIG_HOME", getHomeDir() / ".config") / AppName
proc configFile(): string = configDir() / "config.json"
proc spellUserFile(): string = configDir() / "words.txt"     # your own dictionary words (spell check)
proc stateFile(): string = getEnv("XDG_STATE_HOME", getHomeDir() / ".local" / "state") / AppName / "state.json"
proc tmpDir(): string =
  when defined(windows): return getTempDir().strip(leading = false, chars = {'/', '\\'})   # (%TEMP%: the user's own)
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
  defS("Appearance", "theme.trueBlack", %false, "A dark theme on true black — for an OLED screen, whose black pixels " &
       "are off: the editor and its bars black, popups and the current line a little lifted; the text and the syntax " &
       "keep the theme's colours")
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
  defS("Appearance", "ui.touchBarKeys", %["esc", "tab", "unindent", "left", "down", "up", "right", "undo", "redo", "save",
                                          "find", "palette"],
       "The touch bar's keys, in order: esc tab indent unindent enter left right up down home end pgup pgdn undo redo save find " &
       "palette copy cut paste, a key like \"ctrl+p\" or \"alt+r\", or \"Label=command\" for any palette command " &
       "(e.g. \"Run=Run file\")")
  defS("Appearance", "ui.batterySaver", %"auto",
       "Save the battery: no cursor glide, the compiler's check on save rather than while you type, no AI " &
       "completion as you type, and ned wakes up less often when you are not typing — auto = while the device " &
       "runs on its battery (as the system says; a tap on the leaf in the status bar turns it on or off)",
       @["auto", "on", "off"])
  defS("Appearance", "ui.bigTargets", %"auto",
       "Lists (Open file, the palette, Telescope …) with rows twice as tall, easier to tap: auto = while the touch " &
       "bar is shown", @["auto", "on", "off"])
  defS("Appearance", "ui.touchBarLanguageKeys",
       %*{"nim": ["▶=Run current file", "✓=Nim: check project", "μ=Nim: expand macro/template at cursor",
                  "?=Nim: why? (where an exception or a side effect comes from)", "⚡=Quick fix / code actions…"]},
       "More touch bar keys while you edit a file of a language, after the others: by language id (nim, python, c …), " &
       "each as in ui.touchBarKeys")
  defS("Appearance", "ui.terminalScroll", %true, "When the text moves up or down, let the terminal move the lines " &
       "it shows and send only the new ones (much less to draw: smoother on Termux and over SSH). Turn it off if a " &
       "terminal draws scrolled text in the wrong place")
  defS("Appearance", "ui.minimap", %"auto", "Code minimap at the right edge ('auto' = when the editor is wide " &
       "and the terminal draws fast enough)",
       @["auto", "on", "off"])
  defS("Appearance", "ui.scrollbar", %true, "Scrollbar with diagnostic marks (click or drag it to scroll)")
  defS("Appearance", "ui.longPressMenu", %true,
       "Touch: press and hold (about half a second, without moving) opens the context menu, like a right click")
  defS("Appearance", "ui.shadows", %true, "Drop shadows under menus, popups and dialogs")
  defS("Appearance", "ui.italics", %false, "Italic comments, hints and placeholders — off by default because " &
       "many terminals and fonts (Termux included) have no italic face")
  defS("Appearance", "ui.toasts", %true, "Pop-up notifications for warnings, errors and finished jobs")
  defS("Appearance", "ui.formButtons", %true, "Lists and prompts as dialogs: OK and Cancel buttons under them (a " &
       "row more), the settings in a window of their own, as in a desktop app — off: Enter and Esc only, and the " &
       "settings as a list")
  defS("Appearance", "ui.dragAndDrop", %true, "Drag and drop with the mouse: a tab onto the other pane or an edge " &
       "(split), a file from the file tree onto the editor (open) or a folder (move), the selected text elsewhere " &
       "(move; hold Ctrl or Alt to copy)")
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
  defS("Appearance", "ui.cursorAnimation", %"glide", "When the cursor jumps — a line up or down, to the next word, " &
       "to a definition — it glides there with a short trail that fades behind it (up to 120 frames a second; only " &
       "the trail's cells are sent). 'off': it jumps at once. Never on a slow terminal", @["glide", "off"])
  defS("Appearance", "ui.cursorAnimationMs", %100, "How long the cursor's glide lasts, in milliseconds (40 to 300)")
  defS("Appearance", "ui.trueColor", %"auto", "24-bit colour ('off' uses the 256-colour palette; 'auto' also asks the " &
       "terminal, so it is right over SSH and in tmux, where COLORTERM is often lost)", @["auto", "on", "off"])
  defS("Appearance", "ui.kittyKeyboard", %"auto", "The kitty keyboard protocol, where the terminal has it (kitty, " &
       "WezTerm, Ghostty, foot, Alacritty, iTerm2 …): Ctrl+Shift+letters can be bound, Ctrl+I is not Tab, Ctrl+Enter " &
       "and Shift+Enter work, Alt+key has no delay", @["auto", "off"])
  defS("Appearance", "ui.graphemes", %"auto", "Emoji sequences — 👨‍👩‍👧, 👍🏽, flags, 1️⃣ — as one character two " &
       "columns wide. 'auto': when the terminal says it joins them (mode 2027: WezTerm, Ghostty, Contour, foot …); " &
       "'on' for one that joins them without saying so; 'off': each emoji apart, as most terminals show them",
       @["auto", "on", "off"])
  defS("Appearance", "ui.undercurl", %"auto", "Errors and warnings get a curly underline in their colour and the " &
       "text keeps its own. 'auto': terminals that draw them (kitty, WezTerm, Ghostty, foot, Alacritty, GNOME " &
       "Terminal, VS Code, tmux …); elsewhere a straight underline, the text in the problem's colour",
       @["auto", "on", "off"])
  defS("Appearance", "ui.terminalTitle", %true, "Show the file and the project in the terminal's title (● when it " &
       "has unsaved changes); the old title comes back when ned quits")
  defS("Appearance", "ui.transparentBackground", %false, "Leave the editor's background to the terminal, so its " &
       "own see-through or blurred window shows through (the theme's other colours stay)")
  defS("Appearance", "ui.jumpHighlight", %true, "After a jump — go to definition, a search result, Ctrl+G, a " &
       "problem — the line you land on lights up for a moment")
  defS("Appearance", "ui.progressBar", %true, "Long jobs — a run or build, formatting a folder, a project search, " &
       "the assistant — fill the status bar as they go (Windows Terminal and Ghostty also show it on the tab)")
  defS("Appearance", "ui.pauseWhenAway", %true, "When the terminal loses the focus, background work for what is on " &
       "the screen (type hints, the engine's checks, AI suggestions) waits until you are back — battery on a phone")
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
  defS("Editor", "editor.pickerPreview", %true, "Open file, Go to symbol and the buffer list show the selected " &
       "file, symbol or buffer beside the list (on a screen 110 columns wide or more)")
  defS("Editor", "editor.nextEdit", %true, "Next-edit suggestions: after you change a name (width → size), the next " &
       "place that still has it shows → size ⇥ — Tab goes there, Tab again makes the same change, Esc says no")
  defS("Editor", "editor.largeFileSize", %16,
       "Large-file mode for files of this many MB or more: no soft wrap, language server, Nim engine, minimap or " &
       "word highlight, so scrolling and typing stay instant (palette › Large file mode turns it off for one file)")
  defS("Editor", "editor.viewerSize", %512,
       "Files bigger than this many MB (512 at most) open in the large-file viewer: read-only, a window of their " &
       "lines read as you scroll, the whole file reached by Go to line and Find (in the background)")
  defS("Editor", "editor.longLineLimit", %10000,
       "Large-file mode also for a file with a line this long — minified JSON/JS, one-line logs (0: never)")
  defS("Editor", "editor.lineNumbers", %"absolute", "Line numbers (Alt+L cycles)", @["absolute", "relative", "off"])
  defS("Editor", "editor.scrollOff", %3, "Lines kept visible above and below the cursor")
  defS("Editor", "editor.lineHighlight", %true, "Highlight the line with the cursor")
  defS("Editor", "editor.indentGuides", %true, "Vertical indentation guides")
  defS("Editor", "editor.rulers", newJArray(), "Vertical lines at these columns, like VS Code's rulers: [80] or " &
       "[80, 120] (best per project, in .ned/settings.json) — or \"lineLength\": where the file's formatter wraps " &
       "(Nim: nim.format.lineLength; an .editorconfig max_line_length; else 80), so it moves with that setting. " &
       "View › Editor › Rulers hides and shows them")
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
  defS("Editor", "editor.continueComments", %true,
       "Enter in a doc comment starts the next line with it: ## (Nim), /// and //! (C, C++, Rust …), * in /** … */")
  defS("Editor", "editor.autoClosePairs", %true, "Type the closing bracket/quote automatically")
  defS("Editor", "editor.autoDedent", %true, "Nim: a closing bracket typed alone on its line goes back to the " &
       "indentation of the line that opened it; of, elif, else, except and finally typed at the start of a line go " &
       "back to the column of their case, if/when or try")
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
       "committed) — in a file git does not have, since you opened it; black, ruff and clang-format are given those " &
       "lines — an old file you touch does not turn into one big diff", @["file", "changed"])
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
  defS("Editor", "editor.saveOnFocusLost", %false, "Save the changed files when the terminal loses the focus — you " &
       "switch to another window or app (terminals that report it: most do)")
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
  defS("Decompiler", "decompiler.tool", %"auto", "What decompiles a function (Nim: decompile this proc, Hex: " &
       "decompile a function): auto — the best installed: radare2 with r2ghidra or r2dec (C), rizin with rz-ghidra, " &
       "RetDec, then a disassembly with the Nim lines it came from (radare2, rizin, objdump, llvm-objdump)",
       @["auto", "r2ghidra", "r2dec", "rz-ghidra", "retdec", "radare2", "rizin", "objdump", "llvm-objdump"])
  defS("Compiler Explorer", "compilerExplorer.options", %"", "Compiler Explorer: the Nim compiler's options for " &
       "the file (-d:release, -d:danger, --mm:arc, --opt:size …) — empty: a debug build, as on godbolt.org")
  defS("Compiler Explorer", "compilerExplorer.cOptions", %"-O2", "Compiler Explorer: the C compiler's options for a " &
       "C or C++ file (-O0, -O2, -O3 -march=native …)")
  defS("Compiler Explorer", "compilerExplorer.compiler", %"auto", "Compiler Explorer: the C compiler — auto: gcc " &
       "(clang on Termux and macOS), else whichever is installed; zig builds for another target",
       @["auto", "gcc", "clang", "zig"])
  defS("Compiler Explorer", "compilerExplorer.target", %"native", "Compiler Explorer: the processor the code is for — " &
       "native, or another one through zig cc (zig installed)", @["native", "x86_64", "arm64", "riscv64", "i386"])
  defS("Compiler Explorer", "compilerExplorer.syntax", %"intel", "Compiler Explorer: x86 assembly in Intel's syntax " &
       "(mov rax, rdi) or AT&T's (movq %rdi, %rax)", @["intel", "att"])
  defS("Compiler Explorer", "compilerExplorer.output", %"asm", "Compiler Explorer: the compiler's assembly (asm), or " &
       "the object file disassembled with objdump (binary, with addresses and the calls' targets)", @["asm", "binary"])
  defS("Compiler Explorer", "compilerExplorer.filterLabels", %true, "Compiler Explorer: leave out labels nothing jumps to")
  defS("Compiler Explorer", "compilerExplorer.filterLibrary", %true, "Compiler Explorer: leave out the functions of " &
       "other files (Nim's runtime, the standard library) — only the file's own code")
  defS("Compiler Explorer", "compilerExplorer.filterDirectives", %true, "Compiler Explorer: leave out the assembler's " &
       "directives (.loc, .cfi_…, sections, debug info) — the data a used label holds stays")
  defS("Compiler Explorer", "compilerExplorer.filterComments", %true, "Compiler Explorer: leave out the compiler's " &
       "comments")
  defS("Compiler Explorer", "compilerExplorer.demangle", %true, "Compiler Explorer: Nim's names as Nim writes them " &
       "(square__example_u3 → square)")
  defS("Compiler Explorer", "compilerExplorer.allProcs", %true, "Compiler Explorer: every proc of a Nim file in the " &
       "assembly, also the ones nothing calls yet (Nim leaves those out of the program) — a generic proc still needs " &
       "a call. The private copy gets a line that names them; your file is not changed")
  defS("Compiler Explorer", "compilerExplorer.execute", %false, "Compiler Explorer: run the program too, its output " &
       "(and exit code) in the Output panel — like godbolt.org's Execution")
  defS("Compiler Explorer", "compilerExplorer.args", %"", "Compiler Explorer: the program's arguments when it runs")
  defS("Compiler Explorer", "compilerExplorer.delay", %600, "Compiler Explorer: how long after you stop typing it " &
       "compiles again (ms)")
  defS("Decompiler", "decompiler.follow", %true, "The decompiled view follows the cursor: into another proc of the " &
       "Nim file, another function of the program in the hex editor")
  defS("Files", "files.encoding", %"auto", "What a file that is not UTF-8 is read as (a BOM says UTF-8 or UTF-16 " &
       "itself): auto = Windows-1252, or an encoding's name (iso-8859-1, iso-8859-15, koi8-r, shift_jis … — other " &
       "than Windows-1252, ISO-8859-1 and UTF-16 through iconv). A file is saved in the encoding it was read in; the " &
       "status bar shows it — click: reopen or save with another")
  defS("Files", "files.hotExit", %true, "Quit without being asked about unsaved edits: they are kept and come " &
       "back, still unsaved, the next time ned opens the folder (the files and untitled tabs). Off: asked to save or " &
       "discard them")
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
  defS("Terminal", "terminal.editorEnv", %true, "In ned's terminal, ned is git's editor — GIT_EDITOR, EDITOR " &
       "and VISUAL, each where you have not set it: `git commit` opens its message in a tab of this ned and waits until you " &
       "close it (`ned FILE` in ned's terminal opens the file here either way; ned --new starts another ned)")
  defS("Terminal", "terminal.cwd", %"project", "Where new terminals start", @["project", "file"])
  defS("Terminal", "terminal.keepRunning", %true, "Terminals keep running when ned quits or its window closes: " &
       "the next ned in the same folder takes them back, with what they showed. Kill terminal ends one; Terminal: " &
       "kept terminals… lists them all. Not on Windows, nor REPLs or a remote folder's terminal")
  defS("Terminal", "terminal.shellIntegration", %true, "bash, zsh and fish mark each command (OSC 133): Ctrl+↑/↓ " &
       "jumps between them, failed ones are marked, and a command's output can be copied or the command run again")
  # ── Git ──
  defS("Git", "git.gutter", %true, "Added/modified/deleted marks next to line numbers")
  defS("Git", "git.autoRefresh", %true, "Refresh the git panel periodically while it is open")
  defS("Git", "git.untrackedFiles", %"folders", "New files in a new folder: folders = the folder as one line (with " &
       "how many files it holds — git does not walk a folder of thousands) · all = every file on its own line",
       @["folders", "all"])
  defS("Git", "git.inlineBlame", %false, "Show who last changed the current line, and when, at its end")
  # ── Nim ──
  defS("Nim", "nim.ide", %"builtin",
       "Code intelligence: builtin = ned's own Nim index (instant, no compiler needed) plus nimsuggest for what only " &
       "the compiler knows · nimlangserver = the language server · off", @["builtin", "nimlangserver", "off"])
  defS("Nim", "nim.semanticColors", %true,
       "Colour names by what they are (procs, types, constants, fields), as the built-in engine knows them — not by " &
       "whether they start with a capital letter. C and C++ get them from ned's C engine (parameters, globals, " &
       "macros, fields, enum constants, types), other languages from their language server")
  defS("Nim", "nim.richColors", %true,
       "With semantic colours: a `var` tinted (a `let` stays plain), the module's own variables in bold, deprecated " &
       "names faded and struck through, cast/addr/unsafeAddr/ptr in the warning colour")
  defS("Nim", "nim.completeCallArguments", %false,
       "Completion of a routine writes its call with the parameters to fill in — area(width, height), Tab to the next " &
       "(as clangd and rust-analyzer do); off: the name only, for command syntax (echo x) and method calls")
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
       "Before a commit: format = the files it takes are formatted (ned's own formatters, on what is staged; only " &
       "with editor.formatOnSave on, for the languages it formats), " &
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
       "common). Not written in your settings or the project's: a file's .editorconfig max_line_length, if it has " &
       "one — in the editor, nedfmt, ned --format and nedls alike")
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
  defS("Nim", "nim.format.alignNimbleFields", %true, "Built-in formatter: the `=` of a .nimble's (or a .nims's) " &
       "package fields that follow each other lined up, as nimble's own template writes them (`version       = " &
       "\"0.1.0\"`); off: fields written `name = value` each stay so, as nph writes them")
  defS("Nim", "nim.format.alignComments", %false, "Built-in formatter: the comments at the end of lines that follow " &
       "each other (`x: int  ## the x`) lined up at one column — the one they share already when there is room, else " &
       "two after the longest line; a line the column would take past nim.format.lineLength keeps its comment " &
       "one space after its code (off: one space each, as nph writes them)")
  defS("Nim", "nim.format.magicTrailingComma", %false, "Built-in formatter: a list you end with a comma before " &
       "its bracket — written one element a line, `f(⏎ a, ⏎ b, ⏎ )`, or on one line, `f(a, b,)` — stays one element " &
       "per line, as black and ruff keep it (off: joined when it fits, as nph does)")
  defS("Nim", "nim.format.normalizeNumbers", %false, "Built-in formatter: number literals written one way — " &
       "0x, 0b, 0o in lower case, hexadecimal digits in upper case (0xFF), e for an exponent (1e10), as ruff does")
  defS("Nim", "nim.format.embedded", %true, "Built-in formatter: the SQL, HTML and JSON in triple-quoted strings " &
       "formatted too (ned's own formatters, at the string's indentation) — the strings ned colours as that language: " &
       "sql\"\"\"…\"\"\", #[sql]#, parseJson(\"\"\"…\"\"\"), a database's exec/getRow…, nim.embeddedLanguages, or " &
       "text that starts with SELECT … or an HTML tag. Off: strings stay exactly as written")
  defS("Nim", "nim.format.docCode", %false, "Built-in formatter: the Nim code in doc comments formatted too — " &
       "```nim fences and .. code-block:: nim blocks in ## comments (ruff's docstring-code-format)")
  defS("Nim", "nim.format.reflowDocComments", %false, "Built-in formatter: a ## doc comment paragraph with a line " &
       "longer than nim.format.lineLength is re-wrapped to fit (lists, code and tables stay as they are)")
  defS("Nim", "nim.format.reflowComments", %false, "Built-in formatter: a paragraph of # comments with a line longer " &
       "than nim.format.lineLength is re-wrapped to fit, as reflowDocComments does for ## — prose only: what reads as " &
       "commented-out code, banners, lists, TODOs and `# ned:` directives stay as they are (nph never re-wraps " &
       "comments)")
  defS("Nim", "nim.format.maxBlankLines", %1, "Built-in formatter: empty lines kept in a row (1–3)")
  defS("Nim", "nim.format.verify", %false, "Built-in formatter: check each result with Nim's own parser as well (the " &
       "formatter checks its tokens and blocks anyway). Needs the compiler sources — choosenim and source builds have " &
       "them, or `nimble install compiler`; ned builds a small checker from them once, in the background")
  defS("C", "c.formatter", %"auto", "What formats C files and the C in a Nim file's emits: auto = clang-format while " &
       "clangd is the C engine (c.engine), else ned's own · clang-format (when installed) · builtin = ned's own (in " &
       "c.format.style)", @["auto", "clang-format", "builtin"])
  defS("C", "c.format.style", %"auto", "ned's own C formatter's style: auto = the project's .clang-format (its keys " &
       "ned knows: IndentWidth, ColumnLimit, BreakBeforeBraces, PointerAlignment, AlignTrailingComments …) when it " &
       "has one, else keep · keep = indentation and spaces, your line breaks kept · or clang-format's presets: " &
       "LLVM, Google, Chromium, Mozilla, WebKit, Microsoft, GNU — and Linux (the kernel's)",
       @["auto", "keep", "LLVM", "Google", "Chromium", "Mozilla", "WebKit", "Microsoft", "GNU", "Linux"])
  defS("C", "c.format.options", newJObject(), "clang-format's keys on top of the style, as a .clang-format writes " &
       "them: {\"ColumnLimit\": 100, \"PointerAlignment\": \"Left\", \"IndentCaseLabels\": true, " &
       "\"AlignConsecutiveMacros\": true, \"BreakBeforeBraces\": \"Linux\"}")
  defS("C", "c.engine", %"auto",
       "What answers in C files: builtin = ned's own engine (completion with struct members, hover with the " &
       "comment above a declaration, F12 through #includes, references, rename, outline, signature help, the C " &
       "compiler's errors while you type — instant, nothing to install) · clangd (more precise with macros and " &
       "C++) · both = ned's answers at once and clangd's errors and fixes · auto = clangd when it is installed, " &
       "else ned's own", @["auto", "builtin", "clangd", "both"])
  defS("C", "c.engineChecks", %*{"unusedIncludes": true, "padding": true, "formats": true},
       "ned's own checks of C files while you type, with no compiler (when ned's engine answers for the file, " &
       "c.engine): unusedIncludes — an #include nothing of which is used (Alt+Enter removes it) · padding — a " &
       "struct that would take less room with its fields ordered by size (Alt+Enter orders them) · formats — " &
       "printf and scanf formats against their arguments (Alt+Enter: the conversion the argument takes). false: " &
       "none of them")
  defS("Nim", "nim.parameterHints", %"literals", "Parameter names shown before the arguments of a call " &
       "(built-in engine, with the inlay hints): literals = before numbers, strings, true/false/nil — draw(width: 10, " &
       "height: 20) · all = before every argument · off", @["literals", "all", "off"])
  defS("Nim", "nim.memoryLayout", %true, "The hover of a type shows its memory layout: each field's offset, size " &
       "and the padding after it, the total size and alignment, as the compiler lays it out here (64-bit; 32-bit on " &
       "i386 and ARM) — only when ned is sure of every field. Alt+Enter on an object reorders its fields when that " &
       "saves bytes")
  defS("Nim", "nim.raisesHints", %false, "After the header of a routine without {.raises.}: what it can raise, as " &
       "ned's engine works it out (its raise statements and the routines it calls, less what its try … except " &
       "catches) — only when it is sure of every call; Defects are not listed. The hover of a routine shows it too")
  defS("Nim", "nim.chainHints", %true, "A call chain written over several lines (each line starting with a dot: " &
       ".filterIt(…) ⏎ .mapIt(…)): the type of what each line gives, after it — from ned's engine, when it is sure")
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
  defS("Nim", "nim.ciNedRepository", %"", "Where a CI workflow made by Nim › add a CI workflow builds ned from, for " &
       "its lint and format check (https://… or git@…; asked the first time)")
  defS("Nim", "nim.toolchain", %"auto", "The Nim this project builds with — for every tool ned starts (nim, nimble, " &
       "nimsuggest, nimlangserver, testament, the terminal): its bin folder goes first on PATH. auto = the nim on " &
       "PATH, unless the project's .nimble asks for a Nim it is not and choosenim or grabnim installed one that is · " &
       "path = the nim on PATH · a version (\"2.0.16\") · a Nim folder. Best set per project (Nim › choose the Nim " &
       "for this project); a project's own setting needs the folder trusted")
  defS("Nim", "nim.liveDiagnostics", %true, "Errors while you type, not only on save")
  defS("Nim", "nim.liveDiagnosticsFrom", %"auto", "What checks the text while you type: the compiler (nim check " &
       "on the unsaved text, after a pause), nimsuggest, or auto: the compiler, unless its check of the file takes " &
       "over 10 s and nimsuggest runs", @["auto", "compiler", "nimsuggest"])
  defS("Nim", "nim.compilerOracle", %true, "With nim.nimsuggest off: what ned's engine cannot work out by reading " &
       "— the type of a let a macro or a `when compiles` makes, which of several overloads a call picks — is asked " &
       "of the compiler after a pause in the typing: one nimsuggest run for the lines around the screen, which then " &
       "quits. The answers are kept (by the text of each line) for the next time; type hints, hover and Go to " &
       "definition use them")
  defS("Nim", "nim.compilerAnswers", %true, "With nim.nimsuggest off: where ned's engine has no answer (a hover, Go to " &
       "definition — names a macro makes, say), ask the compiler once — one nimsuggest run for that question, which " &
       "then quits. Kept until the file changes")
  defS("Nim", "nim.engineChecks", %true, "While you type, ned's own engine checks what it can be sure of, at once " &
       "(before the compiler's check): a field name that is a typo of one the object has, a call with the wrong number " &
       "of arguments, a value neither used nor discarded, a literal of the wrong type, an unused import, code after a " &
       "return, a local never used. The compiler's word wins on a line where both speak")
  defS("Nim", "nim.engineHints", %true, "With nim.engineChecks: hints the compiler does not give — a var nothing " &
       "changes (it can be a let), a parameter a routine never uses, a routine that never sets its result, a proc " &
       "with no side effects (it can be a func)")
  defS("Nim", "nim.minVersion", %"", "The oldest Nim your code must build with: a standard-library name or module newer " &
       "than it is marked (its {.since.}, or the Nim release that added it), except inside a `when` that asks which " &
       "Nim this is. Empty: what the package's .nimble requires (\"nim >= 2.0.0\") · \"off\"")
  defS("Nim", "nim.macroNames", %true, "Names a macro makes (makeProcs(Foo) declaring getFoo): a file's top-level " &
       "macro calls, and those of the project files it imports, are expanded by the compiler once (nim check " &
       "--expandMacro, in the background) and what they declare is known to completion, hover and Go to " &
       "definition. Again only when those calls change")
  defS("Nim", "nim.indexCache", %true, "Keep the engine's reading of the standard library and nimble packages on " &
       "disk (~/.cache/ned/index), so a new session answers at once instead of reading them again. An entry is used " &
       "only for the very text it was made from")
  defS("Nim", "nim.indexCacheProject", %true, "The project's own files in the index cache too, as they are on " &
       "disk: reopening a project of hundreds of files reads them instead of parsing them (a changed file is " &
       "parsed again)")
  defS("Nim", "nim.engineWorker", %true, "The engine's type and parameter hints, its own checks and misspelled " &
       "names worked out by a second ned on another processor core (the engine worker): typing, scrolling and " &
       "opening files never wait for them. Off: worked out by the editor itself, a few ms at a time")
  defS("Nim", "nim.indexMemory", %64, "Megabytes the engine's parsed files may take (0: no limit). Above it the " &
       "files asked about least recently, and not open, are dropped; one is read again when needed (a library file " &
       "from the index cache, in a few ms)")
  defS("Nim", "nim.extraFlags", %"", "Extra flags for nim c/cpp/js when running or building, e.g. \"--mm:orc -d:ssl\"")
  defS("Nim", "nim.testFlags", %"--hints:off", "Flags used by the test explorer when compiling tests")
  defS("Nim", "nim.coverageTestFiles", %false,
       "Test coverage for Nim also counts the test files' own lines (off: only the project's code they test)")
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
  defS("AI", "ai.trimOldResults", %true, "Long tool outputs (a file read, a command's output) of earlier questions are " &
       "sent cut to their start and end — those of the question being answered in full: fewer tokens each step, " &
       "answers sooner. The assistant can run the tool again")
  defS("AI", "ai.inlineCompletion", %false, "Grey inline suggestions while you type (Tab accepts) — sends code on every pause")
  defS("AI", "ai.inlineCompletionDelay", %700, "Pause in ms before an inline suggestion is requested")
  defS("AI", "ai.nextEdit", %false, "Next-edit suggestions from AI: when an edit has no repeat in the file, the quick " &
       "model is asked what edit follows from it (shown as → … ⇥ (AI), Tab takes it) — sends the code around it")
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
  defS("AI", "ai.redactSecrets", %true, "Keep secrets from the AI provider: API keys, tokens, private keys and " &
       "passwords in what is sent (the file, the chat, the agent's reads, inline suggestions) are replaced with " &
       "placeholders such as [REDACTED:api-key#1] — put back where the assistant writes one into a file — and files " &
       "of secrets (.env, *.pem, id_ed25519, what the project's .gitignore keeps out for secrets) are not sent at all")
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
  defS("Languages", "web.engine", %"auto", "ned's own CSS, HTML and SQL — completion (properties and values, " &
       "elements and attributes, your tables and columns), hover and problems (an unknown property, a missing `;`, a " &
       "closing tag that closes the wrong element, a table no CREATE TABLE makes, a query given more values than its " &
       "`?`), in their files and in Nim strings: auto = when no language server does it · on · off",
       @["auto", "on", "off"])
  defS("Plugins", "plugins.enabled", %true, "Run your plugins (~/.config/ned/plugins/<name>/plugin.nims) and, in a " &
       "folder you trust, the project's (.ned/plugins/<name>) — NimScript, all in one `nim e` process; a folder " &
       "with a plugin.nim is a plugin in full Nim, compiled into a program of its own (Plugins dock)")
  defS("Plugins", "plugins.disabled", newJArray(), "Plugins that are off (by name): [\"zig-lite\"]")
  defS("Plugins", "plugins.bundled", newJArray(), "ned's own plugins you turned on (Plugins dock › AVAILABLE, or " &
       "Plugins › Available plugins…), by name: [\"dial\", \"harpoon\"] — they come with ned and update with it")
  defS("Plugins", "plugins.native", %"auto", "Compile the NimScript plugins (nim c, in the background) instead of " &
       "running them with nim e: a faster start, faster calls, less memory. auto: a set of plugins is compiled as " &
       "it starts, for the next start (a plugin you are writing — changed in the last 10 minutes — once it has " &
       "started unchanged) · on: always · off: never (a plugin that uses what only NimScript has stays with nim e)", @["auto", "on", "off"])
  defS("Plugins", "plugins.alone", newJArray(), "NimScript plugins that run in a process of their own (by name): a " &
       "slow or crashing one never holds up the others — [\"big-linter\"] (plugins in full Nim always do)")
  defS("Plugins", "plugins.indexUrl", %"", "A list of plugins to install from (Plugins: browse the plugin list…): " &
       "a URL or a file of JSON — [{\"name\": …, \"url\": \"https://… (git)\", \"description\": …}]")
  defS("AI", "ai.commentCommands", %true, "Comments ending in AI! or AI? (# make this a func AI!): when the file " &
       "is saved, the assistant makes the change an AI! comment asks for — shown side by side, checked by the " &
       "compiler first, to take or leave — and answers an AI? comment in the chat")
  defS("AI", "ai.commentButton", %true, "✦ write it after the comment the cursor is on: the assistant writes the " &
       "code the comment describes (as Alt+Shift+C on a comment does), shown before it is used")
  defS("Plugins", "plugins.checkForUpdates", %true, "Once a day, ask the repositories of your plugins that came from " &
       "git whether they have a newer version (git fetch, in the background): the Plugins dock shows ↑ 1.3.0, and " &
       "Plugins: update… brings it. Plugins: check for updates asks now")
  defS("Plugins", "plugins.pinned", newJObject(), "Plugins kept at the version they are at — updates leave them " &
       "alone: {\"notes\": \"1.2.0\"} (a plugin's menu in the Plugins dock: Pin at …)")
  defS("Plugins", "plugins.sandbox", %true, "Linux: run plugins in a sandbox (Landlock) — they read the project " &
       "and what they need to run, and change files only in their data folder and the project, with no network, " &
       "unless you allowed them more; a plugin you allowed to run programs itself runs as before (needs Linux 5.13 or " &
       "newer: elsewhere plugins run as before)")
  defS("Plugins", "plugins.timeoutMs", %1500, "How long ned waits for a plugin that must answer before it goes on " &
       "(an event before saving, a NimScript formatter, a vim text object)")
  defS("Plugins", "plugins", newJObject(), "Each plugin's own settings: {\"zig-lite\": {\"width\": 80}} — or " &
       "\"plugins.zig-lite.width\": 80 (a plugin reads them with setting(\"width\", 80))")
  defS("Plugins", "plugins.idleStopMinutes", %10, "Stop the plugins' process after this many minutes without a " &
       "call (0: never); it starts again when a plugin is needed. Plugins with timers or events keep it running")
  defS("Languages", "formatters", newJObject(), "Formatter command per language id (stdin → stdout), e.g. {\"nim\": \"nph -\"}")
  defS("Languages", "run", newJObject(), "Run command per language id ($file, $dir, $name), e.g. {\"python\": \"python3 $file\"}")
  defS("Languages", "languages", newJObject(), "Your own languages (or changes to built-in ones): {\"zig\": " &
       "{\"extensions\": [\"zig\"], \"lineComment\": \"//\", \"blockComment\": [\"/*\", \"*/\"], \"keywords\": " &
       "\"fn const var pub return if else while for\", \"types\": \"u8 i32 usize bool\", \"constants\": \"true false null\", " &
       "\"functionWords\": \"fn\", \"indentSize\": 4, \"run\": \"zig run $file\", \"formatter\": \"zig fmt --stdin\", " &
       "\"languageServer\": [\"zls\"]}} — also files, quotes, builtins, classWords, indentAfter, dedent, dedentWords " &
       "(\"end\": a line that becomes it goes one level out), tabs, name, pairs, build, check; and how the text is read: " &
       "nestedComments, tripleQuotes, multilineStrings (a string that goes on below), charLiterals ('a'), capitalTypes " &
       "(a Capitalised word is a type), decorators (@name), docComment (\"///\"), docBlockComment, nameChars (\"?!\": " &
       "characters a name may have)")
  defS("Languages", "snippets", newJObject(),
       "Your snippets per language id (\"*\" = all): {\"nim\": {\"dbg\": \"echo \\\"${1:x} = \\\", $1\"}} — a body may also be a list of lines")
  defS("Settings sync", "sync.repository", %"", "A git repository of yours for Settings sync (settings, key bindings, " &
       "snippets, themes, dictionary words, macros, the list of your plugins — never API keys or tokens). An ssh URL or one " &
       "your credential helper knows")
  defS("Settings sync", "sync.auto", %"off", "Settings sync both ways on its own: off · start (a few seconds after ned " &
       "starts) · quit (when ned quits, a few seconds at most) · both")
  defS("Settings sync", "sync.exclude", newJArray(), "Settings that stay on this device, never synced: " &
       "[\"terminal.shell\", \"ui.mouse\"]")
  defS("Remote (SSH)", "remote.exclude", %*[".git", "node_modules", ".venv", "venv", "target", "nimcache", "__pycache__",
       ".mypy_cache", ".pytest_cache"], "Folders left on the server when a remote folder is copied over (Remote: open a folder over SSH)")
  defS("Remote (SSH)", "remote.languageServers", %"auto", "Where a remote folder's language servers run: auto = on " &
       "the server when it has the server's program (with the packages and toolchain there), else here on the local " &
       "copy · server = only there · here = only on the local copy. Files of the server's that they point to — a " &
       "definition in its library — are fetched to read. With no Nim here, ned's own Nim engine reads the server's " &
       "library (fetched once), except with here", @["auto", "server", "here"])
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
  defS("Editor", "pictures.open", %true, "A .png, .jpg, .gif, .bmp or .webp file opens as a picture (Tab: its bytes, in " &
       "the hex editor; Shift+Tab: the picture again) — else in the hex editor")
  defS("Editor", "pictures.draw", %"auto", "How pictures are drawn: auto (the terminal's own way where it has one — " &
       "kitty, iTerm2, sixel — else in cells) · cells (▀, two pixels a cell: any terminal) · kitty · iterm · sixel")
  defS("Run", "notebook.nim", %"vm", "Notebook (a .nim file's # %% cells, Ctrl+Enter): vm — nim secret, one session " &
       "that keeps the cells' variables, instant, but no C libraries (importc, FFI: std/times' now …) · compiled — each " &
       "run builds and runs the cells up to that one as a program (slower; everything Nim has)")
  defS("Run", "notebook.outputLines", %30, "Notebook: the lines of a cell's output shown under it (the rest: Notebook: " &
       "the cell's whole output)")
  defS("Run", "notebook.timeoutSeconds", %120, "Notebook: a cell that has not finished after this long is stopped " &
       "(its session too: the next run starts a new one)")
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

proc settingsMarkdown(): string =
  ## every setting as Markdown, by category (`ned --doc-settings`: docs/reference/settings.md is made from it)
  initSettingDefs()
  proc cell(s: string): string = s.replace("|", "\\|").replace("\n", " ")
  result = "# Settings reference\n\n" &
           "Every setting ned has, its default and what it does — made by `ned --doc-settings` (do not edit this " &
           "file: change the setting's text in `src/ned/config/settings.nim`). Yours go in " &
           "`~/.config/ned/config.json` (Settings › *Edit settings.json*, or the Settings window), a project's in " &
           "`.ned/settings.json`. `ned --default-settings` prints them all as a settings file.\n"
  var cats: seq[string]
  for d in setDefs:
    if d.cat notin cats: cats.add d.cat
  result.add "\n**Categories:** "
  for i, c in cats:
    var slug = ""                        # (GitHub's anchor for the heading)
    for ch in c.toLowerAscii:
      if ch in {'a'..'z', '0'..'9', '-', '_'}: slug.add ch
      elif ch == ' ': slug.add '-'
    result.add (if i > 0: " · " else: "") & "[" & c & "](#" & slug & ")"
  result.add "\n"
  for c in cats:                         # one section per category, its settings in the order they are defined
    result.add "\n## " & c & "\n\n| Setting | Default | What it does |\n|---|---|---|\n"
    for d in setDefs:
      if d.cat != c: continue
      var doc = d.doc
      if d.opts.len > 0 and d.key notin ["theme", "theme.dark", "theme.light"]:
        doc.add " — one of: " & d.opts.join(", ")
      var def = $d.def
      if def.len > 60: def = def[0 ..< 57] & "…"
      result.add "| `" & d.key & "` | `" & cell(def) & "` | " & cell(doc) & " |\n"

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
  if d.key == "plugins.native" and v.kind == JBool: return true       # (6.19's true/false: on/off)
  if d.key in ["theme", "theme.dark", "theme.light"] and v.kind == JString and themeAlias(v.getStr).len > 0:
    return true                                                       # (a theme 6.30 folded into another)
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
  if k == "plugins" or (k.startsWith("plugins.") and k.count('.') >= 2): return ""   # (a plugin's own settings)
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

var
  projectSettingKeys: seq[string]   # keys the project file set (settings UI marks them)
  projectSettingsBlocked: seq[string]

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
  cfgCallArgs = sBool("nim.completeCallArguments")
  cfgPostfix = sBool("nim.postfixCompletion")
  cfgShowCopies = sBool("nim.showCopies")
  cfgTestOnSave = sStr("nim.testOnSave")
  cfgDimInactive = sBool("editor.dimInactiveCode")
  cfgCommitChecks = sStr("git.checksBeforeCommit")
  cfgSemColors = sBool("nim.semanticColors")
  cfgRichColors = sBool("nim.richColors")
  cfgMinimap = sStr("ui.minimap")
  cfgTermScroll = sBool("ui.terminalScroll")
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
  cfgFormButtons = sBool("ui.formButtons")
  cfgDragDrop = sBool("ui.dragAndDrop")
  cfgMessages = sStr("ui.messages")
  cfgRenamePreview = sBool("editor.renamePreview")
  cfgPersistentUndo = sBool("editor.persistentUndo")
  cfgHoverFx = sBool("ui.hoverEffects")
  cfgPointer = sBool("ui.pointerShapes")
  cfgTooltips = sBool("ui.tooltips")
  cfgMouse = sBool("ui.mouse")
  cfgCursorStyle = sStr("ui.cursorStyle")
  cfgCursorAnim = sStr("ui.cursorAnimation")
  cfgCursorAnimMs = clamp(sInt("ui.cursorAnimationMs"), 40, 300)
  cfgKittyKeys = sStr("ui.kittyKeyboard")
  if cfgKittyKeys == "off" and tcKittyOn:
    writeAll("\e[<u")
    tcKittyOn = false
  cfgGraphemes = sStr("ui.graphemes")
  cfgUndercurl = sStr("ui.undercurl")
  cfgTrueColorSet = sStr("ui.trueColor")
  if gRaw:
    applyGraphemes()
    applyUndercurl()
  cfgTermTitle = sBool("ui.terminalTitle")
  let transp = sBool("ui.transparentBackground")
  if transp != cfgTransparentBg: prevGrid.setLen(0)
  cfgTransparentBg = transp
  cfgJumpHl = sBool("ui.jumpHighlight")
  cfgProgressBar = sBool("ui.progressBar")
  cfgPauseAway = sBool("ui.pauseWhenAway")
  cfgSaveOnBlur = sBool("editor.saveOnFocusLost")
  cfgEditorEnv = sBool("terminal.editorEnv")
  cfgLeftW = sInt("ui.leftDockWidth")
  cfgRightW = sInt("ui.rightDockWidth")
  cfgPanelH = sInt("ui.panelHeight")
  cfgTabSize = max(1, sInt("editor.tabSize"))
  tabW = cfgTabSize
  cfgWrapUser = sBool("editor.softWrap")
  cfgWrap = cfgWrapUser
  cfgLargeMB = max(1, sInt("editor.largeFileSize"))
  cfgViewerMB = clamp(sInt("editor.viewerSize"), 16, 512)
  cfgLongLine = max(0, sInt("editor.longLineLimit"))
  cfgLineNums = case sStr("editor.lineNumbers")
    of "off": 0
    of "relative": 2
    else: 1
  cfgScrollOff = clamp(sInt("editor.scrollOff"), 0, 20)
  cfgLineHl = sBool("editor.lineHighlight")
  cfgGuides = sBool("editor.indentGuides")
  cfgRulers.setLen(0)
  cfgRulerAtLength = false
  for r in jitems(settingNode("editor.rulers")):
    if r.kind == JString and r.getStr.toLowerAscii.replace(" ", "") in ["linelength", "format", "formatter"]:
      cfgRulerAtLength = true
      continue
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
  cfgContinueComments = sBool("editor.continueComments")
  cfgAutoPairs = sBool("editor.autoClosePairs")
  cfgAutoDedent = sBool("editor.autoDedent")
  cfgAutoComplete = sBool("editor.autoComplete")
  cfgSnippets = sBool("editor.snippets")
  cfgAutoHover = sBool("editor.autoHover")
  cfgHoverDelay = clamp(sInt("editor.hoverDelay"), 150, 10000)
  cfgInlayHints = sBool("editor.inlayHints")
  cfgCodeLens = sBool("editor.codeLens")
  cfgRefCounts = sBool("nim.referenceCounts")
  cfgAiCheckEdits = sBool("ai.checkEdits")
  cfgAiTrimOld = sBool("ai.trimOldResults")
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
  cfgTermKeep = sBool("terminal.keepRunning")
  cfgGitGutter = sBool("git.gutter")
  cfgGitAutoRefresh = sBool("git.autoRefresh")
  cfgGitUntrackedAll = sStr("git.untrackedFiles") == "all"
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
  cfgFileEncoding = sStr("files.encoding")
  cfgCheckWrappers = sBool("nim.checkWrappers")
  cfgEmitClangd = sBool("nim.emitClangd")
  cfgFormatEmitC = sBool("nim.formatEmitC")
  cfgFormatVerify = sBool("nim.format.verify")
  cfgEngineChecks = sBool("nim.engineChecks")
  cfgCompilerAnswers = sBool("nim.compilerAnswers")
  cfgOracle = sBool("nim.compilerOracle")
  nxDiskCache = sBool("nim.indexCache")
  nxCacheProject = sBool("nim.indexCacheProject")
  nxIndexBudget = max(0, sInt("nim.indexMemory")) * 1048576
  cfgMacroNames = sBool("nim.macroNames")
  cfgEngineMoreChecks = sBool("nim.engineHints")
  cfgNimMinVersion = sStr("nim.minVersion")
  cfgCSigHints = sBool("nim.cSignatureHints")
  cfgParamHints = sStr("nim.parameterHints")
  nxLayoutOn = sBool("nim.memoryLayout")
  if sBool("nim.chainHints") != cfgChainHints:
    cfgChainHints = sBool("nim.chainHints")
    for b in bufs: b.inlayAt = -1
  if sBool("nim.raisesHints") != cfgRaisesHints:
    cfgRaisesHints = sBool("nim.raisesHints")
    for b in bufs: b.inlayAt = -1             # (the hints again, with or without what routines raise)
  cfgCEngine = sStr("c.engine")
  cfgCFormatter = sStr("c.formatter")
  cfgCStyleName = sStr("c.format.style")
  cfgCStyleOpts = cStyleOptions(sval("c.format.options"))
  block:
    let ec = sval("c.engineChecks")
    cxChecks = if ec.kind == JBool: (ec.getBool, ec.getBool, ec.getBool)
               else: (ec{"unusedIncludes"}.getBool(true), ec{"padding"}.getBool(true), ec{"formats"}.getBool(true))
  if not cfgCSigHints: cSigHints.clear()
  cSigHintsAt.clear()
  cfgPasteFmt = sStr("editor.formatOnPaste")
  FmtWidth = clamp(sInt("nim.format.lineLength"), 40, 240)
  FmtMax = FmtWidth
  cfgFmtWidth = FmtWidth
  cfgFmtWidthSet = settingsUser.hasKey("nim.format.lineLength") or "nim.format.lineLength" in projectSettingKeys
  FmtParams = parseEnum[FWrap](sStr("nim.format.params"), fwFit)
  FmtArgs = parseEnum[FWrap](sStr("nim.format.arguments"), fwFit)
  FmtColl = parseEnum[FWrap](sStr("nim.format.collections"), fwFit)
  FmtImports = case sStr("nim.format.imports")
               of "sort": 1
               of "merge": 2
               else: 0
  FmtAlign = sBool("nim.format.align")
  FmtScriptAlign = sBool("nim.format.alignNimbleFields")
  FmtAlignComments = sBool("nim.format.alignComments")
  FmtMagicComma = sBool("nim.format.magicTrailingComma")
  FmtNumbers = sBool("nim.format.normalizeNumbers")
  FmtDocCode = sBool("nim.format.docCode")
  FmtEmbedded = sBool("nim.format.embedded")
  FmtReflow = sBool("nim.format.reflowDocComments")
  FmtReflowPlain = sBool("nim.format.reflowComments")
  FmtBlank = clamp(sInt("nim.format.maxBlankLines"), 1, 3)
  cfgNimFlags = sStr("nim.extraFlags")
  cfgNimTestFlags = sStr("nim.testFlags")
  cfgCovTestFiles = sBool("nim.coverageTestFiles")
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
  cfgWebEngine = sStr("web.engine")
  cfgPickerPreview = sBool("editor.pickerPreview")
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
  let own = trustKey(configDir())                  # (your own settings folder: your plugins run from it)
  if d == own or d.startsWith(own & "/"): return true
  let tour = trustKey(parentDir(stateFile()) / "tour")   # (the Nim tour's lessons: ned's own, your copies of them)
  if d == tour or d.startsWith(tour & "/"): return true
  let lib = nimLibDir()
  if lib.len > 0:
    let k = trustKey(lib)
    if d == k or d.startsWith(k & "/"): return true
  let nb = trustKey(getHomeDir() / ".nimble")
  d.startsWith(nb & "/")


var userLangIds: seq[string]           # languages that come from the "languages" setting

proc applyUserLanguages() =
  ## the "languages" setting: new languages (coloured by the generic lexer) or changes to built-in ones
  embedLangCache.clear()
  let own = settingNode("languages")
  # (the plugins' languages first, then yours: a field of yours wins over a plugin's)
  var j = newJObject()
  for (_, id, spec) in plugLangSpecs:
    if not j.hasKey(id): j[id] = newJObject()
    for k, v in spec: j[id][k] = v
  if own != nil and own.kind == JObject:
    for id0, d in own:
      let id = id0.toLowerAscii
      if d.kind != JObject: continue
      if not j.hasKey(id): j[id] = newJObject()
      for k, v in d: j[id][k] = v
  for id in userLangIds:                     # the ones from last time go (they may have changed)
    for i in countdown(langs.high, 0):
      if langs[i].id == id: langs.delete(i)
  userLangIds.setLen(0)
  if j.len == 0: return
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
    # (the generic lexer's own choices)
    if d{"nestedComments"} != nil: l.nested = d{"nestedComments"}.getBool
    if d{"tripleQuotes"} != nil: l.triple = d{"tripleQuotes"}.getBool
    if d{"multilineStrings"} != nil: l.multiline = d{"multilineStrings"}.getBool
    if d{"charLiterals"} != nil: l.charLit = d{"charLiterals"}.getBool
    if d{"capitalTypes"} != nil: l.capsTypes = d{"capitalTypes"}.getBool
    if d{"decorators"} != nil: l.decorators = d{"decorators"}.getBool
    if d{"docComment"} != nil: l.docLine = d{"docComment"}.getStr
    let db = words(d{"docBlockComment"})
    if db.len == 2: (l.docBlockStart, l.docBlockEnd) = (db[0], db[1])
    if d{"nameChars"} != nil:
      for c in d{"nameChars"}.getStr:
        if c notin {' ', '\t'}: l.nameChars.incl c
    for w in words(d{"dedentWords"}): (if w notin l.dedentWords: l.dedentWords.add w)
    if d{"build"} != nil: l.build = d{"build"}.getStr
    if d{"check"} != nil: l.check = d{"check"}.getStr
  # open files of these languages: coloured again
  for b in bufs:
    if b.path.len == 0: continue
    let nl = detectLang(b.path, b.lines[0])
    if nl != b.lang and (nl.id in userLangIds or b.lang.id in userLangIds or b.lang.id == "plaintext"):
      b.lang = nl
      b.hlValid = 0

func riskyProjectKey(k: string): bool =
  ## settings that start programs or send code somewhere: a cloned repository must not set them
  ## until you trust the folder
  k in ["lsp", "lsp.alsoRun", "formatters", "run", "run.configs", "terminal.shell", "nim.nimsuggestPath", "nim.ide",
        "nim.toolchain", "nim.ciNedRepository", "keys", "commands",
        "languages", "debug.adapters", "repl.commands", "sync.repository", "editor.spellDictionary", "editor.keymap",
        "plugins.bundled"] or
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

func jsonValueEnd(s: string, i0: int): int =
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
  applyNimToolchain()                # (nim.toolchain, or another project: the Nim every tool uses)
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
  wkSettingsChanged()                # (the engine worker's settings too)
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

proc setSettings(changes: seq[(string, JsonNode)]) =
  ## several settings changed at once (the Settings window's OK): one write of the file, one reload
  if changes.len == 0: return
  initSettingDefs()
  let p = configFile()
  try:
    var text = if fileExists(p): readFile(p) else: defaultSettingsText()
    for (key, val) in changes:
      settingsJ[key] = val
      settingsUser[key] = val
      text = updateSettingsText(text, key, val)
    createDir(parentDir(p))
    writeFileSafe(p, text)
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

proc nimLineLength(path: string): int =
  ## where the built-in formatter wraps a Nim file's lines: nim.format.lineLength when a settings file says it,
  ## else the file's .editorconfig max_line_length, else nim.format.lineLength's default (nph's 88)
  if not cfgFmtWidthSet and cfgEditorConfig and path.len > 0:
    let m = editorConfigMaxLine(path)
    if m > 0: return clamp(m, 40, 240)
  cfgFmtWidth

template withNimLineLength(path: string, body: untyped) =
  ## `body` with the formatter wrapping at the file's line length (nimLineLength) — and as NimScript for a .nims
  ## or .nimble (FmtScript)
  let keepW = FmtWidth
  let keepM = FmtMax
  let keepS = FmtScript
  FmtWidth = nimLineLength(path)
  FmtMax = FmtWidth
  FmtScript = fIsScriptPath(path)
  try:
    body
  finally:
    FmtWidth = keepW
    FmtMax = keepM
    FmtScript = keepS

proc lineLengthFor(b: Buffer): int =
  ## where a file's lines should end: for Nim where its formatter wraps (nimLineLength; nph's 88, nimpretty's 80),
  ## else its .editorconfig max_line_length, else 80
  if b != nil and b.lang != nil and b.lang.mode == lmNim:
    return (case cfgNimFormatter
            of "nph": 88
            of "nimpretty": 80
            else: nimLineLength(b.path))
  if b != nil and b.ecMaxLine > 0: return b.ecMaxLine
  80

proc rulerColumns(b: Buffer): seq[int] =
  ## the columns of a file's rulers (editor.rulers; "lineLength" where its formatter wraps)
  if b != nil and b.ecMaxLine > 0 and not (cfgRulerAtLength and b.lang != nil and b.lang.mode == lmNim):
    return @[b.ecMaxLine]                                      # (.editorconfig: the project's limit)
  result = cfgRulers
  if cfgRulerAtLength:
    let c = lineLengthFor(b)
    if c notin result: result.add c
    result.sort()

proc rulersSet(): bool = cfgRulers.len > 0 or cfgRulerAtLength

proc rulerList(): string =
  for i, c in rulerColumns(buf()): result.add (if i > 0: ", " else: "") & $c
  if cfgRulerAtLength: result.add " (the line length)"

proc toggleRulers() =
  ## View › Rulers: hide or show them; with none set yet, one where the file's formatter wraps
  if not rulersSet():
    rulersHidden = false
    setSetting("editor.rulers", %["lineLength"])
    info("Ruler at the line length (" & $lineLengthFor(buf()) & ": nim.format.lineLength in Nim files) — " &
         "other columns: settings › editor.rulers, e.g. [80, 120]")
  else:
    rulersHidden = not rulersHidden
    info(if rulersHidden: "Rulers hidden (View › Editor › Rulers shows them again)"
         else: "Rulers at column " & rulerList())
