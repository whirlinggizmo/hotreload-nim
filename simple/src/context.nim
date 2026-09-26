## What the app keeps between frames: owned by the host, so a reload keeps it; the
## script is passed it. Plain values only (handles, numbers, strings): no refs or
## closures, which would belong to one library's runtime.
##
## Changing this file needs a restart: the host refuses a script built from another
## version of it (ContextStamp).

import std/hashes
import wgr
import hcr

type
  Context* = object
    elapsed*: float
    countdownTimer*: float
    debugFont*: Font
    greyAlpha*: Color
    komikaFont*: Font
    sprite*: Sprite3d
    model*: Model
    bgm*: Sound
    camera*: Camera3d
    scene*: Scene
    backgroundColor*: Color
    message*: string
    platformText*: string

const ContextStamp* = hash(staticRead(currentSourcePath()))
  ## this file, hashed: what the host checks a reloaded script against

proc hcrContextStamp*(): int {.reloadable.} = ContextStamp
