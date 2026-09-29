import hotreload
proc step*(i: int) {.hot.} =
  echo "S13 v1 step i=", i
