import hotreload
proc step*(i: int) {.hot.} =
  echo "S13 v3 (reverted sig) step i=", i
