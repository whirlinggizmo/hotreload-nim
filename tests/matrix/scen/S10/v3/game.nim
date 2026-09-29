import hotreload
type Bag = ref object
  n: int
var hits {.hot.} = 0
var bag {.hot.} = Bag(n: 0)
proc makeCallback*(): (proc (): string) {.hot.} =
  let moves = hotMoves()
  result = proc (): string =
    inc hits
    inc bag.n
    "cb code=v3 madeAtMoves=" & $moves & " nowMoves=" & $hotMoves() & " hits=" & $hits & " bag.n=" & $bag.n
proc tick*() {.hot.} =
  echo "S10 tick v3 hits=", hits, " bag.n=", bag.n, " hotMoves=", hotMoves()
