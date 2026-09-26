## Carrying a value across a change to its type, from one build of a program to the next:
## the old build writes it out field by field, each with its name and its type's name, and
## the new build reads back each field it still has, by the same name and type. A field
## that's gone is dropped; a new one, or one whose type changed (by name: an array that
## changed length is another type), keeps its default.
##
## Numbers, bools, chars, enums, sets, distinct types of those (wgrender's handles),
## strings, and seqs, arrays, objects and tuples of them. Refs, pointers and closures
## belong to the build that made them, so they're refused at compile time.

import std/[tables, typetraits]

proc putLen(s: var string; n: int) =
  var x = uint32(n)
  let at = s.len
  s.setLen(at + 4)
  copyMem(addr s[at], addr x, 4)

proc getLen(s: string; pos: var int): int =
  if pos + 4 > s.len: raise newException(ValueError, "migrate: the data ends early")
  var x: uint32
  copyMem(addr x, unsafeAddr s[pos], 4)
  inc pos, 4
  int(x)

proc putStr(s: var string; v: string) =
  s.putLen(v.len)
  s.add v

proc getStr(s: string; pos: var int): string =
  let n = s.getLen(pos)
  if pos + n > s.len: raise newException(ValueError, "migrate: the data ends early")
  result = s[pos ..< pos + n]
  inc pos, n

proc save*[T](s: var string; x: T) =
  ## appends `x` to `s`, for `load` in a build whose T may differ
  when T is distinct:
    save(s, distinctBase(T)(x))
  elif T is object or T is tuple:
    var n = 0
    for _, _ in fieldPairs(x): inc n
    s.putLen(n)
    for name, v in fieldPairs(x):
      s.putStr(name)
      s.putStr($typeof(v))
      var one = ""
      save(one, v)
      s.putStr(one)
  elif T is string:
    s.add x
  elif T is seq or T is array:
    s.putLen(x.len)
    for v in x:
      var one = ""
      save(one, v)
      s.putStr(one)
  elif T is SomeNumber or T is bool or T is char or T is enum or T is set:
    var v = x
    let at = s.len
    s.setLen(at + sizeof(T))
    copyMem(addr s[at], addr v, sizeof(T))
  else:
    {.error: "migrate: a " & $T & " can't be carried to another build " &
             "(refs, pointers and closures belong to the build that made them)".}

proc load*[T](s: string; x: var T) =
  ## reads back into `x` what `save` wrote that still fits it
  when T is distinct:
    var b: distinctBase(T)
    load(s, b)
    x = T(b)
  elif T is object or T is tuple:
    var pos = 0
    var fields: Table[string, (string, string)] # name: (type, data)
    for _ in 0 ..< s.getLen(pos):
      let name = s.getStr(pos)
      let typ = s.getStr(pos)
      fields[name] = (typ, s.getStr(pos))
    for name, v in fieldPairs(x):
      if name in fields and fields[name][0] == $typeof(v):
        load(fields[name][1], v)
  elif T is string:
    x = s
  elif T is seq:
    var pos = 0
    x.setLen(s.getLen(pos))
    for v in x.mitems:
      load(s.getStr(pos), v)
  elif T is array:
    var pos = 0
    var left = s.getLen(pos)
    for v in x.mitems:
      if left == 0: break
      load(s.getStr(pos), v)
      dec left
  elif T is SomeNumber or T is bool or T is char or T is enum or T is set:
    if s.len == sizeof(T):
      copyMem(addr x, unsafeAddr s[0], sizeof(T))
  else:
    {.error: "migrate: a " & $T & " can't be carried to another build " &
             "(refs, pointers and closures belong to the build that made them)".}
