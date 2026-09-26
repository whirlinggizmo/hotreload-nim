# The example's tasks, run from here: `nim hot` is `cd simple && nim hot`.
#
# Nim reads this file for every build below it too (a parent directory's config), so it
# sets nothing for builds but hints off, and in simple/ its tasks step aside: a task sets
# the command to "nop" before it runs, so one run there puts it back for simple's own task
# to match.

# The stock nimlangserver checks a .nims with --import:system/nimscript, which `nim check`
# (nim.useNimCheck) turns into every NimScript proc twice, all ambiguous: when that module
# is visible, there is nothing here to check. A real run (nim build, a nim c config) never
# sees it, nor does the patched server (see .vscode/settings.json), which checks this file
# for real.
when not declared(nimscript):
  from std/os import `/`, parentDir, splitFile, quoteShell # what NimScript doesn't have already

  const thisDir = currentSourcePath().parentDir()

  # no hints for builds and tasks, but a check keeps them: `nim check` (the editor's, with
  # nim.useNimCheck) runs as "check", the patched nimsuggest as "idetools", the stock one
  # with none
  if getCommand() notin ["check", "idetools", ""]:
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

  task test, "Run the host's tests (tests/t*.nim)":
    # tests/config.nims has their settings; a test's own <test>.nims, any it needs more
    for f in listFiles(thisDir / "tests"):
      let (_, name, ext) = splitFile(f)
      if ext == ".nim" and name.len > 0 and name[0] == 't':
        exec "nim c -r --outdir:" & quoteShell(thisDir / "build/tests") & " " & quoteShell(f)
