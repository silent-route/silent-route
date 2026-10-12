#!/bin/bash
# Build build/Silent Route.app — one universal bundle for Intel and Apple Silicon.
#
#   scripts/build-app.sh            release build
#   scripts/build-app.sh --debug    debug build (faster, unoptimised)
#
# Needs only the Command Line Tools: each architecture is compiled separately
# with --triple and merged with lipo, so no Xcode build system is involved.
#
# Bundle layout:
#   Contents/MacOS/SilentRoute             the app
#   Contents/MacOS/SilentRouteHelper       root helper (copied out at install)
#   Contents/MacOS/sroute                    command line
#   Contents/Resources/install-helper.sh  run as root by the app
#   Contents/Resources/sing-box/          pinned binaries for both CPUs, their licence

set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
[ "${1:-}" = "--debug" ] && CONFIG=debug

APP_NAME="Silent Route"
BUNDLE_ID="org.silentroute.app"
MIN_OS="14.0"
# The release version comes from the latest tag (v1.2.3) unless SR_VERSION
# says otherwise; the build string tells builds apart (the app offers to
# update the helper when they differ).
# FULL_VERSION may carry a pre-release suffix (1.0.0-beta); macOS wants
# only the numbers in CFBundleShortVersionString.
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)
FULL_VERSION=${SR_VERSION:-${LAST_TAG#v}}
FULL_VERSION=${FULL_VERSION:-1.0.0-dev}
SHORT_VERSION=${FULL_VERSION%%-*}
VERSION=$(git describe --tags --always --dirty 2>/dev/null || echo "$FULL_VERSION")
# Where the app looks for updates: "owner/repo" on GitHub. The release
# workflow sets it to the repository it runs in; local builds read
# scripts/release.env and may leave it empty (no update checks).
# shellcheck source=release.env
[ -f scripts/release.env ] && source scripts/release.env
UPDATE_REPOSITORY=${SR_UPDATE_REPOSITORY:-${UPDATE_REPOSITORY:-}}
PRODUCTS=(SilentRoute SilentRouteHelper sroute)

[ -x Resources/sing-box/sing-box-darwin-arm64 ] && [ -x Resources/sing-box/sing-box-darwin-amd64 ] \
  && [ -f Resources/sing-box/LICENSE ] || scripts/fetch-sing-box.sh

for arch in arm64 x86_64; do
  echo "==> building $arch ($CONFIG)"
  for p in "${PRODUCTS[@]}"; do
    swift build -c "$CONFIG" --triple "$arch-apple-macosx$MIN_OS" --product "$p" 2>&1 | grep -vE '^\[[0-9]+/[0-9]+\]' || true
    [ -x ".build/$arch-apple-macosx/$CONFIG/$p" ] || { echo "build of $p ($arch) failed" >&2; exit 1; }
  done
done

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/sing-box"

for p in "${PRODUCTS[@]}"; do
  lipo -create ".build/arm64-apple-macosx/$CONFIG/$p" ".build/x86_64-apple-macosx/$CONFIG/$p" \
    -output "$APP/Contents/MacOS/$p"
done

cp Resources/AppIcon.icns LICENSE "$APP/Contents/Resources/"
cp Resources/sing-box/LICENSE "$APP/Contents/Resources/sing-box/LICENSE"
install -m 0755 Resources/install-helper.sh "$APP/Contents/Resources/"
install -m 0755 Resources/sing-box/sing-box-darwin-arm64 Resources/sing-box/sing-box-darwin-amd64 \
  "$APP/Contents/Resources/sing-box/"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>                 <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>          <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>           <string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key>           <string>SilentRoute</string>
  <key>CFBundleIconFile</key>             <string>AppIcon</string>
  <key>CFBundlePackageType</key>          <string>APPL</string>
  <key>CFBundleShortVersionString</key>   <string>$SHORT_VERSION</string>
  <key>CFBundleVersion</key>              <string>$VERSION</string>
  <key>SRVersion</key>                    <string>$FULL_VERSION</string>
  <key>SRUpdateRepository</key>           <string>$UPDATE_REPOSITORY</string>
  <key>LSMinimumSystemVersion</key>       <string>$MIN_OS</string>
  <key>LSApplicationCategoryType</key>    <string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key>      <true/>
  <key>NSPrincipalClass</key>             <string>NSApplication</string>
  <!-- .srprofile: a profile as JSON. Double-click in Finder imports it. -->
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key>         <string>$BUNDLE_ID.profile</string>
      <key>UTTypeDescription</key>        <string>Silent Route Profile</string>
      <key>UTTypeConformsTo</key>         <array><string>public.json</string><string>public.data</string></array>
      <key>UTTypeIconFile</key>           <string>AppIcon</string>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>srprofile</string></array></dict>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>         <string>Silent Route Profile</string>
      <key>CFBundleTypeRole</key>         <string>Viewer</string>
      <key>LSHandlerRank</key>            <string>Owner</string>
      <key>LSItemContentTypes</key>       <array><string>$BUNDLE_ID.profile</string></array>
    </dict>
  </array>
</dict>
</plist>
EOF

# Sign inside out with the local identity; each executable gets its own
# identifier, which the helper's XPC requirement checks.
# shellcheck source=signing.sh
source scripts/signing.sh
sign_begin
trap sign_end EXIT
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID.helper" --timestamp=none "$APP/Contents/MacOS/SilentRouteHelper"
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID.cli" --timestamp=none "$APP/Contents/MacOS/sroute"
# sing-box keeps its upstream ad-hoc signature: its sha256 is pinned and
# re-signing would change it.
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" --timestamp=none "$APP"
sign_end
trap - EXIT

codesign --verify --strict "$APP" && echo "==> signature ok"
for p in "${PRODUCTS[@]}"; do printf '%-18s %s\n' "$p" "$(lipo -archs "$APP/Contents/MacOS/$p")"; done
echo "==> $APP"
