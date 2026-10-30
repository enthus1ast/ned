## Secrets kept from the AI: API keys, tokens, private keys, passwords in connection strings and in assignments
## (`.env` lines, settings, code) are found in what ned is about to send to an AI provider and replaced with a
## placeholder such as `[REDACTED:api-key#1]`. The same secret always gets the same placeholder, so the model can
## still say which one it means, and where the model writes a placeholder back into a file ned puts the secret
## back (restoreSecrets) — the file never loses it. Also: which files hold secrets (.env, *.pem, id_ed25519 …) and
## are never sent at all, and which environment variables are secrets (ned --sandbox leaves them out).
## A module of its own, standard library only: the unit tests and ned --sandbox use it as the editor does.

import std/[json, strutils]

type SecretTable* = object
  ## the placeholders given so far, (placeholder, the secret): one table for a chat, so that every request of it
  ## uses the same placeholder for the same secret
  items*: seq[(string, string)]

const
  SecretMark* = "[REDACTED:"           # how every placeholder starts
  SecTok = {'A'..'Z', 'a'..'z', '0'..'9', '_', '-'}
  SecAlnum = {'A'..'Z', 'a'..'z', '0'..'9'}
  SecHex = {'0'..'9', 'a'..'f', 'A'..'F'}
  SecB64 = SecAlnum + {'+', '/', '=', '-', '_'}
  SecIdent = {'A'..'Z', 'a'..'z', '0'..'9', '_'}

func secPlaceholder(tab: var SecretTable, kind, value: string): string =
  ## the placeholder for a secret value of this kind: the one it already has in the table, else a new
  ## `[REDACTED:kind#n]` (n counting up) which is added to the table
  for (p, v) in tab.items:
    if v == value: return p
  result = SecretMark & kind & "#" & $(tab.items.len + 1) & "]"
  tab.items.add (result, value)

type SecSpan = tuple[a, b: int, kind: string]     # text[a ..< b] is a secret of this kind

func secFree(spans: seq[SecSpan], a, b: int): bool =
  ## no span found already overlaps a ..< b
  for s in spans:
    if a < s.b and s.a < b: return false
  true

func secRun(s: string, i: int, chars: set[char]): int =
  ## where the run of `chars` starting at i ends
  result = i
  while result < s.len and s[result] in chars: inc result

func secBoundary(s: string, i: int): bool =
  ## a token may start at i: what is before it is not part of a word
  i == 0 or s[i - 1] notin SecTok + {'.', '+', '/'}

func secPlaceholderish(v: string): bool =
  ## a value that only stands for a secret — an example, a variable, an empty one, one already replaced
  let l = v.toLowerAscii.strip
  if l.len == 0 or v.startsWith(SecretMark): return true
  if l[0] in {'$', '<', '%', '{'} or l.startsWith("env:") or l.startsWith("vault:"): return true
  var same = true
  for c in l:
    if c != l[0]: same = false
  if same: return true                                     # ****, xxxxxxxx
  for p in ["your", "my-", "my_", "change", "example", "placeholder", "todo", "fixme", "redacted", "dummy",
            "fake", "replace", "insert", "enter", "put-", "put_", "xxx", "<", "…", "..."]:
    if l.startsWith(p): return true
  l in ["password", "passwd", "secret", "token", "apikey", "api_key", "api-key", "key", "none", "null", "nil",
        "undefined", "true", "false", "yes", "no", "on", "off", "test", "string", "required", "optional"]

# ── tokens that are secrets by their shape ──

type SecShape = tuple[prefix, kind: string, chars: set[char], minLen, maxLen: int]

