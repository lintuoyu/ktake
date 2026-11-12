#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
template="Resources/GarageBandTemplate.band"
# Use --release before packaging the app into a DMG.
case "$#:${1:-}" in
    0:) ;;
    1:--release)
        if [[ ! -s "$template/Alternatives/000/ProjectData" ||
              ! -s "$template/Alternatives/000/MetaData.plist" ||
              ! -s "$template/projectData" ]]; then
            print -u2 "发布构建缺少完整的 GarageBand 工程模板：$template"
            exit 1
        fi
        ;;
    *)
        print -u2 "用法：$0 [--release]"
        exit 2
        ;;
esac
destination="$PWD/dist/KTake.app"
mkdir -p dist
staging="$(mktemp -d "$PWD/dist/.ktake-build.XXXXXXXX")"
trap 'rm -rf -- "$staging"' EXIT
app="$staging/KTake.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
source scripts/toolchain.sh
# No external dependencies; build directly with Command Line Tools or Xcode.
xcrun swiftc "${compiler_flags[@]}" -O -whole-module-optimization -module-name KTake \
    Sources/KTVPro/*.swift -o "$app/Contents/MacOS/KTake"
cp scripts/Info.plist "$app/Contents/Info.plist"
cp scripts/extract-roformer.py "$app/Contents/Resources/ExtractRoFormer.py"
cp scripts/extract-inst-hq3.py "$app/Contents/Resources/ExtractInstHQ3.py"
cp scripts/extract-small-karaoke.py "$app/Contents/Resources/ExtractSmallKaraoke.py"
cp scripts/separation_model_files.py "$app/Contents/Resources/"
cp scripts/separation_progress.py "$app/Contents/Resources/"
if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$app/Contents/Resources/"
    plutil -insert CFBundleIconFile -string AppIcon.icns "$app/Contents/Info.plist"
fi
if [[ -d "$template" ]]; then
    rsync -a --exclude '.DS_Store' "$template" "$app/Contents/Resources/"
fi
if [[ -f Library/catalog.json ]]; then
    mkdir -p "$app/Contents/Resources/SongLibrary"
    rsync -a --exclude '.DS_Store' Library/ "$app/Contents/Resources/SongLibrary/"
fi
codesign --force --sign - --entitlements scripts/Entitlements.plist "$app"
rsync -a --delete "$app/" "$destination/"
# Finder may cache the old icon if only files inside the bundle change.
touch "$destination"
echo "Built: $destination"
