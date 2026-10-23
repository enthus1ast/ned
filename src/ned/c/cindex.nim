## ned's own C engine: an index of C files and the headers they include — functions, structs and their members,
## unions, enums, typedefs, macros, globals, a function's parameters and locals, and the comments that document
## them — answering completion (members after `.` and `->` too), hover, go to definition, references, the outline
## and signature help. Text in, answers out: no compiler, no server, a few milliseconds a file.
##
## It reads C the way a person skimming it does, not as a compiler: the preprocessor is not run (every #if branch
## is read, macros are not expanded), so code built out of macros is understood less than clangd understands it.
##
## C++ too (a .cpp/.cc/.hpp file, or C++ in a Nim emit — `cpp`): classes with their methods (in the class or
## `Ret Class::method(…) { … }` outside it), bases, namespaces and `using`, templates read past (a template's
## arguments put in for its parameters in member types), references, `auto` from what initializes it, enum class.
## The C++ standard library's headers are not read: `std::` offers a known list of its names instead.

import std/[strutils, tables, sets, times, algorithm]
when defined(windows): import ../sys/winos as os   # (std/os, with '/' in the paths it makes)
else: import std/os

type
  CxKind* = enum
    cxFunc, cxStruct, cxUnion, cxEnum, cxTypedef, cxMacro, cxVar, cxEnumConst, cxField, cxParam, cxLocal, cxLabel,
    cxClass, cxNamespace, cxMethod      # (C++)
  CxParam* = object
    name*, typ*: string
    line*, col*: int            # where its name is written (-1: nowhere — unnamed)
  CxSym* = object
    name*: string
    kind*: CxKind
    line*, col*: int            # where its name is
    endLine*: int               # functions, structs, enums: where their body ends
    typ*: string                # variables, fields, params: the declared type ("struct point *"); typedefs: what they
                                # name; functions: what they return
    params*: seq[CxParam]       # functions and function-like macros
    varargs*: bool
    owner*: string              # fields: their struct or union (tag, or typedef name); enum constants: the enum
    text*: string               # the declaration, on one line
    doc*: string                # the comment above it (or after it on its line)
    isDef*: bool                # a function with its body; a struct with its members
    weak*: bool                 # a system header's inline wrapper over the real declaration (fortify, optimizing)
    scopeA*, scopeB*: int       # locals, parameters and labels: the lines they are seen on
    scope*: string              # C++: the namespace or class it is declared in, qualified ("geo", "geo::Box"); a
                                # method defined outside its class: the namespace it is defined in. "" in C
    bases*: seq[string]         # C++ classes: the classes they derive from, as written
    tparams*: seq[string]       # C++ templates: their parameters' names
    init*: string               # C++ `auto` variables: what initializes them (their type is its type); enum
                                # constants: their value as written (`= 1 << 4`)
    dims*: string               # fields: their array dimensions as written (`[SIZE][2]`)
    bits*: string               # fields: a bit-field's width (`3`)
  CxFile* = ref object
    path*: string
    stamp*: string
    syms*: seq[CxSym]
    includes*: seq[(string, int)]     # as written (<x.h> or "y.h"), and the line
    lines*: seq[string]
    inactive*: seq[(int, int)]        # what #if 0, #ifdef __cplusplus … leave out: (first line, last line)
    cpp*: bool                        # read as C++
    usings*: seq[(string, int)]       # C++: `using namespace x;` — x as written, and the line
    spaces*: seq[(string, int, int)]  # C++: the namespaces' bodies — (qualified name, first line, last line)
    byName, byOwner: Table[string, seq[int32]]   # the syms by name, the fields by owner (made when first asked)
    byScope: Table[string, seq[int32]]           # C++: the syms by the scope they are in (an enum's constants
                                                 # by their enum too)
    indexed: bool
  CxTokKind = enum ctWord, ctNum, ctStr, ctChar, ctPunct, ctTemplate
  CxTok = object
    kind: CxTokKind
    text: string
    line, col: int
    nameLine, nameCol: int      # C++: where the last part of a qualified name is (`Point::norm`: norm)
  CxComment = object
    a, b: int                   # first and last line
    text: string
    lone: bool                  # nothing but the comment on its first line

const
  CxKeywords* = ["auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum",
    "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "restrict", "return", "short",
    "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while",
    "_Bool", "_Complex", "_Alignas", "_Alignof", "_Atomic", "_Generic", "_Noreturn", "_Static_assert",
    "_Thread_local", "bool", "true", "false", "NULL"]
  CxTypeWords = ["void", "char", "short", "int", "long", "float", "double", "signed", "unsigned", "_Bool", "bool",
    "_Complex", "struct", "union", "enum", "const", "volatile", "static", "extern", "register", "inline", "restrict",
    "__restrict", "__restrict__", "__inline", "__inline__", "__extension__", "_Atomic", "_Noreturn", "_Thread_local",
    "size_t", "ssize_t", "ptrdiff_t", "intptr_t", "uintptr_t", "int8_t", "int16_t", "int32_t", "int64_t",
    "uint8_t", "uint16_t", "uint32_t", "uint64_t", "FILE", "va_list", "off_t", "pid_t", "time_t", "wchar_t"]
  CxQualifiers = ["const", "volatile", "static", "extern", "register", "inline", "restrict", "__restrict",
    "__restrict__", "__inline", "__inline__", "__extension__", "_Atomic", "_Noreturn", "_Thread_local", "__const",
    "__volatile__", "__volatile"]

  CxTargetMacros = ["__x86_64__", "__amd64__", "__i386__", "__aarch64__", "__arm__", "__powerpc__", "__powerpc64__",
    "__ppc64__", "__riscv", "__s390x__", "__mips__", "__sparc__", "__loongarch__", "__wasm__", "__linux__",
    "__gnu_linux__", "__ANDROID__", "__APPLE__", "__MACH__", "__FreeBSD__", "__OpenBSD__", "__NetBSD__",
    "__DragonFly__", "__sun", "__CYGWIN__", "__MINGW32__", "__MINGW64__", "_WIN32", "_WIN64", "_MSC_VER",
    "__clang__", "__GNUC__", "__unix__", "__unix", "__LP64__", "_LP64", "__ILP32__", "__ELF__", "__EMSCRIPTEN__",
    "__HAIKU__", "__STDC_VERSION__", "__SIZEOF_POINTER__", "__CHAR_UNSIGNED__"]
    ## macros the compiler defines (or not) for its target, never a header: their #if branches are known

  CxxKeywords* = ["alignas", "alignof", "auto", "bool", "break", "case", "catch", "char", "char8_t", "char16_t",
    "char32_t", "class", "co_await", "co_return", "co_yield", "concept", "const", "const_cast", "consteval",
    "constexpr", "constinit", "continue", "decltype", "default", "delete", "do", "double", "dynamic_cast", "else",
    "enum", "explicit", "export", "extern", "false", "final", "float", "for", "friend", "goto", "if", "inline", "int",
    "long", "mutable", "namespace", "new", "noexcept", "nullptr", "operator", "override", "private", "protected",
    "public", "register", "reinterpret_cast", "requires", "return", "short", "signed", "sizeof", "static",
    "static_assert", "static_cast", "struct", "switch", "template", "this", "thread_local", "throw", "true", "try",
    "typedef", "typeid", "typename", "union", "unsigned", "using", "virtual", "void", "volatile", "wchar_t", "while",
    "NULL"]
  CxxStdNames* = [
    # (name, kind, what it is) — what `std::` offers: the C++ library's headers are not read
    ("string", cxClass, "a growable sequence of characters  <string>"),
    ("vector", cxClass, "a growable array, vector<T>  <vector>"),
    ("map", cxClass, "a sorted key → value map, map<K, V>  <map>"),
    ("unordered_map", cxClass, "a hash map, unordered_map<K, V>  <unordered_map>"),
    ("set", cxClass, "a sorted set of unique keys, set<K>  <set>"),
    ("unique_ptr", cxClass, "owns an object alone and deletes it when it goes, unique_ptr<T>  <memory>"),
    ("shared_ptr", cxClass, "shares an object, deleted with its last owner, shared_ptr<T>  <memory>"),
    ("make_unique", cxFunc, "make_unique<T>(args…): a new T in a unique_ptr  <memory>"),
    ("make_shared", cxFunc, "make_shared<T>(args…): a new T in a shared_ptr  <memory>"),
    ("move", cxFunc, "move(x): x as an rvalue, to be moved from  <utility>"),
    ("forward", cxFunc, "forward<T>(x): x passed on as it came, lvalue or rvalue  <utility>"),
    ("cout", cxVar, "the standard output stream: std::cout << x  <iostream>"),
    ("cerr", cxVar, "the standard error stream (unbuffered)  <iostream>"),
    ("endl", cxFunc, "a newline, then a flush: << std::endl  <ostream>"),
    ("optional", cxClass, "a value or nothing, optional<T>  <optional>"),
    ("variant", cxClass, "one value of one of several types, variant<A, B…>  <variant>"),
    ("array", cxClass, "a fixed-size array, array<T, N>  <array>"),
    ("pair", cxClass, "two values, .first and .second, pair<A, B>  <utility>"),
    ("tuple", cxClass, "several values, std::get<I>(t)  <tuple>"),
    ("function", cxClass, "any callable of a signature, function<R(Args…)>  <functional>"),
    ("thread", cxClass, "a thread of execution: thread t(f, args…); t.join()  <thread>"),
    ("mutex", cxClass, "a lock for one thread at a time  <mutex>"),
    ("lock_guard", cxClass, "locks a mutex until the end of its scope, lock_guard<mutex>  <mutex>"),
    ("sort", cxFunc, "sort(first, last[, less]): sorts a range  <algorithm>"),
    ("find", cxFunc, "find(first, last, value): the first element equal to value, else last  <algorithm>"),
    ("begin", cxFunc, "begin(c): an iterator to the first element  <iterator>"),
    ("end", cxFunc, "end(c): an iterator past the last element  <iterator>"),
    ("size", cxFunc, "size(c): how many elements  <iterator>"),
    ("swap", cxFunc, "swap(a, b): exchanges two values  <utility>"),
    ("min", cxFunc, "min(a, b): the smaller  <algorithm>"),
    ("max", cxFunc, "max(a, b): the larger  <algorithm>")]
  CxxStdMembers = [
    # (the library types, member, its type — T U: the template's arguments, K V: a map's —, what it does); "fn:":
    # a method, what it returns
    ("string", "size", "fn:size_t", "size(): how many characters"),
    ("string", "length", "fn:size_t", "length(): how many characters"),
    ("string", "empty", "fn:bool", "empty(): no characters?"),
    ("string", "c_str", "fn:const char *", "c_str(): the characters, 0-terminated"),
    ("string", "data", "fn:char *", "data(): the characters"),
    ("string", "substr", "fn:std::string", "substr(pos, n): a part of it"),
    ("string", "find", "fn:size_t", "find(s[, pos]): where s is, else npos"),
    ("string", "rfind", "fn:size_t", "rfind(s): where s is last, else npos"),
    ("string", "append", "fn:std::string &", "append(s): s added at the end"),
    ("string", "push_back", "fn:void", "push_back(c): c added at the end"),
    ("string", "clear", "fn:void", "clear(): empty it"),
    ("string", "at", "fn:char &", "at(i): character i (checked)"),
    ("string", "starts_with", "fn:bool", "starts_with(s): does it start with s? (C++20)"),
    ("string", "ends_with", "fn:bool", "ends_with(s): does it end with s? (C++20)"),
    ("vector", "size", "fn:size_t", "size(): how many elements"),
    ("vector", "empty", "fn:bool", "empty(): no elements?"),
    ("vector", "push_back", "fn:void", "push_back(x): x added at the end"),
    ("vector", "emplace_back", "fn:T &", "emplace_back(args…): a T made at the end"),
    ("vector", "pop_back", "fn:void", "pop_back(): the last element removed"),
    ("vector", "clear", "fn:void", "clear(): every element removed"),
    ("vector", "reserve", "fn:void", "reserve(n): room for n elements"),
    ("vector", "resize", "fn:void", "resize(n): n elements"),
    ("vector", "at", "fn:T &", "at(i): element i (checked)"),
    ("vector", "front", "fn:T &", "front(): the first element"),
    ("vector", "back", "fn:T &", "back(): the last element"),
    ("vector", "data", "fn:T *", "data(): the elements, in a row"),
    ("vector", "begin", "fn:T *", "begin(): an iterator to the first element"),
    ("vector", "end", "fn:T *", "end(): an iterator past the last element"),
    ("vector", "insert", "fn:T *", "insert(pos, x): x put before pos"),
    ("vector", "erase", "fn:T *", "erase(pos): the element at pos removed"),
    ("map", "size", "fn:size_t", "size(): how many entries"),
    ("map", "empty", "fn:bool", "empty(): no entries?"),
    ("map", "find", "fn:std::pair<K, V> *", "find(k): an iterator to k's entry, else end()"),
    ("map", "count", "fn:size_t", "count(k): 1 if k is in it, else 0"),
    ("map", "contains", "fn:bool", "contains(k): is k in it? (C++20)"),
    ("map", "insert", "fn:void", "insert({k, v}): the entry added (not when k is there)"),
    ("map", "emplace", "fn:void", "emplace(k, v): the entry made in place"),
    ("map", "erase", "fn:size_t", "erase(k): k's entry removed"),
    ("map", "at", "fn:V &", "at(k): k's value (checked)"),
    ("map", "clear", "fn:void", "clear(): every entry removed"),
    ("map", "begin", "fn:std::pair<K, V> *", "begin(): an iterator to the first entry"),
    ("map", "end", "fn:std::pair<K, V> *", "end(): an iterator past the last entry"),
    ("set", "size", "fn:size_t", "size(): how many keys"),
    ("set", "empty", "fn:bool", "empty(): no keys?"),
    ("set", "insert", "fn:void", "insert(k): k added"),
    ("set", "erase", "fn:size_t", "erase(k): k removed"),
    ("set", "find", "fn:T *", "find(k): an iterator to k, else end()"),
    ("set", "count", "fn:size_t", "count(k): 1 if k is in it, else 0"),
    ("set", "contains", "fn:bool", "contains(k): is k in it? (C++20)"),
    ("set", "clear", "fn:void", "clear(): every key removed"),
    ("unique_ptr", "get", "fn:T *", "get(): the pointer it owns"),
    ("unique_ptr", "reset", "fn:void", "reset([p]): what it owns deleted (p owned instead)"),
    ("unique_ptr", "release", "fn:T *", "release(): the pointer, no longer owned"),
    ("shared_ptr", "get", "fn:T *", "get(): the pointer it shares"),
    ("shared_ptr", "reset", "fn:void", "reset(): no longer shared by this one"),
    ("shared_ptr", "use_count", "fn:long", "use_count(): how many share it"),
    ("optional", "has_value", "fn:bool", "has_value(): is there a value?"),
    ("optional", "value", "fn:T &", "value(): the value (throws when there is none)"),
    ("optional", "value_or", "fn:T", "value_or(x): the value, else x"),
    ("optional", "reset", "fn:void", "reset(): no value any more"),
    ("optional", "emplace", "fn:T &", "emplace(args…): a value made in place"),
    ("pair", "first", "T", "the first value"),
    ("pair", "second", "U", "the second value"),
    ("array", "size", "fn:size_t", "size(): how many elements"),
    ("array", "at", "fn:T &", "at(i): element i (checked)"),
    ("array", "front", "fn:T &", "front(): the first element"),
    ("array", "back", "fn:T &", "back(): the last element"),
    ("array", "data", "fn:T *", "data(): the elements, in a row"),
    ("array", "fill", "fn:void", "fill(x): every element set to x")]
  CxxStdHeaders = ["algorithm", "any", "array", "atomic", "bitset", "cassert", "cctype", "cerrno", "cfloat",
    "chrono", "climits", "cmath", "complex", "condition_variable", "cstddef", "cstdint", "cstdio", "cstdlib",
    "cstring", "ctime", "deque", "exception", "filesystem", "format", "fstream", "functional", "future",
    "initializer_list", "iomanip", "iostream", "istream", "iterator", "limits", "list", "map", "memory", "mutex",
    "new", "numeric", "optional", "ostream", "queue", "random", "ranges", "ratio", "regex", "set", "span", "sstream",
    "stack", "stdexcept", "string", "string_view", "thread", "tuple", "type_traits", "typeinfo", "unordered_map",
    "unordered_set", "utility", "variant", "vector"]

var
  cxCache: Table[string, CxFile]               # path → its index (by modification time and size, or a text stamp)
  cxCheckedAt: Table[string, float]            # path → when its stamp was last looked at (once a second is enough)
  cxDirs*: seq[string]                         # where #include <…> and "…" look (set by the editor)
  cxSysDirs*: seq[string]                      # which of them are the system's (C++: its headers are read as C,
                                               # and the C++ library's not at all)
  cxPredef*: Table[string, string]             # the C compiler's predefined macros (cc -dM -E), set by the editor
  cxPredefSet*: bool
  cxCppNow: bool                               # the text being read is C++ (__cplusplus is defined)

func cxIsCppPath*(path: string): bool =
  ## a C++ file by its name: .cpp .cc .cxx .hpp .hh .hxx …
  let e = path.splitFile.ext.toLowerAscii
  e in [".cpp", ".cc", ".cxx", ".c++", ".hpp", ".hh", ".hxx", ".h++", ".ipp", ".tpp", ".inl"]

func cxLooksCpp*(text: string): bool =
  ## a header (.h) that is C++: a line that starts a class, a namespace, a template or an access section
  for raw in text.splitLines:
    let t = raw.strip
    if t.startsWith("namespace ") or t.startsWith("template <") or t.startsWith("template<") or
       t in ["public:", "private:", "protected:"]: return true
    if t.startsWith("class ") and t.len > 6 and t[6] in IdentStartChars and not t.endsWith(";"): return true

# ── lexing ──

proc cxLex(text: string, toks: var seq[CxTok], comments: var seq[CxComment], pp: var seq[(int, string)],
           cpp = false) =
  ## C as tokens (comments and preprocessor lines apart: pp is (line, the directive with its \ continuations));
  ## cpp: C++'s raw strings R"x(…)x" too
  var i = 0
  var line = 0
  var col = 0
  var lineStart = true
  let n = text.len
  template adv() =
    if text[i] == '\n':
      inc line
      col = 0
      lineStart = true
    else: inc col
    inc i
  while i < n:
    let c = text[i]
    if c in {' ', '\t', '\r', '\f', '\v', '\n'}:
      adv()
      continue
    if c == '#' and lineStart:
      let l0 = line
      var s = ""
      while i < n:
        if text[i] == '\n':
          var k = s.len - 1
          while k >= 0 and s[k] in {' ', '\t', '\r'}: dec k
          if k >= 0 and s[k] == '\\':
            s.setLen(k)
            s.add ' '
            adv()
            continue
          break
        if text[i] == '/' and i + 1 < n and text[i + 1] == '*':
          let e = text.find("*/", i + 2)
          let stop = if e < 0: n else: e + 2
          while i < stop: adv()
          s.add ' '
          continue
        if text[i] == '/' and i + 1 < n and text[i + 1] == '/':
          while i < n and text[i] != '\n': adv()
          continue
        s.add text[i]
        adv()
      pp.add (l0, s.strip)
      continue
    let wasStart = lineStart
    lineStart = false
    let l0 = line
    let c0 = col
    if c == '/' and i + 1 < n and text[i + 1] == '/':
      var s = ""
      while i < n and text[i] != '\n':
        s.add text[i]
        adv()
      comments.add CxComment(a: l0, b: l0, text: s, lone: wasStart)
      continue
    if c == '/' and i + 1 < n and text[i + 1] == '*':
      let e = text.find("*/", i + 2)
      let stop = if e < 0: n else: e + 2
      let s = text[i ..< stop]
      while i < stop: adv()
      comments.add CxComment(a: l0, b: line, text: s, lone: wasStart)
      continue
    if cpp and c == 'R' and i + 1 < n and text[i + 1] == '"':
      let p = text.find('(', i + 2)
      let close = if p > 0 and p - i < 20: text.find(")" & text[i + 2 ..< p] & "\"", p + 1) else: -1
      if close > 0:
        let st = i
        let stop = close + p - i
        while i < stop: adv()
        toks.add CxTok(kind: ctStr, text: text[st ..< i], line: l0, col: c0)
        continue
    if c in {'"', '\''}:
      let st = i
      adv()
      while i < n and text[i] != c and text[i] != '\n':
        if text[i] == '\\' and i + 1 < n: adv()
        adv()
      if i < n and text[i] == c: adv()
      toks.add CxTok(kind: (if c == '"': ctStr else: ctChar), text: text[st ..< i], line: l0, col: c0)
      continue
    if c in Digits or (c == '.' and i + 1 < n and text[i + 1] in Digits):
      let st = i
      while i < n and (text[i] in {'0'..'9', 'a'..'z', 'A'..'Z', '_', '.', '\''} or
                       (text[i] in {'+', '-'} and text[i - 1] in {'e', 'E', 'p', 'P'})):
        adv()
      toks.add CxTok(kind: ctNum, text: text[st ..< i], line: l0, col: c0)
      continue
    if c in IdentStartChars or ord(c) >= 128:
      let st = i
      while i < n and (text[i] in IdentChars or ord(text[i]) >= 128): adv()
      toks.add CxTok(kind: ctWord, text: text[st ..< i], line: l0, col: c0)
      continue
    var len = 1
    for p in ["...", "->", "++", "--", "<<", ">>", "<=", ">=", "==", "!=", "&&", "||", "::"]:
      if text.continuesWith(p, i):
        len = p.len
        break
    let st = i
    for _ in 1 .. len: adv()
    toks.add CxTok(kind: ctPunct, text: text[st ..< i], line: l0, col: c0)

proc cxCleanComment*(t: string): string =
  ## a comment's text without its markers (/* */ // /// /** and a leading * on each line)
  var outp: seq[string]
  for raw in t.splitLines:
    var s = raw.strip
    for pre in ["/**<", "/*!<", "///<", "//!<", "/**", "/*!", "/*", "///", "//!", "//"]:
      if s.startsWith(pre):
        s = s[pre.len .. ^1]
        break
    if s.endsWith("*/"): s = s[0 ..< s.len - 2]
    s = s.strip
    if s.startsWith("* ") or s == "*": s = s[1 .. ^1].strip
    elif s.startsWith("*") and not s.startsWith("*/"): s = s[1 .. ^1].strip
    outp.add s
  while outp.len > 0 and outp[0].len == 0: outp.delete(0)
  while outp.len > 0 and outp[^1].len == 0: outp.setLen(outp.len - 1)
  outp.join("\n")

# ── declarations ──

proc cxIsTypeStart(toks: seq[CxTok], k: int, typedefs: HashSet[string]): bool =
  ## can a declaration start with toks[k]: a type word, a qualifier, struct/union/enum, or a typedef name
  if k >= toks.len or toks[k].kind != ctWord: return false
  let w = toks[k].text
  w in CxTypeWords or w in typedefs or w.endsWith("_t")

func cxNoise(w: string): bool =
  ## words that are not part of the C a reader cares about: attributes, export and calling macros
  w.startsWith("__attribute") or w in ["__asm__", "__asm", "asm", "__declspec", "__THROW", "__wur", "__nonnull",
    "__attr_dealloc", "__attr_dealloc_free", "__THROWNL", "__NTH", "__LEAF", "__BEGIN_DECLS", "__END_DECLS",
    "__attribute_pure__", "__attribute_malloc__", "__attribute_warn_unused_result__", "__attribute_deprecated__",
    "__dead2", "__pure2", "__printflike", "__scanflike", "_GLIBCXX_NOTHROW", "__MINGW_NOTHROW", "WINAPI",
    "APIENTRY", "CALLBACK", "__cdecl", "__stdcall", "__fastcall", "__inline_always", "__extern_always_inline",
    "__extern_inline", "__fortify_function", "__always_inline", "__attribute_artificial__"]

