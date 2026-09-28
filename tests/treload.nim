## The smoke test: a real hot build, reloading while it runs. tests/reload/ is a small
## program (main.nim) and the code it reloads (code.nim); this copies them to
## build/tests/reload/, builds the program with hot reload, runs it, and edits its copy of
## the code while it runs, reading what the program prints.

import std/[os, osproc, strutils, times, unittest]
when defined(windows):
  import std/streams
else:
  import std/posix

const
  repoDir = currentSourcePath().parentDir.parentDir
  fixture = repoDir / "tests/reload"
  appDir = repoDir / "build/tests/reload"

type Running = object
  p: Process
  log: seq[string]   ## every line it printed, for a failure's report
  next: int          ## the first line of `log` not yet looked at
  partial: string    ## what's been read of a line not yet ended
  ended: bool

proc readable(r: Running; ms: int): bool =
  ## whether the program has printed something, waiting up to `ms` for it
  when defined(windows):
    # osproc's hasData only looks (PeekNamedPipe); a pipe the program closed counts, for
    # readSome to find it gone
    let deadline = epochTime() + ms / 1000
    while true:
      if r.p.hasData or not r.p.running: return true
      if epochTime() >= deadline: return false
      sleep 5
  else:
    # (osproc's hasData waits for as long as it takes)
    var fds = [TPollfd(fd: r.p.outputHandle.cint, events: POLLIN)]
    poll(addr fds[0], 1, ms.cint) > 0

proc readSome(r: var Running) =
  ## what the program has printed since, into `log`. Read from the pipe itself: a
  ## buffered reader takes in more than a line, and a check of the pipe (readable) then
  ## misses what it holds
  var buf: array[4096, char]
  when defined(windows):
    # the output stream is the pipe, unbuffered: a read takes what's there
    let n = if r.p.hasData: r.p.outputStream.readData(addr buf[0], buf.len) else: 0
  else:
    let n = read(r.p.outputHandle.cint, addr buf[0], buf.len)
  if n == 0:
    r.ended = true   # the program closed its output: it's gone
    return
  if n < 0:
    return           # nothing after all, or a signal came first (EAGAIN, EINTR): again
  for i in 0 ..< n:
    if buf[i] == '\n':
      r.log.add r.partial
      r.partial = ""
    else:
      r.partial.add buf[i]

proc waitFor(r: var Running; text: string; timeout = 30.0): string =
  ## the next line the program prints that has `text` in it ("" after `timeout` s)
  let deadline = epochTime() + timeout
  while true:
    while r.next < r.log.len:
      let line = r.log[r.next]
      inc r.next
      if text in line: return line
    if r.ended or epochTime() >= deadline: return ""
    if r.readable(20): r.readSome()

proc quiet(r: var Running; text: string; within: float): bool =
  ## no line with `text` in it for `within` s
  waitFor(r, text, within) == ""

proc countIn(line: string): int =
  ## the n of a "... count=n" line
  parseInt(line.split("count=")[1].strip)

proc edit(file, old, new: string) =
  let s = readFile(appDir / file)
  doAssert old in s, file & " has no " & old
  writeFile(appDir / file, s.replace(old, new))

suite "hot reload, while it runs":
  removeDir(appDir)
  createDir(appDir)
  for f in ["main.nim", "code.nim"]:
    copyFile(fixture / f, appDir / f)
  # its path with /: a Windows one's \ would be an escape
  writeFile(appDir / "config.nims", """
from std/os import parentDir
import "$1"
let target = BuildTarget(dir: currentSourcePath().parentDir, name: "app",
                         main: "main.nim", code: "code.nim")
hotReloadConfig(target)
""" % (repoDir / "src/hotreload/tasks.nims").replace('\\', '/'))

  let (output, code) = execCmdEx("nim c -d:hotReload --out:" & quoteShell(appDir / "app") &
                                 " main.nim", workingDir = appDir)
  if code != 0: echo output
  require code == 0

  var r = Running(p: startProcess(appDir / "app".addFileExt(ExeExt), workingDir = appDir,
                                  options = {poStdErrToStdOut}))

  teardown:
    if testStatusIMPL == TestStatus.FAILED:
      echo "  what the program printed:"
      for line in r.log: echo "    ", line

  test "it runs the code compiled in":
    check r.waitFor("report: v1 ring=true") != ""

  test "an edit to the code reloads: its hooks run, and hot globals are kept":
    edit("code.nim", "const Version = \"v1\"", "const Version = \"v2\"")
    # in this order: the old code's hook, the program's, the new code's, the program's
    let wrapUp = r.waitFor("beforeHotReload ")
    let before = r.waitFor("beforeReload count=")
    let fixUp = r.waitFor("afterHotReload ")
    let after = r.waitFor("afterReload count=")
    check "beforeHotReload v1 " in wrapUp   # the old code
    check "afterHotReload v2 " in fixUp     # the new
    check before != "" and after != ""
    if before != "" and after != "":
      check countIn(before) > 0
      check countIn(after) == countIn(before)  # the same storage: nothing ticked between
      check countIn(fixUp) == countIn(before)
    # the new code, and the ref graph (a cycle) it kept
    check r.waitFor("report: v2 ring=true") != ""

  test "a hot global's type changes: what still fits is carried over":
    edit("code.nim", "    count: int\n", "    count: int\n    extra: string = \"new\"\n")
    edit("code.nim", "$(ring.next.next == ring)", "$(ring.next.next == ring) & \" extra=\" & stats.extra")
    check r.waitFor("code.stats's type changed") != ""
    let after = r.waitFor("afterReload count=")
    check after != "" and countIn(after) > 0
    check r.waitFor("report: v2 ring=true extra=new") != ""

  test "a hot proc's signature changes: refused, and the last code runs on":
    edit("code.nim", "proc report*(): string", "proc report*(verbose = false): string")
    check r.waitFor("report's signature changed") != ""
    check r.quiet("afterReload", 2.0)
    edit("code.nim", "proc report*(verbose = false): string", "proc report*(): string")
    check r.waitFor("afterReload") != ""

  test "a build error keeps the last code, and fixing it reloads":
    edit("code.nim", "proc count*()", "this isn't Nim\nproc count*()")
    check r.waitFor("build failed") != ""
    edit("code.nim", "this isn't Nim\n", "")
    check r.waitFor("afterReload") != ""

  test "an edit to the program's main module doesn't rebuild":
    edit("main.nim", "sleep(10)", "sleep(10) # an edit")
    check r.quiet("building", 2.0)

  test "it quits when asked":
    writeFile(appDir / "quit", "")
    let deadline = epochTime() + 10
    while r.p.running and epochTime() < deadline: sleep 50
    check not r.p.running
    check r.p.peekExitCode == 0

  if r.p.running: r.p.kill()
  r.p.close()
  if programResult != 0 or getEnv("TRELOAD_LOG") == "1":
    echo "  what the program printed:"
    for line in r.log: echo "    ", line
