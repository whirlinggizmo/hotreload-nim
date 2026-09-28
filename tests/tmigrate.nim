import std/unittest
import hotreload/migrate

type
  Handle = distinct int32
  Inner = object
    x, y: float32
  Node = ref object
    name: string
    next: Node

proc carry[A, B](a: A; b: var B) =
  var s = ""
  save(s, a)
  load(s, b)

suite "values":
  test "fields by name; a gone one dropped, a new one kept at its default":
    type
      A = object
        keep: int
        gone: string
        inner: Inner
      B = object
        inner: Inner
        added: string = "default"
        keep: int
    var b = B() # with its defaults
    carry(A(keep: 7, gone: "x", inner: Inner(x: 1, y: 2)), b)
    check b.keep == 7 and b.inner.x == 1 and b.inner.y == 2 and b.added == "default"

  test "a field whose kind changed keeps its default":
    type
      A = object
        n: int
        s: seq[int]
      B = object
        n: float = 0.5
        s: string
    var b = B()
    carry(A(n: 3, s: @[1]), b)
    check b.n == 0.5 and b.s == ""

  test "seqs, arrays (what fits), tuples, distinct":
    type
      A = object
        items: seq[Inner]
        arr: array[4, int]
        pair: (string, int)
        h: Handle
      B = object
        items: seq[Inner]
        arr: array[2, int]
        pair: (string, int)
        h: Handle
    var b: B
    carry(A(items: @[Inner(x: 1), Inner(x: 2)], arr: [1, 2, 3, 4], pair: ("p", 9),
            h: Handle(5)), b)
    check b.items.len == 2 and b.items[1].x == 2
    check b.arr == [1, 2]
    check b.pair == ("p", 9)
    check int32(b.h) == 5

suite "refs":
  test "shared stays shared, a cycle stays a cycle":
    type R = object
      all: seq[Node]
      ring: Node
    let a = Node(name: "a")
    var r = R(all: @[a, Node(name: "b", next: a), a], ring: Node(name: "r1"))
    r.ring.next = Node(name: "r2", next: r.ring)
    var b: R
    carry(r, b)
    check b.all[0] != a and b.all[0].name == "a"
    check b.all[1].next == b.all[0] and b.all[2] == b.all[0]
    check b.ring.next.next == b.ring
    r.ring.next.next = nil
    b.ring.next.next = nil

  test "an object is kept when the field that held the first ref to it is gone":
    type
      A = object
        first: Node
        later: Node
      B = object
        later: Node
    let n = Node(name: "n")
    var b: B
    carry(A(first: n, later: n), b)
    check b.later != nil and b.later.name == "n"

  test "what a ref points at can change":
    type
      NodeB = ref object
        name: string
        next: NodeB
        hp: int = 10
      A = object
        head: Node
      B = object
        head: NodeB
    var b: B
    carry(A(head: Node(name: "1", next: Node(name: "2"))), b)
    check b.head.name == "1" and b.head.next.name == "2" and b.head.hp == 10

  test "a long list doesn't recurse as deep as it is long":
    var head: Node
    for i in 0 ..< 100_000: head = Node(name: $i, next: head)
    var b: Node
    carry(head, b)
    var n = 0
    while b != nil: inc n; b = b.next
    check n == 100_000
    # freed a node at a time: Nim's destructor frees a list as deep as it is long, too
    # deep for Windows' 1 MB stack
    while head != nil: head = head.next

  test "copy: the same type, in place, with new refs":
    type R = object
      all: seq[Node]
      ring: Node
      plain: seq[Inner]
    let a = Node(name: "a")
    var r = R(all: @[a, Node(name: "b", next: a)], ring: Node(name: "r1"),
              plain: @[Inner(x: 3)])
    r.ring.next = Node(name: "r2", next: r.ring)
    var c: R
    copy(c, addr r)
    check c.all[0] != a and c.all[1].next == c.all[0]
    check c.ring != r.ring and c.ring.next.next == c.ring
    check c.plain[0].x == 3
    r.ring.next.next = nil
    c.ring.next.next = nil

suite "refused":
  test "pointers, closures, and refs to objects that inherit":
    type
      Base = ref object of RootObj
      P = object
        p: ptr int
      C = object
        f: proc ()
      I = object
        b: Base
    var s = ""
    check not compiles(save(s, P()))
    check not compiles(save(s, C()))
    check not compiles(save(s, I()))
