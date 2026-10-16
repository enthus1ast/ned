# ── tests (std/unittest): explorer view, gutter ▶, run single tests ──

type TestEntry = object
  path, name, suite: string
  line: int
  isSuite: bool

var
  testEntries: seq[TestEntry]
  testScanned = false
  testStatus = initTable[string, int]()    # "file::name" → 1 ok, 2 failed, 3 running, 4 skipped
  testRunPath = ""

proc quotedName(t: string, kw: string): string =
  ## test "name": → name
  let s = t.strip
  if not s.startsWith(kw): return ""
  let q = s.find('"')
  if q < 0: return ""
  let e = s.find('"', q + 1)
  if e < 0: return ""
  s[q + 1 ..< e]

proc testKey(path, name: string): string = path & "::" & name

# ── tests in other languages: pytest, go test, cargo test (▶ in the gutter, the test explorer) ──

proc testLangOf(path: string): string =
  if path.endsWith(".py"): "py"
  elif path.endsWith("_test.go"): "go"
  elif path.endsWith(".rs"): "rs"
  elif path.endsWith(".nim"): "nim"
  elif path.endsWith(".php"): "php"
  elif path.endsWith(".cs"): "cs"
  elif path.endsWith(".kt") or path.endsWith(".java"): "jvm"
  else: ""

proc testMethodName(t: string): string =
  ## the method declared on a line: `fun name(` / `fun `two words`(` / `void name(` / `public function name(`
  let bt = t.find("fun `")
  if bt >= 0:
    let e = t.find('`', bt + 5)
    if e > bt: return t[bt + 5 ..< e]
  let par = t.find('(')
  if par <= 0: return ""
  var e = par
  while e > 0 and t[e - 1] == ' ': dec e
  var a = e
  while a > 0 and (t[a - 1].isAlphaNumeric or t[a - 1] == '_'): dec a
  if a == e: return ""
  let before = t[0 ..< a].strip
  if before.len == 0 or before.endsWith("=") or before.endsWith(".") or before.endsWith("new"): return ""
  t[a ..< e]

proc testAttrLine(lang, t: string): bool =
  ## an attribute or annotation that makes the next method a test
  case lang
  of "cs": t.startsWith("[Fact") or t.startsWith("[Theory") or t.startsWith("[Test") or
           t.startsWith("[DataTestMethod") or t.startsWith("[TestCase")
  of "jvm": t.startsWith("@Test") or t.startsWith("@ParameterizedTest") or t.startsWith("@RepeatedTest")
  of "php": t.startsWith("#[Test") or t == "* @test" or t.startsWith("/** @test")
  else: false

proc scanOtherTests(path: string, lines: seq[string]): seq[TestEntry] =
  case testLangOf(path)
  of "py":
    var cls = ""
    for i, l in lines:
      let t = l.strip(trailing = false)
      let ind = l.len - t.len
      if ind == 0 and t.len > 0 and not t.startsWith("#") and not t.startsWith("@"): cls = ""
      if ind == 0 and t.startsWith("class Test"):
        var e = 6
        while e < t.len and (t[e].isAlphaNumeric or t[e] == '_'): inc e
        cls = t[6 ..< e]
        result.add TestEntry(path: path, name: cls, line: i, isSuite: true)
      elif t.startsWith("def test") or t.startsWith("async def test"):
        let k = t.find("test")
        var e = k
        while e < t.len and (t[e].isAlphaNumeric or t[e] == '_'): inc e
        let n = t[k ..< e]
        if ind == 0: result.add TestEntry(path: path, name: n, line: i)
        elif cls.len > 0: result.add TestEntry(path: path, name: cls & "::" & n, suite: cls, line: i)
  of "go":
    for i, l in lines:
      if l.startsWith("func Test") and "*testing.T" in l:
        var e = 5
        while e < l.len and (l[e].isAlphaNumeric or l[e] == '_'): inc e
        result.add TestEntry(path: path, name: l[5 ..< e], line: i)
  of "rs":
    var pending = false
    for i, l in lines:
      let t = l.strip
      if t.startsWith("#[") and t.endsWith("test]"):
        pending = true
        continue
      if pending and t.startsWith("#["): continue
      if pending:
        let k = t.find("fn ")
        if k >= 0:
          var e = k + 3
          while e < t.len and (t[e].isAlphaNumeric or t[e] == '_'): inc e
          result.add TestEntry(path: path, name: t[k + 3 ..< e], line: i)
        pending = false
  of "cs", "jvm", "php":
    # [Fact] / @Test / #[Test] then the method; PHPUnit also runs every public function test…()
    let lang = testLangOf(path)
    var pending = false
    for i, l in lines:
      let t = l.strip
      if testAttrLine(lang, t):
        pending = true
        continue
      if t.len == 0 or t.startsWith("[") or t.startsWith("@") or t.startsWith("*") or t.startsWith("/*") or
         t.startsWith("//") or t.startsWith("#["): continue
      let n = testMethodName(t)
      if n.len > 0 and (pending or (lang == "php" and "function test" in t)):
        result.add TestEntry(path: path, name: n, line: i)
      pending = false
  else: discard