func cxTypeText(toks: seq[CxTok], a, b: int): string =
  ## tokens as a type, spaced the way C is written: "const char *", "struct point"
  for k in a ..< b:
    let t = toks[k].text
    if t in ["restrict", "__restrict", "__restrict__"] or cxNoise(t): continue
    if t == "*": result.add (if result.len > 0 and result[^1] != '*': " *" else: "*")
    elif t in ["[", "]", "(", ")", ","]: result.add t
    else:
      if result.len > 0 and result[^1] notin {'(', '['}: result.add ' '
      result.add t

func cxSkipGroup(toks: seq[CxTok], k: int): int =
  ## past the bracket group that starts at toks[k] ( ( [ { ): the index after its closing one
  var d = 0
  var i = k
  while i < toks.len:
    let t = toks[i].text
    if toks[i].kind == ctPunct:
      if t in ["(", "[", "{"]: inc d
      elif t in [")", "]", "}"]:
        dec d
        if d == 0: return i + 1
    inc i
  toks.len

func cxTypeEnd(toks: seq[CxTok], a, b: int): int =
  ## where a declaration's type ends and its first declarator starts: `struct list *next` → at `*`, `int x = 1` → at
  ## `x`, `int (*fn)(int)` → at `(`, `int f(void)` → at `f`; b when there is no declarator (`struct list;`)
  var j = a
  var lastWord = -1
  var words = 0
  while j < b:
    let x = toks[j]
    if x.kind == ctWord and cxNoise(x.text):
      j = if j + 1 < b and toks[j + 1].text == "(": cxSkipGroup(toks, j + 1) else: j + 1
      continue
    if x.kind == ctWord:
      lastWord = j
      inc words
    if x.text in ["*", "[", "=", ",", ";", ":", "("]: break
    inc j
  if j < b and toks[j].text == "*": return j
  if j < b and toks[j].text == "(" and j + 1 < b and toks[j + 1].text == "*": return j
  if j < b and toks[j].text == "(" and j + 1 < b and toks[j + 1].text == "(" and lastWord == j - 1 and
     lastWord - 1 > a and toks[lastWord - 1].kind == ctWord:
    return lastWord - 1                         # void name _((int a)): a prototype through a portability macro
  if lastWord > a:
    # struct list; — a tag, no declarator
    if words == 2 and toks[a].text in ["struct", "union", "enum"] and (j >= b or toks[j].text == ";"): return b
    return lastWord
  j

func cxDimsAt(toks: seq[CxTok], ni, b: int): (string, string) =
  ## after a declarator's name: its array dimensions as written (`[SIZE][2]`) and a bit-field's width
  var k = ni + 1
  while k < b and toks[k].text == "[":
    var d = 0
    while k < b:
      let t = toks[k].text
      result[0].add t
      if t == "[": inc d
      elif t == "]":
        dec d
        if d == 0:
          inc k
          break
      inc k
  if k + 1 < b and toks[k].text == ":" and toks[k + 1].kind == ctNum: result[1] = toks[k + 1].text

func cxDeclarators(toks: seq[CxTok], a, b: int): seq[(int, string, int)] =
  ## the declarators of toks[a ..< b] after the type: (index of the name, the pointer stars and array part, the
  ## index just past it) — `*p = 1, q[3], (*fn)(int)`
  var k = a
  while k < b:
    var stars = ""
    while k < b and toks[k].text in ["*", "const", "volatile", "restrict", "__restrict"]:
      if toks[k].text == "*": stars.add "*"
      inc k
    var nameAt = -1
    if k < b and toks[k].text == "(" and k + 1 < b and toks[k + 1].text == "*":
      # (*name)(…): a function pointer
      var j = k + 1
      while j < b and toks[j].text in ["*", "const"]: inc j
      if j < b and toks[j].kind == ctWord: nameAt = j
      stars.add "(*)"
      k = cxSkipGroup(toks, k)
      if k < b and toks[k].text == "(": k = cxSkipGroup(toks, k)
    elif k < b and toks[k].kind == ctWord and not cxNoise(toks[k].text):
      nameAt = k
      inc k
    while k < b and toks[k].text == "[":
      stars.add "*"
      k = cxSkipGroup(toks, k)
    # what follows the name up to the next top-level comma: an initializer, a bit-field width, attributes
    var d = 0
    while k < b:
      let t = toks[k].text
      if toks[k].kind == ctPunct and t in ["(", "[", "{"]: inc d
      elif toks[k].kind == ctPunct and t in [")", "]", "}"]: dec d
      elif t == "," and d == 0: break
      inc k
    if nameAt >= 0: result.add (nameAt, stars, k)
    inc k                                         # past the comma

func cxParams(toks: seq[CxTok], a, b: int): (seq[CxParam], bool) =
  ## a parameter list's parameters (toks[a ..< b] inside the parentheses); `void` alone: none; `...`: varargs
  var parts: seq[(int, int)]
  var d = 0
  var st = a
  for k in a ..< b:
    let t = toks[k].text
    if toks[k].kind == ctPunct and t in ["(", "["]: inc d
    elif toks[k].kind == ctPunct and t in [")", "]"]: dec d
    elif t == "," and d == 0:
      parts.add (st, k)
      st = k + 1
  if b > st: parts.add (st, b)
  for (x, y) in parts:
    if y - x == 1 and toks[x].text == "void": continue
    if y - x == 1 and toks[x].text == "...":
      result[1] = true
      continue
    # the name: the last word that is not a type word, before any [ ] (a function pointer: (*name))
    var nameAt = -1
    var e = y
    for k in x ..< y:
      if toks[k].text == "[":
        e = k
        break
    for k in countdown(e - 1, x):
      if toks[k].kind == ctWord and toks[k].text notin CxTypeWords and k > x:
        nameAt = k
        break
      if toks[k].text == ")": break
    for k in x ..< y:
      if toks[k].text == "(" and k + 1 < y and toks[k + 1].text == "*" and k + 2 < y and toks[k + 2].kind == ctWord:
        nameAt = k + 2
    var typ = ""
    if nameAt > x:
      typ = cxTypeText(toks, x, nameAt)
      if e < y: typ.add "*"
    else: typ = cxTypeText(toks, x, y)
    result[0].add CxParam(name: (if nameAt >= 0: toks[nameAt].text else: ""), typ: typ.strip,
                          line: (if nameAt >= 0: toks[nameAt].line else: -1),
                          col: (if nameAt >= 0: toks[nameAt].col else: -1))

proc cxDefinedKnown(name: string): int =
  ## is `name` defined — 1, 0, or -1 when only the preprocessor would know. Known: __cplusplus (defined when this
  ## reads C++), __STDC_HOSTED__, and the compiler's own target macros (__x86_64__, __linux__, _WIN32 …) once
  ## cxPredef is set
  case name
  of "__cplusplus": (if cxCppNow: 1 else: 0)
  of "__STDC_HOSTED__", "__STDC__": 1
  else:
    if cxPredefSet and name in CxTargetMacros: (if name in cxPredef: 1 else: 0) else: -1

proc cxValueKnown(name: string): int =
  ## `#if name`: 1 when known nonzero, 0 when known zero (or not defined), -1 not known
  let d = cxDefinedKnown(name)
  if d <= 0: return d
  if name in cxPredef:
    try: return (if parseInt(cxPredef[name].strip(chars = {'L', 'U', 'l', 'u', ' '})) != 0: 1 else: 0)
    except ValueError: return 1
  1

func cxTopSplit(t, op: string): seq[string] =
  ## t split at `op` outside parentheses
  var d = 0
  var st = 0
  var i = 0
  while i < t.len:
    if t[i] == '(': inc d
    elif t[i] == ')': dec d
    elif d == 0 and t.continuesWith(op, i):
      result.add t[st ..< i]
      i += op.len
      st = i
      continue
    inc i
  result.add t[st .. ^1]

proc cxCond(c: string): int =
  ## a #if condition known without running the preprocessor — 0 false, 1 true, -1 not known: `0`, `1`,
  ## `defined X` and `X` for the macros cxDefinedKnown knows, with !, &&, || and parentheses
  var t = c.strip
  # (a comment left on the line)
  let cm = t.find("/*")
  if cm >= 0: t = t[0 ..< cm].strip
  if t.len == 0: return -1
  proc unwrap(x: string): string =
    ## (a) → a, but not (a) && (b)
    result = x.strip
    while result.len >= 2 and result[0] == '(' and result[^1] == ')':
      var d = 0
      var closesAtEnd = true
      for i, ch in result:
        if ch == '(': inc d
        elif ch == ')':
          dec d
          if d == 0 and i < result.high:
            closesAtEnd = false
            break
      if not closesAtEnd: break
      result = result[1 .. ^2].strip
  t = unwrap(t)
  let ors = cxTopSplit(t, "||")
  if ors.len > 1:
    result = 0
    for o in ors:
      let v = cxCond(o)
      if v == 1: return 1
      if v < 0: result = -1
    return
  let ands = cxTopSplit(t, "&&")
  if ands.len > 1:
    result = 1
    for a in ands:
      let v = cxCond(a)
      if v == 0: return 0
      if v < 0: result = -1
    return
  var neg = false
  if t.startsWith("!") and not t.startsWith("!="):
    neg = true
    t = unwrap(t[1 .. ^1])
  var v = -1
  if t.startsWith("defined") and t.len > 7 and t[7] in {' ', '(', '\t'}:
    v = cxDefinedKnown(t[7 .. ^1].strip(chars = {' ', '(', ')', '\t'}))
  elif t == "0": v = 0
  elif t == "1": v = 1
  elif t.len > 0 and t.allCharsInSet(IdentChars): v = cxValueKnown(t)
  elif cxCppNow and t.startsWith("__cplusplus") and t[11 .. ^1].strip.len > 0 and t[11 .. ^1].strip[0] in {'>', '<', '=', '!'}:
    # C++: the version as C++17's (201703L)
    let r = t[11 .. ^1].strip
    var op = ""
    while op.len < r.len and r[op.len] in {'>', '<', '=', '!'}: op.add r[op.len]
    try:
      let x = parseInt(r[op.len .. ^1].strip.strip(chars = {'L', 'l', 'U', 'u', ' '}))
      const ver = 201703
      v = case op
          of ">=": ord(ver >= x)
          of ">": ord(ver > x)
          of "<=": ord(ver <= x)
          of "<": ord(ver < x)
          of "==": ord(ver == x)
          of "!=": ord(ver != x)
          else: -1
    except ValueError: v = -1
  elif t.startsWith("__cplusplus") and t[11 .. ^1].strip.len > 0 and t[11 .. ^1].strip[0] in {'>', '='}: v = 0
  if v >= 0 and neg: v = 1 - v
  v

proc cxInactive(pp: seq[(int, string)]): seq[(int, int)] =
  ## the parts that #if 0, #ifdef __cplusplus and their #else leave out: (a, b), the lines after a and before b.
  ## Every other #if is read whole, all its branches
  type Frame = object
    known, taken, skip, outer: bool
    start: int
  var st: seq[Frame]
  for (l, d) in pp:
    let t = d[1 .. ^1].strip
    var w = 0
    while w < t.len and t[w] in IdentChars: inc w
    let word = t[0 ..< w]
    let rest = t[w .. ^1].strip
    case word
    of "if", "ifdef", "ifndef":
      if st.len > 0 and (st[^1].skip or st[^1].outer):
        st.add Frame(outer: true)
        continue
      let c = case word
        of "ifdef": cxDefinedKnown(rest)
        of "ifndef": (let d = cxDefinedKnown(rest); if d < 0: -1 else: 1 - d)
        else: cxCond(rest)
      st.add Frame(known: c >= 0, taken: c == 1, skip: c == 0, start: l)
    of "elif", "else":
      if st.len == 0 or st[^1].outer: continue
      var fr = st[^1]
      if fr.skip: result.add (fr.start, l)
      let c = if word == "else": 1 else: cxCond(rest)
      if fr.known and fr.taken: fr.skip = true
      elif c == 0: fr.skip = true
      else:
        fr.skip = false
        if c == 1 and fr.known: fr.taken = true
        else: fr.known = false
      fr.start = l
      st[^1] = fr
    of "endif":
      if st.len == 0: continue
      let fr = st.pop()
      if not fr.outer and fr.skip: result.add (fr.start, l)
    else: discard
  for fr in st:
    if not fr.outer and fr.skip: result.add (fr.start, high(int))
  result.sort(proc(x, y: (int, int)): int = cmp(x[0], y[0]))

proc cxUnbalanced(pp: seq[(int, string)], toks: seq[CxTok], gone: var seq[(int, int)]) =
  ## #if branches that open or close braces — `#ifdef X  if (a) {  #else  if (b) {  #endif` —: only the first is
  ## read (as ctags does), or the function's body would never close. Inner #ifs first
  type Chain = object
    marks: seq[int]                     # the lines of its #if, #elif …, #else and #endif
    depth: int
    closed: bool
  var chains: seq[Chain]
  var open: seq[int]
  for (l, d) in pp:
    let t = d[1 .. ^1].strip
    var w = 0
    while w < t.len and t[w] in IdentChars: inc w
    case t[0 ..< w]
    of "if", "ifdef", "ifndef":
      chains.add Chain(marks: @[l], depth: open.len)
      open.add chains.high
    of "elif", "else":
      if open.len > 0: chains[open[^1]].marks.add l
    of "endif":
      if open.len > 0:
        let c = open.pop()
        chains[c].marks.add l
        chains[c].closed = true
    else: discard
  var order: seq[int]
  for i, c in chains:
    if c.closed and c.marks.len >= 3: order.add i         # (two branches or more)
  if order.len == 0: return
  order.sort(proc(x, y: int): int = cmp(chains[y].depth, chains[x].depth))
  template isGone(l: int): bool =
    var r = false
    for (ga, gb) in gone:
      if l > ga and l < gb: r = true
    r
  template covered(a, b: int): bool =
    var r = false
    for (ga, gb) in gone:
      if ga <= a and gb >= b: r = true
    r
  for ci in order:
    let m = chains[ci].marks
    var branches: seq[(int, int, int)]       # (from, to, what its braces add)
    for k in 0 ..< m.len - 1:
      let (a, b) = (m[k], m[k + 1])
      if covered(a, b): continue
      var lo = 0
      var hi = toks.len
      while lo < hi:                         # the first token after line a
        let mid = (lo + hi) div 2
        if toks[mid].line <= a: lo = mid + 1 else: hi = mid
      var dl = 0
      var i = lo
      while i < toks.len and toks[i].line < b:
        if toks[i].kind == ctPunct and toks[i].text in ["{", "}"] and not isGone(toks[i].line):
          dl += (if toks[i].text == "{": 1 else: -1)
        inc i
      branches.add (a, b, dl)
    if branches.len < 2: continue
    # (read together, alternatives that each open or close a brace add up: one too many)
    var opens = false
    for x in branches:
      if x[2] != 0: opens = true
    if opens:
      for x in branches[1 .. ^1]: gone.add (x[0], x[1])

proc cxDocFor(comments: seq[CxComment], line: int, endLine = -1): string =
  ## the comment that documents what starts on `line`: the block right above it (ending on the line before), or
  ## one after it on its last line
  var lo = 0
  var hi = comments.high
  var best = -1
  while lo <= hi:                                 # the last comment that ends before `line`
    let m = (lo + hi) div 2
    if comments[m].b < line:
      best = m
      lo = m + 1
    else: hi = m - 1
  if best >= 0 and comments[best].b == line - 1 and comments[best].lone:
    # (several // lines in a row are one comment)
    var a = best
    while a > 0 and comments[a - 1].b == comments[a].a - 1 and comments[a - 1].lone and
          comments[a - 1].text.startsWith("//") and comments[a].text.startsWith("//"): dec a
    var parts: seq[string]
    for k in a .. best: parts.add comments[k].text
    let t = cxCleanComment(parts.join("\n"))
    if "Copyright" notin t and "License" notin t: return t
  let el = if endLine >= 0: endLine else: line
  for k in max(0, best) .. min(comments.high, best + 3):
    if k >= 0 and comments[k].a == el and not comments[k].lone: return cxCleanComment(comments[k].text)

# ── C++: its tokens folded so that C's reading of declarations reads it: `std::map<K, V>`, `Point::norm`,
#    `operator==`, `~Circle` one word each, attributes and specifiers that change no type left out, a template's
#    header one token ──

func cxxSplit*(q: string): seq[string] =
  ## a qualified name's parts, split at the `::` outside template arguments: "a::B<c::d>::e" → a, B<c::d>, e
  var d = 0
  var st = 0
  var i = 0
  while i < q.len:
    if q[i] == '<': inc d
    elif q[i] == '>': dec d
    elif d == 0 and q.continuesWith("::", i):
      result.add q[st ..< i]
      i += 2
      st = i
      continue
    inc i
  result.add q[st .. ^1]

func cxxNoArgs*(t: string): string =
  ## a name without template arguments: "Box<int>" → "Box", "a::B<T>::c" → "a::B::c" (not an operator's `<`)
  if t.startsWith("operator") or "<" notin t: return t
  var d = 0
  for i, ch in t:
    if ch == '<' and not t.continuesWith("operator", max(0, i - 8)): inc d
    elif ch == '>' and d > 0: dec d
    elif d == 0: result.add ch

func cxxArgs*(t: string): seq[string] =
  ## the template arguments of a type's last part: "std::map<std::string, Box<int>> &" → std::string, Box<int>
  let parts = cxxSplit(t)
  let last = parts[^1]
  let a = last.find('<')
  if a < 0: return
  var d = 0
  var st = a + 1
  for i in a ..< last.len:
    let ch = last[i]
    if ch in {'<', '('}: inc d
    elif ch in {'>', ')'}:
      dec d
      if d == 0:
        if last[st ..< i].strip.len > 0: result.add last[st ..< i].strip
        return
    elif ch == ',' and d == 1:
      result.add last[st ..< i].strip
      st = i + 1

func cxxQual*(s: CxSym): string =
  ## a C++ declaration's qualified name: "geo::Point"
  if s.scope.len > 0: s.scope & "::" & s.name else: s.name

func cxxRender(toks: seq[CxTok], a, b: int): string =
  ## tokens as one type or expression, spaced the way C++ is written: "std::map<std::string, int>", "new Foo(1, 2)"
  for k in a ..< b:
    let t = toks[k].text
    if result.len > 0 and t.len > 0 and (t[0] in IdentChars or t[0] in {'"', '\''}) and
       (result[^1] in IdentChars or result[^1] in {'"', '\''}):
      result.add ' '
    if t == "=":
      result.add " = "
      continue
    result.add t
    if t == ",": result.add ' '

func cxxAngle(toks: seq[CxTok], i: int): int =
  ## toks[i] is `<`: the index past the `>` that closes it when it opens a template's arguments (`vector<int>`,
  ## `map<K, vector<V>>`, `function<void(int)>`), else -1 (`i < n`, `a < b && c > d`)
  var d = 0
  var p = 0
  var k = i
  while k < toks.len and k - i < 160:
    let t = toks[k]
    if t.kind in {ctTemplate, ctStr, ctChar}: return -1     # (ctTemplate first: the set's type)
    if t.kind == ctPunct:
      case t.text
      of "<": inc d
      of ">", ">>":
        if p == 0:
          d -= t.text.len
          if d < 0: return -1
          if d == 0:
            let nx = if k + 1 < toks.len: toks[k + 1] else: CxTok(kind: ctPunct, text: ";")
            if nx.kind == ctWord or nx.text in ["::", "(", ")", "{", "}", "*", "&", "&&", ",", ";", ">", ">>", "...",
                                                "[", "]", "=", ":"]:
              return k + 1
            return -1
      of "(":
        inc p
      of ")":
        if p == 0: return -1
        dec p
      of "::", ",", "*", "&", "...", "[", "]": discard
      of "&&", "-", "+":
        if p == 0 and t.text == "&&": return -1
      else:
        if p == 0 or t.text in [";", "{", "}"]: return -1
    inc k
  -1

func cxxOperator(toks: seq[CxTok], i: int): (string, int) =
  ## toks[i] is `operator`: the operator's name (`operator==`, `operator()`, `operator new[]`, `operator bool`)
  ## and the index past it
  var j = i + 1
  var s = "operator"
  let n = toks.len
  if j >= n: return (s, j)
  let x = toks[j]
  if x.text == "(" and j + 1 < n and toks[j + 1].text == ")":
    s.add "()"
    j += 2
  elif x.text == "[" and j + 1 < n and toks[j + 1].text == "]":
    s.add "[]"
    j += 2
  elif x.kind == ctWord and x.text in ["new", "delete"]:
    s.add " " & x.text
    inc j
    if j + 1 < n and toks[j].text == "[" and toks[j + 1].text == "]":
      s.add "[]"
      j += 2
  elif x.kind == ctPunct:
    while j < n and toks[j].kind == ctPunct and toks[j].text != "(" and j - i <= 3:
      s.add toks[j].text
      inc j
  elif x.kind == ctStr:
    s.add x.text
    inc j
    if j < n and toks[j].kind == ctWord:
      s.add toks[j].text
      inc j
  else:
    let a = j
    while j < n and toks[j].text != "(" and toks[j].text notin [";", "{", ")"] and j - i < 8: inc j
    s.add " " & cxxRender(toks, a, j)
  (s, j)

func cxxTemplateNames*(header: string): seq[string] =
  ## a template header's parameters' names: "typename T, int N = 3, class... Ts" → T, N, Ts
  var d = 0
  var st = 0
  var parts: seq[string]
  for i, ch in header:
    if ch in {'<', '(', '['}: inc d
    elif ch in {'>', ')', ']'}: dec d
    elif ch == ',' and d == 0:
      parts.add header[st ..< i]
      st = i + 1
  parts.add header[st .. ^1]
  for p in parts:
    var q = p
    let eq = q.find('=')
    if eq >= 0: q = q[0 ..< eq]
    let ws = q.replace("...", " ").replace("&", " ").replace("*", " ").splitWhitespace
    if ws.len >= 2 and ws[^1] notin ["typename", "class"]: result.add ws[^1]

