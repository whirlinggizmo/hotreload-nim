## Carrying a value across a change to its type, from one build of a program to the next:
## the old build writes it out field by field, each with its name and its kind, and the new
## build reads back each field it still has, by the same name and kind. A field that's gone
## is dropped; a new one, or one whose kind changed, keeps its default.
##
## A kind is what a value is made of: an object, a tuple, a seq or an array matches another
## of its sort, whatever its type is called or holds, and what's inside is matched the same
## way, field by field or element by element (an array keeps what fits). A ref matches a
## ref to the same kind. Anything else matches by its type's name: an int is not a float,
## a Meters is not a Seconds.
##
## Numbers, bools, chars, enums, sets, distinct types of those (handles, ids, units),
## strings, refs, and seqs, arrays, objects and tuples of them. An enum is carried by its
## member's name, not its number, so members can be added or reordered; one that's gone
## keeps the default. Refs are copied as a graph: each object once, however many refs point
## at it, so what was shared is shared in the copy, and a cycle stays a cycle. What a ref
## points at is written out apart from the value, so it's still there for another ref to it
## when the field that held the first one is gone. A ref to an object that inherits can't
## be: its type is only known when it runs. Pointers and closures belong to the build that
## made them, so they're refused at compile time.
##
## When the type hasn't changed but holds refs, there's a quicker way: `copy`, in the new
## build, reads the old value in place (the layout is the same) and makes its own refs.
##
## Every value a build carries over, by `load` or by `copy`, shares one table of the copies
## it has made, by the old object's address: so an object two hot globals both point at is
## one object in the new build too. Each build (each library) has its own, which is only
## used while it starts, so it's as good as new for each reload.

import std/[strutils, tables, typetraits]
from std/enumutils import nil
import ./typesig

type
  Writer = object
    ids: Table[pointer, int]  ## a ref's object: its number, from 1
    objects: seq[string]      ## what each ref points at, written out
    addrs: seq[pointer]       ## and where it is, in the build that wrote it
    pending: seq[proc (w: var Writer) {.closure.}] ## objects still to write
  Reader = object
    objects: seq[string]
    addrs: seq[pointer]
    made: Table[int, (string, pointer)] ## an object's number: its copy, and its type's name
    pending: seq[proc (r: var Reader) {.closure.}] ## copies still to fill in
    path: seq[string]         ## where in the value it's reading: fields, and [] for elements
    lost: seq[string]         ## what didn't carry over (`load`'s `lost`)

var copies: Table[pointer, (string, pointer)]
  ## the last build's objects this build has copied, by their address there: their type's
  ## name and the copy. One table for every value carried over (see the module's doc)

proc forgetCopies*() =
  ## starts the table of copies over: for a program that carries values over more than once
  ## (a test), since an old object's address can be another's once it's freed. A reload
  ## needn't: each library has its own table, used only while it starts
  copies.clear()

proc note(r: var Reader; what: string; name = "") =
  ## `name` (a field; "" = the value being read) at the current path didn't carry over
  var at = ""
  for p in r.path & (if name.len > 0: @[name] else: @[]):
    if p != "[]" and at.len > 0: at.add '.'
    at.add p
  let entry = what & " " & at
  if entry notin r.lost: r.lost.add entry

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

proc putPtr(s: var string; p: pointer) =
  var x = cast[uint64](p)
  let at = s.len
  s.setLen(at + 8)
  copyMem(addr s[at], addr x, 8)

proc getPtr(s: string; pos: var int): pointer =
  if pos + 8 > s.len: raise newException(ValueError, "migrate: the data ends early")
  var x: uint64
  copyMem(addr x, unsafeAddr s[pos], 8)
  inc pos, 8
  cast[pointer](x)

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
        w.addrs.add p
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
  elif T is enum:
    s.add $x
  elif T is set:
    when elementType(x) is enum:
      s.putLen(card(x))
      for v in x: s.putStr($v)
    else:
      var v = x
      let at = s.len
      s.setLen(at + sizeof(T))
      copyMem(addr s[at], addr v, sizeof(T))
  elif T is SomeNumber or T is bool or T is char:
    var v = x
    let at = s.len
    s.setLen(at + sizeof(T))
    copyMem(addr s[at], addr v, sizeof(T))
  else:
    {.error: "migrate: a " & $T & " can't be carried to another build " & Refused.}

