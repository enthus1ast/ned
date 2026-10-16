import std/strformat

{.emit: """
#include <stdio.h>
#include <string.h>

static int vowels(const char *s) {
  int n = 0;
  for (; *s; s++)
    if (strchr("aeiou", *s)) n++;
  return n
}

static void shout(const char *s) {

}
""".}

proc vowels(s: cstring): cint {.importc, nodecl.}
proc shout(s: cstring) {.importc, nodecl.}

echo &"{vowels(\"emit\")} vowels"
