## ned's built-in formatters: Nim (in nph's style, checked), JSON, Markdown tables, CSS and C (indentation).
## Text in, text out.

import std/[strutils, tables, sets, json, times, monotimes, algorithm]
when defined(windows): import ../sys/winos as os   # (std/os, with '/' in the paths it makes)
else: import std/os
when defined(windows): import ../sys/winposix as posix
else: import std/posix
import ../core/text

const FmtMaxNest = 500     # (JSON's and CSS's nesting past which a file is left as it is: each level is indented, so
                           # the result grows with the square of the depth — 30 000 deep took more memory than a phone
                           # has — and no file a person writes nests that deep)

include nimlex
include nimspacing
include nim
include json
include markdown
include css
include cstyle
include cfmt
include yamltoml
include html
include sql
include nimembed

# ── format on save, only the lines changed (editor.formatOnSaveScope: changed): those lines given to a formatter
#    that takes ranges ──

func fmtLineRuns*(lines: HashSet[int]): seq[(int, int)] =
  ## the line numbers (from 0) as runs of lines that follow each other, from 1: {2, 3, 4, 9} → (3, 5), (10, 10)
  var ls: seq[int]
  for l in lines: ls.add l
  ls.sort()
  for l in ls:
    if result.len > 0 and result[^1][1] == l: result[^1][1] = l + 1
    else: result.add (l + 1, l + 1)

func fmtWithRanges*(cmd: string, runs: seq[(int, int)]): string =
  ## a formatter's command given only the lines changed, where it takes ranges: black's --line-ranges, ruff's
  ## --range (one run), clang-format's --lines — any other command as it is
  if runs.len == 0: return cmd
  let w = cmd.splitWhitespace
  if w.len == 0: return cmd
  let exe = extractFilename(w[0])
  var extra = ""
  if exe == "black":
    for (a, e) in runs: extra.add " --line-ranges=" & $a & "-" & $e
  elif exe == "ruff" and w.len > 1 and w[1] == "format" and runs.len == 1:
    extra = " --range=" & $runs[0][0] & "-" & $runs[0][1]
  elif exe == "clang-format":
    for (a, e) in runs: extra.add " --lines=" & $a & ":" & $e
  else: return cmd
  # (after the program and its subcommand)
  let at = cmd.find(w[0]) + w[0].len
  let at2 = if exe == "ruff": cmd.find("format", at) + "format".len else: at
  cmd[0 ..< at2] & extra & cmd[at2 .. ^1]
