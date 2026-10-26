# ── forms: dialogs with fields, as a desktop app has them — check boxes, choices (a drop-down list), text fields,
#    links, buttons. Tab and the arrows move between the fields, Space ticks a box or opens a choice, Enter is the
#    default button, Esc cancels; every field answers the mouse (a click ticks, opens the list, places the cursor; a
#    drag selects in a text field). A form with groups (the settings) has a side list of them and a search field
#    over every field. ──

type
  FfKind = enum ffText, ffNumber, ffCheck, ffChoice, ffLabel, ffHeader, ffAction
  FormField = ref object
    kind: FfKind
    key, label, help: string
    on: bool                      # ffCheck
    opts, optLabels: seq[string]  # ffChoice: the values, and how they show (optLabels may be empty)
    sel: int
    text: string                  # ffText, ffNumber
    cur: int
    placeholder: string
    secret: bool
    disabled: bool
    group: string                 # (a form with groups) the group it is in
    search: string                # (a form with groups) more words its search finds it by
    act: Action                   # ffAction: what a click does
    tag: string                   # what the field is for (free: the settings keep their key's kind here)
    onChange: proc(f: FormField)
    def: string                   # its default (hasDef): ↺ beside it when it differs, a click puts it back
    hasDef: bool
  FormButton = object
    label, id: string
    primary, danger, left: bool   # left: on the left of the row (a secondary action)
  Form = ref object
    title, intro: string
    fields: seq[FormField]
    buttons: seq[FormButton]
    focus: int                    # 0 ..< fields.len a field, then the buttons
    scroll: int                   # (the first content row shown)
    width: int                    # wanted width (0: 64)
    tall: bool                    # as tall as the screen allows (the settings)
    danger: bool                  # a frame in the warning colour
    groups: seq[string]           # the side list (empty: none)
    group: int
    filter: string                # (with groups) the search over every field
    filterCur: int
    zone: int                     # (with groups) where the keyboard is: 0 the fields and buttons, 1 the side list,
                                  # 2 the search field
    error: string
    onButton: proc(f: Form, id: string): bool    # true: the form closes (nil: every button closes it)
    # (the last drawing: for the mouse wheel, the scroll bar, keeping the focus in view)
    contentY, contentH, contentRows: int
    sbX: int
    sbTop, sbH, sbThumbH: int     # (the scroll bar's track and thumb: a press puts the thumb's middle there)
    shownFocus: int               # the field last brought into view (the scroll bar and the wheel move away from it;
                                  # a key or another focus brings it back)

var forms: seq[Form]

proc formOpen(): bool {.inline.} = forms.len > 0

proc newForm(title: string, intro = ""): Form = Form(title: title, intro: intro, sbX: -1, shownFocus: -2)

proc addField(f: Form, ff: FormField): FormField {.discardable.} =
  f.fields.add ff
  ff

proc addCheck(f: Form, key, label: string, on: bool, help = ""): FormField {.discardable.} =
  f.addField FormField(kind: ffCheck, key: key, label: label, on: on, help: help)

proc addChoice(f: Form, key, label: string, opts: seq[string], value: string, help = "",
            labels: seq[string] = @[]): FormField {.discardable.} =
  f.addField FormField(kind: ffChoice, key: key, label: label, opts: opts, optLabels: labels, sel: max(0, opts.find(value)),
                  help: help)

proc addText(f: Form, key, label, text: string, placeholder = "", help = "", secret = false): FormField {.discardable.} =
  f.addField FormField(kind: ffText, key: key, label: label, text: text, cur: text.len, placeholder: placeholder,
                  help: help, secret: secret)

proc addNumber(f: Form, key, label: string, n: int, help = ""): FormField {.discardable.} =
  f.addField FormField(kind: ffNumber, key: key, label: label, text: $n, cur: len($n), help: help)

proc addNote(f: Form, text: string): FormField {.discardable.} = f.addField FormField(kind: ffLabel, label: text)
proc addHeader(f: Form, text: string): FormField {.discardable.} = f.addField FormField(kind: ffHeader, label: text)
proc addLink(f: Form, label: string, act: Action, help = ""): FormField {.discardable.} =
  f.addField FormField(kind: ffAction, label: label, act: act, help: help)

