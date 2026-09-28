# hotreload's build, for a program's config.nims: the switches a hot build needs, and the
# tasks that build and run each variant.
#
#   import "../../src/hotreload/tasks.nims"  # or computed: see the README
#
#   let target = BuildTarget(dir: thisDir(), name: "hello")
#   hotReloadConfig(target)                  # first: what follows can add to it or override
#   ...                                      # the program's own switches
#   hotReloadTasks(target)                   # or hotReloadTasks(target, [("web", buildWeb)])
#
# The program's main module is src/main.nim, and the code it hot reloads src/<name>.nim
# (BuildTarget's main and code say otherwise).
#
# The variants, each making what it makes in out/<platform>/<variant>/ and keeping its
# work (Nim's cache) in build/<platform>/<variant>/:
#
#   hot       -d:hotReload, a debug build that rebuilds its code as a library when a source
#             changes (-d:hotReloadLibrary, into build/<platform>/hot/library/) and swaps
#             it in
#   debug     the code compiled in, no hot reload (breakpoints never go stale)
#   release   the code compiled in, -d:release
#
# and the tasks:
#
#   nim build hot|debug|release|all   build (all: every variant, and the program's own)
#   nim hot / nim debug / nim release  build and run
#   nim clean                          remove out/ and build/
#
# A target that isn't the desktop (-d:emscripten) has no hot reload: hotReloadConfig
# leaves it to the program's config.

# The stock nimlangserver checks a .nims with --import:system/nimscript, which makes every
# NimScript proc ambiguous: when that module is visible there is nothing here to check
# (see the example's config.nims).
when not declared(nimscript):
  from std/os import `/`, parentDir, quoteShell

  type BuildTarget* = object
    dir*: string    ## the program's directory: its config.nims's
    name*: string   ## the program's name: what the builds are called
    main*: string   ## its main module, when not src/main.nim
    code*: string   ## the module it hot reloads, when not src/<name>.nim

  type ExtraBuild* = tuple
    ## a build target of the program's own, for `nim build <name>` (and `all`)
    name: string
    build: proc () {.nimcall.}

  proc mainModule*(target: BuildTarget): string =
    target.dir / (if target.main.len > 0: target.main else: "src/main.nim")

  proc codeModule*(target: BuildTarget): string =
    target.dir / (if target.code.len > 0: target.code else: "src" / target.name & ".nim")

  proc desktopPlatform*(): string =
    when defined(windows): "windows"
    elif defined(macosx): "macos"
    else: "linux"

  proc variantDir*(variant: string): string =
    ## <platform>/<variant>, under out/ and build/
    desktopPlatform() / variant

  proc exe*(target: BuildTarget; variant: string): string =
    ## what a variant's build makes
    target.dir / "out" / variantDir(variant) / target.name

  proc hotReloadConfig*(target: BuildTarget) =
    ## the switches for this compile: its variant's (from -d:hotReload, -d:hotReloadLibrary,
    ## -d:release), the path to hotreload, and the code's module
    # hotreload's modules: `import hotreload`
    switch("path", currentSourcePath().parentDir.parentDir)
    # which module is the code: the library a hot build makes of it, and where hot globals'
    # and procs' keys are from
    switch("define", "hotReloadCode=" & target.codeModule)

    # no hints for builds and tasks, but a check keeps them: `nim check` (an editor's)
    # runs as "check", nimsuggest as "idetools" (one that checks a .nims as NimScript)
    # or with none
    if getCommand() notin ["check", "idetools", ""]:
      switch("hints", "off")

    if defined(emscripten):
      return

    # debug builds carry DWARF line info mapped to the .nim sources, for gdb/lldb; the
    # host builds its code with the same -d:release it was built with, so they match
    if not defined(release):
      switch("debugger", "native")

    # the program and its code share one heap (libc's), so either may free what the other
    # made
    if defined(hotReload) or defined(hotReloadLibrary):
      switch("define", "useMalloc")

    # what the code calls in the program (hotreload's own procs, an engine it links),
    # which a Windows DLL has to be linked against: the hot program's import library
    let programLib = target.dir / "build" / variantDir("hot") / "lib" & target.name & ".a"

    if defined(hotReloadLibrary):
      # the code alone, loaded by the running program
      switch("app", "lib")
      switch("noMain", "on")
      if defined(windows):
        switch("passL", quoteShell(programLib))
    elif defined(hotReload):
      # export the program's own symbols (an engine it links) for the code to resolve
      # against
      if defined(windows):
        switch("passL", "-Wl,--export-all-symbols -Wl,--out-implib," & quoteShell(programLib))
      else:
        switch("passL", "-rdynamic")
      switch("nimcache", target.dir / "build" / variantDir("hot") / "nimcache")
      switch("define", "hotReloadBuildDir=" & target.dir / "build" / variantDir("hot") / "library")
    elif defined(release):
      switch("nimcache", target.dir / "build" / variantDir("release") / "nimcache")
    else:
      switch("nimcache", target.dir / "build" / variantDir("debug") / "nimcache")

  proc build*(target: BuildTarget; variant: string) =
    ## builds a variant: hot, debug or release
    let flags =
      case variant
      of "hot": "-d:hotReload "
      of "release": "-d:release "
      else: ""
    echo "Building " & target.name & " (" & variant & ")..."
    exec "nim c " & flags & "--out:" & quoteShell(target.exe(variant)) & " " &
         quoteShell(target.mainModule)

  proc run*(target: BuildTarget; variant: string) =
    ## builds a variant and runs it, from the program's directory
    target.build(variant)
    withDir target.dir:
      exec quoteShell(target.exe(variant))

  template hotReloadTasks*(target: BuildTarget; extra: openArray[ExtraBuild] = []) =
    ## the tasks (see the top of this file); `extra` adds the program's own build targets
    ## to `nim build` (and to `all`): [("web", buildWeb)]
    task build, "Build: nim build hot|debug|release|all, or a target of the program's":
      let wanted = if paramCount() >= 2: paramStr(paramCount()) else: ""
      var known = false
      if wanted in ["hot", "debug", "release"]:
        target.build(wanted)
        known = true
      elif wanted == "all":
        for v in ["hot", "debug", "release"]: target.build(v)
        for (_, b) in extra: b()
        known = true
      else:
        for (name, b) in extra:
          if name == wanted:
            b()
            known = true
      if not known:
        var targets = "hot|debug|release"
        for (name, _) in extra: targets.add "|" & name
        quit "usage: nim build " & targets & "|all", 1

    task hot, "Build and run with hot reload": target.run("hot")
    task debug, "Build and run a debug build, no hot reload": target.run("debug")
    task release, "Build and run a release build": target.run("release")

    task clean, "Remove what the builds made (out/) and their work (build/)":
      rmDir(target.dir / "out")
      rmDir(target.dir / "build")
