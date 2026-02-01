#!/bin/bash
set -e

APP_NAME="VoiceScribe"
APP_BUNDLE="${APP_NAME}.app"
BINARY_NAME="VoiceScribe"
SRC_ROOT=$(pwd)

echo "🚀 Building Release..."
swift build -c release --arch arm64

echo "📦 Creating Bundle Structure..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

echo "📋 Copying Artifacts..."
cp ".build/arm64-apple-macosx/release/$BINARY_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "backend/transcribe_daemon.py" "$APP_BUNDLE/Contents/Resources/"

echo "📝 Generating Info.plist..."
cat <<EOF > "$APP_BUNDLE/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.codex.$APP_NAME</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSUIElement</key>
    <true/> <!-- Menu Bar App Mode -->
    <key>NSMicrophoneUsageDescription</key>
    <string>VoiceScribe needs specific access to your microphone to transcribe your voice locally.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "✍️ Signing Bundle..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "✅ App Packaged: $APP_BUNDLE"
echo "To run: open $APP_BUNDLE"
