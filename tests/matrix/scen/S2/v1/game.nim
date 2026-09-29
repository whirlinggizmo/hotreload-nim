import hotreload
var ticks {.hot.} = 0
proc tick*() {.hot.} =
  inc ticks
  echo "S2 v1 ticks=", ticks
