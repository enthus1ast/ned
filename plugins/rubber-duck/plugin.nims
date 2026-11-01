## rubber-duck — talk your code through with a duck, a line at a time: it asks the questions, you find the bug
##
##   Duck: talk it through        the selection — or the routine the cursor is in — a line at a time: for each, a
##                                question that fits it (when is this true? what comes back here? what do you expect
##                                x to be?) and you answer. Enter with nothing stops. Then the talk, in a Markdown
##                                tab of its own, to keep or throw away
##   Duck: a question to ask myself   one question to get you thinking, for when you are stuck
##
## Explaining code out loud, line by line, is how the bug shows itself: the duck only listens. Blank lines and
## comments are passed over; at most 40 lines a talk.
import nedplugin

requiresNed(">= 6.31")
pluginInfo(version = "1.0.0", author = "Sultan Al Isaiee (@foxoman)", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")

const
  Openers = ["proc ", "func ", "method ", "iterator ", "template ", "macro ", "converter ", "def ", "fn ", "func(",
             "function ", "pub fn ", "async def ", "sub "]
  Stuck = [
    "What did you expect to happen — and what happened instead?",
    "When did it last work? What changed since?",
    "What is the smallest input that goes wrong?",
    "Which line would you bet the bug is on? Why that one?",
    "What are you sure of, that you have not checked?",
    "If a value were wrong here, which one would it be?",
    "Does it fail every time, or only sometimes? What is different when it does?",
    "What would you print, to see where it starts going wrong?",
    "Is the code you are reading the code that runs?",
    "What would you tell someone who asked what this part is for?",
  ]
  Cheers = ["Quack. Did you hear it too?", "Quack! That line looked suspicious.", "Quack — I think you have it.",
            "The duck nods. Go and fix it."]

var seed = 0                    # (NimScript has no random of its own: a little one, seeded by the clock)

proc rnd(n: int): int =
  ## a number from 0 to n - 1, more or less at random
  if seed == 0: seed = int(unixTime() * 1000) mod 2147483647 + 1
  seed = (seed * 1103515245 + 12345) mod 2147483648
  (seed shr 8) mod max(1, n)

func indentOf(s: string): int =
  ## how far the line is indented
  while result < s.len and s[result] in {' ', '\t'}: inc result

func isComment(t: string): bool =
  ## a line that is only a comment
  t.startsWith("#") or t.startsWith("//") or t.startsWith("--") or t.startsWith(";") or t.startsWith("/*") or
    t.startsWith("*")

func firstName(t: string, after: int): string =
  ## the name that starts at `after` (letters, digits, _)
  var i = after
  while i < t.len and t[i] in {' ', '\t'}: inc i
  while i < t.len and t[i] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
    result.add t[i]
    inc i

func question*(line: string): string =
  ## the question that fits the line: a condition, a loop, what comes back, what a variable is, a call …
  let t = line.strip
  let w = t.split({' ', '(', ':'})[0]
  for o in Openers:
    if t.startsWith(o) or t.startsWith("export " & o) or t.startsWith("pub " & o):
      let n = firstName(t, t.find(o) + o.len)
      return "What is `" & n & "` for — what does it take, and what does it promise to give back?"
  case w
  of "if", "elif", "when", "while", "unless", "until":
    return "When is this true — and what happens when it is not?"
  of "else":
    return "Which cases end up here? Is each of them right?"
  of "case", "match", "switch":
    return "Which values can come here — is there one no branch handles?"
  of "of":
    return "When does this branch run? Is it the only one that should?"
  of "for", "foreach":
    return "What does this go over, and how many times does it run? What about none at all?"
  of "return", "yield":
    return "What should come back here, and for which input? Is it always that?"
  of "raise", "throw", "panic":
    return "When does this happen — and who catches it?"
  of "assert", "doAssert":
    return "Why must this hold here? What would break it?"
  of "discard":
    return "What is thrown away here — could it ever matter?"
  of "try":
    return "What can go wrong in this block?"
  of "except", "catch", "finally":
    return "What do you do when that happens — is it enough?"
  of "let", "var", "const", "val", "auto", "local":
    let n = firstName(t, w.len)
    return "What value do you expect `" & n & "` to have here — and could it be anything else?"
  of "break", "continue":
    return "Why stop here — is this the loop you mean?"
  else: discard
  if t.startsWith("result") and "=" in t:
    return "What should the result be at this point?"
  let eq = t.find(" = ")
  if eq > 0 and t.find('(') < 0 or (eq > 0 and t.find('(') > eq):
    return "What is `" & t[0 ..< eq].strip & "` before this line, and after it?"
  # (a call: the command-like one at the start of the line — echo x — else the first name before a bracket)
  let head = firstName(t, 0)
  if head.len > 0 and head.len < t.len and t[head.len] == ' ' and head.len + 1 < t.len and
     t[head.len + 1] notin {'=', '+', '-', '*', '/', '<', '>', '!', '.', '&', '|', '%', ':'}:
    return "What does `" & head & "` do with what it is given — and what could go wrong in it?"
  let paren = t.find('(')
  if paren > 0:
    var k = paren - 1
    while k >= 0 and t[k] in {'a'..'z', 'A'..'Z', '0'..'9', '_', '.'}: dec k
    let name = t[k + 1 ..< paren]
    if name.len > 0:
      return "What does `" & name & "` do with what it is given — and what could go wrong in it?"
  "Say what this line does, in plain words."

proc routineAround(b: Buf, at: int): (int, int) =
  ## the lines of the routine the line `at` is in — the nearest one above it whose body reaches it: from its header to
  ## its last indented line (-1, -1: none)
  let ls = b.lines
  if ls.len == 0: return (-1, -1)
  var k = min(at, ls.high)
  while k >= 0:
    let t = ls[k].strip
    var opener = false
    for o in Openers:
      if t.startsWith(o) or t.startsWith("export " & o) or t.startsWith("pub " & o): opener = true
    if opener:
      let base = indentOf(ls[k])
      var e = k
      for i in k + 1 .. ls.high:
        if ls[i].strip.len == 0: continue
        if indentOf(ls[i]) <= base and not ls[i].strip.startsWith("}"): break
        e = i
      if e >= at: return (k, e)
    dec k
  (-1, -1)

proc talkThrough() =
  ## the talk: the lines, a question for each, the answers, then the tab
  let b = current()
  let r = b.selection
  var first, last: int
  if not r.isEmpty:
    first = r.start.line
    last = (if r.stop.col == 0 and r.stop.line > r.start.line: r.stop.line - 1 else: r.stop.line)
  else:
    (first, last) = routineAround(b, b.cursor.line)
    if first < 0:
      message("🦆 Select the lines to talk through, or put the cursor in a routine")
      return
  let ls = b.lines(first, last)
  var talk = "# 🦆 Talking it through\n\n" & (if b.path.len > 0: "`" & extractFilename(b.path) & "`, " else: "") &
             "lines " & $(first + 1) & "–" & $(last + 1) & "\n\n"
  var asked = 0
  var stopped = false
  for i, l in ls:
    let t = l.strip
    if t.len == 0 or isComment(t): continue
    if asked >= 40: break
    let q = question(l)
    let shownLine = if t.len > 50: t[0 ..< 49] & "…" else: t
    let a = ask("🦆 " & $(first + i + 1) & ": " & shownLine & " — " & q, "")
    inc asked
    talk.add "**" & $(first + i + 1) & "** `" & t.replace("`", "'") & "`\n\n> " & q & "\n\n"
    if a.strip.len == 0:
      talk.add "*(stopped here)*\n"
      stopped = true
      break
    talk.add a.strip & "\n\n"
  if asked == 0:
    message("🦆 Nothing to talk through there: only blank lines and comments")
    return
  talk.add "\n---\n" & Cheers[rnd(Cheers.len)] & "\n"
  discard newTab("🦆 talk", talk, "markdown")
  message("🦆 " & $asked & (if asked == 1: " line" else: " lines") & " talked through" &
          (if stopped: " (stopped)" else: "") & " — the talk is in its tab")

command "Duck: talk it through":
  talkThrough()

command "Duck: a question to ask myself":
  let q = Stuck[rnd(Stuck.len)]
  toast("🦆 " & q)
  message("🦆 " & q)
