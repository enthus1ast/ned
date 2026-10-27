#!/bin/sh
# sums.sh DIR [FILE…] — DIR/SHA256SUMS for FILE… (every file in DIR when none is named), in sha256sum's format: the
# lines for those names are replaced and the rest kept, so each script that makes a release's files adds its own,
# and `sums.sh release/` over the folder of a whole release lists all of them.
# With NED_SIGNING_KEY (an ssh private key, or its .pub when the key is in ssh-agent) it signs SHA256SUMS too:
# SHA256SUMS.sig, made with `ssh-keygen -Y sign -n ned-release` — what `ned --update` and install.sh check against
# the public key in src/ned/app/release-signers. Publish both files with the release.
set -eu
[ $# -ge 1 ] || { echo "usage: sums.sh DIR [FILE…]" >&2; exit 2; }
dir=$1; shift
[ -d "$dir" ] || { echo "sums.sh: $dir is not a folder" >&2; exit 2; }
if command -v sha256sum > /dev/null; then sum() { sha256sum -b -- "$1" | cut -d' ' -f1; }
elif command -v shasum > /dev/null; then sum() { shasum -a 256 -b -- "$1" | cut -d' ' -f1; }
else echo "sums.sh: needs sha256sum (coreutils) or shasum" >&2; exit 1
fi
if [ $# -eq 0 ]; then
  for f in "$dir"/*; do
    case "${f##*/}" in SHA256SUMS|SHA256SUMS.sig) continue ;; esac
    [ -f "$f" ] && set -- "$@" "$f"
  done
fi
new="$dir/SHA256SUMS.new.$$"
: > "$new"
for f in "$@"; do
  [ -f "$f" ] || { echo "sums.sh: $f is not a file" >&2; rm -f "$new"; exit 1; }
  printf '%s  %s\n' "$(sum "$f")" "${f##*/}" >> "$new"
done
# (the lines of the other files, as they were)
if [ -f "$dir/SHA256SUMS" ]; then
  while IFS= read -r line; do
    name=${line#*  }
    keep=yes
    for f in "$@"; do [ "${f##*/}" = "$name" ] && keep=no; done
    [ $keep = yes ] && printf '%s\n' "$line" >> "$new"
  done < "$dir/SHA256SUMS"
fi
sort -k 2 "$new" > "$dir/SHA256SUMS"
rm -f "$new"
echo "$dir/SHA256SUMS ($(wc -l < "$dir/SHA256SUMS" | tr -d ' ') files)"
rm -f "$dir/SHA256SUMS.sig"
if [ -n "${NED_SIGNING_KEY:-}" ]; then
  command -v ssh-keygen > /dev/null || { echo "sums.sh: signing needs ssh-keygen (OpenSSH)" >&2; exit 1; }
  ssh-keygen -q -Y sign -f "$NED_SIGNING_KEY" -n ned-release "$dir/SHA256SUMS"
  echo "$dir/SHA256SUMS.sig"
else
  echo "(not signed: NED_SIGNING_KEY is not set)"
fi
