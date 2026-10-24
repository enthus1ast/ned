# Settings

Everything is in one commented JSON file: **`~/.config/ned/config.json`** (palette › *Open settings file*),
or use the Settings window (palette › *Settings*, ⚙ in the title bar): the categories on the left, a search over
every setting (its name or words from its description), check boxes (▐✓▌ on, an empty frame off), lists (▾), text
and number fields in boxes (a number with − and + beside it); ↺ at the end of a row you changed puts its default
back, a • after a name says your settings file sets it, and the line over the help shows the setting's key. Its scroll bar has ▲ and ▼ to tap, a tap on the track
jumps there (touch screens), the thumb drags, the wheel or a swipe scrolls. OK or Apply writes what you changed into
the file, its comments kept (*Settings: quick list…* is the older one-line list; `"ui.formButtons": false` brings it
back, with prompts and pickers without their OK/Cancel buttons). Saving the file applies it immediately.
`ned --default-settings` prints every option with its default and a description.

A few examples:

```jsonc
{
  "theme": "vscode-dark",
  "ui.icons": "nerd",
  "ui.italics": false,
  "editor.tabSize": 2,
  "editor.rulers": [80],
  "editor.fontLigatures": "symbols",
  "editor.formatOnSave": true,
  "editor.vimMode": false,
  "editor.completionDocs": true,
  "nim.ide": "builtin",
  "nim.nimsuggest": false,
  "nim.formatter": "builtin",
  "ai.provider": "anthropic",
  "ai.autoApprove": "reads",
  "git.inlineBlame": true,
  "keys": {"alt+g": "Go to symbol in project…", "ctrl+shift+f": "Search in project…"},
  "commands": {"Upper case": {"run": "tr a-z A-Z", "output": "replace"}},
  "ui.messages": "popup",
  "snippets": {"nim": {"dbg": "echo \"${1:x} = \", $1"}},
  "lsp": {"python": ["pyright-langserver", "--stdio"]},
  "run": {"python": "python3 $file"},
  "editor.keymap": "default",
  "editor.spellCheck": "markdown",
  "ui.accessible": false,
  "repl.commands": {"python": "ipython --no-autoindent"},
  "sync.repository": "git@github.com:you/ned-settings.git"
}
```

*Settings: reset to defaults* (palette, or near the top of the Settings UI) puts every setting and key binding
back to its default after asking. Your old file stays next to it as `config.json.bak-<date>`.

**Project settings**: `<folder>/.ned/settings.json` overrides your settings inside that folder (palette ›
*Settings: open project settings*). Typical uses: `editor.tabSize`, `nim.projectFile`, `files.exclude`,
`nim.toolchain` (the Nim the project builds with), `nim.minVersion`, `nim.format.lineLength`. Settings that start
programs (`nim.toolchain`, `lsp`, `run` …) take effect only in a folder you trust.

Setting groups: Appearance (`theme`, `ui.*`), Editor (`editor.*`), Zen (`zen.*`), Vim (`vim.*`), Files
(`files.*`), Search (`search.*`), Terminal (`terminal.*`), Git (`git.*`), Nim (`nim.*`, including every
nimlangserver option), C (`c.*`), AI (`ai.*`), Languages (`lsp`, `formatters`, `run`, `snippets`, `web.engine`) and `keys`.
