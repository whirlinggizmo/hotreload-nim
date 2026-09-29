import hotreload
type Pet = ref object of RootObj
  n: int
var pet {.hot.} = Pet(n: 1)
proc tick*() {.hot.} =
  inc pet.n
  echo "S8c v2 n=", pet.n
