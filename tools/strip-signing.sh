#!/usr/bin/env bash
# Restore the committed (sanitized) build-profile.json5 after a local build
# that used tools/restore-signing.sh. Never commit the signing overlay.
set -euo pipefail
cd "$(dirname "$0")/.."
if git diff --quiet -- build-profile.json5; then
  echo "build-profile.json5 is already at the committed (sanitized) version"
  exit 0
fi
git checkout -- build-profile.json5
echo "build-profile.json5 reset to committed (sanitized) version"
