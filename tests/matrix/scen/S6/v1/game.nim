import hotreload
var score {.hot.} = 5
proc tick*() {.hot.} =
  inc score
  echo "S6 v1 score=", score
