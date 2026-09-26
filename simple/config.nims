# wgrender's simple example with its app code hot-reloaded.
#
#   nim build hot|debug|release|web|all
#                 build without running: one of the four below, or all of them
#   nim hot       build and run the host with hot reload (-d:hcrHost, a debug build):
#                 out/linux/hot/simple. Edit src/simple.nim while it runs and the host
#                 rebuilds it into build/linux/hot/script/ and swaps it in
#   nim debug     build and run a debug build with simple.nim compiled in, no hot reload:
#                 out/linux/debug/simple (breakpoints never go stale)
#   nim release   build and run a release build with simple.nim compiled in:
#                 out/linux/release/simple
#   nim web       build it for the web, simple.nim compiled in: out/web/<variant>/ with
#                 simple.js + simple.wasm and wgrender-nim's page
#   nim serve     serve the web build on http://localhost:8000 (assets at /assets)
#   nim clean     remove out/ (what the builds made) and build/ (their work)
#
# The layout is wgrender-nim's: what a build makes in out/<platform>/<variant>/, its work
# (Nim's cache) in build/<platform>/<variant>/.
#
# wgrender-nim: WGRENDER_NIM, else ~/projects/github/whirlinggizmo/wgrender-nim; the web
# build uses its page and tools. Web options, as wgrender-nim reads them:
#   BACKEND=webgl2|webgpu   WEB_THREADS=1|0   WEB_DEBUG=0|1
# Scripts are built by the host with -d:hcrScript, which this file also answers.

