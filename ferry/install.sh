#!/bin/sh
# DesignBridge Ferry installer — macOS + Linux (Windows: install.ps1).
#
#   curl -fsSL https://raw.githubusercontent.com/hadelekan/designbridge-releases/main/ferry/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/hadelekan/designbridge-releases/main/ferry/install.sh | sh -s -- --uninstall
#
# Downloads the compiled `ferry` binary for this OS/arch, verifies its sha256, puts it in
# ~/.designbridge/bin, then hands over to `ferry install` (login item + designbridge://
# scheme) and `ferry wake`. Per-user, no sudo.
#
# No code signing needed: curl/wget never set macOS `com.apple.quarantine`, so Gatekeeper
# doesn't assess the binary. Apple Silicon still requires *a* signature to exec, so an
# unsigned binary gets an ad-hoc one (`codesign -s -`) locally.
#
# Env overrides: FERRY_DOWNLOAD_BASE, FERRY_VERSION (default latest), FERRY_INSTALL_DIR,
# DB_FERRY_TOKEN (same as --token: overrides the secret ferry makes for itself).
set -eu

BASE="${FERRY_DOWNLOAD_BASE:-https://raw.githubusercontent.com/hadelekan/designbridge-releases/main/ferry}"
VERSION="${FERRY_VERSION:-latest}"
INSTALL_DIR="${FERRY_INSTALL_DIR:-$HOME/.designbridge/bin}"
TOKEN="${DB_FERRY_TOKEN:-}"
MODE=install

say() { printf '🛟 %s\n' "$*"; }
die() {
  printf 'ferry installer: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
DesignBridge Ferry installer

  sh install.sh [--token <pairing-token>] [--version <v>]   install or update
  sh install.sh --uninstall                                 remove everything
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --token)
      [ $# -ge 2 ] || die "--token needs a value"
      TOKEN="$2"
      shift 2
      ;;
    --token=*)
      TOKEN="${1#--token=}"
      shift
      ;;
    --version)
      [ $# -ge 2 ] || die "--version needs a value"
      VERSION="$2"
      shift 2
      ;;
    --version=*)
      VERSION="${1#--version=}"
      shift
      ;;
    --uninstall)
      MODE=uninstall
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown option: $1" ;;
  esac
done

BIN="$INSTALL_DIR/ferry"

# A previous daemon would keep serving the old build after the file is swapped.
stop_running() { pkill -x ferry 2>/dev/null || true; }

if [ "$MODE" = uninstall ]; then
  [ -x "$BIN" ] || die "ferry is not installed at $BIN"
  "$BIN" uninstall || true
  stop_running
  rm -f "$BIN"
  rmdir "$INSTALL_DIR" "$(dirname "$INSTALL_DIR")" 2>/dev/null || true
  say "ferry removed"
  exit 0
fi

os=$(uname -s)
arch=$(uname -m)
case "$os" in
  Darwin) os=darwin ;;
  Linux) os=linux ;;
  *) die "unsupported OS: $os (on Windows, use install.ps1)" ;;
esac
case "$arch" in
  x86_64 | amd64) arch=x64 ;;
  arm64 | aarch64) arch=arm64 ;;
  *) die "unsupported CPU: $arch" ;;
esac
# An x64 shell under Rosetta still gets the native Apple Silicon build.
if [ "$os" = darwin ] && [ "$arch" = x64 ] &&
  [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ]; then
  arch=arm64
fi
ASSET="ferry-$os-$arch"

fetch() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$2" "$1"
  else
    die "need curl or wget"
  fi
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

say "downloading $ASSET ($VERSION)"
fetch "$BASE/$VERSION/$ASSET" "$TMP/$ASSET" || die "download failed: $BASE/$VERSION/$ASSET"
fetch "$BASE/$VERSION/SHA256SUMS" "$TMP/SHA256SUMS" || die "download failed: SHA256SUMS"

expected=$(awk -v a="$ASSET" '$2 == a { print $1 }' "$TMP/SHA256SUMS")
[ -n "$expected" ] || die "$ASSET is not listed in SHA256SUMS"
actual=$(sha256 "$TMP/$ASSET")
[ "$expected" = "$actual" ] || die "checksum mismatch for $ASSET (expected $expected, got $actual)"

chmod 755 "$TMP/$ASSET"
if [ "$os" = darwin ]; then
  xattr -d com.apple.quarantine "$TMP/$ASSET" 2>/dev/null || true
  codesign --verify "$TMP/$ASSET" 2>/dev/null || codesign --force --sign - "$TMP/$ASSET"
fi

stop_running
mkdir -p "$INSTALL_DIR"
mv -f "$TMP/$ASSET" "$BIN"

# `ferry install` registers its own absolute path, so it must run from the final location.
# A partial OS integration (e.g. no xdg-mime on a headless box) still leaves a usable CLI.
if [ -n "$TOKEN" ]; then
  "$BIN" install --token "$TOKEN" || say "some OS integration steps failed (above); continuing"
else
  "$BIN" install || say "some OS integration steps failed (above); continuing"
fi

if "$BIN" wake >/dev/null 2>&1; then
  say "ferry is running — click Connect in the Figma plugin (Account → Local connections)"
else
  say "installed, but it did not start: run $BIN status to see why"
fi

case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *) say "optional, for the CLI: add $INSTALL_DIR to your PATH" ;;
esac