proc addButton(f: Form, label, id: string, primary = false, danger = false, left = false) =
  f.buttons.add FormButton(label: label, id: id, primary: primary, danger: danger, left: left)

proc formField(f: Form, key: string): FormField =
  for ff in f.fields:
    if ff.key == key: return ff
  FormField(kind: ffLabel)            # (no such field: an empty one, so a typo cannot crash)

proc formChecked(f: Form, key: string): bool = f.formField(key).on
proc formValue(f: Form, key: string): string =
  let ff = f.formField(key)
  case ff.kind
  of ffChoice: (if ff.sel >= 0 and ff.sel < ff.opts.len: ff.opts[ff.sel] else: "")
  of ffCheck: $ff.on
  else: ff.text

func focusable(ff: FormField): bool = ff.kind notin {ffLabel, ffHeader} and not ff.disabled

proc formVisible(f: Form): seq[int] =
  ## the fields shown: all — or, with groups, the chosen group's (or those the search finds, in every group)
  if f.groups.len == 0:
    for i in 0 ..< f.fields.len: result.add i
    return
  let q = f.filter.strip.toLowerAscii
  if q.len > 0:
    let words = q.splitWhitespace
    var lastGroup = ""
    for i, ff in f.fields:
      if ff.kind in {ffHeader, ffLabel}: continue
      let hay = (ff.label & " " & ff.help & " " & ff.key & " " & ff.search & " " & ff.group).toLowerAscii
      var ok = true
      for w in words:
        if w notin hay: ok = false
      if ok:
        if ff.group != lastGroup:
          lastGroup = ff.group
          result.add -1 - i           # (a group's name over its fields: a header row, negative)
        result.add i
    return
  let g = if f.group >= 0 and f.group < f.groups.len: f.groups[f.group] else: ""
  for i, ff in f.fields:
    if ff.group == g: result.add i

proc formFocusList(f: Form): seq[int] =
  ## where Tab goes: the shown fields that take the keyboard, then the buttons (as fields.len + k)
  for i in f.formVisible:
    if i >= 0 and f.fields[i].focusable: result.add i
  for k in 0 ..< f.buttons.len: result.add f.fields.len + k

proc formFix(f: Form) =
  ## the focus on something that takes it
  let fl = f.formFocusList
  if fl.len == 0: return
  if f.focus notin fl:
    f.focus = fl[0]

proc openForm(f: Form) =
  if f.buttons.len == 0:
    f.addButton("Cancel", "cancel")
    f.addButton("OK", "ok", primary = true)
  f.focus = -1
  f.formFix()
  closeComp()
  hoverOpen = false
  forms.add f
  needRender = true

proc closeForm() =
  if forms.len == 0: return
  discard forms.pop()
  needRender = true

proc formPress(f: Form, id: string) =
  ## a button: the form's answer — it closes when its handler says so (or has none)
  f.error = ""
  let close = if f.onButton == nil: true else: f.onButton(f, id)
  if close and forms.len > 0 and forms[^1] == f: closeForm()
  needRender = true

proc formCancel(f: Form) =
  var id = "cancel"
  for b in f.buttons:
    if b.id == "cancel": id = "cancel"
  f.formPress(id)

proc formPrimary(f: Form) =
  for b in f.buttons:
    if b.primary:
      f.formPress(b.id)
      return
  if f.buttons.len > 0: f.formPress(f.buttons[^1].id)

proc formChanged(f: Form, ff: FormField) =
  if ff.onChange != nil: ff.onChange(ff)
  needRender = true

proc formOpenChoice(f: Form, ff: FormField, x, y: int) =
  ## the choice's list, under the field: the current one ticked
  var items: seq[MenuItem]
  for i, o in ff.opts:
    let k = i
    let lab = if i < ff.optLabels.len and ff.optLabels[i].len > 0: ff.optLabels[i] else: o
    capture k:
      items.add mi(lab, "", proc() =
        ff.sel = k
        f.formChanged(ff), (if k == ff.sel: 1 else: 0))
  openMenu(items, x, y)
  if menus.len > 0:
    menus[^1].sel = clamp(ff.sel, 0, max(0, items.high))
    menus[^1].menuKeepSel()

