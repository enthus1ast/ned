# Troubleshooting

- **Start here:** `ned --check` (or *Help › Check setup*) shows which tools ned found and how to install the
  missing ones. When you report a problem, *Help › Copy info for bug report* gives the details to paste.
- **Several nimsuggest processes** — open *Nim: language server status*: it lists each process and why it
  exists. With the built-in engine there is one per project at most; with nimlangserver it is usually a test
  file with `nim.maxNimsuggestProcesses` ≥ 2, or a `nim.projectMapping` of your own.
- **No completion or hover for Nim** — check that `nim` is on your `PATH`. The engine finds the standard
  library from it. *Nim: language server status* shows the library folder and the search paths in use.
  Completion that comes up but does not know a type falls back to nimsuggest when it is turned on.
- **nimsuggest uses too much memory** — it is off by default since 5.28; if you turned it on, lower
  `nim.nimsuggestMaxMB` or `nim.nimsuggestIdleMinutes`, or set `"nim.nimsuggest": false` again.
- **Nim works in single files but not in a nimble project** — open *Nim: language server status*: it shows the
  library and search paths the engine uses (and, with nimsuggest or nimlangserver, the process for each project and
  its errors). If the package needs another Nim, choose it with *Nim: choose the Nim for this project…*
  (`nim.toolchain`).
- **"nimlangserver exited"** — the warning shows the server's last error line, and the status page shows
  its output. ned restarts it, and switches to the built-in nimsuggest client if it keeps failing.
- **AI: "Unsupported parameter…" or a model that answers with nothing** — ned adjusts the request to what each
  model accepts and remembers it; an empty reply says why, usually the token limit (raise `ai.maxTokens`).
- **Alt keys don't work** — in Termux add ALT to the extra-keys row (`~/.termux/termux.properties`); on macOS
  terminals enable "Option as Meta". Every command is also in the menus (F10) and the palette (Ctrl+E).
- **Can't select text with the mouse in Termux** — Alt+U turns ned's mouse support off for a moment.
- **Slow on a phone** — *Help › Performance…* says what takes the time and which settings would help (often
  `"ui.minimap": "off"` on a slow terminal, or `"nim.engineHints": false` on a big file).
- **Lines left behind or out of place after scrolling** — the terminal does not handle scroll regions as ned
  expects: set `"ui.terminalScroll": false` (and *Redraw the screen* from the palette clears it at once).
- **Colours look wrong** — set `"ui.trueColor": "on"` or `"off"` (256 colours).
- **Emoji push the text out of place** — terminals disagree on emoji sequences (👨‍👩‍👧, 👍🏽, flags): ned joins them
  where the terminal says it does (mode 2027). If yours joins them without saying so, set `"ui.graphemes": "on"`; if
  it shows them apart although it said otherwise, `"off"`. *Help › Check setup* shows what the terminal answered.
- **A key does something odd in kitty, WezTerm, Ghostty or foot** — ned speaks the kitty keyboard protocol there;
  `"ui.kittyKeyboard": "off"` goes back to the classic keys (please report the key).
- **`ned FILE` in ned's terminal starts no second ned** — that is on purpose: the file opens in the ned around it.
  `ned --new FILE` starts another one; `"terminal.editorEnv": false` keeps git's and your `$EDITOR` as they were.
- **Comments look odd or garbled** — italics are off by default. Turn them on with `"ui.italics": true`
  only if your terminal font has an italic face.
- **AI says "No API key"** — export the key in the shell that starts ned, or set `ai.apiKey`
  (`ai.apiKeyEnv` names a different variable). Or use a model on the device, which needs none: *AI: on this
  device, offline…*.
- **git push asks for a username and password, and fails** — GitHub stopped taking passwords. Since 6.7 ned
  offers *Sign in* when that happens (also *Git: sign in to GitHub*): the GitHub CLI signs you in in the
  browser, or an SSH key is made and added. In a shell the same is `gh auth login` and `gh auth setup-git`.
- **"the built-in formatter would change the code here, so nothing was changed"** — the formatter met code it
  cannot lay out safely and left the file as it was. Choose nph for that project (`"nim.formatter": "nph"` in
  its `.ned/settings.json`), and please report the file.
- **A plugin does not load** — open the Plugins dock (*Plugins panel*): it shows each plugin, its state and its
  log. A plugin that does not compile has its error in Problems, at its line; one that needs a newer ned says so
  (`requiresNed`). NimScript plugins need `nim` on the `PATH`. A project's plugins (`.ned/plugins/`) run only once
  you trust its folder. See [Plugins](../plugins/README.md).
- **Something crashed** — start ned again and restore the offered edits; please report the stack trace it
  printed.
