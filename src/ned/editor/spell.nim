# ── spell check: Markdown, commit messages, and (editor.spellCheck "on") comments and strings in code.
#    Dictionaries: hunspell's .dic/.aff (affix rules expanded), or a plain word list ──

type AffRule = object
  strip, add: string
  cond: seq[(bool, set[char])]         # each element: (negated, its characters); '.' is (true, {})
  cross: bool

var
  spellWords: HashSet[string]          # the dictionary, lower case, every form, plus the user's own words
  spellLoaded = false
  spellAffixes = false                 # the forms came from affix rules (else ned guesses -s, -ed, -ing …)
  spellSource = ""                     # where the dictionary came from ("" = none found)
  spellIgnored: HashSet[string]        # Ignore (this session)
  spellIdents: Table[int, (int, HashSet[string])]   # buffer → (changeId, the names its code uses)
  spellIdentsAt: Table[int, MonoTime]

proc spellDataDir(): string = getEnv("XDG_DATA_HOME", getHomeDir() / ".local" / "share") / AppName / "dictionaries"

proc spellReset() =
  spellLoaded = false
  spellWords.clear()
  spellIdents.clear()

proc spellCandidates(): seq[string] =
  ## dictionary files to try, best first
  if cfgSpellDict.len > 0: result.add cfgSpellDict
  let lang = cfgSpellLang
  let lang2 = lang.replace('_', '-')
  let pre = getEnv("PREFIX")
  for d in [spellDataDir(), "/usr/share/hunspell", "/usr/share/myspell", "/usr/share/myspell/dicts",
            "/usr/local/share/hunspell", "/opt/homebrew/share/hunspell", getHomeDir() / "Library/Spelling",
            pre / "share" / "hunspell", pre / "share" / "myspell"]:
    if d.len == 0: continue
    for n in [lang, lang2]:
      result.add d / n & ".dic"
  if lang.startsWith("en"):
    for f in ["/usr/share/dict/words", "/usr/dict/words", pre / "share" / "dict" / "words",
              (if lang.endsWith("GB"): "/usr/share/dict/british-english" else: "/usr/share/dict/american-english")]:
      result.add f

proc parseAffCond(c: string): seq[(bool, set[char])] =
  var i = 0
  while i < c.len:
    if c[i] == '[':
      inc i
      var neg = false
      if i < c.len and c[i] == '^':
        neg = true
        inc i
      var cs: set[char]
      while i < c.len and c[i] != ']':
        cs.incl c[i]
        inc i
      inc i
      result.add (neg, cs)
    elif c[i] == '.':
      result.add (true, {})
      inc i
    else:
      result.add (false, {c[i]})
      inc i

proc affCondOk(w: string, cond: seq[(bool, set[char])], atEnd: bool): bool =
  if cond.len > w.len: return false
  let off = if atEnd: w.len - cond.len else: 0
  for k, (neg, cs) in cond:
    let c = w[off + k]
    if neg == (c in cs): return false
  true

