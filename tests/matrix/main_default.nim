import std/os
import hotreload
import ./game

let reloader = newReloader()
var reloads = 0
reloader.afterReload = proc () =
  inc reloads
  echo "main: afterReload #", reloads, " hotMoves=", hotMoves()
echo "START"
var i = 0
while true:
  reloader.update()
  if i mod 5 == 0: tick()
  inc i
  sleep(50)
