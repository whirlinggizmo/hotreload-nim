import hotreload
proc step*(i: float) {.hot.} =
  echo "S13 v2 (float sig) step i=", i
