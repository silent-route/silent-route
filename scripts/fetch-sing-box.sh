#!/bin/bash
# Download the pinned sing-box for both architectures.
#
#   scripts/fetch-sing-box.sh
#
# Results (not in git):
#   Resources/sing-box/sing-box-darwin-arm64
#   Resources/sing-box/sing-box-darwin-amd64
#   Resources/sing-box/LICENSE
#
# A binary whose sha256 differs from singbox.pin is deleted and the script
# fails. The helper checks the same hashes again before every start.

set -euo pipefail
cd "$(dirname "$0")/.."

pin() { awk -F' *= *' -v k="$1" '$1 == k {print $2}' singbox.pin; }
VERSION=$(pin version)
OUT=Resources/sing-box
mkdir -p "$OUT"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for arch in arm64 amd64; do
  want=$(pin "darwin-$arch")
  dst="$OUT/sing-box-darwin-$arch"
  if [ -f "$dst" ] && [ "$(shasum -a 256 "$dst" | cut -d' ' -f1)" = "$want" ]; then
    echo "sing-box $VERSION $arch: already present"
    continue
  fi
  name="sing-box-$VERSION-darwin-$arch"
  echo "==> downloading $name"
  curl -fsSL --retry 3 -o "$TMP/$name.tar.gz" \
    "https://github.com/SagerNet/sing-box/releases/download/v$VERSION/$name.tar.gz"
  tar -xzf "$TMP/$name.tar.gz" -C "$TMP"
  got=$(shasum -a 256 "$TMP/$name/sing-box" | cut -d' ' -f1)
  if [ "$got" != "$want" ]; then
    echo "CHECKSUM MISMATCH for $arch: got $got, pinned $want" >&2
    exit 1
  fi
  install -m 0755 "$TMP/$name/sing-box" "$dst"
  echo "sing-box $VERSION $arch: ok"
done

# Its licence travels with the binary (GPL-3.0-or-later). The release also
# carries the exact source code (scripts/package-release.sh).
curl -fsSL --retry 3 -o "$OUT/LICENSE" "https://raw.githubusercontent.com/SagerNet/sing-box/v$VERSION/LICENSE"
