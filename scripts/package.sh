#!/bin/sh
# Build a Notchify.app bundle (and optional Notchify.dmg) from the SwiftPM
# release artifacts. Run from the repo root.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Notchify.app"
DMG="$ROOT/dist/Notchify.dmg"

# Force Xcode's toolchain. Some package managers / system setups point
# DEVELOPER_DIR or SDKROOT at an SDK whose Swift version doesn't match
# the installed Xcode compiler; both env vars need to point at Xcode
# for the build to succeed.
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
unset SDKROOT

cd "$ROOT"
swift build -c release

rm -rf "$APP" "$DMG"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/notchify-daemon  "$APP/Contents/MacOS/notchify-daemon"
cp .build/release/notchify         "$APP/Contents/MacOS/notchify"
cp .build/release/notchify-recipes "$APP/Contents/MacOS/notchify-recipes"
cp Resources/Info.plist            "$APP/Contents/Info.plist"

# Ship recipes as bundle data. notchify-recipes resolves
# ../share/notchify/recipes relative to its binary, so place them
# under Contents/share/notchify/recipes inside the .app.
mkdir -p "$APP/Contents/share/notchify"
cp -R recipes "$APP/Contents/share/notchify/recipes"

if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc sign so Gatekeeper doesn't complain about an unsigned bundle on
# the same machine. Distribution to other Macs still requires Apple
# Developer ID signing + notarization.
codesign --force --sign - --deep "$APP" >/dev/null

echo "built $APP"

if command -v hdiutil >/dev/null 2>&1; then
    # Build the DMG from a staging dir that also includes an
    # /Applications symlink, so users get the standard drag-to-
    # install layout instead of a single .app icon.
    STAGE="$ROOT/dist/dmg-staging"
    rm -rf "$STAGE"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname Notchify -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
    rm -rf "$STAGE"
    echo "built $DMG"
fi
