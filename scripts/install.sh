#!/usr/bin/env bash
# Download, checksum and install the pinned gh-actions-lock extension.
set -euo pipefail

VERSION=v0.2.0
ASSET=linux-amd64
SHA256=79ec84c191667fd935a277e6fd3662cf5d3669cccc9e99998731d8f306f373b6

if [[ -n "${RUNNER_OS:-}" && "$RUNNER_OS" != "Linux" ]]; then
  echo "::error::verify-actions-lock supports Linux runners only (RUNNER_OS=$RUNNER_OS)."
  exit 1
fi
if [[ -n "${RUNNER_ARCH:-}" && "$RUNNER_ARCH" != "X64" ]]; then
  echo "::error::verify-actions-lock supports X64 runners only (RUNNER_ARCH=$RUNNER_ARCH)."
  exit 1
fi

dir="${RUNNER_TEMP:-/tmp}/verify-actions-lock/gh-actions-lock"
mkdir -p "$dir"

gh release download "$VERSION" -R github/gh-actions-lock -p "$ASSET" -O "$dir/gh-actions-lock" --clobber
echo "$SHA256  $dir/gh-actions-lock" | sha256sum -c -
chmod +x "$dir/gh-actions-lock"

# Remove any previously installed actions-lock so a stale one is never used.
exts=$(gh extension list) || exts=""
if grep -qE '^gh actions-lock([[:space:]]|$)' <<<"$exts"; then
  gh extension remove actions-lock
fi

(cd "$dir" && gh extension install .)
echo "Installed gh-actions-lock $VERSION ($ASSET)."
