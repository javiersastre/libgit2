#!/usr/bin/env bash
# script/build-android-jni.sh — Builds static libgit2 + mbedTLS for Android NDK.
#
# Outputs: libgit2.android.zip in the repo root, structured as:
#   arm64-v8a/{libgit2.a,libmbedtls.a,libmbedcrypto.a,libmbedx509.a}
#   x86_64/  {libgit2.a,libmbedtls.a,libmbedcrypto.a,libmbedx509.a}
#   include/ {git2.h, git2/}
#
# Usage:
#   export ANDROID_NDK_HOME=~/Library/Android/sdk/ndk/27.1.12297006
#   ./script/build-android-jni.sh
#
# Or let it auto-detect the newest NDK under ANDROID_SDK_ROOT:
#   export ANDROID_SDK_ROOT=~/Library/Android/sdk
#   ./script/build-android-jni.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$(mktemp -d -t libgit2-android-XXXXXXXX)"
OUTPUT_ZIP="$REPO_ROOT/libgit2.android.zip"

LIBGIT2_VERSION="v1.9.4"
MBEDTLS_VERSION="v3.6.2"
ABIS=("arm64-v8a" "x86_64")
API_LEVEL=24

echo "Build dir: $BUILD_DIR"
echo "Output:    $OUTPUT_ZIP"

# ---------------------------------------------------------------------------
# Locate Android NDK
# ---------------------------------------------------------------------------

if [[ -z "${ANDROID_NDK_HOME:-}" ]]; then
    if [[ -n "${ANDROID_SDK_ROOT:-}" && -d "$ANDROID_SDK_ROOT/ndk" ]]; then
        ANDROID_NDK_HOME=$(ls -d "$ANDROID_SDK_ROOT/ndk/"* 2>/dev/null | sort -V | tail -1)
    elif [[ -d "$HOME/Library/Android/sdk/ndk" ]]; then
        ANDROID_NDK_HOME=$(ls -d "$HOME/Library/Android/sdk/ndk/"* 2>/dev/null | sort -V | tail -1)
    else
        echo "ERROR: Set ANDROID_NDK_HOME or ANDROID_SDK_ROOT to point to your Android SDK." >&2
        exit 1
    fi
fi

TOOLCHAIN="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake"
if [[ ! -f "$TOOLCHAIN" ]]; then
    echo "ERROR: Android CMake toolchain not found at $TOOLCHAIN" >&2
    exit 1
fi
echo "NDK:       $ANDROID_NDK_HOME"

# ---------------------------------------------------------------------------
# Download sources
# ---------------------------------------------------------------------------

LIBGIT2_SRC="$BUILD_DIR/libgit2-src"
MBEDTLS_SRC="$BUILD_DIR/mbedtls-src"

echo ""
echo "--- Cloning libgit2 $LIBGIT2_VERSION ---"
git clone --depth 1 --branch "$LIBGIT2_VERSION" \
    https://github.com/libgit2/libgit2.git "$LIBGIT2_SRC"

echo ""
echo "--- Cloning mbedTLS $MBEDTLS_VERSION ---"
# mbedTLS 3.x splits its CMake framework into a git submodule; --recurse-submodules is required.
git clone --depth 1 --branch "$MBEDTLS_VERSION" --recurse-submodules --shallow-submodules \
    https://github.com/Mbed-TLS/mbedtls.git "$MBEDTLS_SRC"

OUTPUT_DIR="$BUILD_DIR/output"
mkdir -p "$OUTPUT_DIR"

# ---------------------------------------------------------------------------
# Build per-ABI
# ---------------------------------------------------------------------------

