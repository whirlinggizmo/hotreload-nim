import hotreload
type Hero = object
  hp: float
  gold: int
var hero {.hot.} = Hero(hp: 3.5, gold: 1)
var ticks {.hot.} = 0
proc tick*() {.hot.} =
  inc ticks
  echo "S5 v2 ticks=", ticks, " hero=", hero
