## ned's Nim index: what Nim code declares and means, read by ned itself — no compiler, no server.
## Completion, hover, definitions, references, types, template expansion and misspelled names.
## Open buffers are read through `nxBufferStamp` / `nxBufferLines`, which the editor sets.

import std/[os, strutils, tables, sets, algorithm, json, posix, times, monotimes, hashes]
import ../core/text

include index/lex
include index/text
include index/parse
include index/nimscript
include index/macrosyms
include index/scope
include index/diskcache
include index/locals
include index/types
include index/complete
include index/resolve
include index/consteval
include index/layout
include index/effects
include index/concepts
include index/hover
include index/expand
include index/typos

proc nxCacheStats*(): string =
  ## (measuring: what the index's caches hold besides the parsed files and the scopes)
  var convRefs, convScopes = 0
  for _, (sc, rs) in nxRsConvCache:
    if sc != nil:
      inc convScopes
      convRefs += sc.refs.len
  var typoBytes = 0
  for _, (st, t) in nxTypoText: typoBytes += t.len
  var lines = 0
  for l in nxLinesCache: lines += l.ls.len
  var layLines = 0
  for l in nxLayLines: layLines += l.lines.len
  var memoTabs = 0
  for _, sc in nxScopes:
    if sc.memo != nil: memoTabs += sc.memo.anc.len + sc.memo.alias.len + sc.memo.unions.len + sc.memo.compat.len
  "raises " & $nxRaisesCache.len & ", converters " & $convScopes & " scopes/" & $convRefs & " names, typo texts " &
    $(typoBytes div 1024) & " KB, lines cached " & $lines & "+" & $layLines & ", auto " & $nxAutoCache.len &
    ", headers " & $nxHeaderCache.len & ", local types " & $nxLocalTypMemo.len & ", concept impls " &
    $nxCpImplCache.len & ", fwd " & $nxFxFwdCache.len & ", type memos " & $memoTabs & ", overlays " & $nxOverlays.len &
    ", macro calls " & $nxMacroSyms.len & ", call sites " & $nxCallSites.len & ", injects " & $nxInjects.len
