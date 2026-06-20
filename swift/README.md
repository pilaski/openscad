# OpenSCADKernel — Swift wrapper over the real OpenSCAD kernel

A SwiftPM package that wraps the genuine OpenSCAD geometry kernel (headless,
CGAL + Manifold) behind an idiomatic Swift API, plus a `scad2stl` command-line
tool. It builds on the pure-C ABI in `../src/swift/include/openscad_kernel.h`.

## Layout
- `Sources/COpenSCADKernel/` — Clang module exposing the C ABI header + the
  link recipe for the prebuilt static libs.
- `Sources/OpenSCADKernel/` — Swift facade (`OpenSCAD.render`, `renderFile`,
  `renderMesh`, `Mesh`, `OpenSCADFormat`, `OpenSCADError`).
- `Sources/OpenSCADKernelUI/` — SwiftUI + SceneKit view layer (`OpenSCADMeshView`,
  `OpenSCADSourceView`, `Mesh.makeSCNGeometry()`). Gated on `canImport(SceneKit)`,
  so it compiles to an **empty module on Linux** and only does anything on
  Apple platforms.
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

### 3D view (no STL round-trip)
For an interactive view, render straight to an in-memory triangle mesh instead
of serializing STL. `Mesh` holds flat, GPU-ready buffers
(`positions`/`normals: [Float]`, `indices: [UInt32]`).

```swift
let mesh = try OpenSCAD.renderMesh(source: src, fn: 24)   // low fn = fast preview
print(mesh.vertexCount, mesh.triangleCount)
```

On Apple platforms, `OpenSCADKernelUI` turns that into a SwiftUI view with
orbit/zoom — and a source-driven view that renders off the main thread with
loading + error states:

```swift
import OpenSCADKernelUI

// Re-renders whenever source/fn change; pass a low fn for a fast preview, 0 = full res.
OpenSCADSourceView(source: editorText, fn: previewFN)
```

The view maps OpenSCAD's **Z-up** space to SceneKit's **Y-up**, frames the
camera to the model's bounding sphere, and `Mesh.makeSCNGeometry()` wraps the
flat buffers as `SCNGeometrySource`/`SCNGeometryElement` with no recopy.

## macOS build

Everything below runs on a **Mac with Xcode** — it cannot be done on the Linux
host. This is the recommended first step onto Apple platforms: one script, all
deps from Homebrew, **no cross-compiling**. iOS comes after (see
`../docs/IOS_BUILD.md`).

### Prerequisites
1. **Xcode + Command Line Tools** — `xcode-select --install` (clang, the macOS
   SDK, the Swift toolchain). Full Xcode if you'll build the app UI.
2. **Homebrew** — <https://brew.sh>. The build script installs the dep set for
   you: `cmake ninja pkg-config flex bison cgal gmp mpfr boost eigen harfbuzz
   freetype fontconfig glib double-conversion libzip libxml2 cairo lib3mf tbb`.
3. **The repo with submodules** — the script inits `manifold` + `Clipper2`
   automatically, so a fresh `git clone` is enough.

### Build & test
```sh
git clone -b swift-wrapper git@github.com:pilaski/openscad.git
cd openscad
scripts/macos/build-macos.sh            # brew install + cmake + swift build
cd swift && OPENSCAD_BUILD_DIR=../build-macos swift test
```
First run is slow — the `brew install` of `cgal`/`boost` is the long pole
(~15–30 min). The kernel compile itself is quick and a Mac won't OOM, so no
`-j` throttling is needed.

### Gotchas
- **Apple Silicon vs Intel.** `Package.swift` defaults the Homebrew prefix to
  `/opt/homebrew` (Apple Silicon). On an Intel Mac, set
  `HOMEBREW_PREFIX=/usr/local` in the environment.
- **`libxml2` is keg-only on Homebrew** (not symlinked into
  `$(brew --prefix)/lib`). The macOS SDK ships its own `libxml2`, so `-lxml2`
  usually still resolves. If `swift build` fails with
  `ld: library 'xml2' not found`, add `-L$(brew --prefix libxml2)/lib` to the
  `#if os(macOS)` link flags in `Package.swift`.

## iOS
Cross-compile the kernel + its native deps (CGAL needs GMP/MPFR; route B keeps
the full stack incl. glib/fontconfig/harfbuzz) into an `.xcframework`, consumed
via a SwiftPM binary target. The dependency table, scope decision, and helper
scripts (`scripts/ios/*`) are in **`../docs/IOS_BUILD.md`**. Scope is settled:
**route B — full OpenSCAD feature parity on iOS, no slimming.**

## Remaining tasks
Done so far: headless kernel (CGAL+Manifold), pure-C ABI, Swift facade
(`render`/`renderFile`/`renderMesh`), `scad2stl` CLI, SwiftUI/SceneKit view
layer, macOS build script. 50/50 official examples render on Linux. Still open:

1. **Run the macOS build** (`scripts/macos/build-macos.sh`) on a Mac — this is
   the first time the SceneKit/SwiftUI `OpenSCADKernelUI` code actually compiles
   (it's an empty module on Linux), so it validates the view layer too.
2. **iOS dependency builds** for route-B full parity, then the `.xcframework`
   (see `../docs/IOS_BUILD.md`): GMP/MPFR (`--disable-assembly`), boost, the
   CMake-cross deps, and the hard three — glib, fontconfig, cairo.
3. **Editor UX** — text editor with line numbers and inline parse-error
   surfacing (the kernel already returns precise parse/eval error messages via
   `OpenSCADError`).
4. **App shell** — wire `OpenSCADSourceView` next to the editor with a
   preview/full-resolution toggle backed by `fn`.
