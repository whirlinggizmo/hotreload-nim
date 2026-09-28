## A local web server for the examples' web builds: `nim serve` in an example runs it.
## It serves the files in its directories, and nothing else: each request from the
## first directory that has the file, so an example's build (out/web/<variant>/, with
## its .js and .wasm), the examples' page (examples/www/) and their assets
## (examples/assets/, at /assets) serve as one site. Every answer has the two headers
## a threaded web build needs (COOP and COEP, for SharedArrayBuffer), and tells the
## browser not to keep anything, so a reload always gets the latest build.
##
##   nim r serve.nim PORT DIR...        # a DIR can be /prefix=DIR: served at /prefix

import std/[asyncdispatch, asynchttpserver, os, strutils, uri]

proc contentType(path: string): string =
  ## the types the examples' page and assets use
  case path.splitFile.ext.toLowerAscii
  of ".html": "text/html; charset=utf-8"
  of ".js": "text/javascript"
  of ".wasm": "application/wasm"   # what a browser needs to compile it as it downloads
  of ".json": "application/json"
  of ".css": "text/css"
  of ".txt", ".md": "text/plain; charset=utf-8"
  of ".png": "image/png"
  of ".jpg", ".jpeg": "image/jpeg"
  of ".ttf": "font/ttf"
  of ".otf": "font/otf"
  of ".glb": "model/gltf-binary"
  of ".gltf": "model/gltf+json"
  of ".mp3": "audio/mpeg"
  of ".ogg": "audio/ogg"
  of ".wav": "audio/wav"
  else: "application/octet-stream"

type Root = tuple
  prefix: string   ## the URL path it's served at ("" for /)
  dir: string

proc find(roots: seq[Root]; rel: string): string =
  ## the file at URL path `rel` in the first of `roots` that has it, or ""
  for (prefix, dir) in roots:
    if prefix.len > 0 and not rel.startsWith(prefix & "/"): continue
    let path = normalizedPath(dir / rel[prefix.len .. ^1])
    # only files under the served directories
    if path.startsWith(dir & DirSep) and fileExists(path): return path
  ""

proc serve(req: Request; roots: seq[Root]) {.async.} =
  let headers = newHttpHeaders({
    "Cross-Origin-Opener-Policy": "same-origin",
    "Cross-Origin-Embedder-Policy": "require-corp",
    "Cache-Control": "no-store"})
  var rel = decodeUrl(req.url.path)
  if rel.endsWith("/"): rel.add "index.html"
  let path = find(roots, rel)
  if path.len == 0:
    await req.respond(Http404, "not found: " & req.url.path, headers)
    return
  headers["Content-Type"] = contentType(path)
  await req.respond(Http200, readFile(path), headers)

proc main() {.async.} =
  if paramCount() < 2:
    quit "usage: nim r serve.nim PORT DIR..."
  let port = parseInt(paramStr(1))
  var roots: seq[Root]
  for i in 2 .. paramCount():
    let arg = paramStr(i)
    var prefix, dir: string
    if arg.startsWith("/") and '=' in arg:   # /prefix=DIR
      let parts = arg.split('=', 1)
      prefix = parts[0].strip(leading = false, chars = {'/'})
      dir = parts[1]
    else:
      dir = arg
    roots.add (prefix, normalizedPath(absolutePath(dir)))
  let server = newAsyncHttpServer()
  server.listen(Port(port))
  echo "serving on http://localhost:" & $port & "/ (Ctrl-C to stop):"
  for (prefix, dir) in roots: echo "  " & prefix & "/  " & dir
  proc handle(req: Request): Future[void] {.gcsafe.} = serve(req, roots)
  while true:
    if server.shouldAcceptRequest():
      await server.acceptRequest(handle)
    else:
      await sleepAsync(10)

waitFor main()
