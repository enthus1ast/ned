## license-header — the copyright and licence line at the top of a file, in the file's own comments: the licence the
## project's LICENSE file is, the name git knows you by, this year
##
##   License: add the header to this file    `# Copyright (c) 2026 Ada Lovelace` and
##                                    `# SPDX-License-Identifier: MIT` at the top (after a #! line, an XML or
##                                    <!doctype> one), as the file's comments are written (// for C and JS,
##                                    <!-- --> in HTML, /* */ in CSS …). A file that has one already is left alone
##   License: add the header to every file of the project   the same for each source file git knows that has none
##                                    (how many is asked first)
##   License: the files without a header   listed in the Output panel
## The licence: plugins.license-header.license (empty: read from LICENSE, COPYING, LICENSE.md — MIT, Apache-2.0,
## GPL-3.0, LGPL-3.0, AGPL-3.0, GPL-2.0, BSD-3-Clause, BSD-2-Clause, MPL-2.0, ISC, Unlicense, Zlib, BSL-1.0); the
## holder: plugins.license-header.holder (empty: git's user.name).
import nedplugin
import std/[strutils, os]

requiresNed(">= 6.26")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "MIT")
permission("shell", "asks git for your name and for the project's files")
permission("files", "License: add the header to every file — writes the header into each file")

settingDef("license", "", "The SPDX identifier (MIT, Apache-2.0 …): empty to read it from the project's LICENSE")
settingDef("holder", "", "The copyright holder: empty for git's user.name")

const SourceExts = ["nim", "nims", "c", "h", "cpp", "hpp", "cc", "js", "mjs", "ts", "py", "sh", "go", "rs", "java",
                    "kt", "swift", "zig", "lua", "rb", "php", "cs", "css", "scss", "html", "dart", "jl", "ml",
                    "cr", "clj", "ex", "exs", "gleam", "hs", "odin", "sql"]

func licenseOfText*(t: string): string =
  ## the SPDX identifier of a licence's text ("" not known)
  let s = t.toLowerAscii
  if "gnu affero general public license" in s: "AGPL-3.0"
  elif "gnu lesser general public license" in s: "LGPL-3.0"
  elif "gnu general public license" in s and "version 3" in s: "GPL-3.0"
  elif "gnu general public license" in s and "version 2" in s: "GPL-2.0"
  elif "apache license" in s and "version 2.0" in s: "Apache-2.0"
  elif "mozilla public license" in s and "2.0" in s: "MPL-2.0"
  elif "boost software license" in s: "BSL-1.0"
  elif "this is free and unencumbered software released into the public domain" in s: "Unlicense"
  elif "permission to use, copy, modify, and/or distribute this software for any purpose" in s: "ISC"
  elif "this software is provided 'as-is'" in s and "altered source versions must be plainly marked" in s: "Zlib"
  elif "redistribution and use in source and binary forms" in s:
    (if "neither the name" in s or "contributors may be used" in s: "BSD-3-Clause" else: "BSD-2-Clause")
  elif "permission is hereby granted, free of charge" in s: "MIT"
  else: ""

proc projectLicense(): string =
  result = setting("license", "").strip
  if result.len > 0: return
  let root = projectRoot()
  for n in ["LICENSE", "LICENSE.md", "LICENSE.txt", "COPYING", "COPYING.md", "LICENCE", "license"]:
    let p = root / n
    if fileExists(p):
      result = licenseOfText(readFile(p))
      if result.len > 0: return

proc holder(): string =
  result = setting("holder", "").strip
  if result.len == 0: result = shell("git config user.name").output.strip

func commentFor*(lang, ext, lineComment: string): (string, string) =
  ## how the file writes a comment: (its start, its end — "" for a line comment)
  case lang
  of "html", "xml", "markdown", "vue", "svelte": ("<!--", "-->")
  of "css", "scss", "less": ("/*", "*/")
  else:
    case ext
    of "html", "htm", "xml", "svg", "md": ("<!--", "-->")
    of "css", "scss", "less": ("/*", "*/")
    of "ml", "mli": ("(*", "*)")
    else: ((if lineComment.len > 0: lineComment else: "#"), "")

