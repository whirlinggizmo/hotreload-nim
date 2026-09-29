import std/os
import hotreload
import ./game
let reloader = newReloader()
echo "START"
var i = 0
while true:
  reloader.update()
  if i mod 5 == 0: step(i)
  inc i
  sleep(50)
