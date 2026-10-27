# Recipes

Step-by-step changes that come up again and again, with the files to touch. Each ends with the tests and the
documentation it needs: a change is finished when both are done. Read [Pitfalls](pitfalls.md) first.

## Add a setting

1. **Define it** in `initSettingDefs` in [`src/ned/config/settings.nim`](../../src/ned/config/settings.nim), next to
   the settings of the same subject (their order is the order of the settings file, the Settings window and the
   reference):

   ```nim
   defS("Editor", "editor.wordCount", %false,
        "Show the number of words in the status bar (Markdown and text files)")
   defS("Editor", "editor.wordCountIn", %"markdown", "Which files count words", @["markdown", "text", "all"])
   ```

   The category is the section (`Appearance`, `Editor`, `Files`, `Nim` …); the key is `section.name`; the default is a
   JSON value (`%true`, `%4`, `%"x"`, `newJObject()`); a list of options makes it a choice. The description is what
   the person reads in the settings file and the Settings window: say what happens, in plain words, and what the
   values mean.

2. **Give it a variable** when hot code reads it: `cfgWordCount = false` with a comment naming the setting, in
   `core/state.nim` (read in many places) or next to the code that uses it. Code that reads it rarely can call
   `sBool("editor.wordCount")`, `sInt`, `sStr` or `sval` directly — they fall back to the default.

3. **Apply it** in `applySettings` (same file): `cfgWordCount = sBool("editor.wordCount")`. When a change must do
   something — restart a server, repaint everything (`prevGrid.setLen(0)`), refresh a view — do it there, or in
   `reloadSettings`. `applySettings` also runs in the engine worker and in nedls: nothing that writes to the terminal
   unless `gRaw` is set.

