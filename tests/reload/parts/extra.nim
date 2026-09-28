## A second reloaded module, in a directory of its own, that nothing names: it's
## reloaded because it has a hot proc (main.nim calls it)

import hotreload

proc extra*(): string {.hot.} = "e1"
