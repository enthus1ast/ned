# ════════════════════════════════════════════════════════════════════════════
#  AI assistant: streaming chat + agent tools (Anthropic, OpenAI-compatible, Ollama) via curl
# ════════════════════════════════════════════════════════════════════════════

type
  AiCall = object
    id, name, args: string
    state: int            # 0 waiting for approval, 1 approved/running, 2 done, 3 denied
    result: string
    isError: bool
    expanded: bool
    diff: string          # edit_file / write_file: the change as a unified diff
    check: string         # edits: what checking the file found ("" not checked, "ok", or "2 errors")
    checkOut: string      #   the errors
  AiMsg = object
    role: int             # 0 user, 1 assistant, 2 tool results, 3 notice
    text: string
    calls: seq[AiCall]
    checked: bool         # its edits were checked (ai.checkEdits)
    shown: string         # what the chat shows for a user message (attachments hidden)
    pics: seq[string]     # pictures sent with it (@shot.png): for models that read them
    think: string         # the assistant's: what a thinking model thought before it answered (never sent back)
    thinkShown: int       # … 0 as ai.showThinking says, 1 opened, 2 folded (a tap on its line)

  AiPlanState = enum apNone, apPlanning, apReady, apDoing

# ── pictures with a message (@shot.png): for models that read them ──

const AiPicMax = 5_000_000              # (the most the providers take, per picture)
var aiPicCache: Table[string, (int64, string)]   # picture → (when it changed, its base64): each turn sends them all

proc aiPicMime(path: string): string =
  ## the MIME type of a picture the assistant can take, from its file extension (PNG, JPEG, GIF, WebP); empty for any
  ## other file
  case splitFile(path).ext.toLowerAscii
  of ".png": "image/png"
  of ".jpg", ".jpeg": "image/jpeg"
  of ".gif": "image/gif"
  of ".webp": "image/webp"
  else: ""

proc aiPicWhy(path: string): string =
  ## why a picture cannot go with a message ("" when it can)
  if not fileExists(path): return "not found"
  if aiPicMime(path).len == 0: return "the assistant takes PNG, JPEG, GIF and WebP pictures"
  try:
    if getFileSize(path) > AiPicMax: return "over 5 MB, the most the assistants take"
  except CatchableError: return "cannot be read"
  ""

proc aiPicData(path: string): string =
  ## the picture in base64 ("" when it cannot be read any more)
  try:
    let t = getLastModificationTime(path).toUnix * 1000 + getFileSize(path) mod 1000
    aiPicCache.withValue(path, e):
      if e[][0] == t: return e[][1]
    result = base64.encode(readFile(path))
    aiPicCache[path] = (t, result)
  except CatchableError: result = ""

proc aiUserContent(m: AiMsg, text, style: string): JsonNode =
  ## a user message's content, its pictures with it — style: "openai" (chat completions, Ollama, the compatible
  ## ones), "responses" (OpenAI's Responses API), "anthropic"
  if m.pics.len == 0: return %text
  result = newJArray()
  case style
  of "responses": result.add %*{"type": "input_text", "text": text}
  of "anthropic": discard                        # (Anthropic: the pictures first, then what is asked of them)
  else: result.add %*{"type": "text", "text": text}
  for p in m.pics:
    let d = aiPicData(p)
    if d.len == 0: continue
    let mime = aiPicMime(p)
    case style
    of "anthropic": result.add %*{"type": "image", "source": {"type": "base64", "media_type": mime, "data": d}}
    of "responses": result.add %*{"type": "input_image", "image_url": "data:" & mime & ";base64," & d}
    else: result.add %*{"type": "image_url", "image_url": {"url": "data:" & mime & ";base64," & d}}
  if style == "anthropic": result.add %*{"type": "text", "text": text}

type ChatSpan = object
  t: string
  fg, bg: Rgb
  at: set[Attr]
  link: string          # the Markdown preview: where a tap on it goes (a URL, a file, #a-heading)
type ChatLine = object
  spans: seq[ChatSpan]
  bg: Rgb
  act: Action
  tip: string
  src: int              # the Markdown preview: the source line it comes from
  pic: string           # … a picture's row: its file (picRow of picRows)
  picRow, picRows: int
  file: string          # code block header: the file the block is for (```nim src/app.nim)

var
  aiMsgs: seq[AiMsg]
  aiJob: Job
  aiBusy = false
  aiPhase = ""            # thinking | writing | running tools | waiting for approval
  aiSteps = 0
  aiInput = ""
  aiInputCur = 0
  aiHistIdx = -1
  aiScrollOff = 0         # rows above the bottom (0 = follow)
  aiVersion = 0
  aiRaw = ""              # non-SSE output (errors)
  aiBlocks: Table[int, int]   # anthropic content-block index → call index (-1 = text)
  aiHttp = ""
  aiTmp: seq[string]
  aiInlineMode = false    # current request is an inline edit
  aiInlineBuf = -1
  aiInlineA, aiInlineE: Pos
  aiInlineText = ""
  aiTokensOut = 0
  aiCmdJob: Job
  aiAlwaysAllow: HashSet[string]
  aiRendered: seq[ChatLine]
  aiRenderedKey = ""
  aiChatId = ""           # saved chats: <state>/chats/<id>.json
  aiUsageIn, aiUsageOut, aiUsageCacheRead, aiUsageCacheWrite: int
  aiWarnOk = false          # this run's big request was allowed
  aiReqIn, aiReqOut, aiReqCacheRead, aiReqCacheWrite: int
  aiSplit: ThinkSplit       # the reply being read: the <think> … </think> a model writes into its answer, taken out
  aiInlineThink = ""        # … an inline edit's or a one-shot request's thinking (kept out of what it writes)
  aiReqStart: MonoTime      # when the request went: the chat counts the seconds until something comes
  aiOneShotCb: proc(t: string) {.closure.}
  aiCheckGen = 0          # bumped when the assistant stops: a check of its edits still running is then dropped
  aiRespApi = false       # the running request uses OpenAI's Responses API
  # plan first, then do it (plan.nim)
  aiPlanState = apNone
  aiPlanTask = ""
  aiPlanSteps: seq[string]
  aiPlanAt = 0            # the next step to do
  aiPlanAuto = false      # all the steps without asking in between
  aiPlanCps: seq[int]     # each step's restore point (a checkpoint id; -1: the step changed no files)

