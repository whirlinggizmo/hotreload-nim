import hotreload
var score {.hot.} = "first"
proc tick*() {.hot.} =
  score.add "!"
  echo "S6 v2 score=", score
