#!/usr/bin/env bash
#
# Build libgit2 as an iOS XCFramework (static library).
#
# Three slices are compiled and assembled into a single XCFramework:
#   - arm64 device       (PLATFORM=OS64)
#   - arm64 simulator    (PLATFORM=SIMULATORARM64, Apple Silicon Mac)
#   - x86_64 simulator   (PLATFORM=SIMULATOR64,    Intel Mac / CI)
#
# The two simulator slices are merged into a fat binary with lipo before
# the XCFramework is assembled — the standard pattern for multi-arch
# simulator support.
#
# HTTPS is provided by SecureTransport (Apple built-in TLS).
# No OpenSSL, no libssh2, no external dependencies.
#
# Output (inside build/xcframework-ios/):
#   libgit2.xcframework        — the framework directory
#   libgit2.xcframework.zip    — zipped for SPM binaryTarget consumption
#   libgit2.xcframework.zip.sha256
#
# Prerequisites: Xcode CLI tools, CMake >= 3.21, Ninja, curl
#   brew install cmake ninja
#
# Usage:
#   cd /path/to/libgit2
#   bash script/build-xcframework-ios.sh [TAG]
#
# If TAG is supplied the script checks out that tag before building.
# The working tree must be clean when a TAG is given.
# Example:
#   bash script/build-xcframework-ios.sh v1.9.4
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(dirname "$SCRIPT_DIR")"
TAG="${1:-}"

WORK_DIR="${SOURCE_DIR}/build/xcframework-ios"
TOOLCHAIN_URL="https://raw.githubusercontent.com/leetal/ios-cmake/master/ios.toolchain.cmake"
TOOLCHAIN="${WORK_DIR}/ios.toolchain.cmake"

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
for cmd in cmake ninja xcodebuild lipo shasum curl git; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: required command not found: $cmd" >&2
        case "$cmd" in
            cmake|ninja) echo "  Install: brew install cmake ninja" >&2 ;;
            xcodebuild)  echo "  Install: Xcode (from the App Store) or xcode-select --install" >&2 ;;
        esac
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Optional tag checkout
# ---------------------------------------------------------------------------
if [ -n "$TAG" ]; then
    echo "==> Checking out $TAG"
    git -C "$SOURCE_DIR" checkout "$TAG"
fi

LIBGIT2_VERSION=$(git -C "$SOURCE_DIR" describe --tags --exact-match 2>/dev/null || git -C "$SOURCE_DIR" rev-parse --short HEAD)
echo "==> Building libgit2 ${LIBGIT2_VERSION} as iOS XCFramework"
echo "    Source:  $SOURCE_DIR"
echo "    Work:    $WORK_DIR"

mkdir -p "$WORK_DIR"

# ---------------------------------------------------------------------------
# iOS CMake toolchain (leetal/ios-cmake — same as ci/setup-ios-build.sh)
# ---------------------------------------------------------------------------
if [ ! -f "$TOOLCHAIN" ]; then
    echo "==> Downloading ios.toolchain.cmake"
    curl -fsSL "$TOOLCHAIN_URL" -o "$TOOLCHAIN"
fi

# ---------------------------------------------------------------------------
# CMake options common to all slices
#
# Key choices:
#   BUILD_SHARED_LIBS=OFF      static library, embeddable in app bundle
#   USE_HTTPS=SecureTransport  Apple built-in TLS, no OpenSSL dependency
#   USE_SSH=OFF                HTTPS-only; SSH not required for GitHub
#   USE_GSSAPI=OFF             no Kerberos
#   USE_HTTP_PARSER=builtin    no external http-parser dependency
#   USE_REGEX=builtin          no PCRE dependency
# ---------------------------------------------------------------------------
CMAKE_COMMON=(
    -G Ninja
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN"
    -DCMAKE_SYSTEM_NAME=iOS
    -DCMAKE_BUILD_TYPE=Release
    -DBUILD_SHARED_LIBS=OFF
    -DBUILD_TESTS=OFF
    -DDEPRECATE_HARD=ON
    -DUSE_HTTPS=SecureTransport
    -DUSE_SSH=OFF
    -DUSE_GSSAPI=OFF
    -DUSE_HTTP_PARSER=builtin
    -DUSE_REGEX=builtin
)

