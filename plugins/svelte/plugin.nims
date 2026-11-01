## svelte — Svelte components: colours, comments, indentation, F5, snippets, an outline; svelteserver and prettier
##
## Turn it on in the Plugins dock (AVAILABLE). It teaches ned Svelte's `.svelte` components: their colours (ned's
## generic lexer with JavaScript's words and Svelte's — {#if}, {#each … as}, {:else}, {@html}, {@render} … —,
## Capitalised components as types), `<!-- … -->` comments (Ctrl+/ makes them) and the script's and style's
## `/* … */`, indentation after `{` `(` `[`, two spaces as prettier writes, brackets and quotes that close
## themselves, snippets (script, style, if, each, await, snippet, props, state, derived, effect) and F5: `npm run
## dev` in the project (the package.json above the file; pnpm, yarn or bun when its lock file is there). Build
## (Alt+B) is `npm run build` the same way. The generic lexer colours the file as one language: the markup's tags
## are not told apart from the script.
##
## Without a language server, the outline lists the component's scripts (their props, state, constants and
## functions under them), its {#snippet}s and its style, from a simple scan.
##
## The tools, when they are on PATH: svelteserver, Svelte's language server (`npm install -g
## svelte-language-server`) — completion, hover, go to definition, problems, the script's TypeScript too; prettier
## formats (Format document, and on save with editor.formatOnSave) with prettier-plugin-svelte, which the project
## names in its .prettierrc (`"plugins": ["prettier-plugin-svelte"]`, as `npx sv create` sets it up).
##
## Settings (the Plugins dock › svelte › its settings; Plugins: reload after a change):
## - plugins.svelte.server — the language server's command, when it is not `svelteserver --stdio` ("off": none)
## - plugins.svelte.formatter — the formatter's command (the text on its stdin), when it is not prettier
import nedplugin
import std/strutils

