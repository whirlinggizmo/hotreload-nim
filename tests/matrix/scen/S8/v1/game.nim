import hotreload
type
  Base = ref object of RootObj
    n: int
  Derived = ref object of Base
method speak(b: Base): string {.base.} = "base"
method speak(d: Derived): string = "derived v1"
var pet {.hot.}: Base = Derived(n: 1)
proc tick*() {.hot.} =
  inc pet.n
  echo "S8 v1 n=", pet.n, " speak=", pet.speak()
