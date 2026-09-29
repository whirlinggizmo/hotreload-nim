#!/usr/bin/env bash
# run.sh <scenario> [extra nim flags...]: builds scen/<s>/v1 hot, runs it, applies v2, v3, ...
# each a directory of files copied into src/ (a file named DELETE lists files to remove)
set -u
M=$(cd "$(dirname "$0")" && pwd)
S=$1; shift
FLAGS="$*"
TAG=$S${TAGSUFFIX:-}
mkdir -p $M/logs
LOG=$M/logs/$TAG.log
WAIT=${WAIT:-1.5}
cd $M
rm -rf src; mkdir src
cp scen/$S/v1/* src/
[ -f src/main.nim ] || cp main_default.nim src/main.nim
: > $LOG
echo "$EPOCHREALTIME DRIVER build exe ($FLAGS)" >> $LOG
if ! nim c -d:hotReload -d:useMalloc --debugger:native --hints:off $FLAGS \
     --nimcache:build/linux/hot/exe-$TAG --out:out/hot/matrix src/main.nim >> $LOG 2>&1; then
  echo "$EPOCHREALTIME DRIVER EXE BUILD FAILED" >> $LOG; exit 1
fi
echo "$EPOCHREALTIME DRIVER exe built" >> $LOG
( timeout -s INT 240 ./out/hot/matrix 2>&1 | while IFS= read -r l; do echo "$EPOCHREALTIME $l"; done >> $LOG ) &
for n in $(seq 1 100); do grep -q " START" $LOG && break; sleep 0.1; done
sleep ${FIRSTWAIT:-1.5}
PAT='hotreload: reloaded|build failed|signature changed|can.t load'
for v in $(ls -d scen/$S/v* | sort -V | tail -n +2); do
  before=$(grep -cE "$PAT" $LOG)
  if [ -f $v/DELETE ]; then while read -r f; do rm -f src/$f; done < $v/DELETE; fi
  for f in $v/*; do b=$(basename $f); [ "$b" = DELETE ] && continue
    cp $f src/.$b.tmp && mv src/.$b.tmp src/$b; done
  echo "$EPOCHREALTIME DRIVER applied $(basename $v)" >> $LOG
  for n in $(seq 1 1200); do [ $(grep -cE "$PAT" $LOG) -gt $before ] && break; sleep 0.05; done
  sleep $WAIT
done
pkill -INT -f "$M/out/hot/matrix" ; pkill -INT -x matrix
sleep 0.5
echo "$EPOCHREALTIME DRIVER done" >> $LOG
