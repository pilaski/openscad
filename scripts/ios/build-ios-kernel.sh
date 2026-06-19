#!/usr/bin/env bash
#
# build-ios-kernel.sh — configure + build the headless OpenSCAD kernel and the
# openscad_kernel static lib for an iOS slice, using the vendored
# cmake/ios/ios.toolchain.cmake and the cross-compiled deps from deps-ios/.
#
# Run once per slice (device, then sim). Output: build-ios/<slice>/ with the
# static archives (libopenscad_kernel.a + libopenscadinternal.a + svg/manifold/
# Clipper2). Assemble across slices with make-xcframework.sh.
#
# PRECONDITION: all kernel deps must be available for this slice as static libs
# under a prefix you pass in DEPS_PREFIX (GMP/MPFR from build-ios-deps.sh, plus
# the CMake-cross deps and boost/glib/fontconfig — see docs/IOS_BUILD.md).
#
# Usage: scripts/ios/build-ios-kernel.sh <device|sim> <DEPS_PREFIX>
set -euo pipefail

SLICE="${1:?usage: build-ios-kernel.sh <device|sim> <DEPS_PREFIX>}"
DEPS_PREFIX="${2:?missing DEPS_PREFIX (path to cross-compiled deps for this slice)}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOLCHAIN="$REPO_ROOT/cmake/ios/ios.toolchain.cmake"
BUILD_DIR="$REPO_ROOT/build-ios/$SLICE"

# Map our slice name to an ios-cmake PLATFORM.
case "$SLICE" in
  device) PLATFORM="OS64" ;;
  sim)    PLATFORM="SIMULATORARM64" ;;
  *) echo "slice must be 'device' or 'sim'"; exit 2 ;;
esac

echo "==> Configuring iOS kernel [$SLICE / $PLATFORM]"
cmake -S "$REPO_ROOT" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
  -DPLATFORM="$PLATFORM" \
  -DDEPLOYMENT_TARGET=13.0 \
  -DENABLE_BITCODE=OFF \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="$DEPS_PREFIX" \
  -DCMAKE_FIND_ROOT_PATH="$DEPS_PREFIX" \
  -DHEADLESS=ON -DNULLGL=ON \
  -DENABLE_CGAL=ON -DENABLE_MANIFOLD=ON \
  -DUSE_BUILTIN_MANIFOLD=ON -DUSE_BUILTIN_CLIPPER2=ON \
  -DMANIFOLD_PAR=OFF \
  -DENABLE_PYTHON=OFF -DUSE_MIMALLOC=OFF -DENABLE_TESTS=OFF \
  -DEXPERIMENTAL=OFF

echo "==> Building openscad_kernel [$SLICE]"
cmake --build "$BUILD_DIR" --target openscad_kernel -j"$(sysctl -n hw.ncpu)"

echo "Done: archives in $BUILD_DIR"
