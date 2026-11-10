# Editing

What ned does to the text, beyond typing it. The keys are all in [Key bindings](keys.md); every action here is
also in the **Edit** menu and the palette (Ctrl+E). With vim, Emacs or Helix keys, see
[Vim mode and zen mode](vim-and-zen.md).

## Cursors and selections

- **Several cursors.** Ctrl+D selects the next place the selected word (or the word under the cursor) appears, with
  a cursor of its own; Alt+A all of them at once. Alt+J and Alt+K (or Alt+Shift+↓ ↑) add a cursor on the line below
  or above, Alt+click adds one where you click, Alt+drag selects a box (columns). What you type, delete or paste
  happens at every cursor; Esc goes back to one.
- **Growing the selection by the code's structure.** Alt+Shift+→ selects the name under the cursor, then the member
  chain (`a.b(c).d`), what a pair of brackets or quotes holds and then the pair, one argument, the statement, the
  block, the block with its header, the whole declaration (with the comments above it) and the file;
  Alt+Shift+← goes back a step. It goes by brackets, quotes and indentation, so it works in every language.
- **Copy and cut with nothing selected** take the whole line, and paste puts it back as a line.
- **Copying by touch** (Termux): a double tap selects a word, a triple tap the whole line — a long one too, all of
  its rows — and while something is selected, **⧉ Copy** in the status bar puts it on Android's clipboard as it is
  in the file. Termux's own long press copies what the screen shows instead: a long line comes with a line break
  where it wraps, and the ↪ and the line numbers.
- **Jump labels** (Alt+Shift+J): a letter appears over every word on the screen; type it to go there.
- **Bookmarks**: Alt+' marks the line (a sign in the gutter), Alt+; and Alt+: go to the next and the one before,
  *Bookmarks: list…* shows them all. They are kept with the folder's session.

## Changing text

- **Move and duplicate**: Alt+↑ / Alt+↓ move the line (or the selected lines), Alt+D duplicates them, Ctrl+K
  deletes them, Ctrl+/ comments them in or out — in the comment style of the language.
