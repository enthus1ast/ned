# Nim tour · 14 of 16 · The standard library
# notebook: compiled
#
# Nim comes with a large standard library: text, collections, files and paths, times, JSON, maths, the network,
# processes. Each part is a module you `import` (std/strutils …). This lesson is a quick walk through the ones
# used most; Nim › Documentation › Standard library docs in ned has them all, and Ctrl+Space after a dot lists
# what a value can do.

# %% Text: std/strutils
import std/strutils
let line = "  Nim is fast, Nim is fun  "
echo line.strip, "|", line.strip.toUpperAscii
echo line.strip.split(", "), " ", "a-b-c".split('-').join("+")
echo line.count("Nim"), " ", line.contains("fun"), " ", "nimble".startsWith("nim"), " ", "x".repeat(3)
echo "3.5".parseFloat * 2, " ", "Ada".align(6), "|", "Ada".alignLeft(6), "|", "nim".replace("n", "N")
#> Nim is fast, Nim is fun|NIM IS FAST, NIM IS FUN
#> @["Nim is fast", "Nim is fun"] a+b+c
#> 2 true true xxx
#> 7.0    Ada|Ada   |Nim

# %% Formatting: std/strformat
# `fmt"…"` (or `&"…"`) puts values into a string where `{name}` stands; after a colon, how to show it.
import std/strformat
let item = "tea"
let cost = 3.14159
let qty = 7
echo fmt"{item} costs {cost:.2f}, {qty} of them {cost * float(qty):.1f}"
echo fmt"[{item:>6}] [{item:<6}] [{qty:03}] [{255:x}]"
#> tea costs 3.14, 7 of them 22.0
#> [   tea] [tea   ] [007] [ff]

# %% Sequences: std/sequtils
# `map`, `filter` and `foldl` take a proc; the `…It` forms take an expression with `it` in it.
import std/sequtils
let nums = @[3, 1, 4, 1, 5, 9, 2, 6]
echo nums.filterIt(it > 3), " ", nums.mapIt(it * 10)[0 .. 2], " ", nums.foldl(a + b)
echo nums.anyIt(it > 8), " ", nums.allIt(it > 0), " ", nums.deduplicate, " ", nums.countIt(it == 1)
echo zip(@["a", "b"], @[1, 2]), " ", toSeq(1 .. 4).map(proc (x: int): int = x * x)
#> @[4, 5, 9, 6] @[30, 10, 40] 31
#> true true @[3, 1, 4, 5, 9, 2, 6] 2
#> @[("a", 1), ("b", 2)] @[1, 4, 9, 16]

# %% Sorting: std/algorithm
import std/algorithm
var ws = @["pear", "fig", "banana", "kiwi"]
ws.sort()
echo ws, " ", ws.reversed, " ", ws.sortedByIt(it.len)
echo ws.sorted(proc (a, b: string): int = cmp(a.len, b.len), SortOrder.Descending), " ", ws.binarySearch("kiwi")
#> @["banana", "fig", "kiwi", "pear"] @["pear", "kiwi", "fig", "banana"] @["fig", "kiwi", "pear", "banana"]
#> @["banana", "kiwi", "pear", "fig"] 2

# %% Tables: std/tables
# A Table maps keys to values (a hash table). An OrderedTable remembers the order of insertion; a CountTable counts.
import std/tables
var stock = {"apples": 3, "pears": 0}.toOrderedTable
stock["figs"] = 12
stock["apples"] += 2
echo stock, " ", stock.getOrDefault("plums", -1), " ", "pears" in stock
for name, n in stock:
  if n > 0: echo "  ", name, ": ", n
let letters = toCountTable("mississippi")
echo letters.largest, " ", letters['p']
#> {"apples": 5, "pears": 0, "figs": 12} -1 true
#>   apples: 5
#>   figs: 12
#> (key: 'i', val: 4) 2

# %% Sets of anything: std/sets
import std/sets
let mine = toHashSet(["vim", "ned", "nano"])
let yours = toHashSet(["ned", "emacs"])
echo mine.len, " ", "ned" in mine, " ", mine * yours, " ", (mine - yours).len
#> 3 true {"ned"} 2

# %% Maths: std/math
import std/math
echo sqrt(2.0).round(3), " ", 2 ^ 10, " ", floorDiv(-7, 2), " ", [1.0, 2.0, 4.5].sum, " ", PI.round(5)
echo gcd(12, 18), " ", lcm(4, 6), " ", isPowerOfTwo(64), " ", hypot(3.0, 4.0), " ", 10.0.log10
#> 1.414 1024 -4 7.5 3.14159
#> 6 12 true 5.0 1.0

# %% Dates and times: std/times
# A DateTime is a moment on a calendar; a Duration a length of time. `parse` and `format` take a pattern.
import std/times
let launch = parse("2026-10-26 09:30", "yyyy-MM-dd HH:mm", utc())
let later = launch + 3.days + 2.hours
echo later.format("dddd d MMMM yyyy, HH:mm"), " ", later.weekday, " ", (later - launch).inHours, " h"
#> Thursday 29 October 2026, 11:30 Thursday 74 h

# %% JSON: std/json
# `parseJson` reads JSON; `%*` builds it from Nim values; `to` turns it into an object of yours.
import std/json
let doc = parseJson("""{"name": "ned", "version": [6, 32], "nim": true}""")
echo doc["name"].getStr, " ", doc["version"][1].getInt, " ", doc{"missing"}.getStr("none")
type Release = object
  name: string
  version: seq[int]
let rel = doc.to(Release)
echo rel.name, " ", rel.version, " ", $(%*{"ok": rel.version.len == 2, "list": [1, 2]})
#> ned 32 none
#> ned @[6, 32] {"ok":true,"list":[1,2]}

# %% Paths and files: std/os and std/paths
# Joining and taking apart paths needs no file at all (on Windows, `/` joins with \). readFile, writeFile, walkDir
# and fileExists read and write real files; std/osproc runs programs.
import std/os
let p = "/home/ada" / "notes" / "todo.txt"
let (dir, name, ext) = splitFile(p)
echo p, " · ", dir, " · ", name, " · ", ext, " · ", p.extractFilename, " · ", p.changeFileExt("md")
#> /home/ada/notes/todo.txt · /home/ada/notes · todo · .txt · todo.txt · /home/ada/notes/todo.md

# %% Exercise: the most common word
# Write `topWord`: the word that comes most often in a text, in lower case. Split the text into words, count them
# in a CountTable and take the largest — the modules above have everything it needs.
proc topWord(text: string): string =
  ""
# Check:
let w1 = topWord("The cat and the hat and THE bat")
let w2 = topWord("one two two three three three")
if w1 == "the" and w2 == "three": echo "✓ topWord works"
else: echo "not yet: topWord gives \"", w1, "\" and \"", w2, "\", not \"the\" and \"three\""
# Answer:
  # proc topWord(text: string): string =
  #   let counts = toCountTable(text.toLowerAscii.splitWhitespace)
  #   counts.largest.key
