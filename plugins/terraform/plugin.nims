## terraform — Terraform and HCL: colours, comments, indentation, F5, snippets, an outline; terraform-ls, terraform fmt
##
## Turn it on in the Plugins dock (AVAILABLE). It teaches ned three languages that share HCL's syntax: Terraform's
## `.tf` files, its variables' `.tfvars` files (a language of their own, so that terraform-ls reads them as such),
## and other `.hcl` files (Terragrunt's, Packer's, Nomad's …). Their colours (ned's generic lexer with Terraform's
## words: resource, data, variable, output, locals, module …, its types, its functions, names with - in them), `#`,
## `//` and `/* … */` comments, indentation after `{` `(` `[`, two spaces as terraform fmt writes, brackets and
## quotes that close themselves, snippets in .tf files (resource, data, variable, output, module, locals, provider)
## and F5: `terraform plan` in the file's folder (a module is a folder) — with `-var-file=file` for a .tfvars.
## Build (Alt+B) is `terraform validate`.
##
## Without a language server — and always for .hcl files — the outline lists the file's blocks by their labels
## (`aws_instance.web`, `var` region …, a locals block with its values under it) and its top-level attributes, from
## a simple scan.
##
## The tools, when they are on PATH (https://developer.hashicorp.com/terraform/install; OpenTofu's tofu works too:
## set the formatter to `tofu fmt -`): terraform-ls, Terraform's language server (`terraform-ls serve`) for .tf
## and .tfvars files — completion, hover, go to definition, problems; `terraform fmt -` formats all three
## (Format document, and on save with editor.formatOnSave). ned starts one terraform-ls for .tf files and one for
## .tfvars files.
##
## Settings (the Plugins dock › terraform › its settings; Plugins: reload after a change):
## - plugins.terraform.server — the language server's command, when it is not `terraform-ls serve` ("off": none)
## - plugins.terraform.formatter — the formatter's command (the text on its stdin), when it is not `terraform fmt -`
import nedplugin
import std/strutils

requiresNed(">= 6.28")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")

settingDef("server", "", "The language server's command for .tf and .tfvars files: empty for terraform-ls serve " &
           "(when it is installed), \"off\" for none. Plugins: reload after a change")
settingDef("formatter", "", "The formatter's command, which reads the text on its stdin: empty for terraform fmt - " &
           "(when terraform is installed), \"off\" for none. Plugins: reload after a change")

proc tfSpec(name: string, exts: seq[string], run, build: string): LangSpec =
  LangSpec(
    name: name,
    extensions: exts,
    lineComment: "#",
    blockComment: @["/*", "*/"],
    quotes: "\"",
    nameChars: "-",
    keywords: @["resource", "data", "variable", "output", "locals", "module", "provider", "terraform", "moved",
                "import", "removed", "check", "dynamic", "lifecycle", "backend", "required_providers",
                "provisioner", "connection", "content", "for", "in", "if", "else", "endif", "endfor", "for_each",
                "count", "depends_on"],
    types: @["string", "number", "bool", "list", "map", "set", "object", "tuple", "any"],
    constants: @["true", "false", "null"],
    builtins: @["file", "templatefile", "lookup", "merge", "concat", "length", "element", "format", "join",
                "split", "jsonencode", "jsondecode", "yamlencode", "toset", "tolist", "tomap", "try", "can",
                "coalesce", "cidrsubnet", "replace", "keys", "values", "flatten", "contains"],
    indentAfter: @["{", "(", "["],
    dedent: "})]",
    indentSize: 2,
    run: run,
    build: build,
    pairs: "()[]{}\"\"")

language("terraform", tfSpec("Terraform", @["tf"], "terraform plan", "terraform validate"))
language("terraform-vars", tfSpec("Terraform variables", @["tfvars"], "terraform plan -var-file=\"$file\"",
                                  "terraform validate"))
language("hcl", tfSpec("HCL", @["hcl"], "", ""))

# (no ${…} in these: a snippet takes it for a placeholder)
snippet("terraform", "resource", "resource \"${1:type}\" \"${2:name}\" {\n\t$0\n}", "a resource")
snippet("terraform", "data", "data \"${1:type}\" \"${2:name}\" {\n\t$0\n}", "a data source")
snippet("terraform", "variable", "variable \"${1:name}\" {\n\ttype        = ${2:string}\n" &
        "\tdescription = \"${3:what it is}\"\n$0}", "a variable")
snippet("terraform", "output", "output \"${1:name}\" {\n\tvalue = ${2:value}\n$0}", "an output")
snippet("terraform", "module", "module \"${1:name}\" {\n\tsource = \"${2:./modules/name}\"\n\t$0\n}", "a module")
snippet("terraform", "locals", "locals {\n\t${1:name} = ${2:value}$0\n}", "local values")
snippet("terraform", "provider", "provider \"${1:aws}\" {\n\t$0\n}", "a provider")

# ── the outline ──