- **Indent and unindent**: Tab indents the selected lines one level, Shift+Tab takes them (or the cursor's line)
  one level out. The same are *Indent lines* and *Unindent lines* in the Edit menu and the palette (it finds
  "unindent", "outdent" and "dedent"), and ⇤ on the touch bar (in its default keys; add ⇥ with `indent` in
  `ui.touchBarKeys`). In vim mode: `>>` and `<<` (with a count), `>` and `<` in visual mode, and
  Ctrl+T / Ctrl+D while inserting.
- **Surround** (Alt+Shift+S): put brackets, quotes, an HTML tag or a block (`if`, `try`, `block:` … in Nim) around
  the selection. *Change the surrounding pair…* and *Delete the surrounding pair* work on the pair around the
  cursor. In vim mode, vim-surround's `ys`, `cs` and `ds` do the same.
- **Text transforms**: *Sort lines*, *Join lines*, *Upper case*, *Lower case*, *Trim trailing whitespace*; *Indent
  with 2 spaces / 4 spaces / tabs* re-indents the file, *Toggle line endings (LF/CRLF)* changes how lines end.
- **Auto-pairs and indentation**: a bracket or quote closes itself (`editor.autoClosePairs`), Enter indents the next
  line as the language expects (after a `:` in Nim and Python, a `{` in C …), and in a doc comment Enter starts the
  next line with `##`, `///` or ` * ` (`editor.continueComments`). Pasted code takes the indentation of where it
  goes (`editor.formatOnPaste`). In Nim a closing bracket typed alone on its line goes back to the line that opened
  it, and `of`, `elif`, `else:`, `except`, `finally:` typed at the start of a line go back to their `case`, `if` or
  `try` (`editor.autoDedent`).
- **Snippets**: Tab after a keyword (`proc`, `for`, `test`, `def`, `fn` …) writes the whole construct; Tab and
  Shift+Tab move through its fields. Nim, Python, C, C++, JavaScript/TypeScript, Rust, Go, HTML and shell have
  snippets; yours go in the `snippets` setting — `{"nim": {"dbg": "echo \"${1:x} = \", $1"}}` (`"*"` for every
  language). *Insert snippet…* lists them.
- **Emmet** in HTML and CSS: Tab after `ul>li.item*3` writes the list (`editor.emmet`). Renaming an opening HTML
  tag renames its closing one too (`editor.linkedEditing`).
- **Next-edit suggestions**: after you rename something by hand (`width` → `size`), the next place that still has
  the old name shows `→ size ⇥`; Tab goes there, Tab again makes the same change, Esc says no (`editor.nextEdit`).
- **Completion** appears as you type (`editor.autoComplete`; Ctrl+Space always works), with the documentation of
  the selected item beside the list. The [Nim IDE](nim.md) and [C and C++](c.md) guides say what their completion
  knows.

## Undo

Ctrl+Z and Ctrl+Y undo and redo. ned keeps an **undo tree**: when you undo and then type something else, what you
undid is kept as a branch. *Undo history…* (Alt+Shift+U) lists every state the file has been in — the other
branches too, newest first — with the text there; picking one goes to it. The history is kept after you
close the file, and after you quit (`editor.persistentUndo`), as long as nothing else changed the file in between:
the steps nearest to the text first, up to 4 MB in all. While a file is open its history holds at most 64 MB (8 MB
when memory is short), the oldest steps going first. For older versions, see *Local history* in [Safety](safety.md).

## Keyboard macros

Alt+Shift+R starts recording the keys you press; Alt+Shift+R again stops. Alt+Shift+M plays it. **Edit › Macros**
also plays it N times, once on each selected line, or again and again to the end of the file (it stops when it
changes nothing more); *Save the last one…* gives it a name — then it is a palette command, `Macro: <name>`, that
the `keys` setting can bind to a key. Saved macros are in `~/.config/ned/macros.json`.

## Folding

Alt+- folds the block at the cursor and Alt+= unfolds it; a click on ▾ or ▸ in the gutter does the same. *Fold
all*, *Unfold all* and *Fold level 2* work on the whole file. Folding follows the indentation (and a language
server's folding ranges, when it has them); `editor.folding` turns it off. A jump into a folded part — go to
line, a definition, a symbol, a problem, a picked result, back and forward — opens it.

## Looking at the code

- **Soft wrap** (Alt+W) wraps long lines at the edge of the window (`editor.softWrap`). Line numbers: absolute,
  relative or off (Alt+L).
- **Rulers** at the columns you choose — `"editor.rulers": [80, 120]`, or `["lineLength"]` for where the formatter
  wraps — and the part of a line past the last one tinted (`editor.rulerTint`). *View: set ruler columns…*.
- **Sticky scroll** keeps the headers of the proc and the type you are in at the top; **indentation guides**,
  **rainbow brackets**, the **minimap** (with what the find box finds marked at its right edge, and git's changes —
  added, changed, deleted lines — at its left), the **word under the cursor** highlighted everywhere it appears —
  each one its own setting, and each one in **View**.
- **Breadcrumbs** (the bar under the tabs): a tap on a folder lists what is in it — pick a file to open it; a tap on
  a symbol (the proc, the type you are in) lists the declarations beside it in the same block — pick one to go
  there.
- **Colour swatches**: a small block in the colour before `#RRGGBB`, `rgb(…)`, `hsl(…)` and Nim's `0xRRGGBB`; a
  click copies the colour in another notation, or makes it lighter or darker.
- **Ligatures** (`editor.fontLigatures`): `->`, `=>`, `!=`, `<=`, `>=` drawn as one symbol by ned in any terminal
  (`symbols`), or kept together for a ligature font to draw (`font`).
- **Inactive code** — a Nim `when` branch that is false on this platform — is dimmed (`editor.dimInactiveCode`).

## Markdown

*Markdown: open preview to the side* (View › Markdown preview) shows the file rendered beside it, and
follows it: the line at the cursor is at the same height in the preview, marked ▎, as you move or scroll. It has
headings, paragraphs reflowed to the width, **bold**, *italics*, ~~struck~~ and `code`, code blocks, quotes, lists
(nested, numbered, and task lists as ☐ and ☑), tables (box-drawn, the columns aligned as the `|:--|--:|` line says,
long cells wrapped), GitHub's notes (`> [!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]`, `[!CAUTION]`), and
pictures (drawn in the text's cells, as in [the picture view](hex-and-binaries.md#pictures)). A tap on a link opens
it: a heading of the file (`#setup`) goes there, a web address opens in the browser, another file opens beside.

## Spell check

Misspelled words are underlined in Markdown files and commit messages (`editor.spellCheck`: off, markdown, or on —
then also comments and strings in code). Alt+Enter on a word suggests the spelling; *Spell check: add the word at
the cursor to your dictionary* puts it in `~/.config/ned/words.txt`, *Spell check: next misspelled word* goes on. `editor.spellLanguage` chooses the dictionary (a hunspell dictionary, or *Spell check:
download a dictionary…*).

## Files in other encodings, and big files

- A file that is not UTF-8 is read in its own encoding — UTF-16 (from its BOM), Windows-1252 or what
  `files.encoding` says — and written back the same way. *File: reopen with encoding…* and *File: save with
  encoding…* change it.
- `.editorconfig` is followed: indentation, tab width, line ends, trailing whitespace, the final newline and
  `max_line_length` (`editor.editorConfig`). Trailing spaces are taken off the lines you changed when you save
  (`editor.trimTrailingWhitespace`).
- **Large files**: from 16 MB (`editor.largeFileSize`), or with a line longer than 10 000 characters (minified
  JSON, a one-line log), ned leaves out soft wrap, the language server, the engine and the minimap so that scrolling
  and typing stay instant; *Large file mode: on/off for this file* switches it by hand. A file bigger than 512 MB
  (`editor.viewerSize`) opens in the **large-file viewer**: read-only, with only the part on the screen in memory,
  but Go to line, Ctrl+End and search reach all of it.
- **CSV and TSV** files are shown as a table, the columns lined up (*CSV: toggle lining the columns up*); *CSV: sort
  by this column* (the heading row stays at the top) and *CSV: summary of this column* — the count, the sum, the
  smallest, the largest, the mean and the most common values.
- **Binary files** open in the hex editor — see [Hex editor and programs](hex-and-binaries.md).

## Editing many files at once

- *Open results in a multibuffer* (after a project search) puts every hit, with the lines around it, in one
  editable view; Ctrl+S writes each change back to its file. *Problems: all of them with their code* does the same
  for the problems, and *Git › Changes* (Alt+Shift+G) for every change you have not committed — see
  [Search and replace](search.md) and [Git](git.md).
- F2 renames a symbol in every file, with a preview of each change first (`editor.renamePreview`).
- *Format all* formats the whole project — see [Formatting](formatting.md).

## Saving

Ctrl+S saves; *Save all* saves every file. Saving is safe: ned writes a new file and puts it in place, so a full
disk or a crash never leaves half a file, and it never overwrites a file someone else changed without asking
([Safety](safety.md)). `editor.autoSave` saves when you switch tabs or leave ned, `editor.saveOnFocusLost` when you
switch to another window, `editor.formatOnSave` formats first. With `files.hotExit` (the default) you can quit
with unsaved edits: they come back, still unsaved, the next time you open the folder.
