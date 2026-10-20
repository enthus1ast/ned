# the data ned's CSS, HTML and SQL engines use: no name twice, one short line per description, names in the
# case each language writes them, and the lookups find what is there

import std/[os, sequtils, sets, strutils, unittest]
import ../../src/ned/web/webdata

const src = currentSourcePath.parentDir / ".." / ".." / "src" / "ned" / "web" / "webdata.nim"

proc isDesc(s: string): bool =
  ## one short line
  s.len > 0 and s.len <= 90 and '\n' notin s and s == s.strip

proc unique(names: openArray[string]): seq[string] =
  ## the names seen more than once
  var seen: HashSet[string]
  for n in names:
    if n in seen: result.add n
    seen.incl n

proc isLower(s: string): bool = s == s.toLowerAscii

suite "CSS":
  test "properties: unique lower-case names, known kinds, no global keywords, one-line descriptions":
    const kinds = ["length", "percentage", "number", "integer", "color", "time", "angle", "url", "string", "image",
                   "ident", "flex", "resolution", "position"]
    var names: seq[string]
    for p in CssProps:
      names.add p.name
      check p.name.isLower and p.name.allCharsInSet({'a'..'z', '-'}) and not p.name.startsWith("-")
      check p.desc.isDesc
      for k in p.kinds.splitWhitespace: check k in kinds
      for v in p.values.splitWhitespace:
        check v notin ["inherit", "initial", "unset", "revert", "revert-layer"]
      check unique(p.values.splitWhitespace).len == 0
    check unique(names).len == 0
    check CssProps.len >= 250

  test "the common properties are all there":
    for n in ["display", "align-items", "grid-template-columns", "margin-inline", "inset", "aspect-ratio", "gap",
              "place-items", "container-type", "accent-color", "caret-color", "appearance", "font-family",
              "transition-duration", "animation", "scroll-snap-type", "overscroll-behavior", "user-select",
              "pointer-events", "backdrop-filter", "mask-image", "columns", "list-style-type", "border-collapse"]:
      check cssProp(n) >= 0

  test "at-rules, pseudo-classes, pseudo-elements, functions":
    var names: seq[string]
    for a in CssAtRules:
      names.add a.name
      check a.name.startsWith("@") and a.name.isLower and a.desc.isDesc
    check unique(names).len == 0
    names = @[]
    for p in CssPseudoClasses:
      names.add p.name
      check p.name.startsWith(":") and not p.name.startsWith("::") and p.name.isLower and p.desc.isDesc
      check '(' notin p.name or p.name.endsWith("()")
    check unique(names).len == 0
    names = @[]
    for p in CssPseudoElements:
      names.add p.name
      check p.name.startsWith("::") and p.name.isLower and p.desc.isDesc
      check '(' notin p.name or p.name.endsWith("()")
    check unique(names).len == 0
    names = @[]
    for f in CssFunctions:
      names.add f.name
      check f.name.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '-'})
      check f.sig.startsWith("(") and f.desc.isDesc
    check unique(names).len == 0
    for n in ["calc", "var", "clamp", "oklch", "color-mix", "linear-gradient", "translateX", "matrix3d", "minmax",
              "repeat", "fit-content", "drop-shadow", "cubic-bezier", "steps"]:
      check n in names

  test "units and colors":
    check unique(CssUnits).len == 0
    for u in ["px", "rem", "%", "dvh", "cqi", "fr", "turn", "ms", "dppx"]: check u in CssUnits
    check unique(CssColorNames).len == 0
    check CssColorNames.len == 148 + 2
    for c in CssColorNames: check c.isLower and c.allCharsInSet({'a'..'z'})
    for c in ["rebeccapurple", "transparent", "currentcolor", "lightgoldenrodyellow", "grey", "gray"]:
      check c in CssColorNames

