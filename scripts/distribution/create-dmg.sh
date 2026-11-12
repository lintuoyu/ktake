#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h:h}"
export TMPDIR="$PWD/.build/distribution/tmp"
mkdir -p "$TMPDIR"
app="${1:-$PWD/dist/KTake.app}"
app="${app:A}"
if [[ "$(plutil -extract KTakeBundledSeparation raw "$app/Contents/Info.plist" 2>/dev/null)" != true ]]; then
    print -u2 "请先用 scripts/build-app.sh --release 构建完整应用。"
    exit 1
fi
if [[ -e "$app/Contents/Resources/SeparationModels" ]]; then
    print -u2 "安装包只能包含分离引擎。请重新构建应用以移除模型权重。"
    exit 1
fi
version="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
destination="$PWD/dist/KTake-$version-macOS-universal.dmg"
staging="$(mktemp -d "$PWD/dist/.ktake-dmg.XXXXXXXX")"
image_device=""
detach_image() {
    if [[ -n "$image_device" && -e "$image_device" ]]; then
        hdiutil detach "$image_device" || hdiutil detach -force "$image_device" || return
    fi
    image_device=""
}
cleanup() {
    detach_image || return
    rm -rf -- "$staging"
}
trap cleanup EXIT
mkdir "$staging/image"
cp -ca "$app" "$staging/image/KTake.app"
ln -s /Applications "$staging/image/Applications"
hdiutil create -srcfolder "$staging/image" -volname "KTake $version" \
    -layout GPTSPUD -fs HFS+ -format UDRW "$staging/staging.dmg"
hdiutil convert "$staging/staging.dmg" -format ULFO -o "$staging/KTake.dmg"
hdiutil verify "$staging/KTake.dmg"
hdiutil attach -readonly -nobrowse -noverify -plist "$staging/KTake.dmg" > "$staging/attachment.plist"
image_device="$(plutil -extract system-entities.0.dev-entry raw "$staging/attachment.plist")"
mount_point=""
for index in {0..8}; do
    if candidate="$(plutil -extract "system-entities.$index.mount-point" raw "$staging/attachment.plist" 2>/dev/null)"; then
        mount_point="$candidate"
        break
    fi
done
[[ -n "$mount_point" ]]
[[ "$(readlink "$mount_point/Applications")" == /Applications ]]
[[ "$(plutil -extract CFBundleShortVersionString raw "$mount_point/KTake.app/Contents/Info.plist")" == "$version" ]]
codesign --verify --deep --strict "$mount_point/KTake.app"
detach_image
if [[ -n "${KTAKE_SIGN_IDENTITY:-}" && "$KTAKE_SIGN_IDENTITY" != "-" ]]; then
    codesign --force --sign "$KTAKE_SIGN_IDENTITY" --timestamp "$staging/KTake.dmg"
fi
mv -f "$staging/KTake.dmg" "$destination"
echo "Built: $destination"
