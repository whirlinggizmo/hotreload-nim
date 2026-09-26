# The example's tasks, run from here: `nim hot` is `cd simple && nim hot`.
#
# Nim reads this file for every build below it too (a parent directory's config), so it
# sets nothing for builds, and in simple/ its tasks step aside: a task sets the command
# to "nop" before it runs, so one run there puts it back for simple's own task to match.

import std/os

const thisDir = currentSourcePath().parentDir()

switch("hints", "off")


proc inSimple(t: string; args = "") =
  if getCurrentDir() != thisDir:
    setCommand t
    return
  withDir thisDir / "simple":
    exec "nim " & t & (if args.len > 0: " " & args else: "")

task build, "Build simple: nim build hot|debug|release|web|all":
  inSimple "build", (if paramCount() >= 2: paramStr(paramCount()) else: "")

task hot, "Build and run simple with hot reload": inSimple "hot"
task debug, "Build and run simple's debug build, no hot reload": inSimple "debug"
task release, "Build and run simple's release build": inSimple "release"
task web, "Build simple for the web": inSimple "web"
task serve, "Serve simple's web build on http://localhost:8000": inSimple "serve"
task clean, "Remove simple's build outputs": inSimple "clean"
