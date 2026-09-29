import hotreload
type Color = enum Red, Green, Blue
var c {.hot.} = Red
var ticks {.hot.} = 0
proc tick*() {.hot.} =
  inc ticks
  if ticks == 2: c = Blue
  echo "S7 v1 ticks=", ticks, " c=", c, " ord=", ord(c)
