# ── a tab closed: what ned kept about it goes with it. Many parts keep something per buffer (by its id) — the
#    semantic colours, the dimmed code, the engine's checks, inlay hints, the C engine's parse … — and a buffer's id is
#    never used again, so each one left behind stayed for good: opening and closing files made ned grow by a
#    megabyte or two each time (6.32.2: tests/soak/soak.py). The worker does the same when ned tells it a file closed.
#    (The hidden documents of embedded languages and of C in emit have their own closing: embClose, emitClose.) ──

proc bufForget(id: int) =
  ## drops everything the other parts of ned keep for the buffer with this id (colour maps, caches, hints, per-buffer
  ## views and plans) — called when its tab closes, and by the engine worker when told a file closed
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
  # (6.32.4: those tests/memory/bufids.py found — kept per buffer and let go only on some paths)
  multiBufs.del id
  commitBufs.del id
  rebaseBufs.del id
  sigPlans.del id
  nbBuild.del id
  mergeViews.excl id
  diffViews.del id
  flameViews.excl id
  graphBufs.excl id
  nxWarm.excl id
  nxPreloaded.excl id
  wkRefsVer.del id

proc projectForget() =
  ## another folder opened: what was kept about the last project's files goes (each is made again for the new one, or
  ## read back from the disk when that project is opened again) — opening project after project made ned keep all of
  ## them: the words of every file, the compiler's answers, the names macros make, header and stylesheet indexes
  refWordId.clear(); refFilesOf.setLen(0); refFileId.clear(); refFilePath.setLen(0); refFileInfo.setLen(0)
  refCounts.clear(); refJobs.clear(); refFiles.setLen(0)
  refScanPos = 0; refComplete = false; refDisk.clear(); refDiskRead = false; refDiskVersion = -1
  inc refVersion
  orAsked.clear(); orMem.clear(); orMemAt.clear(); orNotAsked.clear()
  mnDone.clear(); mnDiskTried.clear(); mnSigMemo.clear(); mnQueue.setLen(0)
  for p in nxMacroSyms.keys: nxFiles.del p
  nxMacroSyms.clear(); nxMacroDone.clear()
  nxTypoText.clear(); nxTypoTextBytes = 0; nxAutoCache.clear()
  cIndexes.clear(); cssFileMemo.clear(); sqlFileMemo.clear()
  unusedHints.clear()            # (the other project's files: the compiler's unused names, from its checks)
  nifForget(); diagsMemo.clear()
  inc nxGen