proc aiProviderBase(): string =
  ## the address the requests go to: ai.base when it is set (without a closing `/`, and without `/v1` for Anthropic, to
  ## which ned adds its own path), else the provider's usual one (empty for an unknown provider)
  if cfgAiBase.len > 0:
    result = cfgAiBase.strip.strip(chars = {'/'})
    # ned adds /v1/messages for Anthropic itself; a base URL copied with /v1 must not double it
    if cfgAiProvider == "anthropic" and result.endsWith("/v1"): result.setLen(result.len - 3)
    return
  case cfgAiProvider
  of "anthropic": "https://api.anthropic.com"
  of "openai": "https://api.openai.com/v1"
  of "openrouter": "https://openrouter.ai/api/v1"
  of "groq": "https://api.groq.com/openai/v1"
  of "deepseek": "https://api.deepseek.com/v1"
  of "gemini": "https://generativelanguage.googleapis.com/v1beta/openai"
  of "mistral": "https://api.mistral.ai/v1"
  of "ollama": "http://localhost:11434/v1"
  else: ""

proc aiKeyEnvName(): string =
  ## the name of the environment variable that holds the API key: ai.keyEnv when set, else the provider's usual one
  ## (AI_API_KEY for the others)
  if cfgAiKeyEnv.len > 0: return cfgAiKeyEnv
  case cfgAiProvider
  of "anthropic": "ANTHROPIC_API_KEY"
  of "openai": "OPENAI_API_KEY"
  of "openrouter": "OPENROUTER_API_KEY"
  of "groq": "GROQ_API_KEY"
  of "deepseek": "DEEPSEEK_API_KEY"
  of "gemini": "GEMINI_API_KEY"
  of "mistral": "MISTRAL_API_KEY"
  else: "AI_API_KEY"

proc aiKey(): string =
  ## the API key: the one in the settings, else the one in the environment variable
  if cfgAiKey.len > 0: cfgAiKey else: getEnv(aiKeyEnvName())

proc aiModel(): string =
  ## the model to ask: the fast model while fast mode is on and one is set, else ai.model, else the provider's default
  ## (empty when there is none)
  if aiFastOn and cfgAiFastModel.len > 0: return cfgAiFastModel
  if cfgAiModel.len > 0: return cfgAiModel
  case cfgAiProvider
  of "anthropic": "claude-sonnet-5-5"
  of "deepseek": "deepseek-chat"
  of "ollama": "qwen2.5-coder"
  else: ""

# whether the assistant is busy with a request
proc aiRunning(): bool = aiBusy

proc aiStatus(): string =
  ## what the assistant is doing, for the status bar: its phase ("thinking…" when it has none) while it works,
  ## "editing…" during an inline edit, else empty
  if aiBusy: (if aiPhase.len > 0: aiPhase else: "thinking…")
  elif aiInlineMode: "editing…"
  else: ""

# ── tools the agent may call ──

const AiTools = [
  ("read_file", "Read a text file from the project. Returns numbered lines. Use start_line/end_line (1-based) for big files.",
   """{"type":"object","properties":{"path":{"type":"string","description":"path relative to the project root"},"start_line":{"type":"integer"},"end_line":{"type":"integer"}},"required":["path"]}"""),
  ("list_files", "List project files (relative paths). Optional substring filter.",
   """{"type":"object","properties":{"filter":{"type":"string","description":"substring that paths must contain"}}}"""),
  ("search", "Search the project for a literal string. Returns path:line: text matches.",
   """{"type":"object","properties":{"query":{"type":"string"},"path":{"type":"string","description":"optional sub-folder"}},"required":["query"]}"""),
  ("edit_file", "Replace an exact, unique snippet of a file with new text. old_text must match exactly (including indentation) and appear once. Use an empty old_text to append.",
   """{"type":"object","properties":{"path":{"type":"string"},"old_text":{"type":"string"},"new_text":{"type":"string"}},"required":["path","old_text","new_text"]}"""),
  ("write_file", "Create a file or replace its whole content.",
   """{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}"""),
  ("run_command", "Run a shell command in the project (e.g. nim c -r, nimble test, git status). Returns exit code and output.",
   """{"type":"object","properties":{"command":{"type":"string"},"cwd":{"type":"string","description":"optional folder relative to the project root"}},"required":["command"]}"""),
  ("get_diagnostics", "Compiler/language-server errors and warnings, for one file or the whole project.",
   """{"type":"object","properties":{"path":{"type":"string"}}}""")]
