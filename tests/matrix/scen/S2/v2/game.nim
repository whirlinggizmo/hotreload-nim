import hotreload
var ticks {.hot.} = 0
var bonus {.hot.} = 42
proc tick*() {.hot.} =
  inc ticks
  inc bonus
  echo "S2 v2 ticks=", ticks, " bonus=", bonus
