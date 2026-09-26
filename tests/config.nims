# The tests build nimhcr's modules as a program's builds do (with the allocator a hot
# build uses); a test of the hot build's host side has its own <test>.nims with
# -d:hcrHost. Wrapped like the other configs (see examples/simple/config.nims).
when not declared(nimscript):
  from std/os import `/`, parentDir
  switch("path", currentSourcePath().parentDir / ".." / "src")
  switch("define", "useMalloc")
