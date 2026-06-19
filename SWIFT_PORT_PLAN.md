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
- [ ] **Phase 3 — Swift package.** SwiftPM package wrapping the C ABI with an
      idiomatic Swift API (`Geometry`, `throws`, `Data` STL export). Builds with
      `swift build` on Linux and opens in Xcode.
- [ ] **Phase 4 — `Examples/scad2stl` Swift CLI.** SwiftPM executable: reads a
      `.scad`, writes `.stl`. Validate against the MiniCAD 50-example harness
      (the real kernel should clear the cases the reimplementation couldn't).
- [ ] **Phase 5 — Apple/iOS.** CMake iOS-toolchain build → `.xcframework`;
      consumed by the same Swift package via a binary target. (CGAL needs
      GMP/MPFR cross-compiled for iOS — heavier; done on the Mac.) Turnkey
      scripts + docs delivered for Martin to run on macOS.

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
