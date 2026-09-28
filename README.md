# hotreload-nim

Hot reload for Nim programs: while the program runs, edit its code and save, and the code
is rebuilt in the background and swapped in, without restarting and without losing its
state. Debug, release and web builds compile the same code in, with no reloading and no
cost.

Linux and Windows (with MinGW, the gcc that choosenim installs); not macOS yet.

## A program that hot reloads

The **main module** (`src/main.nim`) is compiled into the executable and is never
reloaded: a change to it requires a restart. It creates the reloader, which has to be
made there, and calls `reloader.update()` in its loop, which is what drives each reload.

The rest of the program, the module the main module imports (`src/game.nim` here) and
everything that imports, is reloaded: the hot build starts with it compiled in, and
whenever one of its sources changes, rebuilds all of it as one shared library and swaps
that in. (A module only the main module imports stays in the executable, like the main
module.)

```nim
# src/main.nim: the main module, never reloaded
import hotreload
import ./game

let reloader = newReloader()

game.onStart()
while running():
  reloader.update()   # pumps the file watcher, library builder, and reloader
  game.onFrame()      # the newest onFrame, after a reload too
```

```nim
# src/game.nim, and what it imports: reloaded
import hotreload

var score {.hot.} = 0            # kept across reloads
var player {.hot.}: Player       # kept too, even when Player's fields change

proc onStart*() = ...            # called once, before any reload: an ordinary proc
proc onFrame*() {.hot.} = ...    # called on every frame: the newest version

proc fixUp() {.afterHotReload.} = ...   # runs after each reload, on the new code
```

Three pragmas, used in the reloaded modules:

- **`{.hot.}` on a global** keeps it across reloads: the executable holds it, and each
  new library is handed the same one. When a reload changes its type, what still fits is
  carried over and the rest starts from the first value. That first value is used once,
  when it's made: to change a kept value, assign it. A global without it starts over
  with each reload.
- **`{.hot.}` on a proc** marks one the main module calls after a reload. The main
  module is compiled once, so its calls would otherwise reach the version it was built
  with; these follow each reload to the newest version. A proc it calls only before any
  reload (a start-up proc) doesn't need it, and a proc only the library calls doesn't
  either: calls within the library are all to the new code anyway.
- **`{.beforeHotReload.}` and `{.afterHotReload.}`** mark reload hooks, which the reloader
  calls: before a reload on the old code, after one on the new. No parameters, and at
  most one of each per module.

The names of the procs the main module calls (`onStart`, `onFrame`) are its own:
hotreload calls none of them. It calls only the hooks, and `reloader.beforeReload` and
`reloader.afterReload`, if the main module sets them, for its own business around a
reload.

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

`BuildTarget` names the program. Its main module is `src/main.nim`, and the module
that's reloaded (with what it imports) `src/<name>.nim`, unless `main` and `code` say
otherwise, as paths from `dir`.

That gives three builds of the program:

| Build     | What it is                                                               |
|-----------|--------------------------------------------------------------------------|
| `hot`     | a debug build that rebuilds the library while it runs, and reloads it    |
| `debug`   | one executable, no library: no reloading, and breakpoints don't go stale |
| `release` | one executable, no library, `-d:release`                                 |

`nim hot`, `nim debug` and `nim release` build one and run it; `nim build
hot|debug|release|all` only builds, and `nim clean` removes what they made. Each build
goes to `out/<platform>/<build>/<name>`, with its Nim cache in `build/<platform>/<build>/`.
The hot build's libraries go in `build/<platform>/hot/library/`.

## Trying it

`examples/hello` is a console program that hot reloads: `src/main.nim` is its main
module, and `src/hello.nim` is reloaded.

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

It all happens in `reloader.update()`. A few times a second it checks the sources beside
the reloaded module and below it (all but the main module) for changes; there's no
watcher thread. When one has changed, it starts a build of the reloaded module and
everything it imports as one shared library (`-d:hotReloadLibrary`), in the background,
and returns: the old code runs on meanwhile, and the compiler's errors go to the
terminal. The first `update()` after the build is done swaps it in: it loads the
library, runs the hooks, and points the main module's calls at the new code. So a swap
only ever happens where the main module calls `update()`, never in the middle of a
frame. A change made during a build starts another when it's done.

Each reload is a new library (`libgame_1.so`, `libgame_2.so`, ...; `.dll` on Windows),
replacing the last one whole.

The executable keeps the hot globals, so the new code gets the same ones. When a reload
changes a hot global's type, what still fits is carried over, field by field, by name.
That covers objects, tuples, seqs, arrays, and refs, which are copied as a graph: shared
stays shared, and cycles stay cycles.

A replaced library stays loaded, so a callback its code handed out keeps working, running
the code it came from.

## Limits

- No macOS yet. On Windows, MinGW's gcc only, not MSVC: the library links against the
  hot executable's import library, which MinGW's linker makes (`--out-implib`).
- A change to the parameters or result of a proc the main module calls can't be swapped
  in: the reload is refused, with a message, and the old code runs on until a restart.
  So does adding or renaming one.
- A change to the main module requires a restart.
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
examples/hello/          a console program: src/main.nim, its main module, and
                         src/hello.nim, which is reloaded
```

## License

MIT: see [LICENSE](LICENSE).