proc cxxFold(toks: seq[CxTok]): seq[CxTok] =
  ## C++'s tokens as C's reading wants them (see above). Every token gets where its name is (nameLine, nameCol)
  let n = toks.len
  var i = 0
  template add(t0: CxTok) =
    var t = t0
    if t.nameLine == 0 and t.nameCol == 0:
      t.nameLine = t.line
      t.nameCol = t.col
    result.add t
  while i < n:
    let t = toks[i]
    if t.kind == ctPunct and t.text == "[" and i + 1 < n and toks[i + 1].text == "[":
      i = cxSkipGroup(toks, i)                        # [[nodiscard]]
      continue
    if t.kind == ctWord:
      case t.text
      of "alignas", "decltype", "noexcept", "__declspec":
        if i + 1 < n and toks[i + 1].text == "(":
          let e = cxSkipGroup(toks, i + 1)
          if t.text == "decltype":
            add CxTok(kind: ctWord, text: cxxRender(toks, i, e), line: t.line, col: t.col)
          i = e
        else: inc i
        continue
      of "throw":
        if result.len > 0 and result[^1].text == ")" and i + 1 < n and toks[i + 1].text == "(":
          i = cxSkipGroup(toks, i + 1)               # void f() throw(): a dynamic exception specification
          continue
      of "override", "final":
        if result.len > 0 and (result[^1].text in [")", "const", "volatile", "&", "&&"] or
                               (result.len > 1 and result[^2].text in ["class", "struct"])):
          inc i
          continue
      of "constexpr", "consteval", "constinit", "explicit", "virtual", "mutable", "thread_local", "typename",
         "__forceinline", "__inline_always":
        inc i
        continue
      of "template":
        if i + 1 < n and toks[i + 1].text == "<":
          # template <typename T, int N = 3>: one token, the parameters as written
          var d = 0
          var p = 0
          var k = i + 1
          while k < n:
            let x = toks[k].text
            if x == "(": inc p
            elif x == ")": dec p
            elif p == 0 and x == "<": inc d
            elif p == 0 and x in [">", ">>"]:
              d -= x.len
              if d <= 0: break
            elif x in [";", "{"]: break
            inc k
          add CxTok(kind: ctTemplate, text: cxxRender(toks, i + 2, min(k, n)), line: t.line, col: t.col)
          i = min(k + 1, n)
          continue
        inc i                                         # obj.template get<T>(): a hint, nothing more
        continue
      of "extern":
        if i + 2 < n and toks[i + 1].kind == ctStr and toks[i + 2].text != "{":
          add t                                       # extern "C" int f(void); — the linkage left out
          i += 2
          continue
      else: discard
      # a function-like macro that makes a type — `PREFIX(node) *x` —: one word
      if t.text.len > 1 and t.text[0] in {'A'..'Z', '_'} and t.text.allCharsInSet({'A'..'Z', '0'..'9', '_'}) and
         i + 1 < n and toks[i + 1].text == "(":
        let e = cxSkipGroup(toks, i + 1)
        if e < n and toks[e].line == toks[e - 1].line and
           (toks[e].kind == ctWord or toks[e].text in ["*", "&", "&&", "::"]):
          add CxTok(kind: ctWord, text: cxxRender(toks, i, e), line: t.line, col: t.col)
          i = e
          continue
      # a name: qualified (a::b::c), with template arguments (Box<T>), an operator, a destructor
      var text = t.text
      var nl = t.line
      var nc = t.col
      var j = i + 1
      if t.text == "operator":
        (text, j) = cxxOperator(toks, i)
      while j < n:
        if toks[j].kind == ctPunct and toks[j].text == "<" and not text.startsWith("operator"):
          let e = cxxAngle(toks, j)
          if e > 0:
            text.add cxxRender(toks, j, e)
            j = e
            continue
        if toks[j].text == "::" and j + 1 < n and toks[j + 1].line == toks[j].line:   # (`a::` being typed: not
          let x = toks[j + 1]                                                         # the next line's word)
          if x.kind == ctWord and x.text == "operator":
            let (op, e) = cxxOperator(toks, j + 1)
            text.add "::" & op
            nl = x.line
            nc = x.col
            j = e
            break
          if x.kind == ctWord and x.text != "template":
            text.add "::" & x.text
            nl = x.line
            nc = x.col
            j += 2
            continue
          if x.text == "~" and j + 2 < n and toks[j + 2].kind == ctWord:
            text.add "::~" & toks[j + 2].text
            nl = x.line
            nc = x.col
            j += 3
            continue
        break
      add CxTok(kind: ctWord, text: text, line: t.line, col: t.col, nameLine: nl, nameCol: nc)
      i = j
      continue
    if t.kind == ctPunct and t.text == "::" and i + 1 < n and toks[i + 1].kind == ctWord and
       (result.len == 0 or result[^1].kind != ctWord):
      inc i                                           # ::name — the global one: the name
      continue
    if t.kind == ctPunct and t.text == "~" and i + 2 < n and toks[i + 1].kind == ctWord and toks[i + 2].text == "(" and
       (result.len == 0 or (result[^1].kind notin {ctWord, ctNum, ctStr, ctChar} and result[^1].text notin [")", "]"])):
      add CxTok(kind: ctWord, text: "~" & toks[i + 1].text, line: t.line, col: t.col)   # ~Circle(): a destructor
      i += 2
      continue
    add t
    inc i

proc cxInactiveIn*(text: string, cpp = false): seq[(int, int)] =
  ## what #if 0, #ifdef __cplusplus … leave out of a C text (C++: #ifndef __cplusplus …): (first line, last line)
  ## — for the editor to dim, with whichever engine answers for the file
  var toks: seq[CxTok]
  var comments: seq[CxComment]
  var pp: seq[(int, string)]
  let was = cxCppNow
  cxCppNow = cpp
  defer: cxCppNow = was
  cxLex(text, toks, comments, pp, cpp)
  for (a, b) in cxInactive(pp):
    if b - 1 >= a + 1: result.add (a + 1, b - 1)

