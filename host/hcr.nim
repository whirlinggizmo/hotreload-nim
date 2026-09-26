## Hot code reload for a Nim program: the program runs, and when a source file changes
## it rebuilds its code as a shared library in the background (-d:hcrScript) and swaps it
## in, without stopping. Nothing here knows what the program is: it calls its own code,
## and hcr keeps that code current.
##
## Mark the procs the program calls into {.reloadable.}. In a hot build (-d:hcrHost) each
## is a stub that calls the latest library's version, so `onFrame(dt)` in a frame
## callback runs whatever onFrame was last saved. Everywhere else (debug, release, web)
## it's an ordinary proc, called directly.
##
## What the code keeps between calls lives in hot globals, `var x {.hot.}: T`
## (hotvars.nim): kept by the host across reloads, and carried over when a reload
## changes their type. A module's plain globals start over with each reload.
##
## The program itself, what wires the code to the engine or loop, goes in a `hotMain:`
## block, which the script's library leaves out:
##
##   hotMain:
##     let hot = hotHost()
##     hot.afterReload = proc () = onLoad(reloaded = true)
##     setFrame(proc (dt: float) =
##       hot.update()   # rebuilds and swaps when a source changed
##       onFrame(dt))   # the latest onFrame
##
## A replaced library stays loaded, so a callback its code handed out keeps working, but
## runs the code it came from: fine for a one-off (an asset arriving), not for one that
## keeps firing (a frame callback), which the program registers and points at a
## reloadable. If a reload has moved a hot global to new storage since the callback was
## made, what it writes there is lost: `hotCarries()` tells it.
##
## A reload whose code changed a reloadable's signature (its parameters or result) is
## refused: the program would call it the old way. Restart to run it.

import std/macros
import ./hotvars
export hotvars
when defined(hcrHost) or defined(hcrScript):
  import std/hashes

when defined(hcrHost) or defined(hcrScript):
  # what {.reloadable.} makes a stub or an export from, in a hot build
  proc cName(key: string): string {.compileTime.} =
    ## a reloadable's symbol in the script's library
    result = "hcr_"
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

when defined(hcrHost):
  import std/[dynlib, os, osproc, strutils, times]

  type Reloadable = object
    key: string          ## module.name
    cname: string        ## its symbol in a script's library
    target: ptr pointer  ## the stub's: what it calls
    sig: int

  var reloadables: seq[Reloadable]

  proc hcrRegister*(key, cname: string; target: ptr pointer; sig: int) =
    ## a reloadable's stub, for a swap to point at the new code (called as the program
    ## starts, by the code {.reloadable.} makes)
    reloadables.add Reloadable(key: key, cname: cname, target: target, sig: sig)

macro reloadable*(def: untyped): untyped =
  ## a proc the program calls, which a reload replaces (see the module's doc)
  if def.kind notin {nnkProcDef, nnkFuncDef}:
    error("{.reloadable.}: a proc", def)
  if def[2].kind != nnkEmpty:
    error("{.reloadable.}: not a generic proc (a library can't export one)", def)
  when not (defined(hcrScript) or defined(hcrHost)):
    result = def # an ordinary proc
  else:
    let base = if def[0].kind == nnkPostfix: def[0][1] else: def[0]
    let key = moduleKey(def) & "." & $base
    let cname = cName(key)
    let sig = sigOfProc(def.params)

    when defined(hcrScript):
      # the code, under its symbol, and its signature, for the host to check first
      result = newStmtList(def)
      def.addPragma ident"cdecl"
      def.addPragma newColonExpr(ident"exportc", newLit(cname))
      def.addPragma ident"dynlib"
      let sigProc = genSym(nskProc, $base & "Sig")
      result.add quote do:
        proc `sigProc`(): int {.cdecl, exportc: `cname` & "_sig", dynlib.} = `sig`
    elif defined(hcrHost):
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
      let register = bindSym"hcrRegister"
      result = newStmtList(forward, impl)
      result.add quote do:
        var `target`: `procTy` = `implName`
        `register`(`key`, `cname`, cast[ptr pointer](addr `target`), `sig`)
      result.add stub

template hotMain*(body: untyped) =
  ## the program: what calls the reloadable code (see the module's doc). A script's
  ## library is the reloadable code alone, so it leaves this out
  when not defined(hcrScript):
    body

