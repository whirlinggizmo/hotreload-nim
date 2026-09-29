import hotreload
var ticks {.hot.} = 0
proc tick*() {.hot.} =
  inc ticks
  echo "S1 body=v2 ticks=", ticks
