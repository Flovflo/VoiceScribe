#!/bin/bash
set -e

APP_NAME="VoiceScribe"
APP_BUNDLE="${APP_NAME}.app"
BINARY_NAME="VoiceScribe"
SRC_ROOT=$(pwd)
ICON_SOURCE="AppIcon.png"
ICONSET_DIR="VoiceScribe.iconset"

# Cleanup
rm -rf "$APP_BUNDLE" "$ICONSET_DIR"

echo "🚀 Building Release..."
swift build -c release --arch arm64

echo "📦 Creating Bundle Structure..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

echo "📋 Copying Artifacts..."
cp ".build/arm64-apple-macosx/release/$BINARY_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

echo "🎨 Processing Icon..."
if [ -f "$ICON_SOURCE" ]; then
    mkdir -p "$ICONSET_DIR"
    
    # Generate standard icon sizes
    sips -z 16 16     -s format png "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16.png" > /dev/null
    sips -z 32 32     -s format png "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16@2x.png" > /dev/null
    sips -z 32 32     -s format png "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32.png" > /dev/null
    sips -z 64 64     -s format png "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32@2x.png" > /dev/null
    sips -z 128 128   -s format png "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128.png" > /dev/null
    sips -z 256 256   -s format png "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128@2x.png" > /dev/null
    sips -z 256 256   -s format png "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256.png" > /dev/null
    sips -z 512 512   -s format png "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256@2x.png" > /dev/null
    sips -z 512 512   -s format png "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512.png" > /dev/null
    sips -z 1024 1024 -s format png "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512@2x.png" > /dev/null

    echo "   Converting to .icns..."
    iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/VoiceScribe.icns"
    rm -rf "$ICONSET_DIR"
else
    echo "⚠️ Warning: $ICON_SOURCE not found. Using generic icon."
fi

echo "📝 Generating Info.plist..."
cat <<EOF > "$APP_BUNDLE/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.voicescribe.app</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>VoiceScribe</string>
    <key>CFBundleDisplayName</key>
    <string>VoiceScribe</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.2.0</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>LSUIElement</key>
    <false/>
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
