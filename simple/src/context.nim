## What the app keeps between frames: owned by the host, so a reload keeps it; the app's
## code is passed it. Values and refs (handles, numbers, strings, refs, and objects,
## tuples, seqs and arrays of them), not pointers or closures, which belong to one library.
## Refs are copied to the new code on each reload, as a graph (what's shared stays
## shared); a ref to an object that inherits can't be.
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