const SecShapes: array[33, SecShape] = [
  ("AKIA", "aws-key", {'A'..'Z', '0'..'9'}, 16, 16),
  ("ASIA", "aws-key", {'A'..'Z', '0'..'9'}, 16, 16),
  ("ghp_", "github-token", SecAlnum, 36, 255),
  ("gho_", "github-token", SecAlnum, 36, 255),
  ("ghu_", "github-token", SecAlnum, 36, 255),
  ("ghs_", "github-token", SecAlnum, 36, 255),
  ("ghr_", "github-token", SecAlnum, 36, 255),
  ("github_pat_", "github-token", SecIdent, 22, 255),
  ("glpat-", "gitlab-token", SecTok, 20, 255),
  ("xoxb-", "slack-token", SecAlnum + {'-'}, 10, 255),
  ("xoxp-", "slack-token", SecAlnum + {'-'}, 10, 255),
  ("xoxa-", "slack-token", SecAlnum + {'-'}, 10, 255),
  ("xoxr-", "slack-token", SecAlnum + {'-'}, 10, 255),
  ("xoxs-", "slack-token", SecAlnum + {'-'}, 10, 255),
  ("xoxe-", "slack-token", SecAlnum + {'-'}, 10, 255),
  ("sk-", "api-key", SecTok, 20, 300),                       # OpenAI, Anthropic (sk-ant-), OpenRouter (sk-or-) …
  ("sk_live_", "stripe-key", SecAlnum, 16, 255),
  ("sk_test_", "stripe-key", SecAlnum, 16, 255),
  ("rk_live_", "stripe-key", SecAlnum, 16, 255),
  ("rk_test_", "stripe-key", SecAlnum, 16, 255),
  ("whsec_", "webhook-secret", SecAlnum, 24, 255),
  ("AIza", "google-key", SecTok, 35, 35),
  ("npm_", "npm-token", SecAlnum, 36, 36),
  ("pypi-", "pypi-token", SecTok, 50, 400),
  ("hf_", "hf-token", SecAlnum, 30, 60),
  ("gsk_", "groq-key", SecAlnum, 40, 80),
  ("dop_v1_", "digitalocean-token", SecHex, 64, 64),
  ("shpat_", "shopify-token", SecHex, 32, 32),
  ("shpss_", "shopify-token", SecHex, 32, 32),
  ("glsa_", "grafana-token", SecIdent, 32, 64),
  ("AGE-SECRET-KEY-1", "age-key", {'A'..'Z', '0'..'9'}, 58, 58),
  ("SG.", "sendgrid-key", SecTok + {'.'}, 60, 80),
  ("xapp-", "slack-token", SecAlnum + {'-'}, 10, 255)]

func secShapeAt(s: string, i: int): (int, string) =
  ## a token of a known shape starting at i: (its end, its kind) — (-1, "") none
  for sh in SecShapes:
    if s.continuesWith(sh.prefix, i):
      let a = i + sh.prefix.len
      let e = secRun(s, a, sh.chars)
      let n = e - a
      if n < sh.minLen or n > sh.maxLen: continue
      if e < s.len and s[e] in SecAlnum: continue          # (part of a longer word)
      let body = s[a ..< e]
      if sh.prefix == "sk-":
        # (not "sk-learn-something": a key has letters and digits)
        var digits, letters = 0
        for c in body:
          if c in Digits: inc digits
          elif c in Letters: inc letters
        if digits < 2 or letters < 6: continue
      if sh.prefix == "SG." and body.count('.') != 1: continue
      return (e, sh.kind)
  (-1, "")

func secJwtAt(s: string, i: int): int =
  ## a JSON web token (eyJ….eyJ….sig) starting at i: its end, -1 none
  if not (s.continuesWith("eyJ", i)): return -1
  let a = secRun(s, i, SecTok)
  if a - i < 10 or a >= s.len or s[a] != '.' or not s.continuesWith("eyJ", a + 1): return -1
  let b = secRun(s, a + 1, SecTok)
  if b - a - 1 < 10 or b >= s.len or s[b] != '.': return -1
  let c = secRun(s, b + 1, SecTok)
  if c - b - 1 < 10: return -1
  c

func secTelegramAt(s: string, i: int): int =
  ## a Telegram bot token (123456789:AA…, 35 characters after the colon): its end, -1 none
  let a = secRun(s, i, Digits)
  if a - i notin 8 .. 10 or a >= s.len or s[a] != ':': return -1
  let b = secRun(s, a + 1, SecTok)
  if b - a - 1 != 35: return -1
  b

