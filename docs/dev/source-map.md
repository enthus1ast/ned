# The source, file by file

Every source file of ned with what it is — the first comment of each file, so a file that says what it is well is described well here. *include N* is the file's place in `src/ned.nim`, which `include`s most files in order (each sees what the ones before it declare: a proc used earlier needs a forward declaration in [`app/forward.nim`](../../src/ned/app/forward.nim)); *module* is a part compiled on its own and imported. The rest belong to `nedls`, `nedfmt` or the plugin library, or are taken in by the module they are part of. [Architecture](architecture.md) says how the parts fit; this page is where to look for one.

Made by `python3 tests/docs/sourcemap.py` from the sources (CI checks it is up to date) — run it after adding, moving or renaming a file.

| program | file | |
|---|---|---|
| `ned` | [`src/ned.nim`](../../src/ned.nim) | ned — a fast, safe code editor and Nim IDE for Termux, Linux and macOS (Windows: WSL), in Nim (standard library only) |
| `nedls` | [`src/nedls.nim`](../../src/nedls.nim) | nedls — ned's built-in engines as a language server (LSP over stdio), for any editor: VS Code, Neovim, Helix, Zed, Emacs, Kate, Sublime … instead of nimlangserver or … |
| `nedfmt` | [`src/nedfmt.nim`](../../src/nedfmt.nim) | nedfmt — ned's formatters as a command of their own: Nim in nph's style (checked: a file it is not sure of is left alone), JSON, Markdown tables, CSS/SCSS, C, YAML, … |

## ai

The AI assistant: providers, chat, the agent and its tools, MCP, inline suggestions.

