# Package

version       = "0.1.2"
author        = "Rob Knopf"
description   = "Hot reload for Nim programs: rebuild the code while it runs, keep its state"
license       = "MIT"
srcDir        = "src"
installExt    = @["nim"]
# Everything but src/. A plain `nimble install` copies only srcDir, and nimble leaves
# out tests/ itself, but a project's own dependencies (nimbledeps/) get every .nim file
# in the repo (nimble 0.24 ignores srcDir and skipDirs there), so say it outright
skipDirs      = @["examples", "tests", ".github", ".vscode"]

# Dependencies

requires "nim >= 2.2.0"
