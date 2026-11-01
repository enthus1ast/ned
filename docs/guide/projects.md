# Files, folders and projects

How ned opens things: the folder it works in, the file tree, the file finder, tabs and sessions. Where ned keeps
its own files is in [Files ned uses](files.md); several folders at once and folders on another machine are in
[The terminal and remote work](terminal.md#multi-root-workspaces).

## Starting ned

```sh
ned                      # the current folder, with the files you had open there last time
ned src/app.nim          # a file — and its project folder
ned src/app.nim:42:7     # at line 42, column 7  (also: ned +42 src/app.nim)
ned ~/code/app           # a folder
git log -p | ned         # what a command printed, in a tab of its own (also: ned -)
```

**The project folder** is the folder ned works in: the file tree shows it, Ctrl+P and the search look in it, git,
builds and the terminal start there, and its `.ned/settings.json` applies ([Settings](settings.md)). It is the folder
you name; else, when you open a file from outside its project (`ned ~/code/app/src/x.nim` from your home), the
nearest folder above the file that looks like a project — it has `.git`, a `.nimble` file, `Cargo.toml`,
`package.json`, `go.mod`, `pyproject.toml`, `build.zig` or `.ned` — and else the current folder.

In ned's own terminal, `ned FILE` opens the file in this ned instead of starting another one (`ned --new` starts
another) — see [The terminal and remote work](terminal.md).

## The Welcome page

With no file to open, ned shows the Welcome page: the recent files (`1`–`9` open them) and one key for each way to
start — `o` open a file, `f` the file tree, `d` open a folder, `r` a recent project, `g` clone a repository from a
link, `j` a new Nim project, `e` the palette, `t` a theme, `s` the settings, `a` the assistant, `?` the keys, `q`
quit; `n` (or any other key) starts typing in a new file. *Welcome page* in the palette shows it again.

## Opening folders and projects

- *Open folder…* (File menu) browses the folders, marking with ◆ the ones that look like a project (git, nimble,
  cargo …); *File: open folder by path…* takes a path you type.
- *File: open recent project…* lists the folders you worked in, newest first.
- *Nim: new project…* makes a Nim project (its `.nimble` — a program, a library or both — `src/`, `tests/`,
  `.gitignore`, and git with a first commit) and opens it; *File: clone from a
  link…* clones a repository and opens it ([Git](git.md)).
- *Open as the project* on a folder in the file tree makes it the project folder.

**Sessions.** Each folder remembers its open files and the one you were in, its breakpoints and watches, and the
run configuration and tasks you chose; opening the folder again brings them back (`files.restoreSession`). ned also
remembers where the cursor was in every file, your bookmarks, and how the panes were split (`ui.restoreLayout`). It
starts with no dock or panel open, the keys in the editor; `ui.restorePanels` reopens them as you left them. Unsaved edits come back too, still unsaved (`files.hotExit` — [Safety](safety.md)).

## The file tree

**Ctrl+B** (or the Files icon) shows the project's files in the left dock. With the tree focused:

| key | |
|---|---|
| ↑ ↓ · `j` `k` · PgUp PgDn · Home End | move |
| Enter · `l` · `o` | open the file, or open and close the folder |
| → · ← · `h` | open a folder · close it, or go to the folder above |
| `n` (or `a`) · `f` (or `A`) | a new file · a new folder, in the selected folder — the name can have folders in it: `src/util/strs.nim` |
| `r` | rename or move |
| `d` · Delete | delete (asks first; the file is deleted, not moved to a trash) |
| `.` | show or hide dot-files (`files.showHidden`) |
| `R` | read the folder again (*Refresh file tree*) |
| `q` · Esc | close the tree · back to the editor |

The right-click menu also has *Open to the side*, *Copy path*, *Copy relative path*, *Add to .gitignore*, *Search in
folder…*, *Open in browser*, *Ask AI about this file* and *Open as the project* (and *Initialize a git repository
here* outside one). Each file shows its git state, a • when it has unsaved changes, how many problems it has and
its TODO comments (⚑3). *Reveal file in tree* finds the current file in it.
`files.exclude` lists the folders the tree, the finder and the built-in search leave out (`node_modules`,
`nimcache`, `target` …).

## Finding a file: Ctrl+P

**Ctrl+P** opens the file finder: type some letters of the path, in their order, as fzf takes them (`srvcfg` finds
`src/server/config.nim`). The open files (●) come first, then the recent ones (○), then the rest
of the project. On a wide screen the selected file is shown beside the list (`editor.pickerPreview`). The finder
also does more with a first character:

| type | |
|---|---|
| `:42` | go to line 42 of this file (`:42:7` and the column) |
| `@name` | a symbol of this file (as Ctrl+T) |
| `#name` | a symbol of the whole project |
| `>name` | a command (as the palette, Ctrl+E) |

*Switch buffer…* lists the open files only. Go to definition, F12, opens files too — the files of the Nim toolchain
and installed packages it lands in open read-only (`files.protectLibraries`).

## Tabs and panes

