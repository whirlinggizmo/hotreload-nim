## The smoke test's code, which the program reloads: treload.nim edits its copy.

import hotreload

type
  Stats = object
    count: int
  Node = ref object
    name: string
    next: Node

var stats {.hot.}: Stats
var ring {.hot.}: Node

proc tick*() {.hotEntry.} =
  inc stats.count
  if ring == nil:
    ring = Node(name: "a")
    ring.next = Node(name: "b", next: ring)

proc count*(): int {.hotEntry.} = stats.count

proc report*(): string {.hotEntry.} =
  "v1 ring=" & $(ring.next.next == ring)
