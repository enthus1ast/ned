# Compile settings for src/nedls.nim — picked up by `nim c src/nedls.nim`: ned's editor code without its main,
# built the way ned is (ned.nims).

switch("define", "nedNoMain")

when defined(release) or defined(danger):
  switch("opt", "speed")
  switch("stackTrace", "off")
  switch("lineTrace", "off")

switch("mm", "orc")
