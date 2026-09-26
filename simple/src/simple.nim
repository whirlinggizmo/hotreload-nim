## wgrender's simple example, as an app the host runs (host/wgrhost.nim): setup, assets,
## each frame's update, picking and drawing. Edit it while `nim hot` runs (BobSpeed, the
## colors, the text) and the host rebuilds it and swaps it in.

import std/[math, strformat]
import wgr
import wgrhost
import ./context

const
  DebugFontPath = "fonts/JetBrainsMono/JetBrainsMono-Regular.ttf"
  KomikaFontPath = "fonts/Komika/KOMIKAH_.ttf"
  CharacterPath = "models/woman_casual/woman_casual.glb"
  SpritePath = "sprites/logo/wg-logo-bw-alpha.png"
  MusicPath = "music/a_hero_is_born.mp3"

  DebugFontSize = 18
  KomikaFontSize = 24

  SpriteYOffset = 3.0
  BobSpeed = 1.0
  BobHeight = 1.5

var reloads {.hot.} = 0
  ## how many times this code has been reloaded: a global that survives it (hot build)

proc update(ctx: var Context; dt: float) =
  ctx.elapsed += dt
  ctx.countdownTimer -= dt

  if not ctx.model.isNone:
    ctx.model.animate(dt)
  if not ctx.sprite.isNone:
    let y = sin(ctx.elapsed * BobSpeed) * BobHeight + SpriteYOffset
    ctx.sprite.setPosition(0, y, 0)

proc updatePickMessage(ctx: var Context; mouse: MouseState) =
  let pick = ctx.scene.pick(mouse.x.float, mouse.y.float)
  let what =
    if not pick.hit: ""
    elif pick.handle == ctx.model: "Model"
    elif pick.handle == ctx.sprite: "Sprite"
    else: ""
  if what.len == 0:
    ctx.message = "Nothing picked!"
    return
  ctx.message = &"{what} pick: Mouse position (mouse.x:{mouse.x}, mouse.y:{mouse.y}) " &
              &"pick result y: {pick.pointWorld.y:.6f}"

# Draw with the TTF font once it's loaded, the built-in font until then.
proc drawText(font: Font; text: string; x, y: float; size: int; color: Color) =
  if not font.isNone:
    font.drawText(text, x, y, size.float, color)
  else:
    drawText(text, x.int, y.int, size, color)

proc drawCenteredMessage(ctx: Context) =
  let screen = getScreenSize()
  let size =
    if not ctx.komikaFont.isNone: ctx.komikaFont.measureText(ctx.message, KomikaFontSize)
    else: (measureText(ctx.message, KomikaFontSize).float, KomikaFontSize.float)
  drawText(ctx.komikaFont, ctx.message, (screen.x - size.x) / 2, (screen.y - size.y) / 2,
           KomikaFontSize, ColorBlue)

proc drawOverlay(ctx: Context; mouse: MouseState) =
  drawText(ctx.debugFont, &"Remaining: {ctx.countdownTimer:.2f}", 10, 36, DebugFontSize, ColorBlack)
  drawText(ctx.debugFont, &"Elapsed: {ctx.elapsed:.2f}", 10, 56, DebugFontSize, ColorBlack)
  drawText(ctx.debugFont,
           &"Mouse: ({mouse.x}, {mouse.y}) w:{mouse.wheel:.1f} " &
           &"b:[{mouse.left}, {mouse.right}, {mouse.middle}]",
           10, 76, DebugFontSize, ColorBlack)
  drawText(ctx.debugFont, ctx.platformText, 10, 96, DebugFontSize, ColorBlack)
  drawText(ctx.debugFont, &"Reloads: {reloads}", 10, 116, DebugFontSize, ColorBlack)

  ctx.debugFont.drawFps(10, 10, DebugFontSize, ctx.greyAlpha)

