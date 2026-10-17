# Compile settings for src/ned.nim — picked up automatically by `nim c src/ned.nim` and by nimble.
# ned uses only the standard library; these just make release builds as fast as they can be.

when defined(release) or defined(danger):
  switch("opt", "speed")
  switch("stackTrace", "off")
  switch("lineTrace", "off")
  # -d:lto: link-time optimisation — 5-10% less time in the engine and the formatter, a 7% smaller binary, 1.5 MB
  # less memory at start (measured), for a build that takes about twice as long. The release binaries are built
  # with it; gcc, or clang with a linker that does LTO (lld, Apple's)
  if defined(lto):
    put("gcc.options.speed", get("gcc.options.speed") & " -flto")
    put("gcc.options.linker", get("gcc.options.linker") & " -flto=auto -w")
    put("clang.options.speed", get("clang.options.speed") & " -flto")
    put("clang.options.linker", get("clang.options.linker") & " -flto -w")

# ORC is Nim 2's default memory manager; stated here so older configs cannot change it
switch("mm", "orc")
