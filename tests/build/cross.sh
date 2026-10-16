#!/bin/bash
# cross.sh [OUTDIR] — ned built for every target this machine can reach: the host compiler, clang, and with
# zig (https://ziglang.org, `pip install ziglang` works) macOS arm64/x86_64 and Android/Linux arm64 (musl).
# One line per target; exit status 1 when one fails. NIM224: a second Nim's bin folder to build with too.
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=${1:-$root/build}
mkdir -p "$out/zcc"
ZIG=${ZIG:-$(command -v zig || python3 -c 'import ziglang, os; print(os.path.join(os.path.dirname(ziglang.__file__), "zig"))' 2>/dev/null || true)}
fails=0
run() { # name, extra PATH (or ""), nim flags…
  local name=$1 pre=$2; shift 2
  local t0=$(date +%s)
  if PATH=${pre:+$pre:}$PATH nim c -d:release --hints:off --nimcache:"$out/cache-$name" "$@" "$root/src/ned.nim" > "$out/$name.log" 2>&1; then
    echo "$name OK $(( $(date +%s) - t0 ))s"
  elif grep -q "exit code: 134" "$out/$name.log" && PATH=${pre:+$pre:}$PATH nim c -d:release --hints:off --nimcache:"$out/cache-$name" "$@" "$root/src/ned.nim" > "$out/$name.log" 2>&1; then
    echo "$name OK $(( $(date +%s) - t0 ))s (zig aborted once: built again)"
  else
    echo "$name FAILED (see $out/$name.log)"; fails=1
  fi
}
zcc() { # a wrapper that makes zig a C compiler for one target
  printf '#!/bin/sh\nexec "%s" cc -target %s "$@"\n' "$ZIG" "$1" > "$out/zcc/zcc-$1"; chmod +x "$out/zcc/zcc-$1"
  echo "$out/zcc/zcc-$1"
}
run linux-gcc "" -d:strip -o:"$out/ned-linux-gcc"
command -v clang > /dev/null && run linux-clang "" --cc:clang -d:strip -o:"$out/ned-linux-clang"
[ -n "${NIM224:-}" ] && run linux-nim224 "$NIM224" -d:strip -o:"$out/ned-linux-nim224"
if [ -n "$ZIG" ]; then
  z=$(zcc aarch64-macos);      run macos-arm64 "" --os:macosx --cpu:arm64 --cc:clang --clang.exe:"$z" --clang.linkerexe:"$z" -d:strip -o:"$out/ned-macos-arm64"
  z=$(zcc x86_64-macos);       run macos-x86_64 "" --os:macosx --cpu:amd64 --cc:clang --clang.exe:"$z" --clang.linkerexe:"$z" -d:strip -o:"$out/ned-macos-x86_64"
  z=$(zcc aarch64-linux-musl); run android-arm64 "" --os:android --cpu:arm64 --cc:clang --clang.exe:"$z" --clang.linkerexe:"$z" -d:strip -o:"$out/ned-android-arm64"
else
  echo "zig not found: macOS and Android builds skipped"
fi
exit $fails