# ---------------------------------------------------------------------------
# Build one slice and echo the path to the resulting .a
# ---------------------------------------------------------------------------
build_slice() {
    local PLATFORM="$1"
    local BUILD_DIR="${WORK_DIR}/build-${PLATFORM}"
    echo "" >&2
    echo "==> Configuring PLATFORM=${PLATFORM}" >&2
    cmake "${CMAKE_COMMON[@]}" -DPLATFORM="$PLATFORM" -S "$SOURCE_DIR" -B "$BUILD_DIR" >&2
    echo "==> Building PLATFORM=${PLATFORM}" >&2
    cmake --build "$BUILD_DIR" --config Release >&2
    find "$BUILD_DIR" -name "libgit2.a" | head -1
}

LIB_DEVICE=$(build_slice OS64)
LIB_SIM_ARM64=$(build_slice SIMULATORARM64)
LIB_SIM_X86_64=$(build_slice SIMULATOR64)

# ---------------------------------------------------------------------------
# Merge simulator slices into a fat binary
# ---------------------------------------------------------------------------
echo ""
echo "==> Creating simulator fat binary (arm64 + x86_64)"
LIB_SIM_FAT="${WORK_DIR}/libgit2-simulator.a"
lipo -create "$LIB_SIM_ARM64" "$LIB_SIM_X86_64" -output "$LIB_SIM_FAT"

# ---------------------------------------------------------------------------
# Prepare headers directory
#
# Copy include/ into a staging directory and inject a module.modulemap so
# that Swift consumers can `import libgit2` without a bridging header.
# We stage into WORK_DIR rather than modifying the source tree, so this
# works for any historical tag regardless of whether it already has a map.
# ---------------------------------------------------------------------------
HEADERS_DIR="${WORK_DIR}/Headers"
rm -rf "$HEADERS_DIR"
cp -R "${SOURCE_DIR}/include/" "$HEADERS_DIR/"

if [ ! -f "${HEADERS_DIR}/module.modulemap" ]; then
    cat > "${HEADERS_DIR}/module.modulemap" <<'MODULEMAP'
module libgit2 [system] {
    header "git2.h"
    export *
}
MODULEMAP
fi

# ---------------------------------------------------------------------------
# Assemble XCFramework
# ---------------------------------------------------------------------------
echo "==> Assembling XCFramework"
XCFRAMEWORK="${WORK_DIR}/libgit2.xcframework"
rm -rf "$XCFRAMEWORK"
xcodebuild -create-xcframework \
    -library "$LIB_DEVICE"  -headers "$HEADERS_DIR" \
    -library "$LIB_SIM_FAT" -headers "$HEADERS_DIR" \
    -output "$XCFRAMEWORK"

# ---------------------------------------------------------------------------
# Zip (--symlinks preserves any symlinks inside the .xcframework bundle)
# ---------------------------------------------------------------------------
echo "==> Zipping"
OUTPUT_ZIP="${WORK_DIR}/libgit2.xcframework.zip"
rm -f "$OUTPUT_ZIP"
(cd "$WORK_DIR" && zip -r --symlinks "libgit2.xcframework.zip" libgit2.xcframework)

# ---------------------------------------------------------------------------
# Checksum (SPM requires sha256 of the zip)
# ---------------------------------------------------------------------------
SHA256=$(shasum -a 256 "$OUTPUT_ZIP" | awk '{ print $1 }')
echo "$SHA256  libgit2.xcframework.zip" > "${OUTPUT_ZIP}.sha256"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "================================================================"
echo "  libgit2 ${LIBGIT2_VERSION} iOS XCFramework"
echo ""
echo "  Zip:    $OUTPUT_ZIP"
echo "  SHA256: $SHA256"
echo ""
echo "  Next steps:"
echo "  1. Create a GitHub release tagged ${LIBGIT2_VERSION} on your fork"
echo "  2. Upload libgit2.xcframework.zip as a release asset"
echo "  3. Add to your Package.swift:"
echo ""
echo "     .binaryTarget("
echo "         name: \"libgit2\","
echo "         url: \"https://github.com/javiersastre/libgit2/releases/download/${LIBGIT2_VERSION}/libgit2.xcframework.zip\","
echo "         checksum: \"${SHA256}\""
echo "     )"
echo "================================================================"