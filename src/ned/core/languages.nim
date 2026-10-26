# ════════════════════════════════════════════════════════════════════════════
#  Languages
# ════════════════════════════════════════════════════════════════════════════

type
  EmbedEnd = enum eeTriple, eeFence, eeTag   # what ends it: Nim's """, a ``` line, the element's closing tag
  EmbedDesc = object
    langId: string          # "" — not known yet: the string's first line of text decides
    ends: EmbedEnd
    tag: string             # eeTag: script or style
    fmt: bool               # a strformat string: {expressions} in the text are Nim

var
  embeds: seq[EmbedDesc] = @[EmbedDesc()]   # an id is an index (0: none); ids are kept for the session
  embedLangCache: Table[string, Lang]
  pseudoLangs: seq[Lang]                    # languages that only live inside strings: regex, peg, nimfmt
  cfgEmbedded: Table[string, string]        # nim.embeddedLanguages: a name before a string → its language
  lexDepth = 0
  lexForeign: seq[(int, int)]               # the line lexed last: the byte ranges another language coloured
  lexLangs: seq[(int, int, int, Lang)]      # the line lexed last: every embedded range at any depth (from, to,
                                            # depth, language) — which language the cursor is in
  lexOff = 0                                # where the string a nested lexer is colouring starts in the line
  embedSig = ""                             # nim.embeddedLanguages and the backend, when last applied

proc ws(s: string): HashSet[string] = toHashSet(s.splitWhitespace())
proc wsAnyCase(s: string): HashSet[string] =
  ## SQL: keywords in lower and upper case
  for w in s.splitWhitespace():
    result.incl w.toLowerAscii
    result.incl w.toUpperAscii

