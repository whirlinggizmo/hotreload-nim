# hotreload-nim

Hot reload for Nim programs: while the program runs, edit its code and save, and the code
is rebuilt in the background and swapped in, without restarting and without losing its
state. Debug, release and web builds compile the same code in, with no reloading and no
cost.

Linux and Windows (with MinGW, the gcc that choosenim installs); not macOS yet.

## A program that hot reloads

It's two parts. The **program** is its main module: it sets things up, runs the loop,
and calls into the **code**, a module it imports (with everything that imports). Only
the code is reloaded; a change to the program takes a restart.

```nim
# src/main.nim: the program
import hotreload
import ./game

let reloader = newReloader()

onStart()
while running():
  reloader.update()   # rebuilds the code and swaps it in when a source changed
  onFrame()           # the latest onFrame
```

```nim
# src/game.nim: the code
import hotreload

var score {.hot.} = 0            # kept across reloads
var player {.hot.}: Player       # kept too, even when Player's fields change

proc onStart*() {.hot.} = ...    # a proc the program calls
proc onFrame*() {.hot.} = ...

proc fixUp() {.afterHotReload.} = ...   # runs after each reload, on the new code
```

Three pragmas, all in the code:

- **`{.hot.}` on a global** keeps it across reloads. When a reload changes its type, what
  still fits is carried over and the rest starts from the first value. That first value
  is used once, when it's made: to change a kept value, assign it.
- **`{.hot.}` on a proc** marks one the program calls. The program is compiled once, so
  its calls would otherwise reach the version it was built with; these follow each
  reload. Only the procs the program calls need it: everything else in the code is
  reloaded anyway.
- **`{.beforeHotReload.}` and `{.afterHotReload.}`** mark the code's own reload hooks,
  which the reloader calls: before a reload on the old code, after one on the new. No
  parameters, and at most one of each per module.

The program's names for its calls (`onStart`, `onFrame`) are its own: hotreload calls
none of them. It calls only the hooks, and `reloader.beforeReload` and
`reloader.afterReload`, if the program sets them, for its own business around a reload.

## The build

hotreload's `tasks.nims` sets up the builds, from the program's `config.nims`. A
`config.nims` can't import a package nimble installed by its name (it's read before
nimble's paths are added), so it asks nimble where hotreload is:

```nim
# config.nims
import std/[macros, strutils]
macro importHotreloadTasks(): untyped =
  let dir = staticExec("nimble path hotreload").strip
  newTree(nnkImportStmt, newLit(dir & "/hotreload/tasks.nims"))
importHotreloadTasks()

let target = BuildTarget(dir: thisDir(), name: "game")
hotReloadConfig(target)   # the switches: before the program's own
hotReloadTasks(target)    # the tasks
```

(With a copy of hotreload at a known place, `import "<path>/src/hotreload/tasks.nims"`
does the same.)

`BuildTarget` names the program. Its main module is `src/main.nim` and its code
`src/<name>.nim`, unless `main` and `code` say otherwise, as paths from `dir`.

That gives three builds of the program:

| Build     | What it is                                                         |
|-----------|--------------------------------------------------------------------|
| `hot`     | a debug build that rebuilds the code while it runs, and reloads it |
| `debug`   | the code compiled in: no reloading, and breakpoints don't go stale |
| `release` | the code compiled in, `-d:release`                                 |

`nim hot`, `nim debug` and `nim release` build one and run it; `nim build
hot|debug|release|all` only builds, and `nim clean` removes what they made. Each build
goes to `out/<platform>/<build>/<name>`, with its Nim cache in `build/<platform>/<build>/`.
The hot build's libraries go in `build/<platform>/hot/library/`.

## Trying it

`examples/hello` is a console program that hot reloads: `src/main.nim` is the program,
`src/hello.nim` the code.

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
hotreload: reloaded hello.nim (libhello_1.so, or .dll on Windows)
Howdy, world! (ticks: 20, since the last reload: 2)
```

`ticks` is a hot global, so it counts on through the reload; `sinceReload` is a plain
one, so it starts over.

## How it works

The hot build (`-d:hotReload`) watches the code's sources. When one changes, it rebuilds
the code (the code module and every module it imports, whichever changed) as one shared
library (`-d:hotReloadLibrary`), loads it, and points the program's calls at the new
code. Each reload is a new library (`libgame_1.so`, `libgame_2.so`, ...; `.dll` on
Windows), replacing the last one whole.

The program keeps the hot globals, so the new code gets the same ones. When a reload
changes a hot global's type, what still fits is carried over, field by field, by name.
That covers objects, tuples, seqs, arrays, and refs, which are copied as a graph: shared
stays shared, and cycles stay cycles.

A replaced library stays loaded, so a callback its code handed out keeps working, running
the code it came from.

## Limits

- No macOS yet. On Windows, MinGW's gcc only, not MSVC: the code links against the hot
  program's import library, which MinGW's linker makes (`--out-implib`).
- A change to the parameters or result of a proc the program calls can't be swapped in:
  the reload is refused, with a message, and the old code runs on until a restart. So
  does adding or renaming one.
- A change to the program's main module needs a restart.
- Hot globals can't hold pointers, closures, or refs to objects that inherit.
- Old libraries, and the old copies of hot globals whose type changed, aren't freed.
- Breakpoints go stale after a reload shifts lines; the debug build doesn't reload.

## The repo

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

## License

MIT: see [LICENSE](LICENSE).
