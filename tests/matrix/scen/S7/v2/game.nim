import hotreload
type Color = enum Black, Red, Green, Blue
var c {.hot.} = Red
var ticks {.hot.} = 0
proc tick*() {.hot.} =
  inc ticks
  echo "S7 v2 ticks=", ticks, " c=", c, " ord=", ord(c)