proc initLangs() =
  let cKw = ws"""break case const continue default do else enum extern for goto if inline
    register restrict return sizeof static struct switch typedef union volatile while
    class namespace template typename public private protected virtual override new delete
    this throw try catch using operator friend constexpr noexcept static_cast dynamic_cast
    reinterpret_cast const_cast decltype explicit mutable final auto"""
  let cTy = ws"""int char float double long short unsigned signed void bool size_t ssize_t
    uint8_t uint16_t uint32_t uint64_t int8_t int16_t int32_t int64_t uintptr_t intptr_t
    FILE wchar_t std string vector map"""
  langs = @[
    Lang(name: "Nim", id: "nim", exts: @["nim", "nims", "nimble"], files: @["nim.cfg", "config.nims"],
      mode: lmNim, lineComment: "#", docLine: "##", blockStart: "#[", blockEnd: "]#",
      docBlockStart: "##[", docBlockEnd: "]##", nested: true, quotes: {'"'}, triple: true,
      charLit: true, capsTypes: true,
      keywords: ws"""addr and as asm bind block break case cast concept const continue converter
        defer discard distinct div do elif else end enum except export finally for from func if
        import in include interface is isnot iterator let macro method mixin mod nil not notin
        object of or out proc ptr raise ref return shl shr static template try tuple type using
        var when while xor yield""",
      types: ws"""int int8 int16 int32 int64 uint uint8 uint16 uint32 uint64 float float32 float64
        bool char string cstring pointer seq array set openArray varargs auto any void typed
        untyped typedesc byte range cint cuint clong culong cfloat cdouble cchar csize_t""",
      consts: ws"true false result",
      builtins: ws"""echo len add inc dec high low ord chr assert doAssert new newSeq sizeof quit
        isNil del insert contains items pairs mitems mpairs `$` repr move sink lent""",
      defWords: ws"proc func method iterator template macro converter",
      indentChars: {':', '=', '(', '[', '{', ','},
      indentWords: @["object", "tuple", "enum", "concept", "type", "var", "let", "const",
                     "import", "export", "using", "ref object"],
      indentWidth: 2,
      run: "nim c -r --hints:off \"$file\"", build: "nim c --hints:off \"$file\"",
      check: "nim check --hints:off --colors:off --listFullPaths:on \"$file\"",
      lsp: @[@["nimlangserver"], @["nimlsp"]],
      fmt: @["nph -", "nimpretty --out:$out $in"], pairs: "()[]{}\"\""),
    Lang(name: "Python", id: "python", exts: @["py", "pyw", "pyi"], mode: lmPython,
      lineComment: "#", quotes: {'"', '\''}, triple: true, decorators: true,
      keywords: ws"""and as assert async await break class continue def del elif else except
        finally for from global if import in is lambda nonlocal not or pass raise return try
        while with yield match case""",
      types: ws"int float str bool list dict set tuple bytes object type complex frozenset",
      consts: ws"True False None self cls",
      builtins: ws"print len range open enumerate zip map filter sorted isinstance super input",
      defWords: ws"def", classWords: ws"class",
      indentChars: {':', '(', '[', '{'}, indentWidth: 4,
      run: "python3 \"$file\"", lsp: @[@["pylsp"], @["pyright-langserver", "--stdio"],
        @["basedpyright-langserver", "--stdio"], @["jedi-language-server"]],
      fmt: @["ruff format -", "black -q -"], pairs: "()[]{}\"\"''"),
    Lang(name: "C", id: "c", exts: @["c", "h"], mode: lmC, lineComment: "//",
      blockStart: "/*", blockEnd: "*/", docBlockStart: "/**", docBlockEnd: "*/",
      quotes: {'"', '\''}, charLit: true, keywords: cKw, types: cTy,
      consts: ws"NULL true false nullptr EOF stdin stdout stderr",
      indentChars: {'{', '(', '['}, dedentChars: {'}', ')', ']'}, indentWidth: 4,
      run: "cc -Wall -O1 \"$file\" -o \"$tmp/ned_run\" -lm && \"$tmp/ned_run\"",
      lsp: @[@["clangd"]], fmt: @["clang-format --assume-filename=\"$file\""],
      pairs: "()[]{}\"\"''"),
    Lang(name: "C++", id: "cpp", exts: @["cpp", "cc", "cxx", "hpp", "hh", "hxx"], mode: lmC,
      lineComment: "//", blockStart: "/*", blockEnd: "*/", docBlockStart: "/**", docBlockEnd: "*/",
      quotes: {'"', '\''}, charLit: true, keywords: cKw, types: cTy,
      consts: ws"NULL true false nullptr", capsTypes: true,
      indentChars: {'{', '(', '['}, dedentChars: {'}', ')', ']'}, indentWidth: 4,
      run: "c++ -Wall -O1 -std=c++17 \"$file\" -o \"$tmp/ned_run\" && \"$tmp/ned_run\"",
      lsp: @[@["clangd"]], fmt: @["clang-format --assume-filename=\"$file\""],
      pairs: "()[]{}\"\"''"),
    Lang(name: "JavaScript", id: "javascript", exts: @["js", "mjs", "cjs", "jsx"], mode: lmJs,
      lineComment: "//", blockStart: "/*", blockEnd: "*/", docBlockStart: "/**", docBlockEnd: "*/",
      quotes: {'"', '\'', '`'}, capsTypes: true, decorators: true,
      keywords: ws"""break case catch class const continue debugger default delete do else export
        extends finally for function if import in instanceof let new return super switch this
        throw try typeof var void while with yield async await of static get set from as""",
      consts: ws"true false null undefined NaN Infinity",
      builtins: ws"console require",
      defWords: ws"function", classWords: ws"class",
      indentChars: {'{', '(', '['}, dedentChars: {'}', ')', ']'}, indentWidth: 2,
      run: "node \"$file\"", lsp: @[@["typescript-language-server", "--stdio"]],
      fmt: @["prettier --stdin-filepath \"$file\""], pairs: "()[]{}\"\"''``"),
    Lang(name: "TypeScript", id: "typescript", exts: @["ts", "tsx", "mts", "cts"], mode: lmJs,
      lineComment: "//", blockStart: "/*", blockEnd: "*/", docBlockStart: "/**", docBlockEnd: "*/",
      quotes: {'"', '\'', '`'}, capsTypes: true, decorators: true,
      keywords: ws"""break case catch class const continue debugger default delete do else export
        extends finally for function if import in instanceof let new return super switch this
        throw try typeof var void while with yield async await of static get set from as
        interface type enum implements private public protected readonly declare namespace
        abstract keyof infer is satisfies""",
      types: ws"string number boolean any unknown never void object bigint symbol",
      consts: ws"true false null undefined NaN Infinity",
      defWords: ws"function", classWords: ws"class interface type enum",
      indentChars: {'{', '(', '['}, dedentChars: {'}', ')', ']'}, indentWidth: 2,
      run: "node \"$file\"", lsp: @[@["typescript-language-server", "--stdio"]],
      fmt: @["prettier --stdin-filepath \"$file\""], pairs: "()[]{}\"\"''``"),
    Lang(name: "Rust", id: "rust", exts: @["rs"], mode: lmRust, lineComment: "//",
      docLine: "///", blockStart: "/*", blockEnd: "*/", nested: true, quotes: {'"', '\''},
      charLit: true, capsTypes: true,
      keywords: ws"""as async await break const continue crate dyn else enum extern fn for if impl
        in let loop match mod move mut pub ref return self Self static struct super trait type
        unsafe use where while""",
      types: ws"""i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str""",
      consts: ws"true false None Some Ok Err",
      defWords: ws"fn", classWords: ws"struct enum trait union",
      indentChars: {'{', '(', '['}, dedentChars: {'}', ')', ']'}, indentWidth: 4,
      run: "rustc -O \"$file\" -o \"$tmp/ned_run\" && \"$tmp/ned_run\"",
      lsp: @[@["rust-analyzer"]], fmt: @["rustfmt --edition 2021"], pairs: "()[]{}\"\""),
    Lang(name: "Go", id: "go", exts: @["go"], mode: lmGeneric, lineComment: "//",
      blockStart: "/*", blockEnd: "*/", quotes: {'"', '\'', '`'}, charLit: true,
      keywords: ws"""break case chan const continue default defer else fallthrough for func go goto
        if import interface map package range return select struct switch type var""",
      types: ws"""int int8 int16 int32 int64 uint uint8 uint16 uint32 uint64 uintptr float32
        float64 complex64 complex128 string byte rune bool error any""",
      consts: ws"true false nil iota",
      builtins: ws"len cap make new append copy delete panic recover print println close",
      defWords: ws"func", indentChars: {'{', '(', '['}, dedentChars: {'}', ')', ']'},
      useTabs: true, indentWidth: 4, run: "go run \"$file\"", lsp: @[@["gopls"]],
      fmt: @["gofmt"], pairs: "()[]{}\"\"``"),
    Lang(name: "Java", id: "java", exts: @["java"], mode: lmC, lineComment: "//",
      blockStart: "/*", blockEnd: "*/", docBlockStart: "/**", docBlockEnd: "*/",
      quotes: {'"', '\''}, charLit: true, capsTypes: true, decorators: true,
      keywords: ws"""abstract assert break case catch class continue default do else enum extends
        final finally for if implements import instanceof interface native new package private
        protected public return static super switch synchronized this throw throws transient try
        volatile while var val fun when object companion data sealed override open internal is
        by init lateinit suspend""",
      types: ws"int long short byte float double char boolean void",
      consts: ws"true false null", defWords: ws"fun", classWords: ws"class interface object",
      indentChars: {'{', '(', '['}, dedentChars: {'}', ')', ']'}, indentWidth: 4,
      run: "java \"$file\"", pairs: "()[]{}\"\"''"),
    Lang(name: "Shell", id: "shellscript", exts: @["sh", "bash", "zsh", "ksh"],
      files: @[".bashrc", ".zshrc", ".profile", ".bash_profile"], mode: lmShell,
      lineComment: "#", commentNeedsSpace: true, quotes: {'"', '\'', '`'},
      keywords: ws"""if then else elif fi case esac for while until do done in function select
        return exit local export readonly declare unset shift break continue source alias set
        trap eval exec""",
      builtins: ws"echo printf cd pwd test read mkdir rm cp mv ls cat grep sed awk",
      consts: ws"true false", indentWords: @["then", "do", "else", "{", "("],
      indentWidth: 2, run: "bash \"$file\"", lsp: @[@["bash-language-server", "start"]],
      fmt: @["shfmt -"], pairs: "()[]{}\"\"''"),
    Lang(name: "Kotlin", id: "kotlin", exts: @["kt", "kts"], mode: lmC, lineComment: "//",
      blockStart: "/*", blockEnd: "*/", docBlockStart: "/**", docBlockEnd: "*/", nested: true,
      quotes: {'"', '\''}, triple: true, charLit: true, capsTypes: true, decorators: true,
      keywords: ws"""as break class continue do else for fun if in interface is object package return super this
        throw try typealias typeof val var when while by catch constructor finally get import init set where
        abstract actual annotation companion const crossinline data enum expect external final infix inline
        inner internal lateinit noinline open operator out override private protected public reified sealed
        suspend tailrec vararg value""",
      types: ws"""Int Long Short Byte Float Double Char Boolean String Unit Any Nothing Array List MutableList Map
        MutableMap Set MutableSet Sequence Pair Triple""",
      consts: ws"true false null it", defWords: ws"fun", classWords: ws"class interface object",
      builtins: ws"println print listOf mutableListOf mapOf mutableMapOf setOf arrayOf require check error TODO",
      indentChars: {'{', '(', '['}, dedentChars: {'}', ')', ']'}, indentWidth: 4,
      run: "case \"$file\" in *.kts) kotlinc -script \"$file\" ;; *) kotlinc -nowarn \"$file\" -include-runtime " &
           "-d \"$tmp/ned_run.jar\" && java -jar \"$tmp/ned_run.jar\" ;; esac",
      lsp: @[@["kotlin-lsp", "--stdio"], @["kotlin-language-server"]], fmt: @["ktfmt -"],
      pairs: "()[]{}\"\"''"),
    Lang(name: "C#", id: "csharp", exts: @["cs", "csx"], mode: lmC, lineComment: "//",
      blockStart: "/*", blockEnd: "*/", docLine: "///", quotes: {'"', '\''}, charLit: true, capsTypes: true,
      keywords: ws"""abstract as base break case catch checked class const continue default delegate do else enum
        event explicit extern finally fixed for foreach goto if implicit in interface internal is lock namespace
        new operator out override params private protected public readonly ref return sealed sizeof stackalloc
        static struct switch this throw try typeof unchecked unsafe using virtual volatile while async await var
        record init get set value yield when where with partial global dynamic nameof required file""",
      types: ws"""bool byte sbyte char decimal double float int uint long ulong short ushort object string void
        nint nuint Task List Dictionary IEnumerable Span""",
      consts: ws"true false null", classWords: ws"class interface struct record enum",
      indentChars: {'{', '(', '['}, dedentChars: {'}', ')', ']'}, indentWidth: 4,
      run: "case \"$file\" in *.csx) dotnet script \"$file\" ;; *) dotnet run ;; esac",
      lsp: @[@["csharp-ls"], @["OmniSharp", "-lsp"]], fmt: @["csharpier format --write-stdout"],
      pairs: "()[]{}\"\"''"),
    Lang(name: "PHP", id: "php", exts: @["php", "phtml", "php8"], mode: lmC, lineComment: "//",
      blockStart: "/*", blockEnd: "*/", docBlockStart: "/**", docBlockEnd: "*/", quotes: {'"', '\''},
      capsTypes: true, decorators: true,
      keywords: ws"""abstract and array as break callable case catch class clone const continue declare default do
        echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile enum extends final finally fn
        for foreach function global goto if implements include include_once instanceof insteadof interface isset
        list match namespace new or print private protected public readonly require require_once return static
        switch throw trait try unset use var while xor yield""",
      types: ws"int float bool string array object mixed void never iterable callable self parent null",
      consts: ws"true false null TRUE FALSE NULL __DIR__ __FILE__ __LINE__ __CLASS__ __FUNCTION__ __METHOD__",
      defWords: ws"function fn", classWords: ws"class interface trait enum",
      builtins: ws"count strlen str_replace explode implode array_map array_filter in_array json_encode json_decode sprintf printf var_dump",
      indentChars: {'{', '(', '['}, dedentChars: {'}', ')', ']'}, indentWidth: 4,
      run: "php \"$file\"", lsp: @[@["intelephense", "--stdio"], @["phpactor", "language-server"]],
      pairs: "()[]{}\"\"''"),
    Lang(name: "SQL", id: "sql", exts: @["sql", "psql", "mysql", "pgsql"], mode: lmGeneric, lineComment: "--",
      blockStart: "/*", blockEnd: "*/", quotes: {'\'', '"', '`'},
      keywords: wsAnyCase"""select from where and or not insert into values update set delete create table view index
        drop alter add column primary key foreign references unique check default constraint join inner left
        right full outer cross on using group by order having limit offset union all distinct as case when then
        else end in is like ilike between exists returning with recursive begin commit rollback transaction grant
        revoke if replace trigger function procedure language declare return returns asc desc nulls first last
        fetch next rows only over partition window cascade schema database explain analyze vacuum pragma""",
      types: wsAnyCase"""int integer bigint smallint serial bigserial real double precision float numeric decimal
        text varchar char character boolean bool date time timestamp timestamptz interval uuid json jsonb blob bytea""",
      consts: wsAnyCase"true false null", builtins: wsAnyCase"count sum avg min max coalesce now cast nullif length lower upper",
      indentChars: {'('}, dedentChars: {')'}, indentWidth: 2,
      run: "db=$(ls \"$dir\"/*.db \"$dir\"/*.sqlite \"$dir\"/*.sqlite3 2>/dev/null | head -1); " &
           "sqlite3 -box \"${db:-:memory:}\" < \"$file\"",
      lsp: @[@["sqls"], @["sql-language-server", "up", "--method", "stdio"]], fmt: @["sql-formatter"],
      pairs: "()[]\"\"''``"),
    Lang(name: "Lua", id: "lua", exts: @["lua"], mode: lmGeneric, lineComment: "--",
      blockStart: "--[[", blockEnd: "]]", quotes: {'"', '\''},
      keywords: ws"""and break do else elseif end for function goto if in local not or repeat
        return then until while""",
      consts: ws"true false nil", defWords: ws"function",
      indentWords: @["then", "do", "else", "repeat", "{", "("], indentWidth: 2,
      run: "lua \"$file\"", lsp: @[@["lua-language-server"]], fmt: @["stylua -"],
      pairs: "()[]{}\"\"''"),
    Lang(name: "Ruby", id: "ruby", exts: @["rb"], files: @["Gemfile", "Rakefile"], mode: lmGeneric,
      lineComment: "#", quotes: {'"', '\''},
      keywords: ws"""alias and begin break case class def defined? do else elsif end ensure for if
        in module next not or redo rescue retry return self super then undef unless until when
        while yield require attr_accessor""",
      consts: ws"true false nil", defWords: ws"def", classWords: ws"class module",
      capsTypes: true, indentWords: @["do", "then", "else", "begin"], indentWidth: 2,
      run: "ruby \"$file\"", lsp: @[@["ruby-lsp"], @["solargraph", "stdio"]], pairs: "()[]{}\"\"''"),
    Lang(name: "JSON", id: "json", exts: @["json", "jsonc", "json5"], mode: lmJson,
      files: @["atlas.config", "atlas.lock", "atlas.workspace", ".babelrc", ".eslintrc", ".prettierrc", ".jshintrc"],
      lineComment: "//", blockStart: "/*", blockEnd: "*/", quotes: {'"'},
      consts: ws"true false null", indentChars: {'{', '['}, dedentChars: {'}', ']'},
      indentWidth: 2, fmt: @["prettier --stdin-filepath \"$file\""], lsp: @[@["vscode-json-language-server", "--stdio"]],
      pairs: "[]{}\"\""),
    Lang(name: "NIF", id: "nif", exts: @["nif"], mode: lmNif, quotes: {'"'}, indentWidth: 1, pairs: "()\"\""),
    Lang(name: "YAML", id: "yaml", exts: @["yml", "yaml"], mode: lmYaml, lineComment: "#",
      commentNeedsSpace: true, quotes: {'"', '\''}, consts: ws"true false null yes no on off ~",
      indentChars: {':'}, indentWidth: 2, lsp: @[@["yaml-language-server", "--stdio"]], pairs: "[]{}\"\"''"),
    Lang(name: "TOML", id: "toml", exts: @["toml", "ini", "cfg", "conf", "properties", "desktop"],
      files: @[".gitconfig", ".editorconfig"], mode: lmToml, lineComment: "#",
      quotes: {'"', '\''}, triple: true, consts: ws"true false", indentWidth: 2,
      pairs: "[]{}\"\""),
    Lang(name: "Markdown", id: "markdown", exts: @["md", "markdown", "mdx"], mode: lmMarkdown,
      indentWidth: 2, fmt: @["prettier --stdin-filepath \"$file\""], lsp: @[@["marksman", "server"]], pairs: "()[]``"),
    Lang(name: "HTML", id: "html", exts: @["html", "htm", "xml", "svg", "xhtml", "vue", "plist"],
      mode: lmHtml, quotes: {'"', '\''}, indentWidth: 2, lsp: @[@["vscode-html-language-server", "--stdio"]],
      fmt: @["prettier --stdin-filepath \"$file\""], pairs: "\"\""),
    Lang(name: "Nim template", id: "nimf", exts: @["nimf"], mode: lmNimf, quotes: {'"'},
      blockStart: "<!--", blockEnd: "-->", indentWidth: 2, pairs: "()[]{}\"\""),
    Lang(name: "Jinja template", id: "jinja", exts: @["nimja", "jinja", "jinja2", "j2", "nwt", "twig", "njk"],
      mode: lmJinja, quotes: {'"'}, blockStart: "{#", blockEnd: "#}", indentWidth: 2, pairs: "()[]\"\""),
    Lang(name: "CSS", id: "css", exts: @["css", "scss", "less"], mode: lmCss,
      blockStart: "/*", blockEnd: "*/", quotes: {'"', '\''},
      keywords: ws"important media import from to and not only supports keyframes",
      indentChars: {'{'}, dedentChars: {'}'}, indentWidth: 2, lsp: @[@["vscode-css-language-server", "--stdio"]],
      fmt: @["prettier --stdin-filepath \"$file\""], pairs: "()[]{}\"\"''"),
    Lang(name: "CSV", id: "csv", exts: @["csv"], mode: lmCsv, indentWidth: 2, csvSep: '\0', pairs: "\"\""),
    Lang(name: "TSV", id: "tsv", exts: @["tsv", "tab"], mode: lmCsv, indentWidth: 2, csvSep: '\t', useTabs: true),
    Lang(name: "PSV", id: "psv", exts: @["psv"], mode: lmCsv, indentWidth: 2, csvSep: '|'),
    Lang(name: "Makefile", id: "makefile", exts: @["mk", "make"],
      files: @["Makefile", "makefile", "GNUmakefile"], mode: lmMake, lineComment: "#",
      quotes: {'"', '\''}, useTabs: true, indentWidth: 4, run: "make", pairs: "()[]{}\"\""),
    Lang(name: "Dockerfile", id: "dockerfile", exts: @["dockerfile"], files: @["Dockerfile"],
      mode: lmGeneric, lineComment: "#", quotes: {'"', '\''},
      keywords: ws"""FROM RUN CMD LABEL EXPOSE ENV ADD COPY ENTRYPOINT VOLUME USER WORKDIR ARG
        ONBUILD STOPSIGNAL HEALTHCHECK SHELL AS""", indentWidth: 2, lsp: @[@["docker-langserver", "--stdio"]],
      pairs: "()[]{}\"\""),
    Lang(name: "Diff", id: "diff", exts: @["diff", "patch"], mode: lmDiff, indentWidth: 2),
    # (machine code: objdump's, radare2's, a .s file — the instructions, the registers, the numbers)
    Lang(name: "Assembly", id: "asm", exts: @["s", "S", "asm"], mode: lmGeneric, lineComment: ";",
      quotes: {'"'},
      keywords: ws"""mov movl movq movb movw movzx movsx movsxd movabs movz movk movn lea push pop call ret jmp je jne jz
        jnz jg jge jl jle ja jae jb jbe js jns jo jno cmp test add sub imul mul idiv div inc dec neg not and or xor
        shl shr sar sal rol ror nop leave enter cmov cmove cmovne cmovg cmovl sete setne setg setl cqo cdq cdqe
        endbr64 syscall int hlt ud2 xchg bt bts btr ldr ldrb ldrh ldrsw ldur ldp str strb strh stur stp adrp adr
        b bl blr br cbz cbnz tbz tbnz csel cset csinc cneg madd msub sdiv udiv lsl lsr asr orr eor mvn tst cmn fmov
        fadd fsub fmul fdiv scvtf fcvtzs bic ands subs adds ret beq bne blt bgt ble bge bhi blo bls bhs b.eq b.ne
        b.lt b.gt b.le b.ge b.hi b.lo b.ls b.hs b.cc b.cs b.mi b.pl movss movsd movaps movups pxor xorps cvtsi2sd""",
      types: ws"""rax rbx rcx rdx rsi rdi rbp rsp rip r8 r9 r10 r11 r12 r13 r14 r15 eax ebx ecx edx esi edi ebp esp
        r8d r9d r10d r11d r12d r13d r14d r15d ax bx cx dx si di bp sp al bl cl dl ah bh ch dh sil dil r8b r9b xmm0
        xmm1 xmm2 xmm3 xmm4 xmm5 xmm6 xmm7 x0 x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 x13 x14 x15 x16 x17 x18 x19
        x20 x21 x22 x23 x24 x25 x26 x27 x28 x29 x30 w0 w1 w2 w3 w4 w5 w6 w7 w8 w9 w10 w11 w12 w13 w14 w15 w16 w17
        w18 w19 w20 w21 w22 w23 w24 w25 w26 w27 w28 w29 w30 xzr wzr lr fp pc qword dword word byte ptr""",
      indentWidth: 8, pairs: "()[]"),
    Lang(name: "Text", id: "plaintext", exts: @["txt", "text", "log"], mode: lmPlain,
      indentWidth: 2, pairs: "()[]{}"),
  ]
  # languages that only live inside strings (re"…", peg"…", fmt"…")
  pseudoLangs = @[Lang(name: "Regular expression", id: "regex", mode: lmRegex, indentWidth: 2),
                  Lang(name: "PEG", id: "peg", mode: lmRegex, indentWidth: 2),
                  Lang(name: "Nim format string", id: "nimfmt", mode: lmNimFmt, indentWidth: 2)]
  embedLangCache.clear()

proc langByName(name: string): Lang =
  for l in langs:
    if cmpIgnoreCase(l.name, name) == 0 or l.id == name: return l
  nil

proc detectLang(path: string, firstLine: string): Lang =
  if firstLine.startsWith("#? stdtmpl") or firstLine.startsWith("#?stdtmpl"): return langByName("nimf")
  let name = extractFilename(path)
  let ext = splitFile(path).ext.toLowerAscii().strip(chars = {'.'})
  for l in langs:
    if name in l.files: return l
  if ext.len > 0:
    for l in langs:
      if ext in l.exts: return l
  if firstLine.startsWith("#!"):
    if "python" in firstLine: return langByName("Python")
    if "node" in firstLine: return langByName("JavaScript")
    if "nim" in firstLine: return langByName("Nim")
    if "lua" in firstLine: return langByName("Lua")
    if "ruby" in firstLine: return langByName("Ruby")
    if "sh" in firstLine: return langByName("Shell")
  langByName("Text")
