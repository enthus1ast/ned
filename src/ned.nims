# Compile settings for src/ned.nim — picked up automatically by `nim c src/ned.nim` and by nimble.
# ned uses only the standard library; these just make release builds as fast as they can be.

when defined(release) or defined(danger):
  switch("opt", "speed")
  switch("stackTrace", "off")
  switch("lineTrace", "off")

# ORC is Nim 2's default memory manager; stated here so older configs cannot change it
switch("mm", "orc")
