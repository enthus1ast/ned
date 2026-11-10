## ned — a fast, safe code editor and Nim IDE for Termux, Linux and macOS (Windows: WSL), in Nim (standard library only).
## It looks and behaves like a desktop editor inside the terminal.
##
##   Termux: pkg install nim git ripgrep curl
##   Build : nim c -d:release --opt:speed -o:$PREFIX/bin/ned src/ned.nim     (Linux: -o:ned)   — or: nimble install
##   Run   : ned [file|folder ...]          (file:line:col and +line work too)
##   Keys  : F10 menus · Ctrl+E command palette · Ctrl+P find file · F1 key bindings
##
##   Nim intelligence is built in: ned's own Nim index (completion with docs, hover, definition, signatures,
##   references, rename, outline) plus nimsuggest from your Nim install (types it cannot infer, live errors,
##   inlay hints). nimlangserver is optional ("nim.ide": "nimlangserver"). Nim formatting is built in too
##   (nph's style, checked); nph or nimpretty can be chosen instead ("nim.formatter").
##
##   Optional: nimble install inim            → Nim REPL in the terminal
##             pkg install gdb                → Nim: debug with gdb
##             pkg install termux-api (+ the Termux:API app) → system clipboard
##             export ANTHROPIC_API_KEY=…     → AI assistant (or OpenAI, OpenRouter, Ollama … see settings)
##
## Title bar with menus, docks (files, search & replace, git, Nim, tests · assistant, outline, timeline),
## tabs, split editor, breadcrumbs, minimap, bottom panel (problems, output, terminal), toasts, dialogs and
## context menus; integrated terminal (pty); AI chat + agent with diff approvals, saved chats, slash
## commands and inline suggestions; Vim mode; 42 themes; one commented settings file (plus per-project
## settings) with every option, including all nimlangserver settings; a built-in Nim engine and formatter;
## multi-cursor editing, regex find/replace, project-wide replace, folding, inlay hints, quick fixes
## (std imports, unused imports), test explorer, git changes/blame, bookmarks; crash-safe saves, recovery
## files and local history.

{.warning[BareExcept]: off.}
import std/[strutils, tables, sets, algorithm, json, times, monotimes, base64, sugar, editdistance]
when defined(windows): import ned/sys/winos as os   # (std/os, with '/' in the paths it makes)
else: import std/os
when defined(windows): import ned/sys/winposix as posix   # (Win32 and the C runtime behind the same names)
else: import std/[posix, termios]
from std/hashes import hash, Hash, `!&`, `!$`
from std/math import pow, round

# the parts that stand on their own (modules: compiled separately, in parallel)
import ned/core/images, ned/core/text, ned/core/editorconfig, ned/editor/regex, ned/format/formatters, ned/format/fmtcli, ned/nim/index,
       ned/nim/arccopies, ned/c/cindex, ned/c/cnim, ned/nim/nifread, ned/version, ned/testing/gcovdata, ned/editor/binfmt, ned/web/web, ned/core/encodings,
       ned/editor/asmview, ned/core/secrets, ned/sys/landlock, ned/app/releasecheck, ned/debug/clines, ned/ai/streamparts

const
  Version = NedVersion
  AppName = "ned"

# ── ned --startup-time: how long each step of starting takes, and the memory it uses ──

var
  startT0 = getMonoTime()          # when the program started
  startTrace = false               # --startup-time: the steps are timed, and ned quits once it has settled
  startMarks: seq[(string, float)] # (step, ms since start)
  startRss: seq[(string, float)]   # (when, resident memory in MB)

proc smark(name: string) =
  ## with --startup-time, notes a step of starting up and how many milliseconds have passed since the program started;
  ## otherwise it does nothing
  if startTrace: startMarks.add (name, float((getMonoTime() - startT0).inMicroseconds) / 1000.0)

proc rssMB(): float =
  ## the resident memory of this process, in MB (Linux and Android from /proc; elsewhere the peak so far)
  try:
    for l in lines("/proc/self/status"):
      if l.startsWith("VmRSS:"):
        return parseFloat(l[6 .. ^1].strip.splitWhitespace()[0]) / 1024.0
  except CatchableError: discard
  var ru: Rusage
  if getrusage(RUSAGE_SELF, addr ru) == 0:
    when defined(macosx): return float(ru.ru_maxrss) / 1048576.0
    else: return float(ru.ru_maxrss) / 1024.0
  0.0