proc cxParse*(text, path: string, full = true, cpp = false): CxFile =
  ## one C file's declarations (not the ones of the files it includes); full: a prototype's parameters too (the
  ## file being edited: they are answered for; a header read for it: they are not needed). cpp: read as C++
  result = CxFile(path: path, cpp: cpp)
  let f = result
  let wasCpp = cxCppNow
  cxCppNow = cpp
  defer: cxCppNow = wasCpp
  var toks: seq[CxTok]
  var comments: seq[CxComment]
  var pp: seq[(int, string)]
  cxLex(text, toks, comments, pp, cpp)
  f.lines = text.splitLines
  var gone = cxInactive(pp)
  # (what the preprocessor leaves out, for the editor to dim — not the branches cxUnbalanced sets aside to read one)
  for (a, b) in gone:
    if b - 1 >= a + 1: f.inactive.add (a + 1, b - 1)
  f.inactive.sort(proc(x, y: (int, int)): int = cmp(x[0], y[0]))
  cxUnbalanced(pp, toks, gone)
  if gone.len > 1:
    gone.sort(proc(x, y: (int, int)): int = cmp(x[0], y[0]))
    var merged = @[gone[0]]
    for g in gone[1 .. ^1]:
      if g[0] < merged[^1][1]: merged[^1][1] = max(merged[^1][1], g[1])     # (one inside another)
      else: merged.add g
    gone = merged
  if gone.len > 0:
    # (tokens, comments and directives are in line order; the parts left out too)
    proc keep[T](xs: var seq[T], lineOf: proc(x: T): int) =
      var r = 0
      var o = 0
      for i in 0 ..< xs.len:
        let l = lineOf(xs[i])
        while r < gone.len and l >= gone[r][1]: inc r
        if r < gone.len and l > gone[r][0] and l < gone[r][1]: continue
        if o != i: xs[o] = xs[i]
        inc o
      xs.setLen(o)
    keep(toks, proc(x: CxTok): int = x.line)
    keep(comments, proc(x: CxComment): int = x.a)
    keep(pp, proc(x: (int, string)): int = x[0])
  if cpp: toks = cxxFold(toks)
  var typedefs: HashSet[string]
  # preprocessor: #define, #include
  for (l, d) in pp:
    let t = d[1 .. ^1].strip
    if t.startsWith("include"):
      let next = t.startsWith("include_next")             # (GCC's: the same name, from the folders after this one's)
      let r = t[(if next: 12 else: 7) .. ^1].strip
      if r.len >= 3 and r[0] in {'<', '"'}:
        let close = r.find((if r[0] == '<': '>' else: '"'), 1)
        if close > 0: f.includes.add ((if next: "next" else: "") & r[0 .. close], l)
    elif t.startsWith("define"):
      let r = t[6 .. ^1].strip
      var j = 0
      while j < r.len and r[j] in IdentChars: inc j
      if j == 0: continue
      var s = CxSym(name: r[0 ..< j], kind: cxMacro, line: l, endLine: l, text: "#define " & r)
      let c = f.lines[min(l, f.lines.high)].find(s.name)
      s.col = max(0, c)
      if j < r.len and r[j] == '(':
        let e = r.find(')', j)
        if e > j:
          for p in r[j + 1 ..< e].split(','):
            if p.strip == "...": s.varargs = true
            elif p.strip.len > 0: s.params.add CxParam(name: p.strip)
      if s.text.len > 160: s.text = s.text[0 ..< 159] & "…"
      s.doc = cxDocFor(comments, l)
      f.syms.add s
  # declarations, at file level (and inside extern "C" { … })
  let base = extractFilename(path)
  proc anonName(word: string, line: int): string =
    ## an anonymous struct's name, unique across the files read together
    "(anonymous " & word & " at " & base & ":" & $(line + 1) & ")"
  proc addSym(s0: CxSym) =
    var s = s0
    if s.doc.len == 0: s.doc = cxDocFor(comments, s.line, s.endLine)
    f.syms.add s
  proc parseMembers(a, b: int, owner: string, kind: CxKind) =
    ## a struct's (or union's) members, toks[a ..< b] inside the braces; an enum's constants
    if kind == cxEnum:
      var k = a
      while k < b:
        if toks[k].kind == ctWord:
          addSym(CxSym(name: toks[k].text, kind: cxEnumConst, line: toks[k].line, col: toks[k].col, endLine: toks[k].line,
                       owner: owner, typ: "enum " & owner, text: toks[k].text & " (" & owner & ")"))
          # its value as written: after `=`, to the next comma
          if k + 1 < b and toks[k + 1].text == "=":
            var j = k + 2
            var dd = 0
            var v = ""
            while j < b:
              let tj = toks[j].text
              if toks[j].kind == ctPunct and tj in ["(", "[", "{"]: inc dd
              elif toks[j].kind == ctPunct and tj in [")", "]", "}"]: dec dd
              elif tj == "," and dd == 0: break
              v.add (if v.len > 0: " " else: "") & tj
              inc j
            f.syms[^1].init = v
          # past its value, to the next comma
          var d = 0
          while k < b:
            let t = toks[k].text
            if toks[k].kind == ctPunct and t in ["(", "[", "{"]: inc d
            elif toks[k].kind == ctPunct and t in [")", "]", "}"]: dec d
            elif t == "," and d == 0: break
            inc k
        inc k
      return
    var k = a
    var st = a
    while k < b:
      let t = toks[k]
      if t.kind == ctPunct and t.text == "{":
        k = cxSkipGroup(toks, k)
        continue
      if t.kind == ctPunct and t.text == ";":
        if k > st:
          # a member: type then declarators; a nested struct { … } name; flattens when it has no name
          var tEnd = st
          var nestedAt = -1
          if toks[st].text in ["struct", "union"]:
            var j = st + 1
            if j < k and toks[j].kind == ctWord: inc j
            if j < k and toks[j].text == "{":
              nestedAt = j
              tEnd = cxSkipGroup(toks, j)
          if nestedAt >= 0:
            let nk = if toks[st].text == "union": cxUnion else: cxStruct
            let decls = cxDeclarators(toks, tEnd, k)
            if decls.len == 0:
              parseMembers(nestedAt + 1, tEnd - 1, owner, nk)    # an anonymous member: its fields are ours
            else:
              let nm = if st + 1 < k and toks[st + 1].kind == ctWord and toks[st + 1].text != "{": toks[st + 1].text
                       else: anonName(toks[st].text, toks[st].line)
              addSym(CxSym(name: nm, kind: nk, line: toks[st].line, col: toks[st].col,
                           endLine: toks[tEnd - 1].line, isDef: true, text: toks[st].text & " " & nm & " { … }"))
              parseMembers(nestedAt + 1, tEnd - 1, nm, nk)
              for (ni, stars, _) in decls:
                addSym(CxSym(name: toks[ni].text, kind: cxField, line: toks[ni].line, col: toks[ni].col,
                             endLine: toks[ni].line, owner: owner, typ: toks[st].text & " " & nm & (if stars.len > 0: " " & stars else: ""),
                             text: toks[st].text & " " & nm & " " & stars & toks[ni].text))
          else:
            let typeEnd = cxTypeEnd(toks, st, k)
            let base = cxTypeText(toks, st, typeEnd)
            for (ni, stars, _) in cxDeclarators(toks, typeEnd, k):
              let typ = (base & (if stars.len > 0: " " & stars else: "")).strip
              let (dims, bits) = cxDimsAt(toks, ni, k)
              # (an array: shown as written — `char name[16]` — though typed as its pointer for `x.name[0]`)
              let shown = if dims.len > 0 and typ.endsWith("*"): typ[0 ..< typ.high].strip & " " & toks[ni].text & dims
                          else: typ & " " & toks[ni].text
              addSym(CxSym(name: toks[ni].text, kind: cxField, line: toks[ni].line, col: toks[ni].col,
                           endLine: toks[ni].line, owner: owner, typ: typ, text: shown,
                           dims: dims, bits: bits))
        st = k + 1
      inc k
  proc parseDecl(a, b: int) =
    ## one declaration toks[a ..< b] that ended with `;`
    var k = a
    while k < b and cxNoise(toks[k].text):
      k = if k + 1 < b and toks[k + 1].text == "(": cxSkipGroup(toks, k + 1) else: k + 1
    if k >= b: return
    let isTypedef = toks[k].text == "typedef"
    if isTypedef: inc k
    let k0 = k
    while k < b and toks[k].text in CxQualifiers: inc k        # static const struct { … } table[] = …
    if k >= b or toks[k].text notin ["struct", "union", "enum"]: k = k0
    # struct / union / enum with a body
    var tagKind = cxVar
    var tag = ""
    var bodyEnd = -1
    if k < b and toks[k].text in ["struct", "union", "enum"]:
      tagKind = (case toks[k].text
                 of "struct": cxStruct
                 of "union": cxUnion
                 else: cxEnum)
      var j = k + 1
      while j < b and cxNoise(toks[j].text):
        j = if j + 1 < b and toks[j + 1].text == "(": cxSkipGroup(toks, j + 1) else: j + 1
      var tagAt = k
      if j < b and toks[j].kind == ctWord:
        tag = toks[j].text
        tagAt = j
        inc j
      if j < b and toks[j].text == "{":
        bodyEnd = cxSkipGroup(toks, j)
        var nm = tag
        if nm.len == 0: nm = anonName(toks[k].text, toks[k].line)
        let word = toks[k].text
        let firstSym = f.syms.len
        addSym(CxSym(name: nm, kind: tagKind, line: toks[tagAt].line, col: toks[tagAt].col,
                     endLine: toks[bodyEnd - 1].line, isDef: true,
                     text: word & " " & (if tag.len > 0: tag & " " else: "") & "{ … }"))
        parseMembers(j + 1, bodyEnd - 1, nm, tagKind)
        # declarators after the body: typedef names, or variables of this type
        let decls = cxDeclarators(toks, bodyEnd, b)
        var named = ""
        for (ni, stars, _) in decls:
          let typ = word & " " & nm & (if stars.len > 0: " " & stars else: "")
          if isTypedef:
            typedefs.incl toks[ni].text
            addSym(CxSym(name: toks[ni].text, kind: cxTypedef, line: toks[ni].line, col: toks[ni].col,
                         endLine: toks[ni].line, typ: typ, text: "typedef " & word & " " &
                         (if tag.len > 0: tag & " " else: "") & "{ … } " & stars & toks[ni].text,
                         doc: cxDocFor(comments, toks[k].line)))
            if tag.len == 0 and stars.len == 0 and named.len == 0: named = toks[ni].text
          else:
            addSym(CxSym(name: toks[ni].text, kind: cxVar, line: toks[ni].line, col: toks[ni].col,
                         endLine: toks[ni].line, typ: typ, text: typ & " " & toks[ni].text, isDef: true))
        if named.len > 0:
          # an anonymous struct named only by its typedef is filed under the typedef's name (as its fields' owner,
          # and in the types that name it: `typedef struct { … } Options, *OptionsP;`)
          let old = word & " " & nm
          for q in firstSym ..< f.syms.len:
            if f.syms[q].owner == nm: f.syms[q].owner = named
            if f.syms[q].name == nm and f.syms[q].kind == tagKind: f.syms[q].name = named
            if f.syms[q].typ.startsWith(old): f.syms[q].typ = word & " " & named & f.syms[q].typ[old.len .. ^1]
        return
    # the type: up to the first declarator
    let ts = k
    let typeEnd = cxTypeEnd(toks, ts, b)
    if typeEnd >= b:
      if tag.len > 0 and not isTypedef and b - k == 2:
        # struct list; — declared here, its members elsewhere (or nowhere: an opaque type)
        addSym(CxSym(name: tag, kind: tagKind, line: toks[k + 1].line, col: toks[k + 1].col, endLine: toks[k + 1].line,
                     text: toks[k].text & " " & tag & ";"))
      return
    var base = cxTypeText(toks, ts, typeEnd).strip
    for w in ["extern ", "static ", "inline ", "__inline ", "__inline__ ", "__extension__ ", "register ", "_Noreturn "]:
      base = base.replace(w, "")
    base = base.strip
    if base.len == 0: return
    var isExtern = false
    for q in a ..< typeEnd:
      if toks[q].text == "extern": isExtern = true
    for (ni, stars, after) in cxDeclarators(toks, typeEnd, b):
      let nm = toks[ni].text
      # a function: name( params ) — or name _(( params )), through a portability macro (zsh's _, __P, PROTO, OF)
      var p = ni + 1
      var viaMacro = false
      if p + 2 < after and toks[p].kind == ctWord and toks[p + 1].text == "(" and toks[p + 2].text == "(":
        inc p
        viaMacro = true
      if p < after and toks[p].text == "(" and "(*)" notin stars:
        let pe = cxSkipGroup(toks, p)
        let (ps, va) = if viaMacro: cxParams(toks, p + 2, cxSkipGroup(toks, p + 1) - 1)
                       else: cxParams(toks, p + 1, pe - 1)
        let ret = (base & (if stars.len > 0: " " & stars else: "")).strip
        if isTypedef:
          typedefs.incl nm
          addSym(CxSym(name: nm, kind: cxTypedef, line: toks[ni].line, col: toks[ni].col, endLine: toks[ni].line,
                       typ: ret & " (" & nm & ")(…)", text: "typedef " & cxTypeText(toks, ts, pe)))
        else:
          var txt = ret & " " & nm & "("
          var pl: seq[string]
          for q in ps: pl.add (q.typ & (if q.name.len > 0: " " & q.name else: "")).replace("* ", "*")
          if va: pl.add "..."
          txt.add pl.join(", ") & ")"
          addSym(CxSym(name: nm, kind: cxFunc, line: toks[ni].line, col: toks[ni].col, endLine: toks[ni].line,
                       typ: ret, params: ps, varargs: va, text: txt, doc: cxDocFor(comments, toks[ts].line)))
          if full:
            for q in ps:
              if q.name.len > 0 and q.line >= 0:
                f.syms.add CxSym(name: q.name, kind: cxParam, line: q.line, col: q.col, typ: q.typ,
                                 scopeA: toks[ni].line, scopeB: toks[pe - 1].line, owner: nm,
                                 text: q.typ & " " & q.name)
        continue
      let typ = (base & (if stars.len > 0: " " & stars else: "")).strip
      if isTypedef:
        typedefs.incl nm
        addSym(CxSym(name: nm, kind: cxTypedef, line: toks[ni].line, col: toks[ni].col, endLine: toks[ni].line,
                     typ: typ, text: "typedef " & typ & " " & nm, doc: cxDocFor(comments, toks[ts].line)))
      elif base notin ["return", "goto", "case"]:
        addSym(CxSym(name: nm, kind: cxVar, line: toks[ni].line, col: toks[ni].col, endLine: toks[ni].line,
                     typ: typ, text: typ & " " & nm, doc: cxDocFor(comments, toks[ts].line), isDef: not isExtern))
  proc parseBody(k, bodyEnd: int, fname: string, fline, endL: int) =
    ## a function's body (toks[k] its `{`, toks[bodyEnd - 1] its `}`): its locals — declarations inside, seen
    ## from their line to the end of their block — and labels
    var blockEnds: seq[int]
    var bst = k + 1
    var i = k + 1
    var depth = 1
    blockEnds.add endL
    proc rangeFor(i, bst: var int): bool =
      ## C++'s for (auto &s : shapes): s, seen in the loop (its type: the elements'); i past the `)`
      let hc = min(cxSkipGroup(toks, i + 1), bodyEnd - 1)
      var ci = -1
      var dd = 0
      for q in i + 2 ..< hc - 1:
        let y = toks[q]
        if y.kind == ctPunct and y.text in ["(", "[", "{"]: inc dd
        elif y.kind == ctPunct and y.text in [")", "]", "}"]: dec dd
        elif y.kind == ctPunct and y.text == ";": break
        elif dd == 0 and y.kind == ctPunct and y.text == ":":
          ci = q
          break
      if ci <= i + 2 or toks[ci - 1].kind != ctWord: return false
      let typ = cxTypeText(toks, i + 2, ci - 1).strip
      let ends = if hc < bodyEnd - 1 and toks[hc].text == "{": toks[cxSkipGroup(toks, hc) - 1].line
                 else:
                   var q = hc
                   while q < bodyEnd - 1 and toks[q].text != ";": inc q
                   toks[min(q, bodyEnd - 1)].line
      f.syms.add CxSym(name: toks[ci - 1].text, kind: cxLocal, line: toks[ci - 1].line, col: toks[ci - 1].col,
                       typ: typ, scopeA: toks[ci - 1].line, scopeB: ends, owner: fname,
                       text: typ & " " & toks[ci - 1].text,
                       init: (if "auto" in typ.splitWhitespace: "@elem:" & cxxRender(toks, ci + 1, hc - 1) else: ""))
      i = hc
      bst = hc
      true
    while i < bodyEnd - 1:
      let x = toks[i]
      if i > 0 and toks[i - 1].line != x.line and toks[i - 1].kind == ctPunct and
         (toks[i - 1].text in [".", "->"] or (cpp and toks[i - 1].text == "::")):
        bst = i                     # (a line still being typed — `p->` — does not swallow the next one)
      if x.kind == ctPunct and x.text == "{":
        inc depth
        let ce = cxSkipGroup(toks, i)
        blockEnds.add toks[ce - 1].line
        bst = i + 1
      elif x.kind == ctPunct and x.text == "}":
        dec depth
        if blockEnds.len > 1: blockEnds.setLen(blockEnds.len - 1)
        bst = i + 1
      elif x.kind == ctPunct and x.text == ";":
        bst = i + 1

      elif cpp and x.kind == ctWord and x.text == "for" and i + 1 < bodyEnd and toks[i + 1].text == "(" and
           rangeFor(i, bst):
        continue
      elif x.kind == ctWord and (x.text == "for" or (cpp and x.text == "catch") or
                                 (cpp and x.text in ["if", "while", "switch"] and i + 2 < bodyEnd and
                                  toks[i + 2].text in ["auto", "const"])) and
           i + 1 < bodyEnd and toks[i + 1].text == "(":
        bst = i + 2                 # for (int i = 0; …): the declaration starts after the (
        inc i
        inc i
        continue
      elif i == bst and x.kind == ctWord and i + 1 < bodyEnd - 1 and toks[i + 1].text == ":" and
           x.text notin ["default", "case"]:
        # a label — `goto` it from anywhere in the function
        f.syms.add CxSym(name: x.text, kind: cxLabel, line: x.line, col: x.col, scopeA: fline,
                         scopeB: endL, owner: fname, text: x.text & ":")
        bst = i + 2
        i += 2
        continue
      elif i == bst and toks[i].kind == ctWord and
           toks[i].text notin ["return", "goto", "case", "else", "do", "sizeof", "break", "continue", "default",
                               "if", "while", "switch", "for"] and
           not (cpp and toks[i].text in ["delete", "throw", "new", "co_return", "co_yield", "co_await", "using",
                                         "namespace", "static_assert", "operator", "this", "typedef", "try", "catch",
                                         "friend", "public", "private", "protected", "nullptr", "true", "false"]) and
           (cxIsTypeStart(toks, i, typedefs) or
            (i + 2 < bodyEnd and toks[i + 1].kind == ctWord and
             (toks[i + 2].text in [";", "=", ",", "["] or (cpp and toks[i + 2].text in ["{", "("]))) or
            (block:
              # a type named in a header (not known here): `T *p;`, `T **pp = 0;` (C++: `T &r = x;`)
              var j = i + 1
              var stars = 0
              while j < bodyEnd and (toks[j].text in ["*", "const", "volatile", "restrict", "__restrict"] or
                                     (cpp and toks[j].text in ["&", "&&"])):
                if toks[j].text in ["*", "&", "&&"]: inc stars
                inc j
              stars > 0 and j + 1 < bodyEnd and toks[j].kind == ctWord and
                toks[j + 1].text in [";", "=", ",", "["])) and
           not (i + 1 < bodyEnd and toks[i + 1].kind == ctPunct and toks[i + 1].text in ["(", "=", "[", ".", "->"]):
        # a declaration statement: type declarators ;
        var e = i
        var dd = 0
        while e < bodyEnd - 1:
          let y = toks[e]
          if y.kind == ctPunct and y.text in ["(", "[", "{"]: inc dd
          elif y.kind == ctPunct and y.text in [")", "]", "}"]:
            if dd == 0: break
            dec dd
          elif y.text == ";" and dd == 0: break
          inc e
        # struct { … } x; — a type of its own, declared here (its members known too)
        var r0 = i
        while r0 < e and toks[r0].text in CxQualifiers: inc r0
        if r0 + 1 < e and toks[r0].text in ["struct", "union", "enum"] and
           (toks[r0 + 1].text == "{" or (toks[r0 + 1].kind == ctWord and r0 + 2 < e and toks[r0 + 2].text == "{")):
          let word = toks[r0].text
          let tag2 = if toks[r0 + 1].kind == ctWord: toks[r0 + 1].text else: ""
          let ob = if tag2.len > 0: r0 + 2 else: r0 + 1
          let be = cxSkipGroup(toks, ob)
          let nk = (case word
                    of "struct": cxStruct
                    of "union": cxUnion
                    else: cxEnum)
          let nm = if tag2.len > 0: tag2 else: anonName(word, toks[r0].line)
          addSym(CxSym(name: nm, kind: nk, line: toks[r0].line, col: toks[r0].col, endLine: toks[be - 1].line,
                       isDef: true, text: word & " " & (if tag2.len > 0: tag2 & " " else: "") & "{ … }"))
          parseMembers(ob + 1, be - 1, nm, nk)
          for (ni2, stars2, _) in cxDeclarators(toks, be, e):
            let typ = word & " " & nm & (if stars2.len > 0: " " & stars2 else: "")
            f.syms.add CxSym(name: toks[ni2].text, kind: cxLocal, line: toks[ni2].line, col: toks[ni2].col,
                             typ: typ, scopeA: toks[ni2].line, scopeB: blockEnds[^1], owner: fname,
                             text: typ & " " & toks[ni2].text)
          i = e
          continue
        let typeEnd = cxTypeEnd(toks, i, e)
        if typeEnd > i and typeEnd < e:
          let baseT = cxTypeText(toks, i, typeEnd).strip
          for (ni2, stars2, after) in cxDeclarators(toks, typeEnd, e):
            let typ = (baseT & (if stars2.len > 0: " " & stars2 else: "")).strip
            var s = CxSym(name: toks[ni2].text, kind: cxLocal, line: toks[ni2].line, col: toks[ni2].col,
                          typ: typ, scopeA: toks[ni2].line, scopeB: blockEnds[^1], owner: fname,
                          text: typ & " " & toks[ni2].text)
            if cpp and "auto" in baseT.splitWhitespace and ni2 + 1 < after and toks[ni2 + 1].text == "=":
              s.init = cxxRender(toks, ni2 + 2, after)        # auto x = …: its type is what initializes it
            f.syms.add s
        i = e
        continue
      inc i
  # ── C++: namespaces, classes and their members, functions and methods (in the class or outside it) ──
  proc qualify(scope, name: string): string = (if scope.len > 0: scope & "::" & name else: name)
  proc stmtEnd(k, b: int): int =
    ## the `;` that ends the statement from toks[k] (b when none)
    var j = k
    while j < b:
      let x = toks[j]
      if x.kind == ctPunct:
        if x.text == ";" or x.text == "}": return j
        if x.text in ["(", "[", "{"]:
          j = min(cxSkipGroup(toks, j), b)
          continue
      inc j
    b
  proc stmtAt(k, b: int): (int, int, int, int) =
    ## the C++ statement from toks[k]: (where it ends — its `;`, or past a body's `}` —, its parameters' `(` (-1:
    ## none), past their `)`, the body's `{` (-1: a declaration)). A constructor's `: a(x), b{y}` before its body
    var j = k
    var paren = -1
    var pclose = -1
    var sawEq = false
    var inInit = false
    var trailing = false
    while j < b:
      let x = toks[j]
      if x.kind != ctPunct:
        inc j
        continue
      case x.text
      of ";", "}": return (j, paren, pclose, -1)
      of "=":
        if paren < 0: sawEq = true
        inc j
      of "(":
        let ce = min(cxSkipGroup(toks, j), b)
        if not sawEq and not inInit and not trailing and j > k and toks[j - 1].kind == ctWord and
           not cxNoise(toks[j - 1].text) and not toks[j - 1].text.startsWith("decltype(") and
           toks[j - 1].text notin ["sizeof", "alignof", "static_assert", "if", "while", "for", "switch", "return"] and
           not (toks[j - 1].text in CxTypeWords and toks[j - 1].text notin ["size_t", "FILE"]) and
           not (j + 1 < b and toks[j + 1].text == "*"):
          paren = j
          pclose = ce
        j = ce
      of "[": j = min(cxSkipGroup(toks, j), b)
      of ":":
        if paren >= 0 and j >= pclose and not sawEq: inInit = true
        inc j
      of "->":
        if paren >= 0 and j >= pclose: trailing = true
        inc j
      of "{":
        let ce = min(cxSkipGroup(toks, j), b)
        if paren >= 0 and not sawEq and (not inInit or toks[j - 1].kind != ctWord): return (ce, paren, pclose, j)
        j = ce
      else: inc j
    (b, paren, pclose, -1)
  proc cxxParamsAt(a, b: int): (seq[CxParam], bool) =
    ## C++'s parameters: default values (`int n = MAX`) and unnamed references (`const Point&`) too
    var d = 0
    var st = a
    var parts: seq[(int, int)]
    for k in a ..< b:
      let t = toks[k].text
      if toks[k].kind == ctPunct and t in ["(", "[", "{"]: inc d
      elif toks[k].kind == ctPunct and t in [")", "]", "}"]: dec d
      elif t == "," and d == 0:
        parts.add (st, k)
        st = k + 1
    if b > st: parts.add (st, b)
    for (x, y0) in parts:
      var y = y0
      d = 0
      for k in x ..< y0:
        let t = toks[k].text
        if toks[k].kind == ctPunct and t in ["(", "[", "{"]: inc d
        elif toks[k].kind == ctPunct and t in [")", "]", "}"]: dec d
        elif t == "=" and d == 0:
          y = k
          break
      if y <= x: continue
      if toks[y - 1].text in ["&", "&&", "*"] or y - x == 1:
        if y - x == 1 and toks[x].text == "void": continue
        if y - x == 1 and toks[x].text == "...":
          result[1] = true
          continue
        result[0].add CxParam(name: "", typ: cxTypeText(toks, x, y).strip, line: -1, col: -1)
        continue
      let (ps, va) = cxParams(toks, x, y)
      result[0].add ps
      if va: result[1] = true
  proc fnText(ret, name: string, ps: seq[CxParam], va: bool, suffix: string): string =
    var pl: seq[string]
    for x in ps: pl.add (x.typ & (if x.name.len > 0: " " & x.name else: "")).replace("* ", "*").replace("& ", "&")
    if va: pl.add "..."
    (if ret.len == 0: "" elif ret[^1] in {'*', '&'}: ret else: ret & " ") & name & "(" & pl.join(", ") & ")" & suffix
  proc spaceNamed(qual, ns: string): string =
    ## the namespace this file declares that `qual` names, seen from namespace ns ("" when none)
    var at = ns
    while true:
      let want = qualify(at, qual)
      for (q, _, _) in f.spaces:
        if q == want: return q
      if at.len == 0: break
      let k = at.rfind("::")
      at = if k >= 0: at[0 ..< k] else: ""
    ""
  proc classNamed(qual: string): string =
    ## the class `qual` names, qualified, when this file declares it — else qual as written
    for s in f.syms:
      if s.kind in {cxClass, cxStruct, cxUnion} and s.isDef:
        let q = cxxQual(s)
        if q == qual or q.endsWith("::" & qual): return q
    qual
  proc retType(st, ni: int): string =
    ## a function's type: the words before its name that are types (not static, inline, friend …)
    var ts = st
    while ts < ni and (cxNoise(toks[ts].text) or toks[ts].text in ["static", "inline", "extern", "friend",
                                                                     "__inline", "__inline__"]):
      ts = if cxNoise(toks[ts].text) and ts + 1 < ni and toks[ts + 1].text == "(": cxSkipGroup(toks, ts + 1) else: ts + 1
    cxTypeText(toks, ts, ni).strip
  proc suffixOf(pclose, stop: int): (string, string) =
    ## after a function's `)`: (const = 0 = default …, the type after `->`)
    var sfx = ""
    var q = pclose
    while q < stop:
      let t = toks[q].text
      if t == "const": sfx.add " const"
      elif t in ["&", "&&"] and sfx.len < 8: sfx.add " " & t
      elif t == "=" and q + 1 < stop: sfx.add " = " & toks[q + 1].text
      elif t in [":", "{"]: break
      elif t == "->": return (sfx, cxTypeText(toks, q + 1, stop).strip)
      inc q
    (sfx, "")
  proc enumConsts(a, b: int, owner, scope: string) =
    var k = a
    while k < b:
      if toks[k].kind == ctWord:
        addSym(CxSym(name: toks[k].text, kind: cxEnumConst, line: toks[k].line, col: toks[k].col,
                     endLine: toks[k].line, owner: owner, scope: scope, typ: owner,
                     text: toks[k].text & " (" & owner & ")"))
        var d = 0
        while k < b:
          let t = toks[k].text
          if toks[k].kind == ctPunct and t in ["(", "[", "{"]: inc d
          elif toks[k].kind == ctPunct and t in [")", "]", "}"]: dec d
          elif t == "," and d == 0: break
          inc k
      inc k
  proc initAfter(ni, e: int): string =
    ## `x = …`: what initializes the declarator named at toks[ni] (up to the next top-level comma)
    if ni + 1 >= e or toks[ni + 1].text != "=": return ""
    var j = ni + 2
    var d = 0
    while j < e:
      let t = toks[j].text
      if toks[j].kind == ctPunct and t in ["(", "[", "{"]: inc d
      elif toks[j].kind == ctPunct and t in [")", "]", "}"]: dec d
      elif t == "," and d == 0: break
      inc j
    cxxRender(toks, ni + 2, j)
  proc funcDef(st, paren, pclose, body, e: int, ns, cls, clsShort: string, tp: seq[string], docLine: int) =
    ## a function or method with its body: in a class (cls), or `Ret Class::method(…) { … }` outside it
    let nt = toks[paren - 1]
    let parts = cxxSplit(nt.text)
    let short = if parts[^1].startsWith("operator") or parts[^1].startsWith("~"): parts[^1] else: cxxNoArgs(parts[^1])
    var qual = ""
    for i in 0 ..< parts.len - 1: qual = qualify(qual, cxxNoArgs(parts[i]))
    var kind = cxFunc
    var owner = ""
    var scope = if cls.len > 0: cls else: ns
    if cls.len > 0:
      kind = cxMethod
      owner = cls
    elif qual.len > 0:
      let nsq = spaceNamed(qual, ns)
      if nsq.len > 0 or qual == "std": scope = (if nsq.len > 0: nsq else: qual)
      else:
        kind = cxMethod
        owner = classNamed(qual)
    let clsName = if cls.len > 0: clsShort elif kind == cxMethod: cxxSplit(owner)[^1] else: ""
    let ctor = kind == cxMethod and (short == clsName or short == "~" & clsName)
    let (sfx, trail) = suffixOf(pclose, body)
    var ret = if ctor: "" elif trail.len > 0: trail else: retType(st, paren - 1)
    if ret == "auto" and trail.len > 0: ret = trail
    let (ps, va) = cxxParamsAt(paren + 1, pclose - 1)
    let endL = toks[e - 1].line
    let shown = (if kind == cxMethod: clsName & "::" elif qual.len > 0: qual & "::" else: "") & short
    addSym(CxSym(name: short, kind: kind, line: nt.nameLine, col: nt.nameCol, endLine: endL,
                 typ: (if ret.len > 0 or ctor: ret else: "int"), params: ps, varargs: va, isDef: true, owner: owner,
                 scope: scope, tparams: tp, text: fnText(ret, shown, ps, va, sfx), doc: cxDocFor(comments, docLine)))
    for x in ps:
      if x.name.len > 0:
        f.syms.add CxSym(name: x.name, kind: cxParam, line: (if x.line >= 0: x.line else: nt.nameLine),
                         col: max(0, x.col), typ: x.typ, scopeA: nt.nameLine, scopeB: endL, owner: short,
                         text: x.typ & " " & x.name)
    parseBody(body, e, short, nt.nameLine, endL)
  proc protoDecl(st, e, paren, pclose: int, here, cls, clsShort: string, tp: seq[string], docLine: int) =
    ## a function's (or a method's) declaration, no body
    let nt = toks[paren - 1]
    let parts = cxxSplit(nt.text)
    let short = if parts[^1].startsWith("operator") or parts[^1].startsWith("~"): parts[^1] else: cxxNoArgs(parts[^1])
    let ctor = cls.len > 0 and (short == clsShort or short == "~" & clsShort)
    let (sfx, trail) = suffixOf(pclose, e)
    var ret = if ctor: "" elif trail.len > 0: trail else: retType(st, paren - 1)
    let (ps, va) = cxxParamsAt(paren + 1, pclose - 1)
    let shown = (if cls.len > 0: clsShort & "::" else: "") & short
    addSym(CxSym(name: short, kind: (if cls.len > 0: cxMethod else: cxFunc), line: nt.nameLine, col: nt.nameCol,
                 endLine: nt.nameLine, typ: (if ret.len > 0 or ctor: ret else: "int"), params: ps, varargs: va,
                 isDef: " = default" in sfx or " = delete" in sfx, owner: cls, scope: here, tparams: tp,
                 text: fnText(ret, shown, ps, va, sfx), doc: cxDocFor(comments, docLine, toks[max(st, e - 1)].line)))
    if full:
      for x in ps:
        if x.name.len > 0 and x.line >= 0:
          f.syms.add CxSym(name: x.name, kind: cxParam, line: x.line, col: x.col, typ: x.typ,
                           scopeA: nt.nameLine, scopeB: toks[pclose - 1].line, owner: short, text: x.typ & " " & x.name)
  proc memberDecl(st, e, paren, pclose: int, cls, clsShort: string, tp: seq[string], docLine: int) =
    ## a class member that has no body: a method's declaration, or fields
    if toks[st].text == "friend": return
    if paren > st and toks[paren - 1].kind == ctWord and not (paren + 1 < e and toks[paren + 1].text == "*") and
       not (paren + 1 < pclose - 1 and toks[paren + 1].kind in {ctNum, ctStr, ctChar}):
      let nm = toks[paren - 1].text
      if nm == clsShort or nm == "~" & clsShort or nm.startsWith("operator") or retType(st, paren - 1).len > 0:
        protoDecl(st, e, paren, pclose, cls, cls, clsShort, tp, docLine)
      return                                     # (no type, not the constructor: a macro — DECLARE_X(y);)
    let typeEnd = cxTypeEnd(toks, st, e)
    if typeEnd >= e: return
    var base = cxTypeText(toks, st, typeEnd).strip
    for w in ["static ", "inline ", "extern ", "register "]: base = base.replace(w, "")
    base = base.strip
    if base.len == 0: return
    for (ni, stars, _) in cxDeclarators(toks, typeEnd, e):
      let typ = (base & (if stars.len > 0: " " & stars else: "")).strip
      addSym(CxSym(name: toks[ni].text, kind: cxField, line: toks[ni].line, col: toks[ni].col, endLine: toks[ni].line,
                   owner: cls, scope: cls, typ: typ, text: typ & " " & toks[ni].text))
  proc declHere(st, e, paren, pclose: int, ns: string, tp: seq[string], docLine: int) =
    ## a declaration at file or namespace level: variables, prototypes, typedefs (C's reading, then put in ns)
    if paren > st and toks[paren - 1].kind == ctWord and toks[st].text != "typedef":
      if paren + 1 < pclose - 1 and toks[paren + 1].kind in {ctNum, ctStr, ctChar}:
        # Point origin(0, 0); — a variable, and its constructor's arguments
        let nt = toks[paren - 1]
        let typ = retType(st, paren - 1)
        if typ.len > 0:
          addSym(CxSym(name: nt.text, kind: cxVar, line: nt.line, col: nt.col, endLine: nt.line, typ: typ, scope: ns,
                       isDef: true, text: typ & " " & nt.text))
        return
      if not (paren + 1 < e and toks[paren + 1].text == "*") and retType(st, paren - 1).len > 0:
        protoDecl(st, e, paren, pclose, ns, "", "", tp, docLine)
        return
    let first = f.syms.len
    parseDecl(st, e)
    for q in first ..< f.syms.len:
      var s = f.syms[q]
      case s.kind
      of cxParam, cxLocal, cxLabel: continue
      of cxField:
        s.owner = qualify(ns, s.owner)
        s.scope = s.owner
      of cxEnumConst:
        s.owner = qualify(ns, s.owner)
        s.scope = ns
        s.typ = s.owner
      else:
        s.scope = ns
        if "::" in s.name:
          # int Counter::count = 0; — a static member's definition
          let parts = cxxSplit(s.name)
          var qual = ""
          for i in 0 ..< parts.len - 1: qual = qualify(qual, cxxNoArgs(parts[i]))
          for k in st ..< e:
            if toks[k].line == s.line and toks[k].col == s.col:
              s.line = toks[k].nameLine
              s.col = toks[k].nameCol
          s.name = cxxNoArgs(parts[^1])
          if s.kind == cxVar and spaceNamed(qual, ns).len == 0:
            s.kind = cxField
            s.owner = classNamed(qual)
            s.scope = s.owner
        if s.kind == cxVar and "auto" in s.typ.splitWhitespace:
          for k in st ..< e:
            if toks[k].line == s.line and toks[k].col == s.col: s.init = initAfter(k, e)
      f.syms[q] = s
  proc cppScan(a, b: int, ns, cls, clsShort: string) =
    ## C++'s declarations in toks[a ..< b]: a namespace's (cls ""), or a class's members (cls: its qualified name,
    ## clsShort: its own)
    let here = if cls.len > 0: cls else: ns
    var k = a
    var tm = ""
    var hasTm = false
    var tmLine = -1
    while k < b:
      let t = toks[k]
      if t.kind == ctTemplate:
        (tm, hasTm, tmLine) = (t.text, true, t.line)
        inc k
        continue
      let tp = if hasTm: cxxTemplateNames(tm) else: @[]
      let tmText = if hasTm: "template <" & tm & "> " else: ""
      let docLine = if hasTm: tmLine else: t.line
      hasTm = false
      if t.kind != ctWord:
        k = if t.kind == ctPunct and t.text in ["{", "(", "["]: min(cxSkipGroup(toks, k), b) else: k + 1
        continue
      # public: protected: (Qt's `public slots:` too)
      if cls.len > 0 and t.text in ["public", "private", "protected", "signals", "slots", "Q_SIGNALS", "Q_SLOTS"]:
        var j = k
        while j < b and toks[j].kind == ctWord and j - k < 3: inc j
        if j < b and toks[j].text == ":":
          k = j + 1
          continue
      # a macro on a line of its own: Q_OBJECT, DECLARE_THING(x)
      let macroWord = (let w0 = t.text.split('(')[0]; w0.len > 1 and w0[0] in {'A'..'Z', '_'} and
                       w0.allCharsInSet({'A'..'Z', '0'..'9', '_'}))
      if macroWord:
        var j = k + 1
        let paren = '(' in t.text or (j < b and toks[j].text == "(")
        if j < b and toks[j].text == "(": j = min(cxSkipGroup(toks, j), b)
        if j < b and toks[j].line > toks[j - 1].line and
           ((paren and toks[j].text notin [";", "{", ":", ",", "=", "->", "const", "&", "&&", "*", "override"]) or
            (not paren and cls.len > 0 and (toks[j].kind == ctWord or toks[j].text in ["}", "~"]))):
          k = j
          continue
      # namespace a::b { … }, inline namespace, namespace { … }; namespace x = y;
      if cls.len == 0 and (t.text == "namespace" or (t.text == "inline" and k + 1 < b and toks[k + 1].text == "namespace")):
        let inl = t.text == "inline"
        var j = k + (if inl: 2 else: 1)
        var nameAt = -1
        if j < b and toks[j].kind == ctWord:
          nameAt = j
          inc j
        if j < b and toks[j].text == "{":
          let e = min(cxSkipGroup(toks, j), b)
          var inner = ns
          if nameAt >= 0 and not inl:
            let l = toks[nameAt].line
            var c0 = toks[nameAt].col
            for part in cxxSplit(toks[nameAt].text):
              let parent = inner
              inner = qualify(inner, part)
              let c = if l < f.lines.len: max(0, f.lines[l].find(part, c0)) else: c0
              c0 = c + part.len
              addSym(CxSym(name: part, kind: cxNamespace, line: l, col: c, endLine: toks[e - 1].line, scope: parent,
                           isDef: true, text: "namespace " & inner))
          f.spaces.add (inner, toks[j].line, toks[e - 1].line)
          cppScan(j + 1, e - 1, inner, "", "")
          k = e
          continue
        k = stmtEnd(k, b) + 1
        continue
      # extern "C" { … } (C's declarations, read the same way)
      if t.text == "extern" and k + 2 < b and toks[k + 1].kind == ctStr and toks[k + 2].text == "{":
        let e = min(cxSkipGroup(toks, k + 2), b)
        cppScan(k + 3, e - 1, ns, cls, clsShort)
        k = e
        continue
      # using namespace x; using T = …; (using Base::f; — nothing new)
      if t.text == "using":
        let e = stmtEnd(k, b)
        if k + 2 < e and toks[k + 1].text == "namespace":
          f.usings.add (toks[k + 2].text, t.line)
        elif k + 3 < e and toks[k + 1].kind == ctWord and toks[k + 2].text == "=":
          let nm = toks[k + 1].text
          let typ = cxTypeText(toks, k + 3, e).strip
          typedefs.incl nm
          addSym(CxSym(name: nm, kind: cxTypedef, line: toks[k + 1].line, col: toks[k + 1].col, endLine: toks[e - 1].line,
                       typ: typ, scope: here, owner: cls, tparams: tp, text: tmText & "using " & nm & " = " & typ,
                       doc: cxDocFor(comments, docLine)))
        k = e + 1
        continue
      if t.text in ["friend", "static_assert"]:
        let (e, _, _, body) = stmtAt(k, b)
        k = if body >= 0: e else: e + 1
        continue
      if t.text == "typedef":
        let e = stmtEnd(k, b)
        if cls.len > 0:
          let first = f.syms.len
          parseDecl(k, e)
          for q in first ..< f.syms.len:
            if f.syms[q].kind == cxTypedef:
              f.syms[q].owner = cls
              f.syms[q].scope = cls
        else: declHere(k, e, -1, -1, ns, tp, docLine)
        k = e + 1
        continue
      # class / struct / union / enum: with a body, or declared (class Foo;)
      var j = k
      while j < b and toks[j].text in ["static", "const", "volatile", "inline", "extern"]: inc j
      if j < b and toks[j].text in ["class", "struct", "union", "enum"]:
        let word = toks[j].text
        var m = j + 1
        var scoped = false
        if word == "enum" and m < b and toks[m].text in ["class", "struct"]:
          scoped = true
          inc m
        var nameAt = -1
        while m < b:                                 # (the name: the last word — export macros before it)
          if cxNoise(toks[m].text):
            m = if m + 1 < b and toks[m + 1].text == "(": cxSkipGroup(toks, m + 1) else: m + 1
            continue
          if toks[m].kind != ctWord: break
          nameAt = m
          inc m
        var bases: seq[string]
        var m2 = m
        if m2 < b and toks[m2].text == ":":
          inc m2
          var cur = ""
          while m2 < b and toks[m2].text notin ["{", ";"]:
            let x = toks[m2]
            if x.text == ",":
              if cur.len > 0: bases.add cur
              cur = ""
            elif x.kind == ctWord and x.text notin ["public", "private", "protected", "virtual"]: cur = x.text
            inc m2
          if cur.len > 0 and word != "enum": bases.add cur
          if word == "enum": bases.setLen(0)
        if m2 < b and toks[m2].text == "{" and (nameAt < 0 or nameAt == m - 1):
          let be = min(cxSkipGroup(toks, m2), b)
          let kind = (case word
                      of "class": cxClass
                      of "struct": cxStruct
                      of "union": cxUnion
                      else: cxEnum)
          var scope = here
          var nm = ""
          if nameAt >= 0:
            let parts = cxxSplit(toks[nameAt].text)
            nm = cxxNoArgs(parts[^1])
            for i in 0 ..< parts.len - 1: scope = qualify(scope, cxxNoArgs(parts[i]))   # class A::B { … }
          let anon = nm.len == 0
          if anon: nm = anonName(word, toks[j].line)
          else: typedefs.incl nm
          let q = qualify(scope, nm)
          var after = be - 1
          var decls: seq[(int, string, int)]
          if be < b and toks[be].text == ";": after = be
          elif be < b and (toks[be].line == toks[be - 1].line or toks[be].text in ["*", "&"]):
            after = stmtEnd(be, b)
            decls = cxDeclarators(toks, be, after)
          if anon and cls.len > 0 and decls.len == 0 and word != "enum":
            cppScan(m2 + 1, be - 1, ns, cls, clsShort)       # union { … }; in a class: its members are the class's
            k = after + 1
            continue
          var head = tmText & word & (if scoped: " class" else: "") & (if anon: "" else: " " & nm)
          if bases.len > 0: head.add " : " & bases.join(", ")
          addSym(CxSym(name: nm, kind: kind, line: (if nameAt >= 0: toks[nameAt].nameLine else: toks[j].line),
                       col: (if nameAt >= 0: toks[nameAt].nameCol else: toks[j].col), endLine: toks[be - 1].line,
                       isDef: true, scope: scope, owner: cls, bases: bases, tparams: tp, text: head & " { … }",
                       doc: cxDocFor(comments, docLine)))
          if word == "enum": enumConsts(m2 + 1, be - 1, q, (if scoped: q else: scope))
          else: cppScan(m2 + 1, be - 1, ns, q, nm)
          for (ni, stars, _) in decls:
            let typ = q & (if stars.len > 0: " " & stars else: "")
            addSym(CxSym(name: toks[ni].text, kind: (if cls.len > 0: cxField else: cxVar), line: toks[ni].line,
                         col: toks[ni].col, endLine: toks[ni].line, typ: typ, owner: cls, scope: here, isDef: true,
                         text: typ & " " & toks[ni].text))
          k = after + 1
          continue
        if m < b and toks[m].text == ";" and nameAt == m - 1 and nameAt >= 0 and m2 == m:
          let nm = cxxNoArgs(cxxSplit(toks[nameAt].text)[^1])
          addSym(CxSym(name: nm, kind: (case word
                                        of "class": cxClass
                                        of "struct": cxStruct
                                        of "union": cxUnion
                                        else: cxEnum),
                       line: toks[nameAt].nameLine, col: toks[nameAt].nameCol, endLine: toks[nameAt].line,
                       scope: here, owner: cls, text: word & " " & nm & ";"))
          k = m + 1
          continue
      # a declaration, or a function with its body
      let (e, paren, pclose, body) = stmtAt(k, b)
      if body >= 0:
        funcDef(k, paren, pclose, body, e, ns, cls, clsShort, tp, docLine)
        k = e
        continue
      if e > k:
        if cls.len > 0: memberDecl(k, e, paren, pclose, cls, clsShort, tp, docLine)
        else: declHere(k, e, paren, pclose, ns, tp, docLine)
      k = e + 1
  if cpp:
    cppScan(0, toks.len, "", "", "")
    return
  var k = 0
  var st = 0
  var transparent = 0                       # extern "C" { … }: its braces are not a body
  while k < toks.len:
    let t = toks[k]
    if t.kind == ctPunct and t.text == ";":
      if k > st: parseDecl(st, k)
      st = k + 1
      inc k
      continue
    if t.kind == ctPunct and t.text == "}" and transparent > 0:
      dec transparent
      st = k + 1
      inc k
      continue
    if t.kind == ctPunct and t.text == "{":
      # extern "C" {
      if k - st == 2 and toks[st].text == "extern" and toks[st + 1].kind == ctStr:
        if toks[st + 1].text == "\"C++\"":         # extern "C++" { … }: C++'s declarations, left out
          k = cxSkipGroup(toks, k)
          st = k
          continue
        inc transparent
        st = k + 1
        inc k
        continue
      # a function's body: name(…) {
      var p = k - 1
      while p > st and (cxNoise(toks[p].text) or toks[p].text in ["const", "__attribute__"]): dec p
      # f(…) VA_DCL {, f(…) NOEXCEPT {: macro words between the parameters and the body
      var p2 = p
      while p2 > st and toks[p2].kind == ctWord and toks[p2].text.len > 1 and
            toks[p2].text.allCharsInSet({'A'..'Z', '0'..'9', '_'}): dec p2
      if p2 < p and p2 > st and toks[p2].text == ")": p = p2
      if p > st and toks[p].text == ")":
        # find its (
        var d = 0
        var q = p
        while q >= st:
          if toks[q].text == ")": inc d
          elif toks[q].text == "(":
            dec d
            if d == 0: break
          dec q
        # (… ) __attribute__((x)) {: back over the attribute to the parameter list
        while q > st + 1 and toks[q - 1].kind == ctWord and cxNoise(toks[q - 1].text) and toks[q - 2].text == ")":
          var d2 = 0
          var q2 = q - 2
          while q2 >= st:
            if toks[q2].text == ")": inc d2
            elif toks[q2].text == "(":
              dec d2
              if d2 == 0: break
            dec q2
          q = q2
        if q > st and toks[q - 1].kind == ctWord and toks[q - 1].text notin ["if", "while", "for", "switch"]:
          let ni = q - 1
          let bodyEnd = cxSkipGroup(toks, k)
          var tEnd = ni
          var stars = ""
          while tEnd > st and toks[tEnd - 1].text == "*":
            dec tEnd
            stars.add "*"
          var ts = st
          while ts < tEnd and cxNoise(toks[ts].text):
            ts = if ts + 1 < tEnd and toks[ts + 1].text == "(": cxSkipGroup(toks, ts + 1) else: ts + 1
          let ret = (cxTypeText(toks, ts, tEnd) & (if stars.len > 0: " " & stars else: "")).strip
          let (ps, va) = cxParams(toks, q + 1, p)
          var pl: seq[string]
          for x in ps: pl.add (x.typ & (if x.name.len > 0: " " & x.name else: "")).replace("* ", "*")
          if va: pl.add "..."
          let endL = toks[bodyEnd - 1].line
          var weak = false
          for q in st ..< ni:
            if toks[q].text in ["__extern_always_inline", "__extern_inline", "__fortify_function"]: weak = true
          addSym(CxSym(name: toks[ni].text, kind: cxFunc, line: toks[ni].line, col: toks[ni].col, endLine: endL,
                       typ: (if ret.len > 0: ret else: "int"), params: ps, varargs: va, isDef: not weak, weak: weak,
                       text: (if ret.len > 0: ret else: "int") & " " & toks[ni].text & "(" & pl.join(", ") & ")",
                       doc: cxDocFor(comments, toks[ts].line)))
          for x in ps:
            if x.name.len > 0:
              f.syms.add CxSym(name: x.name, kind: cxParam, line: (if x.line >= 0: x.line else: toks[ni].line),
                               col: max(0, x.col), typ: x.typ, scopeA: toks[ni].line, scopeB: endL,
                               owner: toks[ni].text, text: x.typ & " " & x.name)
          parseBody(k, bodyEnd, toks[ni].text, toks[ni].line, endL)
          k = bodyEnd
          st = k
          continue
      # a struct / union / enum body or an initializer: to its end, then on to the `;`
      k = cxSkipGroup(toks, k)
      continue
    inc k
  if st < toks.len: parseDecl(st, toks.len)

