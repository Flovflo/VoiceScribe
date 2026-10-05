#!/bin/bash
set -euo pipefail

APP_NAME="VoiceScribe"
APP_BUNDLE="${APP_NAME}.app"
BINARY_NAME="VoiceScribe"
SRC_ROOT=$(pwd)
ICON_PACK_DIR="assets/native-icon.icon"
ICON_SOURCE="$ICON_PACK_DIR/Assets/voice-scribe-icon.png"
RENDERED_ICON_SOURCE="$SRC_ROOT/.build/voicescribe-rendered-icon.png"
ICONSET_DIR="VoiceScribe.iconset"
MLX_METALLIB_NAME="default.metallib"
VERSION="${VOICESCRIBE_VERSION:-1.4.5}"
BUILD_NUMBER="${VOICESCRIBE_BUILD:-1}"
BUNDLE_ID="${VOICESCRIBE_BUNDLE_ID:-com.voicescribe.app}"
MIN_MACOS_VERSION="${VOICESCRIBE_MIN_MACOS_VERSION:-14.0}"
SKIP_BUILD="${VOICESCRIBE_SKIP_BUILD:-0}"
SIGN_IDENTITY="${VOICESCRIBE_CODESIGN_IDENTITY:--}"

find_mlx_metallib_source() {
    local candidates=()
    if [ -n "${VOICESCRIBE_MLX_METALLIB_PATH:-}" ]; then
        candidates+=("$VOICESCRIBE_MLX_METALLIB_PATH")
    fi
    # Use the library compiled with this MLX version. System-private copies may
    # have incompatible kernels and must never be shipped in a release bundle.
    candidates+=(
        "$BIN_DIR/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
        "$BIN_DIR/mlx-swift_Cmlx.bundle/default.metallib"
    )
    for path in "${candidates[@]}"; do
        if [ -f "$path" ]; then
            echo "$path"
            return 0
        fi
    done
    return 1
}

render_icon_source() {
    if [ -d "$ICON_PACK_DIR" ] && xcrun --find swift >/dev/null 2>&1; then
        local render_script="$SRC_ROOT/.build/render_icon.swift"
        mkdir -p "$SRC_ROOT/.build"
        cat > "$render_script" <<'EOF'
import Foundation
import QuickLookThumbnailing
import AppKit

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let request = QLThumbnailGenerator.Request(
    fileAt: input,
    size: CGSize(width: 1024, height: 1024),
    scale: 1,
    representationTypes: .all
)
let semaphore = DispatchSemaphore(value: 0)
var finished = false

QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, error in
    defer {
        finished = true
        semaphore.signal()
    }

    if let error {
        fputs("render error: \(error)\n", stderr)
        return
    }

    guard let cgImage = thumbnail?.cgImage else {
        fputs("render error: missing cgImage\n", stderr)
        return
    }

    let rep = NSBitmapImageRep(cgImage: cgImage)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fputs("render error: failed to encode PNG\n", stderr)
        return
    }

    do {
        try data.write(to: output)
    } catch {
        fputs("render error: \(error)\n", stderr)
    }
}

let timeout = semaphore.wait(timeout: .now() + 15)
if timeout == .timedOut && !finished {
    fputs("render error: timed out\n", stderr)
    exit(1)
}
EOF

        if swift "$render_script" "$ICON_PACK_DIR" "$RENDERED_ICON_SOURCE"; then
            echo "$RENDERED_ICON_SOURCE"
            return 0
        fi
    fi

    if [ -f "$ICON_SOURCE" ]; then
        echo "$ICON_SOURCE"
        return 0
    fi

    return 1
}

# Cleanup
rm -rf "$APP_BUNDLE" "$ICONSET_DIR"

if [ "$SKIP_BUILD" != "1" ]; then
    echo "🚀 Building Release..."
    swift build -c release --arch arm64
fi

echo "📦 Creating Bundle Structure..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/MacOS/Resources"

echo "📋 Copying Artifacts..."
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
cp "$BIN_DIR/$BINARY_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

echo "📚 Copying SwiftPM resource bundles..."
find "$BIN_DIR" -maxdepth 1 -type d -name "*.bundle" -print0 | while IFS= read -r -d '' bundle_path; do
    bundle_name=$(basename "$bundle_path")
    cp -R "$bundle_path" "$APP_BUNDLE/Contents/Resources/$bundle_name"
    echo "   Added: $bundle_name"
done

echo "🧠 Installing MLX Metallib..."
if MLX_METALLIB_SOURCE=$(find_mlx_metallib_source); then
    # MLX runtime probes multiple locations relative to the executable:
    # 1) Contents/MacOS/mlx.metallib
    # 2) Contents/MacOS/Resources/mlx.metallib
    # 3) Contents/MacOS/Resources/default.metallib
    # We also keep a canonical copy in Contents/Resources for app resources.
    cp "$MLX_METALLIB_SOURCE" "$APP_BUNDLE/Contents/MacOS/mlx.metallib"
    cp "$MLX_METALLIB_SOURCE" "$APP_BUNDLE/Contents/MacOS/Resources/mlx.metallib"
    cp "$MLX_METALLIB_SOURCE" "$APP_BUNDLE/Contents/MacOS/Resources/$MLX_METALLIB_NAME"
    cp "$MLX_METALLIB_SOURCE" "$APP_BUNDLE/Contents/Resources/$MLX_METALLIB_NAME"
    echo "   Using: $MLX_METALLIB_SOURCE"
else
    echo "❌ Error: No MLX metallib source found."
    echo "   Install Xcode's Metal Toolchain and rebuild, or set VOICESCRIBE_MLX_METALLIB_PATH."
    exit 1
fi

echo "🎨 Processing Icon..."
if RASTER_ICON_SOURCE=$(render_icon_source); then
    mkdir -p "$ICONSET_DIR"
    
    # Generate standard icon sizes
    sips -z 16 16     -s format png "$RASTER_ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16.png" > /dev/null
    sips -z 32 32     -s format png "$RASTER_ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16@2x.png" > /dev/null
    sips -z 32 32     -s format png "$RASTER_ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32.png" > /dev/null
    sips -z 64 64     -s format png "$RASTER_ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32@2x.png" > /dev/null
    sips -z 128 128   -s format png "$RASTER_ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128.png" > /dev/null
    sips -z 256 256   -s format png "$RASTER_ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128@2x.png" > /dev/null
    sips -z 256 256   -s format png "$RASTER_ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256.png" > /dev/null
    sips -z 512 512   -s format png "$RASTER_ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256@2x.png" > /dev/null
    sips -z 512 512   -s format png "$RASTER_ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512.png" > /dev/null
    sips -z 1024 1024 -s format png "$RASTER_ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512@2x.png" > /dev/null

    echo "   Converting to .icns..."
    iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/VoiceScribe.icns"
    rm -rf "$ICONSET_DIR"
else
    echo "⚠️ Warning: no icon source found. Using generic icon."
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
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>VoiceScribe</string>
    <key>CFBundleDisplayName</key>
    <string>VoiceScribe</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MIN_MACOS_VERSION</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>VoiceScribe needs specific access to your microphone to transcribe your voice locally.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "✍️ Signing Bundle..."
chmod -R u+w "$APP_BUNDLE"
xattr -cr "$APP_BUNDLE"
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE"

echo "✅ App Packaged: $APP_BUNDLE"
