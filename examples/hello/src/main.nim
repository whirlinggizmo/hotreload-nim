## hotreload's hello: the program. It calls the code (hello.nim) a few times a second;
## run it with `nim hot`, edit hello.nim, save, and the next calls are the new code.
## Ctrl-C to stop.

import std/os
import hotreload
import ./hello

let reloader = newReloader()

onStart()
while true:
  reloader.update()   # rebuilds hello.nim and swaps it in when it changed
  onTick()
  sleep(250)