requiresNed(">= 6.28")
pluginInfo(version = "1.0.0", author = "Sultan Al Isaiee (@foxoman)", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")

settingDef("server", "", "The language server's command: empty for svelteserver --stdio (when it is installed), " &
           "\"off\" for none. Plugins: reload after a change")
settingDef("formatter", "", "The formatter's command, which reads the text on its stdin: empty for prettier (when " &
           "it is installed; the project names prettier-plugin-svelte), \"off\" for none. Plugins: reload after a " &
           "change")

# (the project's package manager, by its lock file: npm when there is none)
const SveltePm = "pm=npm; [ -f \"$d/pnpm-lock.yaml\" ] && pm=pnpm; [ -f \"$d/yarn.lock\" ] && pm=yarn; " &
                 "{ [ -f \"$d/bun.lock\" ] || [ -f \"$d/bun.lockb\" ]; } && pm=bun; "

proc svelteScript(what: string): string =
  ## `<pm> run <what>` in the folder of the package.json above the file
  "sh -c 'd=\"$dir\"; while [ ! -f \"$d/package.json\" ] && [ \"$d\" != / ]; do d=$(dirname \"$d\"); done; " &
    "cd \"$d\" || exit 1; " & SveltePm & "exec $pm run " & what & "'"

language("svelte", LangSpec(
  name: "Svelte",
  extensions: @["svelte"],
  # (the generic lexer has one block comment: the markup's <!-- -->, which Ctrl+/ makes; the script's and style's
  # /* */ are coloured through the documentation comment's)
  blockComment: @["<!--", "-->"],
  docBlockComment: @["/*", "*/"],
  quotes: "\"'`",
  capitalTypes: true,
  decorators: true,
  # (not `class`: the markup's class="…" would colour the word after it as a type)
  keywords: @["const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "switch", "case",
              "break", "continue", "new", "this", "typeof", "instanceof", "in", "of", "import", "export", "from",
              "default", "async", "await", "try", "catch", "finally", "throw", "yield", "each", "as", "then", "key",
              "snippet"],
  constants: @["true", "false", "null", "undefined"],
  functionWords: @["function"],
  indentAfter: @["{", "(", "["],
  dedent: "})]",
  indentSize: 2,
  run: svelteScript("dev"),
  build: svelteScript("build"),
  pairs: "()[]{}\"\""))

snippet("svelte", "script", "<script lang=\"${1:ts}\">\n\t$0\n</script>", "the component's script")
snippet("svelte", "style", "<style>\n\t$0\n</style>", "the component's style")
snippet("svelte", "if", "{#if ${1:cond}}\n\t$0\n{/if}", "an if block")
snippet("svelte", "each", "{#each ${1:items} as ${2:item}}\n\t$0\n{/each}", "an each block")
snippet("svelte", "await", "{#await ${1:promise}}\n\t${2:loading}\n{:then ${3:value}}\n\t$0\n{/await}",
        "an await block")
snippet("svelte", "snippet", "{#snippet ${1:name}(${2:item})}\n\t$0\n{/snippet}", "a snippet")
snippet("svelte", "props", "let { ${1:name} } = $props();$0", "the props")
snippet("svelte", "state", "let ${1:name} = $state(${2:0});$0", "a state")
snippet("svelte", "derived", "const ${1:name} = $derived(${2:value});$0", "a derived value")
snippet("svelte", "effect", "$effect(() => {\n\t$0\n});", "an effect")

# ── the outline, when there is no language server ──

func svelteJs(s: string, st: var int): string =
  ## a line of the script with its comments and strings made spaces (the columns kept) — `st`: 1 inside a
  ## /* comment */, 2 inside a `template` that goes on below
  result = s
  var i = 0
  while i < s.len:
    if st == 1:
      if s.continuesWith("*/", i):
        st = 0
        result[i] = ' '
        result[i + 1] = ' '
        i += 2
      else:
        result[i] = ' '
        inc i
      continue
    if st == 2:
      if s[i] == '\\' and i + 1 < s.len:
        result[i] = ' '
        result[i + 1] = ' '
        i += 2
        continue
      if s[i] == '`': st = 0
      result[i] = ' '
      inc i
      continue
    if s.continuesWith("//", i):
      for k in i ..< s.len: result[k] = ' '
      break
    if s.continuesWith("/*", i):
      st = 1
      result[i] = ' '
      result[i + 1] = ' '
      i += 2
      continue
    if s[i] == '`':
      st = 2
      result[i] = ' '
      inc i
      continue
    if s[i] in {'"', '\''}:
      let q = s[i]
      result[i] = ' '
      inc i
      while i < s.len and s[i] != q:
        if s[i] == '\\' and i + 1 < s.len:
          result[i] = ' '
          inc i
        result[i] = ' '
        inc i
      if i < s.len: result[i] = ' '
    inc i

func svelteNameEnd(s: string, i: int): int =
  ## where the name (letters, digits, `_` and `$`) that starts at `i` ends
  result = i
  while result < s.len and (s[result].isAlphaNumeric or s[result] in {'_', '$'}): inc result

func svelteProps(inner: string): seq[string] =
  ## the names a destructuring gives: `a, b = 1, c: d, ...rest` → a b c rest
  var depth = 0
  var part = ""
  for c in inner & ",":
    if c in {'{', '[', '('}: inc depth
    elif c in {'}', ']', ')'}: dec depth
    if c == ',' and depth == 0:
      var p = part.strip
      if p.startsWith("..."): p = p[3 .. ^1]
      let e = svelteNameEnd(p, 0)
      if e > 0: result.add p[0 ..< e]
      part = ""
    else: part.add c

func svelteSymbols*(lines: seq[string]): seq[Symbol] =
  ## the scripts with their props, state, constants and functions; the {#snippet}s; the style
  var where = 0                        # 0 the markup, 1 a script, 2 the style
  var st = 0
  var inHtmlComment = false
  var level = 0                        # the script's braces open
  var props = ""                       # a `let { … } = $props()` over several lines, so far
  var propsLine = -1
  for ln, s in lines:
    let t = s.strip
    if where == 0:
      if inHtmlComment:
        if "-->" in t: inHtmlComment = false
        continue
      if t.startsWith("<!--"):
        inHtmlComment = "-->" notin t
        continue
      if t.startsWith("<script"):
        let close = t.find('>')
        let attrs = if close > 7: t[7 ..< close].strip else: ""
        result.add Symbol(name: "script", kind: "section", detail: attrs, line: ln, col: s.find("<script") + 1)
        if "</script>" notin t:
          where = 1
          level = 0
          st = 0
      elif t.startsWith("<style"):
        result.add Symbol(name: "style", kind: "section", line: ln, col: s.find("<style") + 1)
        if "</style>" notin t: where = 2
      elif t.startsWith("{#snippet "):
        let a = s.find("{#snippet ") + 10
        let e = svelteNameEnd(s, a)
        if e > a:
          let close = s.find(')', e)
          result.add Symbol(name: s[a ..< e], kind: "function", detail: (if close > e: s[e .. close] else: ""),
                            line: ln, col: a)
      continue
    if where == 2:
      if "</style>" in t: where = 0
      continue
    # the script
    if st == 0 and t.startsWith("</script>"):
      where = 0
      continue
    let code = svelteJs(s, st)
    let c = code.strip
    let col = code.len - code.strip(trailing = false).len
    if propsLine >= 0:
      props.add " " & c
      if '}' in c:
        for n in svelteProps(props[0 ..< props.rfind('}')]):
          result.add Symbol(name: n, kind: "property", detail: "prop", line: propsLine,
                            col: max(0, lines[propsLine].find(n)), depth: 1)
        propsLine = -1
    elif level == 0 and c.len > 0:
      var w = c
      for pre in ["export ", "async "]:
        if w.startsWith(pre): w = w[pre.len .. ^1]
      if w.startsWith("function"):
        let a = w.find(' ') + 1
        let e = svelteNameEnd(w, a)
        if a > 0 and e > a:
          let close = w.find(')', e)
          result.add Symbol(name: w[a ..< e], kind: "function", detail: (if close > e: w[e .. close] else: ""),
                            line: ln, col: max(0, s.find(w[a ..< e], col)), depth: 1)
      elif w.startsWith("const ") or w.startsWith("let ") or w.startsWith("var "):
        let kw = w[0 ..< w.find(' ')]
        var a = kw.len + 1
        while a < w.len and w[a] == ' ': inc a
        if a < w.len and w[a] == '{':
          # let { a, b = 1 } = $props()
          let close = w.find('}', a)
          if close > a:
            if "$props" in w[close .. ^1]:
              for n in svelteProps(w[a + 1 ..< close]):
                result.add Symbol(name: n, kind: "property", detail: "prop", line: ln,
                                  col: max(0, s.find(n, col)), depth: 1)
          else:
            # over several lines: the names up to its }
            props = w[a + 1 .. ^1]
            propsLine = ln
        else:
          let e = svelteNameEnd(w, a)
          if e > a:
            let name = w[a ..< e]
            let value = (let q = w.find('=', e); if q >= 0: w[q + 1 .. ^1].strip else: "")
            var kind = if kw == "const": "constant" else: "variable"
            var detail = kw
            if c.startsWith("export let") or c.startsWith("export var"):
              kind = "property"
              detail = "prop"
            elif value.startsWith("$state"):
              detail = "$state"
            elif value.startsWith("$derived"):
              kind = "constant"
              detail = "$derived"
            elif value.startsWith("function") or value.startsWith("async") or
                 (value.startsWith("(") and ") =>" in value) or
                 (svelteNameEnd(value, 0) > 0 and value[svelteNameEnd(value, 0) .. ^1].strip.startsWith("=>")):
              kind = "function"
              detail = ""
            result.add Symbol(name: name, kind: kind, detail: detail, line: ln, col: max(0, s.find(name, col)),
                              depth: 1)
    for ch in code:
      if ch == '{': inc level
      elif ch == '}': level = max(0, level - 1)

# ── the tools ──

proc svelteHave(cmd: string): bool =
  ## whether the first word of a configured command (with ~ expanded) is a program that can be found on PATH
  let w = cmd.splitWhitespace()
  w.len > 0 and findExe(expandTilde(w[0])).len > 0

let svelteServerSet = setting("server", "").strip
var svelteServer: seq[string]
if svelteServerSet == "off": discard
elif svelteServerSet.len > 0:
  if svelteHave(svelteServerSet): svelteServer = svelteServerSet.splitWhitespace()
  else: echo "svelte: the server " & svelteServerSet & " is not installed (plugins.svelte.server)"
elif findExe("svelteserver").len > 0: svelteServer = @["svelteserver", "--stdio"]
if svelteServer.len > 0:
  svelteServer[0] = expandTilde(svelteServer[0])
  languageServer("svelte", svelteServer)
else:
  symbols("svelte") do (b: Buf) -> seq[Symbol]:
    svelteSymbols(b.lines)

let svelteFmtSet = setting("formatter", "").strip
if svelteFmtSet == "off": discard
elif svelteFmtSet.len > 0:
  if svelteHave(svelteFmtSet): formatter("svelte", svelteFmtSet)
  else: echo "svelte: the formatter " & svelteFmtSet & " is not installed (plugins.svelte.formatter)"
elif findExe("prettier").len > 0:
  # (--stdin-filepath: a .svelte file goes to prettier-plugin-svelte, and its folder has the project's .prettierrc)
  formatter("svelte", "prettier --stdin-filepath \"$file\"")