# ── assignments: a name that says "secret", then = or :, then a value ──

const
  SecNameNot = ["name", "file", "path", "dir", "url", "uri", "length", "len", "size", "count", "min", "max", "type",
                "kind", "field", "label", "header", "prefix", "suffix", "env", "envvar", "var", "id", "policy",
                "pattern", "regex", "hint", "prompt", "placeholder", "message", "msg", "error", "enabled", "required",
                "expiry", "expires", "ttl", "timeout", "mode", "format", "algorithm", "location", "provider",
                "manager", "service", "source", "endpoint", "validator", "setting", "settings", "helper", "store",
                "storage", "command", "cmd", "flag", "option", "options", "schema", "column", "table", "key"]
  SecKeyNames = ["apikey", "secretkey", "privatekey", "accesskey", "accountkey", "authkey", "masterkey", "signingkey",
                 "sessionkey", "encryptionkey"]

func secNameKind(name: string): string =
  ## the kind of secret a name says it holds ("" none): DB_PASSWORD, apiKey, "client-secret", SECRET_KEY_BASE,
  ## aws_secret_access_key — not passwordLength, tokenKind, secretName, primaryKey
  var n = newStringOfCap(name.len)
  for c in name:
    if c in Letters + Digits: n.add toLowerAscii(c)
  if n.len < 3 or n in ["pwd", "oldpwd"]: return ""            # (the shell's current folder)
  for x in SecNameNot:
    if n.endsWith(x):
      var keyName = false
      for k in SecKeyNames:
        if n.endsWith(k): keyName = true
      if not (x == "key" and keyName): return ""
  if "password" in n or "passwd" in n or "passphrase" in n or n.endsWith("pwd"): return "password"
  if "token" in n: return "token"
  for k in SecKeyNames:
    if k in n: return "api-key"
  if "secret" in n or "credential" in n or n.endsWith("dsn") or "connectionstring" in n or n.endsWith("connstr"):
    return "secret"
  ""

func secRandomish(v: string): bool =
  ## a value that looks made up by a machine, not a word: no spaces, 8 characters or more, and digits or a mix
  if v.len < 8 or ' ' in v: return false
  var digits, upper, lower, other = 0
  for c in v:
    if c in Digits: inc digits
    elif c in {'A'..'Z'}: inc upper
    elif c in {'a'..'z'}: inc lower
    else: inc other
  digits > 0 or (upper > 0 and lower > 0 and v.len >= 12) or v.len >= 24

func secIdentPath(v: string): bool =
  ## a name or a chain of them (a variable, a type, req.body.password): code, not a literal
  if v.len == 0 or v[0] notin Letters + {'_'}: return false
  for c in v:
    if c notin SecIdent + {'.'}: return false
  true