proc cxStampOf(path: string): string =
  try:
    let i = getFileInfo(path)
    $i.lastWriteTime.toUnix & "/" & $i.lastWriteTime.nanosecond & "/" & $i.size
  except CatchableError: ""

proc cxLoad*(path: string, text = "", stamp = "", cpp = cxIsCppPath(path)): CxFile =
  ## a file's index: from `text` (an open buffer, with its own stamp) or from disk; cached until it changes (a file
  ## read from disk does not keep its lines: headers are many). cpp: read as C++ (a header can be read both ways:
  ## each is kept)
  let key = if cpp: "c++:" & path else: path
  if text.len == 0 and stamp.len == 0 and key in cxCache:
    let now = epochTime()
    if now - cxCheckedAt.getOrDefault(key, 0.0) < 1.0: return cxCache[key]
    cxCheckedAt[key] = now
  let st = if stamp.len > 0: stamp else: cxStampOf(path)
  if st.len == 0 and text.len == 0: return nil
  if key in cxCache and cxCache[key].stamp == st: return cxCache[key]
  var t = text
  if t.len == 0 and stamp.len == 0:
    try:
      t = readFile(path)
      if t.len > 6_000_000: t.setLen(6_000_000)
    except CatchableError: return nil
  result = cxParse(t, path, full = text.len > 0, cpp = cpp)
  result.stamp = st
  if text.len == 0: result.lines = @[]
  if cxCache.len > 3000:
    cxCache.clear()
    cxCheckedAt.clear()
  cxCache[key] = result
  if text.len == 0: cxCheckedAt[key] = epochTime()

proc cxFindInclude*(name, fromDir: string): string =
  ## the file an #include names: "x.h" next to the including file first, then the include folders (#include_next,
  ## written "next<x.h>": the folders after the including file's)
  if name.startsWith("next"):
    let n = name[4 .. ^1].strip(chars = {'<', '>', '"'})
    var after = -1
    for i, d in cxDirs:
      if d.strip(leading = false, chars = {'/'}) == fromDir.strip(leading = false, chars = {'/'}): after = i
    for i in after + 1 .. cxDirs.high:
      if cxDirs[i] != fromDir and fileExists(cxDirs[i] / n): return cxDirs[i] / n
    return ""
  let angle = name.startsWith("<")
  let n = name.strip(chars = {'<', '>', '"'})
  if n.isAbsolute: return (if fileExists(n): n else: "")
  if not angle and fileExists(fromDir / n): return fromDir / n
  for d in cxDirs:
    if fileExists(d / n): return d / n
  if angle and fileExists(fromDir / n): return fromDir / n
  ""

var cxClosureCache: Table[string, (string, float, seq[CxFile])]   # path → (its stamp, when, the closure)

proc cxIsSystem(path: string): bool =
  for d in cxSysDirs:
    if path.startsWith(d.strip(leading = false, chars = {'/'}) & "/"): return true
  path.startsWith("/usr/include/") or path.startsWith("/usr/lib/")

proc cxClosure*(f: CxFile, maxFiles = 400): seq[CxFile] =
  ## the file and every file it includes, transitively (each once) — kept a couple of seconds. From C++: the
  ## project's headers read as C++, the system's as C, the C++ library's not at all (<cstdio>: <stdio.h>)
  let now = epochTime()
  let key = if f.cpp: "c++:" & f.path else: f.path
  if key in cxClosureCache:
    let (st, at, files) = cxClosureCache[key]
    if st == f.stamp and now - at < 2.0 and files.len > 0 and files[0] == f: return files
  defer: cxClosureCache[key] = (f.stamp, now, result)
  var seen: HashSet[string]
  var stack = @[f]
  while stack.len > 0 and result.len < maxFiles:
    let g = stack.pop()
    if g == nil or ((if g.cpp: "c++:" else: "") & g.path) in seen: continue
    seen.incl ((if g.cpp: "c++:" else: "") & g.path)
    result.add g
    for (inc0, _) in g.includes:
      var inc = inc0
      if g.cpp and inc.startsWith("<") and '.' notin inc:
        # the C++ library: not read — but <cstdio> is <stdio.h>
        let n = inc.strip(chars = {'<', '>'})
        if n.len > 1 and n[0] == 'c' and n notin ["complex", "chrono", "codecvt", "condition_variable", "charconv",
                                                   "concepts", "coroutine", "compare"]:
          inc = "<" & n[1 .. ^1] & ".h>"
        else: continue
      let p = cxFindInclude(inc, parentDir(g.path))
      if p.len == 0: continue
      let cpp = g.cpp and not cxIsSystem(p)
      if g.cpp and cxIsSystem(p) and ("/c++/" in p or p.splitFile.ext.len == 0): continue
      if ((if cpp: "c++:" else: "") & p) notin seen:
        let h = cxLoad(p, cpp = cpp)
        if h != nil: stack.add h

# ── types ──

proc cxStrip*(t: string): (string, int) =
  ## a C type without qualifiers, and how many pointers deep it is: "const struct p **" → ("struct p", 2)
  var stars = 0
  var words: seq[string]
  for w in t.replace("*", " * ").replace("(*)", " * ").splitWhitespace:
    if w == "*": inc stars
    elif w in CxQualifiers or w.startsWith("__attribute") or w in ["&", "&&"]: discard     # (C++: a reference)
    else: words.add w
  (words.join(" "), stars)

proc cxIndexed(g: CxFile) =
  if g.indexed: return
  g.indexed = true
  for k in 0 ..< g.syms.len:
    template s: untyped = g.syms[k]
    if s.kind in {cxParam, cxLocal, cxLabel}: continue
    g.byName.mgetOrPut(s.name, @[]).add k.int32
    if s.kind == cxField or (g.cpp and s.kind == cxMethod): g.byOwner.mgetOrPut(s.owner, @[]).add k.int32
    if g.cpp:
      if s.scope.len > 0: g.byScope.mgetOrPut(s.scope, @[]).add k.int32
      if s.kind == cxEnumConst and s.owner != s.scope: g.byScope.mgetOrPut(s.owner, @[]).add k.int32

iterator cxNamed*(g: CxFile, name: string): int =
  ## the indexes of g's declarations called `name` (not parameters, locals or labels)
  cxIndexed(g)
  g.byName.withValue(name, ks):
    for k in ks[]: yield k.int

proc cxFindSym*(files: seq[CxFile], name: string, kinds: set[CxKind]): (CxFile, int) =
  for g in files:
    for k in cxNamed(g, name):
      if g.syms[k].kind in kinds: return (g, k)
  (nil, -1)

proc cxDropMarkers(files: seq[CxFile], base: string): string =
  ## a type without the words that are macros meaning nothing to it: export markers (`mod_export struct job`,
  ## `API Foo`) — macros defined empty, or as attributes only
  let ws = base.splitWhitespace
  if ws.len < 2: return base
  var keep: seq[string]
  for w in ws:
    if w notin CxTypeWords and w notin ["struct", "union", "enum"]:
      let (g, k) = cxFindSym(files, w, {cxMacro})
      if g != nil and g.syms[k].params.len == 0 and not g.syms[k].varargs:
        let body = g.syms[k].text["#define ".len + w.len .. ^1].strip
        if body.len == 0 or body.startsWith("__attribute") or body.startsWith("__declspec"): continue
    keep.add w
  keep.join(" ")

proc cxRecord*(files: seq[CxFile], typ: string): (string, int) =
  ## the struct or union a type is (through typedefs): its name as fields know it as their owner, and the
  ## pointer depth left — ("", 0) when it is not one
  var (base, stars) = cxStrip(typ)
  base = cxDropMarkers(files, base)
  for _ in 0 .. 8:
    for kw in ["struct ", "union "]:
      if base.startsWith(kw): return (base[kw.len .. ^1].strip, stars)     # (an anonymous one's name has spaces)
    let w = base.splitWhitespace
    if w.len == 1:
      # a typedef: what it names (a struct named by the typedef only is filed under the typedef's name)
      let (g, k) = cxFindSym(files, w[0], {cxTypedef})
      if g != nil:
        var (b2, s2) = cxStrip(g.syms[k].typ)
        b2 = cxDropMarkers(files, b2)
        let ww = b2.splitWhitespace
        if ww.len == 2 and ww[0] in ["struct", "union"] and ww[1] == w[0]: return (w[0], stars + s2)
        base = b2
        stars += s2
        continue
      let (g2, _) = cxFindSym(files, w[0], {cxStruct, cxUnion})
      if g2 != nil: return (w[0], stars)
    return ("", 0)
  ("", 0)

proc cxFields*(files: seq[CxFile], owner: string): seq[(CxFile, int)] =
  for g in files:
    cxIndexed(g)
    g.byOwner.withValue(owner, ks):
      for k in ks[]: result.add (g, k.int)

func cxLocalsAt*(f: CxFile, line: int): seq[CxSym] =
  ## the parameters, locals and labels seen on `line` (the innermost last)
  for s in f.syms:
    if s.kind in {cxParam, cxLocal, cxLabel} and line >= s.scopeA and line <= s.scopeB and
       (s.kind != cxLocal or s.line <= line): result.add s

proc cxTypeOfName*(files: seq[CxFile], f: CxFile, name: string, line: int): string =
  let ls = cxLocalsAt(f, line)
  for i in countdown(ls.high, 0):
    if ls[i].name == name and ls[i].kind != cxLabel: return ls[i].typ
  let (g, k) = cxFindSym(files, name, {cxVar, cxFunc, cxEnumConst})
  if g != nil:
    let s = g.syms[k]
    return (if s.kind == cxFunc: "fn:" & s.typ else: s.typ)

proc cxTypeOfExpr*(files: seq[CxFile], f: CxFile, expr: string, line: int, depth = 0): string =
  ## the type of `a.b->c[i]`, `p->next`, `get(x).y`, `*pp`, `(struct q *)v` — "" when not known; a name that is
  ## a macro (`#define atime tv[0]`) has its expansion's type
  var s = expr.strip
  var derefs = 0
  while s.startsWith("*"):
    inc derefs
    s = s[1 .. ^1].strip
  var addrOf = false
  if s.startsWith("&"):
    addrOf = true
    s = s[1 .. ^1].strip
  var typ = ""
  var i = 0
  if s.startsWith("("):
    # a cast (type)x, or a parenthesized expression
    var d = 0
    var e = 0
    while e < s.len:
      if s[e] == '(': inc d
      elif s[e] == ')':
        dec d
        if d == 0: break
      inc e
    if e >= s.len: return ""
    let inner = s[1 ..< e].strip
    let rest = s[e + 1 .. ^1].strip
    let words = inner.replace("*", " ").splitWhitespace
    if words.len > 0 and (words[0] in CxTypeWords or cxFindSym(files, words[0], {cxTypedef})[0] != nil) and
       rest.len > 0 and rest[0] notin {'.', '-', '['}:
      typ = inner                            # (struct q *)v
      i = s.len
    else:
      typ = cxTypeOfExpr(files, f, inner, line, depth + 1)
      i = e + 1
  else:
    var e = 0
    while e < s.len and s[e] in IdentChars: inc e
    if e == 0: return ""
    let name = s[0 ..< e]
    typ = cxTypeOfName(files, f, name, line)
    i = e
    if typ.len == 0 and depth < 4:
      # a macro: its expansion's type — `#define atime tv[0]`, `#define P_OPERAND(p) ((Upat)(p) + 1)` with the
      # arguments put in
      let (g, k) = cxFindSym(files, name, {cxMacro})
      if g != nil and not g.syms[k].text.endsWith("…"):
        let m = g.syms[k]
        var body = m.text["#define ".len + name.len .. ^1]
        if m.params.len == 0 and not m.varargs and not body.startsWith("("):
          if body.strip.len > 0: typ = cxTypeOfExpr(files, f, body.strip, line, depth + 1)
        elif body.startsWith("("):
          let pe = body.find(')')
          var j = i
          while j < s.len and s[j] == ' ': inc j
          if pe > 0 and j < s.len and s[j] == '(':
            body = body[pe + 1 .. ^1].strip
            # the arguments, at the call's top-level commas
            var d = 0
            var a = j + 1
            var args: seq[string]
            var q = j
            while q < s.len:
              if s[q] in {'(', '['}: inc d
              elif s[q] in {')', ']'}:
                dec d
                if d == 0:
                  args.add s[a ..< q].strip
                  break
              elif s[q] == ',' and d == 1:
                args.add s[a ..< q].strip
                a = q + 1
              inc q
            if q < s.len and args.len == m.params.len:
              var ex = ""
              var r = 0
              while r < body.len:                       # each parameter, as a whole word, by its argument
                if body[r] in IdentStartChars and (r == 0 or body[r - 1] notin IdentChars):
                  var t = r
                  while t < body.len and body[t] in IdentChars: inc t
                  let w = body[r ..< t]
                  var hit = -1
                  for pi, prm in m.params:
                    if prm.name == w: hit = pi
                  ex.add(if hit >= 0: "(" & args[hit] & ")" else: w)
                  r = t
                else:
                  ex.add body[r]
                  inc r
              typ = cxTypeOfExpr(files, f, ex, line, depth + 1)
              i = q + 1
  while i < s.len:
    while i < s.len and s[i] == ' ': inc i
    if i >= s.len: break
    if s[i] == '(':
      # a call: what the function returns
      var d = 0
      var e = i
      while e < s.len:
        if s[e] == '(': inc d
        elif s[e] == ')':
          dec d
          if d == 0: break
        inc e
      typ = if typ.startsWith("fn:"): typ[3 .. ^1] else: ""
      i = e + 1
    elif s[i] == '[':
      var d = 0
      var e = i
      while e < s.len:
        if s[e] == '[': inc d
        elif s[e] == ']':
          dec d
          if d == 0: break
        inc e
      let (b, st) = cxStrip(typ)
      typ = b & (if st > 1: " " & "*".repeat(st - 1) else: "")
      i = e + 1
    elif s[i] == '.' or s.continuesWith("->", i):
      i += (if s[i] == '.': 1 else: 2)
      var e = i
      while e < s.len and s[e] in IdentChars: inc e
      let m = s[i ..< e]
      let (rec, _) = cxRecord(files, typ)
      if rec.len == 0: return ""
      typ = ""
      for (g, k) in cxFields(files, rec):
        if g.syms[k].name == m:
          typ = g.syms[k].typ
          break
      if typ.len == 0: return ""
      i = e
    else: break
  if typ.startsWith("fn:"): typ = typ[3 .. ^1]
  if derefs > 0:
    let (b, st) = cxStrip(typ)
    typ = b & (if st > derefs: " " & "*".repeat(st - derefs) else: "")
  if addrOf: typ = typ & " *"
  typ

# ── answers ──

type
  CxItem* = object
    label*, detail*, doc*: string
    kind*: CxKind
    rank*: int                  # 0 locals · 1 this file · 2 its headers · 3 system headers · 4 keywords
    insert*: string

func cxAfterWord(t: string, at: int, words: openArray[string]): bool =
  ## is the text before `at` one of `words` (as a whole word, spaces between)
  var e = at
  while e > 0 and t[e - 1] in {' ', '\t'}: dec e
  for w in words:
    if e >= w.len and t[e - w.len ..< e] == w and (e == w.len or t[e - w.len - 1] notin IdentChars): return true

func cxReceiver*(line: string, endAt: int): string =
  ## the expression before `.` or `->` that ends at endAt (exclusive): `a.b[i]->` → "a.b[i]", `get(x)` → "get(x)"
  var k = endAt - 1
  var d = 0
  while k >= 0:
    let c = line[k]
    if c in {')', ']'} and d == 0 and k + 1 < endAt and line[k + 1] in IdentChars: break   # (T)x.y: x.y, cast
    if c in {')', ']'}: inc d
    elif c in {'(', '['}:
      if d == 0: break
      dec d
    elif d > 0: discard
    elif c in IdentChars or c == '.': discard
    elif c == '>' and k > 0 and line[k - 1] == '-': dec k
    else: break
    dec k
  line[k + 1 ..< endAt].strip

