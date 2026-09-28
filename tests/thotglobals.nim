import std/unittest
import hotreload
import hotkeys/a/state as sa, hotkeys/b/state as sb

var count {.hot.} = 3

type
  Node = ref object
    name: string
    next: Node

template slot(key: string; T: typedesc): ptr T =
  ## what a library's `var x {.hot.}: T` asks the program for, as one loading after another
  cast[ptr T](hotSlot(key, hash(typeSig(T)), holdsRefs(T),
    proc (): pointer {.cdecl.} = create(T),
    proc (p: pointer): string {.cdecl.} = save(result, (value: cast[ptr T](p)[])),
    proc (p: pointer; data: string) {.cdecl.} =
      var v = (value: move(cast[ptr T](p)[]))
      load(data, v)
      cast[ptr T](p)[] = move(v.value),
    proc (old: pointer): pointer {.cdecl.} =
      let p = create(T)
      copy(p[], cast[ptr T](old))
      p))

suite "hot globals":
  test "keyed by module path and name":
    let keys = hotKeys()
    check "thotglobals.count" in keys
    check "hotkeys/a/state.speed" in keys
    check "hotkeys/b/state.speed" in keys
    check sa.speed == 1 and sb.speed == 2.5 and count == 3

  test "the same type, no refs: the same storage":
    let p = slot("t.same", int)
    p[] = 4
    check slot("t.same", int) == p

  test "another type: new storage, with what still fits":
    type
      V1 = object
        a: int
        b: string
      V2 = object
        a: int
        c: float
    let p1 = slot("t.changed", V1)
    p1[] = V1(a: 5, b: "x")
    let p2 = slot("t.changed", V2)
    check cast[pointer](p2) != cast[pointer](p1)
    check p2.a == 5 and p2.c == 0

  test "refs: copied on each load, the same shape":
    type R = object
      head: Node
    let p1 = slot("t.refs", R)
    p1.head = Node(name: "1", next: Node(name: "2"))
    let p2 = slot("t.refs", R)
    check cast[pointer](p2) != cast[pointer](p1)
    check p2.head != p1.head and p2.head.name == "1" and p2.head.next.name == "2"
