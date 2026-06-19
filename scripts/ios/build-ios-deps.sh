#!/usr/bin/env bash
#
# build-ios-deps.sh — cross-compile the autotools-based foundation deps
# (GMP, MPFR) for iOS device (arm64) and simulator (arm64). These are CGAL's
# foundation and the trickiest to cross-compile (assembly must be disabled).
#
# The remaining deps are handled differently (see docs/IOS_BUILD.md):
#   - header-only: Eigen, CGAL        -> just point CMake at the headers
#   - CMake cross: manifold, Clipper2, double-conversion, freetype, harfbuzz,
#                  libxml2, libzip     -> build with the ios.toolchain.cmake
#   - boost: build with b2 (toolset=darwin, architecture=arm)
#   - glib / fontconfig / cairo: the hard ones; see the guide for options
#
# Run on macOS with Xcode installed. Produces per-arch prefixes under
#   deps-ios/<arch>/{include,lib}
#
# Usage: scripts/ios/build-ios-deps.sh
set -euo pipefail

GMP_VERSION="6.3.0"
MPFR_VERSION="4.2.1"
IOS_MIN="13.0"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$REPO_ROOT/deps-ios"
SRC="$WORK/src"
mkdir -p "$SRC"

# arch -> (sdk, clang target triple)
declare -A SDK=( [device]="iphoneos" [sim]="iphonesimulator" )
declare -A TARGET=( [device]="arm64-apple-ios${IOS_MIN}" [sim]="arm64-apple-ios${IOS_MIN}-simulator" )

fetch() { # url, outfile
  [ -f "$SRC/$2" ] || curl -sSL -o "$SRC/$2" "$1"
}

build_gmp_mpfr() { # slice (device|sim)
  local slice="$1"
  local sysroot; sysroot="$(xcrun --sdk "${SDK[$slice]}" --show-sdk-path)"
  local prefix="$WORK/$slice"
  local cc="$(xcrun -f clang)"
  local cflags="-arch arm64 -isysroot $sysroot -target ${TARGET[$slice]} -fembed-bitcode-marker"
  mkdir -p "$prefix"

  echo "==> [$slice] GMP $GMP_VERSION"
  tar xf "$SRC/gmp-$GMP_VERSION.tar.xz" -C "$WORK"
  pushd "$WORK/gmp-$GMP_VERSION" >/dev/null
    # --disable-assembly is essential: GMP's hand-tuned asm is not iOS-valid.
    ./configure --host=aarch64-apple-darwin --prefix="$prefix" \
      --disable-assembly --enable-static --disable-shared --enable-cxx \
      CC="$cc" CFLAGS="$cflags" CXXFLAGS="$cflags"
    make -j"$(sysctl -n hw.ncpu)" && make install
  popd >/dev/null
  rm -rf "$WORK/gmp-$GMP_VERSION"

  echo "==> [$slice] MPFR $MPFR_VERSION"
  tar xf "$SRC/mpfr-$MPFR_VERSION.tar.xz" -C "$WORK"
  pushd "$WORK/mpfr-$MPFR_VERSION" >/dev/null
    ./configure --host=aarch64-apple-darwin --prefix="$prefix" \
      --with-gmp="$prefix" --enable-static --disable-shared \
      CC="$cc" CFLAGS="$cflags"
    make -j"$(sysctl -n hw.ncpu)" && make install
  popd >/dev/null
  rm -rf "$WORK/mpfr-$MPFR_VERSION"
}

fetch "https://gmplib.org/download/gmp/gmp-$GMP_VERSION.tar.xz" "gmp-$GMP_VERSION.tar.xz"
fetch "https://www.mpfr.org/mpfr-current/mpfr-$MPFR_VERSION.tar.xz" "mpfr-$MPFR_VERSION.tar.xz"

for slice in device sim; do
  build_gmp_mpfr "$slice"
done

echo
echo "GMP + MPFR built for device + sim under: $WORK/{device,sim}"
echo "Next: cross-compile the CMake deps and the kernel (build-ios-kernel.sh),"
echo "      then assemble the xcframework (make-xcframework.sh)."
