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
##   var score {.hot.} = 0                          # kept across reloads
##   proc onFrame*(dt: float) {.hotEntry.} = ...    # what the program calls
##
## {.hotEntry.} marks the procs the program calls into. In a hot build (-d:hotReload) each
## is a stub that calls the latest library's version. The rest of the code needs nothing:
## it's all in the new library.
##
## What the code keeps between calls lives in hot globals, `var x {.hot.}: T`
## (hotglobals.nim): kept across reloads, and carried over when a reload changes their
## type. The code's plain globals start over with each reload.
##
## A replaced library stays loaded, so a callback its code handed out keeps working, but
## runs the code it came from: fine for a one-off (an asset arriving), not for one that
## keeps firing (a frame callback), which the program registers and points at an entry. If
## a reload has moved a hot global to new storage since the callback was made, what it
## writes there is lost: `hotMoves()` tells it.
##
## A reload whose code changed an entry's signature (its parameters or result) is refused:
## the program would call it the old way. Restart to run it.

import std/macros
import ./hotglobals
export hotglobals
when defined(hotReload) or defined(hotReloadLibrary):
  import std/hashes

when defined(hotReload) or defined(hotReloadLibrary):
  # what {.hotEntry.} makes a stub or an export from, in a hot build
  proc cName(key: string): string {.compileTime.} =
    ## an entry's symbol in the code's library
    result = "hotreload_"
    for c in key:
      result.add(if c in {'a'..'z', 'A'..'Z', '0'..'9'}: c else: '_')

  proc typeOf(d: NimNode): NimNode =
    ## a parameter's type: the one it's given, or its default value's
    if d[^2].kind != nnkEmpty: d[^2] else: newCall(ident"typeof", d[^1])

  proc paramTypes(params: NimNode): seq[NimNode] =
    ## each parameter's type, one per parameter
    for i in 1 ..< params.len:
      let d = params[i]
      for _ in 0 ..< d.len - 2:
        result.add typeOf(d)

  proc sigOfProc(params: NimNode): NimNode =
    ## an expression for the proc's signature, hashed: its parameters' types (var or not)
    ## and its result's, by their shape (typeSig)
    var parts = newLit("")
    proc part(t: NimNode): NimNode =
      if t.kind == nnkVarTy: infix(newLit("var "), "&", newCall(bindSym"typeSig", t[0]))
      else: newCall(bindSym"typeSig", t)
    for t in paramTypes(params):
      parts = infix(infix(parts, "&", part(t)), "&", newLit(";"))
    if params[0].kind != nnkEmpty:
      parts = infix(infix(parts, "&", newLit("->")), "&", part(params[0]))
    newCall(ident"static", newCall(bindSym"hash", parts))

when defined(hotReload):
  import std/[dynlib, os, osproc, strutils, times]

  type Entry = object
    key: string          ## module.name
    cname: string        ## its symbol in the code's library
    target: ptr pointer  ## the stub's: what it calls
    sig: int

  var entries: seq[Entry]

  proc registerEntry*(key, cname: string; target: ptr pointer; sig: int) =
    ## an entry's stub, for a reload to point at the new code (called as the program
    ## starts, by what {.hotEntry.} makes)
    entries.add Entry(key: key, cname: cname, target: target, sig: sig)

macro hotEntry*(def: untyped): untyped =
  ## a proc the program calls into, which each reload points at the new code (see the
  ## module's doc)
  if def.kind notin {nnkProcDef, nnkFuncDef}:
    error("{.hotEntry.}: a proc", def)
  if def[2].kind != nnkEmpty:
    error("{.hotEntry.}: not a generic proc (a library can't export one)", def)
  when not (defined(hotReloadLibrary) or defined(hotReload)):
    result = def # an ordinary proc
  else:
    let base = if def[0].kind == nnkPostfix: def[0][1] else: def[0]
    let key = moduleKey(def) & "." & $base
    let cname = cName(key)
    let sig = sigOfProc(def.params)

    when defined(hotReloadLibrary):
      # the code, under its symbol, and its signature, for the program to check first
      result = newStmtList(def)
      def.addPragma ident"cdecl"
      def.addPragma newColonExpr(ident"exportc", newLit(cname))
      def.addPragma ident"dynlib"
      let sigProc = genSym(nskProc, $base & "Sig")
      result.add quote do:
        proc `sigProc`(): int {.cdecl, exportc: `cname` & "_sig", dynlib.} = `sig`
    elif defined(hotReload):
      # the stub: the program's name for it, which calls through `target`. At first that's
      # the code compiled in; a swap points it at the new library's
      let impl = copyNimTree(def)
      impl[0] = genSym(nskProc, $base & "Impl")
      impl.addPragma ident"cdecl"
      var procTy = newNimNode(nnkProcTy)
      var tyParams = copyNimTree(def.params)
      for i in 1 ..< tyParams.len:
        # a proc type has no default values, so the type is spelled out
        tyParams[i][^2] = typeOf(tyParams[i])
        tyParams[i][^1] = newEmptyNode()
      procTy.add tyParams
      procTy.add nnkPragma.newTree(ident"cdecl")
      let target = ident($base & "HotTarget")
      var call = newCall(target)
      for i in 1 ..< def.params.len:
        for j in 0 ..< def.params[i].len - 2:
          call.add def.params[i][j]
      let stub = copyNimTree(def)
      stub.body = newStmtList(call)
      let forward = copyNimTree(def)
      forward.body = newEmptyNode()
      let implName = impl[0]
      let register = bindSym"registerEntry"
      result = newStmtList(forward, impl)
      result.add quote do:
        var `target`: `procTy` = `implName`
        `register`(`key`, `cname`, cast[ptr pointer](addr `target`), `sig`)
      result.add stub

type Reloader* = ref object
  ## the program's side of hot reload: `update` it every frame (or loop)
  beforeReload*: proc ()
    ## just before a swap, while the old code is what's called (and its hot globals are
    ## what they were): its last word
  afterReload*: proc ()
    ## just after, on the new code
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
    # program calls each entry the way it was compiled to
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
    if r.beforeReload != nil: r.beforeReload()
    # --noMain: the library's Nim runtime and globals are set up by its NimMain
    cast[proc () {.cdecl, raises: [].}](lib.symAddr("NimMain"))()
    for e in entries:
      let p = lib.symAddr(e.cname.cstring)
      if p == nil: echo "hotreload: " & e.key & " is gone from the new code: its last version runs on"
      else: e.target[] = p
    # The old library stays loaded: strings may still point at its string literals, and
    # what it handed out at its code. A few hundred KB per reload.
    r.lib = lib
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
