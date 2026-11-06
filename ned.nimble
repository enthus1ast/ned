# Package

version       = "6.41.1"
author        = "Sultan Al Isaiee (@foxoman) <sultan@foxoman.net>"
description   = "Fast, safe terminal code editor and Nim IDE for Termux and Linux: desktop-style UI, " &
                "a built-in Nim engine (completion with docs, no language server needed) and nph-style formatter, " &
                "AI agent, split editor, " &
                "integrated terminal, vim mode"
license       = "GPL-3.0-or-later"
srcDir        = "src"
bin           = @["ned", "nedfmt", "nedls"]   # nedfmt: the formatters as a command · nedls: the engine as a language server
installExt    = @["nim"]          # the sources too: `import ned/nim/index` from other programs
skipDirs      = @["tests", "screenshots"]

# Dependencies — none besides the compiler: ned uses only the standard library

requires "nim >= 2.2.0"

# Tasks
#   nimble release        optimised binary ./ned
#   nimble nedfmt         ./nedfmt: ned's formatters from the shell, CI and git hooks (nph's options)
#   nimble nedls          ./nedls: ned's Nim engine as a language server for other editors
#   nimble termux         build straight into $PREFIX/bin (Termux)
#   nimble termuxdeb      the Termux package (.deb), cross-built with zig
#   nimble windowszip     the Windows zip (ned.exe, nedfmt.exe, nedls.exe), cross-built with zig
#   nimble local          build into ~/.local/bin
#   nimble debug          debug build with stack traces and line info
#   nimble typecheck      type-check only (fast)
#   nimble android        cross-check that ned compiles for Android/arm64 (no toolchain needed)
#   nimble test           the unit tests: the Nim index, the formatters, the regular expressions
#   nimble lsptest        nedls driven by a test LSP client (every feature, random edits)
#   nimble parsecheck     the Nim formatter checked by Nim's own parser on 463 files of Nim itself
#   nimble uitest         the whole editor driven through tmux (tests/ui — needs tmux and python3)
#   nimble bench          render a large file off-screen and print frame timings
#   nimble perf           startup time, memory, frame times and the longest waits on a big program, against
#                         their budgets (needs python3)
#   nimble smoke          build, then run the non-interactive self checks
#   nimble tools          install the optional companions: inim (and nph, nimlangserver, if you want them)

const
  flags = "-d:release --opt:speed -d:strip --hints:off"
  main = "src/ned.nim"

proc tmpDir(): string =
  result = getEnv("TMPDIR")
  if result.len == 0: result = "/tmp"
  if not result.endsWith("/"): result.add "/"

task release, "Build an optimised ./ned":
  exec "nim c " & flags & " -o:ned " & main

task nedfmt, "Build ./nedfmt: ned's formatters as a command of their own (nph's options, a pre-commit hook)":
  exec "nim c " & flags & " -o:nedfmt src/nedfmt.nim"

task nedls, "Build ./nedls: ned's Nim engine as a language server (VS Code, Neovim, Helix, Zed, Emacs, Kate …)":
  exec "nim c " & flags & " -o:nedls src/nedls.nim"

task termux, "Build into $PREFIX/bin: ned, nedfmt and nedls (Termux)":
  let prefix = getEnv("PREFIX")
  if prefix.len == 0:
    echo "PREFIX is not set — this task is meant for Termux; use `nimble release` or `nimble local`"
  else:
    exec "nim c " & flags & " -o:" & prefix & "/bin/ned " & main
    exec "nim c " & flags & " -o:" & prefix & "/bin/nedfmt src/nedfmt.nim"
    exec "nim c " & flags & " -o:" & prefix & "/bin/nedls src/nedls.nim"

task termuxdeb, "Cross-build ned, nedls and nedfmt for Termux (Android arm64, with zig) and make the .deb (build/termux/)":
  exec "bash tests/build/termux.sh"

