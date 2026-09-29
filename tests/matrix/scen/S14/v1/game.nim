import hotreload
type
  Critter* = ref object
    n*: int
  Animal* = ref object of RootObj
  Dog* = ref object of Animal
proc newCritter*(): Critter = Critter(n: 1)
proc newDog*(): Dog = Dog()
proc speak*(c: Critter): string =
  inc c.n
  "speak v1 n=" & $c.n
method talk*(a: Animal): string {.base.} = "animal v1"
method talk*(d: Dog): string = "dog v1"
proc describe*(c: Critter): string {.hot.} = "describe v1 n=" & $c.n
proc describeAnimal*(a: Animal): string {.hot.} = "describeAnimal v1 talk=" & a.talk()
