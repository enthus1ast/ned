# Package

version       = "6.1.0"
author        = "Foxoman"
description   = "Fast, safe terminal code editor and Nim IDE for Termux and Linux: desktop-style UI, " &
                "a built-in Nim engine (completion with docs, no language server needed) and nph-style formatter, " &
                "AI agent, split editor, " &
                "integrated terminal, vim mode"
license       = "MIT"
srcDir        = "src"
bin           = @["ned"]
installExt    = @["nim"]          # the sources too: `import ned/nim/index` from other programs
skipDirs      = @["tests", "screenshots"]

# Dependencies — none besides the compiler: ned uses only the standard library

requires "nim >= 2.2.0"

# Tasks
#   nimble release        optimised binary ./ned
#   nimble termux         build straight into $PREFIX/bin (Termux)
#   nimble local          build into ~/.local/bin
#   nimble debug          debug build with stack traces and line info
#   nimble typecheck      type-check only (fast)
#   nimble android        cross-check that ned compiles for Android/arm64 (no toolchain needed)
#   nimble test           the unit tests: the Nim index, the formatters, the regular expressions
#   nimble uitest         the whole editor driven through tmux (tests/ui — needs tmux and python3)
#   nimble bench          render a large file off-screen and print frame timings
#   nimble perf           startup time, memory and frame times against the CI budget (needs python3)
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

task termux, "Build into $PREFIX/bin/ned (Termux)":
  let prefix = getEnv("PREFIX")
  if prefix.len == 0:
    echo "PREFIX is not set — this task is meant for Termux; use `nimble release` or `nimble local`"
  else:
    exec "nim c " & flags & " -o:" & prefix & "/bin/ned " & main

task local, "Build into ~/.local/bin/ned":
  let dir = getEnv("HOME") & "/.local/bin"
  mkDir dir
  exec "nim c " & flags & " -o:" & dir & "/ned " & main
  echo "Make sure ", dir, " is on your PATH"

task debug, "Debug build with stack traces (./ned_debug)":
  exec "nim c -d:debug --stackTrace:on --lineTrace:on --hints:off -o:ned_debug " & main

task typecheck, "Type-check ned without building":
  exec "nim check --hints:off " & main

task android, "Check that ned compiles for Android (arm64) — generates C only":
  exec "nim c --os:android --cpu:arm64 -d:release --compileOnly --hints:off --nimcache:" &
       tmpDir() & "ned_android " & main

task test, "Unit tests: the Nim index, the formatters, the regular expressions":
  for t in ["tests/unit/tindex.nim", "tests/unit/tformat.nim", "tests/unit/tregex.nim"]:
    exec "nim r -d:release --hints:off " & t

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

task perf, "Startup time, memory and frame times, checked against .github/ci/bench-budget.json":
  exec "nim c " & flags & " -o:ned " & main
  exec "python3 .github/ci/bench.py ./ned"

task smoke, "Build and run the non-interactive checks":
  exec "nim c " & flags & " -o:ned " & main
  exec "./ned --version"
  exec "./ned --help > /dev/null"
  exec "./ned --default-settings > " & tmpDir() & "ned_defaults.jsonc"
  echo "ok: ned builds, starts and writes its default settings"

task tools, "Install the optional companions (nimlangserver, nph, inim)":
  exec "nimble install -y nimlangserver nph inim"
