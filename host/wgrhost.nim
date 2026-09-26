## A wgrender program around an app module: the host owns the window, the init and frame
## callbacks and the app's context, and calls the app. With -d:hcrHost it also rebuilds
## the app when its source changes and swaps it in (hcr.nim); everywhere else (release,
## web) the app is compiled in.
##
## The app module defines, all {.reloadable.}:
##
##   onInit(ctx: var Context)                   once, at startup: set up, request assets
##   onLoad(ctx: var Context; reloaded: bool)   after onInit (false), after each reload (true)
##   onUnload(ctx: var Context)                 on the old code, just before a reload
##   onFrame(ctx: var Context; dt, tickFraction: float)
##
## and the Context type with its ContextStamp (see simple's context.nim), and ends with
## `runApp(title, width, height, flags)`: that is the program.
##
## The app asks for assets with `ctx.requestAsset(name) do (ctx: var Context; path: string)`.
## A callback can be the app's own closure even in a hot build: a library that's been
## replaced stays loaded, so a callback from before a reload still runs (the code that
## asked for it).

import wgr
import hcr
export reloadable

proc requestAsset*[C](ctx: var C; name: string;
                      onReady: proc (ctx: var C; path: string) {.closure.}) =
  ## load an asset; `onReady` runs on a later frame with it at `path`, local and ready.
  ## `ctx` is the host's, which lives as long as the program: the callback gets it back
  let c = addr ctx
  let onFailed = proc (path: string) = logError("failed to import asset: " & name)
  let ready = proc (path: string) = onReady(c[], path)
  if not ensureAssetAsync(name).addTask(ready, onFailed):
    onFailed(name)

when defined(hcrScript):
  template runApp*(title: string; width, height: int; flags: set[WindowFlag] = {}) =
    ## a script build is the app alone: the host is the program that loads it
    discard

else:
  const AssetBase {.strdefine: "wgrAssetBase".} = "assets"
    ## beside the page on the web; on the desktop the app's config.nims names it

  template runApp*(title: string; width, height: int; flags: set[WindowFlag] = {}) =
    ## the program: call it last in the app's main module
    var ctx: Context

    # The app's procs: the compiled-in ones, until a reload replaces them
    when defined(hcrHost):
      var frameProc = onFrame
      var loadProc = onLoad
      var unloadProc = onUnload
      var script: HotScript
    else:
      const frameProc = onFrame
      const loadProc = onLoad

    proc hostInit() =
      setAssetHost(AssetBase)
      setAssetManifest(AssetManifestName)
      onInit(ctx)
      loadProc(ctx, false)

      when defined(hcrHost):
        script = newHotScript(instantiationInfo(fullPaths = true).filename, ContextStamp,
          onUnload = proc () = unloadProc(ctx),
          onLoad = proc () =
            frameProc = script.lookup(onFrame)
            loadProc = script.lookup(onLoad)
            unloadProc = script.lookup(onUnload)
            loadProc(ctx, true))

    proc hostFrame(dt, tickFraction: float) =
      when defined(hcrHost):
        script.update(getTime())
      frameProc(ctx, dt, tickFraction)

    initValues(width, height, title, flags)
    setInit(hostInit)
    setFrame(hostFrame)
    let status = run()
    # On the web wgr_run returns at once and the browser drives the frames, so don't
    # exit() here: that would tear the program down.
    when not defined(emscripten):
      quit status
