## ned's built-in formatters: Nim (in nph's style, checked), JSON, Markdown tables and CSS.
## Text in, text out.

import std/[os, strutils, tables, sets, json, posix, times, monotimes]
import ../core/text

include nimlex
include nimspacing
include nim
include json
include markdown
include css
