#!/bin/bash
# Build the two macOS slices from the corresponding source and vendored modules.
set -euo pipefail
output="$1"
cd "$(dirname "$0")"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
export GOOS=darwin CGO_ENABLED=0
for arch in arm64 amd64; do
    GOARCH="$arch" "${KTAKE_GO:-go}" build -mod=vendor -trimpath -ldflags="-s -w" \
        -o "$staging/musicdl-$arch" ./cmd/ktake-music-dl
done
xcrun lipo -create "$staging/musicdl-arm64" "$staging/musicdl-amd64" -output "$output"
