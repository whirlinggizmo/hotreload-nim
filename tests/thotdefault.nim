# {.hot.} in a build that isn't hot: an ordinary global, with its fields' defaults
import std/unittest
import ./hotsettings   # a hot global can't be in the main module

suite "hot globals, not hot":
  test "fields start at their defaults":
    check settings.speed == 2.0
