# the hex editor's reading of executables: Nim's names back from C's, and a program Nim built read as ELF —
# its sections, its symbols with their place in the file, Nim's modules by size

import std/[os, osproc, strutils, unittest]
import ../../src/ned/editor/binfmt

suite "Nim's names":
  test "Nim 2: <name>__<module>_u<n>, operators and hooks":
    check nimDemangle("shout__it_u6") == ("shout", "it")
    check nimDemangle("plus___it_u12") == ("+", "it")
    check nimDemangle("dollar___systemZdollars_u14") == ("$", "system/dollars")
    check nimDemangle("eqdestroy___it_u167") == ("=destroy", "it")
    check nimDemangle("fooBar_baz__it_u36") == ("fooBar_baz", "it")
    check nimDemangle("X5BX5Deq___it_u308") == ("[]=", "it")
    check nimDemangle("eqwasMoved___it_u164") == ("=wasMoved", "it")
    check nimDemangle("_shout__app_u6") == ("shout", "app")        # (Mach-O's _ in front)

  test "Nim 3 (Nimony): <name>_<n>_<module key>":
    check nimDemangle("greet_0_h3j08bn01") == ("greet", "h3j08bn01")
    check nimDemangle("plusQ_0_h3j08bn01") == ("+", "h3j08bn01")
    check nimDemangle("getQ_2_tabj08bn01") == ("[]", "tabj08bn01")

  test "Nim 2 with --debugger:native: C++'s form":
    check nimDemangle("_ZN4demo5greetE6string") == ("greet", "demo")
    check nimDemangle("_ZN4demo5plus_E6string6string") == ("+", "demo")
    check nimDemangle("_ZN10exceptions10eqdestroy_E3varIN10exceptions11IndexDefectEE") == ("=destroy", "exceptions")
    check nimDemangle("_ZN10exceptions34rttiDestroy__systemZexceptions_u58E7pointer") ==
      ("rttiDestroy", "system/exceptions")
    check nimDemangle("__ZN4demo5greetE6string") == ("greet", "demo")       # (Mach-O's _ in front)
    check nimDemangle("_ZNSt6vectorIiE9push_backEOi") == ("", "")          # (C++'s std:: is no module)

  test "C's own names are no Nim names":
    for n in ["main", "__libc_start_main", "_init", "memcpy", "my_func", "sqlite3_open_v2", "_ZN", "_ZN4demoE"]:
      check nimDemangle(n) == ("", "")

suite "ELF":
  test "a program Nim built: sections, symbols in the file, Nim's procs and modules":
    let dir = getTempDir() / "ned-tbinfmt"
    createDir(dir)
    writeFile(dir / "app.nim", "proc shout*(s: string): string = s & \"!\"\nproc `+`(a, b: int): int = a * b\n" &
              "echo shout(\"hi\"), 2 + 3\n")
    let (o, code) = execCmdEx("nim c -d:release --hints:off --nimcache:" & quoteShell(dir / "nc") & " -o:" &
                              quoteShell(dir / "app") & " " & quoteShell(dir / "app.nim"))
    check code == 0
    if code != 0: echo o
    let d = readFile(dir / "app")
    let r = binParse(d)
    check r.format == "ELF"
    check r.nim
    check r.arch.len > 0 and r.kind.startsWith("executable")
    var names: seq[string]
    for s in r.sections: names.add s.name
    check ".text" in names
    var shout = false
    for s in r.symbols:
      if s.nimName == "shout" and s.nimModule == "app":
        shout = true
        check s.code
        check s.offset > 0 and s.offset < d.len
        check s.size > 0
    check shout
    var appBytes = 0'i64
    for (m, b, n) in nimSizes(r):
      if m == "app": appBytes = b
    check appBytes > 0
    removeDir(dir)

  test "not an executable: format empty":
    check binParse("just some text\0\1\2").format == ""

suite "Mach-O and PE (made with zig cc, when there is a zig)":
  let zig = if getEnv("ZIG").len > 0: getEnv("ZIG") else: findExe("zig")
  test "a macOS arm64 program: its symbols (the _ in front taken off for Nim's names), their place and size":
    if zig.len == 0:
      skip()
    else:
      let dir = getTempDir() / "ned-tbinfmt-x"
      createDir(dir)
      writeFile(dir / "h.c", "int shout__app_u6(int x) { return x * 2; }\nint main(void) { return shout__app_u6(3); }\n")
      let (o, code) = execCmdEx(quoteShell(zig) & " cc -target aarch64-macos " & quoteShell(dir / "h.c") & " -o " &
                                quoteShell(dir / "h_mac"))
      check code == 0
      if code != 0: echo o
      else:
        let d = readFile(dir / "h_mac")
        let r = binParse(d)
        check r.format == "Mach-O" and r.arch == "arm64" and r.kind == "executable"
        var found = false
        for s in r.symbols:
          if s.nimName == "shout" and s.nimModule == "app":
            found = true
            check s.code and s.size > 0 and s.offset > 0 and s.offset < d.len
        check found
      removeDir(dir)

  test "a Windows program: PE, its CPU and sections":
    if zig.len == 0:
      skip()
    else:
      let dir = getTempDir() / "ned-tbinfmt-w"
      createDir(dir)
      writeFile(dir / "h.c", "int main(void) { return 3; }\n")
      let (o, code) = execCmdEx(quoteShell(zig) & " cc -target x86_64-windows-gnu " & quoteShell(dir / "h.c") & " -o " &
                                quoteShell(dir / "h.exe"))
      check code == 0
      if code != 0: echo o
      else:
        let r = binParse(readFile(dir / "h.exe"))
        check r.format == "PE" and r.arch == "x86-64" and r.kind == "executable"
        var names: seq[string]
        for s in r.sections: names.add s.name
        check ".text" in names
      removeDir(dir)
