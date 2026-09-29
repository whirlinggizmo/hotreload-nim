import std/os
import hotreload
import ./game
let reloader = newReloader()
let c = newCritter()      # a reloaded module's type, made at start, held by the main module
let a: Animal = newDog()  # an inheriting ref, with a method
echo "START"
var i = 0
while true:
  reloader.update()
  if i mod 5 == 0:
    echo "S14 main: c.speak()=", c.speak(), " | a.talk()=", a.talk(), " | describe(c)=", describe(c), " | describeAnimal(a)=", describeAnimal(a)
  inc i
  sleep(50)
