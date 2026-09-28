## thotdefault's hot global, outside its main module
import hotreload

type Settings* = object
  speed*: float = 2.0

var settings* {.hot.}: Settings
