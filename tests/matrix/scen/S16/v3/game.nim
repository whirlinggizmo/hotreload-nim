import std/monotimes, std/times
import hotreload
proc bench*(label: string) {.hot.} =
  # A: a latency-bound chain (each step needs the last)
  var t0 = getMonoTime()
  var acc = 0'i64
  var f = 0.0
  for i in 0 ..< 50_000_000:
    acc = acc + ((i xor (acc shr 3)) mod 7)
    f = f * 0.999 + float(i and 1023) * 0.5
  let msA = (getMonoTime() - t0).inMicroseconds.float / 1000
  # B: independent steps, mixed int/float
  t0 = getMonoTime()
  var s = 0'i64
  var g = 0.0
  for i in 0 ..< 50_000_000:
    s += (i * 7 + 3) xor (i shr 2)
    g += float(i and 255) * 1.5
  let msB = (getMonoTime() - t0).inMicroseconds.float / 1000
  echo "S16 code=v3 ", label, " loopA ms=", msA, " loopB ms=", msB, " acc=", acc, " f=", f, " s=", s, " g=", g
