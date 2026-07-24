#!/usr/bin/env bash
# Overlay machine-local signing material onto build-profile.json5 before a
# local build. The real material lives in signing-backup/ (git-ignored) and
# must never be committed. Undo with tools/strip-signing.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="signing-backup/build-profile.local.json5"
DST="build-profile.json5"
if [ ! -f "$SRC" ]; then
  echo "error: $SRC not found. Create it from your private signing backup" >&2
  echo "(signingConfigs + product signingConfig for this machine)." >&2
  exit 1
fi
cp "$DST" "signing-backup/build-profile.sanitized.json5"
cp "$SRC" "$DST"
echo "signing restored into $DST (sanitized copy kept in signing-backup/)"
