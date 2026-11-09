#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
source scripts/toolchain.sh
xcrun swiftc "${compiler_flags[@]}" -whole-module-optimization \
    Sources/KTVPro/AudioDevices.swift Sources/KTVPro/SongLibrary.swift \
    Sources/KTVPro/Lyrics.swift Sources/KTVPro/LyricMatcher.swift \
    Sources/KTVPro/LibraryImporter.swift Sources/KTVPro/FiveSingMetadata.swift Sources/KTVPro/FiveSingBrowser.swift \
    Sources/KTVPro/StudioTheme.swift \
    Tests/DownloadSmokeTests.swift -o .build/download-smoke-tests
echo "Built .build/download-smoke-tests; pass isolated library root, original MP3, and local attachment URL."
