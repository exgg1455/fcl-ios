#!/bin/bash
set -euo pipefail

APP_PATH="$1"
SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
WORK_DIRECTORY="$(pwd)/modern_runtime_work"
LWJGL_VERSION="3.4.3"
SDL_COMMIT="147a8ee32dbf9ac02f3794964490687b6bbda1bc"
MOLTENVK_VERSION="v1.4.2"
MAVEN="https://libraries.minecraft.net/org/lwjgl"

rm -rf "$WORK_DIRECTORY"
mkdir -p "$WORK_DIRECTORY/natives" "$WORK_DIRECTORY/moltenvk" "$WORK_DIRECTORY/sdl"
rm -rf "$APP_PATH/libs_lwjgl" "$APP_PATH/lwjgl_natives"
mkdir -p "$APP_PATH/libs_lwjgl" "$APP_PATH/lwjgl_natives"

echo "Downloading LWJGL $LWJGL_VERSION"
for module in lwjgl lwjgl-freetype lwjgl-jemalloc lwjgl-openal lwjgl-opengl lwjgl-sdl lwjgl-shaderc lwjgl-spvc lwjgl-stb lwjgl-vma lwjgl-vulkan; do
    curl -fsSL --retry 3 -o "$APP_PATH/libs_lwjgl/$module.jar" "$MAVEN/$module/$LWJGL_VERSION/$module-$LWJGL_VERSION.jar"
done

for module in lwjgl lwjgl-freetype lwjgl-jemalloc lwjgl-opengl lwjgl-shaderc lwjgl-spvc lwjgl-stb lwjgl-vma; do
    curl -fsSL --retry 3 -o "$WORK_DIRECTORY/$module-natives.jar" "$MAVEN/$module/$LWJGL_VERSION/$module-$LWJGL_VERSION-natives-macos-arm64.jar"
    unzip -oqj "$WORK_DIRECTORY/$module-natives.jar" '*.dylib' -d "$WORK_DIRECTORY/natives"
done

echo "Converting LWJGL natives to iOS"
for library in "$WORK_DIRECTORY"/natives/*.dylib; do
    xcrun vtool -arch arm64 -set-build-version ios 14.0 17.0 -replace -output "$library" "$library"
    for framework in CoreFoundation CoreGraphics CoreText; do
        install_name_tool -change "/System/Library/Frameworks/$framework.framework/Versions/A/$framework" "/System/Library/Frameworks/$framework.framework/$framework" "$library" 2>/dev/null || true
    done
    ldid -S "$library"
    cp "$library" "$APP_PATH/lwjgl_natives/"
    echo "  $(basename "$library")"
done

echo "Downloading MoltenVK $MOLTENVK_VERSION"
curl -fsSL --retry 3 -o "$WORK_DIRECTORY/moltenvk.tar" "https://github.com/KhronosGroup/MoltenVK/releases/download/$MOLTENVK_VERSION/MoltenVK-ios.tar"
tar -xf "$WORK_DIRECTORY/moltenvk.tar" -C "$WORK_DIRECTORY/moltenvk"
MOLTENVK_LIBRARY="$WORK_DIRECTORY/moltenvk/MoltenVK/MoltenVK/dynamic/MoltenVK.xcframework/ios-arm64/MoltenVK.framework/MoltenVK"
if [ ! -f "$MOLTENVK_LIBRARY" ]; then
    echo "libMoltenVK.dylib for iOS was not found"
    find "$WORK_DIRECTORY/moltenvk" -maxdepth 6
    exit 1
fi
cp "$MOLTENVK_LIBRARY" "$APP_PATH/lwjgl_natives/libMoltenVK.dylib"
install_name_tool -id @rpath/libMoltenVK.dylib "$APP_PATH/lwjgl_natives/libMoltenVK.dylib"
ldid -S "$APP_PATH/lwjgl_natives/libMoltenVK.dylib"

echo "Building SDL bridge"
curl -fsSL --retry 3 -o "$WORK_DIRECTORY/sdl.tar.gz" "https://github.com/libsdl-org/SDL/archive/$SDL_COMMIT.tar.gz"
tar -xzf "$WORK_DIRECTORY/sdl.tar.gz" -C "$WORK_DIRECTORY/sdl" --strip-components 1
python3 "$SCRIPT_DIRECTORY/SDLBridge/generate_stubs.py" "$APP_PATH/libs_lwjgl/lwjgl-sdl.jar" "$SCRIPT_DIRECTORY/SDLBridge/SDLBridge.m" "$WORK_DIRECTORY/SDLStubs.c"
SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos clang -target arm64-apple-ios14.0 -isysroot "$SDK_PATH" -O2 -fobjc-arc \
    -I "$WORK_DIRECTORY/sdl/include" \
    -c "$SCRIPT_DIRECTORY/SDLBridge/SDLBridge.m" -o "$WORK_DIRECTORY/SDLBridge.o"
xcrun --sdk iphoneos clang -target arm64-apple-ios14.0 -isysroot "$SDK_PATH" -O2 \
    -c "$WORK_DIRECTORY/SDLStubs.c" -o "$WORK_DIRECTORY/SDLStubs.o"
xcrun --sdk iphoneos clang -target arm64-apple-ios14.0 -isysroot "$SDK_PATH" -dynamiclib -fobjc-arc \
    "$WORK_DIRECTORY/SDLBridge.o" "$WORK_DIRECTORY/SDLStubs.o" \
    -framework Foundation -framework UIKit -framework QuartzCore \
    -install_name @rpath/libSDL3.dylib \
    -o "$APP_PATH/lwjgl_natives/libSDL3.dylib"
ldid -S "$APP_PATH/lwjgl_natives/libSDL3.dylib"

echo "Modern runtime contents:"
ls -la "$APP_PATH/libs_lwjgl" "$APP_PATH/lwjgl_natives"
