## The code of wgrender's simple example, which `nim hot` reloads: setup, assets, each
## frame's update, picking and drawing. Edit it while it runs (BobSpeed, the colors, the
## text) and it's rebuilt and swapped in (hotreload: src/hotreload/reload.nim). Its state
## is hot globals, which a reload keeps; main.nim, the program, calls its hot procs.

import std/[math, strformat]
import wgr
import hotreload

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

var
  elapsed {.hot.} = 0.0
  countdownTimer {.hot.} = 0.0
  debugFont {.hot.}: Font
  komikaFont {.hot.}: Font
  greyAlpha {.hot.}: Color
  sprite {.hot.}: Sprite3d
  model {.hot.}: Model
  bgm {.hot.}: Sound
  camera {.hot.}: Camera3d
  scene {.hot.}: Scene
  backgroundColor {.hot.}: Color
  message {.hot.} = ""
  platformText {.hot.} = ""
  reloads {.hot.} = 0
    ## how many times this code has been reloaded

proc requestAsset(name: string; onReady: proc (path: string)) =
  ## load an asset; `onReady` runs on a later frame with it at `path`, local and ready.
  ## One that arrives after a reload moved hot globals to new storage is skipped: it's
  ## the old code's, which would write to their old copies
  let moves = hotMoves()
  let onFailed = proc (path: string) = logError("failed to import asset: " & name)
  let ready = proc (path: string) =
    if hotMoves() == moves: onReady(path)
    else: echo "simple: " & name & " arrived after a reload moved hot globals: ask again"
  if not ensureAssetAsync(name).addTask(ready, onFailed):
    onFailed(name)

proc update(dt: float) =
  elapsed += dt
  countdownTimer -= dt

  if not model.isNone:
    model.animate(dt)
  if not sprite.isNone:
    let y = sin(elapsed * BobSpeed) * BobHeight + SpriteYOffset
    sprite.setPosition(0, y, 0)

proc updatePickMessage(mouse: MouseState) =
  let pick = scene.pick(mouse.x.float, mouse.y.float)
  let what =
    if not pick.hit: ""
    elif pick.handle == model: "Model"
    elif pick.handle == sprite: "Sprite"
    else: ""
  if what.len == 0:
    message = "Nothing picked!"
    return
  message = &"{what} pick: Mouse position (mouse.x:{mouse.x}, mouse.y:{mouse.y}) " &
            &"pick result y: {pick.pointWorld.y:.6f}"

# Draw with the TTF font once it's loaded, the built-in font until then.
# (Drawing with a None handle will fall back to default)
proc drawText(font: Font; text: string; x, y: float; size: int; color: Color) =
  font.drawText(text, x, y, size.float, color)

proc drawCenteredMessage() =
  let screen = getScreenSize()
  let size =
    if not komikaFont.isNone: komikaFont.measureText(message, KomikaFontSize)
    else: (measureText(message, KomikaFontSize).float, KomikaFontSize.float)
  drawText(komikaFont, message, (screen.x - size.x) / 2, (screen.y - size.y) / 2,
           KomikaFontSize, ColorBlue)

proc drawOverlay(mouse: MouseState) =
  drawText(debugFont, &"Remaining: {countdownTimer:.2f}", 10, 36, DebugFontSize, ColorBlack)
  drawText(debugFont, &"Elapsed: {elapsed:.2f}", 10, 56, DebugFontSize, ColorBlack)
  drawText(debugFont,
           &"Mouse: ({mouse.x}, {mouse.y}) w:{mouse.wheel:.1f} " &
           &"b:[{mouse.left}, {mouse.right}, {mouse.middle}]",
           10, 76, DebugFontSize, ColorBlack)
  drawText(debugFont, platformText, 10, 96, DebugFontSize, ColorBlack)
  drawText(debugFont, &"Reloads: {reloads}", 10, 116, DebugFontSize, ColorBlack)

  debugFont.drawFps(10, 10, DebugFontSize, greyAlpha)

proc onInit*() =
  ## once, at startup
  setLogLevel(LogLevel.Warn)
  setTargetFps(60)

  countdownTimer = 30.0
  message = "Hello from wgrender simple (Nim)!"
  platformText = "Platform: " & getPlatform()

  camera = newCamera3d(Projection.Perspective) # default fov: pi/4 (45 degrees)
  camera.setView(position = (12.0, 12.0, 12.0), target = (0.0, 1.0, 0.0))
  scene = newScene()
  scene.setActiveCamera(camera)

  # same lighting as librl's c-simple: a directional light plus ambient 0.25
  let sun = newLight(LightKind.Directional)
  sun.setDirection((-0.6, -1.0, -0.5))
  sun.setIntensity(3.0)
  scene.add(sun)
  scene.setAmbient(ColorWhite, 0.25)
  backgroundColor = rgba(245, 245, 245, 255)
  greyAlpha = rgba(0, 0, 0, 128)

  # each asset, once it's local and ready at `path`: create the resource, then the object
  requestAsset(MusicPath) do (path: string):
    let audio = newAudio(path)
    bgm = newSound(audio)
    audio.release() # the sound holds its own reference
    bgm.setLoop(true)
    bgm.play()

  requestAsset(CharacterPath) do (path: string):
    let mesh = newMesh(path)
    model = newModel(mesh)
    mesh.release() # the model holds its own reference
    model.setAnimation(1)
    model.setAnimationSpeed(1.0)
    model.setAnimationLoop(true)
    model.setPosition(0, 0, 0)
    model.setTint(ColorRaywhite)
    scene.add(model)

  requestAsset(SpritePath) do (path: string):
    let texture = newTexture(path)
    sprite = newSprite3d(texture)
    texture.release() # the sprite holds its own reference
    sprite.setFacing(SpriteFacing.Free) # librl's default: oriented by its rotation
    sprite.setPosition(0, SpriteYOffset, 0)
    sprite.setTint(ColorRaywhite)
    scene.add(sprite)

  # Fonts are sized per draw call in wgrender, so one font handle serves any size.
  requestAsset(DebugFontPath) do (path: string):
    debugFont = newFont(path)
  requestAsset(KomikaFontPath) do (path: string):
    komikaFont = newFont(path)

proc countReload() {.afterHotReload.} =
  ## after each reload, on the new code
  inc reloads
  echo "simple: reloaded (", reloads, ")"

proc sayGoodbye() {.beforeHotReload.} =
  ## on the old code, just before a reload replaces it
  echo "simple: unloading"

proc onFrame*(dt, tickFraction: float) {.hot.} =
  let mouse = getMouseState()
  if isKeyPressed(Key.A):
    echo &"x:{mouse.x}, y:{mouse.y}"

  # Escape quits on desktop; a web page has nothing to quit to.
  when not defined(emscripten):
    if isKeyPressed(Key.Escape):
      requestQuit()

  update(dt)
  updatePickMessage(mouse)

  beginFrame()
  clearBackground(backgroundColor)
  scene.draw()
  drawCenteredMessage()
  drawOverlay(mouse)
  endFrame()
