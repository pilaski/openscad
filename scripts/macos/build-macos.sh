#!/usr/bin/env bash
#
# build-macos.sh — build the headless OpenSCAD kernel static libs on macOS,
# then the Swift package + scad2stl CLI. This is the "stepping stone" to iOS:
# all dependencies come from Homebrew, so there is no cross-compilation.
#
# After this, `swift build` in ../swift works exactly as on Linux.
#
# Usage:  scripts/macos/build-macos.sh [jobs]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$REPO_ROOT/build-macos"
JOBS="${1:-$(sysctl -n hw.ncpu)}"

echo "==> Initializing required submodules (manifold, Clipper2)"
# USE_BUILTIN_MANIFOLD/USE_BUILTIN_CLIPPER2 below build these from source, so
# they must be checked out. Safe to re-run; no-op if already present.
git -C "$REPO_ROOT" submodule update --init --recursive \
  submodules/manifold submodules/Clipper2

echo "==> Checking Homebrew dependencies"
if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required: https://brew.sh" >&2
  exit 1
fi

# Full headless OpenSCAD dep set (CGAL + Manifold). Qt/OpenGL omitted (NULLGL).
BREW_DEPS=(
  cmake ninja pkg-config flex bison
  cgal gmp mpfr boost eigen
  harfbuzz freetype fontconfig glib double-conversion
  libzip libxml2 cairo lib3mf tbb
)
echo "==> brew install ${BREW_DEPS[*]}"
brew install "${BREW_DEPS[@]}"

# Homebrew keeps flex/bison keg-only; put them first on PATH.
export PATH="$(brew --prefix flex)/bin:$(brew --prefix bison)/bin:$PATH"

echo "==> Configuring (headless, NULLGL, CGAL + Manifold)"
cmake -S "$REPO_ROOT" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="$(brew --prefix)" \
  -DHEADLESS=ON -DNULLGL=ON \
  -DENABLE_CGAL=ON -DENABLE_MANIFOLD=ON \
  -DUSE_BUILTIN_MANIFOLD=ON -DUSE_BUILTIN_CLIPPER2=ON \
  -DENABLE_PYTHON=OFF -DUSE_MIMALLOC=OFF -DENABLE_TESTS=OFF \
  -DEXPERIMENTAL=OFF

echo "==> Building kernel + scad2stl_c (-j$JOBS)"
cmake --build "$BUILD_DIR" --target scad2stl_c -j"$JOBS"

echo "==> Building the Swift package"
( cd "$REPO_ROOT/swift" && OPENSCAD_BUILD_DIR="$BUILD_DIR" swift build --product scad2stl )

echo
echo "Done. Static libs in: $BUILD_DIR"
echo "Run the Swift CLI with:"
echo "  cd $REPO_ROOT/swift && OPENSCAD_BUILD_DIR='$BUILD_DIR' \\"
echo "    swift run scad2stl input.scad output.stl --fn 64"
