## hotreload's hello: the code, which `nim hot` reloads. Edit it while it runs (the
## greeting, the name, how often it speaks) and save.

import hotreload

var name {.hot.} = "world"   # kept across reloads. Its first value is used once, when
                             # it's made: an edit here changes nothing while it runs;
                             # to change it, assign it (in sayReloaded, say)
var ticks {.hot.} = 0        # kept: it counts on through each reload
var sinceReload = 0          # a plain global: starts over with each reload

proc onStart*() {.hot.} =
  when defined(hotReload):
    echo "hello: running. Edit src/hello.nim and save; Ctrl-C to stop."
  else:
    echo "hello: running (no hot reload in this build: `nim hot` for that). Ctrl-C to stop."

proc sayReloaded() {.afterHotReload.} =
  echo "hello: reloaded"

proc onTick*() {.hot.} =
  inc ticks
  inc sinceReload
  if ticks mod 4 == 0:
    echo "Hello, ", name, "! (ticks: ", ticks, ", since the last reload: ", sinceReload, ")"
