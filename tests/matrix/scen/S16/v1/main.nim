import std/os
import hotreload
import ./game
let reloader = newReloader()
var reloads = 0
var pending = 3
reloader.afterReload = proc () =
  inc reloads
  pending = 3
echo "START"
while true:
  reloader.update()
  if pending > 0:
    dec pending
    bench("after " & $reloads & " reloads")
  sleep(50)