proc loadSpellDict() =
  ## the dictionary once, when spell check first needs it (a few hundred ms for hunspell's en_US)
  spellLoaded = true
  spellWords.clear()
  spellAffixes = false
  spellSource = ""
  for f in spellCandidates():
    if f.len == 0 or not fileExists(f): continue
    var text = ""
    try: text = readFile(f)
    except CatchableError: continue
    let aff = f.changeFileExt("aff")
    if f.endsWith(".dic") and fileExists(aff):
      # hunspell: stems with flags, the affix rules expanded here
      var sfx, pfx: Table[string, seq[AffRule]]
      var flagMode = "char"
      try:
        for raw in readFile(aff).splitLines:
          let w = raw.splitWhitespace()
          if w.len == 0: continue
          if w[0] == "FLAG" and w.len > 1: flagMode = w[1]
          elif w[0] in ["SFX", "PFX"] and w.len >= 5:
            let r = AffRule(strip: (if w[2] == "0": "" else: w[2]), add: (if w[3] == "0": "" else: w[3].split('/')[0]),
                            cond: parseAffCond(if w[4] == ".": "" else: w[4]))
            if w[0] == "SFX": sfx.mgetOrPut(w[1], @[]).add r else: pfx.mgetOrPut(w[1], @[]).add r
          elif w[0] in ["SFX", "PFX"] and w.len == 4 and w[2] in ["Y", "N"]:
            discard                         # the header line of a rule group: cross-product Y/N
      except CatchableError: discard
      # cross products: from the group headers
      var crossOk: HashSet[string]
      try:
        for raw in readFile(aff).splitLines:
          let w = raw.splitWhitespace()
          if w.len == 4 and w[0] in ["SFX", "PFX"] and w[2] == "Y": crossOk.incl w[1]
      except CatchableError: discard
      proc flagsOf(fl: string): seq[string] =
        case flagMode
        of "long":
          var i = 0
          while i + 1 < fl.len:
            result.add fl[i .. i + 1]
            i += 2
        of "num":
          for x in fl.split(','): result.add x.strip
        else:
          for c in fl: result.add $c
      var first = true
      for raw in text.splitLines:
        if first:
          first = false
          if raw.strip.len > 0 and raw.strip[0] in Digits: continue
        var line = raw.strip(leading = false)
        let tab = line.find('\t')
        if tab >= 0: line = line[0 ..< tab]
        if line.len == 0: continue
        var stem = line
        var fl = ""
        let sl = line.find('/')
        if sl > 0:
          stem = line[0 ..< sl]
          fl = line[sl + 1 .. ^1].splitWhitespace()[0]
        else:
          let sp = line.find(' ')
          if sp > 0: stem = line[0 ..< sp]
        let low = stem.toLowerAscii
        spellWords.incl low
        if fl.len == 0: continue
        let flags = flagsOf(fl)
        var forms = @[low]
        for f in flags:
          for r in sfx.getOrDefault(f):
            if (r.strip.len == 0 or low.endsWith(r.strip)) and affCondOk(low, r.cond, true):
              let form = low[0 ..< low.len - r.strip.len] & r.add
              spellWords.incl form
              if f in crossOk: forms.add form
        for f in flags:
          for r in pfx.getOrDefault(f):
            for base in forms:
              if (r.strip.len == 0 or base.startsWith(r.strip)) and affCondOk(base, r.cond, false):
                spellWords.incl r.add & base[r.strip.len .. ^1]
      spellAffixes = true
    else:
      for raw in text.splitLines:
        let w = raw.strip
        if w.len > 0 and w[0] != '#': spellWords.incl w.toLowerAscii
    if spellWords.len > 0:
      spellSource = f
      break
  try:
    if fileExists(spellUserFile()):
      for w in readFile(spellUserFile()).splitLines:
        if w.strip.len > 0: spellWords.incl w.strip.toLowerAscii
  except CatchableError: discard

proc spellOn(b: Buffer): bool =
  if cfgSpell == "off" or b.binary or b.largeOn or b.lang == nil: return false
  if b.lang.mode == lmMarkdown or b.title == "COMMIT_EDITMSG" or b.path.endsWith("COMMIT_EDITMSG"): return true
  cfgSpell == "on" and b.lang.mode notin {lmPlain, lmJson, lmYaml, lmToml, lmMake, lmDiff, lmCss}

proc spellIdentsOf(b: Buffer): HashSet[string] =
  ## the names this file's code uses (comments and strings left out), so comments that mention them are not
  ## misspelled; while you type, worked out again at most every 2 s
  if b.id in spellIdents:
    let (at, hs) = spellIdents[b.id]
    if at == b.changeId or b.lines.len > 20_000 or msSince(spellIdentsAt.getOrDefault(b.id)) < 2000: return hs
  var hs: HashSet[string]
  if b.lang.mode != lmMarkdown:
    var toks: seq[TokKind]
    var st: LexSt = 0
    for l in 0 ..< min(b.lines.len, 20_000):
      let t = b.lines[l]
      if t.len > 4000: continue
      st = lexLine(b.lang, t, st, toks)
      var i = 0
      while i < t.len:
        if t[i] in IdentStartChars and (i >= toks.len or toks[i] notin {tkComment, tkDoc, tkString, tkChar}):
          var j = i + 1
          while j < t.len and t[j] in IdentChars: inc j
          if j - i >= 3: hs.incl t[i ..< j].toLowerAscii
          i = j
        else: inc i
  spellIdents[b.id] = (b.changeId, hs)
  spellIdentsAt[b.id] = getMonoTime()
  hs

