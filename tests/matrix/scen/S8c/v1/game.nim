import hotreload
type Pet = ref object
  n: int
var pet {.hot.} = Pet(n: 1)
proc tick*() {.hot.} =
  inc pet.n
  echo "S8c v1 n=", pet.n