proc testRootOf(path: string, marks: openArray[string]): string =
  ## the nearest folder above `path` with one of `marks` (a name, or *.ext), else the project folder
  var d = parentDir(path)
  while d.len > 1:
    for m in marks:
      if m.startsWith("*."):
        try:
          for kind, f in walkDir(d):
            if kind == pcFile and f.endsWith(m[1 .. ^1]): return d
        except OSError: discard
      elif fileExists(d / m): return d
    if d == rootDir or parentDir(d) == d: break
    d = parentDir(d)
  rootDir

proc parseJunitXml(path, xml: string) =
  ## <testcase name="testAdd" …/> · <testcase …><failure …/></testcase> · <skipped/>
  var i = 0
  while true:
    let a = xml.find("<testcase", i)
    if a < 0: break
    let gt = xml.find('>', a)
    if gt < 0: break
    let head = xml[a .. gt]
    var name = ""
    let q = head.find(" name=\"")
    if q >= 0:
      let e = head.find('"', q + 7)
      if e > q: name = head[q + 7 ..< e].replace("&quot;", "\"").replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
    if name.endsWith("()"): name = name[0 ..< ^2]
    var st = 1
    if not head.endsWith("/>"):
      let close = xml.find("</testcase>", gt)
      let body = if close > 0: xml[gt ..< close] else: ""
      if "<failure" in body or "<error" in body: st = 2
      elif "<skipped" in body: st = 4
      i = (if close > 0: close else: gt)
    else: i = gt
    if name.len > 0: testStatus[testKey(path, name)] = st

