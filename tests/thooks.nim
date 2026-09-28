## The pragmas' rules, checked where they're enforced: at compile time. Each case is
## a small program in build/tests/hooks/, compiled with `nim c --compileOnly` (its checks,
## no C compiler).

import std/[os, osproc, strutils, unittest]

const
  repoDir = currentSourcePath().parentDir.parentDir
  dir = repoDir / "build/tests/hooks"

proc nimCompile(files: openArray[(string, string)]; command = "c --compileOnly"):
    tuple[ok: bool, output: string] =
  ## `nim <command>` of the first of `files`, all written to `dir` first
  removeDir(dir)
  createDir(dir)
  for (name, text) in files:
    writeFile(dir / name, text)
  let (output, code) = execCmdEx("nim " & command & " --hints:off -d:hotReload -d:useMalloc " &
                                 "--nimcache:nimcache --path:" & quoteShell(repoDir / "src") &
                                 " " & files[0][0], workingDir = dir)
  (code == 0, output)

suite "reload hooks":
  test "one of each per module, in as many modules as like":
    let (ok, output) = nimCompile([
      ("main.nim", "import ./game\n"),
      ("game.nim", "import hotreload, ./other\n" &
                   "proc a() {.beforeHotReload.} = discard\n" &
                   "proc b() {.afterHotReload.} = discard\n"),
      ("other.nim", "import hotreload\n" &
                    "proc c() {.afterHotReload.} = discard\n")])
    check ok
    if not ok: echo output

  test "a second in a module doesn't compile, and says where the first is":
    let (ok, output) = nimCompile([
      ("main.nim", "import ./game\n"),
      ("game.nim", "import hotreload\n" &
                   "proc first() {.afterHotReload.} = discard\n" &
                   "proc second() {.afterHotReload.} = discard\n")])
    check not ok
    check "this module has one already, first (line 2)" in output

  test "a hook takes nothing and gives nothing":
    let (ok, output) = nimCompile([
      ("main.nim", "import ./game\n"),
      ("game.nim", "import hotreload\n" &
                   "proc fixUp(n: int) {.afterHotReload.} = discard\n")])
    check not ok
    check "no parameters and no result" in output

  test "not in the main module: the reloader's callbacks instead":
    for (pragma, callback) in [("beforeHotReload", "beforeReload"),
                               ("afterHotReload", "afterReload")]:
      let (ok, output) = nimCompile([
        ("main.nim", "import hotreload\n" &
                     "proc hook() {." & pragma & ".} = discard\n")])
      check not ok
      check "{." & pragma & ".} can't be used in the main module" in output
      check "reloader." & callback & " = proc () = ..." in output

suite "{.hot.}":
  test "not in the main module, on a global or a proc":
    for code in ["var count {.hot.} = 0\n", "proc tick() {.hot.} = discard\n"]:
      let (ok, output) = nimCompile([("main.nim", "import hotreload\n" & code)])
      check not ok
      check "{.hot.} can't be used in the main module because the main module is never " &
            "hot reloaded" in output

  test "an editor's check of a reloaded module on its own: no main module to be in":
    # the file an editor checks is the project, but not a main module
    for command in ["check", "c --compileOnly"]:
      let (ok, output) = nimCompile([("game.nim", "import hotreload\n" &
                                                  "var count {.hot.} = 0\n" &
                                                  "proc tick() {.hot.} = discard\n")],
                                    command)
      check ok == (command == "check")
      if command == "check" and not ok: echo output
