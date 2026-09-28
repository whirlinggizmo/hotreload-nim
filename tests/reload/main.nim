## The smoke test's main module (treload.nim builds and runs a copy): calls code.nim every
## few milliseconds and prints what it reports when that changes, until a file named
## `quit` appears (or, should the test die first, five minutes pass).

import std/[os, times]
import hotreload
import ./code

let reloader = newReloader("code.nim")
reloader.beforeReload = proc () = echo "beforeReload count=", count()
reloader.afterReload = proc () = echo "afterReload count=", count()

let start = epochTime()
var last = ""
while epochTime() - start < 300 and not fileExists("quit"):
  reloader.update()
  tick()
  let now = report()
  if now != last:
    echo "report: ", now
    last = now
  sleep(10)
