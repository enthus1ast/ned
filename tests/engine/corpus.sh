#!/bin/bash
# corpus.sh OUTDIR [N] — compare.py over every file in corpus.txt, two at a time, then the totals
#   NIMLIB  the Nim library (default: from `nim dump`), NED_PKGS  the nimble packages (default ~/.nimble/pkgs2)
here=$(cd "$(dirname "$0")" && pwd)
out=$1; n=${2:-120}
[ -z "$out" ] && { echo "usage: corpus.sh OUTDIR [N]"; exit 1; }
mkdir -p "$out"
export NIMLIB=${NIMLIB:-$(nim dump --dump.format:json /dev/null 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["libpath"])')}
export NED_PKGS=${NED_PKGS:-$HOME/.nimble/pkgs2}
one() {
  f=$(eval echo "$1")
  [ -f "$f" ] || { echo "missing: $f"; return; }
  b=$(basename "$f" .nim)_$(echo "$f" | md5sum | cut -c1-4)
  timeout 1800 python3 "$here/compare.py" "$f" --n "$2" --json "$3/$b.json" > "$3/$b.txt" 2>&1
}
export -f one; export here
grep -v '^#' "$here/corpus.txt" | grep -v '^$' | xargs -P 2 -I{} bash -c "one '{}' $n '$out'"
python3 "$here/aggregate.py" "$out"
