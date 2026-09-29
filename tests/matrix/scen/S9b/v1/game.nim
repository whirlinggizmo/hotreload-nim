import hotreload
proc hello(): string {.nimcall.} = "nimcall v1"
var cb {.hot.}: proc (): string {.nimcall.} = hello
proc tick*() {.hot.} =
  echo "S9b ", cb()
