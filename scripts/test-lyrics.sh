#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
source scripts/toolchain.sh
xcrun swiftc "${compiler_flags[@]}" -whole-module-optimization \
    Sources/KTVPro/AudioDevices.swift Sources/KTVPro/SongLibrary.swift Sources/KTVPro/Lyrics.swift \
    Sources/KTVPro/LyricMatcher.swift Sources/KTVPro/LibraryImporter.swift Tests/LyricMatchSmokeTests.swift \
    -o .build/lyric-match-smoke-tests
.build/lyric-match-smoke-tests "$@"
