## Hot procs and reload hooks: the procs a reload has to know about.
##
## `proc onTick*() {.hot.}` (reload.nim's `hot` passes a proc here, to hotProc): a proc the
## main module calls. The main module is compiled once, so its call would reach the
## version it was built with forever; in a hot build (-d:hotReload) the main module gets a
## stub by that name, which calls through a pointer that each reload points at the new
## library's version. The library exports it, and a hash of its signature, which the
## reloader checks before any new code runs. Everywhere else it's an ordinary proc. Only
## the procs the main module calls need it: calls within the library are all to the new
## code anyway.
##
## `proc fixUp() {.afterHotReload.}` and `proc wrapUp() {.beforeHotReload.}`: reload
## hooks, in the reloaded modules, which the reloader calls, after a reload on the new
## code, before one on the old. No parameters, no result; at most one of each per module,
## run in the order the modules start (their imports first). Everywhere but a hot build
## nothing calls them.

import std/[macros, tables]
import ./hotglobals

when defined(hotReload) or defined(hotReloadLibrary):
  import std/hashes

when defined(hotReload) or defined(hotReloadLibrary):
  # what {.hot.} makes a stub or an export from, in a hot build
  proc cName(key: string): string {.compileTime.} =
    ## a hot proc's symbol in the library
    result = "hotreload_"
    for c in key:
      result.add(if c in {'a'..'z', 'A'..'Z', '0'..'9'}: c else: '_')

  proc typeOf(d: NimNode): NimNode =
    ## a parameter's type: the one it's given, or its default value's
    if d[^2].kind != nnkEmpty: d[^2] else: newCall(ident"typeof", d[^1])

  proc paramTypes(params: NimNode): seq[NimNode] =
    ## each parameter's type, one per parameter
    for i in 1 ..< params.len:
      let d = params[i]
      for _ in 0 ..< d.len - 2:
        result.add typeOf(d)

  proc sigOfProc(params: NimNode): NimNode =
    ## an expression for the proc's signature, hashed: its parameters' types (var or not)
    ## and its result's, by their shape (typeSig)
    var parts = newLit("")
    proc part(t: NimNode): NimNode =
      if t.kind == nnkVarTy: infix(newLit("var "), "&", newCall(bindSym"typeSig", t[0]))
      else: newCall(bindSym"typeSig", t)
    for t in paramTypes(params):
      parts = infix(infix(parts, "&", part(t)), "&", newLit(";"))
    if params[0].kind != nnkEmpty:
      parts = infix(infix(parts, "&", newLit("->")), "&", part(params[0]))
    newCall(ident"static", newCall(bindSym"hash", parts))

when defined(hotReload):
  type Entry* = object
    key*: string          ## module.name
    cname*: string        ## its symbol in the library
    target*: ptr pointer  ## the stub's: what it calls
    sig*: int

  var entries*: seq[Entry]
    ## every hot proc the main module calls, for a reload to point at the new code

  proc registerEntry*(key, cname: string; target: ptr pointer; sig: int) =
    ## a hot proc's stub, for a reload to point at the new code (called as the executable
    ## starts, by what {.hot.} makes)
    entries.add Entry(key: key, cname: cname, target: target, sig: sig)

