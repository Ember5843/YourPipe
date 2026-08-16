#!/usr/bin/env bash
# Overlay machine-local signing material onto build-profile.json5 before a
# local build. build-profile.json5 is git-ignored (machine-local); the real
# material lives in signing-backup/ (git-ignored) and must never be committed.
# Fresh clones: cp build-profile.template.json5 build-profile.json5 first —
# this script does that automatically when the file is missing.
# Undo with tools/strip-signing.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="signing-backup/build-profile.local.json5"
DST="build-profile.json5"
if [ ! -f "$DST" ]; then
  cp "build-profile.template.json5" "$DST"
  echo "seeded $DST from build-profile.template.json5"
fi
if [ ! -f "$SRC" ]; then
  echo "error: $SRC not found. Create it from your private signing backup" >&2
  echo "(signingConfigs + product signingConfig for this machine)." >&2
  exit 1
fi
cp "$SRC" "$DST"
echo "signing restored into $DST (file is git-ignored; no need to strip before commit)"
