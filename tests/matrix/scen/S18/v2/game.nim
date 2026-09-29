import std/json
import hotreload
var ticks {.hot.} = 0
proc tick*() {.hot.} =
  inc ticks
  let j = parseJson("""{"name": "orc", "hp": [1, 2, 3]}""")
  j["ticks"] = %ticks
  echo "S18 v2 ticks=", ticks, " json name=", j["name"].getStr, " hp[2]=", j["hp"][2].getInt, " ", $j
