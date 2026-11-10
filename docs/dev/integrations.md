# Integrations

How ned works with the programs and services around it: language servers, nimsuggest, debuggers, shells, git,
AI providers, SSH servers, scripts that drive a running ned, and a settings repository. They have one thing in
common: each runs as **another process**, talked to through non-blocking pipes or sockets that the main loop polls
([Architecture › The main loop](architecture.md#the-main-loop)). Nothing waits for them on the main loop; their
answers are handled in the round they arrive, and a callback finds its buffer again by id.

Programs are started with `spawnProc` or `startJob` ([`run/process.nim`](../../src/ned/run/process.nim)): fork and
exec, a process group of their own (so stopping one stops its helpers too), and a lower priority for background
work. A job's output is collected as it comes; its `onDone` callback runs when it ends.

## Language servers

[`src/ned/lsp/`](../../src/ned/lsp):

| file | what it does |
|---|---|
| [`lsp/client.nim`](../../src/ned/lsp/client.nim) | starting a server (`lspSpawn`: the `initialize` request, the client's capabilities), finding the server for a buffer (`lspFor`), opening and syncing documents (`lspAttach`, `lspSync`: the whole text after a 120 ms pause), positions (UTF-8 or UTF-16, whichever the server takes), completion's answers, workspace edits |
| `lsp/handlers.nim` | reading answers (`lspRead`: `Content-Length` framing, at most 8 ms a round) and handling them by the kind of request they answer (`LspReq`); the server's own requests (`workspace/configuration`, `workspace/applyEdit` …); a polite shutdown, then the whole process group |
| `lsp/codeactions.nim`, `lsp/inlays.nim`, `lsp/doclinks.nim`, `lsp/renamepreview.nim` | quick fixes, inlay hints, pull diagnostics, document links, formatting as you type, the rename preview |
| `lsp/embedded.nim` | HTML, CSS, SQL and JSON inside Nim strings through their servers: hidden documents with that code at the same lines |

Which server a language gets: the `lsp` setting first, then the candidates in the language's `Lang.lsp` list
(`core/languages.nim`), the first one installed. A second server can run next to the main one for its problems and
fixes only (`lsp.alsoRun`, and known linters with `lsp.linters`). Each server gets a `uid`; the problems it reports
carry it (`Diag.srv`).

A server that exits is started again after a short wait that grows with each exit; at the third exit in a row it
is given up for the session (one that ran for two minutes before exiting starts the count again; the palette's
*Restart language server* tries again). Files
over 40 000 lines or in large-file mode are not given to servers. For Nim, a server is only used when
`nim.ide` is `nimlangserver`; otherwise ned's own engine answers.

## nimsuggest

With `nim.nimsuggest` on, the Nim engine asks nimsuggest for what only the compiler knows
([`nim/nimsuggest.nim`](../../src/ned/nim/nimsuggest.nim), answers read in `nim/nimsuggestread.nim`). One process
per project (`nimsuggest --stdin --v4 --maxresults:500 project.nim`, `--v3` for older Nims), at most two at once
(phones have little memory). Requests (`NsReq`) wait in a queue while others are in flight. The main loop stops a
nimsuggest that grows past `nim.nimsuggestMaxMB` (800 MB on Termux unless set) and one idle for
`nim.nimsuggestIdleMinutes`; it starts again on the next question.

With nimsuggest off, ned still asks the compiler where its engine has no answer — one nimsuggest run for one
question (`nim/compileranswers.nim`), the lines around the screen in the background (`nim/oracle.nim`), the names
macros make (`nim/macronames.nim`) — and `nim check -` checks the unsaved text after a pause
(`nim/typingcheck.nim`). Each of these runs on a private copy of the text, one compiler at a time, and not while
you type.

## The debugger

| file | what it does |
|---|---|
| [`debug/gdb.nim`](../../src/ned/debug/gdb.nim) | gdb's machine interface (`gdb --interpreter=mi3`): breakpoints (with conditions and logpoints), stepping, the call stack, variables, watches, values shown inline |
| [`debug/dap.nim`](../../src/ned/debug/dap.nim) | the Debug Adapter Protocol, as VS Code and Zed speak it: debugpy (Python), gdb's own DAP mode, lldb-dap (C, C++, Rust), delve (Go, over TCP) … each adapter a JSON entry (`debug.adapters` adds yours), in the same Debug panel with the same keys |
| `debug/gdbterm.nim` | gdb in the integrated terminal |

Breakpoints are kept per file (`breakpoints` in `core/state.nim`), move with the edits (`shiftMarks` in
`editor/buffer.nim`), and are saved with the session. The debugger's output descriptors (`dbgProc`, `dapSock`) are in
the main loop's `poll`.

## The terminal

[`src/ned/term/`](../../src/ned/term):

| file | what it does |
|---|---|
| `term/pty.nim` | the pseudo-terminal (`posix_openpt`; ConPTY on Windows) and the `Term` type: the screen's rows, scrollback, modes, the commands run |
| `term/vt.nim` | the terminal emulator: an xterm subset (`feed` parses the shell's output: CSI, OSC, SGR colours, the alternate screen, scroll regions), the shell started in it (`newTerm`) |
| `term/shell.nim` | shell integration: bash, zsh and fish mark each prompt, command line, output and exit code (OSC 133) through start-up files ned writes; *Terminal: commands…* and jumping between commands come from them |
| `term/panel.nim` | the terminal panel: each terminal's output read (`pumpTerms`), tabs of terminals, drawing, keys, selection |
| [`term/termhost.nim`](../../src/ned/term/termhost.nim) | terminals that outlive ned (`terminal.keepRunning`): the shell belongs to a small process of its own (`ned --term-host`) that holds the pseudo-terminal and keeps the last MB of output; ned talks to it through a private socket (0600) with framed messages, and the next ned in the same folder attaches again and is played back what it missed |
| `term/repl.nim`, `term/repltabs.nim` | Send to REPL: code typed into the language's REPL (inim or `nim secret`, python, node …) in its own terminal tab |

In the terminal ned is the editor of git and of the shell: `terminal.editorEnv` sets `GIT_EDITOR` (and `EDITOR`,
`VISUAL` where they are not set) to `ned --wait`, which goes through the [remote-control
socket](#the-remote-control-socket).

## git

[`src/ned/git/`](../../src/ned/git) runs git as jobs (`startJob(jkGit, …)`), never in the way of typing:

| file | what it does |
|---|---|
| `git/repos.nim` | the repositories of the open folders (a workspace can have several); the Git dock acts on one at a time |
| `git/status.nim` | `git --no-optional-locks status --porcelain=v1 -b` of each repository; `gitRun` for one command with its result said |
| [`git/watch.nim`](../../src/ned/git/watch.nim) | git status when something changes rather than every few seconds: inotify (Linux, Android) on `.git`, its refs, the project's first folder levels and the open files' folders; elsewhere — or for a change deeper down — the Git dock still looks every so often (`git.autoRefresh`) |
| `git/marks.nim` | the change marks in the gutter, live: the buffer compared with the file as git has it (`gitBase`, `editor/linediff.nim`), worked out after a pause; blame |
| `git/changesview.nim`, `git/conflicts.nim`, `git/mergeeditor.nim`, `git/history.nim`, `git/advanced.nim` | the changes view (a multibuffer), merge conflicts, history, bisect, rebase, cherry-pick, branches |
| `git/commands.nim`, `git/setup.nim`, `git/signin.nim`, `git/undo.nim`, `git/precommit.nim` | push and pull (asking for a login in the terminal), init and clone, signing in to GitHub (never a token seen by ned), undo through the reflog, checks before a commit |
| `git/github.nim`, `git/reviews.nim`, `git/aigit.nim` | GitHub through `gh`, pull-request review comments on their lines, the assistant with git |

For a [remote folder](#remote-folders-over-ssh) git runs on the server, where the real repository is
(`gitWrap`).

## The AI assistant

[`src/ned/ai/`](../../src/ned/ai):

| file | what it does |
|---|---|
| [`ai/endpoints.nim`](../../src/ned/ai/endpoints.nim) | the request sent with `curl` as a job (`jkAi`): the headers, the API key among them, in a private temporary file (`curl -H @file`), never on a command line; the answer streamed (server-sent events) and read line by line as the job's output arrives; what an endpoint refuses (a parameter, a model's limits) learned and the request sent again without it; a thinking model's thoughts kept apart from the answer (`reasoning_content`, `reasoning`, Anthropic's `thinking_delta`, Mistral's parts) and never sent back; the request log (`ai.log`) written before the secrets go back into what the model wrote |
| [`ai/streamparts.nim`](../../src/ned/ai/streamparts.nim) | a module of its own (`tests/unit/tstreamparts.nim`): `<think>` … `</think>` split from an answer however the stream cuts the tags; a string of a tool call's arguments read while they are still coming (what the chat shows of a call being written) |
| `ai/requests.nim`, `ai/assistant.nim` | building the request for the provider (Anthropic, OpenAI-compatible, OpenRouter, Ollama …): the system prompt, the context, the conversation |
| `ai/agenttools.nim` | the agent's tools (read, search, edit or write a file, run a command): what runs without asking is set by `ai.autoApprove`; a path outside the project always asks; edits are shown as diffs to approve — and nothing is approved while the request still streams (`aiJob` set): a call may be half written |
| `ai/mcp.nim` | MCP servers (`ai.mcpServers`): JSON-RPC over their stdio, their tools offered to the agent |
| `ai/chats.nim`, `ai/chatview.nim` | saved chats, slash commands, @mentions; the chat drawn in the right dock |
| `ai/inlineedit.nim`, `ai/suggestions.nim`, `editor/nextedit.nim` | a selection rewritten; grey suggestions after the cursor (`ai.inlineCompletion`); next-edit suggestions |
| `ai/plan.nim`, `ai/review.nim`, `ai/comments.nim`, `ai/oneshot.nim`, `ai/offline.nim` | plan first then do it; the run's changes reviewed; code from comments (`AI!`, `AI?`); one-off requests (commit messages); a model on the device (Ollama or llama.cpp) |

The UI tests talk to a mock server ([`tests/ui/mocks/mockai.py`](../../tests/ui/mocks/mockai.py)) that answers
like the real APIs, refusals included, so the assistant is tested without a key.

## Remote folders over SSH

A remote folder is edited as a local copy ([`project/remote.nim`](../../src/ned/project/remote.nim),
[`project/remotesync.nim`](../../src/ned/project/remotesync.nim)): the file tree, search, the engines and most
language servers work on the copy as usual.

- One shared ssh connection (`ControlPath`) carries everything; `BatchMode` makes sure nothing stops to ask for a
  password in the background.
- Opening copies the folder over (`tar` through ssh, big generated folders left out by `remote.exclude`);
  `remote.autoSync` brings over what changed on the server every few seconds.
- Every save goes to the server at once (`writeFileSafe` calls `fileWritten`, whose hook pushes the file).
- The terminal, Run, tasks, tests and git run on the server, in the matching folder (`remoteCommand`), as a POSIX
  script that works whatever the account's login shell is (`remoteScript`).
- Language servers run on the server when it has them (`remote.languageServers`): the paths in their messages are
  mapped between the server's folder and the local copy (`lspMapJson`), and a file of the server's outside the folder
  (a library's definition) is fetched to read.

The UI suite tests it against a real SSH server when `NED_TEST_SSH=1` (`tests/ui/ssh-setup.sh` makes one on a
throwaway machine).

## The remote-control socket

[`src/ned/app/control.nim`](../../src/ned/app/control.nim) lets a running ned be told what to do, through a Unix
socket only you can reach (`remote-<pid>.sock` in ned's private folder, mode 0600). `ctlListen` opens it at start
and puts its path in `NED_SOCKET`, which everything ned starts inherits — above all its terminal:

- `ned FILE` typed in ned's terminal opens the file in that ned instead of starting a ned inside ned (`--new`
  starts one anyway);
- `ned --wait FILE` (git's editor there) opens the file in a tab and answers when the tab is closed;
- scripts: `ned --remote FILE[:LINE[:COL]]`, `--remote-command NAME`, `--remote-message TEXT`,
  `--remote-problems [NAME]` (a build's output on stdin becomes Problems), `--remote-get WHAT`, `--remote-list`.
  Without `NED_SOCKET`, `ctlFind` picks the ned whose project holds the files, else the last one started.

The protocol is one JSON request per line, and one or two answers ("waiting", then "done"). Each request carries
`"key"`, which ned writes beside the socket (`remote-<pid>.key`, 0600) and the client reads (`ctlKeyOf`): a program
in ned's sandbox (`plugins.sandbox`, sys/landlock.nim) can connect to the socket — Landlock does not limit that —
but cannot read the key, so ned refuses it. A kept terminal's host (`term-<id>.sock`) checks its own key the same
way, in the attach message. The UI tests clear
`NED_SOCKET` for the ned they start, so a test run inside ned's terminal does not talk to the ned it runs in.

## Settings sync

[`src/ned/config/sync.nim`](../../src/ned/config/sync.nim) puts your settings, key bindings, snippets, themes,
dictionary words and the list of your plugins in one bundle, exported to a file, imported from one, or kept in a
git repository of yours (`sync.repository`). API keys, tokens and MCP servers' environment values are taken out
first (`scrubSecrets`) and never leave the device. Syncing both ways is a three-way merge against the bundle of the
last sync (`syncMerge`): a value one side changed takes that side's; changed on both, this device's wins and the
conflict is named. With `sync.auto` it runs a moment after start and when ned quits.