proc formActivate(f: Form, i: int, x = -1, y = -1) =
  ## a field used (Space, a click): a box ticked, a list opened, a link followed
  if i < 0 or i >= f.fields.len: return
  let ff = f.fields[i]
  if ff.disabled: return
  case ff.kind
  of ffCheck:
    ff.on = not ff.on
    f.formChanged(ff)
  of ffChoice: f.formOpenChoice(ff, (if x >= 0: x else: scrW div 2 - 10), (if y >= 0: y else: scrH div 3))
  of ffAction:
    if ff.act != nil: ff.act()
  else: discard
  needRender = true

proc formMoveFocus(f: Form, d: int) =
  let fl = f.formFocusList
  if fl.len == 0: return
  var k = fl.find(f.focus)
  if k < 0: k = 0
  else: k = (k + d + fl.len) mod fl.len
  f.focus = fl[k]
  needRender = true

proc formScroll(d: int) =
  if forms.len == 0: return
  let f = forms[^1]
  f.scroll = clamp(f.scroll + d, 0, max(0, f.contentRows - f.contentH))
  needRender = true

proc formScrollTo(y: int) =
  ## the scroll bar's thumb under the pointer (its middle there): a tap on the track jumps, a drag follows
  if forms.len == 0: return
  let f = forms[^1]
  if f.contentH <= 1 or f.contentRows <= f.contentH: return
  let span = max(1, f.sbH - f.sbThumbH)
  let top = y - f.sbTop - f.sbThumbH div 2
  f.scroll = clamp(top * (f.contentRows - f.contentH) div span, 0, f.contentRows - f.contentH)
  needRender = true

proc formValueOf(ff: FormField): string =
  case ff.kind
  of ffChoice: (if ff.sel >= 0 and ff.sel < ff.opts.len: ff.opts[ff.sel] else: "")
  of ffCheck: $ff.on
  else: ff.text

proc formReset(f: Form, ff: FormField) =
  ## the field back to its default
  case ff.kind
  of ffCheck: ff.on = ff.def == "true"
  of ffChoice:
    let k = ff.opts.find(ff.def)
    if k >= 0: ff.sel = k
  of ffText, ffNumber:
    ff.text = ff.def
    ff.cur = ff.text.len
  else: discard
  f.formChanged(ff)

proc boxEdges(x, y, w: int, under, edge: Rgb) =
  ## a one-row box's sides: thin lines just outside it (▕ before, ▏ after)
  if x - 1 >= 0: setCell(x - 1, y, Cell(ch: 0x2595, fg: edge, bg: under))
  if x + w < scrW: setCell(x + w, y, Cell(ch: 0x258F, fg: edge, bg: under))

proc formLabelW(f: Form, vis: seq[int], areaW: int): int =
  for i in vis:
    if i >= 0 and f.fields[i].kind in {ffText, ffNumber, ffChoice}:
      result = max(result, strWidth(f.fields[i].label) + 4)
  result = clamp(result, 10, max(10, areaW * 2 div 5))

proc formRowsOf(f: Form, i, areaW, lw: int): int =
  if i < 0: return 1
  let ff = f.fields[i]
  case ff.kind
  of ffLabel: max(1, wrapText(ff.label, areaW - 2).len)
  of ffHeader: 1
  of ffText, ffNumber, ffChoice: (if areaW - lw < 16: 2 else: 1)
  else: 1