| file | | what it is |
|---|---|---|
| [`ai/streamparts.nim`](../../src/ned/ai/streamparts.nim) | module | What a model's reply sends in pieces, read as it comes: the thinking some models write into the answer itself (Qwen, QwQ, DeepSeek R1, GLM… between `<think>` and … |
| [`ai/assistant.nim`](../../src/ned/ai/assistant.nim) | include 148 | AI assistant: streaming chat + agent tools (Anthropic, OpenAI-compatible, Ollama) via curl |
| [`ai/mcp.nim`](../../src/ned/ai/mcp.nim) | include 149 | MCP: Model Context Protocol servers give the agent more tools ("ai.mcpServers") |
| [`ai/agenttools.nim`](../../src/ned/ai/agenttools.nim) | include 150 | the assistant's tools: which calls need the user's approval, the tools that read, search, list, edit and write files and report problems, the checkpoints AI: undo … |
| [`ai/requests.nim`](../../src/ned/ai/requests.nim) | include 151 | the AI's requests: the system prompt, the code's context (the definitions it uses, the open file), each provider's request body |
| [`ai/endpoints.nim`](../../src/ned/ai/endpoints.nim) | include 152 | what an endpoint accepts differs per model |
| [`ai/inlineedit.nim`](../../src/ned/ai/inlineedit.nim) | include 153 | inline edit (selection → AI → replacement) |
| [`ai/chats.nim`](../../src/ned/ai/chats.nim) | include 154 | ned 4: saved chats, change diffs, slash commands, @mentions, usage, one-shot requests |
| [`ai/context.nim`](../../src/ned/ai/context.nim) | include 155 | the change an edit/write call would make, as a unified diff |
| [`ai/oneshot.nim`](../../src/ned/ai/oneshot.nim) | include 156 | one-shot requests (commit messages, …): the reply goes to a callback, not the chat |
| [`ai/plan.nim`](../../src/ned/ai/plan.nim) | include 157 | AI: plan first, then do it — the assistant looks at the code (reading only) and answers with a numbered plan |
| [`ai/offline.nim`](../../src/ned/ai/offline.nim) | include 158 | AI on this device, without the internet: Ollama (or llama.cpp's llama-server) found or installed, started, a model that fits the memory downloaded, ned set to use it … |
| [`ai/suggestions.nim`](../../src/ned/ai/suggestions.nim) | include 159 | inline AI suggestions (opt-in: ai.inlineCompletion) — grey text after the cursor, Tab accepts |
| [`ai/chatview.nim`](../../src/ned/ai/chatview.nim) | include 161 | the AI chat drawn: its Markdown, code blocks with Insert and Apply, tool calls in short, scrolling |
| [`ai/review.nim`](../../src/ned/ai/review.nim) | include 257 | the assistant's changes of one run, file by file, as side-by-side diffs (r undoes one change) |
| [`ai/comments.nim`](../../src/ned/ai/comments.nim) | include 284 | code from comments (as in Zed and Aider): a comment says what to write, the assistant writes it — · Alt+Shift+C on a comment (nothing selected), or the ✦ after it: … |

## app

The program as a whole: start, the main loop, the command list, input, updates, the battery, the tour.

| file | | what it is |
|---|---|---|
| [`app/releasecheck.nim`](../../src/ned/app/releasecheck.nim) | module | Checking a release before it is installed |
| [`app/forward.nim`](../../src/ned/app/forward.nim) | include 44 | Forward declarations: procs used before the file that defines them is included (look here before adding one: a second is an error) |
| [`app/crash.nim`](../../src/ned/app/crash.nim) | include 49 | (6.45) when ned itself fails — a fault the program cannot go on from (SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGABRT: a bug, a stack too deep, memory gone bad) — the … |
| [`app/commands.nim`](../../src/ned/app/commands.nim) | include 189 | What many commands do: quitting, the docks and the panel, tabs, sorting and joining lines, indent, restarting language servers |
| [`app/input.nim`](../../src/ned/app/input.nim) | include 190 | Keys and clicks sent where they belong — the editor, the file tree, the panel — and positions past inlay hints |
| [`app/keyboard.nim`](../../src/ned/app/keyboard.nim) | include 270 | Keys routed: ned's global keys, the terminal's, the editor's, your own bindings, key names, conflicts |
| [`app/setupcheck.nim`](../../src/ned/app/setupcheck.nim) | include 271 | Setup check (Help ▸ Check setup, ned --check) and info for bug reports |
| [`app/perfreport.nim`](../../src/ned/app/perfreport.nim) | include 272 | Help › Performance: how fast frames are made, how much each sends to the terminal and how long the terminal takes to draw it, what runs in the background, the memory … |
| [`app/usercommands.nim`](../../src/ned/app/usercommands.nim) | include 289 | your own commands (the "commands" setting): shell commands in the palette, with placeholders |
| [`app/lint.nim`](../../src/ned/app/lint.nim) | include 290 | ned --lint (and nedls --lint): the engine's own checks over files or folders, without the compiler — a misspelled name, a field that is not there, a wrong number of … |
| [`app/commandlist.nim`](../../src/ned/app/commandlist.nim) | include 297 | the list of the command palette: every command with its name and the key (or the words) shown beside it, and the Markdown page of them that `ned --doc-commands` writes |
| [`app/control.nim`](../../src/ned/app/control.nim) | include 298 | Remote control: a socket only you can reach (in ned's private folder, 0600), so that the ned that is running can be told what to do — · `ned FILE` typed in ned's own … |
| [`app/update.nim`](../../src/ned/app/update.nim) | include 300 | ned --update: the newest release (GitHub's newest release, else its newest version tag), installed the way this ned was — built with nimble, a checkout built in … |
| [`app/battery.nim`](../../src/ned/app/battery.nim) | include 301 | (6.32) battery saver (ui.batterySaver): on a battery, ned does less — no cursor glide, the compiler checks on save rather than while you type, no AI completion as you … |
| [`app/lowmem.nim`](../../src/ned/app/lowmem.nim) | include 302 | (6.37) short of memory (ui.lowMemory): when the system has little left to give — on a phone, Android then closes apps, Termux among them, with ned and its terminal — … |
| [`app/main.nim`](../../src/ned/app/main.nim) | include 305 | The main loop (input, jobs, language servers, timers, drawing) and the command line: --help, --bench, --update, files formatted, the remote socket |

## c

Ned's own C and C++ engine, C in Nim (emit, wrappers), clangd.

| file | | what it is |
|---|---|---|
| [`c/cindex.nim`](../../src/ned/c/cindex.nim) | module | ned's own C engine: an index of C files and the headers they include — functions, structs and their members, unions, enums, typedefs, macros, globals, a function's … |
| [`c/cnim.nim`](../../src/ned/c/cnim.nim) | module | a C header as Nim: its functions, structs, unions, enums, typedefs, #define constants and globals as Nim declarations that import them (importc, header) — from what … |
| [`c/headers.nim`](../../src/ned/c/headers.nim) | include 223 | C interop: the C side of importc wrappers — headers, prototypes, wrapper checks, c2nim, clangd |
| [`c/cdoctext.nim`](../../src/ned/c/cdoctext.nim) | include 224 | the documentation of a C declaration (the comment above it in its header or {.emit.}), and its short form |
| [`c/nimside.nim`](../../src/ned/c/nimside.nim) | include 225 | the Nim side: declarations that import C |
| [`c/types.nim`](../../src/ned/c/types.nim) | include 226 | C types and their Nim counterparts, for wrappers: an importc declaration checked against its C one |
| [`c/navigation.nim`](../../src/ned/c/navigation.nim) | include 227 | go to definition and hover from Nim to C: an importc proc's C declaration and its docs |
| [`c/completion.nim`](../../src/ned/c/completion.nim) | include 228 | completion: header names, and C names for importc |
| [`c/emit.nim`](../../src/ned/c/emit.nim) | include 229 | C in {.emit.}: completion, hover and F12 with no language server (headers read by ned itself) |
| [`c/emitclangd.nim`](../../src/ned/c/emitclangd.nim) | include 230 | C in {.emit.} through clangd: a hidden C document per Nim file, with the emitted C on the very lines and columns it has in the .nim file (everything else blank), so … |
| [`c/c2nim.nim`](../../src/ned/c/c2nim.nim) | include 232 | a C header as Nim: by ned's own C engine (cnim.nim), or with c2nim or futhark |
| [`c/compiledb.nim`](../../src/ned/c/compiledb.nim) | include 233 | compile_commands.json for clangd |
| [`c/cdocs.nim`](../../src/ned/c/cdocs.nim) | include 234 | C knowledge in Nim: a wrapper's C documentation, header: / importc: strings, C signatures beside wrappers, a wrapper rewritten from its C declaration, a new wrapper … |
| [`c/cengine.nim`](../../src/ned/c/cengine.nim) | include 235 | C files with ned's own engine (c.engine): completion — struct members after `.` and `->` too, a call's parameters to fill in, a header's names with their #include —, … |
| [`c/cchecks.nim`](../../src/ned/c/cchecks.nim) |  | C checks from ned's own engine, while you type and with no compiler: an #include nothing of which is used, a struct whose fields ordered by size take less room, a … |

## config

Settings, key bindings, folder trust, settings sync.

| file | | what it is |
|---|---|---|
| [`config/settings.nim`](../../src/ned/config/settings.nim) | include 45 | Settings — each declared (defS) with its default and what it does — read, written back with comments kept, applied |
| [`config/session.nim`](../../src/ned/config/session.nim) | include 46 | ned's remembered state between runs (state.json): recent files, cursor positions, theme, each folder's open files, breakpoints and layout, bookmarks, AI prompt … |
| [`config/sync.nim`](../../src/ned/config/sync.nim) | include 115 | settings sync: your settings, key bindings, snippets, themes and dictionary words in one file — exported, imported, or kept in a git repository of yours |
| [`config/reset.nim`](../../src/ned/config/reset.nim) | include 142 | Reset everything: ned as on its first run — its settings, its state (sessions, history, chats …), its caches and its downloads removed (each may be kept), then ned … |

## core

The basics everything uses: types, global state, utilities, languages, themes, text, images, secrets.

| file | | what it is |
|---|---|---|
| [`core/images.nim`](../../src/ned/core/images.nim) | module | Pictures read from their bytes — PNG, JPEG, GIF and BMP, with nothing outside Nim's standard library — and turned into what a terminal can show: half blocks (▀ in two … |
| [`core/text.nim`](../../src/ned/core/text.nim) | module | Text measured as the terminal shows it: UTF-8 runes, their display width, tabs |
| [`core/editorconfig.nim`](../../src/ned/core/editorconfig.nim) | module | editorconfig (editorconfig.org): the properties a project's .editorconfig files give a file — read by the editor (indentation, line ends, whitespace, the ruler) and … |
| [`core/encodings.nim`](../../src/ned/core/encodings.nim) | module | Text encodings: what a file's bytes are (UTF-8, with or without a BOM, UTF-16 with its BOM, Windows-1252 for text that is not UTF-8) and the conversions to and from … |
| [`core/secrets.nim`](../../src/ned/core/secrets.nim) | module | Secrets kept from the AI: API keys, tokens, private keys, passwords in connection strings and in assignments (`.env` lines, settings, code) are found in what ned is … |
| [`core/types.nim`](../../src/ned/core/types.nim) | include 24 | The types every part uses: buffers, positions and cursors, languages, themes, keys, jobs, diagnostics, prompts and pickers |
| [`core/state.nim`](../../src/ned/core/state.nim) | include 25 | The program's global state: the settings in use, open buffers, panes, docks, the panel, prompts, pickers, popups |
| [`core/utils.nim`](../../src/ned/core/utils.nim) | include 26 | Small utilities: positions and ranges, time since, relative paths, fuzzy matching |
| [`core/themes.nim`](../../src/ned/core/themes.nim) | include 27 | Themes: the built-in ones (mkTheme makes each from sixteen colours), the readability pass, true black, e-ink, the names that stand for others |
| [`core/screen.nim`](../../src/ned/core/screen.nim) | include 28 | Terminal: raw mode, cell grid, diffed output |
| [`core/termcaps.nim`](../../src/ned/core/termcaps.nim) | include 29 | What the terminal can do: asked of it when raw mode starts, never assumed from its name alone |
| [`core/keys.nim`](../../src/ned/core/keys.nim) | include 30 | Input decoding (keys, mouse, bracketed paste) |
| [`core/languages.nim`](../../src/ned/core/languages.nim) | include 31 | The built-in languages — extensions, comments, keywords, indent rules, run and build commands, language servers — and finding a file's language |
| [`core/highlight.nim`](../../src/ned/core/highlight.nim) | include 32 | Syntax highlighting (incremental, per-line state machine) |
| [`core/lexgeneric.nim`](../../src/ned/core/lexgeneric.nim) | include 33 | the generic lexer: one line of a language coloured from the language's description — comments, strings, numbers, keywords, types, operators — with the state of block … |
| [`core/lexers.nim`](../../src/ned/core/lexers.nim) | include 34 | the lexers of the languages that need more than the generic one — YAML, TOML and Makefile keys, Nim filter templates, Jinja, CSV, NIF — the host lexer that picks the … |
| [`core/todos.nim`](../../src/ned/core/todos.nim) | include 35 | Comment tags: TODO · FIXME · BUG · HACK · NOTE (colours, the TODOs dock, next/previous) |
| [`core/messages.nim`](../../src/ned/core/messages.nim) | include 36 | The status line's messages: info, warnings and errors (a long one in a popup) |
| [`core/themeimport.nim`](../../src/ned/core/themeimport.nim) | include 114 | Zed and Helix themes imported: a Zed theme family (.json) or a Helix theme (.toml, with its `inherits` and its [palette]) becomes ned's own theme file in … |
| [`core/sha256.nim`](../../src/ned/core/sha256.nim) |  | SHA-256 (FIPS 180-4): ned checks what it downloads against a release's SHA256SUMS |

## debug

The debugger: gdb, the Debug Adapter Protocol, the debug views.

| file | | what it is |
|---|---|---|
| [`debug/clines.nim`](../../src/ned/debug/clines.nim) | module | the C files of a Nim 2.4 build put right for the debugger |
| [`debug/gdb.nim`](../../src/ned/debug/gdb.nim) | include 209 | the debugger: gdb's machine interface (breakpoints, stepping, call stack, variables) |
| [`debug/dap.nim`](../../src/ned/debug/dap.nim) | include 210 | DAP (the Debug Adapter Protocol, as in VS Code and Zed): debugging Python (debugpy), C, C++ and Rust (gdb's own DAP mode, or lldb-dap), Go (delve) … in the same Debug … |
| [`debug/gdbterm.nim`](../../src/ned/debug/gdbterm.nim) | include 211 | debugging with gdb in the integrated terminal |

## editor

Buffers and editing: the edit primitive and undo, cursors, find, folding, saving, swap files, multibuffers, the hex and large-file views.

| file | | what it is |
|---|---|---|
| [`editor/regex.nim`](../../src/ned/editor/regex.nim) | module | Regular expressions: a small backtracking VM (no PCRE needed on Termux) |
| [`editor/binfmt.nim`](../../src/ned/editor/binfmt.nim) | module | executables and object files, read for the hex editor: ELF (Linux, Android), Mach-O (macOS) and PE (Windows) — what kind of file it is, its sections and its symbols … |
| [`editor/asmview.nim`](../../src/ned/editor/asmview.nim) | module | Assembly the way Compiler Explorer (godbolt.org) shows it: a compiler's `-S` output, or an object file disassembled by objdump, read line by line — each instruction … |
| [`editor/buffer.nim`](../../src/ned/editor/buffer.nim) | include 38 | Buffer core: text storage, edit primitive, undo |
| [`editor/loadsave.nim`](../../src/ned/editor/loadsave.nim) | include 39 | Files loaded: encoding, line ends, indent found, .editorconfig, big files streamed, the hex view, the undo saved with a file |
| [`editor/softwrap.nim`](../../src/ned/editor/softwrap.nim) | include 40 | Visual layout helpers (soft wrap) |
| [`editor/motion.nim`](../../src/ned/editor/motion.nim) | include 41 | Cursor movement: by character, word, line start and end, up and down — for every cursor |
| [`editor/editing.nim`](../../src/ned/editor/editing.nim) | include 42 | Editing commands (all multi-cursor aware) |
| [`editor/find.nim`](../../src/ned/editor/find.nim) | include 43 | searching the text: matches in a line (plain or regular expression, whole words), the next match from a position, selecting occurrences with several cursors, adding … |
| [`editor/safewrite.nim`](../../src/ned/editor/safewrite.nim) | include 48 | Safe writing (a temporary file renamed into place), ned's state and private folders, internal errors logged |
| [`editor/swap.nim`](../../src/ned/editor/swap.nim) | include 50 | swap files: unsaved edits survive a crash, a killed Termux session or a dead battery One file per (path, ned process): <hash(path)>-<pid>.json |
| [`editor/localhistory.nim`](../../src/ned/editor/localhistory.nim) | include 51 | local history: every save keeps the previous version (File › Local history) |
| [`editor/linediff.nim`](../../src/ned/editor/linediff.nim) | include 52 | line diff (Myers, after trimming the common head and tail) |
| [`editor/buffers.nim`](../../src/ned/editor/buffers.nim) | include 53 | the open buffers: finding one by id or path, the jump history, centring the view on a position and opening a file in a tab |
| [`editor/save.nim`](../../src/ned/editor/save.nim) | include 55 | the hex editor's bytes saved (editor/hexedit.nim) |
| [`editor/multibuffer.nim`](../../src/ned/editor/multibuffer.nim) | include 72 | multibuffers, as in Zed: pieces of many files in one editable buffer, each under a `§ path:line` header, written back to their files on save and kept in step with the … |
| [`editor/clipboard.nim`](../../src/ned/editor/clipboard.nim) | include 76 | Clipboard (internal + OSC 52 + Termux:API / wl-clipboard / xclip) |
| [`editor/snippets.nim`](../../src/ned/editor/snippets.nim) | include 77 | Snippets — the built-in ones and yours — expanded by Tab, Tab and Shift+Tab walking their placeholders (a placeholder used twice is edited with several cursors) |
| [`editor/html.nim`](../../src/ned/editor/html.nim) | include 78 | HTML editing helpers: a closing tag added when the `>` of an opening one is typed, linked editing (renaming a tag renames its partner) and the expansion of Emmet … |
| [`editor/emmetcss.nim`](../../src/ned/editor/emmetcss.nim) | include 79 | Emmet for CSS: Tab after m10 → margin: 10px |
| [`editor/completion.nim`](../../src/ned/editor/completion.nim) | include 89 | the completion popup: the list for the word being typed (from the language server, nimsuggest, ned's own engines, snippets and the words of the file), filtering it as … |
| [`editor/diagnostics.nim`](../../src/ned/editor/diagnostics.nim) | include 95 | a file's problems (errors, warnings, hints) merged from every source — language server, builds and checks, tests, plugins, ned's own checks — kept in step with the … |
| [`editor/findreplace.nim`](../../src/ned/editor/findreplace.nim) | include 96 | the find and replace commands: counting the matches, finding as you type, stepping to the next or previous match, replacing all at once and asking match by match |
| [`editor/navigation.nim`](../../src/ned/editor/navigation.nim) | include 97 | going to places and asking about code: go to line, the jump list and closed tabs, next problem, go to symbol, definition, type definition, implementations, type … |
| [`editor/search.nim`](../../src/ned/editor/search.nim) | include 98 | project-wide text search: runs ripgrep or grep (or a built-in scan when neither exists) over the project, collects the matching lines for the Search view of the left … |
| [`editor/projectreplace.nim`](../../src/ned/editor/projectreplace.nim) | include 99 | project-wide replace (Search view › ⇄): preview inline, replace one / a file / everything |
| [`editor/undotree.nim`](../../src/ned/editor/undotree.nim) | include 102 | the undo tree: an edit after an undo keeps what was undone as a branch (buffer.nim: detachRedo), and Edit › Undo history… lists every state the file has been in — on … |
| [`editor/nextedit.nim`](../../src/ned/editor/nextedit.nim) | include 160 | next-edit suggestions (editor.nextEdit): after a change to a name — `width` made `size` — the next place that still says `width` shows "→ size ⇥": Tab goes there, Tab … |
| [`editor/pictures.nim`](../../src/ned/editor/pictures.nim) | include 163 | pictures: a .png, .jpg, .gif or .bmp file opens as a picture (Tab: its bytes in the hex editor, Shift+Tab back), and a Markdown preview shows the pictures it has |
| [`editor/spell.nim`](../../src/ned/editor/spell.nim) | include 165 | spell check: Markdown, commit messages, and (editor.spellCheck "on") comments and strings in code |
| [`editor/rainbow.nim`](../../src/ned/editor/rainbow.nim) | include 167 | rainbow brackets: a pair never takes the colour of the text around it |
| [`editor/swatches.nim`](../../src/ned/editor/swatches.nim) | include 170 | colour swatches: a small block before #RRGGBB, rgb(…), hsl(…) and Nim's 0xRRGGBB (editor.colorSwatches) |
| [`editor/hexedit.nim`](../../src/ned/editor/hexedit.nim) | include 171 | the hex editor. A binary file opens as its bytes — offset · hex · text — to type over (or insert, Insert key), delete, undo, search (bytes or text), go to an offset, … |
| [`editor/jumplabels.nim`](../../src/ned/editor/jumplabels.nim) | include 172 | jump labels: a letter or two over every word on screen |
| [`editor/decompile.nim`](../../src/ned/editor/decompile.nim) | include 179 | the decompiler, side by side: a function of a program — a Nim proc by its Nim name — as C (radare2 with r2ghidra or r2dec, rizin with rz-ghidra, RetDec) or as its … |
| [`editor/cexplorer.nim`](../../src/ned/editor/cexplorer.nim) | include 180 | Compiler Explorer, as godbolt.org: the file beside the assembly it compiles to, compiled again a moment after you stop typing (the unsaved text, in a private copy of … |
| [`editor/macros.nim`](../../src/ned/editor/macros.nim) | include 193 | keyboard macros: record what you type, play it back (N times, on each selected line, to the end of the file), keep it under a name |
| [`editor/surround.nim`](../../src/ned/editor/surround.nim) | include 194 | surround: brackets, quotes, a tag or a block (if, for, try…) around the selection |
| [`editor/folding.nim`](../../src/ned/editor/folding.nim) | include 198 | IDE features: folding, inlay hints, tests, project symbols, code actions, expand selection, gutter actions, gdb |
| [`editor/projectsymbols.nim`](../../src/ned/editor/projectsymbols.nim) | include 205 | project-wide symbols (works offline for every language: Nim's and C's from ned's engines, the others' by their shape) |
| [`editor/selection.nim`](../../src/ned/editor/selection.nim) | include 207 | selection by structure: it grows to the enclosing word, string, brackets, statement and block, and shrinks back |
| [`editor/spelldicts.nim`](../../src/ned/editor/spelldicts.nim) | include 222 | spell check commands and the dictionary downloads: the next misspelled word, choosing where it checks, downloading hunspell dictionaries, and the quick fixes (change, … |
| [`editor/inactive.nim`](../../src/ned/editor/inactive.nim) | include 236 | code a compile leaves out, dimmed: Nim's `when` branches that are false on this platform (when defined(windows) on Linux), C's #if 0 and #ifdef __cplusplus … |
| [`editor/csv.nim`](../../src/ned/editor/csv.nim) | include 252 | CSV tables: sort by a column, a column's summary |
| [`editor/notebook.nim`](../../src/ned/editor/notebook.nim) | include 254 | Notebook: a Nim or Python file's `# %%` cells run in one session that stays alive, each cell's output drawn under it (rows that are not part of the text: nothing is … |
| [`editor/tour.nim`](../../src/ned/editor/tour.nim) | include 255 | The Nim tour (Help › Nim tour): sixteen short lessons of Nim that run in the notebook, from the first echo to calling C |
| [`editor/bookmarks.nim`](../../src/ned/editor/bookmarks.nim) | include 262 | ned 4: bookmarks · local history · crash recovery · git changes & blame |
| [`editor/localhistoryview.nim`](../../src/ned/editor/localhistoryview.nim) | include 263 | local history and recent projects: a file's earlier saved versions compared with it, folders opened before |
| [`editor/recovery.nim`](../../src/ned/editor/recovery.nim) | include 264 | crash recovery: unsaved edits kept in recovery files, offered back after a crash |
| [`editor/hotexit.nim`](../../src/ned/editor/hotexit.nim) | include 265 | hot exit (files.hotExit): quitting keeps the unsaved edits without asking |
| [`editor/encodingcmds.nim`](../../src/ned/editor/encodingcmds.nim) | include 266 | a file's encoding: reopen it as another, save it as another (the status bar's UTF-8 · Windows-1252 …) |
| [`editor/lfview.nim`](../../src/ned/editor/lfview.nim) | include 267 | The large-file viewer: a file bigger than editor.viewerSize (512 MB) — a log, a dump, a data file — opened read-only with a window of its lines in memory (LfWin of them) |
| [`editor/bufforget.nim`](../../src/ned/editor/bufforget.nim) | include 304 | a tab closed: what ned kept about it goes with it |
| [`editor/autoindent.nim`](../../src/ned/editor/autoindent.nim) |  | Indentation as you type, for Nim (editor.autoDedent): where a closing bracket typed alone on its line goes, and where a branch word (`of`, `elif`, `else`, `except`, … |
| [`editor/tourlessons.nim`](../../src/ned/editor/tourlessons.nim) |  | The Nim tour's lessons (tour/lesson*.nim), read into ned when it is built, and what ned needs to know of one: its title, its cells' titles, the exercise's answer … |

## format

The formatters: Nim (nph-style), C, YAML, TOML, the others, nedfmt's command line.

| file | | what it is |
|---|---|---|
| [`format/formatters.nim`](../../src/ned/format/formatters.nim) | module | ned's built-in formatters: Nim (in nph's style, checked), JSON, Markdown tables, CSS and C (indentation) |
| [`format/fmtcli.nim`](../../src/ned/format/fmtcli.nim) | module | ned's formatters from the command line: `nedfmt` (and `ned --format`) |
| [`format/apply.nim`](../../src/ned/format/apply.nim) | include 64 | the means of applying a formatter: running an external command as a filter (text in on stdin, text out), putting its result into the buffer as the smallest set of … |
| [`format/commands.nim`](../../src/ned/format/commands.nim) | include 69 | the format commands: which formatter a file gets, formatting a whole file, selected lines, only the lines changed (on save) or the code inside a Nim triple-quoted … |
| [`format/folder.nim`](../../src/ned/format/folder.nim) | include 103 | Format every file of a folder (or the project): each with what Alt+F would use, reviewed before anything is written |
| [`format/cfmt.nim`](../../src/ned/format/cfmt.nim) |  | Built-in C formatter (C files, and the C in a Nim {.emit.}) |
| [`format/css.nim`](../../src/ned/format/css.nim) |  | CSS (and SCSS / Less): one declaration per line, blocks indented, `prop: value;` |
| [`format/cstyle.nim`](../../src/ned/format/cstyle.nim) |  | The C formatter's style: as written ("keep", ned's own way since 5.13), one of clang-format's presets (LLVM, Google, Chromium, Mozilla, WebKit, Microsoft, GNU) or the … |
| [`format/html.nim`](../../src/ned/format/html.nim) |  | HTML (and the templates in it): block elements on their own lines with their content indented, inline content flowing in lines |
| [`format/json.nim`](../../src/ned/format/json.nim) |  | JSON (and JSON with comments): the text of every value is kept exactly |
| [`format/markdown.nim`](../../src/ned/format/markdown.nim) |  | Markdown formatted: tables aligned (each cell padded to its column) |
| [`format/nedastcheck.nim`](../../src/ned/format/nedastcheck.nim) |  | nedastcheck — do two Nim texts parse to the same syntax tree? Nim's own parser (the compiler's sources) reads both |
| [`format/nim.nim`](../../src/ned/format/nim.nim) |  | the Nim formatter in nph's style: statements split and wrapped, calls, collections, comments, blank lines (format/formatters.nim calls it) |
| [`format/nimembed.nim`](../../src/ned/format/nimembed.nim) |  | The code in a Nim file's triple-quoted strings — SQL, HTML, JSON (and CSS) — formatted with ned's own formatter for that language when the Nim is formatted … |
| [`format/nimlex.nim`](../../src/ned/format/nimlex.nim) |  | Built-in Nim formatter, in nph's style: 2-space indentation, spaced operators and commas, one statement per line, blank lines after multi-line routines and types, … |
| [`format/nimspacing.nim`](../../src/ned/format/nimspacing.nim) |  | the Nim formatter's spacing: where a space goes between two tokens, and a line made from its tokens |
| [`format/sql.nim`](../../src/ned/format/sql.nim) |  | SQL: each clause of a statement on its own line, lists and conditions broken when long, sub-queries indented |
| [`format/yamltoml.nim`](../../src/ned/format/yamltoml.nim) |  | YAML and TOML: careful formatters — only the layout changes, never what the file says, and each checks its own result (the same words in the same order and, for YAML, … |

## git

Git: the changes, commits, blame, merge, GitHub.

| file | | what it is |
|---|---|---|
| [`git/repos.nim`](../../src/ned/git/repos.nim) | include 63 | git repositories of the workspace: each folder's own |
| [`git/conflictmarks.nim`](../../src/ned/git/conflictmarks.nim) | include 81 | finding the merge conflicts of a buffer (the <<<<<<< ======= >>>>>>> blocks), and the forward declarations and shared debugger state that code included earlier in … |
| [`git/status.nim`](../../src/ned/git/status.nim) | include 105 | git status: which files changed (for the file tree and the Git dock), refreshed in the background, and one file's diff view |
| [`git/watch.nim`](../../src/ned/git/watch.nim) | include 106 | git status when something changes, not every few seconds: the repository's .git folder (a commit, a stage, a branch, a checkout, a pull — from ned, its terminal or … |
| [`git/mergeeditor.nim`](../../src/ned/git/mergeeditor.nim) | include 187 | the merge editor: ours and theirs side by side above the result (the file itself, with its markers) |
| [`git/conflicts.nim`](../../src/ned/git/conflicts.nim) | include 256 | git merge conflicts: accept ours / theirs / both, and a side-by-side view against the last commit |
| [`git/changesview.nim`](../../src/ned/git/changesview.nim) | include 268 | the Git changes view (Git › Changes…, Alt+Shift+G): every change not committed yet, in every file, in one editable multibuffer — each change with a line or two around … |
| [`git/marks.nim`](../../src/ned/git/marks.nim) | include 269 | git: live change marks, stepping through changes, reverting one, blame |
| [`git/commands.nim`](../../src/ned/git/commands.nim) | include 273 | git: branches, push/pull that ask for a login in the terminal, commit box, history, stash, blame, more |
| [`git/setup.nim`](../../src/ned/git/setup.nim) | include 274 | git for a new folder and for other people's projects: init, who you are, clone from a link |
| [`git/advanced.nim`](../../src/ned/git/advanced.nim) | include 276 | interactive rebase, cherry-pick from a branch, compare branches, branch graph, GitHub (gh) |
| [`git/history.nim`](../../src/ned/git/history.nim) | include 277 | git: the history of some lines, bisect, worktrees, submodules |
| [`git/github.nim`](../../src/ned/git/github.nim) | include 278 | the GitHub commands, through the gh command line tool: pull requests, issues and Actions runs as menus, and the CI status of the current branch shown in the status bar |
| [`git/signin.nim`](../../src/ned/git/signin.nim) | include 279 | signing in to GitHub: GitHub takes no password from git (since 2021), so when a push, pull or fetch needs a login ned offers the ways that work — the GitHub CLI … |
| [`git/undo.nim`](../../src/ned/git/undo.nim) | include 280 | git: undo — the last things done to the branch (git's reflog: commits, amends, pulls, merges, rebases, resets, switches), each undone in one step: the branch goes … |
| [`git/precommit.nim`](../../src/ned/git/precommit.nim) | include 281 | checks before a commit (git.checksBeforeCommit): the files to be committed are formatted (ned's own formatters, on what is staged), and the tests that cover them pass |
| [`git/reviews.nim`](../../src/ned/git/reviews.nim) | include 282 | GitHub review comments of the branch's pull request, on the lines they are about: a note at the end of the line, the whole thread on hover, a list to go through them, … |
| [`git/aigit.nim`](../../src/ned/git/aigit.nim) | include 283 | the assistant with git: why a line changed (its commit, explained), merge conflicts resolved — and checked by the compiler before you see them — and the staged … |

## keymaps

The key bindings that are not VS Code's: Vim (and its : line), Emacs, Helix.

| file | | what it is |
|---|---|---|
| [`keymaps/vim.nim`](../../src/ned/keymaps/vim.nim) | include 191 | Vim mode (editor.vimMode): normal · insert · visual · visual-line · replace |
| [`keymaps/vimex.nim`](../../src/ned/keymaps/vimex.nim) | include 192 | Vim mode's : line — :set for every setting, the line commands with their ranges, Vim's common commands, any of ned's commands by name, and Tab completing all of them … |
| [`keymaps/vimkeys.nim`](../../src/ned/keymaps/vimkeys.nim) | include 195 | the vim keymap's key handling (editor.vimMode): Ctrl+W window commands, and vimKey, which takes each key in insert, replace, normal and visual mode — counts, … |
| [`keymaps/emacs.nim`](../../src/ned/keymaps/emacs.nim) | include 196 | the emacs keymap: C-f C-b C-n C-p · C-a C-e · M-f M-b · C-v M-v · M-< M-> · C-k C-w M-w C-y · C-SPC mark · C-s · M-% · C-/ · C-x C-s / C-f / C-w / b / k / u / h / o / … |
| [`keymaps/helix.nim`](../../src/ned/keymaps/helix.nim) | include 197 | the helix keymap: select, then act |

## lsp

Language servers: the client, their features, nimlangserver and nimsuggest.

| file | | what it is |
|---|---|---|
| [`lsp/client.nim`](../../src/ned/lsp/client.nim) | include 65 | The language server client: servers started, requests and notifications sent, replies read, positions in UTF-16 |
| [`lsp/renamepreview.nim`](../../src/ned/lsp/renamepreview.nim) | include 66 | rename preview: every change listed first |
| [`lsp/handlers.nim`](../../src/ned/lsp/handlers.nim) | include 67 | what ned does with what language servers send: the answers to its requests (symbols, hover, completion, references, formatting, signature help, hierarchies …), the … |
| [`lsp/doclinks.nim`](../../src/ned/lsp/doclinks.nim) | include 68 | more of the language server protocol: problems ned asks for (pull diagnostics — servers that only answer when asked), the file's links (#include "x.h", @import, a … |
| [`lsp/inlays.nim`](../../src/ned/lsp/inlays.nim) | include 199 | inlay hints (LSP textDocument/inlayHint) |
| [`lsp/codeactions.nim`](../../src/ned/lsp/codeactions.nim) | include 206 | code actions (quick fixes): ned's own and the language server's, listed at the cursor and applied |
| [`lsp/embedded.nim`](../../src/ned/lsp/embedded.nim) | include 231 | HTML, CSS, SQL, JSON (and JavaScript) in Nim strings, through their language servers: hidden documents built from what the lexer coloured, one per language (JSON: one … |

## nedls

Nedls, ned's engines as a language server for other editors.

| file | | what it is |
|---|---|---|
| [`nedls/actions.nim`](../../src/ned/nedls/actions.nim) |  | nedls — code actions: what the editor's Alt+Enter offers, for the lines the client asks about |
| [`nedls/diags.nim`](../../src/ned/nedls/diags.nim) |  | nedls — problems, as ned finds them: a misspelled name at once (engineTypos), the compiler on the unsaved text after a pause in typing (typingCheck: `nim check -` on … |
| [`nedls/docs.nim`](../../src/ned/nedls/docs.nim) |  | nedls — open documents as ned Buffers (so the engine reads the unsaved text, as in the editor), positions in the client's encoding (UTF-16 code units, or UTF-8 bytes … |
| [`nedls/features.nim`](../../src/ned/nedls/features.nim) |  | nedls — the language features, each one the editor's own: completion (engineComplete), hover (engineHover), signature help (engineSignature), definition and … |
| [`nedls/langs.nim`](../../src/ned/nedls/langs.nim) |  | nedls — the other languages ned's own engines know, as the editor has them: C and C++ (completion, hover, signature help, definition through the #includes, … |
| [`nedls/more.nim`](../../src/ned/nedls/more.nim) |  | nedls — more of what the editor has, as LSP: the call hierarchy (who calls a routine, what it calls), the type hierarchy (an object's ancestors and the types made of … |
| [`nedls/rpc.nim`](../../src/ned/nedls/rpc.nim) |  | nedls — JSON-RPC over stdio: Content-Length framing (partial reads, several messages in one read), replies, notifications and logging |
| [`nedls/server.nim`](../../src/ned/nedls/server.nim) |  | nedls — the server: lifecycle (initialize · initialized · shutdown · exit), settings, the project and its toolchain (as the editor sets them up), the dispatch of … |
| [`nedls/symbols.nim`](../../src/ned/nedls/symbols.nim) |  | nedls — workspace symbols (workspace/symbol): the declarations of the project's files — Nim's from the index, C's and C++'s from the C engine, JavaScript's and JSON's … |

## nim

The Nim IDE: the engine (index/ is a module of its own), the engine worker, checks, macros, NIF, nimble, Nim 3.

| file | | what it is |
|---|---|---|
| [`nim/index.nim`](../../src/ned/nim/index.nim) | module | ned's Nim index: what Nim code declares and means, read by ned itself — no compiler, no server |
| [`nim/arccopies.nim`](../../src/ned/nim/arccopies.nim) | module | ARC/ORC's copies, from `nim c --expandArc:name …`: where in the source each `=copy` and `=dup` the compiler inserted stands |
| [`nim/nifread.nim`](../../src/ned/nim/nifread.nim) | module | NIF, Nim 3's (Nimony's) code between its passes: read as nodes — each tag, atom and definition with where it is in the NIF text and where it comes from in the Nim … |
| [`nim/nimony.nim`](../../src/ned/nim/nimony.nim) | include 57 | Nim 3 (Nimony). A project built with `nimony` (nim.compiler: "nimony", best in its .ned/settings.json) is Nim 3: ned's engine matches names as written (Nim 3 is … |
| [`nim/typingcheck.nim`](../../src/ned/nim/typingcheck.nim) | include 62 | errors while you type, from the compiler: the unsaved text checked as it is `nim check -` reads the module from stdin |
| [`nim/project.nim`](../../src/ned/nim/project.nim) | include 70 | Tools, nimble projects, scratch buffers |
| [`nim/nimsuggest.nim`](../../src/ned/nim/nimsuggest.nim) | include 71 | Built-in nimsuggest client — completion, hover, definition, references, signatures, outline, macro expansion and live checks with a stock `nim` install |
| [`nim/nimsuggestread.nim`](../../src/ned/nim/nimsuggestread.nim) | include 73 | reading nimsuggest's answers: its output is split into replies, and each reply is turned into what the request asked for — completion, go to definition, hover, … |
| [`nim/oracle.nim`](../../src/ned/nim/oracle.nim) | include 74 | Nim: the compiler as an oracle in the background (nim.compilerOracle) What ned's engine cannot work out by reading — the type of a let whose value a macro makes, a … |
| [`nim/compileranswers.nim`](../../src/ned/nim/compileranswers.nim) | include 75 | Nim: the compiler's answer where the engine has none, without nimsuggest kept running (nim.nimsuggest off): one nimsuggest run for the one question (hover, Go to … |
| [`nim/engine.nim`](../../src/ned/nim/engine.nim) | include 80 | The Nim engine in the editor: when it is on, the toolchain it reads, nim dump and the library paths, the dependencies |
| [`nim/semantic.nim`](../../src/ned/nim/semantic.nim) | include 82 | colours from the index: a name is coloured by what it is (proc, template, type, constant, field, parameter, module), not by its case — and by where it stands: after a … |
| [`nim/answers.nim`](../../src/ned/nim/answers.nim) | include 83 | the answers of ned's own Nim engine to the editor: completion (with its postfix templates), signature help, hover, go to definition, find references and rename — and … |
| [`nim/oraclerun.nim`](../../src/ned/nim/oraclerun.nim) | include 84 | Nim: the oracle's questions and its runs (nim/oracle has what it keeps) |
| [`nim/reflens.nim`](../../src/ned/nim/reflens.nim) | include 85 | reference counts beside Nim declarations ("3 references" |
| [`nim/highlights.nim`](../../src/ned/nim/highlights.nim) | include 86 | the uses in this file of what the name at the cursor names (as clangd's document highlights), resolved by ned's engine: a local of another proc, a field of another … |
| [`nim/copies.nim`](../../src/ned/nim/copies.nim) | include 87 | where ARC/ORC copies: after a save the compiler expands the file's routines (nim c --expandArc) and each =copy / =dup it inserted is marked beside what it copies … |
| [`nim/outline.nim`](../../src/ned/nim/outline.nim) | include 88 | the Nim file's outline for the side panel and the Ctrl+T symbol list, built from the engine's declarations (a heuristic outline when the engine fails), plus a … |
| [`nim/messages.nim`](../../src/ned/nim/messages.nim) | include 90 | Navigation helpers: find, goto, symbols, definitions, diagnostics |
| [`nim/nimapis.nim`](../../src/ned/nim/nimapis.nim) | include 91 | generated by .github/ci/nimapis.py: the standard-library names and modules each Nim release added (a release step: the release before it, it, modules new in it, … |
| [`nim/nim3checks.nim`](../../src/ned/nim/nim3checks.nim) | include 92 | Nim 3 (Nimony): what Nim 2 code must change to compile under Nimony (doc/porting.md, each rule checked against what nimony 0.6.3 itself rejects — closure iterators … |
| [`nim/enginechecks.nim`](../../src/ned/nim/enginechecks.nim) | include 93 | checks from ned's own Nim engine, at once while you type (no compiler): code after a return, a field or proc that is not there (with the name meant), a call with too … |
| [`nim/macronames.nim`](../../src/ned/nim/macronames.nim) | include 94 | names a macro makes, from the compiler: a module's top-level macro calls (makeProcs(Foo, Bar) at the left margin) expanded once by `nim check --expandMacro`, and what … |
| [`nim/why.nim`](../../src/ned/nim/why.nim) | include 101 | why? (6.32): where an exception or a side effect comes from — the place in the routine where it comes in, the routine called there, the place in that one, … down to … |
| [`nim/commands.nim`](../../src/ned/nim/commands.nim) | include 104 | the commands for Nim work: unused exports, expanding templates and macros, the ARC view and the generated C, call hierarchy, peek definition and references, find … |
| [`nim/toolchain.nim`](../../src/ned/nim/toolchain.nim) | include 111 | one Nim per project (nim.toolchain): the Nim a project builds with, for every tool ned starts — nim, nimble, nimsuggest, nimlangserver, testament, the terminal — by … |
| [`nim/projectchecks.nim`](../../src/ned/nim/projectchecks.nim) | include 112 | the project's own checks: a package imported that the .nimble does not require (a quick fix adds the line), a requirement nothing imports, exported routines nothing … |
| [`nim/macroview.nim`](../../src/ned/nim/macroview.nim) | include 120 | macros you can see (6.32): what a macro or template call writes, folded under the call — rows that are not text (Buffer.vrows), coloured as Nim |
| [`nim/atlas.nim`](../../src/ned/nim/atlas.nim) | include 126 | Atlas (nim-lang/atlas): a project whose dependencies are in its own deps/ folder |
| [`nim/nifview.nim`](../../src/ned/nim/nifview.nim) | include 181 | NIF, Nim 3's code between its passes (nifread.nim reads it): its outline |
| [`nim/nimnif.nim`](../../src/ned/nim/nimnif.nim) | include 182 | what the compiler made of a saved file, read from its NIF: Nim 2.4's `nim nif` (run in place of `nim check` on save: the same messages, about the same time — and, for … |
| [`nim/nifprint.nim`](../../src/ned/nim/nifprint.nim) | include 183 | what a macro call made, shown under the call (Alt+M) at once from the saved file's NIF (Nim 2.4's `nim nif`, nimony) instead of running the compiler again — written … |
| [`nim/nifcolors.nim`](../../src/ned/nim/nifcolors.nim) | include 184 | colours from the compiler's reading of a saved file (nimnif.nim: Nim 2.4's `nim nif`, or nimony with Nim 3): what each name is as the compiler resolved it — a name a … |
| [`nim/pnak.nim`](../../src/ned/nim/pnak.nim) | include 185 | pnak, Nim 3's package tool: its pnak.nif lockfile (every package at its commit) read — the outline, hover, F12 to the package's checkout, its problems — and pnak … |
| [`nim/astview.nim`](../../src/ned/nim/astview.nim) | include 186 | the AST view (Nim: AST view): the code's tree as a macro gets it — `body: untyped` — from Nim's own parser (nim e, parseStmt + treeRepr), and what the macro or … |
| [`nim/aifix.nim`](../../src/ned/nim/aifix.nim) | include 217 | quick fixes of our own: Nim imports, AI fix/explain |
| [`nim/stdindex.nim`](../../src/ned/nim/stdindex.nim) | include 219 | Nim: an index of what the standard library exports (for "import std/…" quick fixes) |
| [`nim/codegen.nim`](../../src/ned/nim/codegen.nim) | include 220 | Nim code generation: missing case branches, $ / == / hash / constructor, doc comment, run a selection |
| [`nim/refactors.nim`](../../src/ned/nim/refactors.nim) | include 221 | refactors: extract a variable, inline one, "a" & x → fmt"a{x}", and evaluating Nim at compile time |
| [`nim/fixes.nim`](../../src/ned/nim/fixes.nim) | include 237 | Nim: quick fixes from the compiler's messages (Alt+Enter on the line) Each fix is worked out from the message and the text alone — a list of edits — so it can be … |
| [`nim/refactor/core.nim`](../../src/ned/nim/refactor/core.nim) | include 238 | Nim refactorings across the project: change a routine's signature, inline it, move it to another module The places are the built-in engine's references (Find references) |
| [`nim/refactor/signature.nim`](../../src/ned/nim/refactor/signature.nim) | include 239 | Nim: change signature — a proc's parameters reordered, renamed, added or removed, every call updated |
| [`nim/refactor/inline.nim`](../../src/ned/nim/refactor/inline.nim) | include 240 | inline a routine: each call becomes its body |
| [`nim/refactor/move.nim`](../../src/ned/nim/refactor/move.nim) | include 241 | move a top-level declaration to another module |
| [`nim/refactor/reshape.nim`](../../src/ned/nim/refactor/reshape.nim) | include 242 | the bigger refactorings in the editor: object ⇄ ref object, a module split, callback → async, a call's syntax |
| [`nim/rewrites.nim`](../../src/ned/nim/rewrites.nim) | include 243 | Nim rewrites in the quick-fix list (Alt+Enter), learned from other languages' servers: the type a let or var gets written out (rust-analyzer, Pylance), a call written … |
| [`nim/quickfixes.nim`](../../src/ned/nim/quickfixes.nim) | include 244 | the quick-fix list (Alt+Enter) for Nim and for the other languages: the fixes for the problems at the cursor, the refactorings the cursor's word allows, and the … |
| [`nim/profile.nim`](../../src/ned/nim/profile.nim) | include 246 | Nim: run with ned's line profiler — a small module (kept in this file as text) is imported into the program, which samples where it is about every millisecond and … |
| [`nim/flame.nim`](../../src/ned/nim/flame.nim) | include 247 | the profile as a flame graph: each call stack the profiler saw, the program at the top and what each proc called below it, as wide as the time it took — a tap on a … |
| [`nim/misc.nim`](../../src/ned/nim/misc.nim) | include 250 | small Nim commands that need no engine: share to the Nim Playground, switch the Nim version (choosenim or grabnim), browse the standard library's names, and list a … |
| [`nim/nimbletree.nim`](../../src/ned/nim/nimbletree.nim) | include 251 | Nimble: the dependency tree — what the project requires, what that requires in turn, and what is installed |
| [`nim/refactor/extract.nim`](../../src/ned/nim/refactor/extract.nim) | include 259 | Nim refactors: extract a proc, sort imports, proc ⇄ func |
| [`nim/nimbleupdates.nim`](../../src/ned/nim/nimbleupdates.nim) | include 260 | Nimble: which dependencies have newer versions (each package's git tags), and moving a requirement up |
| [`nim/nimbleedit.nim`](../../src/ned/nim/nimbleedit.nim) | include 261 | Editing a .nimble (and a config.nims): the versions a `requires` can name (installed, and the package's git tags) completed and on hover, a dependency added from the … |
| [`nim/ciworkflow.nim`](../../src/ned/nim/ciworkflow.nim) | include 275 | Nim: add a CI workflow — .github/workflows/ci.yml for the project: its dependencies, build and tests on Linux and macOS with the oldest Nim its .nimble allows and the … |
| [`nim/extras.nim`](../../src/ned/nim/extras.nim) | include 286 | Nim: what a proc can raise · benchmark a call · nimble release |
| [`nim/examples.nim`](../../src/ned/nim/examples.nim) | include 287 | Nim: run runnableExamples — the ▶ beside them runs one block, "run all examples" every block in the file |
| [`nim/worker.nim`](../../src/ned/nim/worker.nim) | include 292 | the engine worker (nim.engineWorker): what the Nim engine works out at length — type and parameter hints, its own checks, misspelled names — worked out by a second … |
| [`nim/pkgwatch.nim`](../../src/ned/nim/pkgwatch.nim) | include 293 | nimble packages installed (or removed) while ned runs: in ned's terminal, another one, or by nimble setup / atlas |
| [`nim/warmindex.nim`](../../src/ned/nim/warmindex.nim) | include 303 | ned --warm-index (6.32): Nim's standard library parsed once into the index cache (~/.cache/ned/index), so that the first session's completion, hover and checks start … |
| [`nim/index/complete.nim`](../../src/ned/nim/index/complete.nim) |  | answers: completion, hover, definition, signature help |
| [`nim/index/concepts.nim`](../../src/ned/nim/index/concepts.nim) |  | concepts: which types satisfy one |
| [`nim/index/consteval.nim`](../../src/ned/nim/index/consteval.nim) |  | compile-time values: a constant expression worked out the way the compiler would, as far as the index knows the names in it — numbers (with shl, and, xor …), strings, … |
| [`nim/index/diskcache.nim`](../../src/ned/nim/index/diskcache.nim) |  | the index on disk: a library or package file parsed once, not again in every session |
| [`nim/index/effects.nim`](../../src/ned/nim/index/effects.nim) |  | side effects: has a routine any, as the engine works it out — the walk of raises.nim, where a side effect is what is "raised": a module's variable used (a var, let, … |
| [`nim/index/expand.nim`](../../src/ned/nim/index/expand.nim) |  | a template call written out: its body with the arguments in place (no compiler needed) |
| [`nim/index/hover.nim`](../../src/ned/nim/index/hover.nim) |  | hover, go to definition and signature help for the Nim index: what the name under the cursor is (its declaration, a constant's value, the generic types bound at a … |
| [`nim/index/layout.nim`](../../src/ned/nim/index/layout.nim) |  | memory layout: how a type lies in memory — each field's offset, size and the padding after it, the total size and alignment — worked out the way Nim's C code … |
| [`nim/index/lex.nim`](../../src/ned/nim/index/lex.nim) |  | Nim index — ned's own understanding of Nim code, no compiler needed |
| [`nim/index/locals.nim`](../../src/ned/nim/index/locals.nim) |  | inside a routine: parameters, result, lets/vars/for variables before the cursor |
| [`nim/index/macrosyms.nim`](../../src/ned/nim/index/macrosyms.nim) |  | names a macro makes: the compiler's expansion of a file's top-level macro calls (ned's nim/macronames runs it) adds their declarations to the file's own, at the call … |
| [`nim/index/nimscript.nim`](../../src/ned/nim/index/nimscript.nim) |  | NimScript files (config.nims, build.nims, a package's .nimble): what they see and write that programs do not system's NimScript API (exec, thisDir, switch …) is … |
| [`nim/index/parse.nim`](../../src/ned/nim/index/parse.nim) |  | the Nim engine's declaration parser: imports, when/defined branches, a file's declarations and their values |
| [`nim/index/raises.nim`](../../src/ned/nim/index/raises.nim) |  | exceptions: what a routine can raise, as the engine works it out — its raise statements and the routines it calls (their {.raises.}, or what they can raise in turn: … |
| [`nim/index/reshape.nim`](../../src/ned/nim/index/reshape.nim) |  | bigger refactorings, worked out from the text and the index: a type between `object` and `ref object`, the selected declarations of a module split into a new one, a … |
| [`nim/index/resolve.nim`](../../src/ned/nim/index/resolve.nim) |  | working out what a word in the code refers to: the word at a column, the operators and constructor fields, forward declarations and their bodies, overloads narrowed … |
| [`nim/index/scope.nim`](../../src/ned/nim/index/scope.nim) |  | files, modules and what each file can see |
| [`nim/index/switches.nim`](../../src/ned/nim/index/switches.nim) |  | the compiler's switches (`nim --fullhelp` of Nim 2.2.12): `--opt:speed` and `switch("opt", "speed")` in a NimScript file completed, explained on hover and checked — … |
| [`nim/index/text.nim`](../../src/ned/nim/index/text.nim) |  | small text helpers on code (strings already intact, comments gone) |
| [`nim/index/types.nim`](../../src/ned/nim/index/types.nim) |  | types: what an expression is, and what a type offers |
| [`nim/index/typos.nim`](../../src/ned/nim/index/typos.nim) |  | names that are surely misspelled: told at once, before the compiler's check comes back |

## plugins

The plugin host (host.nim) and the library plugins are written with (lib/).

| file | | what it is |
|---|---|---|
| [`plugins/decor.nim`](../../src/ned/plugins/decor.nim) | include 37 | plugins: what they put in the editor (gutter signs, text after a line, highlights, status-bar items) and what they declare that the editor's own parts read … |
| [`plugins/perms.nim`](../../src/ned/plugins/perms.nim) | include 294 | plugin permissions: what a plugin may do beyond editing — run programs, use the network, change files, read and set the clipboard |
| [`plugins/host.nim`](../../src/ned/plugins/host.nim) | include 295 | Plugins: folders with a plugin.nims (yours: ~/.config/ned/plugins/<name>, a project's: .ned/plugins/<name>, once you trust the folder) run together in one NimScript … |
| [`plugins/lib/nedlsp.nim`](../../src/ned/plugins/lib/nedlsp.nim) |  | nedlsp — a language server in NimScript |
| [`plugins/lib/nedplugin.nim`](../../src/ned/plugins/lib/nedplugin.nim) |  | nedplugin — what a ned plugin imports |

## project

Projects and workspaces: the file tree, project search, remote folders over SSH.

| file | | what it is |
|---|---|---|
| [`project/files.nim`](../../src/ned/project/files.nim) | include 47 | The project's files: scanned in the background for the picker, the file tree's folders loaded and shown |
| [`project/remote.nim`](../../src/ned/project/remote.nim) | include 54 | remote folders over SSH: a local copy to edit (tree, search, language servers work as usual) |
| [`project/workspaces.nim`](../../src/ned/project/workspaces.nim) | include 212 | multi-root workspaces: several folders in one window (tree, quick open, search, language servers) |
| [`project/remotesync.nim`](../../src/ned/project/remotesync.nim) | include 213 | remote folders over SSH, the working part: the saved list of them, the shared ssh connection, copying the server's files to the local copy (the first pull, the … |

## run

Running things: jobs, the output panel, tasks, tests.

| file | | what it is |
|---|---|---|
| [`run/process.nim`](../../src/ned/run/process.nim) | include 56 | Background jobs: run/build, checks, git |
| [`run/cerrors.nim`](../../src/ned/run/cerrors.nim) | include 58 | C compiler errors in emitted code: the generated C file (nimcache/@mfile.nim.c) → the line in the .nim |
| [`run/output.nim`](../../src/ned/run/output.nim) | include 59 | the Output panel's side of running commands: turning a running job's output into panel lines and problems (compiler messages with their file and line), starting, … |
| [`run/configs.nim`](../../src/ned/run/configs.nim) | include 60 | run configurations ("run.configs"): the project's ways to run, one of them chosen for Alt+R / ▶ |
| [`run/checks.nim`](../../src/ned/run/checks.nim) | include 61 | the check that runs when a file is saved: which checker command suits a language, running it as a background job and turning its output into the file's problems, and … |
| [`run/memcheck.nim`](../../src/ned/run/memcheck.nim) | include 248 | Run with memory checks: the program built with the compiler's address and undefined-behaviour checks (AddressSanitizer, UndefinedBehaviorSanitizer |
| [`run/configsui.nim`](../../src/ned/run/configsui.nim) | include 285 | Run › Configurations, run with arguments |
| [`run/tasks.nim`](../../src/ned/run/tasks.nim) | include 288 | Tasks: the project's Makefile targets, package.json scripts, just recipes, Taskfile tasks, cargo, go and nimble — one list (F4 runs the last one again, Shift+F4 … |

## sys

The operating system: processes, Windows, Landlock.

| file | | what it is |
|---|---|---|
| [`sys/landlock.nim`](../../src/ned/sys/landlock.nim) | module | Landlock (Linux 5.13 and newer): a process says what it — and every program it starts — may do with files and the network, and the kernel holds it to that for good |
| [`sys/heap.nim`](../../src/ned/sys/heap.nim) | module | The heap: how much of the memory ned's allocator holds its objects take, and giving back to the system what it holds but no longer uses |
| [`sys/winos.nim`](../../src/ned/sys/winos.nim) |  | ned on Windows: std/os with '/' in the paths it gives back |
| [`sys/winposix.nim`](../../src/ned/sys/winposix.nim) |  | ned on Windows: the POSIX calls ned makes, done with Win32 and the C runtime — imported as `posix` there, so the rest of ned stays one program |

## term

The terminal: its output, the built-in terminal emulator, keys and mouse read from it.

| file | | what it is |
|---|---|---|
| [`term/pty.nim`](../../src/ned/term/pty.nim) | include 143 | Integrated terminal: pseudo-terminal + xterm-subset emulator |
| [`term/shell.nim`](../../src/ned/term/shell.nim) | include 144 | shell integration: the shell marks each prompt, command line, output and exit code (OSC 133) |
| [`term/vt.nim`](../../src/ned/term/vt.nim) | include 145 | the terminal emulator's core: creating a terminal and its shell, the screen and scrollback, and the parser that turns what the shell prints (UTF-8, escape and CSI … |
| [`term/repltabs.nim`](../../src/ned/term/repltabs.nim) | include 146 | REPL tabs: code is typed in once the REPL shows its prompt |
| [`term/panel.nim`](../../src/ned/term/panel.nim) | include 147 | the terminal panel: reading the shells' output, drawing one terminal or two side by side with their tabs, command marks and scrollback, and handling their keys, … |
| [`term/repl.nim`](../../src/ned/term/repl.nim) | include 253 | Nim helpers: REPL, export marker, docs, nimble dependencies |
| [`term/termhost.nim`](../../src/ned/term/termhost.nim) | include 299 | Terminals that outlive ned (terminal.keepRunning) |

## testing

Test coverage and profiles read for the gutter.

| file | | what it is |
|---|---|---|
| [`testing/gcovdata.nim`](../../src/ned/testing/gcovdata.nim) | module | Nim test coverage, the parts that stand on their own (unit-tested in tests/unit/tgcov.nim): Nim's C (built with --lineDir:on) puts a `#line N "file.nim"` before each … |
| [`testing/runners.nim`](../../src/ned/testing/runners.nim) | include 200 | tests (std/unittest): explorer view, gutter ▶, run single tests |
| [`testing/testament.nim`](../../src/ned/testing/testament.nim) | include 201 | testament (the Nim compiler's test runner): a file whose first statement is a `discard """…"""` spec |
| [`testing/aitests.nim`](../../src/ned/testing/aitests.nim) | include 202 | tests the AI writes, kept only when they compile and pass |
| [`testing/explorer.nim`](../../src/ned/testing/explorer.nim) | include 203 | the test explorer: running every test of the project, the list of tests with their status in the side panel, and the run buttons (code lenses) shown on test lines in … |
| [`testing/onsave.nim`](../../src/ned/testing/onsave.nim) | include 204 | tests on save: the std/unittest file you save — or, saving a module, the test files that import it — compiled and run in the background (nim.testOnSave): ✓ / ✗ beside … |
| [`testing/aifixtest.nim`](../../src/ned/testing/aifixtest.nim) | include 218 | AI: fix a failing test — the test, its failure and the code it tests go to the model |
| [`testing/coverage.nim`](../../src/ned/testing/coverage.nim) | include 245 | Nim: test coverage, profiling, playground, compiler versions, docs browser, nimble view |
| [`testing/proctests.nim`](../../src/ned/testing/proctests.nim) | include 249 | Tests for this proc, from running it: the proc called with arguments its parameters' types suggest (0, 1, 42 |

## ui

Drawing and the interface: the frame, the editor view, docks, the panel, popups, pickers, menus, dialogs, the status bar.

| file | | what it is |
|---|---|---|
| [`ui/actions.nim`](../../src/ned/ui/actions.nim) | include 100 | Nim tooling, nimble/atlas/nimony, git, outline |
| [`ui/outline.nim`](../../src/ned/ui/outline.nim) | include 107 | the outline of files no language server outlines: by indentation and headings, JSON and JavaScript |
| [`ui/fieldsel.nim`](../../src/ned/ui/fieldsel.nim) | include 108 | one-line text fields (prompts, the picker's query, the dock's search, forms): the selection in them A field is its text variable: the selection belongs to the field … |
| [`ui/pickers.nim`](../../src/ned/ui/pickers.nim) | include 109 | Pickers (command palette, files, symbols, buffers, themes, languages) |
| [`ui/prompts.nim`](../../src/ned/ui/prompts.nim) | include 110 | Prompts (find, replace, goto, save as, run, search, file ops) |
| [`ui/themefiles.nim`](../../src/ned/ui/themefiles.nim) | include 113 | themes: the terminal's background (auto), your own theme files, importing VS Code and base16 themes |
| [`ui/promptkeys.nim`](../../src/ned/ui/promptkeys.nim) | include 116 | what the prompts do when answered, and their keys: the commands that start from a prompt or a folder (editing a theme's colours, opening a folder, moving a file) and … |
| [`ui/render.nim`](../../src/ned/ui/render.nim) | include 117 | A frame: the editor, docks, panel, popups and bars drawn in order |
| [`ui/icons.nim`](../../src/ned/ui/icons.nim) | include 118 | Desktop chrome: icons, clickable regions, tooltips, toasts, dialogs, menus |
| [`ui/regions.nim`](../../src/ned/ui/regions.nim) | include 119 | clickable regions (rebuilt every frame |
| [`ui/dialogs.nim`](../../src/ned/ui/dialogs.nim) | include 121 | notifications (toasts) and dialogs: showing one, asking yes or no, closing |
| [`ui/menus.nim`](../../src/ned/ui/menus.nim) | include 122 | drop-down and context menus: opening one, its width and scrolling, the keys and clicks in it |
| [`ui/fields.nim`](../../src/ned/ui/fields.nim) | include 123 | one-line fields drawn: the text in view, its selection, and the mouse in it (a press places the cursor, a drag selects, a double click a word, a triple click … |
| [`ui/popupdraw.nim`](../../src/ned/ui/popupdraw.nim) | include 124 | notifications, dialogs and tooltips drawn, and the keys in a dialog |
| [`ui/forms.nim`](../../src/ned/ui/forms.nim) | include 125 | forms: dialogs with fields, as a desktop app has them — check boxes, choices (a drop-down list), text fields, links, buttons |
| [`ui/layout.nim`](../../src/ned/ui/layout.nim) | include 127 | Layout: title bar · docks · tabs · breadcrumbs · editor · bottom panel · status |
| [`ui/menubar.nim`](../../src/ned/ui/menubar.nim) | include 128 | the menu bar's menus and their items (each a command), File › Open Recent, and a command run by its name |
| [`ui/titlebar.nim`](../../src/ned/ui/titlebar.nim) | include 129 | the title bar: the menu bar's names, the project's name, the window's buttons |
| [`ui/tabbar.nim`](../../src/ned/ui/tabbar.nim) | include 130 | the editor's tab bar: tabs drawn, scrolled, dragged and closed, each with its right-click menu |
| [`ui/breadcrumbs.nim`](../../src/ned/ui/breadcrumbs.nim) | include 131 | the breadcrumbs above the editor: the folders and symbols down to the cursor, each a menu of its neighbours |
| [`ui/docks.nim`](../../src/ned/ui/docks.nim) | include 132 | Docks: left (files · search · git · nim · tests) and right (assistant · outline · timeline) |
| [`ui/todosdock.nim`](../../src/ned/ui/todosdock.nim) | include 133 | TODO comments: open files, the project scan, the dock's list |
| [`ui/lists.nim`](../../src/ned/ui/lists.nim) | include 134 | the docks' lists — files, search results, git changes, tests, TODOs — built and drawn, and what a pick or a right click on an item does |
| [`ui/filetree.nim`](../../src/ned/ui/filetree.nim) | include 135 | the file tree: drawn, and its right-click menu |
| [`ui/dockframe.nim`](../../src/ned/ui/dockframe.nim) | include 136 | the docks' frames: headers and buttons, the search and replace rows, the keys in each dock |
| [`ui/panel.nim`](../../src/ned/ui/panel.nim) | include 137 | Bottom panel (problems · output · terminal · results), status bar, inputs, minimap |
| [`ui/statusbar.nim`](../../src/ned/ui/statusbar.nim) | include 138 | the status bar — mode, position, language, the chips for the engine, clangd, trust, a newer ned … — and the touch bar |
| [`ui/quickinput.nim`](../../src/ned/ui/quickinput.nim) | include 139 | quick input (prompts) and the find widget |
| [`ui/minimap.nim`](../../src/ned/ui/minimap.nim) | include 140 | the minimap: the file in small beside the editor, with its marks |
| [`ui/settingsui.nim`](../../src/ned/ui/settingsui.nim) | include 141 | settings UI: every option in one filterable list |
| [`ui/mdpreview.nim`](../../src/ned/ui/mdpreview.nim) | include 162 | the Markdown preview's renderer: paragraphs reflowed, headings, lists nested (task lists ☐ ☑), quotes nested (GitHub's > [!NOTE] too), tables with their columns lined … |
| [`ui/welcome.nim`](../../src/ned/ui/welcome.nim) | include 164 | the welcome page shown when nothing is open — logo, start actions, recent files, toolchain status and a tip — with its single-key actions |
| [`ui/codeline.nim`](../../src/ned/ui/codeline.nim) | include 166 | drawing one line of code in its syntax colours, without the cursor or selection, for places that show a line out of the editor (sticky headers, previews) |
| [`ui/doclines.nim`](../../src/ned/ui/doclines.nim) | include 168 | which inlay hints may be drawn on a line of the editor, and the tables that keep the Markdown previews' lines and the previews' and diffs' cursor lines between frames |
| [`ui/diffview.nim`](../../src/ned/ui/diffview.nim) | include 169 | a side-by-side diff: lines aligned, removed red on the left, added green on the right, changed words marked |
| [`ui/editorview.nim`](../../src/ned/ui/editorview.nim) | include 173 | drawing the editor's text area: the lines with their syntax colours, gutter, selections, matches, problems, guides, hints, sticky headers, scroll bar and the headers … |
| [`ui/popups.nim`](../../src/ned/ui/popups.nim) | include 174 | the popups drawn over the editor: the completion list with its documentation, the hover box, the picker (command palette, files, symbols …) with its preview, the … |
| [`ui/zen.nim`](../../src/ned/ui/zen.nim) | include 175 | zen mode: the editor alone, with the docks, panel and bars hidden, and only a quiet line of position info and messages at the bottom |
| [`ui/split.nim`](../../src/ned/ui/split.nim) | include 176 | panes (6.31: tiled) — the editor area cut into panes, as many as fit, by a tree of splits (PaneNode): each split side by side or one above the other, its divider … |
| [`ui/paneviews.nim`](../../src/ned/ui/paneviews.nim) | include 177 | (6.32) a terminal and the assistant in a pane of the editor, a tab among the files — beside the code rather than under it or in a dock: View › Panes › Terminal in a … |
| [`ui/contextmenus.nim`](../../src/ned/ui/contextmenus.nim) | include 178 | context menus: what a right click (or a long press) offers, wherever it lands — a text field, the gutter, the status bar and each of its parts, the title bar, a … |
| [`ui/frame.nim`](../../src/ned/ui/frame.nim) | include 188 | drawing one whole frame of the screen — the order everything is drawn in — and the terminal's pointer shape and window title that follow it |
| [`ui/gutter.nim`](../../src/ned/ui/gutter.nim) | include 208 | gutter clicks: fold markers and run buttons |
| [`ui/editormenu.nim`](../../src/ned/ui/editormenu.nim) | include 214 | opening a folder as the project, the editor's right-click menu, and scrolling by the mouse wheel in whichever part of the screen it is over |
| [`ui/dragdrop.nim`](../../src/ned/ui/dragdrop.nim) | include 215 | drag and drop (ui.dragAndDrop): a tab off the tab bar onto a pane or an edge (split there), a file or folder from the file tree onto the editor (opened — at an edge, … |
| [`ui/mouse.nim`](../../src/ned/ui/mouse.nim) | include 216 | drag handles (split divider, dock edges, bottom panel, scrollbar) and sizes from the keyboard |
| [`ui/compare.nim`](../../src/ned/ui/compare.nim) | include 258 | the diff tab's keys, the commands that compare a file with its last commit or with another file, and the command that opens a Markdown preview |
| [`ui/telescope.nim`](../../src/ned/ui/telescope.nim) | include 296 | Telescope: one finder for everything (as Neovim's telescope.nvim) — Alt+Shift+F, or *Telescope…* in the palette: a list of finders — files, live grep, symbols, … |

## web

Ned's own engines for CSS, HTML, SQL, JavaScript and JSON.

| file | | what it is |
|---|---|---|
| [`web/web.nim`](../../src/ned/web/web.nim) | module | ned's own engines for CSS, HTML, SQL, JavaScript and JSON — completion, hover and problems from what they know of the languages and of your project (its stylesheets' … |
| [`web/webui.nim`](../../src/ned/web/webui.nim) | include 291 | ned's own CSS, HTML, SQL, JavaScript and JSON in the editor: in .css / .scss / .less, .html, .sql, .js and .json files and where they are embedded (an HTML <style> or … |
| [`web/cssengine.nim`](../../src/ned/web/cssengine.nim) |  | ned's own CSS: where the cursor is (a selector, a property, its value …), what fits there, what a name is, and the mistakes a browser silently drops (an unknown … |
| [`web/htmlengine.nim`](../../src/ned/web/htmlengine.nim) |  | ned's own HTML: where the cursor is (a tag's name, an attribute, its value, text), what fits there, what an element or attribute is, and the mistakes a browser … |
| [`web/jsdata.nim`](../../src/ned/web/jsdata.nim) |  | data for ned's own JavaScript engine: the keywords, the standard, browser and Node globals, and the members of the objects scripts use most — names, signatures, one … |
| [`web/jsengine.nim`](../../src/ned/web/jsengine.nim) |  | ned's own JavaScript: its tokens (template and regex literals and all), the names a script declares and where they are seen (block scopes by braces), what fits at the … |
| [`web/jsonengine.nim`](../../src/ned/web/jsonengine.nim) |  | ned's own JSON: what is wrong with a file as you type (a missing comma, a comma too many, a key twice, a value a schema does not take), what a key or a value can be … |
| [`web/sqlengine.nim`](../../src/ned/web/sqlengine.nim) |  | ned's own SQL: the tables and columns your project creates (CREATE TABLE in .sql files and in the SQL of Nim strings), completion of tables after FROM / JOIN / INTO / … |
| [`web/webcommon.nim`](../../src/ned/web/webcommon.nim) |  | what ned's own CSS, HTML and SQL engines share: what they answer with, and small text helpers |
| [`web/webdata.nim`](../../src/ned/web/webdata.nim) |  | data for ned's own CSS, HTML and SQL engines: names, what they take, one line each |

## src/ned


| file | | what it is |
|---|---|---|
| [`version.nim`](../../src/ned/version.nim) | module | ned's version — one place for ned, nedfmt and nedls (and ned.nimble's `version`, kept the same) |
