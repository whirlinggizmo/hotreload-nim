import hotreload
type Hero = object
  health: int
  gold: int
var hero {.hot.} = Hero(health: 3, gold: 1)
var ticks {.hot.} = 0
proc tick*() {.hot.} =
  inc ticks
  echo "S4 v2 ticks=", ticks, " hero=", hero
