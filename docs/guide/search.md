# Search and replace

Finding text in the file you are in, and in the whole project — and changing it. Finding *code* (a definition, its
references, a symbol) is in [Key bindings](keys.md#files-and-navigation) and [the Nim IDE](nim.md); finding a
file is Ctrl+P ([Files, folders and projects](projects.md#finding-a-file-ctrlp)).

## In the file: Ctrl+F

**Ctrl+F** opens the find bar at the bottom. Every match is highlighted as you type, and the bar says where you are
(*3 of 12*) — or *No results*, in red. **Enter** goes to the next match and **Shift+Enter** to the one before; F3
and Shift+F3 do the same once the bar is closed. Esc closes it.

| in the bar | button | |
|---|---|---|
| Alt+C | `Aa` | match case |
| Alt+W | `W` | whole words only |
| Alt+R | `.*` | a regular expression (an error in it is shown in the bar) |

## Replace: Ctrl+R

**Ctrl+R** asks for what to find, then for what to put instead, then goes through the matches one by one: **y**
(or Space) replaces this one, **n** leaves it, **a** replaces it and all the rest, **q** or Esc (or *Done*) stops —
the bar counts how many it has done. Ctrl+Z takes back one replacement at a time, or all of what **a** did at once.
With a regular expression, the replacement can use the groups: `$1` … `$9`, `${12}`, `$0` or `$&` for the whole match, and `\n` for a line break.

## In the project: Alt+S

**Alt+S** opens the **Search** dock: type, and the results stream in, grouped by file, each with its line and the
match highlighted. Enter (or a click) opens the file at the match; the dock stays as it was, so you can go through
them one by one.

- The same three toggles as the find bar: `Aa`, `W` and `.*` (in the dock: `c`, `w` and `r`). Without `Aa`, a
  search with a capital letter in it matches case anyway (smart case), unless it is a regular expression.
- **Only some files**: *files…* (or *Search: only in some files…*) takes globs separated by commas — `*.nim`,
  `src/` for a folder, `!tests/` to leave one out: `*.nim, src/, !tests/`.
- What it searches: the project's files — with ripgrep, without what `.gitignore` ignores; else without the
  folders `files.exclude` lists (`node_modules`, `nimcache`, `target` …) — and the files you have changed but not
  saved, as you see them, not as they are on disk. In a [workspace](terminal.md#multi-root-workspaces), every folder of it.
- How: with [ripgrep](https://github.com/BurntSushi/ripgrep) (`rg`) when it is installed — fast in any project
  (Termux: `pkg install ripgrep`); else `grep` for plain text; else ned's own search.

## Replace in the project

Open the replace box in the Search dock (the ⇄ button, the chevron, or **Alt+H**; also *Search: replace in
files…*) and type the replacement. Every result then shows *old → new* inline, so you see each change before it is
made.

- Right-click a result to replace just that line, or that file, or to leave it out of the replace.
- **All** (Alt+Enter) replaces the rest, after asking.
- Files that are open change in the editor — save them to keep it. The others are written to disk, each after a
  copy of it goes into [local history](safety.md).
- *Search: undo replace all* puts every file back as it was.

## Editing the results: multibuffers

*Open results in a multibuffer (edit many files at once)* puts every result, with a few lines around it, in one
tab: an excerpt per match, each headed by its file. Edit them as one file — with several cursors, a replace, a
macro — and **Ctrl+S** writes each change back to its own file. *Problems: all of them with their code* makes the
same kind of view of every problem, and *Git › Changes* (Alt+Shift+G) of every change you have not committed.

## Telescope: one finder for everything (Alt+Shift+F)

**Alt+Shift+F** (or *Telescope…* in the palette) lists ned's finders; type to narrow the list, Enter to open one.
Each is a picker with a preview beside it — the file at the line, a commit's change, a setting's description — that
follows the selection; Enter acts on what is selected, Esc closes it.

| finder | what it lists · what Enter does |
|---|---|
| Files · Open tabs · Recent files · Recent projects | as Ctrl+P does; the recent files, of this folder and others |
| Live grep · Grep the word under the cursor | every line of the project with what you type, found as you type (ripgrep, else git grep, else grep; 1500 lines at most) · the file at the line |
| Symbols in this file · Symbols in the project | as Ctrl+T and *Go to symbol in project* |
| Commands · Keys | every command · the commands that have a key, by key · runs it |
| Settings | every setting, its value, its default and what it does · the Settings panel at it |
| Problems · TODOs · Bookmarks | errors and warnings of every file · the TODO comments of the project · your bookmarks — the place |
| Git: changed files · commits · commits of this file · branches · stashes | the diff, the commit, the branch's last commits, the stash's change beside each · opens the file, shows the commit, checks out the branch, applies the stash |
| Nim: the standard library's modules · names of the standard library · nimble packages installed | each module · every exported name, its declaration beside it · goes there |
| Terminal: commands run | what you ran in ned's terminals, with its output · runs it again |
| Themes · Languages · Plugins | as their own pickers; ned's plugins with their source |

*Telescope: resume* opens the last finder again with what you had typed in it; *Telescope: live grep*, *…settings*,
*…git commits* and *…git changed files* open one directly — give any of them a key in the `keys` setting.

## TODO comments

`TODO`, `FIXME`, `BUG`, `HACK` and `NOTE` comments are coloured in the code, and **Alt+V** / **Alt+Shift+V** go to
the next and the one before in the file. *TODOs panel* (View › TODOs) lists those of the whole project, counted by
kind — `1`–`9` turn a kind on and off — and *TODO: copy the list as Markdown* copies them; *TODO: insert a tag
comment…* writes one. Which words count, and their colours: the settings under *TODO comments* in
[every setting](../reference/settings.md#todo-comments).

## Regular expressions

ned's own regular expressions, the same in the find bar, Replace and the built-in project search (ripgrep uses its
own, which accept the same and more):

| | |
|---|---|
| `.` · `[abc]` · `[^a-z]` · `[[:digit:]]` | any character · one of · none of · a class |
| `\d` `\w` `\s` `\b` (and `\D` `\W` `\S` `\B`) | a digit, a word character, a space, a word boundary (and the opposite) |
| `^` · `$` | the start · the end of the line |
| `( )` · `(?: )` · `a\|b` | a group (`$1` in the replacement) · a group that is not counted · either |
| `*` `+` `?` `{n}` `{n,}` `{n,m}` | repeated: any number, one or more, at most once, n times, n or more, n to m |
| `*?` `+?` `??` | the same, as few as possible |

Matching is by line: a match does not go over a line break.
