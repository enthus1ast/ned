# ════════════════════════════════════════════════════════════════════════════
#  Desktop chrome: icons, clickable regions, tooltips, toasts, dialogs, menus
# ════════════════════════════════════════════════════════════════════════════

proc ic(name: string): string =
  ## icon by role in the configured icon set (unicode works with stock fonts, nerd needs a Nerd Font)
  case cfgIcons
  of "nerd":
    case name
    of "menu": ""
    of "files": ""
    of "search": ""
    of "git": ""
    of "nim": "\u{F01A5}"
    of "tests": ""
    of "ai": "\u{F06A9}"
    of "outline": ""
    of "timeline": ""
    of "todo": "\u{F0AE}"
    of "run": ""
    of "stop": ""
    of "debug": ""
    of "left": ""
    of "panel": ""
    of "right": ""
    of "gear": ""
    of "terminal": ""
    of "error": ""
    of "warn": ""
    of "info": ""
    of "ok": ""
    of "branch": ""
    of "folder": ""
    of "folderOpen": ""
    of "file": ""
    of "close": ""
    of "dirty": ""
    of "split": ""
    of "more": ""
    of "max": ""
    of "min": ""
    of "bell": ""
    of "send": ""
    of "plus": ""
    of "trash": ""
    of "chevD": ""
    of "chevR": ""
    of "spark": "\u{F06A9}"
    of "user": ""
    of "tool": ""
    of "history": "\u{F02DA}"
    of "bookmark": "\uF02E"
    else: "•"
  of "ascii":
    case name
    of "menu": "="
    of "files": "F"
    of "search": "S"
    of "git": "G"
    of "nim": "N"
    of "tests": "T"
    of "ai": "@"
    of "outline": "O"
    of "timeline": "H"
    of "todo": "!"
    of "run": ">"
    of "stop": "#"
    of "debug": "D"
    of "left": "["
    of "panel": "_"
    of "right": "]"
    of "gear": "*"
    of "terminal": "$"
    of "error": "x"
    of "warn": "!"
    of "info": "i"
    of "ok": "v"
    of "branch": "@"
    of "folder": "+"
    of "folderOpen": "-"
    of "file": " "
    of "close": "x"
    of "dirty": "*"
    of "split": "|"
    of "more": "..."
    of "max": "^"
    of "min": "v"
    of "bell": "!"
    of "send": ">"
    of "plus": "+"
    of "trash": "x"
    of "chevD": "v"
    of "chevR": ">"
    of "spark": "*"
    of "user": ">"
    of "tool": "%"
    of "history": "h"
    of "bookmark": "#"
    else: "-"
  else:
    case name
    of "menu": "≡"
    of "files": "▤"
    of "search": "⌕"
    of "git": "⎇"
    of "nim": "♛"
    of "tests": "✓"
    of "ai": "✦"
    of "outline": "◇"
    of "timeline": "◷"
    of "todo": "⚑"
    of "run": "▶"
    of "stop": "■"
    of "debug": "◉"
    of "left": "◧"
    of "panel": "⊟"
    of "right": "◨"
    of "gear": "⚙"
    of "terminal": "❯"
    of "error": "●"
    of "warn": "▲"
    of "info": "ℹ"
    of "ok": "✓"
    of "branch": "⎇"
    of "folder": "▸"
    of "folderOpen": "▾"
    of "file": " "
    of "close": "×"
    of "dirty": "●"
    of "split": "◫"
    of "more": "⋯"
    of "max": "⤢"
    of "min": "⤡"
    of "bell": "◔"
    of "send": "➤"
    of "plus": "+"
    of "trash": "⌫"
    of "chevD": "▾"
    of "chevR": "▸"
    of "spark": "✦"
    of "user": "›"
    of "tool": "⚒"
    of "history": "◷"
    of "bookmark": "◆"
    else: "•"

proc langColor(path: string): Rgb =
  let ext = splitFile(path).ext.toLowerAscii
  case ext
  of ".nim", ".nims", ".nimble": 0xF3D400'u32
  of ".py": 0x4B8BBE'u32
  of ".rs": 0xDEA584'u32
  of ".c", ".h": 0x5C8DBC'u32
  of ".cpp", ".cc", ".cxx", ".hpp", ".hh": 0xF34B7D'u32
  of ".js", ".mjs", ".cjs": 0xF1E05A'u32
  of ".ts", ".tsx": 0x3178C6'u32
  of ".html", ".htm": 0xE34C26'u32
  of ".css", ".scss": 0x563D7C'u32
  of ".md": 0x83A598'u32
  of ".json", ".toml", ".yaml", ".yml", ".cfg", ".ini": 0xCBCB41'u32
  of ".sh", ".bash", ".zsh": 0x89E051'u32
  of ".go": 0x00ADD8'u32
  of ".lua": 0x000080'u32
  else: theme.dim

proc fileIcon(path: string): string =
  if cfgIcons != "nerd": return (if cfgIcons == "ascii": " " else: "•")
  let ext = splitFile(path).ext.toLowerAscii
  case ext
  of ".nim", ".nims", ".nimble": "\u{F01A5}"
  of ".py": ""
  of ".rs": ""
  of ".c", ".h": ""
  of ".cpp", ".cc", ".cxx", ".hpp": ""
  of ".js", ".mjs": ""
  of ".ts", ".tsx": ""
  of ".html", ".htm": ""
  of ".css": ""
  of ".md": ""
  of ".json": ""
  of ".sh", ".bash": ""
  of ".go": ""
  of ".toml", ".yaml", ".yml", ".cfg", ".ini": ""
  else: ""
