# The examples' tasks, run from here. `nim hot simple` runs simple's own `nim hot`, in
# examples/simple. Each example keeps its own config.nims and tasks. These tasks only find
# the example and run its task there.
#
#   nim hot|debug|release|clean <example>
#   nim build <example> hot|debug|release|all
#   nim web|serve simple
#   nim build all [hot|debug|release]    each example that has a build task, with all its
#                                        variants unless one is named
#   nim clean all                        each example's clean
#
# What follows the example's name, options too, goes to the example's task.
#
# Nim reads this file for every compile in the examples' directories, because it's in a
# parent directory of theirs. As such, it has tasks and nothing else: a switch here would
# change every example's build. Its tasks would also hide an example's own tasks of the
# same name. So each example's task runs in a new nim with --skipParentCfg, which leaves
# this file out. In an example's directory, `nim hot` with no example named runs that
# example's task.

when not declared(nimscript):
  # a failed example task ends this one with quit(), which Nim would announce
  {.hint[QuitCalled]: off.}
  from std/os import `/`, getCurrentCompilerExe, lastPathPart, parentDir, quoteShell
  from std/strutils import join, splitLines, splitWhitespace, startsWith

  const examplesDir = currentSourcePath().parentDir()

  proc examples(): seq[string] =
    ## the examples: the directories here with a config.nims
    for dir in listDirs(examplesDir):
      if fileExists(dir / "config.nims"): result.add dir.lastPathPart

  proc tasksOf(example: string): seq[string] =
    ## the example's tasks, as its `nim help` lists them. gorgeEx runs where this file is,
    ## not in withDir's directory, so the command changes directory itself
    let cd = when defined(windows): "cd /d " else: "cd "
    let nim = quoteShell(getCurrentCompilerExe())
    let (output, _) = gorgeEx(cd & quoteShell(examplesDir / example) & " && " & nim &
                              " --skipParentCfg --hints:off help")
    for line in output.splitLines:
      let words = line.splitWhitespace
      if words.len > 1 and line[0] != ' ': result.add words[0]

  proc run(example, name: string; args: seq[string]): bool =
    ## runs the example's task `name` in its directory, with the same nim as this one
    ## (selfExec), not whichever is first on PATH. Whether it succeeded: when it fails, it
    ## has said why, so this adds nothing
    withDir examplesDir / example:
      try:
        let rest = if args.len > 0: " " & args.join(" ") else: ""
        selfExec "--skipParentCfg " & name & rest
        result = true
      except OSError:
        result = false

  proc forward(name: string) =
    ## runs the example's task `name`, with what follows the example's name
    var args: seq[string]
    var after = false
    for i in 1 .. paramCount():
      let p = paramStr(i)
      if after: args.add p
      elif p == name: after = true
    # the example's name: the first argument that isn't an option
    var at = -1
    for i, a in args:
      if not a.startsWith("-"):
        at = i
        break
    let named = if at >= 0: args[at] else: ""

    # every example that has the task, carrying on past one that fails
    if named == "all":
      var rest = args
      rest.delete(at)
      if name == "build" and rest.len == 0: rest = @["all"]
      var failed: seq[string]
      for example in examples():
        if name notin tasksOf(example):
          echo "== " & example & ": no " & name & " task, skipped"
          continue
        echo "== " & example
        if not run(example, name, rest): failed.add example
      if failed.len > 0:
        quit "failed: " & failed.join(", "), 1
      return

    # the example: named, or the one whose directory this is in
    var example = ""
    if named in examples():
      example = named
      args.delete(at)
    else:
      var dir = getCurrentDir()
      while dir.len > examplesDir.len:
        if dir.parentDir == examplesDir: example = dir.lastPathPart
        dir = dir.parentDir
    if example.len == 0:
      quit "usage: nim " & name & " <example> ...: one of " & examples().join(", "), 1
    if not run(example, name, args): quit 1

  task hot, "Build and run an example with hot reload: nim hot <example>": forward("hot")
  task debug, "Build and run an example's debug build: nim debug <example>":
    forward("debug")
  task release, "Build and run an example's release build: nim release <example>":
    forward("release")
  task build, "Build an example without running it: nim build <example> <variant>|all":
    forward("build")
  task clean, "Remove an example's out/ and build/: nim clean <example>": forward("clean")
  task web, "Build an example for the web: nim web simple": forward("web")
  task serve, "Serve an example's web build: nim serve simple": forward("serve")
