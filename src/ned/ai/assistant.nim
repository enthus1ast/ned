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

  AiPlanState = enum apNone, apPlanning, apReady, apDoing

type ChatSpan = object
  t: string
  fg, bg: Rgb
  at: set[Attr]
type ChatLine = object
  spans: seq[ChatSpan]
  bg: Rgb
  act: Action
  tip: string
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
  if cfgAiKey.len > 0: cfgAiKey else: getEnv(aiKeyEnvName())

proc aiModel(): string =
  if aiFastOn and cfgAiFastModel.len > 0: return cfgAiFastModel
  if cfgAiModel.len > 0: return cfgAiModel
  case cfgAiProvider
  of "anthropic": "claude-sonnet-5-5"
  of "deepseek": "deepseek-chat"
  of "ollama": "qwen2.5-coder"
  else: ""

proc aiRunning(): bool = aiBusy

proc aiStatus(): string =
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