proc cxInitType*(files: seq[CxFile], f: CxFile, line, col: int, depth = 0): string =
  ## the type a brace initializer initializes at line:col (inside its braces) — for `.member =` designators:
  ## `struct p v = { .x = 1, .` → "struct p"; `{ .at = { .` → at's type; `arr[] = { { .` → arr's element type
  if depth > 6: return ""
  var d = 0
  var l = min(line, f.lines.high)
  while l >= max(0, line - 60):
    let t = f.lines[l]
    var k = (if l == line: min(col, t.len) else: t.len) - 1
    while k >= 0:
      let ch = t[k]
      if ch == '}': inc d
      elif ch == ';' and d == 0: return ""
      elif ch == '{':
        if d > 0:
          dec d
          dec k
          continue
        # what comes before the {: `name =`, `.member =`, or `{` / `,` (an element of an array)
        var bl = l
        var bk = k - 1
        while true:
          while bk >= 0 and f.lines[bl][bk] in {' ', '\t'}: dec bk
          if bk >= 0 or bl == 0 or bl <= line - 60: break
          dec bl
          bk = f.lines[bl].len - 1
        if bk < 0: return ""
        let bt = f.lines[bl]
        if bt[bk] in {'{', ','}:
          # an element: the outer initializer's type, one level less
          let outer = cxInitType(files, f, bl, (if bt[bk] == '{': bk + 1 else: bk), depth + 1)
          let (b, st) = cxStrip(outer)
          return (if st > 0: b & (if st > 1: " " & "*".repeat(st - 1) else: "") else: "")
        if bt[bk] != '=': return ""
        dec bk
        while bk >= 0 and bt[bk] in {' ', '\t'}: dec bk
        while bk >= 0 and bt[bk] == ']':                 # name[] = { … }, name[N] = { … }: the array's type
          while bk >= 0 and bt[bk] != '[': dec bk
          dec bk
          while bk >= 0 and bt[bk] in {' ', '\t'}: dec bk
        var a = bk
        while a >= 0 and bt[a] in IdentChars: dec a
        let name = bt[a + 1 .. bk]
        if name.len == 0: return ""
        var p = a
        while p >= 0 and bt[p] in {' ', '\t'}: dec p
        if p >= 0 and bt[p] == '.':
          # a nested designator: the member's type in the outer initializer's
          let outer = cxInitType(files, f, bl, p, depth + 1)
          let (rec, _) = cxRecord(files, outer)
          if rec.len == 0: return ""
          for (g, q) in cxFields(files, rec):
            if g.syms[q].name == name: return g.syms[q].typ
          return ""
        let typ = cxTypeOfName(files, f, name, bl)
        return (if typ.startsWith("fn:"): "" else: typ)
      dec k
    dec l
  ""

proc cxIncludeItems(f: CxFile, t: string, col: int, systemDirs: seq[string]): (bool, seq[CxItem]) =
  ## on an #include line: the headers the folders have, after what is typed (`<sys/ty` → sys/'s headers) — the
  ## file's own folder first, then the project's, then the system's
  let s = t.strip(trailing = false)
  if not (s.startsWith("#include") or s.startsWith("# include")): return
  var q = -1
  for k in 0 ..< min(col, t.len):
    if t[k] in {'<', '"'}: q = k
  if q < 0: return
  result[0] = true
  let typed = t[q + 1 ..< min(col, t.len)]
  let slash = typed.rfind('/')
  let sub = if slash >= 0: typed[0 .. slash] else: ""
  let pre = if slash >= 0: typed[slash + 1 .. ^1] else: typed
  var dirs: seq[string]
  if t[q] == '"' and f.path.len > 0: dirs.add parentDir(f.path)
  dirs.add cxDirs
  var seen: HashSet[string]
  for di, d in dirs:
    let dd = d / sub
    if not dirExists(dd): continue
    var rank = 2
    if di == 0 and t[q] == '"': rank = 1
    else:
      for sd in systemDirs:
        if d.startsWith(sd): rank = 3
    for kind, p in walkDir(dd, relative = true):
      if not p.startsWith(pre) or p in seen or p.startsWith("."): continue
      if kind in {pcDir, pcLinkToDir}:
        seen.incl p
        result[1].add CxItem(label: p & "/", detail: "folder", kind: cxMacro, rank: rank)
      elif p.endsWith(".h") or p.endsWith(".hpp") or p.endsWith(".hh") or ('.' notin p and sub.len > 0):
        seen.incl p
        result[1].add CxItem(label: p, detail: d / sub, kind: cxMacro, rank: rank)
      if result[1].len > 400: return

func cxWordAt*(t: string, col: int): (int, int) =
  var a = min(col, t.len)
  var e = a
  while a > 0 and t[a - 1] in IdentChars: dec a
  while e < t.len and t[e] in IdentChars: inc e
  (a, e)

# ── C++ answers: names looked up from where they are written (the namespaces around, `using namespace`, the class
#    whose method it is and its bases), members through templates and the library's common types ──

func cxxStrip(t: string): (string, int) =
  ## a C++ type without qualifiers and references, and how many pointers deep it is — its template arguments as
  ## they are: "const std::vector<Foo *> &" → ("std::vector<Foo *>", 0)
  var d = 0
  var words: seq[string]
  var cur = ""
  var stars = 0
  for ch in t.replace("(*)", "*"):
    if ch == '<': inc d
    elif ch == '>': dec d
    if d == 0 and ch in {'*', '&', ' ', '\t'}:
      if ch == '*': inc stars
      if cur.len > 0: words.add cur
      cur = ""
      continue
    cur.add ch
  if cur.len > 0: words.add cur
  var keep: seq[string]
  for w in words:
    if w notin CxQualifiers and w != "typename" and not w.startsWith("__attribute"): keep.add w
  (keep.join(" "), stars)

type CxxCtx = object
  scopes: seq[string]           # where a name is looked for, the nearest first ("" — the file level — last)
  cls: string                   # in a method's body: its class (qualified), else ""

func cxxJoin(scope, name: string): string = (if scope.len > 0: scope & "::" & name else: name)

func cxxOwnersMatch(a, b: string): bool =
  ## a method's class as written outside it (`Point::norm`) and as declared (`geo::Point`): the same class?
  a == b or a.endsWith("::" & b) or b.endsWith("::" & a)

func cxxSpecial(s: CxSym): bool =
  ## a constructor, a destructor, an operator: not offered by name
  s.name.startsWith("operator") or
    (s.kind == cxMethod and (s.name.startsWith("~") or s.name == cxxSplit(s.owner)[^1]))

func cxxStdGroup(base: string, bare: bool): string =
  ## the library type a type is (what CxxStdMembers knows: string vector map set unique_ptr …), "" when none;
  ## bare: `vector` without std:: counts too
  var b = base.strip
  if b.startsWith("std::"): b = b[5 .. ^1]
  elif not bare: return ""
  case b
  of "string", "wstring", "string_view", "u8string", "basic_string": "string"
  of "vector", "deque", "list", "forward_list", "span", "initializer_list": "vector"
  of "map", "unordered_map", "multimap", "unordered_multimap": "map"
  of "set", "unordered_set", "multiset", "unordered_multiset": "set"
  of "unique_ptr": "unique_ptr"
  of "shared_ptr", "weak_ptr": "shared_ptr"
  of "optional": "optional"
  of "pair": "pair"
  of "array": "array"
  else: ""

func cxxSubst(t: string, params, args: seq[string]): string =
  ## a template's parameters in a type put in for its arguments: "T &" with T = Point → "Point &"
  if params.len == 0 or args.len == 0: return t
  var i = 0
  while i < t.len:
    if t[i] in IdentStartChars and (i == 0 or t[i - 1] notin IdentChars):
      var e = i
      while e < t.len and t[e] in IdentChars: inc e
      let w = t[i ..< e]
      let p = params.find(w)
      result.add(if p >= 0 and p < args.len: args[p] else: w)
      i = e
    else:
      result.add t[i]
      inc i

func cxxStdSubst(t, grp: string, args: seq[string]): string =
  let ps = case grp
           of "map": @["K", "V"]
           of "pair": @["T", "U"]
           else: @["T"]
  cxxSubst(t, ps, args)

proc cxxFindClass(files: seq[CxFile], name: string, scopes: seq[string]): (CxFile, int) =
  ## the class (struct, union) a name means, seen from these scopes: "Point", "geo::Point", "Box<int>"
  var b = cxxNoArgs(name).strip
  if b.startsWith("::"): b = b[2 .. ^1]
  for kw in ["struct ", "class ", "union "]:
    if b.startsWith(kw): b = b[kw.len .. ^1].strip
  if b.len == 0 or ' ' in b: return (nil, -1)
  let short = cxxSplit(b)[^1]
  var best = (CxFile(nil), -1)
  var bestScore = 0
  for g in files:
    for k in cxNamed(g, short):
      let s = g.syms[k]
      if s.kind notin {cxClass, cxStruct, cxUnion}: continue
      let q = cxxQual(s)
      var score = 0
      for i, sc in scopes:
        if cxxJoin(sc, b) == q:
          score = max(score, 20 - min(i, 10))
          break
      if score == 0 and q == b: score = 9
      elif score == 0 and q.endsWith("::" & b): score = 5
      elif score == 0 and "::" notin b: score = 2
      score = score * 2 + ord(s.isDef)
      if score > bestScore:
        bestScore = score
        best = (g, k)
  best

proc cxxFindAlias(files: seq[CxFile], name: string, scopes: seq[string]): string =
  ## what a typedef or `using T = …` seen from these scopes names ("" when none)
  var b = cxxNoArgs(name).strip
  if b.startsWith("::"): b = b[2 .. ^1]
  let short = cxxSplit(b)[^1]
  var bestScore = 0
  for g in files:
    for k in cxNamed(g, short):
      let s = g.syms[k]
      if s.kind != cxTypedef: continue
      let q = cxxQual(s)
      var score = 1
      for i, sc in scopes:
        if cxxJoin(sc, b) == q:
          score = 20 - min(i, 10)
          break
      if score == 1 and q.endsWith("::" & b): score = 5
      if score > bestScore:
        bestScore = score
        result = s.typ

proc cxxRecord(files: seq[CxFile], typ: string, scopes: seq[string], depth = 0): (string, seq[string], CxSym) =
  ## the class a C++ type is — its qualified name (its members' owner), its template's arguments, the class —
  ## through typedefs and `using T = …`; "" when it is not one
  var (base, _) = cxxStrip(typ)
  for kw in ["struct ", "class ", "union ", "typename "]:
    if base.startsWith(kw): base = base[kw.len .. ^1].strip
  if base.len == 0 or depth > 8 or base == "auto": return
  let (g, k) = cxxFindClass(files, base, scopes)
  if g != nil: return (cxxQual(g.syms[k]), cxxArgs(base), g.syms[k])
  let al = cxxFindAlias(files, base, scopes)
  if al.len > 0: return cxxRecord(files, al, scopes, depth + 1)

proc cxxMembers(files: seq[CxFile], key: string, scopes: seq[string], all: bool, args: seq[string] = @[],
                depth = 0): seq[(CxFile, int, seq[string], seq[string])] =
  ## a class's members — fields and methods; all: its nested types, typedefs and enums' constants too — then its
  ## bases' (the derived class's first); each with its class's template parameters and the arguments given them
  var cls: CxSym
  var found = false
  for g in files:
    for k in cxNamed(g, cxxSplit(key)[^1]):
      let s = g.syms[k]
      if s.kind in {cxClass, cxStruct, cxUnion} and cxxQual(s) == key and (not found or s.isDef):
        cls = s
        found = true
  for g in files:
    cxIndexed(g)
    if all:
      g.byScope.withValue(key, ks):
        for k in ks[]: result.add (g, k.int, cls.tparams, args)
      if not g.cpp:
        g.byOwner.withValue(key, ks):
          for k in ks[]: result.add (g, k.int, cls.tparams, args)
    else:
      g.byOwner.withValue(key, ks):
        for k in ks[]: result.add (g, k.int, cls.tparams, args)
  if found and depth < 6:
    for b in cls.bases:
      let bt = cxxSubst(b, cls.tparams, args)
      let (bk, bargs, _) = cxxRecord(files, bt, @[cls.scope] & scopes)
      if bk.len > 0 and bk != key: result.add cxxMembers(files, bk, scopes, all, bargs, depth + 1)

proc cxxBaseKeys(files: seq[CxFile], key: string, scopes: seq[string], depth = 0): seq[string] =
  ## a class's bases, qualified, and theirs
  if depth > 6: return
  for g in files:
    for k in cxNamed(g, cxxSplit(key)[^1]):
      let s = g.syms[k]
      if s.kind in {cxClass, cxStruct, cxUnion} and s.isDef and cxxQual(s) == key:
        for b in s.bases:
          let (bk, _, _) = cxxRecord(files, b, @[s.scope] & scopes)
          if bk.len > 0 and bk != key and bk notin result:
            result.add bk
            result.add cxxBaseKeys(files, bk, scopes, depth + 1)

func cxxWithParents(q: string): seq[string] =
  ## a namespace and those around it: "a::b" → a::b, a
  var x = q
  while x.len > 0:
    result.add x
    let k = x.rfind("::")
    x = if k >= 0: x[0 ..< k] else: ""

proc cxxIsSpace(files: seq[CxFile], q: string): bool =
  ## does one of the files declare the namespace q (qualified)?
  for g in files:
    for (x, _, _) in g.spaces:
      if x == q or x.endsWith("::" & q): return true

func cxxSameDecl(x, s: CxSym): bool =
  ## two declarations of one function, method, variable or field (one of them may be its definition) — a method
  ## defined outside its class, or a namespace's function as `int ns::f() { … }`, by the class (namespace) named
  let mx = x.kind in {cxMethod, cxField}
  let ms = s.kind in {cxMethod, cxField}
  if not mx and not ms: return x.kind == s.kind and x.scope == s.scope
  let ox = if mx: x.owner else: x.scope
  let os = if ms: s.owner else: s.scope
  (x.kind == s.kind or {x.kind, s.kind} == {cxMethod, cxFunc} or {x.kind, s.kind} == {cxField, cxVar}) and
    cxxOwnersMatch(ox, os)

proc cxxCtxAt(files: seq[CxFile], f: CxFile, line: int): CxxCtx =
  ## where names are looked for at `line`
  var inside: seq[string]
  for (q, a, b) in f.spaces:
    if line >= a and line <= b and q notin inside: inside.add q
  inside.sort(proc(x, y: string): int = cmp(y.len, x.len))
  var sp: seq[string]
  # in a method: its class, its bases, the class's namespace; in `int a::b::f() { … }`: a::b
  var fn = -1
  for k in 0 ..< f.syms.len:
    template s: untyped = f.syms[k]
    if s.kind in {cxFunc, cxMethod} and s.isDef and line >= s.line and line <= s.endLine:
      if fn < 0 or s.line >= f.syms[fn].line: fn = k
  if fn >= 0:
    let s = f.syms[fn]
    if s.kind == cxMethod:
      let near = (if s.scope.len > 0: cxxWithParents(s.scope) else: @[]) & inside
      let (key, _, cs) = cxxRecord(files, s.owner, near & @[""])
      if key.len == 0 and cxxIsSpace(files, s.owner):
        sp.add cxxWithParents(s.owner)             # int geo::detail::next() { … }: a namespace's function
      else:
        result.cls = if key.len > 0: key else: s.owner
        sp.add result.cls
        for bk in cxxBaseKeys(files, result.cls, near & @[""]): sp.add bk
        if key.len > 0 and cs.scope.len > 0: sp.add cxxWithParents(cs.scope)
    elif s.scope.len > 0 and s.scope != s.owner: sp.add cxxWithParents(s.scope)
  for q in inside:
    for x in cxxWithParents(q):
      if x notin sp: sp.add x
  # using namespace x: this file's (above the line), its headers' (anywhere)
  var used: seq[string]
  for g in files:
    for (u0, l) in g.usings:
      if g == f and l > line: continue
      let u = if u0.startsWith("::"): u0[2 .. ^1] else: u0
      for q in sp & @[""]:
        let x = cxxJoin(q, u)
        if x notin used: used.add x
  for x in used:
    if x notin sp: sp.add x
  sp.add ""
  result.scopes = sp

func cxxBareVisible(s: CxSym, scopes: seq[string]): bool =
  ## can s be named without a qualifier from where `scopes` are seen?
  case s.kind
  of cxParam, cxLocal, cxLabel: false
  of cxField: s.scope.len > 0 and s.scope in scopes
  of cxMethod: s.scope == s.owner and s.scope in scopes
  else: s.scope in scopes

proc cxxTypeOfExpr(files: seq[CxFile], f: CxFile, expr: string, line: int, ctx: CxxCtx, depth = 0): string

proc cxxAutoType(files: seq[CxFile], f: CxFile, s: CxSym, ctx: CxxCtx, depth: int): string =
  ## a variable's type — `auto`'s: what initializes it (a range-for's element: the container's element)
  if s.init.len == 0 or "auto" notin s.typ.splitWhitespace or depth > 6: return s.typ
  var t = ""
  if s.init.startsWith("@elem:"):
    let ct = cxxTypeOfExpr(files, f, s.init[6 .. ^1], s.line, ctx, depth + 1)
    let (b, stars) = cxxStrip(ct)
    let args = cxxArgs(b)
    let grp = if cxxFindClass(files, b, ctx.scopes)[0] == nil: cxxStdGroup(cxxNoArgs(b), true) else: ""
    t = case grp
        of "vector", "set", "array": (if args.len > 0: args[0] else: "")
        of "map": (if args.len > 1: "std::pair<" & args[0] & ", " & args[1] & ">" else: "")
        of "string": "char"
        else: (if stars > 0: b & (if stars > 1: " " & "*".repeat(stars - 1) else: "") else: "")
  else:
    t = cxxTypeOfExpr(files, f, s.init, s.line, ctx, depth + 1)
    if t.startsWith("fn:"): t = t[3 .. ^1]
  if t.len == 0: s.typ else: t

proc cxxTypeOfName(files: seq[CxFile], f: CxFile, name: string, line: int, ctx: CxxCtx, depth: int): string =
  ## a name's type seen from `line`: a local, a member of the class whose method this is, a variable or function
  ## (functions: "fn:" & what they return)
  let ls = cxLocalsAt(f, line)
  for i in countdown(ls.high, 0):
    if ls[i].name == name and ls[i].kind != cxLabel: return cxxAutoType(files, f, ls[i], ctx, depth)
  if name == "this": return (if ctx.cls.len > 0: ctx.cls & " *" else: "")
  if ctx.cls.len > 0:
    for (g, k, tps, args) in cxxMembers(files, ctx.cls, ctx.scopes, all = false):
      let s = g.syms[k]
      if s.name == name: return (if s.kind == cxMethod: "fn:" & s.typ else: s.typ)
  var best: CxSym
  var found = 0
  for g in files:
    for k in cxNamed(g, name):
      let s = g.syms[k]
      if s.kind notin {cxVar, cxFunc, cxEnumConst}: continue
      let v = if cxxBareVisible(s, ctx.scopes): 2 else: 1
      if v > found:
        found = v
        best = s
  if found > 0:
    let t = cxxAutoType(files, f, best, ctx, depth)
    return (if best.kind == cxFunc: "fn:" & t else: t)

proc cxxScopeSyms(files: seq[CxFile], qual: string, scopes: seq[string]): seq[(CxFile, int)] =
  ## what is declared in the scope `qual` names: a class's members (its bases' too), a namespace's names, an
  ## enum's constants
  let (key, _, _) = cxxRecord(files, qual, scopes)
  if key.len > 0:
    for (g, k, _, _) in cxxMembers(files, key, scopes, all = true): result.add (g, k)
    return
  var q = cxxNoArgs(qual)
  if q.startsWith("::"): q = q[2 .. ^1]
  var keys: seq[string]
  for sc in scopes:
    let x = cxxJoin(sc, q)
    if x notin keys: keys.add x
  for g in files:
    for k in cxNamed(g, cxxSplit(q)[^1]):
      let s = g.syms[k]
      if s.kind == cxEnum and (cxxQual(s) == q or cxxQual(s).endsWith("::" & q)) and cxxQual(s) notin keys:
        keys.add cxxQual(s)
  for g in files:
    cxIndexed(g)
    for key in keys:
      g.byScope.withValue(key, ks):
        for k in ks[]: result.add (g, k.int)

proc cxxMemberType(files: seq[CxFile], typ, m: string, arrow: bool, ctx: CxxCtx): string =
  ## the type of `x.m` (`x->m`), x of type typ ("fn:" & what it returns for a method)
  let (b, _) = cxxStrip(typ)
  let plain = cxxNoArgs(b)
  let args = cxxArgs(b)
  let user = cxxFindClass(files, plain, ctx.scopes)[0] != nil
  let grp = if user: "" else: cxxStdGroup(plain, true)
  if grp in ["unique_ptr", "shared_ptr"] and arrow and args.len > 0:
    return cxxMemberType(files, args[0], m, false, ctx)            # p->x: the object's x
  if grp.len > 0:
    for (g0, mem, mt, _) in CxxStdMembers:
      if g0 == grp and mem == m: return cxxStdSubst(mt, grp, args)
    return ""
  let (key, rargs, _) = cxxRecord(files, b, ctx.scopes)
  if key.len == 0: return ""
  for (g, k, tps, targs) in cxxMembers(files, key, ctx.scopes, all = false, args = rargs):
    let s = g.syms[k]
    if s.name == m:
      let t = cxxSubst(s.typ, tps, targs)
      return (if s.kind == cxMethod: "fn:" & t else: t)

func cxxNameEnd(s: string, a: int): int =
  ## past a C++ name at s[a]: a::b::c, with template arguments (Box<int>)
  var i = a
  while i < s.len:
    if s[i] in IdentChars: inc i
    elif s.continuesWith("::", i) and i + 2 < s.len and s[i + 2] in IdentStartChars: i += 2
    elif s[i] == '<' and i > a:
      var d = 0
      var j = i
      while j < s.len:
        if s[j] == '<': inc d
        elif s[j] == '>':
          dec d
          if d == 0: break
        elif s[j] in {';', '{', '}', '='} or s.continuesWith("&&", j) or s.continuesWith("||", j): break
        inc j
      if j >= s.len or s[j] != '>': break
      i = j + 1
    else: break
  i

func cxxGroupEnd(s: string, i: int): int =
  ## s[i] opens ( [ {: the index of what closes it (s.len when nothing does)
  var d = 0
  var j = i
  while j < s.len:
    if s[j] in {'(', '[', '{'}: inc d
    elif s[j] in {')', ']', '}'}:
      dec d
      if d == 0: return j
    elif s[j] in {'"', '\''}:
      let q = s[j]
      inc j
      while j < s.len and s[j] != q:
        if s[j] == '\\': inc j
        inc j
    inc j
  s.len

