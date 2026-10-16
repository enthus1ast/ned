#!/bin/bash
# build.sh [OUT] — the engine driver for compare.py: ned's source with driver.nim in place of its main
# (default OUT: ./ned-engine)
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=${1:-$here/ned-engine}
tmp=$(mktemp -d)
printf 'include "%s/src/ned.nim"\ninclude "%s/driver.nim"\n' "$root" "$here" > "$tmp/drv.nim"
nim c -d:release -d:nedNoMain --hints:off --warnings:off --nimcache:"$tmp/cache" -o:"$out" "$tmp/drv.nim"
rm -rf "$tmp"
echo "built $out"
