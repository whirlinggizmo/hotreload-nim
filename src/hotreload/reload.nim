## Hot reload for a Nim program: while it runs, everything but its main module is rebuilt
## when a source changes, as a shared library, in the background, and swapped in, without
## stopping. Nothing here knows what the program is.
##
## The main module is compiled into the executable and never reloaded: a change to it
## requires a restart. It makes the reloader, which has to be made there, runs the loop,
## and calls into the reloaded modules. Those are the modules with something hot in them
## ({.hot.} globals or procs, reload hooks), and everything they import: they're built
## into one library, rebuilt whole with each reload. Built any other way (debug,
## release, web), it's all one ordinary executable.
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
## A hot build is `nim c -d:hotReload -d:useMalloc main.nim`: nothing else to configure.
## The executable exports its symbols for the library (the pragmas below), and the
## reloader builds each library with what it needs on its own command line. Defines both
## builds need go in a config.nims, which both read.
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
  import std/[dynlib, macrocache, os, osproc, strutils, times]

  when not defined(useMalloc):
    {.error: "hotreload: a hot build needs -d:useMalloc, because the executable and its " &
             "library share one heap. Add it to the nim command line, or to config.nims: " &
             "switch(\"define\", \"useMalloc\")".}

  # The executable exports its own symbols (hotreload's, an engine it links), which each
  # library resolves against: on Windows, a DLL links against the executable's import
  # library, written to its Nim cache
  when defined(windows):
    import std/compilesettings
    # (joined with /, which MinGW takes: `/` would make a cross-compile's path Windows')
    const programLib = querySetting(nimcacheDir) & "/lib" & querySetting(projectName) & ".a"
    {.passL: "-Wl,--export-all-symbols -Wl,--out-implib," & quoteShell(programLib).}
  else:
    {.passL: "-rdynamic".}

type Reloader* = ref object
  ## the main module's side of hot reload: `update` it every frame (or loop)
  beforeReload*: proc ()
    ## the main module's: just before a swap, after the old code's {.beforeHotReload.}
    ## hooks
  afterReload*: proc ()
    ## the main module's: just after, after the new code's {.afterHotReload.} hooks
  when defined(hotReload):
    modules: seq[string]      ## the modules with something hot in them
    dirs: seq[string]         ## where they are: watched, and below
    root: string              ## the library's main module, which imports them
    name: string              ## the executable's, for the libraries' names
    program: string           ## the main module: not watched
    buildDir: string
    lib: LibHandle
    version: int
    build: Process
    building: string          ## the library the running build makes
    changedSince: bool        ## a source changed while building: build again after
    changed: seq[string]      ## the sources that changed since the last build started
    settling: bool            ## a source changed: build when they've stopped changing
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
    ## the .nim files in the reloaded modules' directories and below, but the main
    ## module, and when each last changed
    for dir in r.dirs:
      for path in walkDirRec(dir):
        if path.splitFile.ext == ".nim" and path != r.program:
          result.add (path, getLastModificationTime(path))

  proc newReloader*(modules: openArray[string]; program: string): Reloader =
    ## rebuilds `modules` (and what they import) as a library when a source in their
    ## directories changes, but `program`, the main module. `newReloader()` passes both
    result = Reloader(modules: @modules, program: program,
                      name: getAppFilename().splitFile.name)
    result.buildDir =
      if hotReloadBuildDir.len > 0: hotReloadBuildDir
      else: program.parentDir.parentDir / "build" / hostOS / "hot" / "library"
    createDir(result.buildDir)
    if modules.len == 0:
      echo "hotreload: nothing to reload: no module has {.hot.} globals or procs, or " &
           "reload hooks"
      return
    # each directory once, and none inside another
    for m in modules:
      if m.parentDir notin result.dirs: result.dirs.add m.parentDir
    let dirs = result.dirs
    result.dirs.setLen 0
    for d in dirs:
      var inside = false
      for other in dirs:
        if other != d and d.startsWith(other & DirSep): inside = true
      if not inside: result.dirs.add d
    # the library's main module: the reloaded modules, and through them what they import
    result.root = result.buildDir / "hotreload_root.nim"
    var imports = "# written by hotreload: the modules this program reloads\n" &
                  "{.warning[UnusedImport]: off.}\n"
    for m in modules:
      imports.add "import \"" & m.replace('\\', '/') & "\"\n"
    writeFile(result.root, imports)
    result.mtimes = result.sources()
    var names: seq[string]
    for m in modules: names.add m.relativePath(program.parentDir).replace('\\', '/')
    echo "hotreload: watching for changes to " & names.join(", ") &
         (if names.len == 1: " and what it imports" else: " and what they import")

  macro hotModuleList(): untyped =
    ## the modules with something hot in them, which the build has seen by the time the
    ## main module's own code is compiled (after its imports)
    result = newTree(nnkBracket)
    for m in hotModules: result.add m
    if result.len == 0: result = newCall(bindSym"newSeq", ident"string")

  template newReloader*(): Reloader =
    ## call once, in the main module
    newReloader(hotModuleList(), instantiationInfo(fullPaths = true).filename)

  proc startBuild(r: Reloader) =
    let why = r.changed.join(", ") & " changed"
    r.changed.setLen 0
    inc r.version
    r.building = r.buildDir / "lib" & r.name & "_" & $r.version & libExt
    # all but the main module, loaded by this executable: with the executable's heap,
    # the same hotreload, keys from the same directory, and -d:release when it has it
    var args = @["c", "-d:hotReloadLibrary", "-d:useMalloc", "--app:lib", "--noMain:on",
                 "--hints:off", "--path:" & currentSourcePath().parentDir.parentDir,
                 "-d:hotReloadRoot=" & r.program.parentDir,
                 "--nimcache:" & r.buildDir / "nimcache", "--out:" & r.building]
    when defined(release): args.add "-d:release"
    else: args.add "--debugger:native"
    # what it calls in the executable: on Windows, linked against its import library; on
    # macOS, found there when it loads
    when defined(windows): args.add "--passL:" & quoteShell(programLib)
    elif defined(macosx): args.add "--passL:-Wl,-undefined,dynamic_lookup"
    args.add r.root
    echo "hotreload: building (" & why & ")"
    # its output (errors) goes straight to this terminal
    r.build = startProcess("nim", r.program.parentDir, args,
                           options = {poUsePath, poParentStreams})

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
    echo "hotreload: reloaded (" & r.building.extractFilename & ")"

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
      # which ones, for the build's message: new or changed, and removed
      var paths: seq[string]
      for (path, time) in current:
        if (path, time) notin r.mtimes: paths.add path
      for (path, _) in r.mtimes:
        var gone = true
        for (other, _) in current:
          if other == path: gone = false
        if gone: paths.add path
      for path in paths:
        let name = path.relativePath(r.program.parentDir).replace('\\', '/')
        if name notin r.changed: r.changed.add name
      r.mtimes = current
      # a change starts a build once the sources have stopped changing (a save can touch
      # a file twice, or several files), at the next check
      r.settling = true
    elif r.settling:
      r.settling = false
      if r.build != nil: r.changedSince = true
      else: r.startBuild()

else:
  template newReloader*(): Reloader =
    ## outside a hot build, nothing to watch: it's all one executable
    Reloader()

  proc update*(r: Reloader) {.inline.} = discard
    ## outside a hot build, nothing to do
