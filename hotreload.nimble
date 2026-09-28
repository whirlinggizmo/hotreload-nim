# Package

version       = "0.0.1"
author        = "Rob Knopf"
description   = "Hot reload for Nim programs: rebuild the code while it runs, keep its state"
license       = "MIT"
srcDir        = "src"
installExt    = @["nim"]
# A plain `nimble install` copies only srcDir, but a project's own dependencies
# (nimbledeps/) get every .nim file in the repo, so say it outright
skipDirs      = @["examples"]

# Dependencies

requires "nim >= 2.2.0"
