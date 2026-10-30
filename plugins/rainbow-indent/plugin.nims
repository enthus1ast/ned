## rainbow-indent — each level of indentation in its own colour, as indent-rainbow; wrong indentation in red
##
##   Rainbow indent: on/off          kept for the next start
##   Rainbow indent: next style      bands → guides → dots → bands, kept for the next start (over .style)
##   what it draws    background — soft bands, a colour for each level, round again after the last (the default)
##                    guides     — the │ of each level in its colour (with editor.indentGuides on)
##                    dots       — a coloured dot in each space of the indentation (with indent-dots: its dots)
##                    and a red band where a line's indentation is not whole levels (3 spaces where a level is 2)
##   settings         plugins.rainbow-indent.colors — the colours, in order: the theme's own (warn add info accent
##                    mod) by default, so they suit light and dark themes; or yours: "#e5c07b #98c379 #61afef"
##                    .style (background, guides or dots) · .markWrong (true)
##                    .languages — "" (every file), or the languages' ids: "nim python yaml"
##
## ned draws the colours as it draws each line — the plugin only says, once, how they look: nothing is sent for each
## line, so a big file costs no more than a small one. A band is the colour blended into the background, so text on
## it reads as before; a selection, a search match or a highlight keeps its own colour.
import nedplugin

requiresNed(">= 6.29")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")

const Styles = ["background", "guides", "dots"]

settingDef("colors", "warn add info accent mod", "Rainbow indent: the levels' colours in order — the theme's " &
           "(warn add info accent mod hint error) or \"#rrggbb\", separated by spaces")
settingDef("style", "background", "Rainbow indent: background (bands), guides (the │ of each level in its colour) " &
           "or dots (a coloured dot in each space of the indentation)")
settingDef("markWrong", true, "Rainbow indent: a red band where a line's indentation is not whole levels")
settingDef("languages", "", "Rainbow indent: only in these languages (their ids, \"nim python\"); \"\": every file")

var
  on = true
  styleNow = ""                  # (Rainbow indent: next style — this session's, over the setting)
  sent = ""

proc curStyle(): string =
  ## the style in use: the one chosen with next style in this session, else the style setting; background when it is
  ## none of the three
  result = if styleNow.len > 0: styleNow else: setting("style", "background")
  if result notin Styles: result = "background"

proc look(): IndentStyle =
  ## how the levels are to be drawn now, from the settings (the colours, the style, the colour of a wrong level, the
  ## languages) — an empty style (nothing drawn) when the plugin is off
  if not on: return IndentStyle()
  var cs = setting("colors", "warn add info accent mod").splitWhitespace
  if cs.len == 0: cs = @["warn", "add", "info", "accent", "mod"]
  IndentStyle(levels: cs, levelStyle: curStyle(), wrongColor: (if setting("markWrong", true): "error" else: ""),
              langs: setting("languages", "").splitWhitespace)

proc apply() =
  ## gives ned the look of the levels, but only when it differs from the one given last
  let st = look()
  let key = $st
  if key == sent: return
  sent = key
  indentStyle(st)

# keeps whether the plugin is on, and the style chosen, in the data folder for the next start
proc save() = writeData("state", (if on: "on" else: "off") & "\n" & styleNow & "\n")

command "Rainbow indent: on/off":
  on = not on
  save()
  apply()
  message("Rainbow indent " & (if on: "on" else: "off"))

command "Rainbow indent: next style":
  styleNow = Styles[(Styles.find(curStyle()) + 1) mod Styles.len]
  on = true
  save()
  apply()
  message("Rainbow indent: " & styleNow & (case styleNow
    of "guides": " (the indentation guides in the levels' colours)"
    of "dots": " (a coloured dot in each space of the indentation)"
    else: " (a band for each level)"))

onStartup(proc(ev: Event) =
  let st = readData("state").splitLines
  on = st.len == 0 or st[0].strip != "off"
  if st.len > 1 and st[1].strip in Styles: styleNow = st[1].strip
  apply())
onEnter("*", proc(ev: Event) = apply())      # (a setting changed meanwhile: its new look)
