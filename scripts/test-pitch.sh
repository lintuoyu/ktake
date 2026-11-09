#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
source scripts/toolchain.sh
xcrun swiftc "${compiler_flags[@]}" -O -whole-module-optimization \
    Sources/KTVPro/AudioDevices.swift Sources/KTVPro/PitchRenderer.swift \
    Tests/PitchSmokeTests.swift -o .build/pitch-smoke-tests
if [[ "${1:-}" != "--build-only" ]]; then
    .build/pitch-smoke-tests
fi
