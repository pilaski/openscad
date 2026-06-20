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
#
# NOTE: lib3mf is intentionally omitted. It is NOT in core Homebrew (no
# `brew install lib3mf`); upstream OpenSCAD pulls it from a custom tap that has
# been unreliable on macOS since Oct 2025 (openscad/openscad#6250). It only
# powers 3MF import/export, which scad2stl / the mesh path do not need, so we
# build against OpenSCAD's dummy 3MF stubs via CMAKE_REQUIRE_FIND_PACKAGE_Lib3MF=OFF
# below. STL/OFF/OBJ export and all geometry are unaffected. If you later want
# 3MF, install it from OpenSCAD's tap and drop the require=OFF flag.
BREW_DEPS=(
  cmake ninja pkg-config flex bison
  cgal gmp mpfr boost eigen
  harfbuzz freetype fontconfig glib double-conversion
  libzip libxml2 cairo tbb
)

# Which formulae are missing? `brew list --versions` is read-only and works even
# when the Homebrew prefix is owned by another (admin) account.
MISSING=()
for dep in "${BREW_DEPS[@]}"; do
  if ! brew list --versions "$dep" >/dev/null 2>&1; then
    MISSING+=("$dep")
  fi
done

if [ "${#MISSING[@]}" -eq 0 ]; then
  echo "==> All ${#BREW_DEPS[@]} dependencies already installed; skipping install."
else
  echo "==> Missing formulae: ${MISSING[*]}"
  # Homebrew refuses to run under sudo and writes into its prefix as the owning
  # user. If that prefix isn't writable by us (e.g. Homebrew lives under an admin
  # account), don't even try — print the exact command to run as that user.
  BREW_PREFIX="$(brew --prefix)"
  if [ "${SKIP_BREW_INSTALL:-0}" != "1" ] && [ -w "$BREW_PREFIX/Cellar" ] 2>/dev/null; then
    echo "==> brew install ${MISSING[*]}"
    brew install "${MISSING[@]}"
  else
    cat >&2 <<EOF

ERROR: ${#MISSING[@]} Homebrew formula(e) are missing and this account cannot
write to the Homebrew prefix ($BREW_PREFIX), so they cannot be installed here.

Install them from the account that OWNS Homebrew (the admin account), e.g.:

    brew install ${MISSING[*]}

If you are in a normal user shell, you can run it as the admin user without
fully logging out (you'll be prompted for the admin password):

    su - <admin-username> -c 'brew install ${MISSING[*]}'

Do NOT prefix brew with sudo — Homebrew refuses to run as root.

Once the formulae are installed, re-run this script. It will detect them and
proceed straight to the build (set SKIP_BREW_INSTALL=1 to force-skip the check).
EOF
    exit 1
  fi
fi

# Homebrew keeps flex/bison keg-only; put them first on PATH.
export PATH="$(brew --prefix flex)/bin:$(brew --prefix bison)/bin:$PATH"

echo "==> Configuring (headless, NULLGL, CGAL + Manifold)"
cmake -S "$REPO_ROOT" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="$(brew --prefix)" \
  -DHEADLESS=ON -DNULLGL=ON \
  -DENABLE_CGAL=ON -DENABLE_MANIFOLD=ON \
  -DUSE_BUILTIN_MANIFOLD=ON -DUSE_BUILTIN_CLIPPER2=ON \
  -DCMAKE_REQUIRE_FIND_PACKAGE_Lib3MF=OFF \
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
