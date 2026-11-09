#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
app="$PWD/dist/KTake.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
source scripts/toolchain.sh
# No external dependencies; build directly with Command Line Tools or Xcode.
xcrun swiftc "${compiler_flags[@]}" -O -whole-module-optimization -module-name KTake \
    Sources/KTVPro/*.swift -o "$app/Contents/MacOS/KTake"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
rsync -a --exclude '.DS_Store' Resources/GarageBandTemplate.band "$app/Contents/Resources/"
mkdir -p "$app/Contents/Resources/SongLibrary"
rsync -a --exclude '.DS_Store' Library/ "$app/Contents/Resources/SongLibrary/"
codesign --force --sign - --entitlements Resources/Entitlements.plist "$app"
# Finder may cache the old icon if only files inside the bundle change.
touch "$app"
echo "Built: $app"