- Each open file has a tab: Alt+← and Alt+→ (or Ctrl+PgUp, Ctrl+PgDn) go to the one before and after, Alt+1 … Alt+9
  to the first nine. Ctrl+W closes a tab (asking about unsaved changes), *Close other tabs* the rest, Alt+Shift+T
  opens the last one you closed again. *Toggle tab bar* hides the bar.
- **Panes**: Alt+\ (*View: split editor right*) and *View: split editor down* cut the editor in two — and each pane
  again, as many times as there is room: two files side by side, three columns, one large file with two stacked
  beside it, or two places in one file. Each pane has its own header bar with its file; a click on a pane (or its
  header) gives it the focus. See [Panes](#panes-tiling) below.
- **Markdown**: *Markdown: open preview to the side* — or **M↓** in the status bar of a Markdown file — shows it
  rendered beside it, following your edits; again (or M↓ in the preview) closes it.
- **Comparing**: *File: compare with saved* shows your unsaved changes as a diff, *File: compare with another file…*
  two files side by side.

## Panes (tiling)

The editor area can be cut into as many panes as fit — each side by side with its neighbour or one above it, each
showing a file of the open tabs with its own place in it. The pane with the focus has a bright mark at the left of
its header; the others keep where they were.

| to | keys | or |
|---|---|---|
| cut the pane in two, the new one at the right · below | Alt+\ (with one pane) | *View: split editor right* · *View: split editor down*, the header's menu |
| go to the next pane · the one before | Alt+\ | *View: focus next pane* · *View: focus previous pane* |
| go to the pane at the left, right, above, below | Ctrl+Alt+Shift+arrows | *View: focus the pane to the left …*, a click |
| make the pane wider, narrower, taller, shorter | Ctrl+Alt+arrows | drag the line between two panes |
| close the pane (its file stays open in its tab) | Alt+\| | the × in its header |
| close every other pane | | *View: close the other panes* |
| swap the file with the pane beside it | | *View: swap with the pane to the right …* |
| the pane alone, full size — again: every pane | | *View: this pane alone (zoom)*, the header's menu |
| side by side ↔ one above the other | | *View: turn the split*, the header's menu |
| every pane the same size | | *View: equal pane sizes* |
| show the current file in the other pane | | *View: show file in other pane* |

Ready-made layouts lay out the open files at once: *View: panes: two columns*, *three columns*, *grid of four* and
*one large and three* (the current file large at the left, the next three stacked at the right). A tab dragged off
the tab bar onto a pane shows it there; onto the right or bottom quarter of a pane, it cuts that pane in two.

**Each pane its own tabs.** With more than one pane, the files a pane has shown are tabs in its header: a tap on one
shows it there, Ctrl+PgUp and Ctrl+PgDn (Alt+← and Alt+→) go through that pane's tabs only, and its × takes the file
out of the pane — and closes it when no other pane has it (asking first when it has unsaved changes). The tab bar at
the top still lists every open file.

**Named layouts.** *View: save this layout as…* keeps the panes — their files, their tabs, where each one is — with
the side docks and the panel, under a name of your choosing, for the folder; *View: layouts…* puts one back
(opening its files when they are closed), *View: forget a layout…* drops one. Also in View › Panes.

**A terminal or the assistant as a pane.** *View: terminal in a pane* opens a shell of its own in a pane at the right
— beside the code rather than under it — as a tab among the files: while that pane has the focus, keys go to the
shell (Ctrl+Alt+Shift+arrows move to another pane); closing its tab (the × on the tab bar) ends the shell. The
panel's terminals are separate. *View: assistant in a pane* moves the AI assistant from its dock into a pane the same
way, and *View: panel in a pane* the bottom panel — Problems, Output, its terminals, the debugger — so that on a wide
screen a build's output sits beside the code rather than under it.

In vim mode, Ctrl+W works as in vim: h, j, k, l to the pane that way, w to the next, s and v split, q closes the pane,
o keeps only this one, = makes them the same size, x swaps with the next, H J K L move the file that way; `:sp`, `:vs`,
`:only`, and `:q` or `:close` close the pane when there are several.

On a narrow screen (a phone held upright) two side-by-side panes are shown one above the other. The panes and their
files come back the next time the folder opens (`ui.restoreLayout`). Plugins can split, focus and fill panes too —
see [the plugin API](../plugins/README.md).

## Files on disk

- A file changed by another program reloads by itself when you have no unsaved changes in it
  (`files.autoReload`); when you do, ned tells you, and saving asks whether to overwrite it or reload it.
- *File: rename or move this file…* renames the file on disk and in its tab — and for a Nim module, the imports of it
  in the project follow. *New file at path…* makes a file (and its folders) where you say. *Copy file path* copies
  where it is.
- Files the Nim toolchain and nimble packages own open read-only; *File: allow editing this file* (or *Read-only* in
  the status bar) unlocks one.
- A file that is not text opens in the [hex editor](hex-and-binaries.md); a very big one in the large-file viewer,
  and non-UTF-8 text in its own encoding — see [Editing](editing.md#files-in-other-encodings-and-big-files).
- The project's files are indexed in the background for Ctrl+P, up to `files.scanLimit` (500 000).
