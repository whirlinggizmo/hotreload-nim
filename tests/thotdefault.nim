# {.hot.} in a build that isn't hot: an ordinary global, with its fields' defaults
import std/unittest
import hotreload

type Settings = object
  speed: float = 2.0

var settings {.hot.}: Settings

suite "hot globals, not hot":
  test "fields start at their defaults":
    check settings.speed == 2.0