func headerLines*(c: (string, string), year, who, spdx: string): seq[string] =
  let (a, e) = c
  let lines = @["Copyright (c) " & year & (if who.len > 0: " " & who else: ""),
                "SPDX-License-Identifier: " & spdx]
  if e.len == 0:
    for l in lines: result.add a & " " & l
  else:
    result.add a & " " & lines[0]
    result.add(spaces(if a == "<!--": 5 else: 3) & lines[1] & " " & e)

func hasHeader*(lines: seq[string]): bool =
  for i in 0 ..< min(lines.len, 12):
    if "SPDX-License-Identifier" in lines[i] or ("Copyright" in lines[i] and ("(c)" in lines[i] or "©" in lines[i])):
      return true

func insertAt*(lines: seq[string]): int =
  ## where the header goes: after a #! line, an <?xml …?> or <!doctype> line, a Python coding line
  var i = 0
  while i < lines.len and i < 3:
    let t = lines[i].strip.toLowerAscii
    if t.startsWith("#!") or t.startsWith("<?xml") or t.startsWith("<!doctype") or
       (t.startsWith("#") and "coding" in t and ("-*-" in t or "coding:" in t)):
      inc i
    else: break
  i

proc headerFor(lang, path, lineComment: string): seq[string] =
  let spdx = projectLicense()
  if spdx.len == 0: return
  let ext = path.splitFile.ext.strip(chars = {'.'}).toLowerAscii
  headerLines(commentFor(lang, ext, lineComment), localTime()[0 ..< 4], holder(), spdx)

proc addHere() =
  let b = current()
  if hasHeader(b.lines):
    message("This file has a header already")
    return
  let h = headerFor(b.lang, b.path, b.lineComment)
  if h.len == 0:
    warn("Which licence? Set plugins.license-header.license (MIT, Apache-2.0 …) — no LICENSE file says it")
    return
  let at = insertAt(b.lines)
  let blank = at < b.lineCount and b.line(at).strip.len > 0
  b.insert(pos(at, 0), h.join("\n") & "\n" & (if blank: "\n" else: ""))
  message("Header added: " & h[^1].strip)

proc sourceFiles(): seq[string] =
  let r = shell("git ls-files")
  if r.code != 0: return
  for l in r.output.splitLines:
    let f = l.strip
    let ext = f.splitFile.ext.strip(chars = {'.'}).toLowerAscii
    if ext in SourceExts and not f.startsWith("vendor/") and "/vendor/" notin f and "node_modules" notin f:
      result.add f

func langOfExt(ext: string): (string, string) =
  ## (a language id, its line comment) by extension, for files that are not open
  case ext
  of "c", "h", "cpp", "hpp", "cc", "js", "mjs", "ts", "go", "rs", "java", "kt", "swift", "zig", "cs", "dart", "php",
     "scss", "odin", "gleam": ("", "//")
  of "lua", "hs", "sql": ("", "--")
  of "clj": ("", ";;")
  of "css": ("css", "")
  of "html": ("html", "")
  else: ("", "#")

proc missing(): seq[string] =
  let root = projectRoot()
  for f in sourceFiles():
    try:
      if not hasHeader(readFile(root / f).splitLines): result.add f
    except IOError: discard

proc addEverywhere() =
  if projectLicense().len == 0:
    warn("Which licence? Set plugins.license-header.license — no LICENSE file says it")
    return
  let todo = missing()
  if todo.len == 0:
    message("Every source file has a header")
    return
  if not confirm("Add the header to " & $todo.len & (if todo.len == 1: " file?" else: " files?")): return
  let root = projectRoot()
  var n = 0
  for f in todo:
    let p = root / f
    let ext = f.splitFile.ext.strip(chars = {'.'}).toLowerAscii
    let (lang, lc) = langOfExt(ext)
    let h = headerFor(lang, p, lc)
    var ls = readFile(p).splitLines
    let at = insertAt(ls)
    var ins = h
    if at < ls.len and ls[at].strip.len > 0: ins.add ""
    ls = ls[0 ..< at] & ins & ls[at .. ^1]
    writeFile(p, ls.join("\n"))
    inc n
  message("Header added to " & $n & (if n == 1: " file" else: " files"))

command "License: add the header to this file":
  addHere()

command "License: add the header to every file of the project":
  addEverywhere()

command "License: the files without a header":
  let m = missing()
  output("Files without a licence header (" & $m.len & "):\n" & m.join("\n") & "\n")
  showOutput()
  message($m.len & (if m.len == 1: " file has" else: " files have") & " no header")
