# OpenSCAD → Swift wrapper → scad2stl — Port Plan

Goal: use the **real OpenSCAD geometry kernel** (not a reimplementation) behind a
Swift package, so it can power a command-line `scad2stl` tool and, ultimately, an
iOS app. No GUI, no Qt, no OpenGL — headless rendering only.

This is a branch of upstream `openscad/openscad` that adds a thin C ABI + Swift
package on top of the existing headless build.

## Decisions (from Martin, 2026-06-19)
1. **License:** not a concern (personal/sideload use). Free to vendor GPL OpenSCAD.
2. **Functionality:** *full* OpenSCAD geometry — **CGAL + Manifold both enabled**
   (so `minkowski()`, `roof()`, exact booleans, projection, DXF/SVG, text, etc.
   all work). Not the Manifold-only subset.
3. **Host:** build + validate on **Linux ARM64 first** (this Raspberry Pi). The
   Apple/iOS xcframework build happens later on Martin's Mac. For the CLI tool the
   platform makes no difference.

## Build configuration (headless, full geometry)
Upstream supports this directly — no source hacks needed to go headless:
```
-DHEADLESS=ON          # no Qt GUI frontend
-DNULLGL=ON            # no OpenGL/GLEW/OpenCSG (implies HEADLESS)
-DENABLE_CGAL=ON       # full exact-geometry backend (minkowski, etc.)
-DENABLE_MANIFOLD=ON   # fast mesh-boolean backend (default)
-DUSE_BUILTIN_MANIFOLD=ON -DUSE_BUILTIN_CLIPPER2=ON   # vendored submodules
-DENABLE_PYTHON=OFF -DUSE_MIMALLOC=OFF -DENABLE_TESTS=OFF
```

## Phases
- [x] **Phase 1 — Compile upstream OpenSCAD headless on Linux.** ✅ DONE
      2026-06-19. Real kernel builds (`-O1 -j2`, ~13 min, 14.6 MB `build/openscad`)
      and renders `scad → stl`: difference (Manifold) 272 facets genus-1 NoError;
      `minkowski()` via `--backend=CGAL` 140 tris — confirms *full* CGAL geometry,
      not just the Manifold subset. Note: `-j4` OOM-kills on this 7.7 GB host;
      use `-j2` (or `-j1`). Build via `./build-headless.sh [jobs]`.
- [x] **Phase 2 — Carve out a library + C ABI.** ✅ DONE 2026-06-19. Added
      `src/swift/include/openscad_kernel.h` (pure-C ABI), `src/swift/openscad_kernel.cpp`
      (wraps the real `parse → instantiate → GeometryEvaluator → export_*`
      pipeline), and CMake targets `openscad_kernel` (static lib linking
      `OpenSCADLibInternal`+`svg`) and `scad2stl_c` (C harness). ABI: `osk_init`,
      `osk_render_string` (→ in-memory buffer), `osk_render_file`, `osk_backend`,
      buffer/string free. Validated: difference→272 tris, minkowski(CGAL)→140
      tris, byte-exact valid binary STL matching the stock binary's counts.
      (Harmless localization warning when resource path unset — translations only.)
- [x] **Phase 3 — Swift package.** ✅ DONE 2026-06-19. `swift/` SwiftPM package:
      `COpenSCADKernel` (Clang module over the C ABI + link recipe),
      `OpenSCADKernel` (idiomatic facade: `OpenSCAD.render`/`renderFile`,
      `OpenSCADFormat`, `OpenSCADError`, `Data` output), XCTest suite. Builds with
      Swift 6.3 on Linux against the prebuilt static libs (linker flags in
      `Package.swift`, `--start-group` to resolve circular archives;
      `OPENSCAD_BUILD_DIR` override). All 4 tests pass (incl. minkowski/CGAL +
      clean parse-error throw). Fixed `osk_init(nil)`: must not call
      `PlatformUtils::applicationPath()` before `registerApplicationPath()`.
- [x] **Phase 4 — `scad2stl` Swift CLI.** ✅ DONE 2026-06-19. Executable product
      in the package (`Sources/scad2stl`): `scad2stl <in.scad> <out> [--fn N]
      [--ascii]`, format inferred from extension. Output **byte-identical** to the
      C harness and the stock `openscad` binary (272-tri difference, 140-tri
      minkowski). Build/run docs in `swift/README.md`. **Validation: 50/50
      official OpenSCAD examples render to valid non-empty STL** (vs 33/50 for the
      old from-scratch reimpl) — incl. DXF import, projection(), text(), MCAD +
      search(), surface() images, and the logo cases that used to time out
      (now 7.4k / 14.4k tris). Run with `OPENSCADPATH=<repo>/libraries`.
- [~] **Phase 5 — Apple/iOS.** 🚧 SCAFFOLDED 2026-06-19 (build runs on Mac, not
      this Linux host). Delivered: `cmake/ios/ios.toolchain.cmake` (leetal,
      BSD-3); `scripts/macos/build-macos.sh` (brew + cmake — the recommended
      *first* step, gets the kernel + Swift package running on macOS with no
      cross-compile); `Package.swift` made macOS/Linux conditional (libc++/brew
      vs libstdc++/`--start-group`); `scripts/ios/build-ios-deps.sh` (GMP/MPFR
      cross-compile, `--disable-assembly`); `scripts/ios/build-ios-kernel.sh`
      (per-slice CMake, device=OS64/sim=SIMULATORARM64); `scripts/ios/make-xcframework.sh`;
      `docs/IOS_BUILD.md` (full dependency table + steps + binaryTarget wiring).
      **Open decision (in the guide §2): route A "slim iOS core"** (patch CMake
      to drop text/import/2D-export → no glib/fontconfig/cairo; keep full 3D CSG
      + minkowski + STL) **vs route B full parity** (cross-compile glib +
      fontconfig + CoreText font shim). Remaining: cross-compile the rest of the
      deps for iOS and build the xcframework on the Mac.

## Linux build dependencies (headless, no Qt/GL)
Derived from `scripts/uni-get-dependencies.sh`, minus Qt/OpenGL/X:
```
build-essential cmake ninja-build pkg-config flex bison git curl gettext
lib3mf-dev libboost-program-options-dev libboost-regex-dev libboost-system-dev
libcairo2-dev libcgal-dev libdouble-conversion-dev libeigen3-dev libffi-dev
libfontconfig-dev libfreetype-dev libglib2.0-dev libgmp-dev libharfbuzz-dev
libmpfr-dev libtbb-dev libxml2-dev libzip-dev nettle-dev python3-dev
```
Manifold + Clipper2 come from in-tree submodules (already checked out).

## Status log
- 2026-06-19: Branch `swift-wrapper` created off upstream master
  (`openscad-2019.05-3946-g0a66508c6`, manifold v3.5.1). cmake 4.3.2 + ninja in
  workspace venv. Waiting on system deps to start Phase 1 build.
