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
## Old code still around after a reload (a callback from before it) keeps the storage it
## had: after a type change that's the old copy, so what it writes there is lost, not
## corrupting.

import std/[hashes, macros]
when defined(hcrHost) or defined(hcrScript):
  import std/os
import ./migrate
export migrate, hashes

proc sigOf(n: NimNode; seen: var seq[string]): string =
  case n.kind
  of nnkSym:
    let impl = n.getTypeImpl
    case impl.kind
    of nnkObjectTy, nnkEnumTy, nnkDistinctTy, nnkTupleTy:
      let name = n.strVal
      if name in seen: return name
      seen.add name
      result = name & "=" & sigOf(impl, seen)
    of nnkBracketExpr, nnkTupleConstr:
      result = sigOf(impl, seen)
    of nnkSym:
      result = impl.strVal
    else:
      result = impl.repr
  of nnkObjectTy:
    result = "object("
    for d in n[2]:
      if d.kind == nnkIdentDefs:
        for i in 0 ..< d.len - 2:
          result.add $d[i] & ":" & sigOf(d[^2], seen) & ";"
      else:
        result.add d.repr & ";"
    result.add ")"
  of nnkTupleTy:
    result = "tuple("
    for d in n:
      for i in 0 ..< d.len - 2:
        result.add $d[i] & ":" & sigOf(d[^2], seen) & ";"
    result.add ")"
  of nnkTupleConstr:
    result = "tuple("
    for c in n: result.add sigOf(c, seen) & ";"
    result.add ")"
  of nnkDistinctTy:
    result = "distinct " & sigOf(n[0], seen)
  of nnkEnumTy:
    result = "enum("
    for c in n:
      if c.kind != nnkEmpty: result.add c.repr & ";"
    result.add ")"
  of nnkBracketExpr:
    result = (if n[0].kind == nnkSym: n[0].strVal else: n[0].repr) & "["
    for i in 1 ..< n.len:
      result.add (if n[i].kind == nnkSym and n[i].symKind == nskType: sigOf(n[i], seen)
                  else: n[i].repr) & ","
    result.add "]"
  else:
    result = n.repr

macro typeSig*(T: typedesc): string =
  ## T's shape, as text: what changes when a change to T matters to migrate
  var seen: seq[string]
  newLit(sigOf(T.getTypeInst[1], seen))

type
  HotMake = proc (): pointer {.cdecl.}
  HotSave = proc (p: pointer): string {.cdecl.}
  HotLoad = proc (p: pointer; data: string) {.cdecl.}

when defined(hcrScript):
  # the host's, which it exports (-rdynamic)
  proc hcrHotSlot(key: cstring; stamp: int; make: HotMake; save: HotSave;
                  load: HotLoad): pointer {.importc, cdecl.}

elif defined(hcrHost):
  import std/tables

  type HotSlot = object
    stamp: int       ## its type, hashed (typeSig)
    data: pointer
    save: HotSave    ## the latest library's, which knows `data`'s type

  var hotSlots: Table[string, HotSlot]

  proc hcrHotSlot(key: cstring; stamp: int; make: HotMake; save: HotSave;
                  load: HotLoad): pointer {.exportc, cdecl, dynlib.} =
    ## the storage for a hot global: made the first time, and made again, with what still
    ## fits carried over, when a library has it with another type. The old storage isn't
    ## freed: old code may still write to it
    let k = $key
    if k notin hotSlots:
      hotSlots[k] = HotSlot(stamp: stamp, data: make(), save: save)
    elif hotSlots[k].stamp != stamp:
      let old = hotSlots[k]
      let data = make()
      load(data, old.save(old.data))
      hotSlots[k] = HotSlot(stamp: stamp, data: data, save: save)
      echo "hcr: " & k & "'s type changed; carried over what still fits"
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
      let saveSym = bindSym"save"
      let loadSym = bindSym"load"
      let slotProc = bindSym"hcrHotSlot"
      # the value goes in and out as a field, so a type change at the top is seen too
      result.add quote do:
        let `slot` = cast[ptr `typ`](`slotProc`(`key`, static(`hashSym`(`typeSigSym`(`typ`))),
          proc (): pointer {.cdecl.} =
            let p = create(`typ`)
            p[] = `first`
            p,
          proc (p: pointer): string {.cdecl.} =
            `saveSym`(result, (value: cast[ptr `typ`](p)[])),
          proc (p: pointer; data: string) {.cdecl.} =
            var v = (value: move(cast[ptr `typ`](p)[]))
            `loadSym`(data, v)
            cast[ptr `typ`](p)[] = move(v.value)))
        template `name`: var `typ` = `slot`[]
