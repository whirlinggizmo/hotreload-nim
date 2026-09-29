import hotreload
var ticks {.hot.} = 0
proc tick*() {.hot.} =
  inc ticks
  let x: int = "not an int"
  echo "S15 v2 ticks=", ticks