proc cxxTypeOfExpr(files: seq[CxFile], f: CxFile, expr: string, line: int, ctx: CxxCtx, depth = 0): string =
  ## the type of a C++ expression: `a.b->c[i]`, `this->x`, `new Foo(…)`, `Foo{…}`, `ns::f()`, `Color::Red`,
  ## `static_cast<T>(x)`, `std::make_unique<T>(…)`, smart pointers, the library's containers — "" when not known
  if depth > 8: return ""
  var s = expr.strip
  var derefs = 0
  while s.startsWith("*"):
    inc derefs
    s = s[1 .. ^1].strip
  var addrOf = false
  if s.startsWith("&") and not s.startsWith("&&"):
    addrOf = true
    s = s[1 .. ^1].strip
  var typ = ""
  var i = 0
  if s.startsWith("new ") or s.startsWith("new\t"):
    var a = 3
    while a < s.len and s[a] in {' ', '\t'}: inc a
    let e = cxxNameEnd(s, a)
    if e == a: return ""
    typ = s[a ..< e] & " *"
    i = e
    while i < s.len and s[i] == ' ': inc i
    if i < s.len and s[i] in {'(', '{', '['}: i = cxxGroupEnd(s, i) + 1
  elif s.startsWith("("):
    let e = cxxGroupEnd(s, 0)
    if e >= s.len: return ""
    let inner = s[1 ..< e].strip
    let rest = s[e + 1 .. ^1].strip
    let words = inner.replace("*", " ").replace("&", " ").splitWhitespace
    if words.len > 0 and rest.len > 0 and rest[0] notin {'.', '-', '['} and
       (words[0] in CxTypeWords or cxxFindClass(files, words[0], ctx.scopes)[0] != nil or
        cxxFindAlias(files, words[0], ctx.scopes).len > 0):
      typ = inner                                     # (Foo *)p
      i = s.len
    else:
      typ = cxxTypeOfExpr(files, f, inner, line, ctx, depth + 1)
      i = e + 1
  else:
    let e = cxxNameEnd(s, 0)
    if e == 0: return ""
    let name = s[0 ..< e]
    var plain = cxxNoArgs(name)
    if plain.startsWith("::"): plain = plain[2 .. ^1]
    i = e
    var j = i
    while j < s.len and s[j] == ' ': inc j
    let args = cxxArgs(name)
    if plain in ["static_cast", "dynamic_cast", "reinterpret_cast", "const_cast", "std::static_pointer_cast",
                 "std::dynamic_pointer_cast"] and args.len > 0:
      typ = if plain.startsWith("std::"): "std::shared_ptr<" & args[0] & ">" else: args[0]
      if j < s.len and s[j] == '(': i = cxxGroupEnd(s, j) + 1
    elif plain in ["std::make_unique", "make_unique", "std::make_shared", "make_shared"] and args.len > 0:
      typ = (if "unique" in plain: "std::unique_ptr<" else: "std::shared_ptr<") & args[0] & ">"
      if j < s.len and s[j] == '(': i = cxxGroupEnd(s, j) + 1
    elif plain in ["std::move", "move", "std::forward", "forward"] and j < s.len and s[j] == '(':
      let ce = cxxGroupEnd(s, j)
      typ = cxxTypeOfExpr(files, f, s[j + 1 ..< min(ce, s.len)], line, ctx, depth + 1)
      i = ce + 1
    elif j < s.len and s[j] in {'(', '{'} and
         (cxxFindClass(files, plain, ctx.scopes)[0] != nil or cxxStdGroup(plain, false).len > 0):
      typ = name                                      # Foo(…), Foo{…}: a Foo made
      i = cxxGroupEnd(s, j) + 1
    elif "::" in plain:
      # Class::member, ns::name, Enum::Constant
      let parts = cxxSplit(plain)
      let qual = parts[0 ..< ^1].join("::")
      for (g, k) in cxxScopeSyms(files, qual, ctx.scopes):
        let x = g.syms[k]
        if x.name == parts[^1] and x.kind in {cxVar, cxFunc, cxMethod, cxField, cxEnumConst}:
          typ = (if x.kind in {cxFunc, cxMethod}: "fn:" & x.typ else: cxxAutoType(files, f, x, ctx, depth))
          break
    else:
      typ = cxxTypeOfName(files, f, plain, line, ctx, depth)
  while i < s.len:
    while i < s.len and s[i] == ' ': inc i
    if i >= s.len: break
    if s[i] == '(':
      typ = if typ.startsWith("fn:"): typ[3 .. ^1] else: ""
      i = cxxGroupEnd(s, i) + 1
    elif s[i] == '[':
      if typ.startsWith("fn:"): return ""
      let (b, st) = cxxStrip(typ)
      let args = cxxArgs(b)
      let grp = if st == 0 and cxxFindClass(files, b, ctx.scopes)[0] == nil: cxxStdGroup(cxxNoArgs(b), true) else: ""
      typ = case grp
            of "vector", "array": (if args.len > 0: args[0] else: "")
            of "map": (if args.len > 1: args[1] else: "")
            of "string": "char"
            else: b & (if st > 1: " " & "*".repeat(st - 1) else: "")
      i = cxxGroupEnd(s, i) + 1
    elif s[i] == '.' or s.continuesWith("->", i):
      let arrow = s[i] == '-'
      i += (if arrow: 2 else: 1)
      var e = i
      while e < s.len and s[e] in IdentChars: inc e
      if typ.startsWith("fn:"): return ""
      typ = cxxMemberType(files, typ, s[i ..< e], arrow, ctx)
      if typ.len == 0: return ""
      i = e
    else: break
  if typ.startsWith("fn:") and i >= s.len and depth == 0: typ = typ[3 .. ^1]
  if derefs > 0:
    let (b, st) = cxxStrip(typ)
    let args = cxxArgs(b)
    let grp = if st == 0 and cxxFindClass(files, b, ctx.scopes)[0] == nil: cxxStdGroup(cxxNoArgs(b), true) else: ""
    if grp in ["unique_ptr", "shared_ptr", "optional"] and args.len > 0: typ = args[0]
    else: typ = b & (if st > derefs: " " & "*".repeat(st - derefs) else: "")
  if addrOf: typ = typ & " *"
  typ

func cxxReceiver(line: string, endAt: int): string =
  ## the expression before `.` or `->` that ends at endAt: C's, and `a::b()`, `Box<int>{}`, `make<T>(x)`
  var k = endAt - 1
  var d = 0
  while k >= 0:
    let c = line[k]
    if c in {')', ']', '}'} and d == 0 and k + 1 < endAt and line[k + 1] in IdentChars: break
    if c in {')', ']', '}'}: inc d
    elif c in {'(', '[', '{'}:
      if d == 0: break
      dec d
    elif d > 0: discard
    elif c in IdentChars or c in {'.', ':'}: discard
    elif c == '>' and k > 0 and line[k - 1] == '-': dec k
    elif c == '>':
      var dd = 0
      var j = k
      while j >= 0:
        if line[j] == '>': inc dd
        elif line[j] == '<':
          dec dd
          if dd == 0: break
        elif line[j] in {';', '(', ')', '='}: break
        dec j
      if j < 0 or line[j] != '<' or j == 0 or line[j - 1] notin IdentChars: break
      k = j
    else: break
    dec k
  line[k + 1 ..< endAt].strip

func cxxQualBefore(t: string, at: int): string =
  ## the qualifier written before the `::` at t[at]: "geo::detail", "Color", "Box<int>"
  var k = at - 1
  while k >= 0:
    let c = t[k]
    if c in IdentChars or c == ':': dec k
    elif c == '>':
      var dd = 0
      var j = k
      while j >= 0:
        if t[j] == '>': inc dd
        elif t[j] == '<':
          dec dd
          if dd == 0: break
        dec j
      if j <= 0: break
      k = j - 1
    else: break
  t[k + 1 ..< at].strip

proc cxxMemberItems(files: seq[CxFile], typ: string, arrow: bool, ctx: CxxCtx): seq[CxItem] =
  ## after `x.` or `x->`: the members of x's class and its bases, or of the library's type
  let (b, _) = cxxStrip(typ)
  let plain = cxxNoArgs(b)
  let args = cxxArgs(b)
  let user = cxxFindClass(files, plain, ctx.scopes)[0] != nil
  let grp = if user: "" else: cxxStdGroup(plain, true)
  if grp in ["unique_ptr", "shared_ptr"] and arrow and args.len > 0:
    return cxxMemberItems(files, args[0], false, ctx)
  if grp.len > 0:
    for (g0, mem, mt, d) in CxxStdMembers:
      if g0 == grp:
        let t = cxxStdSubst(mt, grp, args)
        result.add CxItem(label: mem, detail: (if t.startsWith("fn:"): t[3 .. ^1] & " " & d.split(':')[0] else: t),
                          doc: d, kind: (if t.startsWith("fn:"): cxMethod else: cxField), rank: 0)
    return
  let (key, rargs, _) = cxxRecord(files, b, ctx.scopes)
  if key.len == 0: return
  var seen: HashSet[string]
  for (g, k, tps, targs) in cxxMembers(files, key, ctx.scopes, all = false, args = rargs):
    let s = g.syms[k]
    if s.name in seen or cxxSpecial(s) or (s.kind == cxMethod and s.scope != s.owner) or
       s.name.startsWith("(anonymous"): continue
    seen.incl s.name
    result.add CxItem(label: s.name, detail: cxxSubst((if s.kind == cxMethod: s.text else: s.typ), tps, targs),
                      doc: s.doc, kind: s.kind, rank: 0)

proc cxxComplete(f: CxFile, line, col: int, systemDirs: seq[string]): (seq[CxItem], bool, string) =
  let t = f.lines[line]
  let c = min(col, t.len)
  var w = c
  while w > 0 and t[w - 1] in IdentChars: dec w
  let (onInclude, headers) = cxIncludeItems(f, t, c, systemDirs)
  if onInclude:
    result[0] = headers
    let lt = t.find('<')
    if lt >= 0 and lt < c and '/' notin t[lt ..< c]:
      let typed = t[lt + 1 ..< c]
      for h in CxxStdHeaders:
        if h.startsWith(typed): result[0].add CxItem(label: h, detail: "C++ standard library", kind: cxMacro, rank: 3)
    return
  let files = cxClosure(f)
  let ctx = cxxCtxAt(files, f, line)
  # after ::  — a namespace's names, a class's members, an enum's constants, the library's
  if w >= 2 and t[w - 1] == ':' and t[w - 2] == ':':
    let q = cxxQualBefore(t, w - 2)
    result[1] = true
    result[2] = q
    if q in ["std", "::std"]:
      for (n, k, d) in CxxStdNames: result[0].add CxItem(label: n, detail: d, doc: d, kind: k, rank: 2)
      return
    var seen: HashSet[string]
    for (g, k) in cxxScopeSyms(files, q, ctx.scopes):
      let s = g.syms[k]
      if s.name in seen or s.kind in {cxParam, cxLocal, cxLabel} or s.name.startsWith("(anonymous") or
         cxxSpecial(s) or (s.kind == cxMethod and s.scope != s.owner): continue
      seen.incl s.name
      result[0].add CxItem(label: s.name, detail: (if s.kind in {cxFunc, cxMethod, cxClass, cxStruct, cxUnion, cxEnum,
                                                                 cxNamespace}: s.text else: s.typ),
                           doc: s.doc, kind: s.kind, rank: 1)
    return
  # after . and ->: the members
  var mEnd = -1
  if w > 0 and t[w - 1] == '.': mEnd = w - 1
  elif w > 1 and t[w - 1] == '>' and t[w - 2] == '-': mEnd = w - 2
  if mEnd >= 0:
    let recv = cxxReceiver(t, mEnd)
    let typ = if recv.len == 0 and t[mEnd] == '.': cxInitType(files, f, line, mEnd)
              else: cxxTypeOfExpr(files, f, recv, line, ctx)
    result[1] = true
    result[2] = typ
    result[0] = cxxMemberItems(files, typ, t[mEnd] == '-', ctx)
    return
  var seen: HashSet[string]
  let ls = cxLocalsAt(f, line)
  let afterGoto = cxAfterWord(t, w, ["goto"])
  for i in countdown(ls.high, 0):
    let s = ls[i]
    if s.name in seen or (s.kind == cxLabel) != afterGoto: continue
    seen.incl s.name
    result[0].add CxItem(label: s.name, detail: (if s.kind == cxLabel: "label" else: cxxAutoType(files, f, s, ctx, 0)),
                         kind: s.kind, rank: 0)
  if afterGoto: return
  # the class's members (in its methods), then what the file and its headers declare, seen from here
  var stdUsed = false
  for g in files:
    for (u, _) in g.usings:
      if u in ["std", "::std"]: stdUsed = true
  for gi, g in files:
    let sys = gi > 0 and (cxIsSystem(g.path) or (block:
      var y = false
      for d in systemDirs:
        if g.path.startsWith(d): y = true
      y))
    for s in g.syms:
      if s.name in seen or not cxxBareVisible(s, ctx.scopes) or cxxSpecial(s): continue
      if s.name.startsWith("__") or (s.name.startsWith("_") and (sys or (gi > 0 and s.name.len > 1 and s.name[1] in {'A'..'Z'}))):
        continue
      if s.name.startsWith("(anonymous"): continue
      seen.incl s.name
      let member = s.scope.len > 0 and s.scope == ctx.cls
      result[0].add CxItem(label: s.name, detail: (if s.kind in {cxFunc, cxMethod, cxClass, cxStruct, cxUnion, cxEnum,
                                                                 cxNamespace}: s.text else: s.typ),
                           doc: s.doc, kind: s.kind, rank: (if member or gi == 0: 1 elif sys: 3 else: 2))
  if stdUsed:
    for (n, k, d) in CxxStdNames:
      if n notin seen:
        seen.incl n
        result[0].add CxItem(label: n, detail: d, doc: d, kind: k, rank: 3)
  for kw in CxxKeywords:
    if kw notin seen: result[0].add CxItem(label: kw, detail: "keyword", kind: cxMacro, rank: 4)

proc cxxMethodDefs(files: seq[CxFile], owner, name: string): seq[(CxFile, CxSym)] =
  ## a method's bodies written outside its class (`Ret Class::name(…) { … }`)
  for g in files:
    for k in cxNamed(g, name):
      let x = g.syms[k]
      if x.kind == cxMethod and x.isDef and x.scope != x.owner and cxxOwnersMatch(x.owner, owner): result.add (g, x)

proc cxxMemberTargets(files: seq[CxFile], key, w: string, ctx: CxxCtx, all = false): seq[(CxFile, CxSym)] =
  ## the member w of class `key` (or of its bases): a field; a method — its bodies first, then its declaration
  var owner = ""
  var defs, decls: seq[(CxFile, CxSym)]
  for (g, k, _, _) in cxxMembers(files, key, ctx.scopes, all):
    let s = g.syms[k]
    if s.name != w or (s.kind == cxMethod and s.scope != s.owner): continue
    if s.kind != cxMethod: return @[(g, s)]
    if owner.len > 0 and s.owner != owner: continue
    owner = s.owner
    if s.isDef: defs.add (g, s) else: decls.add (g, s)
  if owner.len == 0: return
  cxxMethodDefs(files, owner, w) & defs & decls

proc cxxTargets(f: CxFile, line, col: int, jump: bool): seq[(CxFile, CxSym)] =
  let t = f.lines[line]
  let (a, e) = cxWordAt(t, col)
  if a >= e: return
  let w = t[a ..< e]
  let files = cxClosure(f)
  # the declaration itself (a method's: its body outside the class, or from there its declaration)
  for s in f.syms:
    if s.name == w and s.line == line and s.col == a and s.kind notin {cxParam, cxLocal, cxLabel}:
      if jump and s.kind in {cxFunc, cxVar, cxMethod, cxField}:
        var others: seq[(CxFile, CxSym)]
        for g in files:
          for k in cxNamed(g, w):
            let x = g.syms[k]
            if x.isDef != s.isDef and not x.weak and cxxSameDecl(x, s): others.add (g, x)
        if others.len > 0: return others & @[(f, s)]
      return @[(f, s)]
  let ctx = cxxCtxAt(files, f, line)
  # a member: x.w, p->w
  var mEnd = -1
  if a > 0 and t[a - 1] == '.': mEnd = a - 1
  elif a > 1 and t[a - 1] == '>' and t[a - 2] == '-': mEnd = a - 2
  if mEnd >= 0:
    let recv = cxxReceiver(t, mEnd)
    let typ = if recv.len == 0 and t[mEnd] == '.': cxInitType(files, f, line, mEnd)
              else: cxxTypeOfExpr(files, f, recv, line, ctx)
    var (b, _) = cxxStrip(typ)
    let args = cxxArgs(b)
    if cxxStdGroup(cxxNoArgs(b), true) in ["unique_ptr", "shared_ptr"] and t[mEnd] == '-' and args.len > 0 and
       cxxFindClass(files, b, ctx.scopes)[0] == nil:
      b = args[0]
    let (key, _, _) = cxxRecord(files, b, ctx.scopes)
    if key.len > 0: return cxxMemberTargets(files, key, w, ctx)
    return
  # Scope::w
  if a >= 2 and t[a - 1] == ':' and t[a - 2] == ':':
    let q = cxxQualBefore(t, a - 2)
    if q in ["std", "::std"]: return
    let (key, _, _) = cxxRecord(files, q, ctx.scopes)
    if key.len > 0:
      let r = cxxMemberTargets(files, key, w, ctx, all = true)
      if r.len > 0: return r
    var defs, r: seq[(CxFile, CxSym)]
    for (g, k) in cxxScopeSyms(files, q, ctx.scopes):
      let x = g.syms[k]
      if x.name != w: continue
      if x.kind == cxFunc and not x.isDef:
        for d in cxxMethodDefs(files, x.scope, w):
          if d notin defs: defs.add d
      if x.isDef: defs.add (g, x) else: r.add (g, x)
    if defs.len + r.len > 0: return defs & r
  # a local, a parameter, a label
  let afterGoto = cxAfterWord(t, a, ["goto"])
  let tagged = cxAfterWord(t, a, ["struct", "union", "enum", "class"])
  if not tagged:
    let ls = cxLocalsAt(f, line)
    for i in countdown(ls.high, 0):
      if ls[i].name == w and (ls[i].kind == cxLabel) == afterGoto: return @[(f, ls[i])]
  if afterGoto: return
  # in a method: its class's members
  if ctx.cls.len > 0 and not tagged:
    let r = cxxMemberTargets(files, ctx.cls, w, ctx, all = true)
    if r.len > 0: return r
  # what the file and its headers declare (seen from here first)
  var types, defs, decls, macros: seq[(CxFile, CxSym)]
  var anyVisible = false
  for g in files:
    for k in cxNamed(g, w):
      let s = g.syms[k]
      if s.kind in {cxField, cxMethod}: continue
      if cxxBareVisible(s, ctx.scopes): anyVisible = true
  for g in files:
    for k in cxNamed(g, w):
      let s = g.syms[k]
      if s.kind in {cxField, cxMethod}: continue
      if anyVisible and not cxxBareVisible(s, ctx.scopes) and s.kind != cxMacro: continue
      if s.kind == cxMacro or s.weak: macros.add (g, s)
      elif s.kind == cxTypedef and not tagged: types.add (g, s)
      elif s.isDef or s.kind notin {cxFunc, cxStruct, cxUnion, cxEnum, cxVar, cxClass}: defs.add (g, s)
      else:
        decls.add (g, s)
        if s.kind == cxFunc and s.scope.len > 0:
          for d in cxxMethodDefs(files, s.scope, w):
            if d notin defs: defs.add d
  types & defs & decls & macros

proc cxComplete*(f: CxFile, line, col: int, systemDirs: seq[string] = @[]): (seq[CxItem], bool, string) =
  ## completion at line:col: (items, after a member access, the type there)
  if f == nil or line >= f.lines.len: return
  if f.cpp: return cxxComplete(f, line, col, systemDirs)
  let t = f.lines[line]
  let c = min(col, t.len)
  var w = c
  while w > 0 and t[w - 1] in IdentChars: dec w
  let (onInclude, headers) = cxIncludeItems(f, t, c, systemDirs)
  if onInclude:
    result[0] = headers
    return
  let files = cxClosure(f)
  # after . or ->: the members
  var mEnd = -1
  if w > 0 and t[w - 1] == '.': mEnd = w - 1
  elif w > 1 and t[w - 1] == '>' and t[w - 2] == '-': mEnd = w - 2
  if mEnd >= 0:
    let recv = cxReceiver(t, mEnd)
    # (`{ .x = 1, .` — a designated initializer: the members of what it initializes)
    let typ = if recv.len == 0 and t[mEnd] == '.': cxInitType(files, f, line, mEnd)
              else: cxTypeOfExpr(files, f, recv, line)
    result[1] = true
    result[2] = typ
    let (rec, _) = cxRecord(files, typ)
    if rec.len == 0: return
    for (g, k) in cxFields(files, rec):
      let s = g.syms[k]
      result[0].add CxItem(label: s.name, detail: s.typ, doc: s.doc, kind: cxField, rank: 0)
    return
  var seen: HashSet[string]
  let ls = cxLocalsAt(f, line)
  let afterGoto = cxAfterWord(t, w, ["goto"])
  for i in countdown(ls.high, 0):
    let s = ls[i]
    if s.name in seen or (s.kind == cxLabel) != afterGoto: continue
    seen.incl s.name
    result[0].add CxItem(label: s.name, detail: (if s.kind == cxLabel: "label" else: s.typ), kind: s.kind, rank: 0)
  if afterGoto: return
  for gi, g in files:
    let sys = gi > 0 and systemDirs.len > 0 and (block:
      var y = false
      for d in systemDirs:
        if g.path.startsWith(d): y = true
      y)
    for s in g.syms:
      if s.kind in {cxParam, cxLocal, cxField, cxLabel} or s.name in seen: continue
      if s.name.startsWith("__") or (s.name.startsWith("_") and (sys or (gi > 0 and s.name.len > 1 and s.name[1] in {'A'..'Z'}))):
        continue
      if s.name.startsWith("(anonymous"): continue
      seen.incl s.name
      result[0].add CxItem(label: s.name, detail: (if s.kind == cxFunc: s.text else: s.typ), doc: s.doc, kind: s.kind,
                           rank: (if gi == 0: 1 elif sys: 3 else: 2))
  for kw in CxKeywords:
    if kw notin seen: result[0].add CxItem(label: kw, detail: "keyword", kind: cxMacro, rank: 4)

proc cxTargets*(f: CxFile, line, col: int, jump = false): seq[(CxFile, CxSym)] =
  ## what the word at line:col names: a member, a local, parameter or label, or declarations in the file and its
  ## headers (a function's definition before its prototype; a typedef before the struct it names). jump: on a
  ## function definition's own name, its declarations first (the header's prototype), as clangd's go to definition
  if f == nil or line >= f.lines.len: return
  if f.cpp: return cxxTargets(f, line, col, jump)
  let t = f.lines[line]
  let (a, e) = cxWordAt(t, col)
  if a >= e: return
  let w = t[a ..< e]
  let files = cxClosure(f)
  # a member: x.w, p->w
  var mEnd = -1
  if a > 0 and t[a - 1] == '.': mEnd = a - 1
  elif a > 1 and t[a - 1] == '>' and t[a - 2] == '-': mEnd = a - 2
  if mEnd >= 0:
    let recv = cxReceiver(t, mEnd)
    let typ = if recv.len == 0 and t[mEnd] == '.': cxInitType(files, f, line, mEnd)
              else: cxTypeOfExpr(files, f, recv, line)
    let (rec, _) = cxRecord(files, typ)
    if rec.len > 0:
      for (g, k) in cxFields(files, rec):
        if g.syms[k].name == w: return @[(g, g.syms[k])]
    return
  # the declaration itself
  for s in f.syms:
    if s.name == w and s.line == line and s.col == a:
      if jump and s.kind in {cxFunc, cxVar}:
        # a definition's name: its prototype (extern declaration); a prototype's: the body
        var others: seq[(CxFile, CxSym)]
        for g in files:
          for k in cxNamed(g, w):
            let x = g.syms[k]
            if x.kind == s.kind and x.isDef != s.isDef and not x.weak: others.add (g, x)
        if others.len > 0: return others & @[(f, s)]
      return @[(f, s)]
  let afterGoto = cxAfterWord(t, a, ["goto"])
  let tagged = cxAfterWord(t, a, ["struct", "union", "enum"])     # (a tag: not a variable of the same name)
  if not tagged:
    let ls = cxLocalsAt(f, line)
    for i in countdown(ls.high, 0):
      if ls[i].name == w and (ls[i].kind == cxLabel) == afterGoto: return @[(f, ls[i])]
  if afterGoto: return
  var types, defs, decls, macros: seq[(CxFile, CxSym)]
  for g in files:
    for k in cxNamed(g, w):
      let s = g.syms[k]
      if s.kind notin {cxField}:
        # (a macro of a function's name — fortify, 64-bit names — and inline wrappers last)
        if s.kind == cxMacro or s.weak: macros.add (g, s)
        elif s.kind == cxTypedef and not tagged: types.add (g, s)
        elif s.isDef or s.kind notin {cxFunc, cxStruct, cxUnion, cxEnum, cxVar}: defs.add (g, s)
        else: decls.add (g, s)
  result = types & defs & decls & macros

