#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
source scripts/toolchain.sh
xcrun swiftc "${compiler_flags[@]}" -whole-module-optimization \
    Sources/KTVPro/AudioDevices.swift Sources/KTVPro/AudioEngine.swift \
    Sources/KTVPro/RecordingWriter.swift Sources/KTVPro/Take.swift Sources/KTVPro/TakePlayer.swift \
    Tests/AudioSmokeTests.swift -o .build/audio-smoke-tests
if [[ "${1:-}" != "--build-only" ]]; then
    .build/audio-smoke-tests
fi
