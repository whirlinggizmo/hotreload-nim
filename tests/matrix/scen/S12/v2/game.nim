import hotreload
import ./helper
var ticks {.hot.} = 0
proc tick*() {.hot.} =
  inc ticks
  echo "S12 v2 ticks=", ticks, " ", helperSays(ticks)
