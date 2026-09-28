## Hot reload for a Nim program: while it runs, everything but its main module is rebuilt
## when a source changes, as a shared library, in the background, and swapped in, without
## stopping. Nothing here knows what the program is.
##
## The main module is compiled into the executable and never reloaded: a change to it
## requires a restart. It makes the reloader, which has to be made there, runs the loop,
## and calls into the reloaded module, which it imports. That module, with everything it
## imports, is built into one library, rebuilt whole with each reload. Built any other
## way (debug, release, web), it's all one ordinary executable.
##
##   # main.nim: the main module, never reloaded
##   import hotreload, game
##   let reloader = newReloader()
##   while running:
##     reloader.update()   # pumps the file watcher, library builder, and reloader
##     game.onFrame(dt)    # the newest onFrame
##
##   # game.nim, and what it imports: reloaded
##   import hotreload
##   var score {.hot.} = 0                    # kept across reloads (hotglobals.nim)
##   proc onFrame*(dt: float) {.hot.} = ...   # the main module's calls follow reloads
##   proc fixUp() {.afterHotReload.} = ...    # run after each reload (hotprocs.nim)
##
## A reload that changed the signature of a hot proc (its parameters or result) is
## refused: the main module would call it the old way. Restart to run it.
##
## A replaced library stays loaded, so a callback its code handed out keeps working, but
## runs the code it came from: fine for a one-off (an asset arriving), not for one that
## keeps firing (a frame callback), which the main module registers and points at a hot
## proc. If a reload has moved a hot global to new storage since the callback was made,
## what it writes there is lost: `hotMoves()` tells it.

import std/macros
import ./hotglobals
export hotglobals
import ./hotprocs
export hotprocs

macro hot*(def: untyped): untyped =
  ## `var x {.hot.}: T` or `proc p() {.hot.}`: what survives a reload. A global is kept
  ## (hotglobals.nim), a proc's calls from the main module follow the new code
  ## (hotprocs.nim)
  case def.kind
  of nnkVarSection: result = newCall(bindSym"hotGlobal", def)
  of nnkProcDef, nnkFuncDef: result = newCall(bindSym"hotProc", def)
  else: error("{.hot.}: a global (var) or a proc", def)

when defined(hotReload):
  import std/[dynlib, os, osproc, strutils, times]

type Reloader* = ref object
  ## the main module's side of hot reload: `update` it every frame (or loop)
  beforeReload*: proc ()
    ## the main module's: just before a swap, after the old code's {.beforeHotReload.}
    ## hooks
  afterReload*: proc ()
    ## the main module's: just after, after the new code's {.afterHotReload.} hooks
  when defined(hotReload):
    code: string              ## the reloaded module: what's built as the library
    program: string           ## the main module: not watched
    buildDir: string
    lib: LibHandle
    version: int
    build: Process
    building: string          ## the library the running build makes
    changedSince: bool        ## a source changed while building: build again after
    mtimes: seq[(string, Time)]
    nextCheck: float

when defined(hotReload):
  when defined(windows):
    const libExt = ".dll"

    proc openLib(path: string): (LibHandle, string) =
      ## the library, or why not. A DLL uses its own symbols before the executable's
      ## anyway
      let lib = loadLib(path)
      (lib, if lib == nil: osErrorMsg(osLastError()) else: "")
  else:
    var RTLD_NOW {.importc, header: "<dlfcn.h>".}: cint
    when defined(macosx):
      const libExt = ".dylib"
      # a library uses its own symbols before the executable's anyway (macOS's two-level
      # namespace)
      var RTLD_LOCAL {.importc, header: "<dlfcn.h>".}: cint
      template openFlags(): cint = RTLD_NOW or RTLD_LOCAL
    else:
      const libExt = ".so"
      # the library's own symbols before the executable's: its Nim runtime, not the
      # executable's
      var RTLD_DEEPBIND {.importc, header: "<dlfcn.h>".}: cint
      template openFlags(): cint = RTLD_NOW or RTLD_DEEPBIND

    proc dlopen(path: cstring; flags: cint): LibHandle {.importc, header: "<dlfcn.h>".}
    proc dlerror(): cstring {.importc, header: "<dlfcn.h>".}

    proc openLib(path: string): (LibHandle, string) =
      ## the library, or why not
      let lib = dlopen(path.cstring, openFlags())
      (lib, if lib == nil: $dlerror() else: "")

  const hotReloadBuildDir {.strdefine.} = ""
    ## where the library builds go (the libraries and their Nim cache), when the
    ## program's config names one: -d:hotReloadBuildDir=<dir>

  proc sources(r: Reloader): seq[(string, Time)] =
    ## the .nim files in the reloaded module's directory and below, but the main module,
    ## and when each last changed
    for path in walkDirRec(r.code.parentDir):
      if path.splitFile.ext == ".nim" and path != r.program:
        result.add (path, getLastModificationTime(path))

  proc newReloader*(code, program: string): Reloader =
    ## watches the .nim files in `code`'s directory and below (but `program`, the main
    ## module), and rebuilds `code`, the reloaded module, as a library when one changes.
    ## `newReloader()` passes both
    result = Reloader(code: code, program: program)
    result.buildDir =
      if hotReloadBuildDir.len > 0: hotReloadBuildDir
      else: code.parentDir.parentDir / "build/library"
    result.mtimes = result.sources()
    createDir(result.buildDir)
    echo "hotreload: watching " & code.parentDir & " for changes to " & code.extractFilename

  template newReloader*(): Reloader =
    ## call once, in the main module: the reloaded module is the one hotReloadConfig
    ## names (-d:hotReloadCode=<module>)
    when hotReloadCode.len == 0:
      {.error: "hotreload: which module is reloaded? -d:hotReloadCode=<module> " &
               "(hotReloadConfig sets it)".}
    newReloader(hotReloadCode, instantiationInfo(fullPaths = true).filename)

  proc startBuild(r: Reloader) =
    inc r.version
    r.building = r.buildDir / "lib" & r.code.splitFile.name & "_" & $r.version & libExt
    var args = @["c", "-d:hotReloadLibrary", "--nimcache:" & r.buildDir / "nimcache",
                 "--out:" & r.building, r.code]
    when defined(release): args.insert("-d:release", 1)
    echo "hotreload: building " & r.code.extractFilename
    # its output (errors) goes straight to this terminal
    r.build = startProcess("nim", r.code.parentDir, args, options = {poUsePath, poParentStreams})

  proc swap(r: Reloader) =
    let (lib, error) = openLib(r.building)
    if lib == nil:
      echo "hotreload: can't load " & r.building & ": " & error
      return
    # Before any of the new code runs (its NimMain would carry hot globals over): the
    # main module calls each hot proc the way it was compiled to
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
    ## outside a hot build, nothing to watch: it's all one executable
    Reloader()

  proc update*(r: Reloader) {.inline.} = discard
    ## outside a hot build, nothing to do
