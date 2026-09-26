## Globals that survive a reload: `var enemies {.hot.}: seq[Enemy]`, or with a first value,
## `var speed {.hot.} = 1.0`. In a hot build the host keeps each one, by its module and
## name, and every library that loads is handed the one that's there: its first value is
## used once, when it's first made. When a reload changes its type, what still fits is
## carried over (migrate.nim) and the rest starts from the first value. Everywhere else
## (debug, release, web) it's an ordinary global.
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
when defined(hcrHost) or defined(hcrScript):
  import std/os
import ./[migrate, typesig]
export migrate, typesig, hashes

when defined(hcrHost) or defined(hcrScript):
  type
    HotMake = proc (): pointer {.cdecl.}
    HotSave = proc (p: pointer): string {.cdecl.}
    HotLoad = proc (p: pointer; data: string) {.cdecl.}
    HotCopy = proc (old: pointer): pointer {.cdecl.}

when defined(hcrScript):
  # the host's, which it exports (-rdynamic)
  proc hcrHotSlot(key: cstring; stamp: int; refs: bool; make: HotMake; save: HotSave;
                  load: HotLoad; copy: HotCopy): pointer {.importc, cdecl.}

elif defined(hcrHost):
  import std/tables

  type HotSlot = object
    stamp: int       ## its type, hashed (typeSig)
    data: pointer
    save: HotSave    ## the latest library's, which knows `data`'s type

  var hotSlots: Table[string, HotSlot]

  proc hcrHotSlot(key: cstring; stamp: int; refs: bool; make: HotMake; save: HotSave;
                  load: HotLoad; copy: HotCopy): pointer {.exportc, cdecl, dynlib.} =
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
      echo "hcr: " & k & "'s type changed; carried over what still fits"
    elif refs:
      hotSlots[k] = HotSlot(stamp: stamp, data: copy(hotSlots[k].data), save: save)
    else:
      hotSlots[k].save = save
    hotSlots[k].data

macro hot*(def: untyped): untyped =
  ## `var name {.hot.}: T = first`: a global that survives a reload (see the module's doc)
  when not (defined(hcrHost) or defined(hcrScript)):
    return def
  else:
    result = newStmtList()
    for d in def:
      if d.kind != nnkIdentDefs or d.len != 3:
        error("{.hot.}: one variable per declaration", d)
      let name = d[0]
      let base = if name.kind == nnkPostfix: name[1] else: name
      let typ = if d[1].kind != nnkEmpty: d[1] else: newCall(ident"typeof", d[2])
      let first = if d[2].kind != nnkEmpty: d[2] else: newCall(ident"default", typ)
      let key = newLit(def.lineInfoObj.filename.splitFile.name & "." & $base)
      let slot = genSym(nskLet, $base & "Slot")
      let hashSym = bindSym"hash"
      let typeSigSym = bindSym"typeSig"
      let holdsRefsSym = bindSym"holdsRefs"
      let saveSym = bindSym"save"
      let loadSym = bindSym"load"
      let copySym = bindSym"copy"
      let slotProc = bindSym"hcrHotSlot"
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
