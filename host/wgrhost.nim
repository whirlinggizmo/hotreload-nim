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
## and the Context type, in a module that ends with `hotContext(Context)` (see simple's
## context.nim), and ends with `runApp(title, width, height, flags)`: that is the program.
## Context can change while a hot build runs: its fields are carried over by name.
##
## The app asks for assets with `ctx.requestAsset(name) do (ctx: var Context; path: string)`.
## A callback can be the app's own closure even in a hot build: a library that's been
## replaced stays loaded, so a callback from before a reload still runs (the code that
## asked for it).

import wgr
import hcr
export hcr

when defined(hcrScript):
  # the host's current context, which it exports (-rdynamic)
  proc wgrhostContext(): pointer {.importc, cdecl.}
elif defined(hcrHost):
  var hostContext: pointer
    ## the app's context: made by the app's code (hcrNewContext), and made again when a
    ## reload changes its type
  proc wgrhostContext(): pointer {.exportc, cdecl, dynlib.} = hostContext

proc requestAsset*[C](ctx: var C; name: string;
                      onReady: proc (ctx: var C; path: string) {.closure.}) =
  ## load an asset; `onReady` runs on a later frame with it at `path`, local and ready,
  ## and the context
  let onFailed = proc (path: string) = logError("failed to import asset: " & name)
  when defined(hcrHost) or defined(hcrScript):
    # The context moves when a reload changes its type. A callback from before that runs
    # old code, which doesn't know the new type: it's skipped.
    let asked = wgrhostContext()
    let ready = proc (path: string) =
      let now = wgrhostContext()
      if now == asked: onReady(cast[ptr C](now)[], path)
      else: echo "hcr: " & name & " arrived after the context's type changed: ask for it again"
  else:
    let c = addr ctx # the host's, which lives as long as the program
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
    when defined(hcrHost):
      # the context's type may change, so the host keeps it by pointer: the app's code
      # passes it back as its own Context
      hostContext = hcrNewContext()
      proc ctx(): var Context = cast[ptr Context](hostContext)[]
    else:
      var context: Context
      proc ctx(): var Context = context

    # The app's procs: the compiled-in ones, until a reload replaces them
    when defined(hcrHost):
      var frameProc = onFrame
      var loadProc = onLoad
      var unloadProc = onUnload
      var saveProc = hcrSaveContext
      var carried: string # the old context, written out, while the new code starts
      var script: HotScript
    else:
      const frameProc = onFrame
      const loadProc = onLoad

    when defined(hcrHost):
      proc beforeSwap(contextChanged: bool) =
        unloadProc(ctx())
        if contextChanged: carried = saveProc(hostContext)

      proc afterSwap(contextChanged: bool) =
        frameProc = script.lookup(onFrame)
        loadProc = script.lookup(onLoad)
        unloadProc = script.lookup(onUnload)
        saveProc = script.lookup(hcrSaveContext)
        if contextChanged:
          # The old context isn't freed: old code that's still around (a callback) may
          # hold on to what's in it.
          hostContext = script.lookup(hcrNewContext)()
          script.lookup(hcrLoadContext)(hostContext, carried)
          carried = ""
        loadProc(ctx(), true)

    proc hostInit() =
      setAssetHost(AssetBase)
      setAssetManifest(AssetManifestName)
      onInit(ctx())
      loadProc(ctx(), false)

      when defined(hcrHost):
        script = newHotScript(instantiationInfo(fullPaths = true).filename, ContextStamp,
                              onLoad = afterSwap, onUnload = beforeSwap)

    proc hostFrame(dt, tickFraction: float) =
      when defined(hcrHost):
        script.update(getTime())
      frameProc(ctx(), dt, tickFraction)

    initValues(width, height, title, flags)
    setInit(hostInit)
    setFrame(hostFrame)
    let status = run()
    # On the web wgr_run returns at once and the browser drives the frames, so don't
    # exit() here: that would tear the program down.
    when not defined(emscripten):
      quit status
