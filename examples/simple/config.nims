# wgrender's simple example, hot reloaded: src/main.nim is the program, src/simple.nim the
# code it reloads. hotreload's tasks (src/hotreload/tasks.nims):
#
#   nim build hot|debug|release|web|all
#   nim hot       build and run with hot reload: edit src/simple.nim while it runs
#   nim debug     build and run a debug build, no hot reload (breakpoints never go stale)
#   nim release   build and run a release build
#   nim clean     remove out/ and build/
#
# and wgrender's web build, here:
#
#   nim web       build it for the web: out/web/<variant>/ with simple.js + simple.wasm
#                 and wgrender-nim's page
#   nim serve     serve the web build on http://localhost:8000 (assets at /assets)
#
# wgrender-nim: WGRENDER_NIM, else ~/projects/github/whirlinggizmo/wgrender-nim; the web
# build uses its page and tools. Web options, as wgrender-nim reads them:
#   BACKEND=webgl2|webgpu   WEB_THREADS=1|0   WEB_DEBUG=0|1

# The stock nimlangserver checks a .nims with --import:system/nimscript, which `nim check`
# (nim.useNimCheck) turns into every NimScript proc twice, all ambiguous: when that module
# is visible, there is nothing here to check. A real run (nim build, a nim c config) never
# sees it, nor does a server that leaves that import out, which checks this file for real.
when not declared(nimscript):
  # what NimScript doesn't have already (it has getEnv, fileExists, findExe, mkDir, ...)
  from std/os import `/`, parentDir, getHomeDir, quoteShell, relativePath
  import "../../src/hotreload/tasks.nims"

  const thisDir = currentSourcePath().parentDir()
  let target = BuildTarget(dir: thisDir, name: "simple")
  hotReloadConfig(target)

  let wgrNim = getEnv("WGRENDER_NIM", getHomeDir() / "projects/github/whirlinggizmo/wgrender-nim")
  let wgrenderDir =
    if getEnv("WGRENDER_DIR").len > 0: getEnv("WGRENDER_DIR")
    elif fileExists(wgrNim / "../wgrender-c/include/wgr.h"): wgrNim / "../wgrender-c"
    else: wgrNim / "project/lib/wgrender-c"

  proc webVariant(): string =
    ## web/<variant>, from the web settings (threaded unless WEB_THREADS=0)
    result = "web/" & (if getEnv("BACKEND").len > 0: getEnv("BACKEND") else: "webgl2")
    if getEnv("WEB_THREADS", "1") == "0": result.add "-nothreads"
    if getEnv("WEB_DEBUG", "0") == "1": result.add "-debug"

  switch("path", wgrNim / "src")

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
  elif defined(hotReloadLibrary):
    # wgrender comes from the host that loads the code
    switch("define", "wgrDeclarationsOnly")
  else:
    switch("define", "wgrAssetBase=" & wgrenderDir / "examples/assets")

  proc python(): string =
    if findExe("python3").len > 0: "python3" else: "python"

  proc buildWeb() =
    echo "Building simple (web)..."
    let site = thisDir / "out" / webVariant()
    mkDir(site)
    exec "nim c -d:emscripten --out:" & quoteShell(site / "simple.js") & " " &
         quoteShell(target.mainModule)
    # wgrender-nim's page opens "simple" first, which is this program's name too
    exec python() & " " & quoteShell(wgrNim / "tools/webdeploy.py") & " " & site.quoteShell &
         " " & quoteShell(wgrNim / "web/index.html")
    echo "built " & relativePath(site, thisDir) & " — `nim serve`, then open http://localhost:8000/"

  hotReloadTasks(target, [("web", buildWeb)])

  task web, "Build for the web, simple.nim compiled in":
    buildWeb()

  task serve, "Serve the web build on http://localhost:8000":
    exec python() & " " & quoteShell(wgrNim / "tools/serve.py") & " 8000 " &
         quoteShell(thisDir / "out" / webVariant()) & " --assets " &
         quoteShell(wgrenderDir / "examples/assets") & " --gzip"
