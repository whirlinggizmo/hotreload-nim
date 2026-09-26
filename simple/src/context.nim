## What the app keeps between frames: owned by the host, so a reload keeps it; the app's
## code is passed it. Plain values only (handles, numbers, strings, and objects, tuples,
## seqs and arrays of them): no refs, pointers or closures, which belong to one library.
##
## It can change while `nim hot` runs: after a reload that changes it, each field that's
## still here with the same type keeps its value, and a new one starts at its default
## (`field: T = value`).

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

hotContext(Context)
