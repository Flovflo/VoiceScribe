#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/VoiceScribe.xcodeproj"
SCHEME="VoiceScribeAppStore"
ARCHIVE_PATH="${VOICE_SCRIBE_ARCHIVE_PATH:-$ROOT_DIR/dist/VoiceScribeAppStore.xcarchive}"
DERIVED_DATA_PATH="${VOICE_SCRIBE_DERIVED_DATA_PATH:-$ROOT_DIR/dist/DerivedData}"

cd "$ROOT_DIR"

mkdir -p "$(dirname "$ARCHIVE_PATH")" "$DERIVED_DATA_PATH"
"$ROOT_DIR/scripts/generate_xcodeproj.sh"

XCODEBUILD_ARGS=(
  -project "$PROJECT_PATH"
  -scheme "$SCHEME"
  -configuration Release
  -destination "generic/platform=macOS"
  -archivePath "$ARCHIVE_PATH"
  -derivedDataPath "$DERIVED_DATA_PATH"
  archive
)

if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
  XCODEBUILD_ARGS+=(
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"
    CODE_SIGN_STYLE=Automatic
  )
else
  XCODEBUILD_ARGS+=(
    CODE_SIGNING_ALLOWED=NO
  )
fi

xcodebuild "${XCODEBUILD_ARGS[@]}"
