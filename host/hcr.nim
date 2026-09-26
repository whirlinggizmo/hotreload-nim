## Hot code reload for a wgrender program: a script module that a running host rebuilds
## and swaps in when its source changes.
##
## The script marks what the host calls {.reloadable.}. Everywhere but a hot build it is
## an ordinary module the host imports: release and web builds compile it in. With
## -d:hcrHost, the host starts on that compiled-in code too, and the first time a source
## file changes it builds the script as a shared library (-d:hcrScript) in the background
## and switches to it.
##
## What the script keeps between calls lives in a context object it is passed, which a
## reload keeps. Its type can change while running: the module that declares it ends with
## `hotContext(Context)`, and when a reloaded script's Context differs, the host has the
## old script write its context out and the new one read back what still fits
## (migrate.nim), and the old script free the old one. A context that holds refs is
## carried over like that on every reload: each library has its own Nim runtime, and a
## ref belongs to the one that made it. A module's own globals can survive a reload too:
## `var x {.hot.}: T` (hotvars.nim).
##
## A replaced library stays loaded, so a callback the script gave wgrender keeps working,
## but it runs the code it came from: fine for a one-off (an asset task), not for one that
## keeps firing (setFrame, events). The host registers those and calls the script's
## current code.
##
## Around a swap, the host is told twice: `onUnload` just before, while the old code is
## still what it calls, and `onLoad` just after, to look the new library's procs up. Both
## are told whether the context is carried over to a new one. The host can pass each on to the script
## (wgrhost calls the app's own onUnload and onLoad). Neither runs for a library that
## fails to build or load: the old code runs on.

import std/[hashes, macros]
import ./hotvars
export hotvars

macro reloadable*(def: untyped): untyped =
  ## a proc the host calls: exported from the script's library in a script build, an
  ## ordinary proc otherwise; cdecl in both so the two have one type
  result = def
  result.addPragma ident"cdecl"
  when defined(hcrScript):
    result.addPragma ident"exportc"
    result.addPragma ident"dynlib"

template hotContext*(T: typedesc) =
  ## call once, after the context type, in the module that declares it: its stamp (T's
  ## shape, hashed: typeSig) and, for the host, the procs that make a context, carry one
  ## over to a new one, and free one
  const ContextStamp* {.inject.} = hash(typeSig(T))

  proc hcrContextStamp*(): int {.reloadable.} = ContextStamp

  proc hcrContextHoldsRefs*(): bool {.reloadable.} = holdsRefs(T)

  proc hcrNewContext*(): pointer {.reloadable.} =
    ## a context with T's defaults, which lives until the program ends
    let c = create(T)
    c[] = T()
    c

  proc hcrSaveContext*(c: pointer): string {.reloadable.} =
    save(result, cast[ptr T](c)[])

  proc hcrLoadContext*(c: pointer; data: string) {.reloadable.} =
    load(data, cast[ptr T](c)[])

  proc hcrFreeContext*(c: pointer) {.reloadable.} =
    ## by the code that made it: what's in it belongs to its runtime
    reset(cast[ptr T](c)[])
    dealloc(c)