proc secAssignments(s: string, spans: var seq[SecSpan]) =
  ## `NAME=value`, `name: value`, `"name": "value"`, `name = "value"`, `--password=value`, `?token=value&`
  var i = 0
  while i < s.len:
    if s[i] notin SecIdent:
      inc i
      continue
    let a = i
    i = secRun(s, i, SecIdent + {'-', '.'})
    var j = i
    if j < s.len and s[j] in {'"', '\''}: inc j                  # "name": …
    while j < s.len and s[j] in {' ', '\t'}: inc j
    if j >= s.len: break
    var sepLen = 0
    if s[j] == '=' and not s.continuesWith("==", j): sepLen = (if s.continuesWith("=>", j): 2 else: 1)
    elif s[j] == ':': sepLen = (if s.continuesWith(":=", j): 2 elif s.continuesWith("::", j): 0 else: 1)
    elif s[j] == '?' and s.continuesWith("?=", j): sepLen = 2
    if sepLen == 0: continue                                     # (most names: no = or : after them)
    let name = s[a ..< i].strip(chars = {'-', '.'})
    let kind = secNameKind(name)
    if kind.len == 0: continue
    j += sepLen
    while j < s.len and s[j] in {' ', '\t'}: inc j
    if j >= s.len: break
    var va, vb: int
    if s[j] in {'"', '\'', '`'}:
      let q = s[j]
      va = j + 1
      var k = va
      while k < s.len and s[k] != q and s[k] != '\n':
        if s[k] == '\\' and q != '\'': inc k
        inc k
      if k >= s.len or s[k] != q: continue                     # (no closing quote on the line: not a literal)
      vb = k
      let v = s[va ..< vb]
      if secPlaceholderish(v): continue
      if kind == "password":
        if v.len < 3: continue
      elif not secRandomish(v): continue
    else:
      va = j
      var k = j
      while k < s.len and s[k] notin {' ', '\t', '\r', '\n', '"', '\'', '`', '&', ';', ',', ')', ']', '}', '>', '<',
                                       '\\'}:
        inc k
      vb = k
      let v = s[va ..< vb]
      if v.len < 3 or secPlaceholderish(v) or '(' in v or '[' in v: continue
      if v.allCharsInSet(Digits) and v.len < 4: continue
      # (in code `password: string` and `token = nextToken` are a type and a variable; a value with no quotes is
      #  taken when the name is an environment variable's — DB_PASSWORD=… — or the value has digits or symbols)
      let envName = name.len > 0 and name.allCharsInSet({'A'..'Z', '0'..'9', '_'})
      if not envName and secIdentPath(v) and v.find(Digits) < 0: continue
      if kind != "password" and not envName and not secRandomish(v): continue
    if secFree(spans, va, vb): spans.add (va, vb, kind)
    i = vb

# ── the rest: private keys, passwords in URLs, Authorization headers, connection strings ──

proc secPrivateKeys(s: string, spans: var seq[SecSpan]) =
  ## finds PEM private keys (`-----BEGIN … PRIVATE KEY-----` through the matching END line, or to the end of the text
  ## when it has none) and adds each as a span of kind private-key
  var i = 0
  while true:
    let a = s.find("-----BEGIN ", i)
    if a < 0: break
    let le = s.find("-----", a + 11)
    if le < 0: break
    let label = s[a + 11 ..< le]
    i = le + 5
    if "PRIVATE KEY" notin label or label.len > 40: continue
    let endMark = "-----END " & label & "-----"
    let e = s.find(endMark, i)
    let b = if e < 0: s.len else: e + endMark.len
    if secFree(spans, a, b): spans.add (a, b, "private-key")
    i = b

proc secUrlPasswords(s: string, spans: var seq[SecSpan]) =
  ## scheme://user:password@host — the password
  var i = 0
  while true:
    let k = s.find("://", i)
    if k < 0: break
    i = k + 3
    if k == 0 or s[k - 1] notin Letters + Digits: continue
    var e = i
    while e < s.len and s[e] notin {'/', ' ', '\t', '\n', '\r', '"', '\'', '`', '?', '#', '<', '>'}: inc e
    let at = s.rfind('@', last = e - 1)
    if at < i: continue
    let colon = s.find(':', i)
    if colon < 0 or colon >= at: continue
    let pw = s[colon + 1 ..< at]
    if pw.len == 0 or secPlaceholderish(pw): continue
    if secFree(spans, colon + 1, at): spans.add (colon + 1, at, "password")
    i = at + 1