macro hotProc*(def: untyped): untyped =
  ## `proc p() {.hot.}`: a proc the main module calls, whose calls each reload points at
  ## the new code (reload.nim's `hot` passes a proc here)
  if def.kind notin {nnkProcDef, nnkFuncDef}:
    error("{.hot.}: a proc", def)
  if def[2].kind != nnkEmpty:
    error("{.hot.}: not a generic proc (a library can't export one)", def)
  if inMainModule(def):
    error("{.hot.} can't be used in the main module because the main module is never " &
          "hot reloaded. Use {.hot.} on the procs in the reloaded modules that the main " &
          "module calls.", def)
  when not (defined(hotReloadLibrary) or defined(hotReload)):
    result = def # an ordinary proc
  else:
    let base = if def[0].kind == nnkPostfix: def[0][1] else: def[0]
    let key = moduleKey(def) & "." & $base
    let cname = cName(key)
    let sig = sigOfProc(def.params)

    when defined(hotReloadLibrary):
      # the proc, under its symbol, and its signature, for the executable to check first
      result = newStmtList(def)
      def.addPragma ident"cdecl"
      def.addPragma newColonExpr(ident"exportc", newLit(cname))
      def.addPragma ident"dynlib"
      let sigProc = genSym(nskProc, $base & "Sig")
      result.add quote do:
        proc `sigProc`(): int {.cdecl, exportc: `cname` & "_sig", dynlib.} = `sig`
    elif defined(hotReload):
      # the stub: the main module's name for it, which calls through `target`. At first
      # that's the version compiled into the executable; a swap points it at the new
      # library's
      let impl = copyNimTree(def)
      impl[0] = genSym(nskProc, $base & "Impl")
      impl.addPragma ident"cdecl"
      var procTy = newNimNode(nnkProcTy)
      var tyParams = copyNimTree(def.params)
      for i in 1 ..< tyParams.len:
        # a proc type has no default values, so the type is spelled out
        tyParams[i][^2] = typeOf(tyParams[i])
        tyParams[i][^1] = newEmptyNode()
      procTy.add tyParams
      procTy.add nnkPragma.newTree(ident"cdecl")
      let target = ident($base & "HotTarget")
      var call = newCall(target)
      for i in 1 ..< def.params.len:
        for j in 0 ..< def.params[i].len - 2:
          call.add def.params[i][j]
      let stub = copyNimTree(def)
      stub.body = newStmtList(call)
      let forward = copyNimTree(def)
      forward.body = newEmptyNode()
      let implName = impl[0]
      let register = bindSym"registerEntry"
      result = newStmtList(forward, impl)
      result.add quote do:
        var `target`: `procTy` = `implName`
        `register`(`key`, `cname`, cast[ptr pointer](addr `target`), `sig`)
      result.add stub

type HookKind* = enum
  hookBefore  ## {.beforeHotReload.}
  hookAfter   ## {.afterHotReload.}

when defined(hotReload) or defined(hotReloadLibrary):
  type Hook = proc () {.cdecl.}

when defined(hotReloadLibrary):
  # the executable's, which it exports (-rdynamic; on Windows, its import library)
  proc registerHook(kind: cint; hook: Hook) {.importc: "hotreload_hook", cdecl.}

elif defined(hotReload):
  var hooks: array[HookKind, seq[Hook]]
    ## the running code's hooks: those compiled into the executable, then each library's

  proc registerHook(kind: cint; hook: Hook) {.exportc: "hotreload_hook", cdecl, dynlib.} =
    ## a hook, as its module starts (compiled into the executable, as it starts; a
    ## library's, in its NimMain)
    hooks[HookKind(kind)].add hook

  proc runHooks*(kind: HookKind) =
    for hook in hooks[kind]: hook()

  proc forgetHooks*() =
    ## before a library starts, which registers its own
    for kind in HookKind: hooks[kind].setLen 0

var hooksSeen {.compileTime.}: Table[string, string]
  ## module and kind: the hook it has, for a second one's error

proc hookDef(def: NimNode; kind: HookKind; pragma: string): NimNode =
  if def.kind notin {nnkProcDef, nnkFuncDef}:
    error("{." & pragma & ".}: a proc", def)
  # the main module would register its hooks once, as it starts, and the first reload
  # forget them (forgetHooks) with the old code's: it has the reloader's callbacks instead
  if inMainModule(def):
    let callback = if kind == hookBefore: "beforeReload" else: "afterReload"
    error("{." & pragma & ".} can't be used in the main module because the main module " &
          "is never hot reloaded. Set `reloader." & callback & " = proc () = ...` in the " &
          "main module instead.", def)
  if def.params.len > 1 or def.params[0].kind != nnkEmpty:
    error("{." & pragma & ".}: a proc with no parameters and no result", def)
  let key = def.lineInfoObj.filename & "|" & $kind
  if key in hooksSeen:
    error("{." & pragma & ".}: this module has one already, " & hooksSeen[key] &
          ": one per module (call the rest from it)", def)
  let base = if def[0].kind == nnkPostfix: def[0][1] else: def[0]
  hooksSeen[key] = $base & " (line " & $def.lineInfoObj.line & ")"
  when defined(hotReload) or defined(hotReloadLibrary):
    def.addPragma ident"cdecl"
    let register = bindSym"registerHook"
    result = newStmtList(def)
    result.add quote do:
      `register`(cint(`kind`), `base`)
  else:
    result = def

macro beforeHotReload*(def: untyped): untyped =
  ## `proc wrapUp() {.beforeHotReload.}`: the reloader calls it just before a reload, on
  ## the old code (see the module's doc)
  hookDef(def, hookBefore, "beforeHotReload")

macro afterHotReload*(def: untyped): untyped =
  ## `proc fixUp() {.afterHotReload.}`: the reloader calls it just after a reload, on the
  ## new code (see the module's doc)
  hookDef(def, hookAfter, "afterHotReload")
