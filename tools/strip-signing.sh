#!/usr/bin/env bash
# Reset build-profile.json5 to the sanitized template after a local build that
# used tools/restore-signing.sh. build-profile.json5 is git-ignored, so this
# is hygiene only (e.g. before sharing the working tree), not commit safety.
set -euo pipefail
cd "$(dirname "$0")/.."
cp "build-profile.template.json5" "build-profile.json5"
echo "build-profile.json5 reset to the sanitized template"
