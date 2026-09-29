import hotreload
type
  Enemy = object
    hp: int
    name: string
  Boss = ref object
    hp: int
    name: string
  Hero = object
    hp: int
var ticks {.hot.} = 0
var enemies {.hot.} = @[Enemy(hp: 5, name: "a"), Enemy(hp: 7, name: "b")]
var boss {.hot.} = Boss(hp: 99, name: "boss")
var hero {.hot.} = Hero(hp: 3)
proc tick*() {.hot.} =
  inc ticks
  for e in enemies.mitems: e.hp += 100
  boss.hp += 1000
  hero.hp += 10
  if ticks == 2: enemies.add Enemy(hp: 1, name: "late")
  echo "S3 v1 ticks=", ticks, " enemies=", enemies, " boss=", boss[], " hero=", hero
