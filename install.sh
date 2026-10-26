#!/bin/sh
# install.sh — ned, the newest release, the easiest way for this machine:
#   Termux (Android)  the release's package (ned, nedfmt, nedls), installed with apt
#   elsewhere         built from the source with nimble (Nim 2.2 or newer is needed: choosenim or grabnim gives it),
#                     into ~/.nimble/bin
#   curl -fsSL https://raw.githubusercontent.com/foxoman/ned/main/install.sh | sh
#   sh install.sh --source      build from the source even in Termux
# Later: `ned --update` brings the next release the same way.
set -eu
repo=foxoman/ned
api=https://api.github.com/repos/$repo/releases/latest
say() { printf '%s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || { say "ned's installer needs $1 — $2"; exit 1; }; }

from_source=no
[ "${1:-}" = "--source" ] && from_source=yes

if [ -n "${TERMUX_VERSION:-}" ] || [ "${PREFIX:-}" != "${PREFIX#*com.termux}" ]; then
  if [ $from_source = no ]; then
    need curl "pkg install curl"
    say "Looking for ned's newest Termux package…"
    url=$(curl -fsSL "$api" | grep -o '"browser_download_url": *"[^"]*_aarch64\.deb"' | head -n 1 | sed 's/.*"\(http[^"]*\)"/\1/')
    if [ -n "$url" ]; then
      deb="${TMPDIR:-/tmp}/$(basename "$url")"
      curl -fL -o "$deb" "$url"
      apt install -y "$deb"
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