for ABI in "${ABIS[@]}"; do
    echo ""
    echo "=== ABI: $ABI ==="

    MBEDTLS_BUILD="$BUILD_DIR/mbedtls-build-$ABI"
    MBEDTLS_INSTALL="$BUILD_DIR/mbedtls-install-$ABI"
    mkdir -p "$MBEDTLS_BUILD" "$MBEDTLS_INSTALL"

    echo "  [1/2] Building mbedTLS for $ABI..."
    cmake -S "$MBEDTLS_SRC" -B "$MBEDTLS_BUILD" \
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
        -DANDROID_ABI="$ABI" \
        -DANDROID_PLATFORM="android-$API_LEVEL" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$MBEDTLS_INSTALL" \
        -DENABLE_TESTING=OFF \
        -DENABLE_PROGRAMS=OFF \
        -DMBEDTLS_FATAL_WARNINGS=OFF \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -Wno-dev \
        > "$BUILD_DIR/mbedtls-cmake-$ABI.log" 2>&1

    cmake --build "$MBEDTLS_BUILD" --parallel \
        >> "$BUILD_DIR/mbedtls-cmake-$ABI.log" 2>&1
    cmake --install "$MBEDTLS_BUILD" \
        >> "$BUILD_DIR/mbedtls-cmake-$ABI.log" 2>&1
    echo "  mbedTLS done."

    LIBGIT2_BUILD="$BUILD_DIR/libgit2-build-$ABI"
    LIBGIT2_INSTALL="$BUILD_DIR/libgit2-install-$ABI"
    mkdir -p "$LIBGIT2_BUILD" "$LIBGIT2_INSTALL"

    echo "  [2/2] Building libgit2 for $ABI..."
    # Pass mbedTLS paths explicitly: FindmbedTLS.cmake uses PATH_SUFFIXES "library" which doesn't
    # match the cmake standard install layout (lib/). Bypassing find_library/find_path entirely.
    cmake -S "$LIBGIT2_SRC" -B "$LIBGIT2_BUILD" \
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
        -DANDROID_ABI="$ABI" \
        -DANDROID_PLATFORM="android-$API_LEVEL" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$LIBGIT2_INSTALL" \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_TESTS=OFF \
        -DBUILD_CLI=OFF \
        -DUSE_SSH=OFF \
        -DUSE_HTTPS=mbedTLS \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DMBEDTLS_INCLUDE_DIR="$MBEDTLS_INSTALL/include" \
        -DMBEDTLS_LIBRARY="$MBEDTLS_INSTALL/lib/libmbedtls.a" \
        -DMBEDX509_LIBRARY="$MBEDTLS_INSTALL/lib/libmbedx509.a" \
        -DMBEDCRYPTO_LIBRARY="$MBEDTLS_INSTALL/lib/libmbedcrypto.a" \
        -Wno-dev \
        > "$BUILD_DIR/libgit2-cmake-$ABI.log" 2>&1

    cmake --build "$LIBGIT2_BUILD" --parallel \
        >> "$BUILD_DIR/libgit2-cmake-$ABI.log" 2>&1
    cmake --install "$LIBGIT2_BUILD" \
        >> "$BUILD_DIR/libgit2-cmake-$ABI.log" 2>&1
    echo "  libgit2 done."

    # Collect per-ABI artifacts
    ABI_OUT="$OUTPUT_DIR/$ABI"
    mkdir -p "$ABI_OUT"
    cp "$LIBGIT2_INSTALL/lib/libgit2.a"         "$ABI_OUT/"
    cp "$MBEDTLS_INSTALL/lib/libmbedtls.a"      "$ABI_OUT/"
    cp "$MBEDTLS_INSTALL/lib/libmbedcrypto.a"   "$ABI_OUT/"
    cp "$MBEDTLS_INSTALL/lib/libmbedx509.a"     "$ABI_OUT/"

    echo "  Artifacts for $ABI:"
    ls -lh "$ABI_OUT/"
done

# ---------------------------------------------------------------------------
# Copy public headers (architecture-independent — take from arm64-v8a install)
# ---------------------------------------------------------------------------

echo ""
echo "--- Copying public headers ---"
cp -r "$BUILD_DIR/libgit2-install-arm64-v8a/include" "$OUTPUT_DIR/"

# ---------------------------------------------------------------------------
# Package
# ---------------------------------------------------------------------------

echo ""
echo "--- Creating zip ---"
rm -f "$OUTPUT_ZIP"
(cd "$OUTPUT_DIR" && zip -r "$OUTPUT_ZIP" .)

echo ""
echo "Done: $OUTPUT_ZIP"
echo "SHA256: $(shasum -a 256 "$OUTPUT_ZIP" | awk '{print $1}')"
echo ""
echo "Cleaning up build dir..."
rm -rf "$BUILD_DIR"
echo "All done."
