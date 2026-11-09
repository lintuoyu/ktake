#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
source scripts/toolchain.sh
xcrun swiftc "${compiler_flags[@]}" -whole-module-optimization \
    Sources/KTVPro/AudioDevices.swift Sources/KTVPro/Take.swift Sources/KTVPro/TakeMix.swift \
    Sources/KTVPro/TakeEffectsPreview.swift Sources/KTVPro/WAVRenderer.swift \
    Sources/KTVPro/AudioEngine.swift Sources/KTVPro/RecordingWriter.swift \
    Tests/TakeMixSmokeTests.swift -o .build/take-mix-smoke-tests
if [[ "${1:-}" != "--build-only" ]]; then
    .build/take-mix-smoke-tests
fi
