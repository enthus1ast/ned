## a wrapper with mistakes, for the header check
{.compile: "mathx.c".}

proc mx_add*(a: int; b: cint): cint {.importc, header: "mathx.h".}
proc mx_scale*(x: cdouble; factor: float): cdouble {.importc, header: "mathx.h".}
proc mx_count*(text: string): int {.importc, header: "mathx.h".}
proc mx_fill*(buf: ptr uint8; len: csize_t) {.importc, header: "mathx.h".}
proc mx_name*(): cstring {.importc, header: "mathx.h".}
proc mx_printf*(fmt: cstring): cint {.importc, header: "mathx.h".}
var mx_errno* {.importc, header: "mathx.h".}: cint
proc cputs(s: cstring): cint {.importc: "puts", header: "<stdio.h>".}
proc csqrt(x: float32): float32 {.importc: "sqrt", header: "<math.h>".}

echo mx_add(2, 3)
discard cputs("hi")
