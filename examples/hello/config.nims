# hotreload's hello: a console program that hot reloads, nothing else needed.
# src/main.nim is the main module, and src/hello.nim is reloaded.
#
#   nim hot       build and run with hot reload: edit src/hello.nim while it runs
#   nim debug     build and run a debug build, no hot reload
#   nim release   build and run a release build
#   nim clean     remove out/ and build/

# The stock nimlangserver checks a .nims with --import:system/nimscript, which makes every
# NimScript proc ambiguous: when that module is visible there is nothing here to check.
when not declared(nimscript):
  # hotreload, from this repo (an installed hotreload needs no path)
  switch("path", thisDir() & "/../../src")

  proc build(variant, flags: string) =
    ## builds and runs src/main.nim: out/<os>/<variant>/hello, its Nim cache in build/
    withDir thisDir():
      exec "nim c -r --hints:off " & flags & " --nimcache:build/" & hostOS & "/" & variant &
           " --out:out/" & hostOS & "/" & variant & "/hello src/main.nim"

  task hot, "Build and run with hot reload: edit src/hello.nim while it runs":
    build("hot", "-d:hotReload -d:useMalloc --debugger:native")
  task debug, "Build and run a debug build, no hot reload":
    build("debug", "--debugger:native")
  task release, "Build and run a release build":
    build("release", "-d:release")
  task clean, "Remove out/ and build/":
    withDir thisDir():
      rmDir "out"
      rmDir "build"
