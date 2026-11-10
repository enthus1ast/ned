## Compiler Explorer's reading of assembly (src/ned/editor/asmview.nim): a compiler's -S output and an object
## file disassembled, each instruction with its Nim line, the noise left out, names as Nim writes them, what an
## instruction or a register is. With nim and gcc (or clang) at hand, a real program compiled; else the samples.
## Run: nim r tests/unit/tasmview.nim

import std/[os, osproc, strutils, unittest]
import ../../src/ned/editor/asmview

const Sample = """	.file	"@mex.nim.c"
	.text
	.file 0 "/w" "nc/@mex.nim.c"
	.section	.rodata.str1.1,"aMS",@progbits,1
.LC0:
	.string	"hello"
.LC9:
	.string	"unused"
	.text
	.p2align 4
	.globl	square__ex_u1
	.type	square__ex_u1, @function
square__ex_u1:
.LFB1:
	.file 1 "/w/ex.nim"
	.loc 1 1 48 view -0
	.cfi_startproc
	endbr64
	.loc 1 2 6 view .LVU7
	imul	rdi, rdi	# a comment
	jo	.L8
.L5:
	.loc 1 3 16 view .LVU13
	lea	rax, .LC0[rip]
	ret
.L8:
	call	raiseOverflow
	.cfi_endproc
	.size	square__ex_u1, .-square__ex_u1
	.p2align 4
	.type	nimHelper, @function
nimHelper:
	.file 2 "/nim/lib/system.nim"
	.loc 2 10 1
	ret
	.section	.debug_info,"",@progbits
	.long	0x2c
"""

suite "a compiler's -S output":
  test "each instruction with its Nim line; directives, comments, unused labels and other files' functions out":
    let r = parseGas(Sample, "/w/ex.nim", AllFilters)
    var shown: seq[string]
    for l in r.lines: shown.add l.text.strip
    check shown == @[".LC0:", ".string \"hello\"", "square:", "endbr64", "imul    rdi, rdi", "jo      .L8",
                     "lea     rax, .LC0[rip]", "ret", ".L8:", "call    raiseOverflow"]
    check r.lines[4].src == 1 and r.lines[3].src == 0 and r.lines[6].src == 2
    check r.functions == @["square"]
    check r.arch == "x86_64"
  test "nothing left out: every line, still with its source line":
    let r = parseGas(Sample, "/w/ex.nim", AsmFilters())
    check r.lines.len > 20
    var found = false
    for l in r.lines:
      if "imul" in l.text: found = l.src == 1
    check found
  test "one filter at a time: labels only (.L5 is jumped to by nothing)":
    var f = AsmFilters(labels: true)
    let r = parseGas(Sample, "/w/ex.nim", f)
    var hasL5, hasL8, hasDirective = false
    for l in r.lines:
      if l.text.strip == ".L5:": hasL5 = true
      if l.text.strip == ".L8:": hasL8 = true
      if ".cfi_startproc" in l.text: hasDirective = true
    check not hasL5 and hasL8 and hasDirective

const MachO = """	.section	__TEXT,__text,regular,pure_instructions
	.build_version macos, 14, 0
	.file	1 "/w" "ex.nim"
	.globl	__ZN2ex6squareE3int
	.p2align	2
__ZN2ex6squareE3int:
	.loc	1 1 0
	.cfi_startproc
	.loc	1 2 6 prologue_end
	mul	x0, x0, x0
	ret
	.cfi_endproc
	.section	__TEXT,__cstring,cstring_literals
l_.str:
	.asciz	"hello"
	.section	__DWARF,__debug_abbrev,regular,debug
Lsection_abbrev:
	.byte	1
"""

