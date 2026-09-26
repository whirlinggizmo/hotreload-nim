# nimhcr's build, for a program's config.nims: the switches a hot build needs, and the
# tasks that build and run each variant.
#
#   import "../../src/nimhcr/tasks.nims"   # a literal path: NimScript won't take another
#
#   let app = HcrApp(dir: thisDir, name: "simple")
#   hcrConfig(app)                          # first: what follows can add to it or override
#   ...                                     # the program's own switches
#   hcrTasks(app)                           # or hcrTasks(app, [("web", buildWeb)])
#
# The variants, each in the wg* layout: what a build makes in out/<platform>/<variant>/,
# its work (Nim's cache) in build/<platform>/<variant>/:
#
#   hot       -d:hcrHost, a debug build that rebuilds its code as a library when a source
#             changes (-d:hcrScript, into build/<platform>/hot/script/) and swaps it in
#   debug     the code compiled in, no hot reload (breakpoints never go stale)
#   release   the code compiled in, -d:release
#
# and the tasks:
#
#   nim build hot|debug|release|all   build (all: every variant, and the program's own)
#   nim hot / nim debug / nim release  build and run
#   nim clean                          remove out/ and build/
#
# A target that isn't the desktop (-d:emscripten) has no hot reload: hcrConfig leaves it to
# the program's config.

# The stock nimlangserver checks a .nims with --import:system/nimscript, which makes every
# NimScript proc ambiguous: when that module is visible there is nothing here to check
# (see the example's config.nims).
when not declared(nimscript):
  from std/os import `/`, parentDir, quoteShell

  type HcrApp* = object
    dir*: string    ## the program's directory: its config.nims's
    name*: string   ## the program's name: its main module is src/<name>.nim
    main*: string   ## its main module, when not src/<name>.nim

  type HcrTarget* = tuple
    ## a build target of the program's own, for `nim build <name>` (and `all`)
    name: string
    build: proc () {.nimcall.}

  proc mainModule*(app: HcrApp): string =
    app.dir / (if app.main.len > 0: app.main else: "src" / app.name & ".nim")

  proc desktopPlatform*(): string =
    when defined(windows): "windows"
    elif defined(macosx): "macos"
    else: "linux"

  proc variantDir*(variant: string): string =
    ## <platform>/<variant>, under out/ and build/
    desktopPlatform() / variant

  proc exe*(app: HcrApp; variant: string): string =
    ## what a variant's build makes
    app.dir / "out" / variantDir(variant) / app.name

  proc hcrConfig*(app: HcrApp) =
    ## the switches for this compile: its variant's (from -d:hcrHost, -d:hcrScript,
    ## -d:release), and the path to nimhcr
    # nimhcr's modules: `import nimhcr`
    switch("path", currentSourcePath().parentDir.parentDir)

    # no hints for builds and tasks, but a check keeps them: `nim check` (an editor's)
    # runs as "check", the patched nimsuggest as "idetools", the stock one with none
    if getCommand() notin ["check", "idetools", ""]:
      switch("hints", "off")

    if defined(emscripten):
      return

    # debug builds carry DWARF line info mapped to the .nim sources, for gdb/lldb; the
    # host builds its code with the same -d:release it was built with, so they match
    if not defined(release):
      switch("debugger", "native")

    # the host and its code share one heap (libc's), so either may free what the other made
    if defined(hcrHost) or defined(hcrScript):
      switch("define", "useMalloc")

    if defined(hcrScript):
      # the code alone, loaded by the running host
      switch("app", "lib")
      switch("noMain", "on")
    elif defined(hcrHost):
      # export the host's own symbols (an engine it links) for the code to resolve against
      switch("passL", "-rdynamic")
      switch("nimcache", app.dir / "build" / variantDir("hot") / "nimcache")
      switch("define", "hcrBuildDir=" & app.dir / "build" / variantDir("hot") / "script")
    elif defined(release):
      switch("nimcache", app.dir / "build" / variantDir("release") / "nimcache")
    else:
      switch("nimcache", app.dir / "build" / variantDir("debug") / "nimcache")

  proc build*(app: HcrApp; variant: string) =
    ## builds a variant: hot, debug or release
    let flags =
      case variant
      of "hot": "-d:hcrHost "
      of "release": "-d:release "
      else: ""
    echo "Building " & app.name & " (" & variant & ")..."
    exec "nim c " & flags & "--out:" & quoteShell(app.exe(variant)) & " " &
         quoteShell(app.mainModule)

  proc run*(app: HcrApp; variant: string) =
    ## builds a variant and runs it, from the program's directory
    app.build(variant)
    withDir app.dir:
      exec quoteShell(app.exe(variant))

  template hcrTasks*(app: HcrApp; extra: openArray[HcrTarget] = []) =
    ## the tasks (see the top of this file); `extra` adds the program's own build targets
    ## to `nim build` (and to `all`): [("web", buildWeb)]
    task build, "Build: nim build hot|debug|release|all, or a target of the program's":
      let target = if paramCount() >= 2: paramStr(paramCount()) else: ""
      var known = false
      if target in ["hot", "debug", "release"]:
        app.build(target)
        known = true
      elif target == "all":
        for v in ["hot", "debug", "release"]: app.build(v)
        for (_, b) in extra: b()
        known = true
      else:
        for (name, b) in extra:
          if name == target:
            b()
            known = true
      if not known:
        var targets = "hot|debug|release"
        for (name, _) in extra: targets.add "|" & name
        quit "usage: nim build " & targets & "|all", 1

    task hot, "Build and run with hot reload": app.run("hot")
    task debug, "Build and run a debug build, no hot reload": app.run("debug")
    task release, "Build and run a release build": app.run("release")

    task clean, "Remove what the builds made (out/) and their work (build/)":
      rmDir(app.dir / "out")
      rmDir(app.dir / "build")
