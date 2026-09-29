import std/os
import hotreload
import ./game

let reloader = newReloader()
var reloads = 0
var cbs: seq[(string, proc (): string)]
cbs.add ("made at start (exe code)", makeCallback())
reloader.afterReload = proc () =
  inc reloads
  echo "main: afterReload #", reloads, " hotMoves=", hotMoves()
  if reloads == 1: cbs.add ("made after reload 1", makeCallback())
echo "START"
var i = 0
var called = false
while true:
  reloader.update()
  if reloads == 2 and not called:
    called = true
    for (label, cb) in cbs:
      echo "main: calling cb ", label, " -> ", cb()
  if i mod 5 == 0: tick()
  inc i
  sleep(50)