4. **A setting that starts programs or sends code somewhere** (a command, a server, a key's action) must not be
   settable by a cloned repository's `.ned/settings.json` until the folder is trusted: add it to
   `riskyProjectKey`.

5. **Regenerate the reference**, with no settings of yours in it:

   ```sh
   XDG_CONFIG_HOME=$(mktemp -d) ./ned --doc-settings > docs/reference/settings.md
   ```

6. **Document and test it**: the guide that covers the feature (`docs/guide/…`), and a UI test that sets it in
   `setup({...})` and checks what it does.

The settings file, the Settings window, the Telescope settings finder, the settings file's JSON schema and the
validation of values are all made from `defS`: nothing else to register.

## Add a command, a key and a menu item

1. **The command**: one line in `initCommands` in
   [`src/ned/app/commandlist.nim`](../../src/ned/app/commandlist.nim):

   ```nim
   add("Edit: count words", "", cmdCountWords())
   add("Edit: join lines", "Alt+J", buf().joinLines())
   ```

   The name is what the palette shows and what `runCmd`, the `keys` setting, `--remote-command` and plugins call
   it by; group it with a prefix (`Git: …`, `Nim: …`). The second field is the key as the palette shows it, or a few
   words of what the command does. The body is a closure: call a proc defined in a file included before
   `commandlist.nim` (nearly all of them are). Renaming a command breaks people's `keys` settings and scripts: add the
   old name to `CmdRenamed` in `ui/menubar.nim`.

2. **The key**, when it has one: handle it in `globalKey` (everywhere) or `editorKey` (the editor only) in
   [`src/ned/app/keyboard.nim`](../../src/ned/app/keyboard.nim), and write it in the command's keys field — that text
   is how *Keyboard shortcuts…* knows the key is taken (`keyTokens`). Check that a terminal can send it
   ([Pitfalls](pitfalls.md#keys-a-terminal-never-sends)), that vim, helix or emacs do not take it first, and that no
   other command has it.

3. **The menu item**: `mc("Edit: count words", "Count words")` in the right menu of `menuItems` in
   [`src/ned/ui/menubar.nim`](../../src/ned/ui/menubar.nim) — the name must be the command's exactly, or the item is
   disabled. A context menu (right click) is built in `ui/editormenu.nim` or `ui/contextmenus.nim` with
   `mi("Label", "keys", action)`.

4. **Regenerate and document**: `XDG_CONFIG_HOME=$(mktemp -d) ./ned --doc-commands > docs/reference/commands.md`;
   a new key goes in [docs/guide/keys.md](../guide/keys.md); the feature in its guide.

5. **Test**: a UI test that runs it from the palette (`palette('Edit: count words')`) and with its key.

## Add a dock view

The docks show a list of `SideItem`s; a new view is a new value of `SideView`.

1. Add `svWords` to `SideView` in [`src/ned/core/types.nim`](../../src/ned/core/types.nim) (its name is also what the
   saved layout remembers).
2. In [`src/ned/ui/docks.nim`](../../src/ned/ui/docks.nim): put it in `LeftViews` or `RightViews`, give it an icon in
   `viewIcon` (an icon name of `ui/icons.nim`, which has a Nerd Font, a Unicode and an ASCII set) and a title in
   `viewTitle`.
3. Write `buildWordItems(): seq[SideItem]` (in `docks.nim`, or a file of its own included before `ui/lists.nim`):
   one `sideItem(text, role, icon, detail, action, path, line, depth)` per row; `role` picks the colour (accent, dim,
   error, warning, ok, header, function, type, keyword). It is called whenever the dock is drawn, so it must be
   cheap: keep what is slow to work out in a variable, updated in the background.
4. Add its case to `buildItems` in `ui/lists.nim`; what opening it does in `showSide`; buttons in its header in
   `dockActions` (`ui/dockframe.nim`); keys of its own in `dockListKey` if it needs them.
5. A command to open it (`add("Words panel", "", showSide(svWords))`), a *View* menu item, a UI test that opens it
   and clicks a row.

A plugin can add a view to the Plugins dock without any of this: the plugin API's `view`.

## Add a language

### As a built-in language

1. A `Lang` in `initLangs` in [`src/ned/core/languages.nim`](../../src/ned/core/languages.nim), like its neighbours:

   ```nim
   Lang(name: "Lua", id: "lua", exts: @["lua"], mode: lmGeneric, lineComment: "--",
     blockStart: "--[[", blockEnd: "]]", quotes: {'"', '\''},
     keywords: ws"""and break do else elseif end for function goto if in local not or repeat return then until while""",
     consts: ws"true false nil", defWords: ws"function",
     indentWords: @["then", "do", "else", "repeat", "{", "("], indentWidth: 2,
     run: "lua \"$file\"", lsp: @[@["lua-language-server"]], fmt: @["stylua -"], pairs: "()[]{}\"\"''"),
   ```

   `id` is the Language Server Protocol's language id. `mode: lmGeneric` colours it with the generic lexer driven by
   these fields — enough for most languages. `exts` and `files` decide which files are in it (`detectLang`; a `#!`
   line has its own list there). `lsp` lists the servers to try, `fmt` a formatter that reads stdin, `run` what F5
   runs.
2. A language the generic lexer cannot colour gets a `LexMode` (`core/types.nim`), a lexer proc in
   `core/lexers.nim` (one line in, a `TokKind` per byte and the state at the line's end out), and its case in
   `lexHost`.
3. Test it in the UI suite: open a file, check a keyword's colour with `fg_at(ansi_row(...), 'word')`, and what F5
   runs. Add it to the languages listed in the docs.

### As a plugin

Most new languages are better as one of ned's own plugins: no change to the editor, off until someone turns it
on, and it can bring its language server, formatter, snippets and outline. Copy one of the language plugins
(`plugins/odin/plugin.nims`, `plugins/zig/plugin.nims`):

1. `plugins/<name>/plugin.nims`, whose first line is `## <name> — what it does`; `language("<id>", LangSpec(...))`
   for its files and colours, `languageServer`, `formatter`, `snippet`, a `symbols` provider for the outline, its
   settings with `settingDef`. The [tutorial](../plugins/tutorial.md#7-a-languages-features) shows each.
2. Its name in `PlugBundledNames` in `src/ned/plugins/host.nim`.
3. Its checks in `tests/plugins/bundled/test_<name>.py`, using the shared checks of
   `tests/plugins/bundled/langcheck.py`; run `python3 tests/plugins/tbundled.py --native <name>`.
4. A line in [docs/plugins/available.md](../plugins/available.md). Build ned again: its plugins are read in when it
   is built.

## Add a theme

1. One line in `allThemesRaw` in [`src/ned/core/themes.nim`](../../src/ned/core/themes.nim):

   ```nim
   mkTheme("harbour-night", true, 0x14202B, 0xD4DEE6, 0x5CB8E4, 0x2A3E50, 0x7A8C99, 0xC792EA, 0xE6C07B,
           0x9ECE6A, 0xF78C6C, 0x82AAFF, 0x89DDFF, 0xFF9E80, 0xB4C8D8, 0xF07178, 0xFFCB6B, 0xC3E88D),
   ```

   The sixteen colours are, in order: background, text, accent, selection, comment, keyword, type, string, number,
   function, operator, macro, property, error, warning, ok. Write them as literal hex numbers: the contrast test reads
   them from the source with a pattern. `chrome(theme, title, dock, status)` gives the bars colours of their own.
2. A theme of ned's own must pass the contrast test: add its name to `OWN` in
   [`tests/themes/contrast.py`](../../tests/themes/contrast.py) and run it; change colours until it passes (text 7:1,
   syntax colours 4.5:1, comments 3:1, syntax colours far enough apart).
3. The theme's name is one of the `theme` setting's options: regenerate `docs/reference/settings.md`. List it in
   [docs/guide/themes.md](../guide/themes.md).
4. A UI test as `t_630_themes` does: `setup({"theme": "harbour-night"})`, then the background and a keyword's
   colour on screen.

A theme of your own needs none of this: a JSON file in `~/.config/ned/themes/`
([Themes](../guide/themes.md#your-own-theme-file)).

## Add a picker or a Telescope finder

**A list of choices**: `openActions(title, items, search)` from `ui/actions.nim`, with `items` a list of
`(label, detail, action)` — the picker filters as you type and Enter runs the action. Make each action with a factory
proc, never a closure written in the loop ([Pitfalls](pitfalls.md#closures-made-in-a-loop-share-its-variables)):

```nim
proc openWordAct(path: string, line: int): Action = (proc() = discard openFile(path, line))

proc cmdPickWord() =
  var items: seq[(string, string, Action)]
  for (path, line, word) in wordHits:
    items.add (word, relPath(path) & ":" & $(line + 1), openWordAct(path, line))
  openActions("Words", items)
```

**A picker of its own kind** (files, symbols, buffers) is a `PickKind` (`core/types.nim`), `openPicker(kind, title,
items)` with `PickItem`s, and its branch in `acceptPicker` ([`ui/pickers.nim`](../../src/ned/ui/pickers.nim)).

**A Telescope finder** ([`ui/telescope.nim`](../../src/ned/ui/telescope.nim)) is an action picker with a preview
beside each entry:

```nim
proc tsWords() =
  var es: seq[TsEntry]
  for (path, line, word) in wordHits:
    es.add TsEntry(label: word, detail: relPath(path) & ":" & $(line + 1),
                   act: tsGoTo(path, line, 0), pv: tsFile(path, line))
  tsOpen("Words", es, tsWords)                    # (the last argument: Telescope › Resume opens it again)
```

The preview is `tsFile(path, line)` (the file at the line), `tsText(text, lang)` or `tsCmd(command)` (a command's
output, run the first time the entry is shown). Add the finder to the list in `telescope()` with
`add(label, detail, action, help)`.

## Add a plugin API function

The library proc with its `##` doc comment (`src/ned/plugins/lib/nedplugin.nim`), its `of "name":` branch in
`plugApi` (`src/ned/plugins/host.nim`), the tests' imitation of ned (`tests/plugins/tplugins.py`,
`tests/plugins/tbundled.py`), a check, and `python3 tests/docs/apiref.py`. The details are in [The plugin host ›
Adding a function to the plugin API](plugins-host.md#adding-a-function-to-the-plugin-api).

## Add a UI test

1. Write `def t_<version>_<topic>():` in [`tests/ui/suite.py`](../../tests/ui/suite.py), with a comment on what it
   checks: `setup({settings})`, files written into `W`, `start('file', w=…, h=…)`, keys and clicks, then
   `check(name, condition, screen())` after `wait_for` or `wait_until`.
2. Add it to the `tests` list at the end of `suite.py`.
3. Run it alone (`python3 tests/ui/run.py ./ned t_<version>_<topic>`), then with its neighbours.

The helpers and the rules are in [Testing › The UI suite](testing.md#the-ui-suite).

## Add a unit test

Only the modules can be unit-tested (an included file cannot be imported alone): the Nim and C engines, the
formatters, the web engines, `core/text`, `core/encodings`, `editor/regex` … For logic in an included file, write a
UI test, move the logic into a module, or do what the engine drivers do (`tests/engine/build.sh`: a file that includes
the whole of `src/ned.nim`, built with `-d:nedNoMain`).

1. A case in the subject's file (`tests/unit/tindex.nim` for the Nim index …), or a new file `tests/unit/t<name>.nim`
   (the runner takes every `t*.nim`) that imports the module from the source:

   ```nim
   ## What these tests check. Run: nim r tests/unit/twords.nim
   import std/unittest
   import ../../src/ned/core/text

   suite "words":
     test "a wide character is two columns":
       check strWidth("日本") == 4
   ```

2. Run it: `nim r -d:release --hints:off tests/unit/t<name>.nim`.
3. A test that also holds on Windows can be added to the Windows job's list in `.github/workflows/tests.yml`.

## Make a release

1. **The version**, in every place it is written: `src/ned/version.nim` (`NedVersion`), `ned.nimble` (`version`),
   `editors/vscode/package.json`, and the file names in the README (the Termux `.deb`, the Windows zip).
2. **The notes**: a *What's new in X.Y* section at the top of the README (and its line in the README's contents); the
   release before it moves to `CHANGELOG.md` when a new X.Y starts (a fix release X.Y.Z gets a short section above
   X.Y's). Plain words, what changed for the person using ned.
3. **The references and the guides**:

   ```sh
   export XDG_CONFIG_HOME=$(mktemp -d)
   ./ned --doc-settings > docs/reference/settings.md
   ./ned --doc-commands > docs/reference/commands.md
   python3 tests/docs/apiref.py
   python3 tests/docs/links.py
   ```

4. **Every test** ([Testing](testing.md)): the unit tests, the plugin tests, nedls, the formatter's parse check, the
   whole UI suite on a quiet machine, `pty_smoke.py`, `bench.py`, `rounds.py`, `budgets.py`, every command
   (`smoke/commands.py`, with and without `--plugins`), the hostile input (`hostile/thostile.py`), the fuzzer, the docs
   and themes checks, and the scoreboard (CI runs it).
5. **The builds**: `bash tests/build/termux.sh OUT` (the `.deb`) and `bash tests/build/windows.sh OUT` (the zip), with
   zig as the C compiler; `tests/build/cross.sh` for every other target. Build one thing at a time on a small machine.
   Gather the release's files in one folder and run `NED_SIGNING_KEY=~/.ssh/ned-release sh tests/build/sums.sh
   FOLDER`; publish SHA256SUMS and SHA256SUMS.sig with them.
6. **Tag and push** `vX.Y.Z`: `.github/workflows/build.yml` builds every platform and attaches the programs (and the
   VS Code extension) to the GitHub release.
