import hotreload
proc cAbs(x: cint): cint {.importc: "abs", header: "<stdlib.h>".}
proc cStrtol(s: cstring; e: pointer; base: cint): clong {.importc: "strtol", header: "<stdlib.h>".}
var ticks {.hot.} = 0
proc tick*() {.hot.} =
  inc ticks
  echo "S17 v2 ticks=", ticks, " cAbs(-", ticks, ")=", cAbs(cint(-ticks)), " strtol(ff,16)=", cStrtol("ff", nil, 16)