proc member[T: enum](name: string; x: var T): bool =
  ## `x` = the member of T named `name`, if T still has one
  when T is Ordinal:
    for v in T:
      if $v == name:
        x = v
        return true
  else: # an enum with holes in its numbers
    for v in enumutils.items(T):
      if $v == name:
        x = v
        return true

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
      else: r.note("reset")
    elif id <= r.objects.len:
      let old = r.addrs[id - 1]
      if old in copies:
        # another value carried over already copied it
        let (name, p) = copies[old]
        r.made[id] = (name, p)
        if name == $T: x = cast[T](p)
        else: r.note("reset")
      else:
        new(x)
        r.made[id] = ($T, cast[pointer](x))
        copies[old] = ($T, cast[pointer](x))
        let target = x
        r.pending.add proc (r: var Reader) =
          # inside what a ref points at, a path starts at its type (`Enemy.shield`): the
          # same for each object of it, and not as long as the chain that reached it
          let path = r.path
          r.path = @[$T]
          get(r, r.objects[id - 1], target[])
          r.path = path
  elif T is object or T is tuple:
    var pos = 0
    var fields: Table[string, (string, string)] # name: (kind, data)
    for _ in 0 ..< s.getLen(pos):
      let name = s.getStr(pos)
      let kind = s.getStr(pos)
      fields[name] = (kind, s.getStr(pos))
    var names: seq[string]
    for name, v in fieldPairs(x):
      names.add name
      if name in fields:
        if fields[name][0] == kind(typeof(v)):
          r.path.add name
          get(r, fields[name][1], v)
          r.path.setLen(r.path.len - 1)
        else:
          r.note("reset", name)
    for name in fields.keys:
      if name notin names: r.note("dropped", name)
  elif T is string:
    x = s
  elif T is seq:
    var pos = 0
    x.setLen(s.getLen(pos))
    r.path.add "[]"
    for v in x.mitems:
      get(r, s.getStr(pos), v)
    r.path.setLen(r.path.len - 1)
  elif T is array:
    var pos = 0
    var left = s.getLen(pos)
    r.path.add "[]"
    for v in x.mitems:
      if left == 0: break
      get(r, s.getStr(pos), v)
      dec left
    r.path.setLen(r.path.len - 1)
  elif T is enum:
    if not member(s, x): r.note("reset")
  elif T is set:
    when elementType(x) is enum:
      var pos = 0
      x = {}
      for _ in 0 ..< s.getLen(pos):
        var v: elementType(x)
        if member(s.getStr(pos), v): x.incl v
        else: r.note("reset")
    else:
      if s.len == sizeof(T):
        copyMem(addr x, unsafeAddr s[0], sizeof(T))
  elif T is SomeNumber or T is bool or T is char:
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
  for i, o in w.objects:
    s.putStr(o)
    s.putPtr(w.addrs[i])

proc load*[T](s: string; x: var T; lost: var seq[string]) =
  ## reads back into `x` what `save` wrote that still fits it. `lost` = what didn't: each
  ## "dropped <field>" (gone from T) or "reset <field>" (its kind changed; it keeps its
  ## default), by its path (`hp`, `enemies[].shield`, `Enemy.shield` inside what a ref of
  ## type Enemy points at; "" = the value itself)
  var r: Reader
  var pos = 0
  let value = s.getStr(pos)
  for _ in 0 ..< s.getLen(pos):
    r.objects.add s.getStr(pos)
    r.addrs.add s.getPtr(pos)
  get(r, value, x)
  var i = 0
  while i < r.pending.len:
    let fill = r.pending[i]
    fill(r)
    inc i
  for entry in r.lost: lost.add entry.strip(leading = false)

proc load*[T](s: string; x: var T) =
  ## reads back into `x` what `save` wrote that still fits it
  var lost: seq[string]
  load(s, x, lost)

type Copier = object
  pending: seq[proc (c: var Copier) {.closure.}] ## copies still to fill in

proc copyInto[T](c: var Copier; dst: var T; src: ptr T) =
  # `src` is the other build's: read through pointers, never assigned from, so none of
  # its refs is counted (or seen by this build's cycle collector)
  when not holdsRefs(T):
    dst = src[]
  elif T is distinct:
    copyInto(c, distinctBase(T)(dst), cast[ptr distinctBase(T)](src))
  elif T is ref:
    let p = cast[pointer](src[])
    if p == nil:
      dst = nil
    elif p in copies and copies[p][0] == $T:
      dst = cast[T](copies[p][1])
    else:
      new(dst)
      copies[p] = ($T, cast[pointer](dst))
      let target = dst
      c.pending.add proc (c: var Copier) =
        copyInto(c, target[], cast[ptr pointerBase(T)](p))
  elif T is object or T is tuple:
    for d, s in fields(dst, src[]):
      copyInto(c, d, addr s)
  elif T is seq:
    dst.setLen(src[].len)
    for i in 0 ..< dst.len: copyInto(c, dst[i], addr src[][i])
  elif T is array:
    for i in low(T) .. high(T): copyInto(c, dst[i], addr src[][i])
  else:
    {.error: "migrate: a " & $T & " can't be carried to another build " & Refused.}

proc copy*[T](dst: var T; src: ptr T) =
  ## `src`, the other build's T of the same layout, copied into `dst`, with refs of this
  ## build's own; what was shared is shared, and a cycle stays a cycle
  var c: Copier
  copyInto(c, dst, src)
  var i = 0
  while i < c.pending.len:
    let fill = c.pending[i]
    fill(c)
    inc i
