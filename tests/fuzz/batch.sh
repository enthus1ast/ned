#!/bin/bash
# batch.sh [SECONDS [MODE …]] — a fuzz round per mode (default: 120 s of "mixed"); a summary of what went wrong.
# NEDBIN: the binary to fuzz (a build with stack traces says where). Exit status 1 when anything went wrong.
here=$(cd "$(dirname "$0")" && pwd)
S=${1:-120}; [ $# -gt 0 ] && shift
modes=("$@"); [ ${#modes[@]} -eq 0 ] && modes=(mixed)
OUT=${NED_FUZZ_OUT:-/tmp/ned-fuzz-$(id -u)-logs}; mkdir -p "$OUT"
sum=$OUT/batch.out; : > "$sum"
for m in "${modes[@]}"; do
  seed=$RANDOM$RANDOM
  NED_FUZZ_OUT=$OUT timeout $((S + 120)) python3 "$here/fuzz.py" $seed $S $m > /dev/null 2>&1
  echo "== $m seed $seed: $(grep "exit took" "$OUT/run_$seed.log") $(tail -1 "$OUT/run_$seed.log")" >> "$sum"
  grep -A30 "=== CRASH\|=== HANG\|=== NED DID" "$OUT/run_$seed.log" | head -40 >> "$sum"
done
cat "$sum"
if grep -q "=== CRASH\|=== HANG\|=== NED DID" "$sum" || grep -qE "errors.log [1-9][0-9]* bytes" "$sum"; then exit 1; fi
