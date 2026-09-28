## wgrender's simple example: the program. It opens the window and runs the frames, and
## calls the code (simple.nim): its latest version, when `nim hot` runs it, which a change
## to this file doesn't reload (restart for those).

import wgr
import hotreload
import ./simple

const AssetBase {.strdefine: "wgrAssetBase".} = "assets"
  ## beside the page on the web; on the desktop the config names it

let reloader = newReloader("simple.nim")

initValues(1024, 1280, "simple (wgrender, Nim, hot reload)",
           {WindowFlag.Msaa4x, WindowFlag.Resizable})
setInit(proc () =
  setAssetHost(AssetBase)
  setAssetManifest(AssetManifestName)
  onInit())
setFrame(proc (dt, tickFraction: float) =
  reloader.update()
  onFrame(dt, tickFraction))
let status = run()
# On the web wgr_run returns at once and the browser drives the frames, so don't exit()
# here: that would tear the program down.
when not defined(emscripten):
  quit status
