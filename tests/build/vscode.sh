#!/bin/bash
# vscode.sh [OUTDIR] — the VS Code extension (editors/vscode: nedls in VS Code) as OUTDIR/vscode-nedls-<version>.vsix,
# to install with Extensions › … › Install from VSIX. Needs python3 only: the extension has no npm packages, and
# tests/build/vsix.py lays the .vsix out as @vscode/vsce does. Its version must be ned's (src/ned/version.nim).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=${1:-$root/build/vscode}
mkdir -p "$out"
ext="$root/editors/vscode"
v=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["version"])' "$ext/package.json")
ned=$(sed -n 's/^const NedVersion\* = "\(.*\)"/\1/p' "$root/src/ned/version.nim")
[ "$v" = "$ned" ] || { echo "editors/vscode/package.json's version $v is not ned's ($ned, src/ned/version.nim)"; exit 1; }
python3 "$here/vsix.py" "$ext" "$out/vscode-nedls-$v.vsix"
python3 "$root/tests/vscode/test_vsix.py" "$out/vscode-nedls-$v.vsix"
sh "$here/sums.sh" "$out" "$out/vscode-nedls-$v.vsix"           # (SHA256SUMS; signed with NED_SIGNING_KEY)
