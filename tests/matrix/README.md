# The capability matrix

The programs behind [docs/comparison.md](../../docs/comparison.md): each scenario edits a
running hot program and records what the reload did. hotreload-hx has the same scenarios
in its `tests/matrix/`.

```bash
./run.sh S7               # one scenario: logs/S7.log
./times.sh logs/S1.log    # save to "building" and to "reloaded", per edit
TAGSUFFIX=-release ./run.sh S16 -d:release   # extra nim flags after the scenario
```

`run.sh <scenario>` builds `scen/<scenario>/v1` hot (with `main_default.nim`, unless the
scenario has its own `main.nim`), runs it, and copies each later version (`v2`, `v3`, ...)
into `src/` in turn, as an editor saves: a temporary file, then a rename. Each line the
program prints goes to `logs/<scenario>.log` with its time, beside the driver's own
`DRIVER` lines. It waits for each version's reload (or its failure) before the next.

The scenarios, and what they showed on 2026-09-29, are in the comparison's "What each can
do" table: S1 to S18, with S8c (inheritance only in v2) and S9a/S9b (a closure, a nimcall
proc). The logs are read by hand; nothing here passes or fails on its own.
