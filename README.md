# hotreload-nim

[![Linux](https://github.com/whirlinggizmo/hotreload-nim/actions/workflows/linux.yml/badge.svg)](https://github.com/whirlinggizmo/hotreload-nim/actions/workflows/linux.yml) [![Windows](https://github.com/whirlinggizmo/hotreload-nim/actions/workflows/windows.yml/badge.svg)](https://github.com/whirlinggizmo/hotreload-nim/actions/workflows/windows.yml) [![macOS](https://github.com/whirlinggizmo/hotreload-nim/actions/workflows/macos.yml/badge.svg)](https://github.com/whirlinggizmo/hotreload-nim/actions/workflows/macos.yml)

Hot reload for Nim applications. hotreload rebuilds a running application's code when you
save a change, in the background, and swaps the new code in without stopping the
application and without losing its state. It is for applications with a loop, such as a
game or a tool with a window, where a restart would cost you the window, the loaded
assets and where you were. Debug, release and web builds compile the same code in, with
no reloading and no cost.

## Requirements

- **Nim 2.2+**
- **gcc** on Linux, **MinGW's gcc** on Windows (choosenim installs it), or **clang** on
  macOS (the Xcode command line tools)
- **Linux**, **Windows** or **macOS**. Note that macOS is only tested by CI so far.

## Install

```bash
nimble install https://github.com/whirlinggizmo/hotreload-nim
```

hotreload isn't in nimble's package list yet, so it is installed from GitHub. A project
that lists its dependencies in a `.nimble` file requires it the same way:

```nim
requires "https://github.com/whirlinggizmo/hotreload-nim >= 0.1.1"
```

Note that nimble keeps the copy of hotreload it fetched first, even after a newer version
is tagged. A newer version is fetched by deleting nimble's cached copies and the
installed one, then installing again:

```bash
rm -rf ~/.nimble/pkgcache/githubcom_whirlinggizmohotreloadnim*
rm -rf nimbledeps/pkgs2/hotreload-*   # or ~/.nimble/pkgs2/hotreload-*, for a global install
nimble install -y --depsOnly
```

## An application that hot reloads

An application that hot reloads has two parts: a main module, which is compiled into the
executable and never reloaded, and the modules it calls into, which are reloaded.

The main module creates the reloader and calls `reloader.update()` in its loop:

```nim
# src/main.nim
import hotreload
import ./game

let reloader = newReloader()   # must be created in the main module

game.init()
while true:
  reloader.update()   # pumps the file watcher, library builder, and reloader
  game.tick()
```

The reloaded modules mark what a reload has to know about. A `{.hot.}` global is kept
across reloads, and a `{.hot.}` proc is one the main module calls, so that its calls
reach the new code:

```nim
# src/game.nim
import hotreload

var score {.hot.} = 0

proc init*() = ...
proc tick*() {.hot.} = ...
```

A hot build is an ordinary `nim c` with two defines:

```bash
nim c -r -d:hotReload -d:useMalloc --out:out/hot/game src/main.nim
```

While it runs, every change you save to `src/game.nim`, or to anything it imports, is
built as a shared library in the background and swapped in at the next `update()`. `score`
keeps its value, and the main module's `game.tick()` calls the new `tick`.

The reloaded modules are found from the pragmas: every module with a `{.hot.}` global or
proc, or a reload hook, in it, and everything those modules import. Note that a module
with nothing hot in it, which only the main module imports, is compiled into the
executable with the main module, and a change to it requires a restart, as a change to
the main module does.

## Trying it

`examples/hello` is a small console application that hot reloads. From a clone of this
repo:

```bash
cd examples/hello
nim hot
```

It prints a greeting a few times a second. Open `src/hello.nim`, change the greeting and
save, and the next greeting is the new one:

```
Hello, world! (ticks: 12, since the last reload: 12)
hotreload: building (hello.nim changed)
Hello, world! (ticks: 16, since the last reload: 16)
hello: reloaded
hotreload: reloaded (libhello_1.so)
Howdy, world! (ticks: 20, since the last reload: 3)
```

`ticks` is a hot global, so it keeps counting through the reload. `sinceReload` is a
plain global, so it starts over.

## Usage

### State

A `{.hot.}` global keeps its value across reloads. A plain global starts over with each
reload:

```nim
var score {.hot.} = 0
var enemies {.hot.}: seq[Enemy]
var frameCount = 0   # starts over
```

The first value (`= 0` above) is only used once, when the global is created. As such, an
edit to the first value changes nothing while the application runs. A kept value is
changed by assigning it, in an `{.afterHotReload.}` hook, say:

```nim
proc reset() {.afterHotReload.} =
  score = 0
```

When a reload changes a hot global's type, whatever still fits is carried over, by field
name, and the rest starts from its default:

```nim
type Enemy = object
  hp: int              # kept
  shield: int = 10     # new: starts at 10
```

That works for objects, tuples, seqs, arrays and refs. Refs are copied as a graph, so
shared objects stay shared and cycles stay cycles, within one hot global. Note that a hot
global can't hold pointers, closures, or refs to objects that inherit. See Limits for two
cases that don't carry over yet: refs shared between two hot globals, and enums.

### Procs the main module calls

The main module is compiled once, so a call from it reaches the version of the proc it
was built with, forever. A `{.hot.}` proc is called through the reloader instead, so a
call from the main module reaches the newest code:

```nim
# src/game.nim
proc tick*() {.hot.} = ...

# src/main.nim
game.tick()   # after a reload, this calls the new tick
```

Only the procs the main module calls after a reload could have happened need it. A proc
the main module only calls at the start (like `init`), or a proc only the reloaded
modules call, is an ordinary proc.

Note that a `{.hot.}` proc's parameters and result can't change while the application
runs. A reload that changes them is refused with a message, and the old code keeps
running until you restart. The same goes for adding a `{.hot.}` proc or renaming one.

### Doing something around a reload

A reloaded module can run something just before a reload, on the old code, and just
after, on the new code:

```nim
# src/game.nim
proc saveScratch() {.beforeHotReload.} = ...
proc rebuildCaches() {.afterHotReload.} = ...
```

These hooks are optional. They take no parameters, and each module can have at most one of
each.

The main module is told about reloads through the reloader's two callbacks, since the
pragmas are for the reloaded modules only:

```nim
# src/main.nim
reloader.beforeReload = proc () = echo "reloading"
reloader.afterReload = proc () = echo "reloaded"
```

A reload runs these in order: the old code's `{.beforeHotReload.}` hooks, the main
module's `beforeReload`, the swap, the new code's `{.afterHotReload.}` hooks, the main
module's `afterReload`.

### Callbacks that outlive a reload

A replaced library stays loaded, so a callback that its code handed out before a reload
(to an asset loader, say) still works when it fires. Note that it runs the code it came
from, not the new code, and that if a reload has moved a hot global to new storage since
the callback was made (its type changed, or it holds refs: those are copied on every
reload), what the callback writes there is lost.
`hotMoves()` counts those moves, so a callback can tell:

```nim
let moves = hotMoves()
loadAsset(path, proc (asset: Asset) =
  if hotMoves() == moves: sprite = asset   # still the same storage
  else: echo "a reload moved the hot globals: ask again")
```

### Building

`-d:hotReload` turns hot reloading on. `-d:useMalloc` is needed because the executable
and its libraries share one heap; without it, hotreload stops the build and says so.
Everything else, the executable's link flags and the whole command line of each library
build, is set by hotreload.

Without `-d:hotReload`, the same sources build one ordinary executable with no
reloading, which is your debug and release build:

```bash
nim c -r --out:out/debug/game src/main.nim                # debug: breakpoints don't go stale
nim c -r -d:release --out:out/release/game src/main.nim  # release
```

A `nim hot` task is a line in your project's `config.nims`:

```nim
# config.nims
task hot, "Build and run with hot reload":
  exec "nim c -r -d:hotReload -d:useMalloc --nimcache:build/hot --out:out/hot/game src/main.nim"
```

`--nimcache` gives the hot build its own Nim cache, so it doesn't share one with your
debug build or with another application's `main.nim`. The libraries go to
`build/<platform>/hot/library/` in your project's directory (the directory above the main
module's). They go somewhere else with `-d:hotReloadBuildDir=<dir>`.

Each library is built with its own `nim c`, from a small module the reloader writes in
the build directory, which imports the reloaded modules. A library build reads the
`config.nims` in your project's directory, and any above it, as your application's build
does, but not one beside your main module in `src/`. Note that defines you pass only on
the command line don't reach the libraries. A define both builds need goes in your
`config.nims`. A library build has `-d:hotReloadLibrary`, for a define only it needs:

```nim
# config.nims
when defined(hotReloadLibrary):
  switch("define", "engineDeclarationsOnly")   # the engine comes from the executable
```

## What happens on a reload

Everything happens in `reloader.update()`; there is no watcher thread. A few times a
second, `update()` checks the sources in the reloaded modules' directories and below them
(except the main module) for changes. Once they've changed and then stopped changing, it
starts a build of the reloaded modules as one shared library in the background, and
returns. The old code keeps running in the meantime, and any compiler errors go to the
terminal. A change during a build starts another build when that one is done.

The first `update()` after the build finishes swaps the new library in. It checks the hot
procs' signatures, runs the hooks, and points the main module's calls at the new code. As
such, a swap only ever happens where the main module calls `update()`, never in the
middle of a frame.

Each reload is a new library (`libgame_1.so`, `libgame_2.so`, ...; `.dll` on Windows,
`.dylib` on macOS), which replaces the last one completely. The executable keeps the hot
globals, so each library gets the same ones. Each library has its own Nim runtime, so a
hot global that holds refs is copied for the new library on every reload.

## Limits

- On Windows, only MinGW's gcc works, not MSVC. The library links against the hot
  executable's import library, which MinGW's linker makes.
- Old libraries, and the old copies of hot globals whose type changed, aren't freed.
- Breakpoints go stale after a reload shifts lines. The debug build doesn't reload, so
  use it when you need reliable breakpoints.
- A change to the main module, to a module only it imports, or to a `{.hot.}` proc's
  signature, requires a restart.
- An enum in a hot global is carried by its ordinal, not its name, so a member inserted
  anywhere but the end changes what a kept value means. Add enum members at the end.
- Refs shared between two hot globals become separate copies after a reload (each global
  is copied as its own graph). Keep what's shared inside one hot global, a tuple or an
  object, until that's fixed.
- A type change's message always says "carried over what still fits", even when the value
  started over from its first value.
- In the default hot build (`-Og`, `--debugger:native`), reloaded code can run slower than
  the same code before the first reload, since the library is compiled `-fPIC`. A
  `-d:release` hot build runs the same.

[docs/comparison.md](docs/comparison.md) compares hotreload-nim with its Haxe side,
hotreload-hx: reload times, the speed of reloaded code, and what each can and can't do.

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
docs/comparison.md       hotreload-nim and hotreload-hx, measured side by side
tests/                   `nimble test`: the modules' tests, and treload.nim, a smoke test
                         that builds tests/reload/ hot, runs it and edits it while it runs
tests/matrix/            the capability matrix behind docs/comparison.md
examples/hello/          a console application: src/main.nim, its main module, and
                         src/hello.nim, which is reloaded
examples/simple/         an application with a window (wgrender), with a web build too
```

## License

MIT. See [LICENSE](LICENSE).
