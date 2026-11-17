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
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Bundled fonts (SIL OFL) with their licences, and the NOTICE listing them.
mkdir -p "$APP/Contents/Resources/Fonts"
cp Resources/Fonts/* "$APP/Contents/Resources/Fonts/"
cp NOTICE "$APP/Contents/Resources/NOTICE"
codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP"
