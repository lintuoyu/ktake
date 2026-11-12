#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
template="Resources/GarageBandTemplate.band"
mode=development
architectures=("$(uname -m)")
case "$#:${1:-}" in
    0:) ;;
    1:--release)
        mode=release
        architectures=(arm64 x86_64)
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
scripts/distribution/prepare.sh "$mode"
components="$PWD/.build/distribution"
destination="$PWD/dist/KTake.app"
mkdir -p dist
staging="$(mktemp -d "$PWD/dist/.ktake-build.XXXXXXXX")"
trap 'rm -rf -- "$staging"' EXIT
app="$staging/KTake.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
export TMPDIR="$components/tmp"
slices=()
for architecture in "${architectures[@]}"; do
    KTAKE_TARGET_ARCH="$architecture"
    source scripts/toolchain.sh
    slice="$staging/KTake-$architecture"
    xcrun swiftc "${compiler_flags[@]}" -O -whole-module-optimization -module-name KTake \
        Sources/KTVPro/*.swift -o "$slice"
    slices+=("$slice")
done
xcrun lipo -create "${slices[@]}" -output "$app/Contents/MacOS/KTake"
cp scripts/Info.plist "$app/Contents/Info.plist"
cp "$components/musicdl/KTakeMusicDL" "$app/Contents/MacOS/"
mkdir -p "$app/Contents/Resources/ThirdParty"
cp "$components/musicdl/LICENSE" "$app/Contents/Resources/ThirdParty/go-music-dl-LICENSE"
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
if [[ "$mode" == release ]]; then
    cp -ca "$components/separation/SeparationRuntime" "$app/Contents/Resources/"
    plutil -insert KTakeBundledSeparation -bool YES "$app/Contents/Info.plist"
    cp "$components/musicdl/go-music-dl-v1.1.5-source.tar.gz" "$app/Contents/Resources/ThirdParty/"
    cp scripts/distribution/ThirdPartyNotices.txt "$app/Contents/Resources/ThirdParty/"
elif [[ -f Library/catalog.json ]]; then
    mkdir -p "$app/Contents/Resources/SongLibrary"
    rsync -a --exclude '.DS_Store' Library/ "$app/Contents/Resources/SongLibrary/"
fi
identity="${KTAKE_SIGN_IDENTITY:--}"
signing=(--force --sign "$identity")
if [[ "$identity" != "-" ]]; then
    signing+=(--options runtime --timestamp)
fi
codesign "${signing[@]}" "$app/Contents/MacOS/KTakeMusicDL"
if [[ "$mode" == release ]]; then
    runtime="$app/Contents/Resources/SeparationRuntime"
    find "$runtime" -type f \( -name '*.dylib' -o -name '*.so' \) -print0 | while IFS= read -r -d '' item; do
        codesign "${signing[@]}" "$item"
    done
    codesign "${signing[@]}" "$runtime/bin/python3.12"
fi
codesign "${signing[@]}" --entitlements scripts/Entitlements.plist "$app"
codesign --verify --strict --deep "$app"
previous="$staging/Previous-KTake.app"
if [[ -e "$destination" || -L "$destination" ]]; then
    mv "$destination" "$previous"
fi
if ! mv "$app" "$destination"; then
    if [[ -e "$previous" || -L "$previous" ]]; then
        if ! mv "$previous" "$destination"; then
            trap - EXIT
            print -u2 "上一个应用仍保存在 $previous"
        fi
    fi
    exit 1
fi
echo "Built: $destination"
