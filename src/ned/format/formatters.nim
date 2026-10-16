## ned's built-in formatters: Nim (in nph's style, checked), JSON, Markdown tables, CSS and C (indentation).
## Text in, text out.

import std/[os, strutils, tables, sets, json, posix, times, monotimes, algorithm, sequtils]
import ../core/text

include nimlex
include nimspacing
include nim
include json
include markdown
include css
include cfmt
