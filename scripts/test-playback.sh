#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
source scripts/toolchain.sh
# CLI Bundle.main looks for resources beside the executable.
rsync -a --exclude '.DS_Store' Resources/GarageBandTemplate.band .build/
xcrun swiftc "${compiler_flags[@]}" -whole-module-optimization \
    Sources/KTVPro/AudioDevices.swift Sources/KTVPro/AudioEngine.swift \
    Sources/KTVPro/RecordingWriter.swift Sources/KTVPro/Take.swift \
    Sources/KTVPro/TakePlayer.swift Sources/KTVPro/TakeMix.swift Sources/KTVPro/Lyrics.swift \
    Sources/KTVPro/WAVRenderer.swift Sources/KTVPro/GarageBandExport.swift \
    Sources/KTVPro/SongLibrary.swift Sources/KTVPro/LyricMatcher.swift Sources/KTVPro/LibraryImporter.swift Sources/KTVPro/PitchRenderer.swift \
    Sources/KTVPro/SongComposition.swift Sources/KTVPro/SessionModel.swift \
    Tests/PlaybackSmokeTests.swift -o .build/playback-smoke-tests
xcrun swiftc "${compiler_flags[@]}" Tests/MakeDemo.swift -o .build/make-demo
if [[ "${1:-}" != "--build-only" ]]; then
    fixture_dir=$(mktemp -d "${TMPDIR:-/tmp/}ktvpro-playback.XXXXXX")
    trap 'rm -rf "$fixture_dir"' EXIT
    .build/make-demo "$fixture_dir/demo.mov"
    .build/playback-smoke-tests "$fixture_dir" "$fixture_dir/demo.mov"
fi
