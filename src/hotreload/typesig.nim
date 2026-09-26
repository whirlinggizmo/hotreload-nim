## What a type is made of, at compile time: its shape as text (typeSig), which changes
## when a change to it matters to carrying a value across a reload, and whether it holds
## refs anywhere (holdsRefs).

import std/macros

proc sigOf(n: NimNode; seen: var seq[string]; refs: var bool): string =
  case n.kind
  of nnkSym:
    let impl = n.getTypeImpl
    case impl.kind
    of nnkObjectTy, nnkEnumTy, nnkDistinctTy, nnkTupleTy, nnkRefTy:
      let name = n.strVal
      if name in seen: return name
      seen.add name
      result = name & "=" & sigOf(impl, seen, refs)
    of nnkBracketExpr, nnkTupleConstr:
      result = sigOf(impl, seen, refs)
    of nnkSym:
      result = impl.strVal
    else:
      result = impl.repr
  of nnkRefTy:
    refs = true
    result = "ref " & sigOf(n[0], seen, refs)
  of nnkObjectTy:
    result = "object("
    if n[1].kind == nnkOfInherit:
      result.add "of " & sigOf(n[1][0], seen, refs) & ";"
    for d in n[2]:
      if d.kind == nnkIdentDefs:
        for i in 0 ..< d.len - 2:
          result.add $d[i] & ":" & sigOf(d[^2], seen, refs) & ";"
      else:
        result.add d.repr & ";"
    result.add ")"
  of nnkTupleTy:
    result = "tuple("
    for d in n:
      for i in 0 ..< d.len - 2:
        result.add $d[i] & ":" & sigOf(d[^2], seen, refs) & ";"
    result.add ")"
  of nnkTupleConstr:
    result = "tuple("
    for c in n: result.add sigOf(c, seen, refs) & ";"
    result.add ")"
  of nnkDistinctTy:
    result = "distinct " & sigOf(n[0], seen, refs)
  of nnkEnumTy:
    result = "enum("
    for c in n:
      if c.kind != nnkEmpty: result.add c.repr & ";"
    result.add ")"
  of nnkBracketExpr:
    result = (if n[0].kind == nnkSym: n[0].strVal else: n[0].repr) & "["
    for i in 1 ..< n.len:
      result.add (if n[i].kind == nnkSym and n[i].symKind == nskType: sigOf(n[i], seen, refs)
                  else: n[i].repr) & ","
    result.add "]"
  else:
    result = n.repr

macro typeSig*(T: typedesc): string =
  ## T's shape, as text: what changes when a change to T matters to migrate. It follows
  ## refs, so a change to what one points at, wherever that's declared, is seen
  var seen: seq[string]
  var refs = false
  newLit(sigOf(T.getTypeInst[1], seen, refs))

macro holdsRefs*(T: typedesc): bool =
  ## whether a T has refs in it, anywhere
  var seen: seq[string]
  var refs = false
  discard sigOf(T.getTypeInst[1], seen, refs)
  newLit(refs)
