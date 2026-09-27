# hotreload-nim

Hot reload for Nim programs: while the program runs, edit its code and save, and the code
is rebuilt in the background and swapped in, without restarting and without losing its
state. Debug, release and web builds compile the same code in, with no reloading and no
cost.

Linux only, for now.

```
hotreload.nimble         the package: srcDir src, `import hotreload`
src/hotreload.nim        {.hot.} globals and procs, the reload hooks, the Reloader
src/hotreload/
  reload.nim             {.hot.}, and the reloader: watch, rebuild, swap
  hotglobals.nim         hot globals: kept across reloads, carried across type changes
  hotprocs.nim           hot procs, and the {.beforeHotReload.} / {.afterHotReload.} hooks
  migrate.nim            carrying a value from one build's type to another's
  typesig.nim            a type's shape, to tell when it changed
  tasks.nims             the build variants and their tasks, for a program's config.nims
tests/                   `nimble test`: the modules' tests, and treload.nim, a smoke test
                         that builds tests/reload/ hot, runs it and edits it while it runs
examples/hello/          a console program: src/main.nim, the program, and src/hello.nim,
                         the code it reloads
```

## Trying it

```
cd examples/hello
nim hot
```

It greets you a few times a second. Open `src/hello.nim`, change the greeting, save, and
the next greeting is the new one:

```
Hello, world! (ticks: 12, since the last reload: 12)
hotreload: building hello.nim
hello: reloaded
hotreload: reloaded hello.nim (libhello_1.so)
Howdy, world! (ticks: 20, since the last reload: 2)
```

`ticks` is a hot global, so it counts on through the reload; `sinceReload` is a plain
one, so it starts over.

## Using it

A program that hot reloads is two parts. The **program** is its main module: it sets
things up, runs the loop, and calls into the **code**, a module it imports. Only the code
is reloaded. hello's program:

```nim
# src/main.nim
import std/os
import hotreload
import ./hello

let reloader = newReloader()

onStart()
while true:
  reloader.update()   # rebuilds hello.nim and swaps it in when it changed
  onTick()
  sleep(250)
```

and its code:

```nim
# src/hello.nim
import hotreload

var name {.hot.} = "world"   # kept across reloads
var ticks {.hot.} = 0        # kept: it counts on through each reload
var sinceReload = 0          # a plain global: starts over with each reload

proc onStart*() {.hot.} =
  echo "hello: running"

proc sayReloaded() {.afterHotReload.} =
  echo "hello: reloaded"

proc onTick*() {.hot.} =
  inc ticks
  inc sinceReload
  if ticks mod 4 == 0:
    echo "Hello, ", name, "! (ticks: ", ticks, ", since the last reload: ", sinceReload, ")"
```

Three pragmas, all in the code:

- **`{.hot.}` on a global** keeps it across reloads. When a reload changes its type, what
  still fits is carried over and the rest starts from its default. Its first value is
  used once, when it's made: to change a kept value, assign it.
- **`{.hot.}` on a proc** marks one the program calls. The program is compiled once, so
  its calls would otherwise reach the version it was built with; these follow each
  reload. Only the procs the program calls need it: everything else in the code is
  reloaded anyway.
- **`{.beforeHotReload.}` and `{.afterHotReload.}`** mark the code's own reload hooks,
  which the reloader calls: before a reload on the old code, after one on the new. No
  parameters, and at most one of each per module.

The program's names for its calls (`onStart`, `onTick`) are its own: hotreload calls
none of them. It calls only the hooks, and `reloader.beforeReload` and
`reloader.afterReload`, if the program sets them, for its own business around a reload.

### The build

In the program's `config.nims` (the path has to be a literal):

```nim
import "../../src/hotreload/tasks.nims"

let target = BuildTarget(dir: thisDir(), name: "hello")  # src/main.nim, src/hello.nim
hotReloadConfig(target)
hotReloadTasks(target)
```

That gives `nim build hot|debug|release|all`, `nim hot`, `nim debug`, `nim release` and
`nim clean`. `nim hot` runs the hot build; the others compile the code in.

## How it works

The hot build (`-d:hotReload`) watches the code's sources. When one changes, it rebuilds
the code (the code module and every module it imports, whichever changed) as one shared
library (`-d:hotReloadLibrary`), loads it, and points the program's calls at the new
code. Each reload is a new library (`libhello_1.so`, `libhello_2.so`, ...), replacing the
last one whole.

The program keeps the hot globals, so the new code gets the same ones. When a reload
changes a hot global's type, what still fits is carried over, field by field, by name.
That covers objects, tuples, seqs, arrays, and refs, which are copied as a graph: shared
stays shared, and cycles stay cycles.

A replaced library stays loaded, so a callback its code handed out keeps working, running
the code it came from.

## Limits

- Linux (it relies on `RTLD_DEEPBIND` and `-rdynamic`).
- A change to the parameters or result of a proc the program calls can't be swapped in:
  the reload is refused, with a message, and the old code runs on until a restart. So
  does adding or renaming one.
- A change to the program's main module needs a restart.
- Hot globals can't hold pointers, closures, or refs to objects that inherit.
- Old libraries, and the old copies of hot globals whose type changed, aren't freed.
- Breakpoints go stale after a reload shifts lines; the debug build doesn't reload.

## License

MIT: see [LICENSE](LICENSE).