proc drawFormField(f: Form, i, ax, ry, n, areaW, lw, bodyTop, bodyBot: int): (string, int, int) =
  ## one field of a form at row ry (its label, its control): (its help when it has the focus, the cursor's x and y).
  ## Each kind of control looks like itself: a check box is a small box (filled when ticked), a text field a box
  ## with thin sides, a number one with − and + beside it, a list a box with ▾, a link a button; the row the
  ## pointer is on is tinted, the one with the focus more and marked ▍ on the left; ↺ at the end puts back a
  ## setting's default
  result = ("", -1, -1)
  let bg = theme.menuBg
  let ff = f.fields[i]
  let focused = i == f.focus and f.zone == 0
  let fg = if ff.disabled: theme.dim else: theme.fg
  let rowH = (if n == 2: 2 else: 1)
  template inView(yy: int): bool = yy >= bodyTop and yy < bodyBot
  let rowBg = if focused: blend(bg, theme.accent, 0.10)
              elif ff.kind notin {ffHeader, ffLabel} and hov(ax - 1, ry, areaW + 1, rowH): blend(bg, theme.fg, 0.05)
              else: bg
  if rowBg != bg:
    for k in 0 ..< rowH:
      if inView(ry + k): fillRect(ax - 1, ry + k, areaW + 1, 1, fg, rowBg)
  if focused and inView(ry): discard putStr(ax - 1, ry, "▍", theme.accent, rowBg)
  let fieldBg = seenOn(theme.inputBg, rowBg, 0.10)
  let edge = seenOn(theme.inputBorder, rowBg, 0.30)
  let endX = ax + areaW - (if f.groups.len > 0: 3 else: 0)      # (settings: a column for ↺)
  let idx = i
  # ↺: back to the default (a setting changed from it)
  if ff.hasDef and ff.formValueOf != ff.def and inView(ry) and not ff.disabled:
    capture idx:
      discard button(ax + areaW - 2, ry, "↺", proc() =
        f.zone = 0
        f.focus = idx
        f.formReset(ff), "Back to the default: " & (if ff.def.len > 0: ff.def else: "(empty)"), theme.accent, rowBg)
  case ff.kind
  of ffHeader:
    if inView(ry):
      let e = putStr(ax, ry, ff.label, theme.accent, bg, {aBold}, ax + areaW)
      for xx in e + 1 ..< ax + areaW: setCell(xx, ry, Cell(ch: 0x2500, fg: theme.border, bg: bg))
  of ffLabel:
    for k, l in wrapText(ff.label, areaW - 2):
      if inView(ry + k): discard putStr(ax, ry + k, l, theme.dim, bg, {}, ax + areaW)
  of ffCheck:
    if inView(ry):
      # ▐✓▌ — a box of its own colour: the accent when ticked
      let boxBg = if ff.on: (if ff.disabled: theme.dim else: theme.accent) else: fieldBg
      setCell(ax, ry, Cell(ch: 0x2590, fg: boxBg, bg: rowBg))
      discard putStr(ax + 1, ry, (if ff.on: "✓" else: " "), (if ff.on: theme.badgeFg else: theme.dim), boxBg, {aBold})
      setCell(ax + 2, ry, Cell(ch: 0x258C, fg: boxBg, bg: rowBg))
      if not ff.on: boxEdges(ax + 1, ry, 1, rowBg, edge)
      discard putStr(ax + 4, ry, ff.label, (if focused: theme.accent else: fg), rowBg, (if focused: {aBold} else: {}),
                     endX)
      capture idx:
        region(ax - 1, ry, endX - ax + 1, 1, proc() =
          f.zone = 0
          f.focus = idx
          f.formActivate(idx), ff.help)
  of ffAction:
    if inView(ry):
      # a link: a button
      let bb = seenOn(theme.btnBg, rowBg, 0.14)
      capture idx:
        discard pill(ax, ry, "› " & truncTo(ff.label, max(4, endX - ax - 6)), proc() =
          f.zone = 0
          f.focus = idx
          f.formActivate(idx), ff.help, (if ff.disabled: theme.dim else: theme.accent), (if focused: blend(bb, theme.accent, 0.25) else: bb),
          (if focused: {aBold} else: {}))
  of ffText, ffNumber, ffChoice:
    let two = n == 2
    if inView(ry):
      discard putStr(ax + 1, ry, ff.label, (if focused: theme.accent else: fg), rowBg, (if focused: {aBold} else: {}),
                     ax + (if two: areaW else: lw - 2))
      capture idx:
        region(ax - 1, ry, (if two: areaW else: lw), 1, proc() =
          f.zone = 0
          f.focus = idx, ff.help)
    let fy = if two: ry + 1 else: ry
    let fx = if two: ax + 3 else: ax + lw
    let room = max(6, endX - fx - 1)
    if inView(fy):
      let fbg = if focused: blend(fieldBg, theme.accent, 0.12)
                elif hov(fx, fy, room): blend(fieldBg, theme.fg, 0.06) else: fieldBg
      if ff.kind == ffChoice:
        let cur = if ff.sel >= 0 and ff.sel < ff.opts.len:
                    (if ff.sel < ff.optLabels.len and ff.optLabels[ff.sel].len > 0: ff.optLabels[ff.sel] else: ff.opts[ff.sel])
                  else: ""
        var mw = 0
        for k, o in ff.opts:
          mw = max(mw, strWidth(if k < ff.optLabels.len and ff.optLabels[k].len > 0: ff.optLabels[k] else: o))
        let cw = min(room, max(14, mw + 4))
        fillRect(fx, fy, cw, 1, fg, fbg)
        boxEdges(fx, fy, cw, rowBg, (if focused: theme.accent else: edge))
        discard putStr(fx + 1, fy, cur, fg, fbg, {}, fx + cw - 2)
        discard putStr(fx + cw - 2, fy, "▾", theme.accent, fbg, {aBold})
        let ffx = fx
        let ffy = fy
        capture idx, ffx, ffy:
          region(fx, fy, cw, 1, proc() =
            f.zone = 0
            f.focus = idx
            f.formActivate(idx, ffx, ffy + 1), ff.help)
      else:
        # a number: a narrow box and − + beside it (a tap each: no keyboard needed on a phone)
        let bw = max(4, if ff.kind == ffNumber: min(room - 9, 12) else: min(room, 52))
        fillRect(fx, fy, bw, 1, fg, fbg)                          # (a space inside each side)
        let cx = drawField(fx + 1, fy, bw - 2, ff.text, ff.cur, focused and not ff.disabled, fg, fbg,
                           ff.placeholder, ff.secret, onFocus = proc() =
                             f.zone = 0
                             f.focus = idx)
        boxEdges(fx, fy, bw, rowBg, (if focused: theme.accent else: edge))
        if ff.kind == ffNumber and not ff.disabled:
          let sb = seenOn(theme.btnBg, rowBg, 0.14)
          proc step(d: int) =
            var v = 0
            try: v = parseInt(ff.text.strip)
            except ValueError: v = 0
            ff.text = $(v + d)
            ff.cur = ff.text.len
            f.zone = 0
            f.focus = idx
            f.formChanged(ff)
          let px = pill(fx + bw + 2, fy, "−", proc() = step(-1), "One less", theme.fg, sb)
          discard pill(px, fy, "+", proc() = step(1), "One more", theme.fg, sb)
        if focused: result = (ff.help, cx, fy)
  if i == f.focus and f.zone == 0 and result[0].len == 0: result[0] = f.fields[i].help

