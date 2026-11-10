# Files ned uses

| path | contents |
|---|---|
| `~/.config/ned/config.json` | your settings (`$XDG_CONFIG_HOME` is respected) |
| `~/.config/ned/themes/*.json` | your own and imported themes |
| `~/.config/ned/words.txt` | your own dictionary words (spell check) |
| `~/.config/ned/plugins/<name>/` | your plugins (`plugin.nims`); a project's are in `<project>/.ned/plugins/` |
| `~/.cache/ned/plugins/` | the plugins' host, its compiled version (`plugins.native`), the library they import, what they registered |
| `~/.local/share/ned/plugins/<name>/` | a plugin's own files (`dataDir()`) |
| `~/.local/share/ned/dictionaries/` | dictionaries downloaded by *Spell check: download a dictionary…* |
| `<folder>/*.ned-workspace` | a multi-root workspace (*Workspace: save as…*) |
| `<project>/.ned/settings.json` | project settings, run configurations |
| `~/.local/state/ned/state.json` | recent files, sessions, layout, bookmarks, trusted folders (`$XDG_STATE_HOME`) |
| `~/.local/state/ned/swap/` | recovery files of unsaved edits |
| `~/.local/state/ned/history/` | local history (previous versions of saved files) |
| `~/.local/state/ned/chats/` | saved AI chats (newest 200) |
| `~/.local/state/ned/ai.log` | the assistant's request log, when `ai.log` is on (the last 4 MB, and the 4 MB before them in a second file beside it) |
| `~/.local/state/ned/nimindex.json` | index of the Nim standard library's exports |
| `~/.cache/ned/index/` | the engine's reading of the standard library, packages and the project's files, kept between sessions (`nim.indexCache`; `$XDG_CACHE_HOME`; safe to delete) |
| `~/.cache/ned/nedastcheck-*` | the Nim parser check the formatter can use (`nim.format.verify`), built once |
| `~/.local/state/ned/errors.log` | details of internal errors, if any ever happen (please include it in a report) |
| `~/.local/state/ned/remote/` | the local copies of remote (SSH) folders, and `remotes.json` |
| `~/.local/state/ned/settings-sync/` | the clone of your settings repository (*Settings sync: push …*, *Settings sync: pull …*) |
| `$TMPDIR/ned-UID/remote-PID.sock` | the socket a running ned answers on (`ned --remote …`, `ned FILE` in its terminal; only you can reach it; gone when it quits) |

*Reset everything* (File › Preferences, the palette) — or `ned --reset` from the shell — removes all of these but
the project's own `.ned` (unless you tick it), and ned starts again as on its first run. On Windows the same paths
are under your user folder (`C:/Users/you/.config/ned` …) and the socket's folder is `%TEMP%/ned-0`.
