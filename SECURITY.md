# Security

## Reporting a vulnerability

Please **don't open a public issue** for a security problem. Use the repository's private vulnerability
reporting (the *Security* tab › *Report a vulnerability*) and include what an attacker could do, the steps or a
file that shows it, and ned's version (`ned --version`). You will get an answer within a week; a fix for a real
problem is released as soon as it is ready, and you are credited unless you would rather not be.

Only the newest release gets security fixes — updating is always the remedy.

## What counts

- Opening a file or a folder makes ned run something it should not (a folder's own settings that start programs —
  its language servers, run commands, formatters, MCP servers — count only once you ran *Workspace: trust this
  folder*, never just because it was opened).
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
- **A folder's own settings that run programs** (`.ned/settings.json`: `lsp`, `run`, `formatters`, `commands`,
  `ai.*` with MCP servers, `nim.nimsuggestPath`, `sync.repository` …) are ignored until you trust the folder, so
  opening a cloned repository cannot start programs or send your code elsewhere.
- The fuzzer refuses to run as root unless it is given a user to drop to (`NED_FUZZ_USER`).
