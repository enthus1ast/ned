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

# on Linux and macOS, the system's memory allocator, not Nim's own: Nim's never gives memory back to the system once it
# has it — after a big file, or a long session, ned held three times what it used — and src/ned/sys/heap.nim gives
# back what is no longer used (with a 7 MB file open: 35 MB, 22 once it is closed; on Nim's: 69, and it stays). The
# cost: formatting a whole big file takes 20% longer; completion as fast. On Android (Termux: musl in the package,
# bionic when built there) and Windows, Nim's: musl's allocator kept 50 MB with that file (Nim's 65), more than Nim's
# after a session, and took 15-40% longer. -d:nedNimAlloc: Nim's everywhere; -d:useMalloc: the system's everywhere
if not defined(nedNimAlloc) and not defined(android) and not defined(windows): switch("define", "useMalloc")