type HotHost* = ref object
  ## the running program's side of hot reload: `update` it every frame (or loop)
  beforeReload*: proc ()
    ## just before a swap, while the old code is what's called (and its hot globals are
    ## what they were): its last word
  afterReload*: proc ()
    ## just after, on the new code
  when defined(hcrHost):
    source: string            ## the main module
    buildDir: string
    lib: LibHandle
    version: int
    build: Process
    building: string          ## the library the running build makes
    changedSince: bool        ## a source changed while building: build again after
    mtimes: seq[(string, Time)]
    nextCheck: float

when defined(hcrHost):
  const
    RTLD_NOW = 2.cint
    # the library's own symbols before the host's: its Nim runtime, not the host's
    RTLD_DEEPBIND = 8.cint

  proc dlopen(path: cstring; flags: cint): LibHandle {.importc, header: "<dlfcn.h>".}
  proc dlerror(): cstring {.importc, header: "<dlfcn.h>".}

  const hcrBuildDir {.strdefine.} = ""
    ## where the script's builds go (the libraries and their Nim cache), when the
    ## program's config names one: -d:hcrBuildDir=<dir>

  proc sources(h: HotHost): seq[(string, Time)] =
    ## the .nim files in the main module's directory and below, and when each last changed
    for path in walkDirRec(h.source.parentDir):
      if path.splitFile.ext == ".nim":
        result.add (path, getLastModificationTime(path))

  proc newHotHost*(source: string): HotHost =
    ## watches the .nim files in `source`'s directory and below, `source` being the
    ## program's main module (hotHost passes it)
    result = HotHost(source: source)
    result.buildDir =
      if hcrBuildDir.len > 0: hcrBuildDir else: source.parentDir.parentDir / "build/script"
    result.mtimes = result.sources()
    createDir(result.buildDir)
    echo "hcr: watching " & source.parentDir & " for changes to " & source.extractFilename

  template hotHost*(): HotHost =
    ## call once, in the main module's hotMain block
    newHotHost(instantiationInfo(fullPaths = true).filename)

  proc startBuild(h: HotHost) =
    inc h.version
    h.building = h.buildDir / "lib" & h.source.splitFile.name & "_" & $h.version & ".so"
    var args = @["c", "-d:hcrScript", "--nimcache:" & h.buildDir / "nimcache",
                 "--out:" & h.building, h.source]
    when defined(release): args.insert("-d:release", 1)
    echo "hcr: building " & h.source.extractFilename
    # its output (errors) goes straight to this terminal
    h.build = startProcess("nim", h.source.parentDir, args, options = {poUsePath, poParentStreams})

  proc swap(h: HotHost) =
    let lib = dlopen(h.building.cstring, RTLD_NOW or RTLD_DEEPBIND)
    if lib == nil:
      echo "hcr: can't load " & h.building & ": " & $dlerror()
      return
    # Before any of the new code runs (its NimMain would carry hot globals over): the
    # program calls each reloadable the way it was compiled to
    var changed: seq[string]
    for r in reloadables:
      let sigName = r.cname & "_sig"
      let sigProc = lib.symAddr(sigName.cstring)
      if sigProc != nil and cast[proc (): int {.cdecl.}](sigProc)() != r.sig:
        changed.add r.key
    if changed.len > 0:
      echo "hcr: " & changed.join(", ") & (if changed.len == 1: "'s" else: "'") &
           " signature changed: restart to run the new code (the last still runs)"
      unloadLib(lib)
      return
    if h.beforeReload != nil: h.beforeReload()
    # --noMain: the library's Nim runtime and globals are set up by its NimMain
    cast[proc () {.cdecl, raises: [].}](lib.symAddr("NimMain"))()
    for r in reloadables:
      let p = lib.symAddr(r.cname.cstring)
      if p == nil: echo "hcr: " & r.key & " is gone from the new code: its last version runs on"
      else: r.target[] = p
    # The old library stays loaded: strings may still point at its string literals, and
    # what it handed out at its code. A few hundred KB per reload.
    h.lib = lib
    if h.afterReload != nil: h.afterReload()
    echo "hcr: reloaded " & h.source.extractFilename & " (" & h.building.extractFilename & ")"

  proc update*(h: HotHost) =
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
    let now = epochTime()
    if now < h.nextCheck: return
    h.nextCheck = now + 0.25
    let current = h.sources()
    if current != h.mtimes:
      h.mtimes = current
      if h.build != nil: h.changedSince = true
      else: h.startBuild()

else:
  template hotHost*(): HotHost =
    ## outside a hot build, nothing to watch: the code is compiled in
    HotHost()

  proc update*(h: HotHost) {.inline.} = discard
    ## outside a hot build, nothing to do
