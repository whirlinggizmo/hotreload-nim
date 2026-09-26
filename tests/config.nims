# The tests build the host's modules as the app's builds do (with its allocator); a test
# of the hot build's host side has its own <test>.nims with -d:hcrHost. Wrapped like the
# other configs (see the root's config.nims).
when not declared(nimscript):
  from std/os import `/`, parentDir
  switch("path", currentSourcePath().parentDir / ".." / "host")
  switch("define", "useMalloc")
