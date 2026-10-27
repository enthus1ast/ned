# The AI assistant

ned's assistant answers questions about your code, explains and fixes problems, writes tests and doc comments,
rewrites a selection in place, and — as an agent — reads, searches and edits files and runs commands, with you
approving each change. It works with the provider you choose, or with a model on your own device, offline.
Every setting is in [the reference](../reference/settings.md#ai).

## Setting it up

Set your provider's key in your shell (e.g. `~/.bashrc`) and start ned again:

```sh
export ANTHROPIC_API_KEY=…     # or OPENAI_API_KEY, OPENROUTER_API_KEY, GROQ_API_KEY, DEEPSEEK_API_KEY …
```

Choose the provider and the model with *AI: choose provider…* and *AI: choose model…* (or *AI: settings…*), or in
the settings: `ai.provider` (anthropic, openai, openrouter, ollama, groq, deepseek, gemini, mistral, custom),
`ai.model`, and `ai.baseUrl` for Ollama or any OpenAI-compatible server. `ai.apiKeyEnv` names another environment
variable for the key, and `ai.apiKey` holds one in the settings (an environment variable is safer). *Type a model
id…* in the model list takes any model your provider offers. Keys are handed to `curl` through a private temporary
file, never on a command line.

**No key, no internet**: *AI: on this device, offline (Ollama, llama.cpp)…* (also first in *AI: choose provider…*)
runs a model on your phone or computer. It finds Ollama — or installs it (`pkg install ollama` in Termux, `brew
install ollama`, Ollama's script on Linux) — starts it, offers the Qwen 2.5 Coder model that fits the device's
memory (0.5B under 3 GB, 1.5B from 3 GB, 3B from 5 GB, 7B from 9 GB, 14B from 18 GB; *Other models…* for the
rest), downloads it with its progress in the status bar, sets `ai.provider` and `ai.model`, and times a first
answer. llama.cpp's `llama-server` on port 8080 is used the same way. `ai.localUrl` says where Ollama listens.

**OpenAI**: ned speaks both Chat Completions and the Responses API (`ai.openaiApi`: auto, chat, responses). For
reasoning models (GPT-5 and later, the o-series) it sends what they accept: `max_completion_tokens` with room to
think, the `developer` role, no temperature. A model that only runs on the Responses API, or an organisation that
is not verified for streaming, is handled by itself. When an endpoint refuses a parameter, ned changes the request,
tries again, and remembers it for that model.

## Secrets

Before anything is sent, ned replaces the secrets in it with placeholders (`ai.redactSecrets`, on): API keys and
tokens it knows by their shape (OpenAI, Anthropic, GitHub, GitLab, Slack, Stripe, Google, AWS, Hugging Face …),
private keys, JSON web tokens, passwords in URLs and connection strings, `Authorization` headers, and the values of
names that say they are secrets — `DB_PASSWORD=…`, `"apiKey": "…"`, `client_secret = '…'`. The model sees
`DB_PASSWORD=[REDACTED:password#1]`; the same secret is the same placeholder for the whole session, and the model is
told to keep a placeholder where its secret belongs. When it writes one into a file — an edit, a new file, an inline
edit, a suggestion, a code block you apply — ned puts the secret back, so your file keeps it; a command the agent
runs, or an MCP call, keeps the placeholder. Code that only names a password (`password: string`,
`let token = nextToken()`) is left as it is.

Files of secrets are not sent at all: `.env` and `.env.*` (not `.env.example`), `*.pem`, `*.key`, `id_rsa` and the
other `id_…` keys, `.netrc`, `.npmrc`, `credentials.json`, `*.tfstate` …, and whatever the project's `.gitignore`
keeps out for its secrets (`config/prod-secrets.yml`). With one of them open, the assistant is told it was left out,
the agent cannot read or search it, and inline suggestions stay off in it.

## Chatting

**Alt+C** opens the assistant in the right dock. Type and Enter sends; the answer streams in, with its code blocks
coloured. The current file — or the selection — goes along with each message (`ai.includeFile`), and for Nim files
the definitions of the procs and types your code uses too, found by ned's engine (`ai.nimContext`), so the answers
know your code and not only its name.

- **Mentions** add more: `@file`, `@selection`, `@diff` (what you changed), `@staged`, `@problems`, `@terminal`
  (the terminal's last output), `@tree` (the project's files), or `@path/to/file`.
- **Pictures**: `@shot.png` — or a picture's path pasted into the message (a terminal pastes a dropped file's path),
  or *AI: attach a picture…*, or *▣ a picture…* after typing `@` — sends the picture with the message, for a model
  that reads pictures: a screenshot of an error, a design to build, a diagram. *AI: attach a picture…* lists the
  project's pictures and the newest screenshots and photos (in Termux, `~/storage/shared/Pictures/Screenshots` and
  the camera's, once `termux-setup-storage` has run). PNG, JPEG, GIF and WebP up to 5 MB; the chat shows each one
  drawn small, with its size, and a tap opens it. A model that cannot read pictures says so in its error, and ned
  adds that the message has some.
- **Slash commands**: `/explain` `/fix` `/tests` `/doc` `/review` `/optimize` `/commit` `/plan` `/regen` `/new`
  `/history` `/model` `/provider` `/help`.
- **Code blocks** have *Copy*, *Insert* (at the cursor) and — when the block names a file — *Apply*, which shows
  the change as a diff first.
- **From the code**: *AI: explain code*, *AI: ask about selection*, *AI: explain problem at cursor*, *AI: fix
  problem at cursor*, *AI: fix problems in file*, *AI: add doc comments* — also on the editor's right-click menu
  and in the AI menu. A Nim fix is checked with `nim check` before it is applied.
- **Chats are kept**: *AI: chat history…* (or the ◷ button) lists them and resumes one (the newest 200);
  *AI: new chat* starts again, *AI: regenerate last reply* asks once more, *AI: stop* stops an answer.
- **Project instructions**: `AGENTS.md`, `CLAUDE.md`, `NED.md`, `.ned/instructions.md` or
  `.github/copilot-instructions.md` in the project are added to what the model is told (`ai.projectInstructions`);
  `ai.systemPrompt` adds your own.
- **What it costs**: a token counter under the chat — in dollars with `ai.price` — and prompt caching for Anthropic
  (`ai.promptCaching`: repeated context costs about a tenth). A request bigger than `ai.warnTokens` asks first.
  `ai.fastModel` adds a ⚡ switch between a quick, cheap model and the smart one (*AI: fast / smart model*).

## The agent

With agent mode on (`ai.agent`, *AI: toggle agent mode*), the assistant can use tools: read a file, list files,
search the project, edit or write a file, run a command, and read the problems. You stay in charge:

- **Approval.** Edits and commands wait for you (`ai.autoApprove`: none, reads — the default: reading and searching
  go ahead —, edits, all). A file change is shown as a **diff** first, with *Open diff* for the whole change.
  Anything outside the project folder always asks, and the agent cannot edit outside it.
- **It checks its own work.** The files it edits are checked — `nim check` for Nim; `py_compile`, `node --check`,
  `cargo check` … for the others — and what is wrong goes back to it, so it fixes its mistakes before it says it is
  done (`ai.checkEdits`). `ai.maxSteps` (30) limits the tool steps of one request.
- **Undo.** Every run keeps the files it changed: the toast at the end, or *AI: undo the assistant's changes…*,
  puts them back. *AI: review the assistant's changes…* shows each file's change side by side; `r` undoes one.
- **Plan first** (*AI: plan a change, then do it step by step…*, or `/plan …`): the assistant reads the code —
  editing and commands are refused while it plans — and answers with numbered steps. *Do it* runs them all
  (stopping when a step leaves errors), *One step* asks again after each, *Change the plan…* sends what should be
  different. Every step has a restore point: *AI: the plan…* › *Back to before step N*.
- **Tests.** *AI: write tests* keeps the tests it writes only when they compile and pass. On a failing test,
  Alt+Enter on the failed check (or *AI: make the failing test pass*) sends the test, how it failed and the code
  it tests; the change is kept only when the test then passes.
- In a folder you have not trusted, the project's AI settings are ignored, and what would run the project's code —
  the compiler, nimble, its tests — is held back for the agent as it is for you ([Safety](safety.md)).

## MCP servers

MCP (Model Context Protocol) servers give the agent more tools — GitHub, a database, a browser. ned starts the ones
in `ai.mcpServers` and offers their tools to the agent; each call asks first unless `ai.autoApprove` is `all`:

```json
{"ai.mcpServers": {"github": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"],
                              "env": {"GITHUB_TOKEN": "…"}}}}
```

A server's **prompts** are chat commands, `/server:name`, and its **resources** are mentions, `@server:uri`.
*AI: MCP servers…* lists the servers — ready, starting or failed — with their tools, resources and prompts, and
restarts them. Tokens go to the server's environment, never onto
a command line, and a project's settings cannot add servers until you trust its folder.

## In the editor

- **Edit a selection** (Alt+Shift+C, *AI: edit selection…*): say what to change, and the selection — or the block
  the cursor is in — is rewritten in place; Ctrl+Z takes it back.
- **Code from a comment** (as in Zed and Aider): write a comment saying what you want — `# parse the header and
  return its fields` — and with the cursor on it press **Alt+Shift+C**, or tap the **✦ write it** after it. The
  assistant writes the code below the comment; you see it side by side with the file first, with what the compiler
  says of it (Nim: `nim check`), and *Take it* or *Leave it*.
- **AI! and AI? comments**: a comment that ends in `AI!` — `# make this a func AI!`, `// handle the empty case AI!`
  — is a request: when you save the file, the assistant makes the change, anywhere in the file, and removes the
  comment; you see it side by side, checked, before it is used. A comment that ends in `AI?` — `# why is this slow
  AI?` — is a question, answered in the chat. Each comment is acted on once. `ai.commentCommands` turns them off,
  `ai.commentButton` the ✦.
- **Inline suggestions** (`ai.inlineCompletion`, off by default because it sends code on every pause; *AI: toggle
  inline suggestions*): grey text after the cursor, Tab takes it. `ai.inlineCompletionModel` picks a fast model for
  them; for Nim, a suggestion that names something that does not exist is dropped (`ai.checkSuggestions`). On the
  empty line under a comment, the suggestion is the code the comment describes — a whole block of it.
- **Next edits from AI** (`ai.nextEdit`, off by default): after an edit with no repeat in the file, the quick model
  is asked what edit follows from it — shown as `→ … ⇥ (AI)`, Tab takes it.

## With git

- *Git: generate commit message with AI* (also in the Git dock and `/commit`): the staged diff goes to the model,
  and the message it writes waits in the commit prompt for you to change or accept — see [Git](git.md).
- *AI: review staged changes (findings in Problems)* — also *Review the changes with AI* in the Git dock: the model
  reads your staged changes and its findings appear in Problems, at their lines (*AI: clear review findings* removes
  them).
- *Git: why did this line change? (AI)*: the commit that last changed the line the cursor is on (git blame), its
  message and what it did to the file go to the assistant, which explains in the chat what the change was for.
- *Git: resolve the conflicts with AI* — also in the Git dock during a merge: the file's conflicts go to the
  assistant with the rest of the file; for Nim, `nim check` reads what it wrote, and the compiler's errors go back
  to it once to be fixed; then you see the result side by side with the conflicts, and take it or leave it.