# The stock nimlangserver checks a .nims with --import:system/nimscript, which makes every
# NimScript proc ambiguous (and crashes nimsuggest): when that module is visible, there is
# nothing here to check. A real run (nim build, a nim c config) never sees it, nor does the
# patched server (see .vscode/settings.json), which checks this file for real.
when not declared(nimscript):
  # what NimScript doesn't have already (it has getEnv, fileExists, findExe, mkDir, ...)
  from std/os import `/`, parentDir, getHomeDir, quoteShell, relativePath

  const thisDir = currentSourcePath().parentDir()

  let wgrNim = getEnv("WGRENDER_NIM", getHomeDir() / "projects/github/whirlinggizmo/wgrender-nim")
  let wgrenderDir =
    if getEnv("WGRENDER_DIR").len > 0: getEnv("WGRENDER_DIR")
    elif fileExists(wgrNim / "../wgrender-c/include/wgr.h"): wgrNim / "../wgrender-c"
    else: wgrNim / "project/lib/wgrender-c"

  proc desktopPlatform(): string =
    when defined(windows): "windows"
    elif defined(macosx): "macos"
    else: "linux"

  proc hotVariant(): string = desktopPlatform() / "hot"

  proc debugVariant(): string = desktopPlatform() / "debug"

  proc releaseVariant(): string = desktopPlatform() / "release"

  proc webVariant(): string =
    ## web/<variant>, from the web settings (threaded unless WEB_THREADS=0)
    result = "web/" & (if getEnv("BACKEND").len > 0: getEnv("BACKEND") else: "webgl2")
    if getEnv("WEB_THREADS", "1") == "0": result.add "-nothreads"
    if getEnv("WEB_DEBUG", "0") == "1": result.add "-debug"

  switch("hints", "off")
  switch("path", wgrNim / "src")
  switch("path", thisDir / "../host")

  if defined(emscripten):
    # one program, simple.nim compiled in: there is no hot reload on the web
    switch("nimcache", thisDir / "build" / webVariant() / "nimcache")
    switch("os", "linux")
    switch("cpu", "wasm32")
    switch("cc", "clang")
    switch("clang.exe", when defined(windows): "emcc.bat" else: "emcc")
    switch("clang.linkerexe", when defined(windows): "emcc.bat" else: "emcc")
    switch("define", "noSignalHandler")
    switch("define", "useMalloc")
    # Nim code only runs on the main thread; wgrender's workers are its own
    switch("threads", "off")
    if getEnv("WEB_DEBUG", "0") != "1":
      switch("define", "release")
      switch("clang.options.linker", "")
  else:
    # debug builds carry DWARF line info mapped to the .nim sources, for gdb/lldb; the host
    # builds its scripts with the same -d:release it was built with, so they match
    if not defined(release):
      switch("debugger", "native")

    # the host and its scripts share one heap (libc's), so either may free what the other made
    if defined(hcrHost) or defined(hcrScript):
      switch("define", "useMalloc")

    if defined(hcrScript):
      # wgrender comes from the host that loads it
      switch("define", "wgrDeclarationsOnly")
      switch("app", "lib")
      switch("noMain", "on")
    else:
      switch("define", "wgrAssetBase=" & wgrenderDir / "examples/assets")
      if defined(hcrHost):
        switch("passL", "-rdynamic") # export wgr_* for the scripts to resolve against
        switch("nimcache", thisDir / "build" / hotVariant() / "nimcache")
        switch("define", "hcrBuildDir=" & thisDir / "build" / hotVariant() / "script")
      elif defined(release):
        switch("nimcache", thisDir / "build" / releaseVariant() / "nimcache")
      else:
        switch("nimcache", thisDir / "build" / debugVariant() / "nimcache")

  proc python(): string =
    if findExe("python3").len > 0: "python3" else: "python"

  proc hotExe(): string = thisDir / "out" / hotVariant() / "simple"

  proc debugExe(): string = thisDir / "out" / debugVariant() / "simple"

  proc releaseExe(): string = thisDir / "out" / releaseVariant() / "simple"

  proc buildHot() =
    echo "Building HCR enabled target..."
    exec "nim c -d:hcrHost --out:" & quoteShell(hotExe()) & " " & quoteShell(thisDir / "src/simple.nim")

  proc buildDebug() =
    echo "Building debug target..."
    exec "nim c --out:" & quoteShell(debugExe()) & " " & quoteShell(thisDir / "src/simple.nim")

  proc buildRelease() =
    echo "Building release target..."
    exec "nim c -d:release --out:" & quoteShell(releaseExe()) & " " &
         quoteShell(thisDir / "src/simple.nim")

  proc buildWeb() =
    echo "Building wasm target..."
    let site = thisDir / "out" / webVariant()
    mkDir(site)
    exec "nim c -d:emscripten --out:" & quoteShell(site / "simple.js") & " " &
         quoteShell(thisDir / "src/simple.nim")
    # wgrender-nim's page opens "simple" first, which is this program's name too
    exec python() & " " & quoteShell(wgrNim / "tools/webdeploy.py") & " " & site.quoteShell &
         " " & quoteShell(wgrNim / "web/index.html")
    echo "built " & relativePath(site, thisDir) & " — `nim serve`, then open http://localhost:8000/"

  task build, "Build: nim build hot|debug|release|web|all":
    let target = if paramCount() >= 2: paramStr(paramCount()) else: ""
    case target
    of "hot": buildHot()
    of "debug": buildDebug()
    of "release": buildRelease()
    of "web": buildWeb()
    of "all":
      buildHot()
      buildDebug()
      buildRelease()
      buildWeb()
    else:
      quit "usage: nim build hot|debug|release|web|all", 1

  task hot, "Build and run with hot reload":
    buildHot()
    exec quoteShell(hotExe())

  task debug, "Build and run a debug build with simple.nim compiled in, no hot reload":
    buildDebug()
    exec quoteShell(debugExe())

  task release, "Build and run a release build with simple.nim compiled in":
    buildRelease()
    exec quoteShell(releaseExe())

  task web, "Build for the web, simple.nim compiled in":
    buildWeb()

  task serve, "Serve the web build on http://localhost:8000":
    exec python() & " " & quoteShell(wgrNim / "tools/serve.py") & " 8000 " &
         quoteShell(thisDir / "out" / webVariant()) & " --assets " &
         quoteShell(wgrenderDir / "examples/assets") & " --gzip"

  task clean, "Remove build outputs":
    rmDir(thisDir / "out")
    rmDir(thisDir / "build")
