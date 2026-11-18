#!/bin/bash
# Builds build/Cell.app (release by default: ./Scripts/build-app.sh [debug|release]).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
echo "▸ Regenerating the graphics probe…"
python3 -I Tools/engine-probe/build.py
echo "▸ Regenerating Wine helpers…"
Tools/game-hotkey/build.sh
Tools/dock-name/build.sh
python3 -I Tools/webview-bridge/build.py
python3 -I Tools/steamwebhelper-wrapper/build.py
echo "▸ Building ($CONFIG)…"
swift build -c "$CONFIG" --product Cell
swift build -c "$CONFIG" --product cell-cli
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/Plugins"
for plugin in Plugins/*.cell; do
    CELL_HOME="$STAGING/home" "$BIN/cell-cli" plugin pack "$plugin" "$STAGING/Plugins/${plugin##*/}"
done

APP="build/Cell.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"

cp "$BIN/Cell" "$APP/Contents/MacOS/Cell"
cp "$BIN/cell-cli" "$APP/Contents/Helpers/cell"
cp Tools/game-hotkey/cell-game-hotkey "$APP/Contents/Helpers/cell-game-hotkey"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# Built-in plugins (the compatibility database).
cp -R "$STAGING/Plugins" "$APP/Contents/Resources/Plugins"
cp -R Docs "$APP/Contents/Resources/Docs"
# The menu bar icon (a template image: macOS tints it for light and dark menu bars).
cp Resources/StatusIcon.png "$APP/Contents/Resources/StatusIcon.png"

echo "▸ Packaging the app icon…"
"$APP/Contents/Helpers/cell" internal-make-icon "$APP/Contents/Resources/AppIcon.icns" Resources/AppIcon.png

echo "▸ Signing (ad hoc)…"
# The helper and the app both run virtual machines, so both carry the virtualization entitlement.
codesign --force --sign - --entitlements Resources/Cell.entitlements "$APP/Contents/Helpers/cell" >/dev/null
codesign --force --sign - --entitlements Resources/Cell.entitlements "$APP" >/dev/null

echo "✓ Built $APP"
echo "  Run it:       open \"$APP\""
echo "  Install it:   cp -R \"$APP\" /Applications/"
