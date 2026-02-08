#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

RAW_VERSION="${1:-${VOICESCRIBE_VERSION:-dev}}"
VERSION="${RAW_VERSION#v}"
if [ -z "$VERSION" ]; then
    VERSION="dev"
fi

BUILD_NUMBER="${VOICESCRIBE_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

export VOICESCRIBE_VERSION="$VERSION"
export VOICESCRIBE_BUILD="$BUILD_NUMBER"

echo "📦 Packaging app bundle (version: $VERSION, build: $BUILD_NUMBER)..."
bash "$ROOT_DIR/package_app.sh"

DIST_DIR="$ROOT_DIR/dist"
STAGING_DIR="$DIST_DIR/dmg-staging"
DMG_NAME="VoiceScribe-${VERSION}.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
mkdir -p "$DIST_DIR"

cp -R "$ROOT_DIR/VoiceScribe.app" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

if [ -f "$DMG_PATH" ]; then
    rm -f "$DMG_PATH"
fi

echo "💽 Creating DMG..."
hdiutil create \
  -volname "VoiceScribe" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

rm -rf "$STAGING_DIR"

shasum -a 256 "$DMG_PATH" | awk '{print $1}' > "$DMG_PATH.sha256"

echo "✅ DMG ready: $DMG_PATH"
echo "✅ SHA256: $DMG_PATH.sha256"
