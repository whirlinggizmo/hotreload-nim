## hotreload: hot reload for a Nim program. `import hotreload`: {.hot.} globals and procs,
## the {.beforeHotReload.} and {.afterHotReload.} hooks, and the Reloader
## (hotreload/reload.nim has the whole story), and what carries a value across a reload
## (hotreload/migrate.nim).

import hotreload/reload
export reload
