import hotreload
type
  Base = ref object of RootObj
    n: int
  Derived = ref object of Base
method speak(b: Base): string {.base.} = "base"
method speak(d: Derived): string = "derived v2"
var pet {.hot.}: Base = Derived(n: 1)
proc tick*() {.hot.} =
  inc pet.n
  echo "S8 v2 n=", pet.n, " speak=", pet.speak()
