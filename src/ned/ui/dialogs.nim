# ── toasts ──

type Toast = object
  text: string
  sev: int              # 1 error 2 warn 3 info 4 ok
  at: MonoTime
  ttl: int
  actLabel: string
  act: Action
  fromMsg: bool         # a message (info/warn/error), not a notification with an action

var toasts: seq[Toast]

proc toast(text: string, sev = 3, actLabel = "", act: Action = nil, ttl = 0) =
  ## shows a notification (severity 1 error, 2 warning, 3 info, 4 ok) in the corner, with an optional button running
  ## `act`; the same text again only extends the first one's time, at most four are kept (when notifications are on),
  ## and it goes after `ttl` ms (by default 9 s for an error, 12 s with a button, else 5 s)
  if not cfgToasts: return
  let text = capMsg(text)
  for t in toasts.mitems:
    if t.text == text:
      t.at = getMonoTime()            # the same again: shown a little longer, not twice
      needRender = true
      return
  toasts.add Toast(text: text, sev: sev, at: getMonoTime(),
                   ttl: (if ttl > 0: ttl elif sev == 1: 9000 elif act != nil: 12000 else: 5000),
                   actLabel: actLabel, act: act)
  if toasts.len > 4: toasts.delete(0)
  needRender = true

proc dropToasts(prefix: string) =
  ## the notifications that are no longer true (a folder's "not trusted yet", once it is)
  for i in countdown(toasts.high, 0):
    if toasts[i].text.startsWith(prefix): toasts.delete(i)
  needRender = true

proc popupMsg(s: string, sev: int) =
  ## a message as a popup: info replaces the previous info (no pile of them); warnings and errors stay a while
  let ts = case sev
    of 1: 1
    of 2: 2
    else: 3
  for i in countdown(toasts.high, 0):
    if toasts[i].text == s:
      toasts[i].at = getMonoTime()
      needRender = true
      return
    if ts == 3 and toasts[i].fromMsg and toasts[i].sev == 3: toasts.delete(i)
  toasts.add Toast(text: s, sev: ts, at: getMonoTime(), fromMsg: true,
                   ttl: (if ts == 1: 12000 elif ts == 2: 7000 else: 3500 + min(4000, s.len * 25)))
  while toasts.len > 5: toasts.delete(0)
  needRender = true

proc pruneToasts(): bool =
  ## drops the notifications whose time is up, except while the mouse is over them; true when any was dropped
  var keep: seq[Toast]
  for t in toasts:
    if msSince(t.at) < t.ttl or hov(scrW - 54, 0, 54, scrH): keep.add t
  result = keep.len != toasts.len
  toasts = keep

# ── modal dialogs ──

type Dialog = object
  title, body: string
  buttons: seq[(string, char)]
  sel: int
  onKey: proc(c: char) {.closure.}
  danger: bool

var
  dialogs: seq[Dialog]

# whether a modal dialog is showing (it then gets the keys)
proc dialogOpen(): bool {.inline.} = dialogs.len > 0

proc openDialog(title, body: string, buttons: seq[(string, char)], onKey: proc(c: char) {.closure.},
                defaultSel = 0, danger = false) =
  ## opens a modal dialog on top of the others: a title, a body and buttons (each a label and the key it stands for);
  ## `onKey` is called with the key of the button chosen, `defaultSel` is the button selected at first and `danger`
  ## draws it as a warning
  dialogs.add Dialog(title: title, body: body, buttons: buttons, sel: clamp(defaultSel, 0, max(0, buttons.high)),
                     onKey: onKey, danger: danger)
  needRender = true

proc closeDialog(c: char) =
  ## closes the top dialog and tells its callback which key (button) ended it
  if dialogs.len == 0: return
  let d = dialogs.pop()
  needRender = true
  if d.onKey != nil: d.onKey(c)

proc parseConfirm(message: string): (string, seq[(string, char)]) =
  ## "Save changes to x? (y)es (n)o (c)ancel" → body + buttons; "… (y/n)" → Yes / No
  var body = message
  var buttons: seq[(string, char)]
  if message.endsWith("(y/n)"):
    body = message[0 ..< message.len - 5].strip
    return (body, @[("Yes", 'y'), ("No", 'n')])
  var i = message.find(" (")
  let dash = message.find(" — (")
  if dash >= 0 and (i < 0 or dash < i): i = dash
  if i < 0:
    return (message, @[("OK", 'y'), ("Cancel", 'c')])
  body = message[0 ..< i].replace("—", "").strip(chars = {' ', '-'})
  let rest = message[i .. ^1]
  var k = 0
  while k < rest.len:
    if rest[k] == '(' and k + 2 < rest.len and rest[k + 2] == ')':
      let key = rest[k + 1]
      var e = k + 3
      while e < rest.len and rest[e] notin {'(', ','}: inc e
      var label = ($key).toUpperAscii & rest[k + 3 ..< e].replace("—", "").strip(chars = {' ', ','})
      if label.len == 1:
        label = case key
          of 'y': "Yes"
          of 'n': "No"
          of 'c': "Cancel"
          else: label
      buttons.add (label, key)
      k = e
    else: inc k
  if buttons.len == 0: buttons = @[("OK", 'y'), ("Cancel", 'c')]
  (body, buttons)

proc askConfirm(message: string, action: proc(c: char) {.closure.}) =
  ## asks a question in a dialog, the buttons made from the message's own "(y)es (n)o" hints by parseConfirm; a message
  ## about unsaved changes is titled that way with Save / Don't save buttons, and one starting with Delete or Discard is
  ## shown as a warning. `action` gets the key of the button chosen
  let (body, buttons0) = parseConfirm(message)
  var title = "Confirm"
  var buttons = buttons0
  if "nsaved" in body or "Save changes" in body:
    title = "Unsaved changes"
    for bt in buttons.mitems:
      case bt[1]
      of 'y', 's': bt[0] = (if body.startsWith("Unsaved"): "Save all" else: "Save")
      of 'n', 'd': bt[0] = "Don't save"
      else: discard
  elif body.startsWith("Delete") or body.startsWith("Discard"): title = "Are you sure?"
  openDialog(title, body, buttons, action, 0, body.startsWith("Delete") or body.startsWith("Discard"))