suite "HTML":
  test "tags: unique lower-case names, the void elements exactly":
    var names: seq[string]
    var voids: seq[string]
    for t in HtmlTags:
      names.add t.name
      check t.name.isLower and t.name.allCharsInSet({'a'..'z', '0'..'9'}) and t.desc.isDesc
      if t.void: voids.add t.name
    check unique(names).len == 0
    check voids.toHashSet == ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source",
                              "track", "wbr"].toHashSet
    for n in ["span", "a", "em", "code", "img", "input", "button", "label"]: check HtmlTags[htmlTag(n)].inline
    for n in ["div", "p", "ul", "table", "section", "html", "body", "script"]: check not HtmlTags[htmlTag(n)].inline
    for n in ["svg", "math", "dialog", "search", "template", "slot", "main", "picture"]: check htmlTag(n) >= 0

  test "attributes: global, events, per tag, their values":
    var names: seq[string]
    for a in HtmlGlobalAttrs:
      names.add a.name
      check a.name.isLower and a.desc.isDesc
    check unique(names).len == 0
    check "aria-*" in names and "data-*" in names
    check unique(HtmlEventAttrs).len == 0
    for e in HtmlEventAttrs: check e.startsWith("on") and e.isLower and e.allCharsInSet({'a'..'z'})
    check HtmlEventAttrs.len >= 60
    names = @[]
    for t in HtmlTagAttrs:
      names.add t.tag
      check htmlTag(t.tag) >= 0
      check unique(t.attrs.splitWhitespace).len == 0
      if t.tag != "svg": check t.attrs.isLower           # (SVG keeps viewBox, preserveAspectRatio)
    check unique(names).len == 0
    names = @[]
    for v in HtmlAttrValues:
      names.add v.attr
      check v.values.len > 0 and unique(v.values.splitWhitespace).len == 0
      let dot = v.attr.find('.')
      if dot > 0: check htmlTag(v.attr[0 ..< dot]) >= 0
    check unique(names).len == 0
    for k in ["type", "button.type", "script.type", "ol.type", "target", "rel", "loading", "autocomplete"]:
      check k in names

suite "SQL":
  test "keywords are unique and upper case":
    check unique(SqlKeywords).len == 0
    for k in SqlKeywords: check k == k.toUpperAscii and k.allCharsInSet({'A'..'Z', '_'})
    for k in ["SELECT", "FROM", "WHERE", "JOIN", "RETURNING", "JSONB", "SERIAL", "AUTOINCREMENT"]:
      check k in SqlKeywords

  test "functions: unique lower-case names, known dialects, one-line descriptions":
    var names: seq[string]
    for f in SqlFunctions:
      names.add f.name
      check f.name.isLower and f.name.allCharsInSet({'a'..'z', '0'..'9', '_'})
      check f.sig.startsWith("(") and f.desc.isDesc
      check f.dialects == "all" or f.dialects.len > 0 and
        f.dialects.splitWhitespace.allIt(it in ["sqlite", "postgres", "mysql"])
    check unique(names).len == 0
    check SqlFunctions.len >= 120
    for n in ["count", "coalesce", "group_concat", "string_agg", "date_trunc", "json_extract", "row_number",
              "dense_rank", "lag", "first_value", "nullif", "ifnull", "iif", "greatest", "least", "cast"]:
      check n in names

suite "lookups":
  test "case-insensitive, -1 for what is not there":
    check cssProp("display") >= 0 and CssProps[cssProp("display")].name == "display"
    check cssProp("Align-Items") == cssProp("align-items")
    check cssProp("-webkit-box-orient") == -1
    check cssProp("--main-color") == -1
    check cssProp("colour") == -1
    check cssProp("") == -1
    check HtmlTags[htmlTag("DIV")].name == "div"
    check htmlTag("my-widget") == -1
    check SqlFunctions[sqlFunction("COUNT")].name == "count"
    check sqlFunction("Json_Extract") >= 0
    check sqlFunction("select") == -1

  test "the source keeps to 120 columns":
    var n = 0
    for l in lines(src):
      inc n
      check l.len <= 120
    check n > 0
