## Writes the asset manifests for a directory tree, as wgrender's tools/gen_manifest.py
## does: a manifest.json in the directory and in every directory under it, giving the
## SHA-256 of each file beside it and of each subdirectory's own manifest.json. The web
## build's asset loader then fetches only the files whose hash changed. `nim web` in an
## example runs it on examples/assets. The same tree always gets the same bytes.
##
##   nim r manifest.nim DIR

import std/[algorithm, json, os, strutils]

const Name = "manifest.json"

# SHA-256 (FIPS 180-4): Nim's standard library has none, and this saves a package
const K = [
  0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32, 0x3956c25b'u32,
  0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32, 0xd807aa98'u32, 0x12835b01'u32,
  0x243185be'u32, 0x550c7dc3'u32, 0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32,
  0xc19bf174'u32, 0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32,
  0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32, 0x983e5152'u32,
  0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32, 0xc6e00bf3'u32, 0xd5a79147'u32,
  0x06ca6351'u32, 0x14292967'u32, 0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32,
  0x53380d13'u32, 0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
  0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32, 0xd192e819'u32,
  0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32, 0x19a4c116'u32, 0x1e376c08'u32,
  0x2748774c'u32, 0x34b0bcb5'u32, 0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32,
  0x682e6ff3'u32, 0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
  0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32]

proc rotr(x: uint32; n: int): uint32 = (x shr n) or (x shl (32 - n))

proc sha256(data: string): string =
  ## "sha256:" and the hash of `data`, in hex
  var h = [0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32,
           0x510e527f'u32, 0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32]
  var msg = data
  msg.add '\x80'
  while msg.len mod 64 != 56: msg.add '\0'
  let bits = uint64(data.len) * 8
  for i in countdown(7, 0): msg.add char((bits shr (i * 8)) and 0xff)
  var w: array[64, uint32]
  for chunk in 0 ..< msg.len div 64:
    for i in 0 ..< 16:
      let p = chunk * 64 + i * 4
      w[i] = (uint32(msg[p]) shl 24) or (uint32(msg[p + 1]) shl 16) or
             (uint32(msg[p + 2]) shl 8) or uint32(msg[p + 3])
    for i in 16 ..< 64:
      let s0 = rotr(w[i - 15], 7) xor rotr(w[i - 15], 18) xor (w[i - 15] shr 3)
      let s1 = rotr(w[i - 2], 17) xor rotr(w[i - 2], 19) xor (w[i - 2] shr 10)
      w[i] = w[i - 16] + s0 + w[i - 7] + s1
    var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
    for i in 0 ..< 64:
      let t1 = hh + (rotr(e, 6) xor rotr(e, 11) xor rotr(e, 25)) +
               ((e and f) xor ((not e) and g)) + K[i] + w[i]
      let t2 = (rotr(a, 2) xor rotr(a, 13) xor rotr(a, 22)) +
               ((a and b) xor (a and c) xor (b and c))
      (hh, g, f, e, d, c, b, a) = (g, f, e, d + t1, c, b, a, t1 + t2)
    for i, v in [a, b, c, d, e, f, g, hh]: h[i] += v
  result = "sha256:"
  for v in h: result.add toHex(v, 8).toLowerAscii

proc writeTree(dir: string; manifests, files: var int): string =
  ## writes `dir`'s manifest after its subdirectories', and returns its hash
  var fileHashes, dirHashes = newJObject()
  var entries: seq[(PathComponent, string)]
  for kind, path in walkDir(dir): entries.add (kind, path)
  entries.sort(proc (a, b: (PathComponent, string)): int = cmp(a[1], b[1]))
  for (kind, path) in entries:
    let name = path.extractFilename
    if kind in {pcDir, pcLinkToDir}:
      dirHashes[name] = %writeTree(path, manifests, files)
    elif name != Name:
      fileHashes[name] = %sha256(readFile(path))
      inc files
  let text = pretty(%*{"dirs": dirHashes, "files": fileHashes, "wgr_manifest": 1}, 1) & "\n"
  let target = dir / Name
  if not fileExists(target) or readFile(target) != text:
    writeFile(target, text)
  inc manifests
  sha256(text)

when isMainModule:
  if paramCount() != 1 or not dirExists(paramStr(1)):
    quit "usage: nim r manifest.nim DIR"
  var manifests, files: int
  discard writeTree(paramStr(1), manifests, files)
  echo "manifest: " & $files & " file(s) in " & $manifests & " manifest(s) under " & paramStr(1)