when defined(hcrHost):
  import std/[dynlib, os, osproc, times]

  const
    RTLD_NOW = 2.cint
    # the library's own symbols before the host's: its Nim runtime, not the host's
    RTLD_DEEPBIND = 8.cint

  proc dlopen(path: cstring; flags: cint): LibHandle {.importc, header: "<dlfcn.h>".}
  proc dlerror(): cstring {.importc, header: "<dlfcn.h>".}

  type
    HotScript* = ref object
      source: string            ## the script's module
      buildDir: string
      contextStamp: int         ## the running script's Context: another is carried over
      onLoad: proc (carry: bool)   ## the host looks its procs up again
      onUnload: proc (carry: bool) ## the old code's last word, before the swap
      lib: LibHandle
      version: int
      build: Process
      building: string          ## the library the running build makes
      changedSince: bool        ## a source changed while building: build again after
      mtimes: seq[(string, Time)]
      nextCheck: float

  proc sources(h: HotScript): seq[(string, Time)] =
    ## the .nim files beside the script's, and when each last changed
    for path in walkFiles(h.source.parentDir / "*.nim"):
      result.add (path, getLastModificationTime(path))

  const hcrBuildDir {.strdefine.} = ""
    ## where the script's builds go (the libraries and their Nim cache), when the host's
    ## config names one: -d:hcrBuildDir=<dir>

  proc newHotScript*(source: string; contextStamp: int; onLoad: proc (carry: bool);
                     onUnload: proc (carry: bool) = nil;
                     buildDir = (if hcrBuildDir.len > 0: hcrBuildDir
                                 else: source.parentDir.parentDir / "build/script")): HotScript =
    ## watches the .nim files in `source`'s directory. `onLoad` runs after each swap:
    ## look the script's procs up there, with `lookup`. `onUnload` runs before it, once
    ## the new library is loaded. `carry`: the context must be carried over to a new one
    ## (the old code's hcrSaveContext, the new code's hcrNewContext and hcrLoadContext,
    ## then the old code's hcrFreeContext): its type changed, or it holds refs
    result = HotScript(source: source, buildDir: buildDir, contextStamp: contextStamp,
                       onLoad: onLoad, onUnload: onUnload)
    result.mtimes = result.sources()
    createDir(buildDir)
    echo "hcr: watching " & source.parentDir & " for changes to " & source.extractFilename

  proc symbol*(h: HotScript; name: string): pointer =
    result = h.lib.symAddr(name)
    if result == nil: raise newException(LibraryError, "hcr: the script has no " & name)

  template lookup*[T: proc](h: HotScript; p: T): T =
    ## the reloaded library's `p`, by its name: `frameProc = script.lookup(onFrame)`
    cast[T](h.symbol(astToStr(p)))

  proc startBuild(h: HotScript) =
    inc h.version
    h.building = h.buildDir / "lib" & h.source.splitFile.name & "_" & $h.version & ".so"
    var args = @["c", "-d:hcrScript", "--nimcache:" & h.buildDir / "nimcache",
                 "--out:" & h.building, h.source]
    when defined(release): args.insert("-d:release", 1)
    echo "hcr: building " & h.source.extractFilename
    # its output (errors) goes straight to this terminal
    h.build = startProcess("nim", h.source.parentDir, args, options = {poUsePath, poParentStreams})

  proc swap(h: HotScript) =
    let lib = dlopen(h.building.cstring, RTLD_NOW or RTLD_DEEPBIND)
    if lib == nil:
      echo "hcr: can't load " & h.building & ": " & $dlerror()
      return
    # --noMain: the library's Nim runtime and globals are set up by its NimMain
    cast[proc () {.cdecl, raises: [].}](lib.symAddr("NimMain"))()
    let stampProc = lib.symAddr("hcrContextStamp")
    if stampProc == nil:
      echo "hcr: " & h.building & " has no hcrContextStamp (hotContext): not loading it"
      unloadLib(lib)
      return
    let stamp = cast[proc (): int {.cdecl.}](stampProc)()
    let changed = stamp != h.contextStamp
    let carry = changed or cast[proc (): bool {.cdecl.}](lib.symAddr("hcrContextHoldsRefs"))()
    if h.onUnload != nil: h.onUnload(carry)
    # The old library stays loaded: strings in the context may still point at its string
    # literals, and what it handed out at its code. A few hundred KB per reload.
    h.lib = lib
    h.contextStamp = stamp
    h.onLoad(carry)
    if changed: echo "hcr: the context's type changed; carried its fields over"
    echo "hcr: reloaded " & h.source.extractFilename & " (" & h.building.extractFilename & ")"

  proc update*(h: HotScript; now: float) =
    ## call every frame: checks the sources a few times a second, and swaps a finished
    ## build in
    if h.build != nil:
      let code = h.build.peekExitCode()
      if code == -1: discard
      else:
        h.build.close()
        h.build = nil
        if code == 0: h.swap()
        else: echo "hcr: build failed; still running the last one"
        if h.changedSince:
          h.changedSince = false
          h.startBuild()
    if now < h.nextCheck: return
    h.nextCheck = now + 0.25
    let current = h.sources()
    if current != h.mtimes:
      h.mtimes = current
      if h.build != nil: h.changedSince = true
      else: h.startBuild()
