#!/usr/bin/env bash
# save-to-reloaded (and to build start) per edit in a log
awk '/DRIVER applied/{t=$1; v=$4} /hotreload: building/{if(t) b=$1} /hotreload: reloaded|build failed|signature changed/{if(t){printf "%s: save->build start %.3fs, save->%s %.3fs\n", v, b-t, ($0 ~ /reloaded/ ? "reloaded" : "result"), $1-t; t=0}}' "$1"
