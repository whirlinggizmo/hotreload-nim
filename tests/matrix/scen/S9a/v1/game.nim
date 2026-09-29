import hotreload
var k = 1
var cb {.hot.}: proc (): string {.closure.} = proc (): string = "closure v1 " & $k
proc tick*() {.hot.} =
  echo "S9a ", cb()
