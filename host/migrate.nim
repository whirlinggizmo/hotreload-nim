## Carrying a value across a change to its type, from one build of a program to the next:
## the old build writes it out field by field, each with its name and its kind, and the new
## build reads back each field it still has, by the same name and kind. A field that's gone
## is dropped; a new one, or one whose kind changed, keeps its default.
##
## A kind is what a value is made of: an object, a tuple, a seq or an array matches another
## of its sort, whatever its type is called or holds, and what's inside is matched the same
## way, field by field or element by element (an array keeps what fits). A ref matches a
## ref to the same kind. Anything else matches by its type's name: an int is not a float, a
## Font is not a Model.
##
## Numbers, bools, chars, enums, sets, distinct types of those (wgrender's handles),
## strings, refs, and seqs, arrays, objects and tuples of them. Refs are copied as a graph:
## each object once, however many refs point at it, so what was shared is shared in the
## copy, and a cycle stays a cycle. What a ref points at is written out apart from the
## value, so it's still there for another ref to it when the field that held the first one
## is gone. A ref to an object that inherits can't be: its type is only known when it runs.
## Pointers and closures belong to the build that made them, so they're refused at
## compile time.

import std/[tables, typetraits]

type
  Writer = object
    ids: Table[pointer, int]  ## a ref's object: its number, from 1
    objects: seq[string]      ## what each ref points at, written out
    pending: seq[proc (w: var Writer) {.closure.}] ## objects still to write
  Reader = object
    objects: seq[string]
    made: Table[int, (string, pointer)] ## an object's number: its copy, and its type's name
    pending: seq[proc (r: var Reader) {.closure.}] ## copies still to fill in

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

proc kind(T: typedesc): string =
  ## what `load` matches a field by
  when T is ref: "ref " & kind(pointerBase(T))
  elif T is object: "object"
  elif T is tuple: "tuple"
  elif T is seq: "seq"
  elif T is array: "array"
  else: $T

const Refused = "(pointers and closures belong to the build that made them)"

proc put[T](w: var Writer; s: var string; x: T) =
  when T is distinct:
    put(w, s, distinctBase(T)(x))
  elif T is ref:
    when pointerBase(T) is RootObj:
      {.error: "migrate: a " & $T & " can't be carried to another build: it inherits, " &
               "so what it points at may be another type".}
    if x == nil:
      s.putLen(0)
    else:
      let p = cast[pointer](x)
      var id = w.ids.getOrDefault(p)
      if id == 0:
        w.objects.add ""
        id = w.objects.len
        w.ids[p] = id
        let (target, at) = (x, id - 1)
        w.pending.add proc (w: var Writer) =
          var one = ""
          put(w, one, target[])
          w.objects[at] = one
      s.putLen(id)
  elif T is object or T is tuple:
    var n = 0
    for _, _ in fieldPairs(x): inc n
    s.putLen(n)
    for name, v in fieldPairs(x):
      s.putStr(name)
      s.putStr(kind(typeof(v)))
      var one = ""
      put(w, one, v)
      s.putStr(one)
  elif T is string:
    s.add x
  elif T is seq or T is array:
    s.putLen(x.len)
    for v in x:
      var one = ""
      put(w, one, v)
      s.putStr(one)
  elif T is SomeNumber or T is bool or T is char or T is enum or T is set:
    var v = x
    let at = s.len
    s.setLen(at + sizeof(T))
    copyMem(addr s[at], addr v, sizeof(T))
  else:
    {.error: "migrate: a " & $T & " can't be carried to another build " & Refused.}

proc get[T](r: var Reader; s: string; x: var T) =
  when T is distinct:
    var b: distinctBase(T)
    get(r, s, b)
    x = T(b)
  elif T is ref:
    if s.len != 4: return # not a ref
    var pos = 0
    let id = s.getLen(pos)
    if id == 0:
      x = nil
    elif id in r.made:
      let (name, p) = r.made[id]
      if name == $T: x = cast[T](p)
    elif id <= r.objects.len:
      new(x)
      r.made[id] = ($T, cast[pointer](x))
      let target = x
      r.pending.add proc (r: var Reader) = get(r, r.objects[id - 1], target[])
  elif T is object or T is tuple:
    var pos = 0
    var fields: Table[string, (string, string)] # name: (kind, data)
    for _ in 0 ..< s.getLen(pos):
      let name = s.getStr(pos)
      let kind = s.getStr(pos)
      fields[name] = (kind, s.getStr(pos))
    for name, v in fieldPairs(x):
      if name in fields and fields[name][0] == kind(typeof(v)):
        get(r, fields[name][1], v)
  elif T is string:
    x = s
  elif T is seq:
    var pos = 0
    x.setLen(s.getLen(pos))
    for v in x.mitems:
      get(r, s.getStr(pos), v)
  elif T is array:
    var pos = 0
    var left = s.getLen(pos)
    for v in x.mitems:
      if left == 0: break
      get(r, s.getStr(pos), v)
      dec left
  elif T is SomeNumber or T is bool or T is char or T is enum or T is set:
    if s.len == sizeof(T):
      copyMem(addr x, unsafeAddr s[0], sizeof(T))
  else:
    {.error: "migrate: a " & $T & " can't be carried to another build " & Refused.}

proc save*[T](s: var string; x: T) =
  ## appends `x` to `s`, for `load` in a build whose T may differ
  var w: Writer
  var value = ""
  put(w, value, x)
  # what refs point at, one after another rather than nested: a long list doesn't
  # recurse as deep as it is long
  var i = 0
  while i < w.pending.len:
    let write = w.pending[i]
    write(w)
    inc i
  s.putStr(value)
  s.putLen(w.objects.len)
  for o in w.objects: s.putStr(o)

proc load*[T](s: string; x: var T) =
  ## reads back into `x` what `save` wrote that still fits it
  var r: Reader
  var pos = 0
  let value = s.getStr(pos)
  for _ in 0 ..< s.getLen(pos): r.objects.add s.getStr(pos)
  get(r, value, x)
  var i = 0
  while i < r.pending.len:
    let fill = r.pending[i]
    fill(r)
    inc i