proc spellKnown(w: string): bool =
  let low = w.toLowerAscii
  if low in spellWords or low in spellIgnored: return true
  var x = low
  for ap in ["'s", "’s"]:
    if x.endsWith(ap):
      x = x[0 ..< x.len - ap.len]
      if x in spellWords: return true
  if not spellAffixes:
    # a word list has the stems only: try the common English endings
    for (suf, rep) in [("ies", "y"), ("ied", "y"), ("ier", "y"), ("iest", "y"), ("ily", "y"), ("es", ""), ("s", ""),
                       ("ed", ""), ("ed", "e"), ("d", ""), ("ing", ""), ("ing", "e"), ("ly", ""), ("er", ""),
                       ("er", "e"), ("ers", ""), ("est", ""), ("ness", ""), ("ment", ""), ("able", ""), ("able", "e")]:
      if x.len > suf.len + 2 and x.endsWith(suf):
        let st = x[0 ..< x.len - suf.len] & rep
        if st in spellWords: return true
        if st.len >= 3 and st[^1] == st[^2] and st[0 ..< ^1] in spellWords: return true   # running → run
  false

proc spellErrors(b: Buffer, s: string, toks: seq[TokKind]): seq[(int, int)] =
  ## misspelled words on a line: their byte ranges
  if not spellLoaded: loadSpellDict()
  if spellWords.len == 0: return
  let md = b.lang.mode == lmMarkdown or b.lang.mode == lmPlain
  let minLen = if md: 3 else: 4
  var idents: HashSet[string]
  var haveIdents = false
  var i = 0
  var inTick = false
  while i < s.len:
    let tk = if i < toks.len: toks[i] else: tkText
    let ok = if md: tk in {tkText, tkHeading, tkBold, tkLink, tkComment, tkKeyword}
             else: tk in {tkComment, tkDoc, tkString}
    if ok and s[i] == '`': inTick = not inTick         # `code` in a comment
    if not ok or inTick or not (s[i].isAlphaAscii or ord(s[i]) >= 0xC0):
      inc i
      continue
    # a run: letters, digits and the characters of names, paths, URLs and versions
    var j = i
    while j < s.len and (s[j].isAlphaNumeric or ord(s[j]) >= 0x80 or s[j] in {'_', '.', '/', '@', ':', '\\', '\'', '-'}):
      inc j
    var e = j
    while e > i and s[e - 1] in {'.', ':', '\'', '-'}: dec e         # the end of a sentence, not part of the word
    let run = s[i ..< e]
    var skip = false
    for c in run:
      if c in {'_', '.', '/', '@', ':', '\\'} or c in Digits: skip = true
    if not skip:
      # words joined by hyphens are checked one by one
      var k = i
      while k < e:
        var q = k
        while q < e and s[q] != '-': inc q
        let w = s[k ..< q]
        var inner = false
        var caps = 0
        for z, c in w:
          if c.isUpperAscii:
            inc caps
            if z > 0: inner = true
        let wl = w.len - (if w.endsWith("'s"): 2 else: 0)
        if wl >= minLen and not inner and caps < w.len and not w.spellKnown:
          if not haveIdents:
            idents = b.spellIdentsOf()
            haveIdents = true
          if w.toLowerAscii notin idents and w.toLowerAscii notin b.lang.keywords and w notin b.lang.types and
             w notin b.lang.builtins:
            result.add (k, q)
        k = q + 1
    i = j

proc spellSuggest(w: string, n = 6): seq[string] =
  ## the dictionary's closest words (edit distance), the same capitalisation as `w`
  if not spellLoaded: loadSpellDict()
  let low = w.toLowerAscii
  var best: seq[(int, string)]
  let lim = if low.len <= 4: 1 else: 2
  for d in spellWords:
    if abs(d.len - low.len) > lim: continue
    if d.len > 0 and low.len > 0 and d[0] != low[0] and (low.len < 2 or d.len < 2 or d[0] != low[1] or d[1] != low[0]):
      continue                           # the first letter is rarely the mistake (except two swapped)
    let dist = editDistance(d, low)
    if dist <= lim: best.add (dist, d)
  best.sort(proc(a, b: (int, string)): int = (if a[0] != b[0]: cmp(a[0], b[0]) else: cmp(a[1], b[1])))
  for (_, d) in best:
    var x = d
    if w.len > 0 and w[0].isUpperAscii: x[0] = x[0].toUpperAscii
    if x notin result: result.add x
    if result.len >= n: break

proc spellAddWord(w: string) =
  let low = w.toLowerAscii
  try:
    createDir(configDir())
    let f = spellUserFile()
    var t = if fileExists(f): readFile(f) else: ""
    if t.len > 0 and not t.endsWith("\n"): t.add "\n"
    t.add low & "\n"
    writeFileSafe(f, t)
    spellWords.incl low
    info("Added “" & low & "” to your dictionary (" & f & ")")
  except CatchableError as e: error("Could not save the word: " & e.msg)
