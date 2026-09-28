# hotreload-nim

Hot reload for Nim programs. While your program runs, you can edit its code and save, and
the code is rebuilt in the background and swapped in without restarting and without
losing its state. Debug, release and web builds compile the same code in, with no
reloading and no cost.

## Requirements

- **Nim 2.2+**
- **gcc** (Linux), or **MinGW's gcc** (Windows; choosenim installs it)
- **Linux** or **Windows**. macOS isn't supported yet.

## Install

```bash
nimble install https://github.com/whirlinggizmo/hotreload-nim
```

hotreload isn't in nimble's package list yet, so you install it from GitHub.

## Trying it

`examples/hello` is a small console program that hot reloads. From a clone of this repo:

```bash
cd examples/hello
nim hot
```

It prints a greeting a few times a second. Open `src/hello.nim`, change the greeting and
save, and the next greeting is the new one:

```
Hello, world! (ticks: 12, since the last reload: 12)
hotreload: building hello.nim
hello: reloaded
hotreload: reloaded hello.nim (libhello_1.so, or .dll on Windows)
Howdy, world! (ticks: 20, since the last reload: 2)
```

`ticks` is a hot global, so it keeps counting through the reload. `sinceReload` is a
plain global, so it starts over.

## Usage

A program that hot reloads has two parts.

The **main module** (`src/main.nim`) is compiled into the executable and is never
reloaded. If you change it, you have to restart the program. It creates the reloader and
calls `reloader.update()` in its loop:

```nim
# src/main.nim
import hotreload
import ./game

let reloader = newReloader()   # must be created in the main module

game.init()
while running():
  reloader.update()   # pumps the file watcher, library builder, and reloader
  game.tick()
```

The **reloaded modules** are everything else: the module your main module imports
(`src/game.nim` here), and everything that module imports. Whenever one of their sources
changes, the hot build rebuilds all of them as one shared library and swaps it in. Note
that a module only the main module imports stays in the executable.

hotreload's pragmas are for the reloaded modules only. Using them in the main module is a
compile error because the main module is never hot reloaded.

### Keeping state across reloads

```nim
# src/game.nim
import hotreload

var score {.hot.} = 0
var enemies {.hot.}: seq[Enemy]
```

A `{.hot.}` global keeps its value across reloads. A plain global starts over with each
reload.

Changed a hot global's type? Whatever still fits is carried over, by field name:

```nim
type Enemy = object
  hp: int              # kept
  shield: int = 10     # new: starts at 10
```

Note that the first value (`= 0` above) is only used once, when the global is created. If
you want to change a kept value, assign it.

### Calling the newest code from the main module

```nim
# src/game.nim
proc tick*() {.hot.} = ...

# src/main.nim
game.tick()   # after a reload, this calls the new tick
```

The main module is compiled once, so without `{.hot.}` its calls would keep going to the
version it was built with. You don't need `{.hot.}` on a proc the main module only calls
before any reload (like `init`), or on a proc only the reloaded modules call.

### Doing something around a reload

```nim
# src/game.nim
proc saveScratch() {.beforeHotReload.} = ...    # on the old code, just before a reload
proc rebuildCaches() {.afterHotReload.} = ...   # on the new code, just after
```

These hooks are optional. They take no parameters, and you can have at most one of each
per module.

Want to know about reloads in the main module?

```nim
# src/main.nim
reloader.beforeReload = proc () = echo "reloading"
reloader.afterReload = proc () = echo "reloaded"
```

## Building

hotreload's `tasks.nims` sets up the builds and adds build tasks, from your program's
`config.nims`. A `config.nims` can't import an installed nimble package by name, because
it's read before nimble's paths are added. As such, it asks nimble where hotreload is:

```nim
# config.nims
import std/[macros, strutils]
macro importHotreloadTasks(): untyped =
  let dir = staticExec("nimble path hotreload").strip
  newTree(nnkImportStmt, newLit(dir & "/hotreload/tasks.nims"))
importHotreloadTasks()

let target = BuildTarget(dir: thisDir(), name: "game")
hotReloadConfig(target)   # the build switches; your own switches go after this
hotReloadTasks(target)    # the build tasks
```

If you have a copy of hotreload somewhere else, `import "<path>/src/hotreload/tasks.nims"`
does the same thing.

`BuildTarget` describes your program. By default, its main module is `src/main.nim` and
its reloaded module is `src/<name>.nim`. You can set `main` and `code` (paths from `dir`)
to use others.

That gives you three builds:

| Build     | What it is                                                               |
|-----------|--------------------------------------------------------------------------|
| `hot`     | a debug build that rebuilds the library while it runs, and reloads it    |
| `debug`   | one executable, no library: no reloading, and breakpoints don't go stale |
| `release` | one executable, no library, `-d:release`                                 |

- `nim hot`, `nim debug` and `nim release` build one and run it.
- `nim build hot|debug|release|all` only builds.
- `nim clean` removes everything the builds made.

Each build goes to `out/<platform>/<build>/<name>`, and its Nim cache to
`build/<platform>/<build>/`. The hot build's libraries go to `build/<platform>/hot/library/`.

## How it works

Everything happens in `reloader.update()`; there's no watcher thread. A few times a
second, `update()` checks the sources in the reloaded module's directory and below it
(except the main module) for changes. When one has changed, it starts a build of the
reloaded modules as one shared library (`-d:hotReloadLibrary`) in the background, and
returns. The old code keeps running in the meantime, and any compiler errors go to the
terminal.

The first `update()` after the build finishes swaps the new library in. It loads the
library, runs the hooks, and points the main module's calls at the new code. As such, a
swap only ever happens where the main module calls `update()`, never in the middle of a
frame. If you change a file during a build, another build starts when that one is done.

Each reload is a new library (`libgame_1.so`, `libgame_2.so`, ...; `.dll` on Windows),
and it replaces the last one completely.

The executable keeps the hot globals, so the new code gets the same ones. When a reload
changes a hot global's type, whatever still fits is carried over field by field, by name.
That works for objects, tuples, seqs, arrays and refs. Refs are copied as a graph, so
shared objects stay shared and cycles stay cycles.

A replaced library stays loaded, so a callback that its code handed out keeps working.
Note that the callback still runs the code it came from, not the new code.

## Limits

- macOS isn't supported yet.
- On Windows, only MinGW's gcc works, not MSVC. The library links against the hot
  executable's import library, which MinGW's linker makes (`--out-implib`).
- If you change the parameters or result of a proc the main module calls, the reload is
  refused with a message, and the old code keeps running until you restart. The same
  goes for adding or renaming one.
- If you change the main module, you have to restart.
- Hot globals can't hold pointers, closures, or refs to objects that inherit.
- Old libraries, and the old copies of hot globals whose type changed, aren't freed.
- Breakpoints go stale after a reload shifts lines. The debug build doesn't reload, so
  use it when you need reliable breakpoints.

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

MIT. See [LICENSE](LICENSE).
