# hotreload-nim

Hot reload for Nim programs: while the program runs, edit its code and save, and the code
is rebuilt in the background and swapped in, without restarting and without losing its
state. Debug, release and web builds compile the same code in, with no reloading and no
cost.

Built for [wgrender](https://github.com/whirlinggizmo/wgrender-nim) games, but nothing in
it knows about wgrender: `examples/simple` is wgrender's simple example, hot reloaded.
Linux only, for now.

```
hotreload.nimble         the package: srcDir src, `import hotreload`
src/hotreload.nim        {.hotEntry.} procs, {.hot.} globals and the Reloader
src/hotreload/
  reload.nim             entry points, the reloader: watch, rebuild, swap
  hotglobals.nim         {.hot.} globals: kept across reloads, carried across type changes
  migrate.nim            carrying a value from one build's type to another's
  typesig.nim            a type's shape, to tell when it changed
  tasks.nims             the build variants and their tasks, for a program's config.nims
tests/                   `nimble test`
examples/simple/         wgrender's simple example: src/main.nim, the program, and
                         src/simple.nim, the code it reloads
```

## Using it

A program that hot reloads is two parts. The **program** (its main module) sets things up
and runs the loop, and calls into the **code**, a module it imports. Only the code is
reloaded.

```nim
# src/game.nim: the code
import hotreload

var score {.hot.} = 0                     # kept across reloads

proc onFrame*(dt: float) {.hotEntry.} =   # what the program calls
  score += 1
```

```nim
# src/main.nim: the program
import hotreload, ./game

let reloader = newReloader()
while running:
  reloader.update()    # rebuilds and swaps when a source changed
  onFrame(dt)          # the latest onFrame
```

- `{.hotEntry.}` marks the procs the program calls into. Everything else in the code is
  reloaded anyway; only the entries need marking.
- `{.hot.}` marks the globals that survive a reload. A plain global starts over.
- `reloader.beforeReload` and `reloader.afterReload` run just before a swap, on the old
  code, and just after, on the new.

The build: `import "…/hotreload/tasks.nims"` in the program's `config.nims` (a literal
path), then

```nim
let target = BuildTarget(dir: thisDir, name: "game")   # src/main.nim, src/game.nim
hotReloadConfig(target)
hotReloadTasks(target)
```

gives `nim build hot|debug|release|all`, `nim hot`, `nim debug`, `nim release` and
`nim clean`. `nim hot` runs the hot build; the others compile the code in.

## How it works

The hot build (`-d:hotReload`) watches the code's sources and, when one changes, rebuilds
the code as a shared library (`-d:hotReloadLibrary`), loads it, and points each entry at the
new code. The program keeps the hot globals, so the new code gets the same ones. When a
reload changes a hot global's type, what still fits is carried over, field by field, by
name, and the rest starts from its default. That covers objects, tuples, seqs, arrays, and
refs, which are copied as a graph: shared stays shared, and cycles stay cycles.

A replaced library stays loaded, so a callback its code handed out keeps working, running
the code it came from.

## Limits

- Linux (it relies on `RTLD_DEEPBIND` and `-rdynamic`).
- A change to an entry's parameters or result can't be swapped in: the reload is refused,
  with a message, and the old code keeps running until a restart.
- A change to the program's main module needs a restart.
- Hot globals can't hold pointers, closures, or refs to objects that inherit.
- Old libraries, and the old copies of hot globals whose type changed, aren't freed.
- Breakpoints go stale after a reload shifts lines; the debug build doesn't reload.

## Examples

`examples/simple` needs [wgrender-nim](https://github.com/whirlinggizmo/wgrender-nim)
(`WGRENDER_NIM`, or `~/projects/github/whirlinggizmo/wgrender-nim`):

```
cd examples/simple
nim hot          # then edit src/simple.nim: BobSpeed, the colors, the text
nim web          # its web build (no hot reload there), and `nim serve` to run it
```

## License

MIT: see [LICENSE](LICENSE).