proc secHeaders(s: string, spans: var seq[SecSpan]) =
  ## Bearer <token>, Authorization: Basic <base64>, AccountKey=…; (Azure), Password=…; (a .NET connection string)
  let low = s.toLowerAscii
  for (word, kind, minLen) in [("bearer ", "token", 16), ("basic ", "password", 8)]:
    var i = 0
    while true:
      let k = low.find(word, i)
      if k < 0: break
      i = k + word.len
      if k > 0 and low[k - 1] in SecIdent: continue
      if word == "basic ":
        let ls = low.rfind('\n', last = max(0, k - 1))
        if "authorization" notin low[max(0, ls) ..< k]: continue
      var a = i
      while a < s.len and s[a] == ' ': inc a
      let e = secRun(s, a, SecB64 + {'.', '~'})
      if e - a >= minLen and not s[a ..< e].startsWith(SecretMark) and secFree(spans, a, e):
        spans.add (a, e, kind)
      i = max(i, e)
  for key in ["accountkey=", "sharedaccesskey=", "password=", "pwd="]:
    var i = 0
    while true:
      let k = low.find(key, i)
      if k < 0: break
      i = k + key.len
      # (in a connection string: after a ;)
      if not (k > 0 and low[k - 1] == ';' or k > 1 and low[k - 1] == ' ' and low[k - 2] == ';'): continue
      var e = i
      while e < s.len and s[e] notin {';', '"', '\'', '\n', '\r', ' ', '\t'}: inc e
      if e - i >= 3 and not secPlaceholderish(s[i ..< e]) and secFree(spans, i, e):
        spans.add (i, e, (if key.startsWith("p"): "password" else: "api-key"))
  for (host, kind) in [("hooks.slack.com/services/", "webhook"), ("discord.com/api/webhooks/", "webhook"),
                       ("discordapp.com/api/webhooks/", "webhook")]:
    var i = 0
    while true:
      let k = s.find(host, i)
      if k < 0: break
      let a = k + host.len
      let e = secRun(s, a, SecTok + {'/'})
      if e - a >= 20 and secFree(spans, a, e): spans.add (a, e, kind)
      i = max(a, e)

proc secTokens(s: string, spans: var seq[SecSpan]) =
  ## finds the tokens that are secrets by their shape — the known prefixes (AWS, GitHub, Slack, Stripe, OpenAI/Anthropic
  ## sk- …), JSON web tokens and Telegram bot tokens — at the start of a word, and adds their spans
  var i = 0
  while i < s.len:
    let c = s[i]
    if c in {'A', 'g', 'x', 's', 'r', 'w', 'n', 'p', 'h', 'd', 'S', 'e', '0'..'9'} and secBoundary(s, i):
      var (e, kind) = secShapeAt(s, i)
      if e < 0 and c == 'e':
        e = secJwtAt(s, i)
        kind = "jwt"
      if e < 0 and c in Digits:
        e = secTelegramAt(s, i)
        kind = "telegram-token"
      if e > 0:
        if secFree(spans, i, e): spans.add (i, e, kind)
        i = e
        continue
    inc i

proc secFind*(s: string): seq[SecSpan] =
  ## where the secrets in a text are (unsorted, not overlapping)
  if s.len < 8: return
  secPrivateKeys(s, result)
  secTokens(s, result)
  secUrlPasswords(s, result)
  secHeaders(s, result)
  secAssignments(s, result)

proc redactSecrets*(text: string, tab: var SecretTable): string =
  ## the text with each secret replaced by its placeholder ([REDACTED:api-key#1]) — the same secret, the same
  ## placeholder, by `tab`
  var spans = secFind(text)
  if spans.len == 0: return text
  # (sorted by where they start: a few, so insertion sort)
  for i in 1 ..< spans.len:
    var j = i
    while j > 0 and spans[j - 1].a > spans[j].a:
      swap(spans[j - 1], spans[j])
      dec j
  var last = 0
  for sp in spans:
    result.add text[last ..< sp.a]
    result.add secPlaceholder(tab, sp.kind, text[sp.a ..< sp.b])
    last = sp.b
  result.add text[last .. ^1]

proc redactSecrets*(text: string): string =
  ## the text with its secrets replaced (placeholders of its own)
  var tab: SecretTable
  redactSecrets(text, tab)

func secBase64Blob(s: string): bool =
  ## a picture or another file in base64 (sent with a message): nothing in it is read as text
  if s.len < 100_000: return false
  let t = if s.startsWith("data:"): s[min(s.len, s.find(',') + 1) .. ^1] else: s
  for k in countup(0, min(t.len, 4096) - 1):
    if t[k] notin SecB64: return false
  true

