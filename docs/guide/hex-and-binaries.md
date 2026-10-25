# Hex editor, programs and the decompiler

A file that is not text — a program, a library, an image, a database — opens in ned's **hex editor**: its bytes as
they are, nothing turned into lines. A program (ELF on Linux and Android, Mach-O on macOS, PE on Windows) is also
read for its sections and symbols, and a Nim program's procs by their Nim names. The **decompiler** shows one
function of a program as C, or as its machine code with the source lines it came from. A picture opens as the
picture.

## Pictures

A `.png`, `.jpg`, `.gif`, `.bmp` or `.webp` file opens as the picture, fitted to the tab, with its format, size in
pixels and file size at the top. **+** and **−** zoom, **0** fits it again, the arrows (or h j k l, Page Up and Page
Down) move a zoomed picture, and **Tab** shows its bytes in the hex editor (there Tab goes between the hex and
the text columns, as in any file; **Shift+Tab**: the picture again).

How it is drawn depends on the terminal (`pictures.draw`, `auto`): with the kitty graphics protocol (kitty, Ghostty),
iTerm2's images (iTerm2, WezTerm) or sixel (a terminal that says it has sixel when ned asks: foot, mlterm, recent
Windows Terminal …) the terminal draws the fitted picture at its own resolution; otherwise — Termux, tmux, others —
and when zoomed in, it is drawn in the text's cells, two pixels to a cell. WebP needs `dwebp` or ImageMagick. `pictures.open` set to false opens pictures in the hex editor as
before. Pictures in a Markdown file's preview are drawn the same way (in cells).

## The hex editor

```
 ELF x86-64 executable · Nim · 1.2 MB  OVERWRITE  0x00000000 (0)  in app.main (app)
 00000000  7f 45 4c 46 02 01 01 00  00 00 00 00 00 00 00 00  .ELF............
 00000010  03 00 3e 00 01 00 00 00  60 4e 00 00 00 00 00 00  ..>.....`N......
 00000020  40 00 00 00 00 00 00 00  a8 b1 0a 00 00 00 00 00  @...............
 u8 127 · i8 127 · bits 01111111 · u16 17791 · BE 32581 · u32 1179403647 · f32 … · varint … · UTF-8 …
```

The first line says what the file is and its size, the mode, the cursor's offset and the function it is in; each row is the offset, the bytes in hex
(sixteen, or eight or four on a narrow screen) and the same bytes as text. A file is taken for binary when its first
8000 bytes hold a NUL byte; *Hex: show as text* shows it as text instead (read-only, the NULs as spaces).

- **Typing**: in the hex column, `0`–`9` and `a`–`f` type over a byte, half a byte at a time; in the text column
  (Tab switches) any key types over a byte with that character. **Insert** switches to insert mode, where typing
  adds bytes; Delete and Backspace take bytes away.
- **Selecting and copying**: Shift+arrows select bytes, Ctrl+A all of them. Ctrl+C copies them as hex (as text in
  the text column); *Hex: copy as a Nim array*, *as a Nim string* and *as a C array* write them as code. Ctrl+V
  pastes hex (`de ad`, `0xde, 0xad`) or text.
- **Going places**: Ctrl+G goes to an offset — `8000`, `0x1F40`, `1f40h`, or `+16` and `-0x10` from where you are.
  Ctrl+F finds bytes (`de ad be ef`) or text (`"abc"`); F3 and Shift+F3 the next and the one before.
- **The data inspector**, under the bytes, reads what is at the cursor: the bits, unsigned and signed integers of
  8, 16, 32 and 64 bits — little-endian and big-endian — 32- and 64-bit floats, a varint, and the UTF-8 character.
- **Undo, redo, save**: Ctrl+Z, Ctrl+Y and Ctrl+S, as in a text file. Saving writes the bytes as they are, into a
  new file put in place of the old one, its permissions kept ([Safety](safety.md)).

Only the rows on the screen are drawn, so a file of hundreds of megabytes scrolls as fast as a small one; binary
files over 512 MB are not opened.

## Programs and libraries

When the file is a program, an object file or a library, the first line says what it is — the format, the kind
(executable, shared library, object file), the processor, whether Nim built it — and the palette has:

- *Hex: sections…* — the sections (`.text`, `.data`, `.rodata` …) with their sizes; Enter goes to one.
- *Hex: symbols…* — the functions and the data, with their sizes, to go to by name. Nim's procs have their Nim
  names: `shout__app_u12` is listed as `app.shout` (Nim 3's `greet_0_h3j08bn01` as `greet`).
- *Hex: Nim modules by size* — for a Nim program, how many bytes each module takes: what makes the program big.
  It needs the symbols: a program built with `-d:strip` has none.
- *Hex: open the Nim source of the proc at the cursor* — the proc whose bytes the cursor is on, in its `.nim` file.
- *Hex: decompile a function…* — see below.

## The decompiler

**Nim › Inspect › Decompile this proc** (*Nim: decompile this proc (side by side)*) builds the program — with
`--debugger:native`, in ned's own folder, only when the sources changed — and shows the proc at the cursor in the
pane beside it. Move to another proc and the view follows (`decompiler.follow`). **Run › Decompile** also has
*A program…* (*Decompile a program…*: any program by its path, opened in the hex editor with its functions to pick)
and *A function of the open binary…* (*Hex: decompile a function…*).

What it shows depends on what is installed — `decompiler.tool` chooses, and `auto` takes the best one there:

| tool | shows | install |
|---|---|---|
| radare2 with r2ghidra, or r2dec | C | `pkg install radare2` (Termux), `brew install radare2`; then `r2pm -ci r2ghidra` |
| rizin with rz-ghidra | C | |
| RetDec | C | |
| radare2, rizin, objdump, llvm-objdump | the machine code, with the Nim line each instruction came from | binutils (Termux: `pkg install binutils`) |

In the machine code, the hover on an instruction says what it does and on a register what it is for, as in
[Compiler Explorer](compiler-explorer.md) — which is the other way to see machine code: live, as you type, from the
compiler's own assembly, without building the whole program.
