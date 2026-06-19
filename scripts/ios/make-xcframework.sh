#!/usr/bin/env bash
#
# make-xcframework.sh — merge the per-slice OpenSCAD static archives into a
# single fat static lib per slice, then bundle them as OpenSCADKernel.xcframework
# with the public C ABI header. Consume from SwiftPM via a binaryTarget.
#
# PRECONDITION: build-ios-kernel.sh has produced build-ios/device and
# build-ios/sim. NOTE: this bundles only the OpenSCAD-built archives; the
# cross-compiled third-party deps (gmp/mpfr/cgal-headers/boost/glib/...) must
# also be linked by the final app — either merged here with libtool or linked
# from deps-ios prefixes in the app target. See docs/IOS_BUILD.md.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$REPO_ROOT/build-ios/OpenSCADKernel.xcframework"
HEADER="$REPO_ROOT/src/swift/include/openscad_kernel.h"

ARCHIVES=(
  libopenscad_kernel.a
  libopenscadinternal.a
  libsvg.a
  submodules/manifold/src/libmanifold.a
  submodules/Clipper2/CPP/libClipper2.a
)

merge_slice() { # slice
  local slice="$1"
  local sdir="$REPO_ROOT/build-ios/$slice"
  local inputs=()
  for a in "${ARCHIVES[@]}"; do inputs+=("$sdir/$a"); done
  echo "==> [$slice] merging ${#inputs[@]} archives -> libOpenSCADKernel.a"
  libtool -static -o "$sdir/libOpenSCADKernel.a" "${inputs[@]}"
  echo "$sdir/libOpenSCADKernel.a"
}

# Per-slice headers dir (xcframework wants a headers path alongside the lib).
HDR_DIR="$REPO_ROOT/build-ios/headers"
mkdir -p "$HDR_DIR"
cp "$HEADER" "$HDR_DIR/"

dev_lib="$(merge_slice device)"
sim_lib="$(merge_slice sim)"

rm -rf "$OUT"
echo "==> Creating $OUT"
xcodebuild -create-xcframework \
  -library "$dev_lib" -headers "$HDR_DIR" \
  -library "$sim_lib" -headers "$HDR_DIR" \
  -output "$OUT"

echo "Done: $OUT"
echo "Wire it into SwiftPM with a binaryTarget — see docs/IOS_BUILD.md."
