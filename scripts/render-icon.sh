#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
source scripts/toolchain.sh
icon_work=$(mktemp -d "${TMPDIR:-/tmp/}/ktvpro-icon.XXXXXX")
trap 'rm -rf "$icon_work"' EXIT
xcrun swiftc "${compiler_flags[@]}" Tools/RenderAppIcon.swift -o "$icon_work/render-icon"
"$icon_work/render-icon" "$icon_work/AppIcon.iconset"
iconutil -c icns "$icon_work/AppIcon.iconset" -o Resources/AppIcon.icns
cp "$icon_work/AppIcon.iconset/icon_512x512@2x.png" Resources/AppIcon.png
