## Hot reload for a Nim program: while it runs, the code it calls is rebuilt when a source
## changes, as a shared library, in the background, and swapped in, without stopping.
## Nothing here knows what the program is.
##
## A program that hot reloads is two parts: the program itself, its main module, which
## sets things up and runs the loop (and calls into the code), and the code, a module the
## main module imports (and what that imports). Only the code is rebuilt; a change to the
## main module takes a restart. Built any other way (debug, release, web), the two are
## one ordinary program.
##
##   # main.nim: the program
##   import hotreload, game
##   let reloader = newReloader()
##   reloader.afterReload = proc () = onLoad(reloaded = true)
##   while running:
##     reloader.update()   # rebuilds and swaps when a source changed
##     onFrame(dt)         # the latest onFrame
##
##   # game.nim: the code
##   import hotreload
##   var score {.hot.} = 0                        # kept across reloads
##   proc onFrame*(dt: float) {.hot.} = ...       # the program's calls get the latest
##   proc fixUp() {.afterHotReload.} = ...        # run after each reload
##
## {.hot.} on a proc marks one the program calls: in a hot build (-d:hotReload) the
## program's calls go to the latest library's version (hotprocs.nim). The rest of the
## code needs nothing: it's all in the new library, which is the code module and all it
## imports, built as one, whichever of them changed. {.beforeHotReload.} and
## {.afterHotReload.} are the code's own reload hooks, at most one of each per module.
##
## What the code keeps between calls lives in hot globals, `var x {.hot.}: T`
## (hotglobals.nim): kept across reloads, and carried over when a reload changes their
## type. The code's plain globals start over with each reload.
##
## A replaced library stays loaded, so a callback its code handed out keeps working, but
## runs the code it came from: fine for a one-off (an asset arriving), not for one that
## keeps firing (a frame callback), which the program registers and points at a hot
## proc. If a reload has moved a hot global to new storage since the callback was made,
## what it writes there is lost: `hotMoves()` tells it.
##
## A reload whose code changed a hot proc's signature (its parameters or result) is
## refused: the program would call it the old way. Restart to run it.

import std/macros
import ./hotglobals
export hotglobals
import ./hotprocs
export hotprocs

macro hot*(def: untyped): untyped =
  ## `var x {.hot.}: T` or `proc p() {.hot.}`: what the program relies on across reloads.
  ## A global is kept (hotglobals.nim), a proc's calls from the program follow the new code
  ## (hotprocs.nim)
  case def.kind
  of nnkVarSection: result = newCall(bindSym"hotGlobal", def)
  of nnkProcDef, nnkFuncDef: result = newCall(bindSym"hotProc", def)
  else: error("{.hot.}: a global (var) or a proc", def)

when defined(hotReload):
  import std/[dynlib, os, osproc, strutils, times]

type Reloader* = ref object
  ## the program's side of hot reload: `update` it every frame (or loop)
  beforeReload*: proc ()
    ## the program's: just before a swap, after the old code's {.beforeHotReload.} hooks
  afterReload*: proc ()
    ## the program's: just after, after the new code's {.afterHotReload.} hooks
  when defined(hotReload):
    code: string              ## the code's module: what's built as the library
    program: string           ## the program's main module: watched for nothing
    buildDir: string
    lib: LibHandle
    version: int
    build: Process
    building: string          ## the library the running build makes
    changedSince: bool        ## a source changed while building: build again after
    mtimes: seq[(string, Time)]
    nextCheck: float

