# hotreload's hello: a console program that hot reloads, nothing else needed.
# src/main.nim is the program, src/hello.nim the code it reloads.
#
#   nim hot       build and run with hot reload: edit src/hello.nim while it runs
#   nim debug     build and run a debug build, no hot reload
#   nim release   build and run a release build
#   nim build hot|debug|release|all, nim clean

# The stock nimlangserver checks a .nims with --import:system/nimscript, which makes every
# NimScript proc ambiguous: when that module is visible there is nothing here to check.
when not declared(nimscript):
  from std/os import parentDir
  import "../../src/hotreload/tasks.nims"

  let target = BuildTarget(dir: currentSourcePath().parentDir, name: "hello")
  hotReloadConfig(target)
  hotReloadTasks(target)
