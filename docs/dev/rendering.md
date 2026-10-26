# Rendering

How ned draws a frame and gets it onto the terminal, how a click finds what was drawn under it, and where the
colours come from.

The idea in one paragraph: every frame draws the **whole screen** into an array of cells, as if from nothing. Then
it compares that array with what the terminal already shows and sends only the difference. Drawing is cheap
(a few milliseconds even on a phone); what is expensive is the bytes the terminal has to read and paint — on
Termux, over SSH, in a slow emulator. So the drawing code can stay simple (no "what changed?" bookkeeping in each
widget), and the diff keeps the bytes small.

## One frame: render()

`render` in [`src/ned/ui/frame.nim`](../../src/ned/ui/frame.nim) is called by the main loop when `needRender` is set
([Architecture › Frame pacing](architecture.md#frame-pacing)). It:

1. resets what each frame sets again: the list of clickable regions, the cursor's place, `modalStart`,
   `overlayStart`, the picture to show (`gfxNow`);
2. fills the screen with the theme's background (and stops with "window too small" under 16 × 5);
3. works out the layout (`computeLayout`, [below](#the-layout));
4. draws, from the bottom up: the tab bar, the panes (or the breadcrumbs and the editor), the minimap, the bottom
   panel, the docks — then `overlayStart` is set — the title bar, the status bar, the touch bar, signature help,
   the completion list, the hover, the find bar or a prompt, the picker, the key help, the which-key hints, the
   toasts, a drag in progress, a form, the menus, a dialog, a tooltip;
5. hides the cursor when a menu or dialog is over it, and drops the terminal-drawn picture when anything covers it;
6. calls `flushScreen`, then sets the mouse pointer's shape and the terminal's title when they changed.

What is drawn later lies on top. Keys follow nearly the same order: `handleKey` gives a key first to a dialog,
then a menu, a form, the help, the replace bar, the picker, a prompt — and only then to the editor
([Editing › Keys](editing.md#the-keyboard-and-command-dispatch)).

## The cell grid

[`src/ned/core/screen.nim`](../../src/ned/core/screen.nim) owns the screen; the arrays are declared in
`core/state.nim`:

| | |
|---|---|
| `grid: seq[Cell]` | the frame being drawn, `scrW × scrH`, row by row |
| `prevGrid: seq[Cell]` | what the terminal shows now (empty: not known — the next frame repaints everything) |
| `Cell` | `ch` (a code point), `fg` and `bg` (`Rgb`, `0xRRGGBB`), `at` (bold, dim, italic, underline, reverse, strike, curly underline and its colour) |
| `NoColor` | `0xFF000000`: the terminal's own default colour |

The drawing primitives: `setCell`, `fillRect`, `putStr` (UTF-8 text, clipped, wide characters taking two cells),
and in [`ui/regions.nim`](../../src/ned/ui/regions.nim) `drawFrame` (a rounded box with a title and a shadow),
`button` and `pill` (a clickable label that registers its region), `shadeRect` and `dropShadow`. `blend(a, b, t)`
in `core/themes.nim` mixes two colours; most of ned's in-between shades are made with it.

A wide character (CJK, most emoji) takes two cells: the second has `ch = 0`. `setCell` repairs a wide character
when one of its halves is overwritten. A character made of several code points (an accent, a joined emoji
sequence) is one cell whose `ch` is an index into a pool of such strings (`cellOf` in `core/text.nim`, values from
`PoolBase` up); `render` empties the pool when it passes 50 000 entries and repaints everything.

`prevGrid.setLen(0)` forces a full repaint. Settings that change how cells are written (italics, a transparent
background, accessibility mode's ASCII glyphs) do it; so do a resize and the command *Redraw the screen*.

## flushScreen: the diff

`flushScreen` builds one string and writes it in one go, inside synchronized output (`ESC [?2026h … l`, so a
terminal that knows it paints the frame at once):

1. **Scrolling by the terminal.** When the editor's text moved up or down (render sets `scrollHint`),
   `termScroll` hashes each row of the old and the new editor area, finds the shift that lines up the most rows,
   and — when that saves enough — sets a scroll region and lets the terminal move the rows it already shows
   (newlines or reverse index), as vim and less do. `prevGrid` is moved the same way, so the diff after it sends
   only the new lines. `ui.terminalScroll` turns it off.
2. **Rows.** A row equal to what the terminal shows costs one `memcmp`. In a changed row, the cells from the first
   to the last difference are sent; a run of five or more unchanged cells inside it is stepped over with a cursor
   move. A row with a wide character is repainted to its end (terminals and `wcwidth` sometimes disagree about
   widths).
3. **Colours.** Colours and attributes carry along the row: only what changed is sent, and a space sends only its
   background (its foreground cannot be seen). 24-bit colour when the terminal has it (`trueColor`, from
   `COLORTERM` and the terminal's own answers), else the nearest colour of the 256-colour palette (`rgbTo256`
   chooses between the colour cube and the grey ramp by how close they look).
4. **A picture** the terminal draws itself ([below](#pictures)), sent after the cells.
5. **The cursor**, put where the frame left it (unless it is gliding).

`frameStats` keeps each frame's build time, write time and size for *Help › Performance…*; `slowTerminal()` uses
them to tell a terminal that falls behind (frames not asked for by a key then come 30 a second, and the minimap
set to `auto` is left out).

The UI suite checks the diff against a model terminal: [`tests/ui/vt.py`](../../tests/ui/vt.py) reads every byte of
a session and the screen it ends with must be what a full redraw draws (`t_611_frames_vt`).

## Regions: how a click finds its target

While drawing, every clickable thing registers a rectangle and an action: `region(x, y, w, h, act, tip, rightAct)`
(`button` and `pill` do it for you; `ctxRegion` registers an area that only has a context menu). The list `regions`
is rebuilt every frame, so it always matches the screen. `hitRegion(x, y)` searches it from the end: the region
drawn last — the one on top — wins. `tip` is the tooltip shown when the pointer rests on it.

Three markers split the list:

| marker | what follows it |
|---|---|
| `modalStart` | the open modal's regions (a dialog, a form, a menu, a prompt): a press is looked up only from here, so nothing under the modal reacts. A dialog also registers the whole screen first, to swallow clicks outside it |
| `pickRegions` | the picker's own regions (its query field, its buttons) |
| `overlayStart` | everything drawn after the docks — popups over the editor, the find bar, notes at a line's end. The minimap and the scroll bar are *drag handles*, not regions; a click on an overlay region that lies over one of them goes to the region |

`handleMouse` in [`src/ned/ui/mouse.nim`](../../src/ned/ui/mouse.nim) takes mouse events in this order: pointer
motion (hover effects and tooltips), the wheel (tabs, a long menu, the picker, the completion's docs, a pane that
is not active, else the text under the pointer), a release (a drop, a long press as a right click on touch
screens, a swipe in the file tree), a drag (a drag handle, a box selection, a text selection), a right click (the
topmost context menu), a middle click on a tab (closes it), and finally a left press: menus, a box taken by its title
bar, a dialog or form, the picker, the completion list, a prompt, the overlay over the minimap or scroll bar, the
drag handles (`dragHandleAt`: dividers, dock edges, the panel's header, the scroll bar, the minimap), the regions,
the terminal, the docks, and last the editor (gutter, Ctrl+click for definition, Alt+click for another cursor,
double and triple clicks, Shift+click, a drag of the selection).

Hover effects use the terminal's any-event mouse mode (`ui.hoverEffects`); drawing code asks `hov(x, y, w)` to
light what is under the pointer. The pointer's shape (a hand over a button, an I-beam over text) is sent with
OSC 22 when it changes (`updatePointer` in `ui/frame.nim`). On a touch screen a long press is a right click
(`ui.longPressMenu`), and the column before the scroll bar counts as the scroll bar.

## Popups, dialogs, forms, pickers, menus

| what | where | how to use it |
|---|---|---|
| messages | `core/messages.nim` | `info`, `warn`, `error`: the status bar (or a popup, `ui.messages`), kept in *Recent messages* |
| toasts | `ui/dialogs.nim`, drawn by `ui/popupdraw.nim` | `toast(text, sev, actLabel, act, ttl)`: a note at the bottom right, with one button |
| dialogs | `ui/dialogs.nim` | `openDialog(title, body, buttons, onKey)`; `askConfirm("Delete x? (y)es (n)o", proc(c: char) = …)` makes the buttons from the `(y)es` words. Dialogs stack |
| forms | [`ui/forms.nim`](../../src/ned/ui/forms.nim) | `newForm`, then `addCheck`, `addChoice`, `addText`, `addNumber`, `addNote`, `addHeader`, `addLink`, `addButton`; `openForm`. The Settings window (`ui/settingsui.nim`) is a form made from the settings' definitions |
| pickers | [`ui/pickers.nim`](../../src/ned/ui/pickers.nim) | `openPicker(kind, title, items)` for files, symbols and the like; `openActions(title, @[(label, detail, action)], search)` for any list of choices. The list filters as you type; Telescope's finders add a preview |
| menus | [`ui/menus.nim`](../../src/ned/ui/menus.nim) | `openMenu(@[mi("Label", "keys", action), msep(), msub("More", …)], x, y)`. The menu bar's menus (`ui/menubar.nim`) are made from palette commands: `mc("Command name")` |
| prompts | `ui/prompts.nim`, `ui/quickinput.nim` | `openPrompt(kind, label, initial)`: a one-line input at the top (go to line, save as, rename …); the find bar |
| completion, hover, signature help, key help | [`ui/popups.nim`](../../src/ned/ui/popups.nim) | filled by the engines and servers, drawn next to the cursor |
| text fields | `ui/fields.nim` | `drawField` draws every one-line field ned has, with its selection and the mouse in it |

A dialog, a form or a picker can be moved by its title bar: `boxPlace(key, x0, y0, w, h)` in `core/state.nim` gives
the place it opens at, moved by what the person did with that kind of box this session.

## The layout

`computeLayout` in [`src/ned/ui/layout.nim`](../../src/ned/ui/layout.nim) fills `lay` with the rows and columns of
everything, from the screen's size and what is open:

- the title bar on the first row (`ui.titleBar`, and at least 14 rows), the status bar on the last, the touch bar
  of extra keys above it (`ui.touchBar`: on by itself on narrow screens);
- the left and right docks, their widths from the settings (a drag on their edge sets `ui.leftDockWidth`,
  `ui.rightDockWidth`); the right dock floats over the editor when the screen has no room for it;
- under 70 columns (a phone held upright) an open dock covers the editor instead of squeezing it (`lay.overlay`),
  and it closes when the focus leaves it;
- the bottom panel's height (`ui.panelHeight`, or a third of the body), the tab bar and the breadcrumbs when there
  are rows for them, and what is left for the text.

The editor area can be cut into **panes**: a tree of splits (`PaneNode` in `core/state.nim`, laid out and drawn by
[`ui/split.nim`](../../src/ned/ui/split.nim)). The active pane shows `curBuf` with its cursors; each other pane
keeps a snapshot of its view (`ViewSnap`) and is drawn from it. Zen mode draws one centred column instead
(`render`, with `ui/zen.nim`).

The editor's text itself is drawn by `drawEditor` in [`ui/editorview.nim`](../../src/ned/ui/editorview.nim): the
gutter, each visible line coloured by its lexer (from the stored state at its start — see
[Editing › Highlighting](editing.md#highlighting)), the selections, the search matches, the problems' underlines,
the inlay hints, the git marks, folds and soft-wrapped rows. Its cost depends on the screen's size, never on the
file's.

## The cursor and its glide

Drawing sets `cursorX` and `cursorY` (−1: hidden); `flushScreen` puts the terminal's cursor there at the end of the
frame, in the shape `ui.cursorStyle` asks for.

When the cursor jumps — a row or more, or three columns or more — it glides there (`ui.cursorAnimation`, the end of
`core/screen.nim`): `caCursorMoved` starts a glide and keeps the real cursor hidden; `caPump`, called each round,
draws a short trail between the two places every 8 ms for `ui.cursorAnimationMs`, writing only the trail's cells.
It marks those cells unknown in `prevGrid`, so the next frame repaints them. The glide is off on a slow terminal, in
accessibility mode, and in the UI tests (their `setup` turns it off: a screen read mid-glide would show the trail).

## Pictures

[`core/images.nim`](../../src/ned/core/images.nim) reads PNG, JPEG, GIF and BMP with the standard library only,
treating every file as untrusted (sizes checked before anything is allocated, every loop bounded), and makes what a
terminal can show. [`editor/pictures.nim`](../../src/ned/editor/pictures.nim) shows a picture file:

1. always in the cells, as half blocks (`▀` with the upper pixel as the foreground and the lower as the background:
   any terminal, Termux too) — the Markdown preview draws its pictures the same way;
2. sharper, when the terminal draws pictures itself: `picProtocol` picks kitty's protocol, iTerm2's or sixel
   (`pictures.draw`, or what the terminal is and answered), and never inside tmux, which would not pass them on.
   The view sets `gfxNow` (where, and the escape sequence); `flushScreen` sends it when it is new, deletes the old
   one (kitty), and sends a sixel picture again when text was drawn over its cells. When a menu, dialog or popup
   covers it, `render` drops it and the cells show.

## Themes

A `Theme` (`core/types.nim`) has every colour ned draws with: the editor's, the bars' and docks', one per kind of
token (`syn[TokKind]`), sixteen ANSI colours for the terminal panel, three for rainbow brackets.

[`src/ned/core/themes.nim`](../../src/ned/core/themes.nim):

- `mkTheme(name, dark, bg, fg, accent, sel, comment, keyword, type, string, number, func, operator, macro,
  property, error, warning, ok)` makes a theme from sixteen colours, deriving the rest by blending; `chrome()` gives
  it its own title bar, dock and status bar colours; `slateTheme`, `monoTheme` and `phosphorTheme` make families
  of themes. `allThemesRaw()` is the list of built-in themes, one line each.
- `makeReadable` runs over every theme once: the interface colours (dimmed text, the gutter, inlay hints, comments,
  popup and bar text, the current line, the selection, the rulers) are moved in lightness only, until they reach
  a minimum contrast. A theme copied from elsewhere keeps its hues and becomes as readable as ned's own.
- `allThemes()` caches the built-in themes and adds your theme files (`~/.config/ned/themes/*.json`;
  `ui/themefiles.nim` also imports VS Code and base16 themes).
- `applyTheme(name)` sets `theme`: `"auto"` picks `theme.light` or `theme.dark` by the terminal's background (it
  answers OSC 11, or tells mode 2031) or by the clock; `theme.colors` overrides some colours (`rebuildTheme` makes
  the theme again from its base colours); `theme.trueBlack` puts a dark theme on black.

[`tests/themes/contrast.py`](../../tests/themes/contrast.py) reads the `mkTheme(…)` lines of `themes.nim` and checks
ned's own themes: text 7:1 against the background, keywords, types, strings and the like 4.5:1, comments 3:1, and
syntax colours far enough apart. [Recipes › Add a theme](recipes.md#add-a-theme) has the steps.
