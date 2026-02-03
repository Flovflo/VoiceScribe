#!/bin/bash
set -e

MLX_SWIFT_DIR="$(pwd)/.build/checkouts/mlx-swift"
CMLX_DIR="$MLX_SWIFT_DIR/Source/Cmlx"
MLX_DIR="$CMLX_DIR/mlx"

INCLUDES="-I$CMLX_DIR/include -I$MLX_DIR -I$CMLX_DIR/mlx-c -I$CMLX_DIR/metal-cpp -I$CMLX_DIR/json/single_include/nlohmann -I$CMLX_DIR/fmt/include"

echo "🔨 Compiling Metal shaders..."

# Find all metal files
METAL_FILES=$(find $MLX_SWIFT_DIR -name "*.metal")

METAL_TOOL="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal"
METALLIB_TOOL="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/metallib"

echo "Using Metal Tool: $METAL_TOOL"

mkdir -p .metal_build
cd .metal_build

for file in $METAL_FILES; do
    filename=$(basename "$file")
    echo "Compiling $filename..."
    "$METAL_TOOL" -c "$file" $INCLUDES -o "${filename}.air"
done

echo "🔗 Linking default.metallib..."
"$METALLIB_TOOL" *.air -o default.metallib

echo "✅ Generated default.metallib"

# Copy to App Bundle
APP_RESOURCES="../VoiceScribe.app/Contents/Resources"
mkdir -p "$APP_RESOURCES"
cp default.metallib "$APP_RESOURCES/"
echo "📦 Installed default.metallib to $APP_RESOURCES"

cd ..
rm -rf .metal_build