proc drawForm() =
  if forms.len == 0: return
  let f = forms[^1]
  f.formFix()
  shadeRect(0, 0, scrW, scrH)
  let border = if f.danger: theme.warn else: theme.accent
  var w = if f.tall: min(scrW - 2, 118) else: min(scrW - 2, (if f.width > 0: f.width else: 64))
  let hasSide = f.groups.len > 0 and w >= 70
  let sideW = if hasSide: clamp(w div 4, 18, 28) else: 0
  let areaX0 = 2 + (if hasSide: sideW + 1 else: 0)            # (from the frame's left edge)
  let areaW = w - areaX0 - 4                                    # (two columns for the scroll bar)
  let vis = f.formVisible
  let lw = f.formLabelW(vis, areaW)
  # the content's height: the intro, the fields
  let introLines = if f.intro.len > 0: wrapText(f.intro, w - 6) else: @[]
  var contentRows = 0
  for i in vis: contentRows += f.formRowsOf(i, areaW, lw)
  let narrowGroups = f.groups.len > 0 and not hasSide
  let topRows = (if f.groups.len > 0: 2 else: 0) + (if narrowGroups: 1 else: 0) +
                (if introLines.len > 0: introLines.len + 1 else: 0)
  let helpRows = 2
  let chrome = 2 + topRows + helpRows + 2                       # frame, top, help, buttons + a gap
  var h = if f.tall: scrH - 2 else: min(scrH - 2, chrome + max(1, contentRows))
  h = max(h, min(scrH - 2, chrome + 1))
  let (x, y) = boxPlace("form:" & f.title, (scrW - w) div 2, max(0, (scrH - h) div 2 - (if f.tall: 0 else: 1)),
                        w, h)
  modalStart = regions.len
  region(0, 0, scrW, scrH, proc() = discard)                  # (outside: nothing — Esc or Cancel close it)
  drawFrame(x, y, w, h, theme.menuBg, border, f.title, border)
  let bg = theme.menuBg
  var cy = y + 1
  # the intro
  for l in introLines:
    discard putStr(x + 3, cy, l, theme.fg, bg, {}, x + w - 2)
    inc cy
  if introLines.len > 0: inc cy
  # with groups: the search field over the top, the side list (or, narrow, the group as a row with arrows)
  if f.groups.len > 0:
    discard putStr(x + 2, cy, ic("search"), (if f.zone == 2: theme.accent else: theme.dim), bg)
    let fx = drawField(x + 4, cy, w - 7, f.filter, f.filterCur, f.zone == 2, theme.fg, theme.inputBg,
                       (if w >= 68: "Search every setting (words of its name or description)"
                        else: "Search every setting"),
                       onFocus = proc() = (f.zone = 2), hintFocused = true)
    if f.zone == 2:
      cursorX = fx
      cursorY = cy
    cy += 2
    if narrowGroups:
      let g = if f.group < f.groups.len: f.groups[f.group] else: ""
      var gx = button(x + 2, cy, " ‹ ", proc() =
        f.group = (f.group - 1 + f.groups.len) mod f.groups.len
        f.scroll = 0, "Previous group", theme.accent, bg)
      gx = putStr(gx + 1, cy, g, theme.fg, bg, {aBold}, x + w - 6)
      discard button(gx + 1, cy, " › ", proc() =
        f.group = (f.group + 1) mod f.groups.len
        f.scroll = 0, "Next group", theme.accent, bg)
      inc cy
  let bodyTop = cy
  let bodyBot = y + h - 1 - helpRows - 2                      # (exclusive)
  if hasSide:
    for yy in bodyTop ..< bodyBot:
      setCell(x + 1 + sideW, yy, Cell(ch: 0x2502, fg: theme.border, bg: bg))
    for gi, g in f.groups:
      let yy = bodyTop + gi
      if yy >= bodyBot: break
      let selected = gi == f.group and f.filter.strip.len == 0
      let rowBg = if selected and f.zone == 1: theme.menuSel
                  elif selected: blend(bg, theme.menuSel, 0.5)
                  elif hov(x + 1, yy, sideW): theme.hoverBg
                  else: bg
      fillRect(x + 1, yy, sideW, 1, theme.fg, rowBg)
      if selected: discard putStr(x + 1, yy, "▍", theme.accent, rowBg)
      discard putStr(x + 3, yy, g, (if selected: theme.fg else: theme.dim), rowBg, (if selected: {aBold} else: {}),
                     x + sideW)
      let k = gi
      capture k:
        region(x + 1, yy, sideW, 1, proc() =
          f.group = k
          f.filter = ""
          f.filterCur = 0
          f.scroll = 0
          f.zone = 1
          f.focus = -1
          f.formFix())
  # the fields
  let ax = x + areaX0
  let viewH = max(1, bodyBot - bodyTop)
  f.contentY = bodyTop
  f.contentH = viewH
  f.contentRows = contentRows
  # (the focused field in view — when it changed, or a key was pressed: not against the scroll bar or the wheel)
  if f.focus != f.shownFocus:
    f.shownFocus = f.focus
    var r = 0
    for i in vis:
      let n = f.formRowsOf(i, areaW, lw)
      if i == f.focus:
        if r < f.scroll: f.scroll = r
        elif r + n > f.scroll + viewH: f.scroll = r + n - viewH
      r += n
  f.scroll = clamp(f.scroll, 0, max(0, contentRows - viewH))
  var row = 0
  var helpText = ""
  for i in vis:
    let n = f.formRowsOf(i, areaW, lw)
    let r0 = row
    row += n
    if r0 + n <= f.scroll or r0 >= f.scroll + viewH: continue
    let ry = bodyTop + r0 - f.scroll
    if i < 0:
      # (a search's group name over its fields)
      let g = f.fields[-1 - i].group
      if ry >= bodyTop and ry < bodyBot:
        discard putStr(ax, ry, g, theme.accent, bg, {aBold}, ax + areaW)
      continue
    let (hx, cx, cyy) = drawFormField(f, i, ax, ry, n, areaW, lw, bodyTop, bodyBot)
    if i == f.focus and f.zone == 0: helpText = hx
    if cx >= 0:
      cursorX = cx
      cursorY = cyy
  # the scroll bar (when the fields are more than the room): two columns wide — ▲ and ▼ to tap, the track a tap
  # jumps on (touch screens: Termux sends taps, not drags), the thumb a mouse drags
  f.sbX = -1
  if contentRows > viewH and viewH >= 3:
    let sx = x + w - 3
    f.sbX = sx
    let trackTop = bodyTop + 1
    let trackH = max(1, viewH - 2)
    let thumbH = clamp(trackH * viewH div contentRows, 1, trackH)
    let thumbY = trackTop + (trackH - thumbH) * f.scroll div max(1, contentRows - viewH)
    f.sbTop = trackTop
    f.sbH = trackH
    f.sbThumbH = thumbH
    let track = blend(bg, theme.fg, 0.07)
    let thumb = seenOn(theme.scrollThumb, track, 0.35)
    for yy in trackTop ..< trackTop + trackH:
      let on = yy >= thumbY and yy < thumbY + thumbH
      for xx in sx .. sx + 1: setCell(xx, yy, Cell(ch: 32, fg: theme.fg, bg: (if on: thumb else: track)))
    discard button(sx, bodyTop, "▲ ", proc() = formScroll(-3), "Up", theme.accent, track)
    discard button(sx, bodyBot - 1, "▼ ", proc() = formScroll(3), "Down", theme.accent, track)
    region(sx, trackTop, 2, trackH, proc() =
      dragTarget = dtFormScroll
      formScrollTo(mouseY), "Drag, or tap where to go")
  # the help of the focused field, an error, the buttons
  let hy = y + h - 1 - helpRows - 1
  for xx in x + 2 ..< x + w - 2: setCell(xx, hy - 1, Cell(ch: 0x2500, fg: theme.border, bg: bg))
  if f.groups.len > 0 and f.focus >= 0 and f.focus < f.fields.len and f.zone == 0 and f.error.len == 0 and
     f.fields[f.focus].key.len > 0 and '.' in f.fields[f.focus].key:
    # (the settings: the key it has in the file, over the line)
    let k = " " & f.fields[f.focus].key & " "
    discard putStr(x + w - 3 - strWidth(k), hy - 1, k, theme.accent, bg, {}, x + w - 2)
  if f.error.len > 0:
    discard putStr(x + 3, hy, ic("error") & " " & f.error, theme.err, bg, {aBold}, x + w - 2)
  elif helpText.len > 0:
    let hl = wrapText(helpText, w - 6)
    for k in 0 ..< min(helpRows, hl.len):
      discard putStr(x + 3, hy + k, (if k == helpRows - 1 and hl.len > helpRows: truncTo(hl[k] & " " & hl[k + 1], w - 6)
                                     else: hl[k]),
                     theme.dim, bg, {aItalic}, x + w - 2)
  let by = y + h - 2
  var rightW = 0
  for b in f.buttons:
    if not b.left: rightW += strWidth(b.label) + 5
  var lx = x + 2
  var bx = x + w - 1 - rightW
  for k, b in f.buttons:
    let fi = f.fields.len + k
    let focused = f.focus == fi and f.zone == 0
    let base = if b.danger: theme.warn elif b.primary: theme.accent else: seenOn(theme.btnBg, bg, 0.16)
    let bfg = if b.primary or b.danger: theme.badgeFg else: theme.fg
    let bbg = if focused and not b.primary: blend(base, theme.accent, 0.35) else: base
    let id = b.id
    capture id:
      let act = proc() = f.formPress(id)
      if b.left: lx = pill(lx, by, b.label, act, "", bfg, bbg, (if b.primary or focused: {aBold} else: {})) + 1
      else: bx = pill(bx, by, b.label, act, "", bfg, bbg, (if b.primary or focused: {aBold} else: {}),
                      blend(bbg, theme.fg, 0.15)) + 1
  if f.zone != 0 and f.zone != 2: cursorX = -1
  elif f.zone == 0 and f.focus >= f.fields.len: cursorX = -1

