import std/unittest
import std/strutils
import hotreload/typesig

type
  Leaf = object
    a: int
  LeafB = object
    a: float
  Node = ref object
    leaf: Leaf
    next: Node
  NodeB = ref object
    leaf: LeafB
    next: NodeB
  Plain = object
    s: seq[string]
    t: (int, Leaf)
  Holder = object
    nodes: seq[Node]
  Base = object of RootObj
    x: int
  Sub = object of Base
    y: int

suite "typeSig":
  test "a change inside, even through a ref, changes it":
    check typeSig(Leaf) != typeSig(LeafB)
    check typeSig(Node).replace("Leaf", "L") != typeSig(NodeB).replace("NodeB", "Node").replace("LeafB", "L")

  test "a recursive type ends":
    check typeSig(Node).len > 0

  test "what it inherits is part of it":
    check "of Base" in typeSig(Sub)

suite "holdsRefs":
  test "refs anywhere inside":
    check not holdsRefs(Plain)
    check not holdsRefs(int)
    check holdsRefs(Node)
    check holdsRefs(Holder)
    check holdsRefs(seq[Node])
    check holdsRefs((int, ref int))
