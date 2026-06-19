# OpenSCADKernel — Swift wrapper over the real OpenSCAD kernel

A SwiftPM package that wraps the genuine OpenSCAD geometry kernel (headless,
CGAL + Manifold) behind an idiomatic Swift API, plus a `scad2stl` command-line
tool. It builds on the pure-C ABI in `../src/swift/include/openscad_kernel.h`.

## Layout
- `Sources/COpenSCADKernel/` — Clang module exposing the C ABI header + the
  link recipe for the prebuilt static libs.
- `Sources/OpenSCADKernel/` — Swift facade (`OpenSCAD.render`, `renderFile`,
  `OpenSCADFormat`, `OpenSCADError`).
- `Sources/scad2stl/` — CLI: `scad2stl <in.scad> <out.stl> [--fn N] [--ascii]`.
- `Tests/` — XCTest suite.

## Prerequisite: build the kernel static libs (CMake)
The Swift package links prebuilt archives produced by the OpenSCAD CMake build.
Build them first (headless, full geometry):

```sh
cd ..                      # repo root
./build-headless.sh 2      # -j2 (this 7.7GB host OOMs at -j4); produces build/*.a
```

This yields `build/libopenscad_kernel.a`, `build/libopenscadinternal.a`,
`build/libsvg.a`, `build/submodules/manifold/src/libmanifold.a`, and
`build/submodules/Clipper2/CPP/libClipper2.a`.

By default `Package.swift` looks in `<repo>/build`. Override with:
```sh
export OPENSCAD_BUILD_DIR=/path/to/build
```

## Build & run (Linux)
```sh
export PATH=/tmp/swift-toolchain/usr/bin:$PATH
export LD_LIBRARY_PATH=/tmp/swift-toolchain/usr/lib/swift/linux

swift build --product scad2stl
swift test

.build/aarch64-unknown-linux-gnu/debug/scad2stl in.scad out.stl --fn 64
```

Note: SwiftPM does not track the external `.a` files' mtimes. After rebuilding
the kernel, force a relink by removing the cached products or touching a Swift
source:
```sh
rm -f .build/*/debug/scad2stl .build/*/debug/*PackageTests.xctest
```

## Swift API
```swift
import OpenSCADKernel

let stl = try OpenSCAD.render(source: """
  difference() { cube([20,20,10], center=true); cylinder(h=12, r=4, $fn=64, center=true); }
  """, format: .binarySTL)        // -> Foundation.Data

try OpenSCAD.renderFile(input: "part.scad", output: "part.stl", fn: 64)
```

## macOS / iOS
The same `Package.swift` shape applies; the difference is *how the static libs
are produced*. On macOS, run the CMake build with the macOS toolchain; for iOS,
cross-compile the kernel + its deps (CGAL needs GMP/MPFR) into an
`.xcframework` and consume it via a SwiftPM binary target. See `../SWIFT_PORT_PLAN.md`
Phase 5.
