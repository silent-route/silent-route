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
# The window: the app and Applications side by side, an arrow between them
# (scripts/dmg-settings.py). dmgbuild writes Finder's view settings itself,
# without scripting Finder; it is pinned in scripts/dmgbuild-requirements.txt
# (see release.yml).
DMGBUILD=${DMGBUILD:-dmgbuild}
# A disk of the same name already open would make the new one "<name> 1"
# while it is built, and that name would end up in its Finder settings.
if [ -e "/Volumes/Silent Route $VERSION" ]; then
  echo "eject \"/Volumes/Silent Route $VERSION\" first" >&2
  exit 1
fi
"$DMGBUILD" -s scripts/dmg-settings.py -D app="$APP" -D background=Resources/dmg-background.png \
  -D icon=Resources/AppIcon.icns "Silent Route $VERSION" "$OUT/$NAME"
# Check the app as the in-app updater will: copied off the disk image,
# its signature must pass a strict check.
CHECK=$(mktemp -d)
hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$CHECK/mnt" "$OUT/$NAME" >/dev/null
ditto "$CHECK/mnt/Silent Route.app" "$CHECK/Silent Route.app"
hdiutil detach -force "$CHECK/mnt" >/dev/null
codesign --verify --strict "$CHECK/Silent Route.app"
rm -rf "$CHECK"
(cd "$OUT" && shasum -a 256 "$NAME" > "$NAME.sha256")
SB=$(awk -F' *= *' '$1 == "version" {print $2}' singbox.pin)
curl -fsSL --retry 3 -o "$OUT/sing-box-$SB-source.tar.gz" \
  "https://github.com/SagerNet/sing-box/archive/refs/tags/v$SB.tar.gz"
ls -l "$OUT"
