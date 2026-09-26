## nimhcr: hot code reload for a Nim program. `import nimhcr`: {.reloadable.} procs,
## {.hot.} globals, hotHost and hotMain (nimhcr/hcr.nim has the whole story), and what
## carries a value across a reload (nimhcr/migrate.nim).

import nimhcr/hcr
export hcr
