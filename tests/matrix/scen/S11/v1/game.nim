import hotreload
type Node = ref object
  name: string
  val: int
  buddy: Node
proc makePair(): tuple[a, b: Node] =
  let a = Node(name: "a")
  let b = Node(name: "b", buddy: a)
  a.buddy = b
  (a, b)
var pair {.hot.} = makePair()          # both ends in one global
var na {.hot.} = Node(name: "na")      # two globals pointing at each other
var nb {.hot.} = Node(name: "nb")
var ticks {.hot.} = 0
proc tick*() {.hot.} =
  inc ticks
  if ticks == 1:
    na.buddy = nb
    nb.buddy = na
  inc pair.a.val
  inc na.val
  echo "S11 v1 ticks=", ticks,
    " pair.a.buddy==pair.b:", pair.a.buddy == pair.b,
    " cycle a.buddy.buddy==a:", pair.a.buddy.buddy == pair.a,
    " pair.b.buddy.val=", pair.b.buddy.val, " pair.a.val=", pair.a.val,
    " | na.buddy==nb:", na.buddy == nb, " nb.buddy==na:", nb.buddy == na,
    " na.val=", na.val, " nb.buddy.val=", (if nb.buddy != nil: nb.buddy.val else: -1)