proc parseOtherTestOutput(path, output: string) =
  ## pytest -v · go test -v · cargo test: each test's result
  let lang = testLangOf(path)
  for raw in output.splitLines:
    let l = stripAnsi(raw).strip
    case lang
    of "py":
      let k = l.find("::")
      if k < 0: continue
      var st = 0
      for (w, v) in [(" PASSED", 1), (" FAILED", 2), (" ERROR", 2), (" SKIPPED", 4), (" XFAIL", 4)]:
        if w in l: st = v
      if st == 0: continue
      var name = l[k + 2 .. ^1]
      let sp = name.find(' ')
      if sp > 0: name = name[0 ..< sp]
      let br = name.find('[')
      if br > 0: name = name[0 ..< br]
      if not l[0 ..< k].endsWith(extractFilename(path)): continue
      if testStatus.getOrDefault(testKey(path, name)) != 2 or st == 2: testStatus[testKey(path, name)] = st
    of "go":
      for (w, v) in [("--- PASS: ", 1), ("--- FAIL: ", 2), ("--- SKIP: ", 4)]:
        if l.startsWith(w):
          let n = l[w.len .. ^1].split(' ')[0]
          testStatus[testKey(path, n)] = v
    of "rs":
      if l.startsWith("test ") and " ... " in l:
        var n = l[5 ..< l.find(" ... ")]
        let res = l[l.find(" ... ") + 5 .. ^1]
        if "::" in n: n = n.rsplit("::", 1)[^1]
        testStatus[testKey(path, n)] = (if res.startsWith("ok"): 1 elif res.startsWith("ignored"): 4 else: 2)
    of "cs":
      # dotnet test (normal verbosity): "Passed Ns.Class.Method [3 ms]"
      for (w, v) in [("Passed ", 1), ("Failed ", 2), ("Skipped ", 4)]:
        if l.startsWith(w):
          var n = l[w.len .. ^1]
          let br = n.find(" [")
          if br > 0: n = n[0 ..< br]
          let par = n.find('(')
          if par > 0: n = n[0 ..< par]
          if '.' in n: n = n.rsplit('.', 1)[^1]
          testStatus[testKey(path, n.strip)] = v
    else: discard
  # PHPUnit, Gradle and Maven write JUnit XML reports
  case lang
  of "php":
    try: parseJunitXml(path, readFile(tmpDir() / "ned-junit.xml"))
    except CatchableError: discard
  of "jvm":
    let root = testRootOf(path, ["settings.gradle.kts", "settings.gradle", "build.gradle.kts", "build.gradle", "pom.xml"])
    let cls = splitFile(path).name
    for d in [root / "build" / "test-results" / "test", root / "target" / "surefire-reports"]:
      try:
        for kind, f in walkDir(d):
          if kind == pcFile and f.endsWith(".xml") and (cls & ".xml") in f: parseJunitXml(path, readFile(f))
      except CatchableError: discard
  else: discard

proc otherTestCmd(path, filter: string): (string, string) =
  ## (command, folder) that runs a file's tests, or one of them
  case testLangOf(path)
  of "py":
    var py = "python3"
    for v in [rootDir / ".venv" / "bin" / "python", rootDir / "venv" / "bin" / "python"]:
      if fileExists(v): py = quoteShell(v)
    let runner = if py == "python3" and haveExe("pytest"): "pytest" else: py & " -m pytest"
    (runner & " -v --no-header -p no:cacheprovider " & quoteShell(path & (if filter.len > 0: "::" & filter else: "")),
     rootDir)
  of "go": ("go test -v" & (if filter.len > 0: " -run " & quoteShell("^" & filter & "$") else: "") & " .", parentDir(path))
  of "rs":
    let root = cargoRoot(parentDir(path))
    ("cargo test" & (if filter.len > 0: " " & quoteShell(filter) else: "") & " 2>&1",
     (if root.len > 0: root else: parentDir(path)))
  of "php":
    let root = testRootOf(path, ["composer.json", "phpunit.xml", "phpunit.xml.dist"])
    let runner = if fileExists(root / "vendor" / "bin" / "phpunit"): "vendor/bin/phpunit" else: "phpunit"
    let log = tmpDir() / "ned-junit.xml"
    ("rm -f " & quoteShell(log) & "; " & runner & " --log-junit " & quoteShell(log) &
     (if filter.len > 0: " --filter " & quoteShell("::" & filter & "( |$)") else: "") & " " & quoteShell(path) & " 2>&1",
     root)
  of "cs":
    let root = testRootOf(path, ["*.csproj", "*.sln"])
    ("dotnet test --logger \"console;verbosity=normal\"" &
     (if filter.len > 0: " --filter " & quoteShell("FullyQualifiedName~" & filter) else: "") & " 2>&1", root)
  of "jvm":
    let root = testRootOf(path, ["settings.gradle.kts", "settings.gradle", "build.gradle.kts", "build.gradle", "pom.xml"])
    let cls = splitFile(path).name
    if fileExists(root / "pom.xml") and not fileExists(root / "build.gradle") and not fileExists(root / "build.gradle.kts"):
      ("mvn -q test -DfailIfNoTests=false -Dsurefire.failIfNoSpecifiedTests=false -Dtest=" &
       quoteShell(cls & (if filter.len > 0: "#" & filter else: "")) & " 2>&1", root)
    else:
      let gradle = if fileExists(root / "gradlew"): "./gradlew" else: "gradle"
      (gradle & " test --console=plain --tests " & quoteShell("*" & cls & (if filter.len > 0: "." & filter else: "")) &
       " 2>&1", root)
  else: ("", "")