func tfCode(s: string, st: var int, heredoc: var string): string =
  ## the line with its comments and strings made spaces (the columns kept) — `st`: 1 inside a /* comment */ that
  ## goes on below; `heredoc`: the word that ends the <<EOF text the line is in ("" none)
  result = s
  if heredoc.len > 0:
    if s.strip == heredoc: heredoc = ""
    for k in 0 ..< s.len: result[k] = ' '
    return
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
    if s[i] == '#' or s.continuesWith("//", i):
      for k in i ..< s.len: result[k] = ' '
      break
    if s.continuesWith("/*", i):
      st = 1
      result[i] = ' '
      result[i + 1] = ' '
      i += 2
      continue
    if s.continuesWith("<<", i):
      # <<EOF or <<-EOF: the lines below, up to EOF alone on its line, are text
      var k = i + 2
      if k < s.len and s[k] == '-': inc k
      var e = k
      while e < s.len and (s[e].isAlphaNumeric or s[e] == '_'): inc e
      if e > k:
        heredoc = s[k ..< e]
        for j in i ..< s.len: result[j] = ' '
        break
    if s[i] == '"':
      # a string, its ${…} parts with their own strings in them
      result[i] = ' '
      inc i
      var interp = 0
      while i < s.len:
        if interp == 0 and s[i] == '"': break
        if s[i] == '\\' and i + 1 < s.len:
          result[i] = ' '
          inc i
        elif s.continuesWith("${", i) or s.continuesWith("%{", i):
          inc interp
          result[i] = ' '
          inc i
        elif interp > 0 and s[i] == '}': dec interp
        elif interp > 0 and s[i] == '"':
          # a string inside ${…}
          result[i] = ' '
          inc i
          while i < s.len and s[i] != '"':
            result[i] = ' '
            inc i
        if i < s.len: result[i] = ' '
        inc i
      if i < s.len: result[i] = ' '
    inc i

func tfNameEnd(s: string, i: int): int =
  result = i
  while result < s.len and (s[result].isAlphaNumeric or s[result] in {'_', '-'}): inc result

func tfSymbols*(lines: seq[string]): seq[Symbol] =
  ## the top-level blocks (by their labels) and attributes; a locals block's values under it
  var st = 0
  var heredoc = ""
  var level = 0
  var localsAt = -1                    # the level of the locals block's values (-1: not in one)
  for ln, s in lines:
    let code = tfCode(s, st, heredoc)
    let t = code.strip
    if t.len > 0:
      let col = code.len - code.strip(trailing = false).len
      let e = tfNameEnd(code, col)
      if e > col and (level == 0 or level == localsAt):
        let word = code[col ..< e]
        var k = e
        while k < code.len and code[k] == ' ': inc k
        if k < code.len and code[k] == '=' and (k + 1 >= code.len or code[k + 1] != '='):
          if level == 0:
            result.add Symbol(name: word, kind: "variable", line: ln, col: col)
          else:
            result.add Symbol(name: word, kind: "constant", detail: "local", line: ln, col: col, depth: 1)
        elif level == 0:
          # a block: its type, then its labels ("quoted" or bare) up to its {
          var labels: seq[string]
          var isBlock = false
          k = e                        # (from the raw line: the code has its "labels" made spaces)
          while k < s.len:
            if s[k] == ' ':
              inc k
            elif s[k] == '"':
              let q = s.find('"', k + 1)
              if q < 0: break
              labels.add s[k + 1 ..< q]
              k = q + 1
            elif s[k] == '{':
              isBlock = true
              break
            else:
              let le = tfNameEnd(s, k)
              if le == k: break
              labels.add s[k ..< le]
              k = le
          if isBlock:
            let kind = case word
                       of "resource", "data": "struct"
                       of "variable": "variable"
                       of "output": "property"
                       of "module", "provider": "module"
                       else: (if labels.len > 0: "struct" else: "section")
            let name = if labels.len > 0: labels.join(".") else: word
            let at = if labels.len > 0: max(0, s.find(labels[0], e)) else: col
            result.add Symbol(name: name, kind: kind, detail: word, line: ln, col: at)
            if word == "locals": localsAt = 1
    for c in code:
      if c in {'{', '[', '('}: inc level
      elif c in {'}', ']', ')'}:
        level = max(0, level - 1)
        if level < localsAt: localsAt = -1

# ── the tools ──

proc tfHave(cmd: string): bool =
  let w = cmd.splitWhitespace()
  w.len > 0 and findExe(expandTilde(w[0])).len > 0

let tfServerSet = setting("server", "").strip
var tfServer: seq[string]
if tfServerSet == "off": discard
elif tfServerSet.len > 0:
  if tfHave(tfServerSet): tfServer = tfServerSet.splitWhitespace()
  else: echo "terraform: the server " & tfServerSet & " is not installed (plugins.terraform.server)"
elif findExe("terraform-ls").len > 0: tfServer = @["terraform-ls", "serve"]
if tfServer.len > 0:
  tfServer[0] = expandTilde(tfServer[0])
  languageServer("terraform", tfServer)
  languageServer("terraform-vars", tfServer)
else:
  symbols("terraform") do (b: Buf) -> seq[Symbol]:
    tfSymbols(b.lines)
  symbols("terraform-vars") do (b: Buf) -> seq[Symbol]:
    tfSymbols(b.lines)
symbols("hcl") do (b: Buf) -> seq[Symbol]:
  tfSymbols(b.lines)

let tfFmtSet = setting("formatter", "").strip
var tfFmt = ""
if tfFmtSet == "off": discard
elif tfFmtSet.len > 0:
  if tfHave(tfFmtSet): tfFmt = tfFmtSet
  else: echo "terraform: the formatter " & tfFmtSet & " is not installed (plugins.terraform.formatter)"
elif findExe("terraform").len > 0: tfFmt = "terraform fmt -"
if tfFmt.len > 0:
  for lang in ["terraform", "terraform-vars", "hcl"]: formatter(lang, tfFmt)