proc redactSecretsJson*(j: JsonNode, tab: var SecretTable): int =
  ## every string in a request (a JSON body) with its secrets replaced, in place: how many strings changed
  if j == nil: return
  case j.kind
  of JString:
    let s = j.getStr
    if secBase64Blob(s): return
    let r = redactSecrets(s, tab)
    if r != s:
      j.str = r
      result = 1
  of JArray:
    for x in j.elems: result += redactSecretsJson(x, tab)
  of JObject:
    for _, v in j: result += redactSecretsJson(v, tab)
  else: discard

func restoreSecrets*(text: string, tab: SecretTable): string =
  ## the placeholders in a text (what the model wrote) back to the secrets they stand for
  result = text
  if SecretMark notin result: return
  for (p, v) in tab.items:
    if p in result: result = result.replace(p, v)

proc restoreSecretsJson*(text: string, tab: SecretTable): string =
  ## the same for a JSON text (a tool call's arguments): the secrets go back inside its strings, escaped
  if SecretMark notin text: return text
  try:
    var j = parseJson(text)
    proc walk(n: JsonNode) =
      ## replaces, in each string of the JSON, the placeholders by the secrets they stand for
      case n.kind
      of JString: n.str = restoreSecrets(n.str, tab)
      of JArray:
        for x in n.elems: walk(x)
      of JObject:
        for _, v in n: walk(v)
      else: discard
    walk(j)
    $j
  except CatchableError:
    var r = text
    for (p, v) in tab.items:
      if p in r: r = r.replace(p, escapeJson(v)[1 ..< ^1])
    r

# ── files that are secrets: never sent as context ──

func secGlob(pat, s: string): bool =
  ## a .gitignore-style pattern: * (not /), ** (anything), ? and [abc]
  var p = 0
  var i = 0
  var starP, starI = -1
  while i < s.len:
    if p < pat.len and pat[p] == '*':
      if p + 1 < pat.len and pat[p + 1] == '*':
        return secGlob(pat[p + 2 .. ^1].strip(trailing = false, chars = {'/'}), s[i .. ^1]) or
               (i < s.len and secGlob(pat[p .. ^1], s[i + 1 .. ^1]))
      starP = p
      starI = i
      inc p
    elif p < pat.len and pat[p] == '[':
      let e = pat.find(']', p + 1)
      if e < 0: return false
      var cls = pat[p + 1 ..< e]
      let neg = cls.startsWith("!") or cls.startsWith("^")
      if neg: cls = cls[1 .. ^1]
      var hit = false
      var k = 0
      while k < cls.len:
        if k + 2 < cls.len and cls[k + 1] == '-':
          if s[i] in cls[k] .. cls[k + 2]: hit = true
          k += 3
        else:
          if s[i] == cls[k]: hit = true
          inc k
      if hit != neg:
        p = e + 1
        inc i
      elif starP >= 0 and s[starI] != '/':
        p = starP + 1
        inc starI
        i = starI
      else: return false
    elif p < pat.len and (pat[p] == '?' and s[i] != '/' or pat[p] == s[i]):
      inc p
      inc i
    elif starP >= 0 and s[starI] != '/':
      p = starP + 1
      inc starI
      i = starI
    else: return false
  while p < pat.len and pat[p] == '*': inc p
  p == pat.len

const SecretFileGlobs* = [".env", ".env.*", "*.env", "*.pem", "*.key", "*.p12", "*.pfx", "*.jks", "*.keystore",
                          "*.ppk", "*.kdbx", "*.tfvars", "*.tfstate", "*.tfstate.backup", ".netrc", "_netrc",
                          ".npmrc", ".pypirc", ".pgpass", ".htpasswd", ".git-credentials", "credentials",
                          "credentials.json", "client_secret*.json", "service-account*.json", "secrets.yml",
                          "secrets.yaml", "secrets.json", "secrets.toml", ".secrets", "*.secret", "*.secrets"]
  ## files that hold secrets by their name (also id_rsa, id_ed25519 …: an id_ name with no extension)

