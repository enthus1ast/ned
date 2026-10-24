#!/bin/bash
# termux.sh [OUTDIR] — ned, nedls and nedfmt for Termux (Android, arm64) built here with zig, and the Termux
# package (ned_<version>_aarch64.deb: `pkg install ./ned_*.deb` on the phone, or `dpkg -i`).
# Needs nim and zig (https://ziglang.org — `pip install ziglang` works) and dpkg-deb.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=${1:-$root/build/termux}
mkdir -p "$out/zcc"
ZIG=${ZIG:-$(command -v zig || python3 -c 'import ziglang, os; print(os.path.join(os.path.dirname(ziglang.__file__), "zig"))' 2>/dev/null || true)}
[ -n "$ZIG" ] || { echo "zig not found (pip install ziglang)"; exit 2; }
z="$out/zcc/zcc-aarch64-linux-musl"
# (-g0: zig cc makes debug information by default — on ned's biggest C file that more than doubles the memory the
#  compile takes, past 6 GB, and the programs are stripped anyway)
printf '#!/bin/sh\nexec "%s" cc -target aarch64-linux-musl -g0 "$@"\n' "$ZIG" > "$z"
chmod +x "$z"
version=$(sed -n 's/^const NedVersion\* = "\(.*\)"/\1/p' "$root/src/ned/version.nim")
nimlib=$(dirname "$(dirname "$(readlink -f "$(command -v nim)")")")/lib
flags=(-d:release --opt:speed -d:strip --hints:off --os:android --cpu:arm64 --cc:clang --clang.exe:"$z"
       --clang.linkerexe:"$z")
build() { # program
  local p=$1 cache="$out/cache-$1"
  local t0=$(date +%s)
  if ! nim c "${flags[@]}" --nimcache:"$cache" -o:"$out/$p" "$root/src/$p.nim" > "$out/$p.log" 2>&1; then
    # (zig's clang can abort on ned's biggest C file when several compile at once: that one alone, then the rest)
    big=$(ls -S "$cache"/@m*.nim.c 2>/dev/null | head -1)
    # (the compiles nim started beside the one that failed go on after it: let them end first)
    for _ in $(seq 600); do pgrep -f -- "-o $cache/" > /dev/null || break; sleep 1; done
    # (the `|| true`: when even that aborts, the one-at-a-time build below still tries — not set -e's silent end)
    { [ -n "$big" ] && "$z" -c -w -ferror-limit=3 -fno-strict-aliasing -pthread -O3 -I"$nimlib" -I"$root/src" \
                            -o "$big.o" "$big" >> "$out/$p.log" 2>&1; } || true
    nim c "${flags[@]}" --parallelBuild:1 --nimcache:"$cache" -o:"$out/$p" "$root/src/$p.nim" >> "$out/$p.log" 2>&1 ||
      { echo "$p FAILED (see $out/$p.log)"; exit 1; }
  fi
  echo "$p OK $(( $(date +%s) - t0 ))s"
}
for p in ned nedls nedfmt; do build $p; done
# the package: Termux's prefix, its documentation, the example plugins
pkg="$out/pkg"
rm -rf "$pkg"
pre="$pkg/data/data/com.termux/files/usr"
mkdir -p "$pre/bin" "$pre/share/doc/ned" "$pre/share/ned" "$pkg/DEBIAN"
for p in ned nedls nedfmt; do install -m 755 "$out/$p" "$pre/bin/$p"; done
install -m 644 "$root/README.md" "$root/CHANGELOG.md" "$root/LICENSE" "$pre/share/doc/ned/"
cp -r "$root/docs" "$pre/share/doc/ned/docs"       # (the README's links into docs/ work there too)
cp -r "$root/examples/plugins" "$pre/share/ned/plugins"
size=$(du -sk "$pkg/data" | cut -f1)
cat > "$pkg/DEBIAN/control" <<EOF
Package: ned
Version: $version
Architecture: aarch64
Maintainer: Foxoman
Installed-Size: $size
Recommends: nim, git, ripgrep
Suggests: clang, gdb, python
Description: a terminal code editor and Nim IDE for Termux
 Desktop-style UI in the terminal, a built-in Nim engine (also as a language
 server: nedls) and formatter (nedfmt), an integrated terminal, git, an AI
 assistant, vim, Emacs and Helix keys, and plugins written in NimScript.
EOF
deb="$out/ned_${version}_aarch64.deb"
dpkg-deb --root-owner-group -Zxz --build "$pkg" "$deb" > /dev/null
echo "$deb"
