# wgrender's simple example, hot reloaded: src/main.nim is the main module, and
# src/simple.nim is reloaded.
#
#   nim hot       build and run with hot reload: edit src/simple.nim while it runs
#   nim debug     build and run a debug build, no hot reload (breakpoints never go stale)
#   nim release   build and run a release build
#   nim clean     remove out/ and build/
#
#   nim web       build it for the web: out/web/<variant>/simple.js and simple.wasm, and
#                 the assets' manifests (examples/tools/manifest.nim)
#   nim serve     serve the build with the examples' page (examples/www/) and assets
#                 (examples/assets/) on http://localhost:8000 (examples/tools/serve.nim)
#
# wgrender: the installed package (nimble install https://github.com/whirlinggizmo/wgrender-nim),
# or a wgrender-nim checkout at WGRENDER_NIM, when you're working on wgrender too. The
# assets are the examples' own, in examples/assets/ (copies of wgrender's; licenses in
# CREDITS.md). Web options, as wgrender-nim reads them:
#   BACKEND=webgl2|webgpu   WEB_THREADS=1|0   WEB_DEBUG=0|1

# The stock nimlangserver checks a .nims with --import:system/nimscript, which `nim check`
# (nim.useNimCheck) turns into every NimScript proc twice, all ambiguous: when that module
# is visible, there is nothing here to check. A real run (nim build, a nim c config) never
# sees it, nor does a server that leaves that import out, which checks this file for real.
when not declared(nimscript):
  # what NimScript doesn't have already (it has getEnv, fileExists, findExe, mkDir, ...)
  from std/os import `/`, parentDir, quoteShell, relativePath
  from std/strutils import splitLines, strip

  const thisDir = currentSourcePath().parentDir()
  const mainModule = thisDir / "src" / "main.nim"
  # hotreload, from this repo (an installed hotreload needs no path)
  switch("path", thisDir / ".." / ".." / "src")

  proc installedWgrender(): string =
    ## where nimble installed wgrender, or "" (its last line: nimble may warn first)
    let (output, code) = gorgeEx("nimble path wgrender")
    if code == 0: output.strip.splitLines[^1] else: ""

  let wgrNim =
    if getEnv("WGRENDER_NIM").len > 0: getEnv("WGRENDER_NIM")
    else: installedWgrender()
  if wgrNim.len == 0 and getCommand() in ["c", "compile"]:
    quit "simple needs wgrender: nimble install https://github.com/whirlinggizmo/wgrender-nim " &
         "(or WGRENDER_NIM=<a wgrender-nim checkout>)"
  # the binding: a checkout's src/, or the package itself
  let wgrSrc = if dirExists(wgrNim / "src"): wgrNim / "src" else: wgrNim

  # the examples' web page (examples/www/) and assets (examples/assets/), which `nim serve`
  # serves beside a web build. The assets are copies of wgrender's example assets, with
  # their licenses (assets/CREDITS.md)
  const wwwDir = thisDir.parentDir / "www"
  const assetsDir = thisDir.parentDir / "assets"

  proc webVariant(): string =
    ## web/<variant>, from the web settings (threaded unless WEB_THREADS=0)
    result = "web/" & (if getEnv("BACKEND").len > 0: getEnv("BACKEND") else: "webgl2")
    if getEnv("WEB_THREADS", "1") == "0": result.add "-nothreads"
    if getEnv("WEB_DEBUG", "0") == "1": result.add "-debug"

  switch("path", wgrSrc)

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
    # wgrender comes from the executable that loads the library
    switch("define", "wgrDeclarationsOnly")
  else:
    switch("define", "wgrAssetBase=" & assetsDir)

  proc buildWeb() =
    echo "Building simple (web)..."
    let site = thisDir / "out" / webVariant()
    mkDir(site)
    exec "nim c --hints:off -d:emscripten --out:" & quoteShell(site / "simple.js") & " " &
         quoteShell(mainModule)
    # the assets' manifests, so the page fetches only what changed (unchanged ones stay)
    exec "nim r --hints:off " & quoteShell(thisDir.parentDir / "tools/manifest.nim") & " " &
         quoteShell(assetsDir)
    echo "built " & relativePath(site, thisDir) & " — `nim serve`, then open " &
         "http://localhost:8000/"

  proc build(variant, flags: string) =
    ## builds and runs src/main.nim: out/<os>/<variant>/simple, its Nim cache in build/
    let variantDir = hostOS & "/" & variant
    exec "nim c -r --hints:off " & flags & " --nimcache:" &
         quoteShell(thisDir / "build" / variantDir) & " --out:" &
         quoteShell(thisDir / "out" / variantDir / "simple") & " " & quoteShell(mainModule)

  task hot, "Build and run with hot reload: edit src/simple.nim while it runs":
    build("hot", "-d:hotReload -d:useMalloc --debugger:native")
  task debug, "Build and run a debug build, no hot reload":
    build("debug", "--debugger:native")
  task release, "Build and run a release build":
    build("release", "-d:release")
  task clean, "Remove out/ and build/":
    rmDir thisDir / "out"
    rmDir thisDir / "build"

  task web, "Build for the web, simple.nim compiled in":
    buildWeb()

  task serve, "Serve the web build and the examples' page on http://localhost:8000":
    withDir thisDir.parentDir / "tools":
      exec "nim r --hints:off serve.nim 8000 " & quoteShell(thisDir / "out" / webVariant()) &
           " " & quoteShell(wwwDir) & " " & quoteShell("/assets=" & assetsDir)
