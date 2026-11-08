#!/bin/sh
# install.sh — ned, the newest release, the easiest way for this machine:
#   Termux (Android)  the newest release's package (ned, nedfmt, nedls) with apt when it has one, else built with
#                     nimble like everywhere else (Nim, git and clang from Termux's packages)
#   elsewhere         built from the source with nimble (Nim 2.2 or newer is needed: choosenim or grabnim gives it),
#                     into ~/.nimble/bin
#   curl -fsSL https://raw.githubusercontent.com/foxoman/ned/main/install.sh | sh
#   sh install.sh --source      build from the source even in Termux
# Later: `ned --update` brings the next release the same way.
# The package is checked before it is installed: its SHA-256 against the release's SHA256SUMS, and SHA256SUMS
# against its signature (SHA256SUMS.sig) by a key in ned's src/ned/app/release-signers, once releases are signed.
set -eu
repo=foxoman/ned
api=${NED_INSTALL_API:-https://api.github.com/repos/$repo/releases/latest}     # (the tests: a file:// URL)
signers_url=https://raw.githubusercontent.com/$repo/main/src/ned/app/release-signers
say() { printf '%s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || { say "ned's installer needs $1 — $2"; exit 1; }; }

sha() { # FILE: its SHA-256 ("" when there is nothing to work it out with)
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 -r "$1" | cut -d' ' -f1
  fi
}

signer_keys() { # DIR: the keys releases are signed with (release-signers' lines that are keys) — fails when unread
  f=${NED_RELEASE_SIGNERS:-}
  if [ -z "$f" ]; then
    if [ -f "$(dirname "$0")/src/ned/app/release-signers" ]; then f="$(dirname "$0")/src/ned/app/release-signers"
    else
      f="$1/release-signers"
      curl -fsSL -o "$f" "$signers_url" || return 1
    fi
  fi
  grep -v '^[[:space:]]*#' "$f" | grep -v PLACEHOLDER | grep -E '^[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+' || true
}

check() { # DIR NAME: DIR/NAME against DIR/SHA256SUMS, and SHA256SUMS against its signature when ned has a key
  d=$1; n=$2
  keys=$(signer_keys "$d") || { say "Could not read ned's release keys ($signers_url) — not installed"; return 1; }
  if [ -n "$keys" ]; then
    [ -f "$d/SHA256SUMS.sig" ] || { say "Refused: the release is not signed (it has no SHA256SUMS.sig) — not installed"; return 1; }
    command -v ssh-keygen >/dev/null 2>&1 ||
      { say "Checking the release's signature needs ssh-keygen: pkg install openssh — then run this again"; return 1; }
    printf '%s\n' "$keys" > "$d/allowed_signers"
    ok=no
    for who in $(printf '%s\n' "$keys" | cut -d' ' -f1); do
      if ssh-keygen -Y verify -f "$d/allowed_signers" -I "$who" -n ned-release -s "$d/SHA256SUMS.sig" \
           < "$d/SHA256SUMS" > /dev/null 2>&1; then ok=yes; break; fi
    done
    [ $ok = yes ] || { say "Refused: SHA256SUMS is not signed by ned's release key — not installed"; return 1; }
  elif [ -f "$d/SHA256SUMS.sig" ]; then say "Note: there is no release key yet to check the signature with: checking the SHA-256 only"
  else say "Note: the release is not signed yet: checking the SHA-256 only"
  fi
  want=$(awk -v n="$n" 'length($1) == 64 { f = $2; sub(/^\*/, "", f); sub(/.*\//, "", f); if (f == n) { print tolower($1); exit } }' "$d/SHA256SUMS")
  [ -n "$want" ] || { say "Refused: SHA256SUMS has no line for $n — not installed"; return 1; }
  got=$(sha "$d/$n")
  [ -n "$got" ] || { say "Checking the package needs sha256sum, shasum or openssl — not installed"; return 1; }
  [ "$got" = "$want" ] ||
    { say "Refused: $n is not the file the release lists (its SHA-256 differs: changed, or the download broke) — not installed"; return 1; }
  if [ -n "$keys" ]; then say "Checked $n: its SHA-256 and the release's signature match"
  else say "Checked $n: its SHA-256 matches"; fi
}

from_source=no
[ "${1:-}" = "--source" ] && from_source=yes

prefix=${PREFIX:-}     # (Termux's own folder there; not set on most other systems)
if [ -n "${TERMUX_VERSION:-}" ] || [ "$prefix" != "${prefix#*com.termux}" ]; then
  if [ $from_source = no ]; then
    need curl "pkg install curl"
    say "Looking for ned's newest Termux package…"
    json=$(curl -fsSL "$api" 2>/dev/null || true)     # (no release, or none with files: built from the source)
    asset() { printf '%s\n' "$json" | grep -o '"browser_download_url": *"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/' |
              grep -E "$1" | head -n 1; }
    url=$(asset '_aarch64\.deb$' || true)
    if [ -n "$url" ]; then
      sums=$(asset '/SHA256SUMS$' || true)
      sig=$(asset '/SHA256SUMS\.sig$' || true)
      [ -n "$sums" ] || { say "The release has no SHA256SUMS, so its package cannot be checked — not installed" \
                              "(it is on https://github.com/$repo/releases)"; exit 1; }
      dir=$(mktemp -d "${TMPDIR:-/tmp}/ned-install.XXXXXX")
      trap 'rm -rf "$dir"' EXIT
      name=$(basename "$url")
      curl -fsSL -o "$dir/SHA256SUMS" "$sums"
      [ -z "$sig" ] || curl -fsSL -o "$dir/SHA256SUMS.sig" "$sig"
      curl -fL -o "$dir/$name" "$url"
      check "$dir" "$name" || exit 1
      apt install -y "$dir/$name"
      say "Installed: $(ned --version) — try: ned --check"
      exit 0
    fi
    say "No package found in the newest release — building from the source instead"
  fi
  pkg install -y nim git clang
fi

need git "install git with your package manager"
if ! command -v nimble >/dev/null 2>&1; then
  say "Nim is needed to build ned (2.2 or newer). Get it with your package manager, or:"
  say "  curl https://nim-lang.org/choosenim/init.sh -sSf | sh     (choosenim)"
  say "  then run this script again"
  exit 1
fi
say "Building ned with nimble (a few minutes)…"
nimble install -y "https://github.com/$repo"
bin="${NIMBLE_DIR:-$HOME/.nimble}/bin"
case ":$PATH:" in *":$bin:"*) ;; *) say "Add $bin to your PATH (in ~/.profile): export PATH=\"$bin:\$PATH\"" ;; esac
say "Installed: ned, nedfmt and nedls in $bin — try: ned --check"