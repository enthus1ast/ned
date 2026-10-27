#!/bin/bash
# cross.sh [OUTDIR] — ned built for every target this machine can reach: the host compiler, clang, and with
# zig (https://ziglang.org, `pip install ziglang` works) macOS arm64/x86_64, Android/Linux arm64 (musl) and
# Windows x86_64 (tests/build/windows.sh makes the release's zip).
# One line per target; exit status 1 when one fails. NIM224: a second Nim's bin folder to build with too.
# nedfmt and nedls (the formatter and the language server) are built for Linux, Android and macOS arm64 as well.
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=${1:-$root/build}
mkdir -p "$out/zcc"
ZIG=${ZIG:-$(command -v zig || python3 -c 'import ziglang, os; print(os.path.join(os.path.dirname(ziglang.__file__), "zig"))' 2>/dev/null || true)}
fails=0
run() { # name, extra PATH (or ""), nim flags…  (SRC=nedfmt.nim run …: another program than ned)
  local name=$1 pre=$2 src=${SRC:-ned.nim}; shift 2
  local t0=$(date +%s)
  if PATH=${pre:+$pre:}$PATH nim c -d:release --hints:off --nimcache:"$out/cache-$name" "$@" "$root/src/$src" > "$out/$name.log" 2>&1; then
    echo "$name OK $(( $(date +%s) - t0 ))s"
  elif grep -q "exit code: 134" "$out/$name.log" && PATH=${pre:+$pre:}$PATH nim c -d:release --hints:off --parallelBuild:1 --nimcache:"$out/cache-$name" "$@" "$root/src/$src" > "$out/$name.log" 2>&1; then
    # (zig's clang aborts when several big C files are compiled at once and memory runs short: one at a time)
    echo "$name OK $(( $(date +%s) - t0 ))s (zig aborted once: built again, one C file at a time)"
  else
    echo "$name FAILED (see $out/$name.log)"; fails=1
  fi
}
zcc() { # a wrapper that makes zig a C compiler for one target
  printf '#!/bin/sh\nexec "%s" cc -target %s -g0 "$@"\n' "$ZIG" "$1" > "$out/zcc/zcc-$1"; chmod +x "$out/zcc/zcc-$1"
  echo "$out/zcc/zcc-$1"
}
run linux-gcc "" -d:strip -o:"$out/ned-linux-gcc"
for p in nedfmt nedls; do SRC=$p.nim run $p-linux-gcc "" -d:strip -o:"$out/$p-linux-gcc"; done
command -v clang > /dev/null && run linux-clang "" --cc:clang -d:strip -o:"$out/ned-linux-clang"
[ -n "${NIM224:-}" ] && run linux-nim224 "$NIM224" -d:strip -o:"$out/ned-linux-nim224"
if [ -n "$ZIG" ]; then
  z=$(zcc aarch64-macos);      run macos-arm64 "" --os:macosx --cpu:arm64 --cc:clang --clang.exe:"$z" --clang.linkerexe:"$z" -d:strip -o:"$out/ned-macos-arm64"
  z=$(zcc x86_64-macos);       run macos-x86_64 "" --os:macosx --cpu:amd64 --cc:clang --clang.exe:"$z" --clang.linkerexe:"$z" -d:strip -o:"$out/ned-macos-x86_64"
  z=$(zcc aarch64-linux-musl); run android-arm64 "" --os:android --cpu:arm64 --cc:clang --clang.exe:"$z" --clang.linkerexe:"$z" -d:strip -o:"$out/ned-android-arm64"
  z=$(zcc x86_64-windows-gnu); run windows-x86_64 "" --os:windows --cpu:amd64 --cc:clang --clang.exe:"$z" --clang.linkerexe:"$z" -d:strip -o:"$out/ned-windows-x86_64.exe"
  for p in nedfmt nedls; do
    z=$(zcc x86_64-windows-gnu); SRC=$p.nim run $p-windows-x86_64 "" --os:windows --cpu:amd64 --cc:clang --clang.exe:"$z" --clang.linkerexe:"$z" -d:strip -o:"$out/$p-windows-x86_64.exe"
    z=$(zcc aarch64-linux-musl); SRC=$p.nim run $p-android-arm64 "" --os:android --cpu:arm64 --cc:clang --clang.exe:"$z" --clang.linkerexe:"$z" -d:strip -o:"$out/$p-android-arm64"
    z=$(zcc aarch64-macos);      SRC=$p.nim run $p-macos-arm64 "" --os:macosx --cpu:arm64 --cc:clang --clang.exe:"$z" --clang.linkerexe:"$z" -d:strip -o:"$out/$p-macos-arm64"
  done
else
  echo "zig not found: macOS, Android and Windows builds skipped"
fi
# (the programs' SHA-256 in $out/SHA256SUMS, signed with NED_SIGNING_KEY when it is set: tests/build/sums.sh)
set --
for f in "$out"/ned-* "$out"/nedfmt-* "$out"/nedls-*; do
  case "$f" in *.log) ;; *) [ -f "$f" ] && set -- "$@" "$f" ;; esac
done
[ $# -gt 0 ] && { sh "$here/sums.sh" "$out" "$@" || fails=1; }
exit $fails
