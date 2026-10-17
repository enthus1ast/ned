#!/bin/sh
# The built-in Nim formatter checked by Nim's own parser over a Nim source tree: each file is formatted into a
# scratch folder with `nedfmt --verify` — the result must parse to the same tree as the original (comments and
# layout aside), else the file is left alone and named. Needs a Nim with its compiler sources (choosenim, a source
# build, or `nimble install compiler`); the checker is built once and kept in ~/.cache/ned.
#
#   tests/format/parsecheck.sh [NIMROOT] [LIST]
#     NIMROOT  the Nim source tree whose files are formatted (default: the one of the nim on PATH)
#     LIST     its files to format, one per line, from NIMROOT (default: tests/format/corpus.txt — 463 files of
#              the compiler and the standard library)
# Exit status 0 when Nim's parser reads every result as the original.
set -e
here=$(cd "$(dirname "$0")/../.." && pwd)
root=$1
list=${2:-$here/tests/format/corpus.txt}
if [ -z "$root" ]; then
  nim=$(command -v nim) || { echo "parsecheck: no nim on PATH" >&2; exit 2; }
  root=$(dirname "$(dirname "$(readlink -f "$nim")")")
fi
[ -f "$root/lib/system.nim" ] || { echo "parsecheck: $root is not a Nim source tree (no lib/system.nim)" >&2; exit 2; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
echo "building nedfmt…"
nim c -d:release --hints:off --nimcache:"$tmp/cache" -o:"$tmp/nedfmt" "$here/src/nedfmt.nim" >"$tmp/build.log" 2>&1 ||
  { cat "$tmp/build.log"; exit 2; }
cd "$root"
grep -v '^#' "$list" | while read -r f; do [ -f "$f" ] && echo "$f"; done > "$tmp/files"
n=$(wc -l < "$tmp/files")
# ned's default layout (not your settings), each result checked by Nim's parser
XDG_CONFIG_HOME="$tmp/config" xargs "$tmp/nedfmt" --verify --quiet --outDir:"$tmp/out" < "$tmp/files" 2> "$tmp/err" || true
bad=$(grep -c "Nim's parser reads" "$tmp/err" || true)
other=$(grep -v "Nim's parser reads\|building the Nim parser" "$tmp/err" | grep -c . || true)
echo "$n files: $bad read differently by Nim's parser; $other left alone by the formatter's own check"
grep "Nim's parser reads\|could not\|needs Nim" "$tmp/err" || true
[ "$bad" = 0 ] && ! grep -q "needs Nim's compiler sources\|could not build" "$tmp/err"
