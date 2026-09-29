import hotreload
type
  Enemy = object
    hp: int
    name: string
    shield: int = 10
  Boss = ref object
    hp: int
    name: string
    shield: int = 10
  Hero = object
    hp: int
    shield: int = 10
var ticks {.hot.} = 0
var enemies {.hot.} = @[Enemy(hp: 5, name: "a"), Enemy(hp: 7, name: "b")]
var boss {.hot.} = Boss(hp: 99, name: "boss")
var hero {.hot.} = Hero(hp: 3)
proc tick*() {.hot.} =
  inc ticks
  echo "S3 v2 ticks=", ticks, " enemies=", enemies, " boss=", boss[], " hero=", hero
