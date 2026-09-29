import hotreload
type Hero = object
  hp: int
  gold: int
var hero {.hot.} = Hero(hp: 3, gold: 1)
var ticks {.hot.} = 0
proc tick*() {.hot.} =
  inc ticks
  hero.hp += 10
  hero.gold += 1
  echo "S5 v1 ticks=", ticks, " hero=", hero