# ── the parts of ned, in the order they build on each other: one program, so each part sees the ones
#    included before it (and what forward declarations announce) ──

include ned/core/types
include ned/core/state
include ned/core/utils
include ned/core/themes
include ned/core/screen
include ned/core/termcaps
include ned/core/keys
include ned/core/languages
include ned/core/highlight
include ned/core/lexgeneric
include ned/core/lexers
include ned/core/todos
include ned/core/messages
include ned/plugins/decor
include ned/editor/buffer
include ned/editor/loadsave
include ned/editor/softwrap
include ned/editor/motion
include ned/editor/editing
include ned/editor/find
include ned/app/forward
include ned/config/settings
include ned/config/session
include ned/project/files
include ned/editor/safewrite
include ned/editor/swap
include ned/editor/localhistory
include ned/editor/linediff
include ned/editor/buffers
include ned/project/remote
include ned/editor/save
include ned/run/process
include ned/nim/nimony
include ned/run/cerrors
include ned/run/output
include ned/run/configs
include ned/run/checks
include ned/nim/typingcheck
include ned/git/repos
include ned/format/apply
include ned/lsp/client
include ned/lsp/renamepreview
include ned/lsp/handlers
include ned/lsp/doclinks
include ned/format/commands
include ned/nim/project
include ned/nim/nimsuggest
include ned/editor/multibuffer
include ned/nim/nimsuggestread
include ned/nim/oracle
include ned/nim/compileranswers
include ned/editor/clipboard
include ned/editor/snippets
include ned/editor/html
include ned/editor/emmetcss
include ned/nim/engine
include ned/git/conflictmarks
include ned/nim/semantic
include ned/nim/answers
include ned/nim/oraclerun
include ned/nim/reflens
include ned/nim/highlights
include ned/nim/copies
include ned/nim/outline
include ned/editor/completion
include ned/nim/messages
include ned/nim/nimapis
include ned/nim/nim3checks
include ned/nim/enginechecks
include ned/nim/macronames
include ned/editor/diagnostics
include ned/editor/findreplace
include ned/editor/navigation
include ned/editor/search
include ned/editor/projectreplace
include ned/ui/actions
include ned/nim/why
include ned/editor/undotree
include ned/format/folder
include ned/nim/commands
include ned/git/status
include ned/git/watch
include ned/ui/outline
include ned/ui/fieldsel
include ned/ui/pickers
include ned/ui/prompts
include ned/nim/toolchain
include ned/nim/projectchecks
include ned/ui/themefiles
include ned/core/themeimport
include ned/config/sync
include ned/ui/promptkeys
include ned/ui/render
include ned/ui/icons
include ned/ui/regions
include ned/nim/macroview
include ned/ui/dialogs
include ned/ui/menus
include ned/ui/fields
include ned/ui/popupdraw
include ned/ui/forms
include ned/nim/atlas
include ned/ui/layout
include ned/ui/menubar
include ned/ui/titlebar
include ned/ui/tabbar
include ned/ui/breadcrumbs
include ned/ui/docks
include ned/ui/todosdock
include ned/ui/lists
include ned/ui/filetree
include ned/ui/dockframe
include ned/ui/panel
include ned/ui/statusbar
include ned/ui/quickinput
include ned/ui/minimap
include ned/ui/settingsui
include ned/config/reset
include ned/term/pty
include ned/term/shell
include ned/term/vt
include ned/term/repltabs
include ned/term/panel
include ned/ai/assistant
include ned/ai/mcp
include ned/ai/agenttools
include ned/ai/requests
include ned/ai/endpoints
include ned/ai/inlineedit
include ned/ai/chats
include ned/ai/context
include ned/ai/oneshot
include ned/ai/plan
include ned/ai/offline
include ned/ai/suggestions
include ned/editor/nextedit
include ned/ai/chatview
include ned/ui/mdpreview
include ned/editor/pictures
include ned/ui/welcome
include ned/editor/spell
include ned/ui/codeline
include ned/editor/rainbow
include ned/ui/doclines
include ned/ui/diffview
include ned/editor/swatches
include ned/editor/hexedit
include ned/editor/jumplabels
include ned/ui/editorview
include ned/ui/popups
include ned/ui/zen
include ned/ui/split
include ned/ui/paneviews
include ned/ui/contextmenus
include ned/editor/decompile
include ned/editor/cexplorer
include ned/nim/nifview
include ned/nim/nimnif
include ned/nim/nifprint
include ned/nim/nifcolors
include ned/nim/pnak
include ned/nim/astview
include ned/git/mergeeditor
include ned/ui/frame
include ned/app/commands
include ned/app/input
include ned/keymaps/vim
include ned/keymaps/vimex
include ned/editor/macros
include ned/editor/surround
include ned/keymaps/vimkeys
include ned/keymaps/emacs
include ned/keymaps/helix
include ned/editor/folding
include ned/lsp/inlays
include ned/testing/runners
include ned/testing/testament
include ned/testing/aitests
include ned/testing/explorer
include ned/testing/onsave
include ned/editor/projectsymbols
include ned/lsp/codeactions
include ned/editor/selection
include ned/ui/gutter
include ned/debug/gdb
include ned/debug/dap
include ned/debug/gdbterm
include ned/project/workspaces
include ned/project/remotesync
include ned/ui/editormenu
include ned/ui/dragdrop
include ned/ui/mouse
include ned/nim/aifix
include ned/testing/aifixtest
include ned/nim/stdindex
include ned/nim/codegen
include ned/nim/refactors
include ned/editor/spelldicts
include ned/c/headers
include ned/c/cdoctext
include ned/c/nimside
include ned/c/types
include ned/c/navigation
include ned/c/completion
include ned/c/emit
include ned/c/emitclangd
include ned/lsp/embedded
include ned/c/c2nim
include ned/c/compiledb
include ned/c/cdocs
include ned/c/cengine
include ned/editor/inactive
include ned/nim/fixes
include ned/nim/refactor/core
include ned/nim/refactor/signature
include ned/nim/refactor/inline
include ned/nim/refactor/move
include ned/nim/refactor/reshape
include ned/nim/rewrites
include ned/nim/quickfixes
include ned/testing/coverage
include ned/nim/profile
include ned/nim/flame
include ned/run/memcheck
include ned/testing/proctests
include ned/nim/misc
include ned/nim/nimbletree
include ned/editor/csv
include ned/term/repl
include ned/editor/notebook
include ned/editor/tour
include ned/git/conflicts
include ned/ai/review
include ned/ui/compare
include ned/nim/refactor/extract
include ned/nim/nimbleupdates
include ned/nim/nimbleedit
include ned/editor/bookmarks
include ned/editor/localhistoryview
include ned/editor/recovery
include ned/editor/hotexit
include ned/editor/encodingcmds
include ned/editor/lfview
include ned/git/changesview
include ned/git/marks
include ned/app/keyboard
include ned/app/setupcheck
include ned/app/perfreport
include ned/git/commands
include ned/git/setup
include ned/nim/ciworkflow
include ned/git/advanced
include ned/git/history
include ned/git/github
include ned/git/signin
include ned/git/undo
include ned/git/precommit
include ned/git/reviews
include ned/git/aigit
include ned/ai/comments
include ned/run/configsui
include ned/nim/extras
include ned/nim/examples
include ned/run/tasks
include ned/app/usercommands
include ned/app/lint
include ned/web/webui
include ned/nim/worker
include ned/nim/pkgwatch
include ned/plugins/perms
include ned/plugins/host
include ned/ui/telescope
include ned/app/commandlist
include ned/app/control
include ned/term/termhost
include ned/app/update
include ned/app/battery
include ned/app/lowmem
include ned/nim/warmindex
include ned/editor/bufforget
when defined(nedMemProbe): include ned/app/memprobe_gen   # (tests/memory/memprobe.py: how big each table is)
include ned/app/main
