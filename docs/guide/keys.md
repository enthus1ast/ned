# Key bindings

In Termux, Alt comes from the extra-keys row (or a hardware keyboard). Every binding is listed in **F1** and in the palette, and you
can add your own (see [Settings](settings.md#settings)).

## Window and layout

| keys | action |
|---|---|
| F10 | menu bar (while debugging: step over — Shift+F10 opens the menus) |
| Ctrl+E / Alt+X | command palette |
| Ctrl+B | left dock (Files · Search · Git · Nim · Tests; Tab cycles) |
| Alt+C | AI assistant (right dock) · Alt+I outline |
| Ctrl+\\ / Alt+` | integrated terminal · Alt+O bottom panel |
| Ctrl+↑ / Ctrl+↓ (in the terminal) | the commands you ran · Alt+Enter: its output, run it again … · Ctrl+PgUp/PgDn the other terminal |
| Alt+\\ | split the editor / switch panes · Alt+\| close the split |
| Ctrl+Alt+←/→ · ↑/↓ | resize the split or the focused dock · the bottom panel (↑ taller) · ⤢ or *Toggle maximized panel* fills the window with it |
| F6 / Shift+F6 | move focus editor → docks → panel |
| Alt+Z | zen mode (Esc Esc leaves) |
| Alt+T | themes (live preview) · Alt+W soft wrap · Alt+L line numbers · Alt+U mouse on/off |
| right click | context menus everywhere: the editor, its gutter, tabs, files, every dock's items, the status bar's items, the title bar, breadcrumbs, the minimap, the panel, messages, text fields, a picker's rows — on touch: press and hold |
| drag | split divider, dock edges, the bottom panel's header, the scrollbar, the minimap, a tab (reorder — or out of the tab bar: onto a pane, or to the editor's right or bottom edge to split with it) · a file from the tree: into the editor (opened, or split at the edges), onto a folder (moved, after asking), into the terminal (its path) · selected text: moved (Ctrl or Alt held: copied) — `ui.dragAndDrop` |
| text fields | click places the cursor, drag or Shift+arrows select, double-click a word, triple-click all, Ctrl+A/C/X/V, right-click for Cut/Copy/Paste |
| wheel | scroll · Shift+wheel or tilt wheel: sideways · over the tabs: switch tabs |

## Files and navigation

| keys | action |
|---|---|
| Ctrl+P / Ctrl+O | find file (`:` line · `@` symbol · `#` project symbol · `>` command) |
| Ctrl+N · Ctrl+W | new file · close tab |
| Ctrl+S · Ctrl+Q | save · quit (asks about unsaved files) |
| Alt+← Alt+→ · Ctrl+PgUp/PgDn · Alt+1..9 | switch tabs |
| Ctrl+G | go to line[:col] · Ctrl+T symbol in file |
| Alt+. / F12 / Ctrl+click | go to definition · Alt+, jump back · Alt+< go forward |
| Alt+F12 · Alt+Shift+F12 | peek definition · peek references |
| Alt+Shift+T | reopen the last closed tab |
| Alt+Shift+J | jump labels: a letter over every word on screen, type it to go there |
| Alt+Q / Shift+F12 | find all references |
| Alt+H | hover info (also automatic) |
| Alt+N / Alt+P / F8 | next / previous problem |
| Alt+' | toggle bookmark · Alt+; next · Alt+: previous |
| Alt+V / Alt+Shift+V | next / previous TODO · FIXME · BUG · HACK · NOTE comment (View › TODOs lists and counts them) |
| F7 / Shift+F7 | next / previous git change · click the branch in the title bar: branches · ⟳ sync |

## Editing

| keys | action |
|---|---|
| Ctrl+Z / Ctrl+Y | undo / redo |
| Ctrl+C / X / V | copy / cut / paste (whole line when nothing is selected) |
| Ctrl+A · Ctrl+L | select all · select line |
| Ctrl+D · Alt+A | next occurrence · all occurrences (multi-cursor) |
| Alt+J / Alt+K · Alt+Shift+↑↓ | add cursor below / above · Esc back to one cursor |
| Alt+click · Alt+drag | add a cursor · box (column) selection |
| Alt+Shift+→ / ← | grow / shrink the selection by the code's structure (name, call, argument, statement, block, routine) |
| Alt+Shift+S | surround: brackets, quotes, a tag or a block around the selection (*Edit › Surround* also changes or deletes a pair) |
| Alt+Shift+U | undo history: every state of the file, the undo tree's branches too, with the text there |
| Tab on a → … ⇥ hint | next edit: to the place, then the same change there (Esc: no) |
| Alt+Shift+G | Git › Changes: every change not committed in one editable view |
| Alt+↑ / Alt+↓ · Alt+D | move line(s) · duplicate |
| Alt+Shift+R · Alt+Shift+M | record a keyboard macro (again: stop) · play it — *Edit › Macros* for N times, each line, saved ones |
| Ctrl+K · Ctrl+/ | delete line(s) · toggle comment |
| Tab · Shift+Tab | indent / unindent the selected lines (Shift+Tab: the cursor's line too) — also *Edit › Indent lines* and *Unindent lines*, the palette ("unindent", "outdent", "dedent"), ⇥ ⇤ on the touch bar; vim: `>>` `<<`, `>` `<` in visual mode, Ctrl+T / Ctrl+D in insert mode |
| Alt+- / Alt+= | fold / unfold (or click ▾ ▸) |
| Tab after a keyword | snippet (Tab / Shift+Tab walk the fields) |
| Ctrl+Space | completion |
| Alt+F | format document (with lines selected: just those) · F2 rename symbol |
| Alt+Enter · Ctrl+. | quick fixes (Nim: fixes for the compiler's errors and warnings, missing case branches, generate $/==/hash, doc comment, run selection, debug this test) — also the right-click menu and Edit › Quick fix…; Windows Terminal keeps Alt+Enter for full screen: there Alt+Shift+Enter |
| F2 | rename — a preview lists every change first (Space unticks, Enter applies) |

## Search

| keys | action |
|---|---|
| Ctrl+F | find (Enter next · Shift+Enter previous · Alt+C case · Alt+W whole word · Alt+R regex) |
| Ctrl+R | replace — then Yes / No / All / Done (y n a q) |
| F3 / Shift+F3 | next / previous match |
| Alt+S | search the project (Search dock) |
| Alt+H (in the Search dock) | show the replace box · Alt+Enter replace all · Tab moves between boxes |

## Run, test, debug

| keys | action |
|---|---|
| Alt+R / F5 | run the current file · Alt+B / Shift+F5 build or check |
| F9 · click the gutter's left edge | toggle a breakpoint (then F5 starts the debugger) · palette: conditional breakpoint, logpoint, stop when this changes |
| F5 · F10 · F11 · Shift+F11 · Shift+F5 | while debugging: continue · step over · step in · step out · stop |
| in the Debug panel | Enter on ▸ expands a variable · *+ add a watch expression* · Enter on a watch (or a *stop when it changes*) removes it |
| Ctrl+F10 | debugger: run to cursor (starts debugging if needed) |
| ▶ in the gutter | run a test, a suite, `when isMainModule`, a nimble task |
| Alt+Y | nimble tasks · Alt+E Nim dock |
| palette | Debug: … · Nim: debug with gdb (in the terminal) · Run tests in file · Run all tests · Stop |

## AI

| keys | action |
|---|---|
| Alt+C | chat (Enter sends, Alt+Enter new line, ↑ history, Ctrl+L new chat, Esc stops) |
| Alt+Shift+C | edit the selection — or the enclosing block — with an instruction |
| y · a · n | allow · always allow · deny an agent action |
| Tab (in the chat box) | complete a `/command` or `@mention` |
| Tab (in the editor) | accept an inline suggestion (when enabled) · Esc dismisses it |

## Hex editor (a binary file)

| keys | action |
|---|---|
| 0-9 a-f · any key | type over a byte in the hex column · in the text column |
| Tab | hex column ⇄ text column |
| Insert | insert mode (typing adds bytes) ⇄ overwrite |
| Delete · Backspace | take bytes away (Backspace: the one before, in insert mode) |
| Shift+arrows · Ctrl+A | select bytes · all of them |
| Ctrl+C · Ctrl+X · Ctrl+V | copy as hex (as text in the text column) · cut · paste hex (`de ad`, `0xde, 0xad`) or text |
| Ctrl+G | go to an offset: `8000`, `0x1F40`, `1f40h`, `+16`, `-0x10` |
| Ctrl+F · F3 · Shift+F3 | find bytes (`de ad be ef`) or text (`"abc"`) · the next · the one before |
| Ctrl+Z · Ctrl+Y · Ctrl+S | undo · redo · save |

Palette: *Hex: symbols…*, *Hex: sections…*, *Hex: Nim modules by size*, *Hex: open the Nim source of the proc at the
cursor*, *Hex: copy as a Nim array / a Nim string / a C array*, *Hex: show as text*.