suite "clang on macOS (Mach-O)":
  test "__TEXT,__text is the code: its functions, with their Nim lines (Nim 2.4's names)":
    let r = parseGas(MachO, "/w/ex.nim", AllFilters)
    check r.functions == @["square"]
    var mulLine = -2
    for l in r.lines:
      if "mul" in l.text: mulLine = l.src
    check mulLine == 1
    for l in r.lines: check "debug_abbrev" notin l.text and ".byte" notin l.text
  test "clang's own labels (Ltmp0, LBB0_2) are no functions; code inlined from the system at the program's line":
    # (Nim 2.4 on an arm64 Mac: num * num is nimMulInt of system/integerops.nim, inlined — its .loc there, and
    # clang's comment says where it was inlined)
    const MachOInl = "\t.section\t__TEXT,__text,regular,pure_instructions\n" &
      "\t.file\t5 \"/w\" \"ex.nim\"\n__ZN2ex6squareE3int:                    ; @_ZN2ex6squareE3int\n" &
      "Lfunc_begin0:\n\t.loc\t5 1 0                           ; ex.nim:1:0\n\tmov\tx8, x0\nLtmp0:\n" &
      "\t.file\t6 \"/n\" \"lib/system/integerops.nim\"\n" &
      "\t.loc\t6 94 45 prologue_end            ; lib/system/integerops.nim:94:45 @[ ex.nim:2:7 ]\n" &
      "\tmul\tx0, x0, x0\nLtmp1:\n\t.loc\t6 96 7                          ; lib/system/integerops.nim:96:7\n" &
      "\tb.hi\tLBB0_2\n\tret\nLBB0_2:\n\tbl\t_raiseOverflow\n"
    let r = parseGas(MachOInl, "/w/ex.nim", AllFilters)
    check r.functions == @["square"]
    var mulAt = (-2, "")
    for l in r.lines:
      if l.text.strip.startsWith("mul"): mulAt = (l.src, l.fn)
    check mulAt == (1, "square")
    for l in r.lines: check "Ltmp" notin l.text and "Lfunc_begin" notin l.text

suite "names, instructions, registers":
  test "Nim's names as Nim writes them":
    check demangleIn("call square__ex_u1") == "call square"
    check demangleIn("mov rax, QWORD PTR nimInErrorMode__system_u4218@gottpoff[rip]") ==
          "mov rax, QWORD PTR nimInErrorMode@gottpoff[rip]"
    check demangleIn("call dollar___systemZdollars_u14") == "call `$`"
    check demangleIn("jmp .L8") == "jmp .L8"
  test "what an instruction does":
    check asmDoc("imul", false).startsWith("Signed multiply")
    check asmDoc("jne", false).startsWith("Jump if not equal")
    check asmDoc("addq", false).endsWith("(64-bit)")
    check asmDoc("cmovge", false).startsWith("Move if greater or equal")
    check asmDoc("b.ne", true) == "Branch if not equal"
    check asmDoc("smulh", true).startsWith("Signed multiply, the high")
    check asmDoc("frobnicate", false) == ""
  test "what a register is for":
    check asmRegDoc("rdi", false).startsWith("The first argument")
    check asmRegDoc("%rax", false).startsWith("The return value")
    check asmRegDoc("x0", true).startsWith("x0: the first argument")
    check asmRegDoc("w19", true).contains("callee-saved")
    check asmRegDoc("x30", true).contains("link register")

suite "a real program (nim and a C compiler at hand)":
  let nim = findExe("nim")
  let cc = if findExe("gcc").len > 0: "gcc" elif findExe("clang").len > 0: "clang" else: ""
  let dir = getTempDir() / "tasmview-" & $getCurrentProcessId()
  test "square: its multiply on its own line, the program's calls kept, the runtime out":
    if nim.len == 0 or cc.len == 0:
      skip()
    else:
      createDir(dir)
      writeFile(dir / "ex.nim", "proc square(num: int): int =\n  num * num\n\necho square(6)\n")
      let (o, code) = execCmdEx(nim & " c --hints:off --debugger:native -d:release --compileOnly --cc:" & cc &
                                " --nimcache:" & quoteShell(dir / "nc") & " " & quoteShell(dir / "ex.nim"))
      checkpoint o
      check code == 0
      let c = dir / "nc" / "@mex.nim.c"
      let (o2, code2) = execCmdEx(cc & " -S -g -O2 -w -fno-asynchronous-unwind-tables" &
                                  (if hostCPU == "amd64": " -masm=intel" else: "") & " -I" &
                                  quoteShell(parentDir(parentDir(nim)) / "lib") & " -o " & quoteShell(dir / "ex.s") &
                                  " " & quoteShell(c))
      checkpoint o2
      check code2 == 0
      let r = parseGas(readFile(dir / "ex.s"), dir / "ex.nim", AllFilters)
      check "square" in r.functions
      var mulOnLine2 = false
      for l in r.lines:
        let mnemonic = l.text.strip.split({' ', '\t'})[0]
        if l.fn == "square" and mnemonic in ["imul", "mul", "madd"] and l.src == 1: mulOnLine2 = true
      check mulOnLine2
      check r.lines.len < r.total div 4               # (most of it is the runtime and the debug info)
      removeDir(dir)
