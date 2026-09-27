## The smoke test's code, which the program reloads: treload.nim edits its copy.

import hotreload

const Version = "v1"

type
  Stats = object
    count: int
  Node = ref object
    name: string
    next: Node

var stats {.hot.}: Stats
var ring {.hot.}: Node

proc tick*() {.hot.} =
  inc stats.count
  if ring == nil:
    ring = Node(name: "a")
    ring.next = Node(name: "b", next: ring)

proc count*(): int {.hot.} = stats.count

proc report*(): string {.hot.} =
  Version & " ring=" & $(ring.next.next == ring)

proc wrapUp() {.beforeHotReload.} =
  echo "beforeHotReload ", Version, " count=", stats.count

proc fixUp() {.afterHotReload.} =
  echo "afterHotReload ", Version, " count=", stats.count
