# ── a tab closed: what ned kept about it goes with it. Many parts keep something per buffer (by its id) — the
#    semantic colours, the dimmed code, the engine's checks, inlay hints, the C engine's parse … — and a buffer's id is
#    never used again, so each one left behind stayed for good: opening and closing files made ned grow by a
#    megabyte or two each time (6.32.2: tests/soak/soak.py). The worker does the same when ned tells it a file closed.
#    (The hidden documents of embedded languages and of C in emit have their own closing: embClose, emitClose.) ──

proc bufForget(id: int) =
  semMaps.del id
  inactiveCache.del id
  typoAt.del id
  typosLast.del id
  ecFuncRounds.del id
  ecLast.del id
  mnSeen.del id
  refLens.del id
  nxPreloadQ.del id
  nxPreloadSeen.del id
  nifMemo.del id
  ihStates.del id
  inlayRetries.del id
  docLinks.del id
  lspSem.del id
  lspSemAsked.del id
  embChange.del id
  embPumpAt.del id
  emitPumpAt.del id
  emitIdxCache.del id
  cxBufParse.del id
  cxCppSeen.del id
  cEngChecked.del id
  cEngSem.del id
  cSigDecls.del id
  cSigHints.del id
  cSigHintsAt.del id
  copyMarks.del id
  csvWidthCache.del id
  profChecked.del id
  profStale.del id
  lineTints.del id
  bracketKept.del id
  vcMarks.del id
  spellIdents.del id
  spellIdentsAt.del id
  undoWritten.del id
  fmtOpenBase.del id
  conflictCache.del id
  conflictScanAt.del id
  mergeCache.del id
  webChkAt.del id
  webHeld.del id
  webLast.del id
  plugChangeSent.del id
  plugOutlineAsked.del id
  plugOutlines.del id
  macroViews.del id
  mvRowLines.del id
  mvSeen.del id
  nbLaid.del id
  nbOuts.del id
  picViews.del id
  mbSig.del id
  gcViews.del id
  blameBufs.del id
  mdFollow.del id
  mdPreviewCache.del id
  viewHead.del id