func isSecretFile*(path: string, extra: openArray[string] = [], root = ""): bool =
  ## a file that holds secrets — by its name (.env, *.pem, id_ed25519, credentials.json …; not .env.example), or
  ## by one of `extra`'s patterns (the project's .gitignore lines about secrets, from secretIgnorePatterns),
  ## matched against its path inside `root` and against each part of it
  let p = path.replace('\\', '/')
  let base = p[p.rfind('/') + 1 .. ^1]
  if base.len == 0: return false
  let lb = base.toLowerAscii
  if lb.startsWith(".env.") or lb.startsWith(".env-"):
    for x in ["example", "sample", "template", "dist", "defaults", "schema"]:
      if lb.endsWith(x) or ("." & x & ".") in lb: return false
  for g in SecretFileGlobs:
    if secGlob(g, lb): return true
  if lb.startsWith("id_") and '.' notin lb and lb.len > 3: return true    # id_rsa, id_ed25519 (not id_rsa.pub)
  if extra.len == 0: return false
  var rel = p
  if root.len > 0:
    let r = root.replace('\\', '/').strip(leading = false, chars = {'/'}) & "/"
    if p.startsWith(r): rel = p[r.len .. ^1]
  let parts = rel.split('/')
  for pat0 in extra:
    var pat = pat0.strip(leading = false, chars = {'/'})
    if pat.len == 0: continue
    if '/' in pat.strip(trailing = false, chars = {'/'}):
      pat = pat.strip(trailing = false, chars = {'/'})
      if secGlob(pat, rel) or secGlob(pat & "/**", rel): return true
    else:
      for part in parts:
        if secGlob(pat, part): return true
  false

func secretIgnorePatterns*(gitignore: string): seq[string] =
  ## the lines of a .gitignore that keep secrets out of git (.env, *.pem, config/prod-secrets.yml, id_*): ned
  ## does not send those files to an AI either
  for raw in gitignore.splitLines:
    let l = raw.strip
    if l.len == 0 or l[0] in {'#', '!'}: continue
    let low = l.toLowerAscii
    let base = low.strip(chars = {'/'})
    let last = base[base.rfind('/') + 1 .. ^1]
    var hit = last.startsWith(".env") or last.endsWith(".env") or last.startsWith("id_")
    for w in ["secret", "credential", "password", "passwd", "token", ".pem", ".key", ".p12", ".pfx", "keystore",
              "private", "apikey", "api_key", "api-key", "netrc", "tfvars", "tfstate", "htpasswd", ".jks", "vault"]:
      if w in low: hit = true
    if hit: result.add l

# ── environment variables that are secrets ──

func secretEnvName*(name: string): bool =
  ## an environment variable that holds a secret by its name: OPENAI_API_KEY, GITHUB_TOKEN, AWS_SECRET_ACCESS_KEY,
  ## PGPASSWORD, NPM_TOKEN … (not SSH_AUTH_SOCK, not KEYMAP)
  let n = name.toUpperAscii
  for x in ["_FILE", "_PATH", "_DIR", "_HOME", "_TOKENS", "_COUNT", "_LIMIT", "_SIZE", "_TTL", "_TIMEOUT"]:
    if n.endsWith(x): return false                       # (where a secret is, or a number about one)
  for w in ["TOKEN", "SECRET", "PASSWORD", "PASSWD", "PASSPHRASE", "CREDENTIAL", "API_KEY", "APIKEY",
            "ACCESS_KEY", "PRIVATE_KEY", "AUTH_KEY", "SESSION_KEY", "SIGNING_KEY", "MASTER_KEY", "ACCOUNT_KEY"]:
    if w in n: return true
  n.endsWith("_KEY") or n.endsWith("_PAT") or n.endsWith("_DSN") or n.endsWith("_PWD") or n == "PGPASS"