proc formKey(k: Key) =
  if forms.len == 0: return
  let f = forms[^1]
  f.formFix()
  needRender = true
  if k.kind notin {kPgUp, kPgDn}: f.shownFocus = -2       # (the field the keys go to: in view again)
  if k.kind == kEsc:
    f.formCancel()
    return
  # with groups: the search field and the side list
  if f.groups.len > 0:
    if k.kind == kTab and mShift in k.mods and f.zone == 0 and f.formFocusList.find(f.focus) == 0:
      f.zone = 1
      return
    case f.zone
    of 2:
      case k.kind
      of kDown, kTab, kEnter:
        f.zone = 0
        f.focus = -1
        f.formFix()
      else:
        if editLine(f.filter, f.filterCur, k):
          f.scroll = 0
          f.focus = -1
          f.formFix()
      return
    of 1:
      case k.kind
      of kUp: f.group = max(0, f.group - 1)
      of kDown: f.group = min(f.groups.high, f.group + 1)
      of kRight, kTab, kEnter:
        f.zone = 0
        f.focus = -1
        f.formFix()
        return
      of kChar:
        if k.mods == {} or k.mods == {mShift}:
          f.zone = 2
          discard editLine(f.filter, f.filterCur, k)
        return
      else: return
      f.scroll = 0
      f.focus = -1
      f.formFix()
      return
    else: discard
  let onField = f.focus >= 0 and f.focus < f.fields.len
  let ff = if onField: f.fields[f.focus] else: nil
  case k.kind
  of kTab:
    if f.groups.len > 0 and mShift notin k.mods and f.formFocusList.find(f.focus) == f.formFocusList.high:
      f.zone = 2                       # (round again: the search field)
      return
    f.formMoveFocus(if mShift in k.mods: -1 else: 1)
    return
  of kUp, kDown:
    if onField or k.kind == kUp:
      if not onField and k.kind == kUp:
        # from the buttons, up to the last field
        let fl = f.formFocusList
        for j in countdown(fl.high, 0):
          if fl[j] < f.fields.len:
            f.focus = fl[j]
            return
        return
      if k.kind == kUp and f.groups.len > 0 and f.formFocusList.find(f.focus) == 0:
        f.zone = 2
        return
      f.formMoveFocus(if k.kind == kUp: -1 else: 1)
    return
  of kPgUp, kPgDn:
    formScroll(if k.kind == kPgUp: -max(1, f.contentH - 1) else: max(1, f.contentH - 1))
    return
  of kEnter:
    if onField and ff.kind == ffAction:
      f.formActivate(f.focus)
    elif not onField and f.focus >= f.fields.len: f.formPress(f.buttons[f.focus - f.fields.len].id)
    else: f.formPrimary()
    return
  else: discard
  if not onField:
    # on the buttons: ← → between them, Space presses
    case k.kind
    of kLeft: f.formMoveFocus(-1)
    of kRight: f.formMoveFocus(1)
    of kChar:
      if k.ch == ord(' ') and f.focus >= f.fields.len: f.formPress(f.buttons[f.focus - f.fields.len].id)
    else: discard
    return
  case ff.kind
  of ffCheck:
    if k.kind == kChar and k.ch == ord(' ') and k.mods == {}: f.formActivate(f.focus)
  of ffChoice:
    if k.kind == kChar and k.ch == ord(' ') and k.mods == {}: f.formActivate(f.focus)
    elif k.kind in {kLeft, kRight} and ff.opts.len > 0:
      ff.sel = (ff.sel + (if k.kind == kLeft: -1 else: 1) + ff.opts.len) mod ff.opts.len
      f.formChanged(ff)
  of ffAction:
    if k.kind == kChar and k.ch == ord(' ') and k.mods == {}: f.formActivate(f.focus)
  of ffText, ffNumber:
    if ff.disabled: return
    if ff.kind == ffNumber and k.kind == kChar and k.mods == {} and k.ch < 128 and char(k.ch) notin {'0'..'9', '-'}:
      return
    if editLine(ff.text, ff.cur, k): f.formChanged(ff)
  else: discard
