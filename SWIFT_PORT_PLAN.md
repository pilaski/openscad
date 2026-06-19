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
- [ ] **Phase 1 — Compile upstream OpenSCAD headless on Linux.** Prove the real
      kernel builds and renders `scad → stl` via the stock `openscad -o out.stl
      in.scad` CLI. This is the foundation; everything else sits on it.
- [ ] **Phase 2 — Carve out a library + C ABI.** OpenSCAD is built as an
      executable, not a lib. Add a static-lib target exposing a small pure-C ABI
      (`openscad_kernel.h`): evaluate a `.scad` string/file → geometry → STL
      bytes, with structured error + cancellation. Reuse the frozen ABI shape
      from the earlier MiniCAD plan so it's a backend swap, not a redesign.
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
