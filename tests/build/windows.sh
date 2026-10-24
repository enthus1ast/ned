#!/bin/bash
# windows.sh [OUTDIR] — ned, nedfmt and nedls for Windows (x86_64) built here with zig, and the release's zip
# (ned-<version>-windows-x86_64.zip: the three programs, the licence and a short README). Needs nim, zig
# (https://ziglang.org — `pip install ziglang` works) and zip (or python3). Windows is the least tried of ned's
# platforms: the CI job windows-x86_64 (.github/workflows/build.yml) builds it natively and runs its checks.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=${1:-$root/build/windows}
ZIG=${ZIG:-$(command -v zig || python3 -c 'import ziglang, os; print(os.path.join(os.path.dirname(ziglang.__file__), "zig"))' 2>/dev/null || true)}
[ -n "$ZIG" ] || { echo "zig not found (pip install ziglang)"; exit 1; }
ver=$(sed -n 's/^const NedVersion\* = "\(.*\)"/\1/p' "$root/src/ned/version.nim")
mkdir -p "$out/zcc" "$out/pkg"
z="$out/zcc/zcc-x86_64-windows-gnu"
printf '#!/bin/sh\nexec "%s" cc -target x86_64-windows-gnu -g0 "$@"\n' "$ZIG" > "$z"; chmod +x "$z"
for p in ned nedfmt nedls; do
  t0=$(date +%s)
  flags=(-d:release --opt:speed -d:strip --os:windows --cpu:amd64 --cc:clang --clang.exe:"$z" --clang.linkerexe:"$z"
         --hints:off --warnings:off --nimcache:"$out/cache-$p" -o:"$out/pkg/$p.exe")
  # (zig's clang can abort when several big C files compile at once and memory runs short: then one at a time)
  nim c "${flags[@]}" "$root/src/$p.nim" > "$out/$p.log" 2>&1 ||
    nim c "${flags[@]}" --parallelBuild:1 "$root/src/$p.nim" >> "$out/$p.log" 2>&1 ||
    { echo "$p FAILED (see $out/$p.log)"; exit 1; }
  echo "$p.exe $(( $(date +%s) - t0 ))s"
done
cp "$root/LICENSE" "$out/pkg/LICENSE.txt"
cat > "$out/pkg/README.txt" <<TXT
ned $ver for Windows (x86-64) — experimental: WSL is the tried way (see the README's Installing › Windows).

  ned.exe      the editor:    .\ned.exe   ·   .\ned.exe FILE   ·   .\ned.exe --check   ·   .\ned.exe --help
  nedfmt.exe   the formatter: .\nedfmt.exe --help
  nedls.exe    the Nim language server (for other editors)

Run it in Windows Terminal (or the console of Windows 10 1809 and later). For the Nim features, nim on the PATH;
for tasks and builds, Git for Windows (its sh runs ned's commands). Documentation: the docs/ folder of ned's
source (docs/README.md), and F1 in ned for the keys.
TXT
rm -f "$out/ned-$ver-windows-x86_64.zip"
if command -v zip > /dev/null; then
  (cd "$out/pkg" && zip -q -9 "../ned-$ver-windows-x86_64.zip" ned.exe nedfmt.exe nedls.exe LICENSE.txt README.txt)
else
  python3 - "$out/pkg" "$out/ned-$ver-windows-x86_64.zip" <<'PY'
import sys, zipfile, os
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for n in ["ned.exe", "nedfmt.exe", "nedls.exe", "LICENSE.txt", "README.txt"]:
        z.write(os.path.join(src, n), n)
PY
fi
echo "$out/ned-$ver-windows-x86_64.zip"
