import std/strutils

proc shout*(s: string): string =
  ## upper-case and add a bang
  s.toUpperAscii & "!"

proc twice*(x: int): int = x * 2
