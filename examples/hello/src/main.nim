## hotreload's hello: the main module, never reloaded. It calls hello.nim a few times a
## second; run it with `nim hot`, edit hello.nim, save, and the next calls are the new
## code.
## Ctrl-C to stop.

import std/os
import hotreload
import ./hello

let reloader = newReloader("hello.nim")

onStart()
while true:
  reloader.update()   # pumps the file watcher, library builder, and reloader
  onTick()
  sleep(250)
