# Editing

The text and everything that works on it: buffers, cursors, edits and undo, colours, wrapping, folding, big files,
encodings, saving — and how a key becomes a command.

## Buffers

A `Buffer` (in [`src/ned/core/types.nim`](../../src/ned/core/types.nim)) is an open file, or a tab without one. Its
text is `lines: seq[string]`, one string per line, without line ends. Next to the text it keeps everything that
belongs to that text: cursors, the undo history, the highlighting state per line, git's marks per line, folds,
inlay hints, bookmarks, the language, the encoding and line ends to write back, and a few markers that tell other
parts when to look again:

| field | what it tells |
|---|---|
| `id` | the buffer's number for its whole life (an index in `bufs` changes when tabs close or move) |
| `changeId` | bumped by every change of the text: anything worked out from the text remembers the `changeId` it was made for (`outlineAt`, `inlayAt`, `gitAt`, `chkAt` …) and is made again when they differ |
| `savedSeq` | the undo step that was saved: `dirty` is "the top undo step is not that one" |
| `path`, `title` | the file; or, for a tab that is not a file (a diff, generated C, a macro's expansion …), its name. `path == "" and title == ""` is an untitled buffer |
| `readOnly`, `libLocked` | not editable; `libLocked`: a file of the Nim toolchain or of an installed package, locked so it is not changed by accident |
| `hlStart`, `hlValid` | the lexer's state at the start of each line, and how far it is known ([Highlighting](#highlighting)) |
| `topLine`, `topSub`, `leftCol` | the view: the first line shown, the wrapped row of it, the first column when not wrapping |
| `large`, `viewer`, `hex` | large-file mode, the large-file viewer, the hex editor ([Big files](#big-files)) |
| `lspVersion`, `lspDirty`, `lspChangeAt` | what the language server has, and when the text last changed |

The procs that make and find buffers are in [`editor/buffers.nim`](../../src/ned/editor/buffers.nim): `openFile`
(open or go to a file, at a line; a folder becomes the project), `loadBuffer` (load without showing it),
`bufById`, `bufIndexByPath`, `pushJump` (the jump list behind Alt+,). Reading a file is `loadFile` in
[`editor/loadsave.nim`](../../src/ned/editor/loadsave.nim); closing, reloading and saving are in
[`editor/save.nim`](../../src/ned/editor/save.nim). `newBuffer` makes an empty one; the welcome page is an empty
buffer marked `welcome`.

Some buffers are views that save in their own way: a multibuffer (`multiBufs`), a commit message, an interactive
rebase's list, a plan for a changed signature. `saveBuffer` checks for those first.

## Positions, cursors and selections

A `Pos` is a line (from 0) and a column that is a **byte offset** into the line's UTF-8 — not a character count and
not a screen column. `clampPos` keeps a position inside the text and on the start of a character. Where a
character ends on screen is worked out by `core/text` (`visColOf`, `colAtVis`, `nextCluster`, `prevCluster`: a
whole character, an emoji sequence too).

A `Cursor` is an `anchor` and a `head` (the selection runs between them; equal: no selection) and the column a
vertical move aims for (`goalX`). A buffer has `cursors: seq[Cursor]` and the index of the primary one, `prim`.
`normalize` (in `editor/buffer.nim`) clamps every cursor, sorts them and merges the ones that overlap — call it after
changing `cursors` by hand. `setSingle(p)` leaves one cursor. Every editing command works on all the cursors;
`insertText` and `typeChar` (in [`editor/editing.nim`](../../src/ned/editor/editing.nim)) go through them from the
last to the first, so an edit never moves the places still to be edited.

Cursor movement is in `editor/motion.nim`; selection by structure (Alt+Shift+→ grows the selection to the
enclosing name, call, block …) in `editor/selection.nim`; multi-cursor commands (next occurrence, all occurrences, a cursor
per line) in `editor/navigation.nim` and `editor/editing.nim`.

## Edits and undo

**`replaceText(b, a, c, text)` is the one way to change a buffer's text** (in
[`editor/buffer.nim`](../../src/ned/editor/buffer.nim)). It replaces what lies between `a` and `c`, records the change
for undo when an edit group is open, and moves every cursor, snippet stop, bookmark, TODO mark, breakpoint and fold
that lies after the change. Under it, `rawReplace` changes `lines` and keeps the rest in step: `changeId` bumped, the
highlighting invalid from that line on, the language server told later (`lspDirty`), the problems' and the inlay
hints' lines shifted, git's per-line marks, the change logged for the [engine worker](engines.md#the-engine-worker),
large-file mode turned on when a line grows past `editor.longLineLimit`, and `needRender`. Loading or reloading a
whole text is `setContent` (in `editor/loadsave.nim`), which resets all of it. Writing `b.lines` directly skips every
one of these steps — see [Pitfalls](pitfalls.md#change-text-only-through-replacetext).

Edits are grouped into undo steps:

```nim
b.beginEdit()                      # (ekType for typing, ekDelete for deleting: consecutive ones merge)
discard b.replaceText(a, c, "new text")
b.endEdit()
```

An `UndoGroup` holds its edits (`EditOp`: where, the old text, the new text) and the cursors before and after.
Typing within 1.5 seconds merges into one step, stopping at the start of a word; `newGroup` forces a new step.
`undo` and `redo` replay the edits backwards or forwards through `rawReplace` and first check that the text is
still what the step left — if something changed the text outside the history, the history is cleared rather than
corrupting the file. The history keeps 2000 steps.

### The undo tree

An edit made after an undo does not throw away what was undone: `detachRedo` keeps the undone steps as a
**branch** (`undoBranches`, at most 64), hanging off the step where they left the line of edits.
[`editor/undotree.nim`](../../src/ned/editor/undotree.nim) lists every state the file has been in — on the line of
edits and on the branches, newest first, with a preview — in *Edit › Undo history…*; picking one goes there, and
the line of edits it leaves becomes a branch in turn. Each step carries a sequence number (`seqId`), so states can
also be walked in the order they were made.

With `editor.persistentUndo` the history (the last 300 steps and the newest branches) is written to the state
folder when a file is saved, and read back when the file is opened unchanged (`writeUndo` and `readUndo` in
`editor/swap.nim`).

## Highlighting

Highlighting is a **per-line state machine**: lexing a line takes the state at its start and gives the colour
kind (`TokKind`) of each byte and the state at its end.

```nim
let endState = lexLine(b.lang, b.lines[l], b.hlStart[l], toks)   # toks: one TokKind per byte of the line
```

`b.hlStart[l]` is the state at the start of line `l`, known for every line up to `b.hlValid`. An edit lowers
`hlValid` to the changed line; the lines below are lexed again only as far as needed. `ensureHl` makes the states
exact up to a line; `stateAt` answers for any line, and for a line far beyond what is known it lexes a 300-line
window before it instead (a jump to the end of a big file is instant), while `hlPump`, each round, makes the states
exact up to the screen a slice at a time. Drawing never lexes more than the lines it shows. A line over 20 000
bytes is not lexed. The bracket depth at each line start (`hlDepth`) is kept the same way, for rainbow brackets.

A state (`LexSt`, 32 bits) is the innermost lexer's own state in its low byte, and up to three **embedded
languages** above it: C in a Nim `{.emit.}`, SQL or HTML in a Nim string, JavaScript in an HTML `<script>`, the code
blocks of Markdown. `embeds` in `core/languages.nim` gives each kind of embedding an id; `lexInto` lexes the
embedded text with its own language up to where it ends. `langAt(b, p)` tells which language the code at a place
is in — completion, comments and bracket pairs use it.

| file | what it has |
|---|---|
| [`core/languages.nim`](../../src/ned/core/languages.nim) | the `Lang` table (`initLangs`): name, extensions, file names, comment markers, keywords, types, indentation rules, the language servers to try, the formatter, run/build/check commands; `detectLang` (by file name, extension, then `#!` line) |
| [`core/lexgeneric.nim`](../../src/ned/core/lexgeneric.nim) | `lexGeneric`: one lexer for most languages, driven by the `Lang`'s fields (comments, nested comments, quotes, triple quotes, keywords …) |
| [`core/highlight.nim`](../../src/ned/core/highlight.nim) | embedded languages, Markdown, HTML, regular expressions and PEGs in strings, strformat strings |
| [`core/lexers.nim`](../../src/ned/core/lexers.nim) | the lexers with a shape of their own (YAML/TOML keys, CSV columns, NIF, Nim source filters, Jinja templates), `lexHost` (which lexer a mode uses) and `lexLine` |

New languages from the `languages` setting and from plugins (`regLanguage`) are `Lang`s made by
`applyUserLanguages` (in `config/settings.nim`) and coloured by the generic lexer.

Over the lexer's colours come colours from understanding the code: Nim's from the engine (`nim/semantic.nim`:
a name coloured by what it is, after a pause in typing), other languages' from their language server's semantic
tokens (`lspSemFor`).

## Soft wrap

With `editor.softWrap`, a long line is shown on several rows. [`editor/softwrap.nim`](../../src/ned/editor/softwrap.nim)
cuts a line into segments (`wrapSegs`, `lineSegs`: at word ends, continuation rows indented like the line) and
counts a line's rows, inlay hints and rows drawn under a line (`VRow`: a notebook cell's output) included. The view
is `topLine` plus `topSub` (which row of that line is at the top); `ensureVisible` and `scrollBy` move it in rows.
For a very long line (minified code, a log on one line) the screen columns of every 16 KB are kept
(`VcMarks`), so a frame does not count columns from the start of a 5 MB line. Wrapping is off in large-file mode
and in CSV tables.

## Folding

`b.folds` lists the folded blocks as (header line, last hidden line).
[`editor/folding.nim`](../../src/ned/editor/folding.nim) works out a block from the language server's folding ranges
when it sent them, else from indentation (every language). `isHidden`, `nextVisible` and `prevVisible` in
`editor/buffer.nim` are what drawing and cursor movement ask; edits shift the folds (`shiftFolds`), and a cursor that
lands in a fold opens it (`revealCursor`).

## Big files

| size | what happens |
|---|---|
| any file over 8 MB that is text | read straight into lines, without a second copy (`setContentStream`) |
| ≥ `editor.largeFileSize` MB (16), or a line ≥ `editor.longLineLimit` characters (10 000) | **large-file mode** (`b.large`): no soft wrap, language server, minimap or word highlight; the palette's *Large file mode* turns them back on for the file (`largeOff`) |
| over 40 000 lines | no language server (typing stays instant); the Nim engine stops at 60 000 |
| > `editor.viewerSize` MB (512 at most) | the **large-file viewer** ([`editor/lfview.nim`](../../src/ned/editor/lfview.nim)): read-only, a window of the file's lines; the index of where lines start is made in the background, and search runs a slice at a time |
| a `\0` in its first 8000 bytes | a binary file: the **hex editor** ([`editor/hexedit.nim`](../../src/ned/editor/hexedit.nim)), with an executable's sections and symbols from `editor/binfmt` |

Nothing that draws a frame may depend on the file's size; the UI suite opens a million-line file
(`big_file()` in `tests/ui/harness.py`) to keep it that way.

## Encodings

The editor keeps every text as UTF-8. [`core/encodings.nim`](../../src/ned/core/encodings.nim) (a module) tells what
a file's bytes are — UTF-8 with or without a BOM, UTF-16 with its BOM, otherwise `files.encoding` (Windows-1252
unless you say) — and converts. UTF-8, UTF-16, Windows-1252 and Latin-1 are converted by ned itself; the others
(the encoding menu's list) through `iconv`. `b.enc` remembers the encoding, and saving writes the file back in it;
a character the encoding cannot hold stops the save and shows where it is. Line ends are kept too (`crlf`;
`mixedEol` warns), and so is a missing newline at the end (`noEol`). The status bar's encoding menu is
`editor/encodingcmds.nim`.

## Saving

`saveBuffer` in [`editor/save.nim`](../../src/ned/editor/save.nim), in order:

1. buffers that save in their own way (multibuffer, commit message, rebase list, a plugin's tab, the hex editor);
2. never silently over someone else's work: a file changed on disk since it was read, a read-only file, a file
   another ned is editing — each asks first;
3. the plugins' "before save" events, format on save, trailing spaces and the final newline (`.editorconfig` or
   the settings), the text joined with its line ends and encoded;
4. the version on disk kept in the local history (`snapshotHistory`, *File › Local history*), then
   `writeFileSafe` ([`editor/safewrite.nim`](../../src/ned/editor/safewrite.nim)): a temporary file in the same
   folder, `fsync`, and a rename over the original — a phone that dies mid-save keeps the old or the new file,
   never half of one. It keeps the file's mode, writes through symbolic links and keeps hard links shared;
5. the recovery file removed, the undo history written, and everything that follows a save: the settings applied
   (when it is the settings file), the language server told, the compiler's check, the tests on save, git's marks,
   the plugins' events — and a remote folder's file sent to the server.

Unsaved work is kept safe in three more ways: **recovery files** (`editor/swap.nim`: written a moment after
typing stops, one per file and ned process, offered back by `editor/recovery.nim` after a crash), **hot exit**
(`editor/hotexit.nim`, `files.hotExit`: quitting keeps the unsaved edits for next time), and an emergency save of
every buffer when ned crashes or the terminal goes away. See [Safety](../guide/safety.md).

## Multibuffers

A multibuffer ([`editor/multibuffer.nim`](../../src/ned/editor/multibuffer.nim)) is one editable buffer made of
pieces of several files: search results, problems, git's changes. `openMultibuffer(title, hits, context)` makes
it: each piece starts with a header line `§ path:line` (in the language's comment), followed by the lines.
`multiBufs[b.id]` keeps each piece's file, first line and original lines (`MbSection`); `openMultibufferOf` makes
one from ranges of lines (the plugin API's `openMultibuffer`).

- Saving (`saveMultibuffer`) splits the buffer at the headers again and writes only the pieces that were edited,
  each where its original lines are now in the file (`mbFind`: lines added or removed above it moved it). It refuses
  when a header was edited, or when an edited piece's own lines were changed in the file too.
- A multibuffer without edits of its own follows its files: `mbPump` (the main loop, twice a second) compares the
  files' versions (`mbSignature`: an open buffer's `changeId`, else the time on disk) and, when a piece's lines are
  no longer where they were, `mbRefresh` re-anchors every piece (`mbAnchor`) and `mbRebuild` makes the text again
  — with `setTextMinimal`, so the cursor stays, and with the undo history cleared: an undo would bring back text
  the pieces no longer match.
- `mbPieceAt`, `mbPlace` and `mbLineOf` map between a line of the multibuffer and a line of a file; the gutter shows
  the files' line numbers (`mbSourceLines`); F12 goes to the definition through the file (`mbDefinition`).
- Enter on a header opens the file there; its ⇡ ⇣ ✕ buttons grow the piece (`mbMore`) or take it out
  (`mbRemovePiece`); `mbAddRange` adds lines of a file to the multibuffer in use (`mbLast`).

## Keymaps: vim, emacs, helix

`editor.keymap` picks the keys: `default`, `vim`, `emacs` or `helix` (with `editor.vimMode` the old way to turn vim
on). Each keymap is a function that may take a key before the default handling and returns `true` when it did:

| keymap | files | entered from |
|---|---|---|
| vim | [`keymaps/vim.nim`](../../src/ned/keymaps/vim.nim) (modes, motions, text objects, operators, registers), [`keymaps/vimex.nim`](../../src/ned/keymaps/vimex.nim) (the `:` line — `vimEx` runs one, `vimExComplete` completes one, `vimSet` is `:set`), `keymaps/vimkeys.nim` (`vimKey`, the key handling) | `vimEditorKey`, at the start of `editorKey` |
| helix | [`keymaps/helix.nim`](../../src/ned/keymaps/helix.nim) (select, then act) | `helixEditorKey`, after vim's |
| emacs | [`keymaps/emacs.nim`](../../src/ned/keymaps/emacs.nim) (C-x and M-g prefixes, the mark, kills) | `emacsKey`, in `handleKey` before the global keys |

Their state is in `core/state.nim` (`vimMode`, `hxMode`, `emacsPrefix` …). Macros (`editor/macros.nim`) record keys;
plugins can add vim mappings, operators and text objects (`plugVimKey` in `plugins/host.nim`).

## The keyboard and command dispatch

### From bytes to keys

`readInput` and `parseKey` in [`core/keys.nim`](../../src/ned/core/keys.nim) turn the terminal's bytes into `Key`s:
characters (UTF-8), control keys, escape sequences (arrows, function keys, modifiers), SGR mouse reports,
bracketed paste (one `kPaste` key with the text), the kitty keyboard protocol when the terminal speaks it, and the
terminal's answers to ned's questions (colours, capabilities), which are taken out of the stream and handed to
`core/termcaps.nim`. A lone ESC waits briefly for the rest of a sequence.

### handleKey

`handleKey` in [`src/ned/app/keyboard.nim`](../../src/ned/app/keyboard.nim) decides where a key goes, in this order:

1. a mouse event → `handleMouse` ([Rendering](rendering.md#regions-how-a-click-finds-its-target));
2. a key being captured for *Keyboard shortcuts…*; jump labels on screen;
3. whatever is open in front: a dialog, a menu, a form, the key help, the replace bar, the picker, a prompt;
4. views with keys of their own: a diff, a picture, the hex editor, the rename preview, a flame graph, Compiler
   Explorer, the git graph, blame, a multibuffer's headers;
5. Ctrl+Alt+arrows (resize), the terminal when it has the focus;
6. `customKey`: your `keys` setting, then the keys plugins gave their commands;
7. the emacs keymap; `globalKey` (Ctrl+S, Ctrl+P, Alt+X …);
8. by focus: the left dock (`sideKey`), the right dock (`rightKey`), the panel, or the editor (`editorKey`: AI
   suggestions, next-edit suggestions, vim and helix, the completion list, then the editing keys).

### Commands

Every command of the palette is a `Command` (name, the keys shown beside it, an action) added in `initCommands` in
[`src/ned/app/commandlist.nim`](../../src/ned/app/commandlist.nim) (and `initCommandsV4` in `app/setupcheck.nim`):

```nim
add("Format document", "Alt+F", buf().formatBuffer())
```

`runCmd(name)` runs one by name (the menus, your `keys` setting, `--remote-command`, plugins); `cmdByName` finds it.
The keys text is what the palette shows, and `keyTokens` reads it to tell which command owns a key (*Keyboard
shortcuts…* warns about a key two commands claim) — but the key itself is handled by `globalKey` or `editorKey`,
not by this text. `ned --doc-commands` writes [docs/reference/commands.md](../reference/commands.md) from the list.

### Menus

The menu bar ([`src/ned/ui/menubar.nim`](../../src/ned/ui/menubar.nim)) builds each menu when it opens
(`menuItems(i)`), mostly from commands: `mc("Command name", "Shorter label")` makes an item that runs the command and
shows its keys. A name that matches no command gives a disabled item. Context menus (right click) are built in
`ui/contextmenus.nim` and `ui/editormenu.nim` with `mi`, `msep` and `msub`.

[Recipes](recipes.md#add-a-command-a-key-and-a-menu-item) has the steps to add a command, a key and a menu item.

## More editing parts

| part | where |
|---|---|
| find and replace in the file | `editor/find.nim`, `editor/findreplace.nim`, the regular expressions in `editor/regex.nim` |
| search and replace in the project | `editor/search.nim` (ripgrep, else grep, else ned's own search a slice at a time), `editor/projectreplace.nim` |
| completion | `editor/completion.nim` (the list, filtering, ranking), filled by the engines, servers and plugins |
| snippets, surround, Emmet | `editor/snippets.nim`, `editor/surround.nim`, `editor/html.nim`, `editor/emmetcss.nim` |
| bookmarks, local history, recovery | `editor/bookmarks.nim`, `editor/localhistory.nim`, `editor/localhistoryview.nim`, `editor/recovery.nim` |
| clipboard | `editor/clipboard.nim` (the system's: OSC 52, and Termux:API, pbcopy, wl-clipboard or xclip when there) |
| spell check | `editor/spell.nim`, `editor/spelldicts.nim` |
| CSV tables, notebooks | `editor/csv.nim`, `editor/notebook.nim` |
