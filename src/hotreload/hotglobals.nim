## Globals that survive a reload: `var enemies {.hot.}: seq[Enemy]`, or with a first value,
## `var speed {.hot.} = 1.0`. In a hot build the program keeps each one, by its module (its
## path from the code's directory: `player/state.speed`) and name, and every library that
## loads is handed the one that's there: its first value is used once, when it's first
## made. When a reload changes its type, what still fits is carried over (migrate.nim)
## and the rest starts from the first value. Everywhere else (debug, release, web) it's an
## ordinary global.
##
## A type change is found from the type itself (typeSig): fields, their types, and the
## types inside those, not the source, so a comment or a proc next to it changes nothing.
##
## One that holds refs is carried over on every reload, changed or not: each library has
## its own Nim runtime, and a ref belongs to the one that made it (its cycle collector
## keeps track of it), so the new code gets its own copy (migrate.nim copies the graph;
## in place, quicker, when the type hasn't changed).
##
## Old code still around after a reload (a callback from before it) keeps the storage it
## had: after a type change that's the old copy, so what it writes there is lost, not
## corrupting.

import std/[hashes, macros]
when defined(hotReload) or defined(hotReloadLibrary):
  import std/[compilesettings, os, strutils]
import ./[migrate, typesig]
export migrate, typesig, hashes

const hotReloadCode* {.strdefine.} = ""
  ## the code's module, which a hot build rebuilds as a library (hotReloadConfig sets it)

proc moduleKey*(n: NimNode): string {.compileTime.} =
  ## where `n` is: its module's path from the code's directory, without the extension
  ## (`player/state`). The program and each library are built with the same code module,
  ## so each makes the same key (without one, a test's: its main module's directory); by
  ## path, so two modules with one name in different directories don't share
  when defined(hotReload) or defined(hotReloadLibrary):
    let root = if hotReloadCode.len > 0: hotReloadCode.parentDir
               else: querySetting(projectPath)
    n.lineInfoObj.filename.changeFileExt("").relativePath(root).replace('\\', '/')
  else:
    ""

when defined(hotReload) or defined(hotReloadLibrary):
  type
    HotMake = proc (): pointer {.cdecl.}
    HotSave = proc (p: pointer): string {.cdecl.}
    HotLoad = proc (p: pointer; data: string) {.cdecl.}
    HotCopy = proc (old: pointer): pointer {.cdecl.}

when defined(hotReloadLibrary):
  # the program's, which it exports (-rdynamic)
  proc hotSlot(key: cstring; stamp: int; refs: bool; make: HotMake; save: HotSave;
               load: HotLoad; copy: HotCopy): pointer {.importc: "hotreload_slot", cdecl.}
  proc hotreloadMoves(): int {.importc: "hotreload_moves", cdecl.}

  proc hotMoves*(): int = hotreloadMoves()
    ## how many times a hot global has moved to new storage (a reload carried it over):
    ## read it when you hand out a callback, and again when it runs. If it changed, the
    ## callback is from older code, and what it writes to hot globals may go to an old
    ## copy: skip it (ask again)

elif defined(hotReload):
  import std/tables

  type HotSlot = object
    stamp: int       ## its type, hashed (typeSig)
    data: pointer
    save: HotSave    ## the latest library's, which knows `data`'s type

  var hotSlots: Table[string, HotSlot]
  var moves: int

  proc hotreloadMoves(): int {.exportc: "hotreload_moves", cdecl, dynlib.} = moves

  proc hotMoves*(): int = moves
    ## how many times a hot global has moved to new storage (see the library build's)

  proc hotSlot*(key: cstring; stamp: int; refs: bool; make: HotMake; save: HotSave;
                load: HotLoad; copy: HotCopy): pointer {.exportc: "hotreload_slot", cdecl,
                                                         dynlib.} =
    ## the storage for a hot global: made the first time, and made again, with what still
    ## fits carried over, when a library has it with another type or it holds refs. The
    ## old storage isn't freed: old code may still write to it
    let k = $key
    if k notin hotSlots:
      hotSlots[k] = HotSlot(stamp: stamp, data: make(), save: save)
    elif hotSlots[k].stamp != stamp:
      let old = hotSlots[k]
      let data = make()
      load(data, old.save(old.data))
      hotSlots[k] = HotSlot(stamp: stamp, data: data, save: save)
      inc moves
      echo "hotreload: " & k & "'s type changed; carried over what still fits"
    elif refs:
      hotSlots[k] = HotSlot(stamp: stamp, data: copy(hotSlots[k].data), save: save)
      inc moves
    else:
      hotSlots[k].save = save
    hotSlots[k].data

  proc hotKeys*(): seq[string] =
    ## the hot globals the program keeps, by key
    for k in hotSlots.keys: result.add k

else:
  proc hotMoves*(): int = 0
    ## nothing moves outside a hot build

macro hotGlobal*(def: untyped): untyped =
  ## `var name {.hot.}: T = first`: a global that survives a reload (reload.nim's `hot`
  ## passes a var section here; see the module's doc)
  when not (defined(hotReload) or defined(hotReloadLibrary)):
    # an ordinary global, but with its fields' defaults, as in a hot build (a bare
    # `var x: T` leaves them out)
    result = def
    for d in result:
      if d.kind == nnkIdentDefs and d[^1].kind == nnkEmpty and d[^2].kind != nnkEmpty:
        d[^1] = newCall(ident"default", d[^2])
  else:
    result = newStmtList()
    for d in def:
      if d.kind != nnkIdentDefs or d.len != 3:
        error("{.hot.}: one variable per declaration", d)
      let name = d[0]
      let base = if name.kind == nnkPostfix: name[1] else: name
      let typ = if d[1].kind != nnkEmpty: d[1] else: newCall(ident"typeof", d[2])
      let first = if d[2].kind != nnkEmpty: d[2] else: newCall(ident"default", typ)
      # the same key in the program and in each library (moduleKey)
      let key = newLit(moduleKey(def) & "." & $base)
      # named, not gensym'd: what a debugger shows for the global (`speedHotSlot[]`)
      let slot = ident($base & "HotSlot")
      let hashSym = bindSym"hash"
      let typeSigSym = bindSym"typeSig"
      let holdsRefsSym = bindSym"holdsRefs"
      let saveSym = bindSym"save"
      let loadSym = bindSym"load"
      let copySym = bindSym"copy"
      let slotProc = bindSym"hotSlot"
      # the value goes in and out as a field, so a type change at the top is seen too
      result.add quote do:
        let `slot` = cast[ptr `typ`](`slotProc`(`key`, static(`hashSym`(`typeSigSym`(`typ`))),
          `holdsRefsSym`(`typ`),
          proc (): pointer {.cdecl.} =
            let p = create(`typ`)
            p[] = `first`
            p,
          proc (p: pointer): string {.cdecl.} =
            `saveSym`(result, (value: cast[ptr `typ`](p)[])),
          proc (p: pointer; data: string) {.cdecl.} =
            var v = (value: move(cast[ptr `typ`](p)[]))
            `loadSym`(data, v)
            cast[ptr `typ`](p)[] = move(v.value),
          proc (old: pointer): pointer {.cdecl.} =
            let p = create(`typ`)
            `copySym`(p[], cast[ptr `typ`](old))
            p))
        template `name`: var `typ` = `slot`[]
