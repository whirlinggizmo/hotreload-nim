# Package

version       = "0.1.0"
author        = "Rob Knopf"
description   = "Hot reload for Nim programs: rebuild the code while it runs, keep its state"
license       = "MIT"
srcDir        = "src"
installExt    = @["nim", "nims"]

# Dependencies

requires "nim >= 2.2.0"