when defined(hotReload):
  const
    RTLD_NOW = 2.cint
    # the library's own symbols before the program's: its Nim runtime, not the program's
    RTLD_DEEPBIND = 8.cint

  proc dlopen(path: cstring; flags: cint): LibHandle {.importc, header: "<dlfcn.h>".}
  proc dlerror(): cstring {.importc, header: "<dlfcn.h>".}

  const hotReloadBuildDir {.strdefine.} = ""
    ## where the code's builds go (the libraries and their Nim cache), when the
    ## program's config names one: -d:hotReloadBuildDir=<dir>

  proc sources(r: Reloader): seq[(string, Time)] =
    ## the .nim files in the code's directory and below, but the program's main module,
    ## and when each last changed
    for path in walkDirRec(r.code.parentDir):
      if path.splitFile.ext == ".nim" and path != r.program:
        result.add (path, getLastModificationTime(path))

  proc newReloader*(code, program: string): Reloader =
    ## watches the .nim files in `code`'s directory and below (but `program`'s), and
    ## rebuilds `code` as a library when one changes. `newReloader()` passes both
    result = Reloader(code: code, program: program)
    result.buildDir =
      if hotReloadBuildDir.len > 0: hotReloadBuildDir
      else: code.parentDir.parentDir / "build/library"
    result.mtimes = result.sources()
    createDir(result.buildDir)
    echo "hotreload: watching " & code.parentDir & " for changes to " & code.extractFilename

  template newReloader*(): Reloader =
    ## call once, in the program's main module: the code is the module hotReloadConfig
    ## names (-d:hotReloadCode=<module>)
    when hotReloadCode.len == 0:
      {.error: "hotreload: which module is the code? -d:hotReloadCode=<module> " &
               "(hotReloadConfig sets it)".}
    newReloader(hotReloadCode, instantiationInfo(fullPaths = true).filename)

  proc startBuild(r: Reloader) =
    inc r.version
    r.building = r.buildDir / "lib" & r.code.splitFile.name & "_" & $r.version & ".so"
    var args = @["c", "-d:hotReloadLibrary", "--nimcache:" & r.buildDir / "nimcache",
                 "--out:" & r.building, r.code]
    when defined(release): args.insert("-d:release", 1)
    echo "hotreload: building " & r.code.extractFilename
    # its output (errors) goes straight to this terminal
    r.build = startProcess("nim", r.code.parentDir, args, options = {poUsePath, poParentStreams})

  proc swap(r: Reloader) =
    let lib = dlopen(r.building.cstring, RTLD_NOW or RTLD_DEEPBIND)
    if lib == nil:
      echo "hotreload: can't load " & r.building & ": " & $dlerror()
      return
    # Before any of the new code runs (its NimMain would carry hot globals over): the
    # program calls each hot proc the way it was compiled to
    var changed: seq[string]
    for e in entries:
      let sigName = e.cname & "_sig"
      let sigProc = lib.symAddr(sigName.cstring)
      if sigProc != nil and cast[proc (): int {.cdecl.}](sigProc)() != e.sig:
        changed.add e.key
    if changed.len > 0:
      echo "hotreload: " & changed.join(", ") & (if changed.len == 1: "'s" else: "'") &
           " signature changed: restart to run the new code (the last still runs)"
      unloadLib(lib)
      return
    runHooks(hookBefore)  # the old code's
    if r.beforeReload != nil: r.beforeReload()
    # --noMain: the library's Nim runtime and globals are set up by its NimMain, and its
    # modules register their hooks as they start
    forgetHooks()
    cast[proc () {.cdecl, raises: [].}](lib.symAddr("NimMain"))()
    for e in entries:
      let p = lib.symAddr(e.cname.cstring)
      if p == nil: echo "hotreload: " & e.key & " is gone from the new code: its last version runs on"
      else: e.target[] = p
    # The old library stays loaded: strings may still point at its string literals, and
    # what it handed out at its code. A few hundred KB per reload.
    r.lib = lib
    runHooks(hookAfter)   # the new code's
    if r.afterReload != nil: r.afterReload()
    echo "hotreload: reloaded " & r.code.extractFilename & " (" & r.building.extractFilename & ")"

  proc update*(r: Reloader) =
    ## call every frame: checks the sources a few times a second, and swaps a finished
    ## build in
    if r.build != nil:
      let code = r.build.peekExitCode()
      if code == -1: discard
      else:
        r.build.close()
        r.build = nil
        if code == 0: r.swap()
        else: echo "hotreload: build failed; still running the last one"
        if r.changedSince:
          r.changedSince = false
          r.startBuild()
    let now = epochTime()
    if now < r.nextCheck: return
    r.nextCheck = now + 0.25
    let current = r.sources()
    if current != r.mtimes:
      r.mtimes = current
      if r.build != nil: r.changedSince = true
      else: r.startBuild()

else:
  template newReloader*(): Reloader =
    ## outside a hot build, nothing to watch: the code is compiled in
    Reloader()

  proc update*(r: Reloader) {.inline.} = discard
    ## outside a hot build, nothing to do
