## indent-dots — a dot in each space of a line's indentation, up to its first letter (not between words)
##
##   Indent dots: on/off      (vim <leader>id) — kept for the next start
##   what it draws            · in each space of the indentation; → where a tab starts; on a blank line, dots as
##                            deep as the code around it; ¬ after each line's end when plugins.indent-dots.lineEnd is
##                            on. The │ of the indentation guides stay on their columns (editor.indentGuides)
##   settings                 plugins.indent-dots.char — the dot (·; or • ⋅ ∙ ˙ .)
##                            .color — guide (the guides' colour), hint, accent, info, or "#rrggbb"
##                            .tabs (→; "" for none) · .blankLines (true) · .lineEnd (false)
##                            .languages — "" (every file), or the languages' ids: "nim python"
##
## ned draws the dots as it draws each line: the plugin only says, once, how they look — nothing is sent for each
## line, so a big file costs no more than a small one. editor.showWhitespace, ned's own, puts a dot in every space
## (between words too); rainbow-indent colours the levels, and with its "dots" style colours these dots.
import nedplugin

requiresNed(">= 6.29")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")

settingDef("char", "·", "Indent dots: the mark in each space of the indentation (·, •, ⋅, ∙, ˙ or .)")
settingDef("color", "guide", "Indent dots: their colour — guide (the indentation guides' colour), hint, accent, " &
           "info, or \"#rrggbb\"")
settingDef("tabs", "→", "Indent dots: the mark where a tab of the indentation starts (\"\" for none)")
settingDef("blankLines", true, "Indent dots: on a blank line, dots as deep as the code around it")
settingDef("lineEnd", false, "Indent dots: ¬ after the end of each line")
settingDef("languages", "", "Indent dots: only in these languages (their ids, \"nim python\"); \"\": every file")

var
  on = true
  sent = ""                      # (the look last given to ned: sent again only when it changes)

proc look(): IndentStyle =
  ## how the dots are to be drawn now, from the settings — an empty style (nothing drawn) when the plugin is off
  if not on: return IndentStyle()
  IndentStyle(dot: setting("char", "·"), dotColor: setting("color", "guide"), tab: setting("tabs", "→"),
              blankLines: setting("blankLines", true), lineEnd: (if setting("lineEnd", false): "¬" else: ""),
              langs: setting("languages", "").splitWhitespace)

proc apply() =
  ## gives ned the look of the dots, but only when it differs from the one given last
  let st = look()
  let key = $st
  if key == sent: return
  sent = key
  indentStyle(st)

proc toggle() =
  ## Indent dots: on/off — switches the dots, keeps the state in the data folder for the next start, gives ned the new
  ## look and says which it is
  on = not on
  writeData("state", (if on: "on" else: "off") & "\n")
  apply()
  message("Indent dots " & (if on: "on" else: "off"))

command "Indent dots: on/off": toggle()
nmap("<leader>id", "Indent dots: on/off", proc(count: int) = toggle())

onStartup(proc(ev: Event) =
  on = readData("state").strip != "off"
  apply())
onEnter("*", proc(ev: Event) = apply())      # (a setting changed meanwhile: its new look)