proc onInit*(ctx: var Context) {.reloadable.} =
  ## once, at startup
  setLogLevel(LogLevel.Warn)
  setTargetFps(60)

  ctx.countdownTimer = 30.0
  ctx.message = "Hello from wgrender simple (Nim)!"
  ctx.platformText = "Platform: " & getPlatform()

  ctx.camera = newCamera3d(Projection.Perspective) # default fov: pi/4 (45 degrees)
  ctx.camera.setView(position = (12.0, 12.0, 12.0), target = (0.0, 1.0, 0.0))
  ctx.scene = newScene()
  ctx.scene.setActiveCamera(ctx.camera)

  # same lighting as librl's c-simple: a directional light plus ambient 0.25
  let sun = newLight(LightKind.Directional)
  sun.setDirection((-0.6, -1.0, -0.5))
  sun.setIntensity(3.0)
  ctx.scene.add(sun)
  ctx.scene.setAmbient(ColorWhite, 0.25)
  ctx.backgroundColor = rgba(245, 245, 245, 255)
  ctx.greyAlpha = rgba(0, 0, 0, 128)

  # each asset, once it's local and ready at `path`: create the resource, then the object
  ctx.requestAsset(MusicPath) do (ctx: var Context; path: string):
    let audio = newAudio(path)
    ctx.bgm = newSound(audio)
    audio.release() # the sound holds its own reference
    ctx.bgm.setLoop(true)
    ctx.bgm.play()

  ctx.requestAsset(CharacterPath) do (ctx: var Context; path: string):
    let mesh = newMesh(path)
    ctx.model = newModel(mesh)
    mesh.release() # the model holds its own reference
    ctx.model.setAnimation(1)
    ctx.model.setAnimationSpeed(1.0)
    ctx.model.setAnimationLoop(true)
    ctx.model.setPosition(0, 0, 0)
    ctx.model.setTint(ColorRaywhite)
    ctx.scene.add(ctx.model)

  ctx.requestAsset(SpritePath) do (ctx: var Context; path: string):
    let texture = newTexture(path)
    ctx.sprite = newSprite3d(texture)
    texture.release() # the sprite holds its own reference
    ctx.sprite.setFacing(SpriteFacing.Free) # librl's default: oriented by its rotation
    ctx.sprite.setPosition(0, SpriteYOffset, 0)
    ctx.sprite.setTint(ColorRaywhite)
    ctx.scene.add(ctx.sprite)

  # Fonts are sized per draw call in wgrender, so one font handle serves any size.
  ctx.requestAsset(DebugFontPath) do (ctx: var Context; path: string):
    ctx.debugFont = newFont(path)
  ctx.requestAsset(KomikaFontPath) do (ctx: var Context; path: string):
    ctx.komikaFont = newFont(path)

proc onLoad*(ctx: var Context; reloaded: bool) {.reloadable.} =
  ## once at startup (reloaded = false), then after each reload, on the new code: set up
  ## or fix up what the new code expects of the context
  if reloaded:
    inc reloads
    echo "simple: reloaded (", reloads, ")"

proc onUnload*(ctx: var Context) {.reloadable.} =
  ## on the old code, just before a reload replaces it
  echo "simple: unloading"

proc onFrame*(ctx: var Context; dt, tickFraction: float) {.reloadable.} =
  let mouse = getMouseState()
  #echo mouse

  # Escape quits on desktop; a web page has nothing to quit to.
  when not defined(emscripten):
    if isKeyPressed(Key.Escape):
      requestQuit()

  ctx.update(dt)
  ctx.updatePickMessage(mouse)

  beginFrame()
  clearBackground(ctx.backgroundColor)
  ctx.scene.draw()
  ctx.drawCenteredMessage()
  ctx.drawOverlay(mouse)
  endFrame()

runApp("simple (wgrender, Nim, hot reload)", 1024, 1280,
        {WindowFlag.Msaa4x, WindowFlag.Resizable})
