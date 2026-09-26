## hotreload: hot reload for a Nim program. `import hotreload`: {.hotEntry.} procs, {.hot.}
## globals and the Reloader (hotreload/reload.nim has the whole story), and what carries a
## value across a reload (hotreload/migrate.nim).

import hotreload/reload
export reload
