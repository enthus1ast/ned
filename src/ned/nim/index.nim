## ned's Nim index: what Nim code declares and means, read by ned itself — no compiler, no server.
## Completion, hover, definitions, references, types, template expansion and misspelled names.
## Open buffers are read through `nxBufferStamp` / `nxBufferLines`, which the editor sets.

import std/[os, strutils, tables, sets, algorithm, json, posix, times, monotimes, hashes]
import ../core/text

include index/lex
include index/text
include index/parse
include index/macrosyms
include index/scope
include index/diskcache
include index/locals
include index/types
include index/complete
include index/resolve
include index/consteval
include index/layout
include index/hover
include index/expand
include index/typos
