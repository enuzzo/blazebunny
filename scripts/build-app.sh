#!/bin/sh
# Builds build/Blazebunny.app from the SwiftPM release binary, ad-hoc signed.
set -eu
cd "$(dirname "$0")/.."
swift build -c release --product Blazebunny
BIN="$(swift build -c release --show-bin-path)/Blazebunny"
APP=build/Blazebunny.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Blazebunny"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Build identity: build number = commit count, "+" after the hash when the tree has uncommitted changes.
BUILD="$(git rev-list --count HEAD)"
HASH="$(git rev-parse --short HEAD)"
git diff --quiet HEAD -- . && git diff --cached --quiet || HASH="$HASH+"
PL="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PL"
/usr/libexec/PlistBuddy -c "Add :BlazebunnyCommit string $HASH" "$PL"
/usr/libexec/PlistBuddy -c "Add :BlazebunnyBuiltAt string $(date '+%Y-%m-%d %H:%M')" "$PL"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Bundled fonts (SIL OFL) with their licences, and the NOTICE listing them.
mkdir -p "$APP/Contents/Resources/Fonts"
cp Resources/Fonts/* "$APP/Contents/Resources/Fonts/"
cp NOTICE "$APP/Contents/Resources/NOTICE"
codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP"
