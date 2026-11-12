#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
scripts/build-app.sh --release
exec scripts/distribution/create-dmg.sh
