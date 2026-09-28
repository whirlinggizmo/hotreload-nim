# hotreload-nim

[![Linux](https://github.com/whirlinggizmo/hotreload-nim/actions/workflows/linux.yml/badge.svg)](https://github.com/whirlinggizmo/hotreload-nim/actions/workflows/linux.yml) [![Windows](https://github.com/whirlinggizmo/hotreload-nim/actions/workflows/windows.yml/badge.svg)](https://github.com/whirlinggizmo/hotreload-nim/actions/workflows/windows.yml) [![macOS](https://github.com/whirlinggizmo/hotreload-nim/actions/workflows/macos.yml/badge.svg)](https://github.com/whirlinggizmo/hotreload-nim/actions/workflows/macos.yml)

Hot reload for Nim programs. While your program runs, you can edit its code and save, and
the code is rebuilt in the background and swapped in without restarting and without
losing its state. Debug, release and web builds compile the same code in, with no
reloading and no cost.

## Requirements

- **Nim 2.2+**
- **gcc** (Linux), **MinGW's gcc** (Windows; choosenim installs it), or **clang** (macOS;
  the Xcode command line tools)
- **Linux**, **Windows** or **macOS**. Note that macOS is only tested by CI so far.

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
hotreload: building hello.nim (hello.nim changed)
hello: reloaded
hotreload: reloaded hello.nim (libhello_1.so; .dll on Windows, .dylib on macOS)
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

The **reloaded modules** are the modules with something hot in them (a `{.hot.}` global
or proc, or a reload hook), like `src/game.nim` here, and everything those modules
import. You don't have to tell the reloader which they are, because the pragmas do.
Whenever one of their sources changes, the hot build rebuilds all of them as one shared
library and swaps it in.

Note that a module with nothing hot in it, which only your main module imports, is
compiled into the executable with the main module, and changes to it require a restart
too. That's true of a module your main module calls, as well: give the procs it calls
`{.hot.}` (see below), and it's reloaded.

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

A hot build is an ordinary `nim c` with two defines:

```bash
nim c -r -d:hotReload -d:useMalloc src/main.nim
```

`-d:hotReload` turns hot reloading on. `-d:useMalloc` is needed because the executable
and its libraries share one heap. If you leave it out, hotreload stops the build and says
so. hotreload sets everything else itself: the executable's link flags, and the whole
command line of each library build.

Without `-d:hotReload`, it's one ordinary executable with no reloading. That's your debug
and release builds, unchanged:

```bash
nim c -r src/main.nim             # debug: breakpoints don't go stale
nim c -r -d:release src/main.nim  # release
```

Want `nim hot` to do it? Add a task to your `config.nims`:

```nim
# config.nims
task hot, "Build and run with hot reload":
  exec "nim c -r -d:hotReload -d:useMalloc --nimcache:build/hot --out:out/hot/game src/main.nim"
```

`--nimcache` gives the hot build its own Nim cache, so it doesn't share one with your
debug build or with another program's `main.nim`. The libraries go to
`build/<platform>/hot/library/` in the directory above the main module's (your project,
when it's `src/main.nim`). To put them somewhere else, add `-d:hotReloadBuildDir=<dir>`.

Each library is built with `nim c` from a small module the reloader writes there, which
imports the reloaded modules. As such, a library build reads the `config.nims` files in
your project's directory and above it, like your program's build does, but not one next
to your main module in `src/`. Put your `config.nims` in your project's directory. Note
also that defines you pass only on the command line don't reach the libraries. Put the
defines both builds need in your `config.nims`. A library build has `-d:hotReloadLibrary`, if you need to tell it apart:

```nim
# config.nims
when defined(hotReloadLibrary):
  switch("define", "engineDeclarationsOnly")   # the engine comes from the executable
```

## How it works

Everything happens in `reloader.update()`; there's no watcher thread. A few times a
second, `update()` checks the sources in the reloaded modules' directories and below them
(except the main module) for changes. Once they've changed and then stopped changing, it
starts a build of the reloaded modules as one shared library (`-d:hotReloadLibrary`) in
the background, and returns. The old code keeps running in the meantime, and any
compiler errors go to the terminal.

The first `update()` after the build finishes swaps the new library in. It loads the
library, runs the hooks, and points the main module's calls at the new code. As such, a
swap only ever happens where the main module calls `update()`, never in the middle of a
frame. If you change a file during a build, another build starts when that one is done.

Each reload is a new library (`libgame_1.so`, `libgame_2.so`, ...; `.dll` on Windows,
`.dylib` on macOS), and it replaces the last one completely.

The executable keeps the hot globals, so the new code gets the same ones. When a reload
changes a hot global's type, whatever still fits is carried over field by field, by name.
That works for objects, tuples, seqs, arrays and refs. Refs are copied as a graph, so
shared objects stay shared and cycles stay cycles.

A replaced library stays loaded, so a callback that its code handed out keeps working.
Note that the callback still runs the code it came from, not the new code.

## Limits

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
tests/                   `nimble test`: the modules' tests, and treload.nim, a smoke test
                         that builds tests/reload/ hot, runs it and edits it while it runs
examples/hello/          a console program: src/main.nim, its main module, and
                         src/hello.nim, which is reloaded
```

## License

MIT. See [LICENSE](LICENSE).