proc otherTestAt(b: Buffer, l: int): (string, bool) =
  ## a test (or test class) declared on line l of a Python, Go or Rust file: (its name, a group of tests?)
  let s = b.lines[l]
  let t = s.strip(trailing = false)
  case testLangOf(b.path)
  of "py":
    if s.startsWith("class Test"):
      var e = 6
      while e < s.len and (s[e].isAlphaNumeric or s[e] == '_'): inc e
      return (s[6 ..< e], true)
    if t.startsWith("def test") or t.startsWith("async def test"):
      let k = t.find("test")
      var e = k
      while e < t.len and (t[e].isAlphaNumeric or t[e] == '_'): inc e
      let n = t[k ..< e]
      if t.len == s.len: return (n, false)
      for u in countdown(l - 1, max(0, l - 2000)):
        let ul = b.lines[u]
        if ul.len > 0 and ul[0] notin {' ', '\t', '#', '@'}:
          if ul.startsWith("class Test"):
            var e2 = 6
            while e2 < ul.len and (ul[e2].isAlphaNumeric or ul[e2] == '_'): inc e2
            return (ul[6 ..< e2] & "::" & n, false)
          break
  of "go":
    if s.startsWith("func Test") and "*testing.T" in s:
      var e = 5
      while e < s.len and (s[e].isAlphaNumeric or s[e] == '_'): inc e
      return (s[5 ..< e], false)
  of "cs", "jvm", "php":
    let lang = testLangOf(b.path)
    let n = testMethodName(t.strip)
    if n.len == 0: return ("", false)
    if lang == "php" and "function test" in t: return (n, false)
    var u = l - 1
    while u >= 0:
      let ut = b.lines[u].strip
      if testAttrLine(lang, ut): return (n, false)
      if ut.startsWith("[") or ut.startsWith("@") or ut.startsWith("*") or ut.startsWith("/*") or ut.startsWith("#["): dec u
      else: break
  of "rs":
    let k = t.find("fn ")
    if k >= 0 and (k == 0 or t[0 ..< k].strip in ["pub", "async", "pub async", "pub(crate)"]):
      var u = l - 1
      while u >= 0 and b.lines[u].strip.startsWith("#["):
        if b.lines[u].strip.endsWith("test]"):
          var e = k + 3
          while e < t.len and (t[e].isAlphaNumeric or t[e] == '_'): inc e
          return (t[k + 3 ..< e], false)
        dec u
  else: discard
  ("", false)

proc runOtherTests(path, filter: string) =
  let (cmd, cwd) = otherTestCmd(path, filter)
  if cmd.len == 0: return
  let tool = cmd.firstWord
  if tool notin ["pytest"] and not tool.contains('/') and not haveExe(tool.strip(chars = {'\''})):
    error(tool & " is not installed")
    return
  discard saveAll()
  for e in testEntries:
    if e.path == path and (filter.len == 0 or e.name == filter or e.suite == filter): testStatus[testKey(path, e.name)] = 3
  testRunPath = path
  runCommand(cmd, cwd)
  let p = path
  let j = runningJob()
  if j != nil:
    let prev = j.onDone
    j.onDone = proc(jj: Job) =
      if prev != nil: prev(jj)
      parseOtherTestOutput(p, jj.output)
      var ok, bad = 0
      for e in testEntries:
        if e.path != p: continue
        let k = testKey(p, e.name)
        if testStatus.getOrDefault(k) == 3: testStatus[k] = (if jj.code == 0: 1 else: 2)
        if not e.isSuite:
          case testStatus.getOrDefault(k)
          of 1: inc ok
          of 2: inc bad
          else: discard
      if bad > 0: toast($bad & " test(s) failed in " & extractFilename(p), 1, "Show", proc() = setPanel(pkOutput))
      elif ok > 0: toast($ok & " test(s) passed in " & extractFilename(p), 4)
      needRender = true
