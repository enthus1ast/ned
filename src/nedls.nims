# Compile settings for src/nedls.nim — picked up by `nim c src/nedls.nim`: ned's editor code without its main,
# built the way ned is (ned.nims).

switch("define", "nedNoMain")

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

switch("mm", "orc")
