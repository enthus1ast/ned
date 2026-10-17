# Security

## Reporting a vulnerability

Please **don't open a public issue** for a security problem. Use the repository's private vulnerability
reporting (the *Security* tab › *Report a vulnerability*) and include what an attacker could do, the steps or a
file that shows it, and ned's version (`ned --version`). You will get an answer within a week; a fix for a real
problem is released as soon as it is ready, and you are credited unless you would rather not be.

Only the newest release gets security fixes — updating is always the remedy.

## What counts

- Opening a file or a folder makes ned run something it should not. Until you trust a folder (*Workspace: trust
  this folder*), nothing of it may run: not the Nim compiler (which runs `config.nims` and macros), nimble,
  nimsuggest, its tests, its program, nor the programs its own settings name (language servers, run commands,
  formatters, MCP servers) — only ned's own engines read it.
- A secret leaks: an API key, an SSH password or passphrase, a token in a git link — into a command line other
  programs can read, a log, a temporary file others can read, the settings-sync repository, or a crash report.
- A file is written outside where it should be (a theme, a dictionary, an imported setting, a clone's folder),
  or a save can lose or corrupt your file.
- The terminal panel, the markdown preview or a hover lets text from a file send escape sequences to your terminal.

## How ned protects you (and what to check when you change it)

- **API keys are never put on command lines or logged.** They go to the AI provider in the request only; an MCP
  server's `env` values go to that server's own environment only. Settings sync leaves keys and tokens out.
- **SSH**: passwords and passphrases are typed into ssh in the terminal, never passed on a command line.
- **git clone** refuses a link with a login or token written into it (it would stay in `.git/config`); git asks
  for the login in the terminal instead.
- **Unsaved text that is checked** (`nim check`, C compilers, formatters) goes to private temporary files in a
  folder only you can read (0700), removed afterwards; old ones are swept at start-up.
- **Saves are atomic** (a temporary file renamed over the original, permissions kept), unsaved edits have
  recovery files, and the standard library and installed packages open read-only.
- **Folder trust** (`security.folderTrust`): in a folder not trusted yet, every program ned starts goes through one
  gate (`spawnProc`) that refuses the Nim compiler, nimble, nimsuggest, nimlangserver, testament and the folder's
  own commands — also inside `sh -c`, behind `env`, `nice`, `timeout` and the like — and says why. ned's own Nim and
  C engines still read the code. A folder's own settings that run programs (`.ned/settings.json`: `lsp`, `run`,
  `formatters`, `commands`, `ai.*` with MCP servers, `nim.nimsuggestPath`, `sync.repository` …) are ignored too,
  so opening a cloned repository cannot start programs or send your code elsewhere.
- **Tests run on save and the copies check** (`nim.testOnSave`, `nim.showCopies`) build into private folders
  (0700), removed afterwards; tests are stopped after two minutes.
- The fuzzer refuses to run as root unless it is given a user to drop to (`NED_FUZZ_USER`).
