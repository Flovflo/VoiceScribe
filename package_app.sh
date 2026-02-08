#!/bin/bash
set -euo pipefail

APP_NAME="VoiceScribe"
APP_BUNDLE="${APP_NAME}.app"
BINARY_NAME="VoiceScribe"
SRC_ROOT=$(pwd)
ICON_SOURCE="AppIcon.png"
ICONSET_DIR="VoiceScribe.iconset"
MLX_METALLIB_NAME="default.metallib"
VERSION="${VOICESCRIBE_VERSION:-1.3.0}"
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

    candidates+=(
        "$SRC_ROOT/$MLX_METALLIB_NAME"
        "$SRC_ROOT/mlx.metallib"
        "/System/Library/PrivateFrameworks/CorePhotogrammetry.framework/Resources/mlx.metallib"
        "/System/Library/PrivateFrameworks/CorePhotogrammetry.framework/Versions/Current/Resources/mlx.metallib"
        "/System/Library/PrivateFrameworks/CorePhotogrammetry.framework/Versions/A/Resources/mlx.metallib"
        "/System/Library/PrivateFrameworks/GESS.framework/Resources/mlx.metallib"
        "/System/Library/PrivateFrameworks/GESS.framework/Versions/Current/Resources/mlx.metallib"
        "/System/Library/PrivateFrameworks/GESS.framework/Versions/A/Resources/mlx.metallib"
    )

    if [ -n "${MD_APPLE_SDK_ROOT:-}" ]; then
        candidates+=(
            "${MD_APPLE_SDK_ROOT}/System/Library/PrivateFrameworks/CorePhotogrammetry.framework/Resources/mlx.metallib"
            "${MD_APPLE_SDK_ROOT}/System/Library/PrivateFrameworks/CorePhotogrammetry.framework/Versions/A/Resources/mlx.metallib"
            "${MD_APPLE_SDK_ROOT}/System/Library/PrivateFrameworks/GESS.framework/Resources/mlx.metallib"
            "${MD_APPLE_SDK_ROOT}/System/Library/PrivateFrameworks/GESS.framework/Versions/A/Resources/mlx.metallib"
            "${MD_APPLE_SDK_ROOT}/Platforms/MacOSX.platform/System/Library/PrivateFrameworks/CorePhotogrammetry.framework/Resources/mlx.metallib"
            "${MD_APPLE_SDK_ROOT}/Platforms/MacOSX.platform/System/Library/PrivateFrameworks/CorePhotogrammetry.framework/Versions/A/Resources/mlx.metallib"
            "${MD_APPLE_SDK_ROOT}/Platforms/MacOSX.platform/System/Library/PrivateFrameworks/GESS.framework/Resources/mlx.metallib"
            "${MD_APPLE_SDK_ROOT}/Platforms/MacOSX.platform/System/Library/PrivateFrameworks/GESS.framework/Versions/A/Resources/mlx.metallib"
        )
    fi

    for path in "${candidates[@]}"; do
        if [ -f "$path" ]; then
            echo "$path"
            return 0
        fi
    done

    local find_roots=(
        "/System/Library/PrivateFrameworks"
    )
    if [ -n "${MD_APPLE_SDK_ROOT:-}" ]; then
        find_roots+=(
            "${MD_APPLE_SDK_ROOT}/System/Library/PrivateFrameworks"
            "${MD_APPLE_SDK_ROOT}/Platforms/MacOSX.platform/System/Library/PrivateFrameworks"
        )
    fi
    for root in "${find_roots[@]}"; do
        if [ -d "$root" ]; then
            local discovered
            discovered=$(find "$root" -name "mlx.metallib" -type f 2>/dev/null | head -n 1 || true)
            if [ -n "$discovered" ]; then
                echo "$discovered"
                return 0
            fi
        fi
    done

    local mlx_root="$SRC_ROOT/.build/checkouts/mlx-swift/Source/Cmlx/mlx"
    local kernels_dir="$mlx_root/mlx/backend/metal/kernels"
    local generated_metallib="$SRC_ROOT/.build/voicescribe-metallib/mlx.metallib"
    if [ -d "$kernels_dir" ] && xcrun -sdk macosx metal -v >/dev/null 2>&1; then
        rm -rf "$SRC_ROOT/.build/voicescribe-metallib"
        mkdir -p "$SRC_ROOT/.build/voicescribe-metallib"

        local kernel_names=(
            "arg_reduce"
            "conv"
            "gemv"
            "layer_norm"
            "random"
            "rms_norm"
            "rope"
            "scaled_dot_product_attention"
            "fence"
            "arange"
            "binary"
            "binary_two"
            "copy"
            "fft"
            "reduce"
            "quantized"
            "fp_quantized"
            "scan"
            "softmax"
            "logsumexp"
            "sort"
            "ternary"
            "unary"
            "steel/conv/kernels/steel_conv"
            "steel/conv/kernels/steel_conv_general"
            "steel/gemm/kernels/steel_gemm_fused"
            "steel/gemm/kernels/steel_gemm_gather"
            "steel/gemm/kernels/steel_gemm_masked"
            "steel/gemm/kernels/steel_gemm_splitk"
            "steel/gemm/kernels/steel_gemm_segmented"
            "gemv_masked"
            "steel/attn/kernels/steel_attention"
            "steel/gemm/kernels/steel_gemm_fused_nax"
            "steel/gemm/kernels/steel_gemm_gather_nax"
            "quantized_nax"
            "fp_quantized_nax"
            "steel/attn/kernels/steel_attention_nax"
        )

        local air_files=()
        local name src air_file safe_name
        for name in "${kernel_names[@]}"; do
            src="$kernels_dir/$name.metal"
            if [ ! -f "$src" ]; then
                continue
            fi
            safe_name="${name//\//_}"
            air_file="$SRC_ROOT/.build/voicescribe-metallib/${safe_name}.air"
            if ! xcrun -sdk macosx metal \
                -x metal \
                -Wall \
                -Wextra \
                -fno-fast-math \
                -Wno-c++17-extensions \
                -Wno-c++20-extensions \
                -c "$src" \
                -I"$mlx_root" \
                -o "$air_file"; then
                air_files=()
                break
            fi
            air_files+=("$air_file")
        done

        if [ "${#air_files[@]}" -gt 0 ] && xcrun -sdk macosx metallib "${air_files[@]}" -o "$generated_metallib"; then
            echo "$generated_metallib"
            return 0
        fi
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
cp ".build/arm64-apple-macosx/release/$BINARY_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

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
    echo "   Set VOICESCRIBE_MLX_METALLIB_PATH or place default.metallib in project root."
    exit 1
fi

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
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE"

echo "✅ App Packaged: $APP_BUNDLE"