proc cxBodyIn*(paths: openArray[string], name: string, kind = cxFunc, owner = ""): (CxFile, int) =
  ## a function's body (or a struct's members — an opaque type's) in one of these .c files (each read once, then
  ## kept while it is unchanged); owner: a C++ method's class
  for p in paths:
    let h = cxLoad(p)
    if h == nil: continue
    for k in cxNamed(h, name):
      if h.syms[k].kind == kind and h.syms[k].isDef and (owner.len == 0 or cxxOwnersMatch(h.syms[k].owner, owner)):
        return (h, k)
  (nil, -1)

# ── what hover adds: constants' values, a macro's expansion where it is used, a struct's layout ──

proc cxEvalConst*(files: seq[CxFile], expr: string, depth = 0): (bool, int64)

proc cxEnumValue*(files: seq[CxFile], s: CxSym, depth = 0): (bool, int64) =
  ## an enum constant's value: what it says (`= 1 << 4`), else the one before it plus one
  if depth > 30: return (false, 0)
  # (its enum's constants, in order)
  var consts: seq[CxSym]
  for g in files:
    for k in cxFields(@[g], s.owner):
      if g.syms[k[1]].kind == cxEnumConst: consts.add g.syms[k[1]]
    if consts.len > 0: break
  if consts.len == 0:
    for g in files:
      for x in g.syms:
        if x.kind == cxEnumConst and x.owner == s.owner: consts.add x
      if consts.len > 0: break
  var v: int64 = -1
  for x in consts:
    if x.init.len > 0:
      let (ok, n) = cxEvalConst(files, x.init, depth + 1)
      if not ok: return (false, 0)
      v = n
    else: v += 1
    if x.name == s.name and x.line == s.line: return (true, v)
  (false, 0)

proc cxEvalConst*(files: seq[CxFile], expr: string, depth = 0): (bool, int64) =
  ## an integer constant expression of C — numbers, characters, other enum constants and macros, ( ) and the
  ## arithmetic, bitwise, shift, comparison and logical operators, `?:`
  if depth > 30: return (false, 0)
  # tokens
  var ts: seq[string]
  var i = 0
  let e0 = expr.strip
  while i < e0.len:
    let c = e0[i]
    if c in Whitespace: inc i
    elif c in Digits:
      var j = i
      while j < e0.len and (e0[j].isAlphaNumeric or e0[j] == '.'): inc j
      ts.add e0[i ..< j]
      i = j
    elif c in IdentStartChars:
      var j = i
      while j < e0.len and e0[j] in IdentChars: inc j
      ts.add e0[i ..< j]
      i = j
    elif c == '\'':
      let j = e0.find('\'', i + 1)
      if j < 0: return (false, 0)
      ts.add e0[i .. j]
      i = j + 1
    else:
      var op = $c
      if i + 1 < e0.len and e0[i .. i + 1] in ["<<", ">>", "<=", ">=", "==", "!=", "&&", "||"]: op = e0[i .. i + 1]
      ts.add op
      i += op.len
  var p = 0
  var ok = true
  proc num(t: string): int64 =
    var x = t.toLowerAscii
    while x.len > 1 and x[^1] in {'u', 'l'}: x.setLen(x.len - 1)
    try:
      if x.startsWith("0x"): result = int64(parseHexInt(x))
      elif x.startsWith("0b"): result = int64(parseBinInt(x))
      elif x.len > 1 and x[0] == '0': result = int64(parseOctInt(x))
      else: result = parseBiggestInt(x)
    except ValueError: ok = false
  proc expr(prec: int): int64
  proc unary(): int64 =
    if p >= ts.len:
      ok = false
      return
    let t = ts[p]
    inc p
    case t
    of "(":
      # (a cast `(int)x`: the type skipped)
      if p < ts.len and ts[p] in ["int", "unsigned", "long", "char", "short", "signed", "size_t", "uint32_t",
                                  "int32_t", "uint64_t", "int64_t", "uint8_t", "uint16_t"]:
        while p < ts.len and ts[p] != ")": inc p
        inc p
        return unary()
      result = expr(0)
      if p < ts.len and ts[p] == ")": inc p
      else: ok = false
    of "-": result = -unary()
    of "+": result = unary()
    of "~": result = not unary()
    of "!": result = (if unary() == 0: 1 else: 0)
    else:
      if t[0] in Digits: result = num(t)
      elif t[0] == '\'' and t.len >= 3:
        result = (if t[1] == '\\' and t.len >= 4:
                    (case t[2]
                     of 'n': 10
                     of 't': 9
                     of '0': 0
                     of 'r': 13
                     else: int64(ord(t[2])))
                  else: int64(ord(t[1])))
      elif t[0] in IdentStartChars:
        if t in ["sizeof", "defined"]:
          ok = false
          return
        let (g, k) = cxFindSym(files, t, {cxEnumConst, cxMacro})
        if g == nil:
          ok = false
          return
        let x = g.syms[k]
        if x.kind == cxEnumConst:
          let (ok2, v) = cxEnumValue(files, x, depth + 1)
          if not ok2: ok = false
          result = v
        else:
          # (an object-like macro: its body)
          if x.params.len > 0 or x.varargs:
            ok = false
            return
          let body = x.text["#define ".len + x.name.len .. ^1]
          let (ok2, v) = cxEvalConst(files, body, depth + 1)
          if not ok2: ok = false
          result = v
      else: ok = false
  proc precOf(op: string): int =
    case op
    of "?": 1
    of "||": 2
    of "&&": 3
    of "|": 4
    of "^": 5
    of "&": 6
    of "==", "!=": 7
    of "<", ">", "<=", ">=": 8
    of "<<", ">>": 9
    of "+", "-": 10
    of "*", "/", "%": 11
    else: -1
  proc expr(prec: int): int64 =
    result = unary()
    while ok and p < ts.len:
      let op = ts[p]
      let pr = precOf(op)
      if pr < 0 or pr < prec: break
      inc p
      if op == "?":
        let a = expr(0)
        if p < ts.len and ts[p] == ":": inc p
        else:
          ok = false
          return
        let b = expr(1)
        result = (if result != 0: a else: b)
        continue
      let r = expr(pr + 1)
      result = case op
               of "||": (if result != 0 or r != 0: 1 else: 0)
               of "&&": (if result != 0 and r != 0: 1 else: 0)
               of "|": result or r
               of "^": result xor r
               of "&": result and r
               of "==": (if result == r: 1 else: 0)
               of "!=": (if result != r: 1 else: 0)
               of "<": (if result < r: 1 else: 0)
               of ">": (if result > r: 1 else: 0)
               of "<=": (if result <= r: 1 else: 0)
               of ">=": (if result >= r: 1 else: 0)
               of "<<": (if r >= 0 and r < 63: result shl r else: 0)
               of ">>": (if r >= 0 and r < 63: result shr r else: 0)
               of "+": result + r
               of "-": result - r
               of "*": result * r
               of "/": (if r != 0: result div r else: (ok = false; 0))
               of "%": (if r != 0: result mod r else: (ok = false; 0))
               else: result
  if ts.len == 0: return (false, 0)
  let v = expr(0)
  (ok and p == ts.len, v)

const CxBaseSizes = {"char": 1, "signed char": 1, "unsigned char": 1, "_Bool": 1, "bool": 1, "short": 2,
  "short int": 2, "unsigned short": 2, "unsigned short int": 2, "int": 4, "signed": 4, "unsigned": 4,
  "signed int": 4, "unsigned int": 4, "long": 8, "long int": 8, "unsigned long": 8, "unsigned long int": 8,
  "long long": 8, "long long int": 8, "unsigned long long": 8, "unsigned long long int": 8, "float": 4,
  "double": 8, "long double": 16, "size_t": 8, "ssize_t": 8, "ptrdiff_t": 8, "intptr_t": 8, "uintptr_t": 8,
  "int8_t": 1, "uint8_t": 1, "int16_t": 2, "uint16_t": 2, "int32_t": 4, "uint32_t": 4, "int64_t": 8,
  "uint64_t": 8, "off_t": 8, "time_t": 8, "pid_t": 4, "uid_t": 4, "gid_t": 4, "mode_t": 4, "wchar_t": 4,
  "char16_t": 2, "char32_t": 4}.toTable

proc cxRecordLayout*(files: seq[CxFile], tag: string, isUnion: bool, depth = 0):
    (bool, int, int, seq[(string, int, int)])

proc cxSizeAlign*(files: seq[CxFile], typ0, dims: string, depth = 0): (bool, int, int) =
  ## the size and alignment of a C type on a 64-bit Unix (LP64): base types, pointers, enums, arrays, structs
  ## and unions made of those — (false, …) when a part is not known
  if depth > 12: return (false, 0, 0)
  var typ = typ0.strip
  for q in ["const ", "volatile ", "static ", "register ", "restrict ", "__restrict ", "_Atomic "]:
    typ = typ.replace(q, "")
  typ = typ.strip
  var count = 1
  if dims.len > 0:
    # ([N][M]…: each dimension's value)
    var rest = dims
    while rest.startsWith("["):
      let e = rest.find(']')
      if e < 0: return (false, 0, 0)
      let (ok, n) = cxEvalConst(files, rest[1 ..< e])
      if not ok or n < 0 or n > 1 shl 32: return (false, 0, 0)
      count *= int(n)
      rest = rest[e + 1 .. ^1]
  if '*' in typ or "(*)" in typ: return (true, 8 * count, 8)
  if typ in CxBaseSizes:
    let sz = CxBaseSizes[typ]
    return (true, sz * count, min(sz, 16))
  if typ.startsWith("enum "): return (true, 4 * count, 4)
  let isUnion = typ.startsWith("union ")
  if typ.startsWith("struct ") or isUnion:
    let tag = typ.splitWhitespace[^1]
    let lay = cxRecordLayout(files, tag, isUnion, depth + 1)
    if not lay[0]: return (false, 0, 0)
    return (true, lay[1] * count, lay[2])
  # a typedef: what it names
  let (g, k) = cxFindSym(files, typ, {cxTypedef})
  if g != nil:
    let x = g.syms[k]
    if x.typ.len > 0 and x.typ != typ:
      let (ok, sz, al) = cxSizeAlign(files, x.typ, "", depth + 1)
      if ok: return (true, sz * count, al)
    # (`typedef struct x {…} X;`: the struct named the same)
  let (g2, k2) = cxFindSym(files, typ, {cxStruct, cxUnion})
  if g2 != nil:
    let lay = cxRecordLayout(files, typ, g2.syms[k2].kind == cxUnion, depth + 1)
    if lay[0]: return (true, lay[1] * count, lay[2])
  (false, 0, 0)

proc cxRecordLayout*(files: seq[CxFile], tag: string, isUnion: bool, depth = 0):
    (bool, int, int, seq[(string, int, int)]) =
  ## a struct's (or union's) size, alignment and its fields' (name, offset, size), as the C compiler lays them out
  ## (LP64; no packing; a bit-field: not known)
  if depth > 12: return
  var fields: seq[CxSym]
  for (g, k) in cxFields(files, tag):
    if g.syms[k].kind == cxField: fields.add g.syms[k]
  if fields.len == 0: return
  fields.sort(proc(a, b: CxSym): int = cmp((a.line, a.col), (b.line, b.col)))
  var off = 0
  var align = 1
  var size = 0
  var res: seq[(string, int, int)]
  for x in fields:
    if x.bits.len > 0: return
    let (ok, sz, al) = cxSizeAlign(files, x.typ.replace(" *", " *").strip(chars = {' '}), x.dims, depth + 1)
    var typ = x.typ
    if x.dims.len > 0 and typ.endsWith("*"):
      # (an array is typed as a pointer by the index: `char name[16]` → `char *` — the element type, then)
      typ = typ[0 ..< typ.high].strip
    let (ok2, sz2, al2) = if x.dims.len > 0: cxSizeAlign(files, typ, x.dims, depth + 1) else: (ok, sz, al)
    if not ok2: return
    align = max(align, al2)
    if isUnion:
      res.add (x.name, 0, sz2)
      size = max(size, sz2)
    else:
      off = (off + al2 - 1) div al2 * al2
      res.add (x.name, off, sz2)
      off += sz2
  if not isUnion: size = off
  size = (size + align - 1) div align * align
  (true, size, align, res)

proc cxMacroExpansion*(f: CxFile, s: CxSym, line, col: int): string =
  ## a macro where it is used: its body with the arguments of this use in place of its parameters (one level)
  let body0 = s.text["#define ".len + s.name.len .. ^1]
  var body = body0
  var params: seq[string]
  if body.startsWith("("):
    let e = body.find(')')
    if e < 0: return ""
    for p in body[1 ..< e].split(','): params.add p.strip
    body = body[e + 1 .. ^1]
  body = body.strip
  if params.len == 0: return body
  # the arguments written after the name on this line
  if line >= f.lines.len: return ""
  let t = f.lines[line]
  var k = col
  while k < t.len and t[k] in IdentChars: inc k
  while k < t.len and t[k] == ' ': inc k
  if k >= t.len or t[k] != '(': return ""
  var args: seq[string]
  var d = 0
  var cur = ""
  inc k
  while k < t.len:
    let c = t[k]
    if c in {'(', '[', '{'}: inc d
    elif c in {')', ']', '}'}:
      if d == 0: break
      dec d
    if c == ',' and d == 0:
      args.add cur.strip
      cur = ""
    else: cur.add c
    inc k
  if k >= t.len: return ""
  args.add cur.strip
  # (each parameter, as a whole word, replaced)
  var outp = ""
  var i = 0
  while i < body.len:
    if body[i] in IdentStartChars:
      var j = i
      while j < body.len and body[j] in IdentChars: inc j
      let w = body[i ..< j]
      let pi = params.find(w)
      outp.add (if pi >= 0 and pi < args.len: args[pi] elif w == "__VA_ARGS__": args[params.len - 1 .. ^1].join(", ")
                else: w)
      i = j
    else:
      outp.add body[i]
      inc i
  outp

proc cxHover*(f: CxFile, line, col: int): string =
  let ts = cxTargets(f, line, col)
  if ts.len == 0 and f != nil and f.cpp and line < f.lines.len:
    # std::vector: what the library's name is (its headers are not read)
    let t = f.lines[line]
    let (a, e) = cxWordAt(t, col)
    if a >= 5 and e > a and t[a - 5 ..< a] == "std::":
      for (n, _, d) in CxxStdNames:
        if n == t[a ..< e]: return "```cpp\nstd::" & n & "\n```\n" & d
  if ts.len == 0: return ""
  let (g, s) = ts[0]
  var doc = s.doc
  if doc.len == 0 and s.kind in {cxFunc, cxVar, cxStruct, cxUnion, cxEnum, cxTypedef, cxClass, cxMethod}:
    # (a definition in a .c file, its comment on the prototype in the header; a method's, on its declaration)
    block find:
      for g2 in cxClosure(f):
        for k in cxNamed(g2, s.name):
          let x = g2.syms[k]
          if x.kind == s.kind and x.doc.len > 0 and (s.kind != cxMethod or cxxOwnersMatch(x.owner, s.owner)):
            doc = x.doc
            break find
  let kindWord = case s.kind
    of cxFunc: "function"
    of cxStruct: "struct"
    of cxUnion: "union"
    of cxEnum: "enum"
    of cxTypedef: "type"
    of cxMacro: "macro"
    of cxVar: "variable"
    of cxEnumConst: "enum constant"
    of cxField: "field of " & s.owner
    of cxParam: "parameter of " & s.owner
    of cxLocal: "local of " & s.owner
    of cxLabel: "label in " & s.owner
    of cxClass: "class"
    of cxNamespace: "namespace"
    of cxMethod:
      (if cxxSplit(s.owner)[^1] == s.name: "constructor of " elif s.name.startsWith("~"): "destructor of "
       else: "method of ") & (block:
        # (a method defined outside its class: the class as declared)
        let (key, _, _) = if s.scope != s.owner: cxxRecord(cxClosure(f), s.owner, cxxWithParents(s.scope) & @[""])
                          else: ("", @[], CxSym())
        if key.len > 0: key else: s.owner)
  let fence = if f.cpp: "cpp" else: "c"
  var text = s.text
  if f.cpp and s.kind in {cxLocal, cxVar, cxParam} and s.init.len > 0:
    # auto x = …: the type it has
    let files = cxClosure(f)
    let t = cxxAutoType(files, f, s, cxxCtxAt(files, f, line), 0)
    if t != s.typ: text = t & (if t.endsWith("*") or t.endsWith("&"): "" else: " ") & s.name & "    // " & s.text
  result = "```" & fence & "\n" & text & "\n```\n" & kindWord & " · " & extractFilename(g.path) & ":" & $(s.line + 1)
  if s.scope.len > 0 and s.kind notin {cxField, cxMethod, cxParam, cxLocal, cxLabel}: result.add " · in " & s.scope
  if doc.len > 0: result.add "\n\n" & doc
  if s.kind in {cxStruct, cxUnion, cxClass}:
    var fl: seq[string]
    if f.cpp:
      let files = cxClosure(f)
      var seen: HashSet[string]
      for (g2, k, _, _) in cxxMembers(files, cxxQual(s), @[s.scope, ""], all = false):
        let x = g2.syms[k]
        if fl.len < 12 and x.name notin seen and not (x.kind == cxMethod and x.scope != x.owner) and not cxxSpecial(x):
          seen.incl x.name
          fl.add x.text.replace(cxxSplit(x.owner)[^1] & "::", "") & ";"
    else:
      for (g2, k) in cxFields(cxClosure(f), s.name):
        if fl.len < 12: fl.add g2.syms[k].text & ";"
    if fl.len > 0: result.add "\n```" & fence & "\n{ " & fl.join(" ") & " }\n```"
  # (C, 64-bit: a struct's layout; a field's offset; an enum constant's value; a macro's value or its expansion
  # where it is used)
  if not f.cpp:
    let files = cxClosure(f)
    case s.kind
    of cxStruct, cxUnion:
      let (ok, size, align, fields) = cxRecordLayout(files, s.name, s.kind == cxUnion)
      if ok:
        result.add "\n\n**" & $size & " bytes**, aligned to " & $align & " (64-bit)"
        var prev = 0
        var lines: seq[string]
        for (nm, off, sz) in fields:
          if off > prev and s.kind == cxStruct: lines.add "  · " & $(off - prev) & " bytes of padding"
          lines.add "  " & nm & ": offset " & $off & ", " & $sz & " byte" & (if sz == 1: "" else: "s")
          prev = off + sz
        if s.kind == cxStruct and size > prev: lines.add "  · " & $(size - prev) & " bytes of padding at the end"
        if lines.len <= 16: result.add "\n" & lines.join("\n")
    of cxField:
      let (ok, _, _, fields) = cxRecordLayout(files, s.owner, false)
      if ok:
        for (nm, off, sz) in fields:
          if nm == s.name:
            result.add "\n\noffset " & $off & " · " & $sz & " byte" & (if sz == 1: "" else: "s") & " (64-bit)"
    of cxEnumConst:
      let (ok, v) = cxEnumValue(files, s)
      if ok: result.add "\n\n**= " & $v & "**" & (if v >= 10 or v < 0: " (0x" & toHex(v).strip(trailing = false,
                                                     chars = {'0'}).toLowerAscii & ")" else: "")
    of cxMacro:
      if s.params.len == 0 and not s.varargs:
        let (ok, v) = cxEvalConst(files, s.text["#define ".len + s.name.len .. ^1])
        if ok: result.add "\n\n**= " & $v & "**" & (if v >= 10 or v < 0: " (0x" & toHex(v).strip(trailing = false,
                                                       chars = {'0'}).toLowerAscii & ")" else: "")
      if (line != s.line or g.path != f.path) and (s.params.len > 0 or s.varargs):
        let ex = cxMacroExpansion(f, s, line, col - (block:
          var a = col
          let t = f.lines[min(line, f.lines.high)]
          while a > 0 and t[a - 1] in IdentChars: dec a
          col - a))
        if ex.len > 0 and ex.len < 600: result.add "\n\nExpands to:\n```c\n" & ex & "\n```"
    else: discard

proc cxSignature*(f: CxFile, line, col: int): (CxSym, int) =
  ## the call around line:col: the function (kind cxFunc, or a function-like macro) and the parameter being typed
  if f == nil or line >= f.lines.len: return
  let t = f.lines[line]
  var k = min(col, t.len) - 1
  var d = 0
  var commas = 0
  while k >= 0:
    let c = t[k]
    if c in {')', ']'}: inc d
    elif c in {'(', '['}:
      if d == 0:
        if c == '(': break
        return
      dec d
    elif c == ',' and d == 0: inc commas
    elif c == '"':
      dec k
      while k >= 0 and t[k] != '"': dec k
    dec k
  if k <= 0: return
  var e = k
  while e > 0 and t[e - 1] == ' ': dec e
  var a = e
  while a > 0 and t[a - 1] in IdentChars: dec a
  if a == e: return
  let name = t[a ..< e]
  let files = cxClosure(f)
  var best = -1
  var bf: CxFile
  for g in files:
    for i in cxNamed(g, name):
      let s = g.syms[i]
      if (s.kind in {cxFunc, cxMacro} or (f.cpp and s.kind == cxMethod)) and (best < 0 or s.isDef):
        best = i
        bf = g
  if best < 0: return
  (bf.syms[best], commas)

proc cxOutline*(f: CxFile): seq[CxSym] =
  ## the file's declarations, in order (C++: a class's members are not among them — they are under it — but a
  ## method defined outside its class is)
  if f == nil: return
  for s in f.syms:
    if (s.kind in {cxFunc, cxStruct, cxUnion, cxEnum, cxTypedef, cxMacro, cxVar} or
        (f.cpp and s.kind in {cxClass, cxMethod})) and not s.name.startsWith("(anonymous") and
       not (s.kind in {cxStruct, cxUnion, cxEnum, cxClass} and not s.isDef) and
       not (f.cpp and s.owner.len > 0 and s.kind != cxMethod) and
       not (f.cpp and s.kind == cxMethod and s.scope == s.owner):
      result.add s
  result.sort(proc(a, b: CxSym): int = cmp(a.line, b.line))

proc cxOccurrences*(lines: seq[string], name: string, a = 0, b = high(int)): seq[(int, int)] =
  ## where `name` is written as a word (not in strings, characters or comments) on lines a..b
  var inBlock = false
  for l in max(0, a) .. min(lines.high, b):
    let t = lines[l]
    if not inBlock and t.strip(trailing = false).startsWith("#include"): continue
    var i = 0
    while i < t.len:
      if inBlock:
        let e = t.find("*/", i)
        if e < 0: break
        inBlock = false
        i = e + 2
        continue
      let c = t[i]
      if c == '/' and i + 1 < t.len and t[i + 1] == '/': break
      if c == '/' and i + 1 < t.len and t[i + 1] == '*':
        inBlock = true
        i += 2
        continue
      if c in {'"', '\''}:
        inc i
        while i < t.len and t[i] != c:
          if t[i] == '\\': inc i
          inc i
        inc i
        continue
      if c in IdentStartChars and (i == 0 or t[i - 1] notin IdentChars):
        var e = i
        while e < t.len and t[e] in IdentChars: inc e
        if e - i == name.len and t[i ..< e] == name: result.add (l, i)
        i = e
        continue
      inc i
