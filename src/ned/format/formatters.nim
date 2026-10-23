## ned's built-in formatters: Nim (in nph's style, checked), JSON, Markdown tables, CSS and C (indentation).
## Text in, text out.

import std/[strutils, tables, sets, json, times, monotimes, algorithm]
when defined(windows): import ../sys/winos as os   # (std/os, with '/' in the paths it makes)
else: import std/os
when defined(windows): import ../sys/winposix as posix
else: import std/posix
import ../core/text

include nimlex
include nimspacing
include nim
include json
include markdown
include css
include cfmt
include yamltoml
include html
include sql