task windowszip, "Cross-build ned, nedfmt and nedls for Windows (x86_64, with zig) and make the zip (build/windows/)":
  exec "bash tests/build/windows.sh"

task local, "Build into ~/.local/bin: ned, nedfmt and nedls":
  let dir = getEnv("HOME") & "/.local/bin"
  mkDir dir
  exec "nim c " & flags & " -o:" & dir & "/ned " & main
  exec "nim c " & flags & " -o:" & dir & "/nedfmt src/nedfmt.nim"
  exec "nim c " & flags & " -o:" & dir & "/nedls src/nedls.nim"
  echo "Make sure ", dir, " is on your PATH"

task debug, "Debug build with stack traces (./ned_debug)":
  exec "nim c -d:debug --stackTrace:on --lineTrace:on --hints:off -o:ned_debug " & main

task typecheck, "Type-check ned without building":
  exec "nim check --hints:off " & main

task android, "Check that ned compiles for Android (arm64) — generates C only":
  exec "nim c --os:android --cpu:arm64 -d:release --compileOnly --hints:off --nimcache:" &
       tmpDir() & "ned_android " & main

import std/[algorithm, strutils, os]

task test, "Unit tests: every tests/unit/t*.nim — the Nim index, the C index and its Nim bindings, the formatters (and nedfmt), the regular expressions, ARC/ORC copies, the JSON / JS / CSS / HTML / SQL engines, NIF, text encodings":
  var ts: seq[string]
  for f in listFiles("tests/unit"):
    let n = f.extractFilename
    if n.startsWith("t") and n.endsWith(".nim"): ts.add f
  ts.sort()
  for t in ts:
    exec "nim r -d:release --hints:off " & t

task lsptest, "nedls driven by a test client: every feature, and 2000 random edits (needs python3)":
  exec "nim c " & flags & " -o:nedls src/nedls.nim"
  exec "python3 tests/lsp/tnedls.py ./nedls"

task plugintest, "The plugins' host (nim e and compiled) with the example plugins, the API, a NimScript language server through ned --lsp-bridge (needs python3)":
  exec "nim c " & flags & " -o:ned " & main
  exec "python3 tests/plugins/tplugins.py ./ned --native"

task parsecheck, "The Nim formatter checked by Nim's own parser over the compiler and stdlib (needs their sources)":
  exec "sh tests/format/parsecheck.sh"

task uitest, "The editor driven through tmux, every feature (tests/ui; needs tmux and python3)":
  exec "nim c " & flags & " -o:ned " & main
  exec "python3 tests/ui/run.py ./ned"

task bench, "Render frames of a big generated file off-screen and print timings":
  exec "nim c " & flags & " -o:ned " & main
  let big = tmpDir() & "ned_bench.nim"
  var s = ""
  for i in 0 ..< 200_000:
    s.add "proc p" & $i & "*(x: int): int = x * " & $i & "  # line " & $i & "\n"
  writeFile(big, s)
  exec "./ned --bench " & big & " > /dev/null"

task perf, "Startup time, memory, frame times, and the longest waits while working on a big program (Linux), checked against their budgets":
  exec "nim c " & flags & " -o:ned " & main
  exec "python3 .github/ci/bench.py ./ned"
  # ned's own source opened as a project: open, scroll, type, completions, an import added, another program —
  # the longest moment each step kept you waiting, the completion times, editor + engine worker memory
  # (tests/perf/budget.json)
  if defined(linux): exec "python3 tests/perf/rounds.py ./ned"

task smoke, "Build and run the non-interactive checks":
  exec "nim c " & flags & " -o:ned " & main
  exec "./ned --version"
  exec "./ned --help > /dev/null"
  exec "./ned --default-settings > " & tmpDir() & "ned_defaults.jsonc"
  echo "ok: ned builds, starts and writes its default settings"

task tools, "Install the optional companions (nimlangserver, nph, inim)":
  exec "nimble install -y nimlangserver nph inim"
