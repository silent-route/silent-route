#!/bin/bash
# Package build/Silent Route.app as a disk image for a GitHub release.
#
#   scripts/package-release.sh
#
# Writes to build/release/:
#   Silent-Route-<version>.dmg          open it, drag Silent Route to Applications
#   Silent-Route-<version>.dmg.sha256   its checksum; the in-app updater checks it
#   sing-box-<version>-source.tar.gz    the source of the bundled sing-box, as its
#                                       licence (GPL-3.0) asks of anyone passing it on

set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Silent Route.app"
OUT=build/release
[ -d "$APP" ] || { echo "build the app first: scripts/build-app.sh" >&2; exit 1; }
VERSION=$(defaults read "$PWD/$APP/Contents/Info.plist" SRVersion)
NAME="Silent-Route-$VERSION.dmg"

rm -rf "$OUT"
mkdir -p "$OUT"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$APP" "$stage/Silent Route.app"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname "Silent Route $VERSION" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$OUT/$NAME"
(cd "$OUT" && shasum -a 256 "$NAME" > "$NAME.sha256")
SB=$(awk -F' *= *' '$1 == "version" {print $2}' singbox.pin)
curl -fsSL --retry 3 -o "$OUT/sing-box-$SB-source.tar.gz" \
  "https://github.com/SagerNet/sing-box/archive/refs/tags/v$SB.tar.gz"
ls -l "$OUT"
