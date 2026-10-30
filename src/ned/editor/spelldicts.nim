# spell check commands and the dictionary downloads: the next misspelled word, choosing where it checks, downloading
# hunspell dictionaries, and the quick fixes (change, add, ignore) for the word at the cursor.
proc spellDownload(lang, code: string)
# the action that downloads one language's dictionary
proc spellDlAct(lang, code: string): Action = (proc() = spellDownload(lang, code))
func spellModeAct(v: string): Action =
  ## the action that sets editor.spellCheck to v (off, markdown or on)
  proc() =
    setSetting("editor.spellCheck", %v)
    info("Spell check: " & v)
    needRender = true

proc spellNext() =
  ## the next misspelled word after the cursor (wrapping around)
  let b = buf()
  if not b.spellOn():
    info("Spell check is off for this file — palette › Spell check: where…")
    return
  if not spellLoaded: loadSpellDict()
  if spellWords.len == 0:
    info("No dictionary found — palette › Spell check: download a dictionary…")
    return
  let start = b.primary.head
  var toks: seq[TokKind]
  for pass in 0 .. 1:
    let (l0, l1) = if pass == 0: (start.line, b.lines.high) else: (0, start.line)
    var st = b.stateAt(l0)[0]
    for l in l0 .. l1:
      let s = b.lines[l]
      if s.len > 4000:
        continue
      let nst = lexLine(b.lang, s, st, toks)
      for (a, e) in b.spellErrors(s, toks):
        if pass == 0 and l == start.line and a <= start.col: continue
        b.setSingle(Pos(line: l, col: e), Pos(line: l, col: a))
        b.centerOn(Pos(line: l, col: a))
        info("“" & s[a ..< e] & "” — Alt+Enter suggests the spelling")
        return
      st = nst
  info("No misspelled words")

const SpellDownloads = [("en_US", "en", "English (US)"), ("en_GB", "en-GB", "English (UK)"), ("de_DE", "de", "German"),
  ("fr_FR", "fr", "French"), ("es_ES", "es", "Spanish"), ("it_IT", "it", "Italian"), ("pt_BR", "pt", "Portuguese (Brazil)"),
  ("pt_PT", "pt-PT", "Portuguese (Portugal)"), ("nl_NL", "nl", "Dutch"), ("ru_RU", "ru", "Russian"), ("pl_PL", "pl", "Polish"),
  ("sv_SE", "sv", "Swedish"), ("tr_TR", "tr", "Turkish"), ("uk_UA", "uk", "Ukrainian")]

proc spellDownload(lang, code: string) =
  ## a hunspell dictionary (github.com/wooorm/dictionaries) into ned's data folder
  if not haveExe("curl"):
    error("curl is needed to download a dictionary")
    return
  let d = spellDataDir()
  try: createDir(d)
  except CatchableError as e:
    error(e.msg)
    return
  let base = "https://raw.githubusercontent.com/wooorm/dictionaries/main/dictionaries/" & code & "/index"
  let cmd = "curl -fsSL --max-time 120 -o " & quoteShell(d / lang & ".aff.part") & " " & quoteShell(base & ".aff") &
            " && curl -fsSL --max-time 120 -o " & quoteShell(d / lang & ".dic.part") & " " & quoteShell(base & ".dic") &
            " && mv " & quoteShell(d / lang & ".aff.part") & " " & quoteShell(d / lang & ".aff") &
            " && mv " & quoteShell(d / lang & ".dic.part") & " " & quoteShell(d / lang & ".dic")
  info("Downloading the " & lang & " dictionary…")
  let j = startJob(jkAux, cmd & " 2>&1", d, proc(jj: Job) =
    if jj.code != 0:
      error("Could not download the dictionary: " & jj.output.strip.splitLines()[^1])
      return
    setSetting("editor.spellLanguage", %lang)
    spellReset()
    if cfgSpell == "off": setSetting("editor.spellCheck", %"markdown")
    loadSpellDict()
    info("Spell check: " & lang & " (" & $spellWords.len & " words)")
    needRender = true)
  if j == nil: error("Could not start curl")

proc cmdSpellDownload() =
  ## Spell check: download a dictionary — a menu of the languages ned can fetch
  var items: seq[(string, string, Action)]
  for (lang, code, name) in SpellDownloads:
    items.add act(name, lang, spellDlAct(lang, code))
  openActions("Download a dictionary (hunspell, from github.com/wooorm/dictionaries)", items)

proc cmdSpellWhere() =
  ## Spell check: where… — a menu to choose between off, Markdown files and commit messages only, or comments and
  ## strings in code too; its title tells which dictionary file is in use and how many words it has
  let cur = cfgSpell
  var items: seq[(string, string, Action)]
  for (v, lab) in [("off", "Off"), ("markdown", "Markdown files and commit messages"),
                   ("on", "Also comments and strings in code")]:
    items.add act((if v == cur: "● " else: "  ") & lab, v, spellModeAct(v))
  if not spellLoaded: loadSpellDict()
  openActions("Spell check — " & (if spellSource.len > 0: spellSource & " (" & $spellWords.len & " words)"
                                  else: "no dictionary found: Spell check: download a dictionary…"), items)

func spellChangeAct(bid, ln, a, e: int, w, sug: string): Action =
  ## the action that replaces the misspelled word w (bytes a..e of line ln in buffer bid) by a suggestion, as an
  ## undoable edit; it does nothing if the text there has changed since
  proc() =
    let bb = bufById(bid)
    if bb == nil or ln >= bb.lines.len or bb.lines[ln].len < e or bb.lines[ln][a ..< e] != w: return
    bb.beginEdit()
    discard bb.replaceText(Pos(line: ln, col: a), Pos(line: ln, col: e), sug)
    bb.endEdit()

proc spellFixes(b: Buffer): seq[(string, string, Action)] =
  ## a misspelled word at the cursor: the closest words, add it to the dictionary, ignore it
  if not b.spellOn(): return
  let p = b.primary.head
  let s = b.lines[p.line]
  if s.len > 4000: return
  var toks: seq[TokKind]
  discard lexLine(b.lang, s, b.stateAt(p.line)[0], toks)
  for (a, e) in b.spellErrors(s, toks):
    if p.col >= a and p.col <= e:
      let w = s[a ..< e]
      let (ln, bid) = (p.line, b.id)
      for sug in spellSuggest(w):
        result.add act("Change to “" & sug & "”", "spelling", spellChangeAct(bid, ln, a, e, w, sug))
      result.add act("Add “" & w & "” to your dictionary", "words.txt", proc() = spellAddWord(w))
      result.add act("Ignore “" & w & "” (this session)", "", proc() =
        spellIgnored.incl w.toLowerAscii
        needRender = true)
      return
