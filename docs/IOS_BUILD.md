# Building the OpenSCAD kernel for macOS and iOS

This documents Phase 5 of the Swift port: getting the headless kernel +
`OpenSCADKernel` Swift package onto Apple platforms. Everything here runs on a
**Mac with Xcode** — it cannot be done on the Linux build host.

> TL;DR recommendation: **do macOS first** (one script, no cross-compiling),
> get the app running there, *then* climb the iOS dependency mountain.

---

## 0. The dependency reality

OpenSCAD's CMake `REQUIRED`s a large native stack. There is **no built-in slim
build** — all of these must be present for each target:

| Dependency | Kind | macOS (brew) | iOS (cross-compile) |
|---|---|---|---|
| Eigen | header-only | trivial | trivial (copy headers) |
| CGAL | header-only* | trivial | headers only; needs GMP/MPFR/boost at link |
| GMP, MPFR | autotools C | brew | **`scripts/ios/build-ios-deps.sh`** (`--disable-assembly`) |
| Boost (regex, program_options) | C++ | brew | `b2 toolset=darwin architecture=arm` |
| Manifold, Clipper2 | CMake (in-tree) | builds with kernel | builds with kernel via toolchain |
| double-conversion | CMake | brew | CMake-cross |
| Freetype, HarfBuzz | CMake | brew | CMake-cross |
| libxml2, libzip | CMake/autotools | brew | CMake-cross |
| **glib-2.0** | Meson | brew | **hard** — Meson iOS cross file, no system glib |
| **Fontconfig** | autotools | brew | **hard** — Linux/X11 oriented; or replace with CoreText |
| Cairo | Meson | brew | hard (2D export only) |
| TBB | — | optional (`MANIFOLD_PAR=OFF`) | drop (`MANIFOLD_PAR=OFF`) |

\* CGAL is header-only but instantiates GMP/MPFR/boost, so those must link.

The three genuinely painful iOS ports are **glib, fontconfig, cairo**. They are
only needed for `text()` (font shaping/discovery) and 2D vector *export*
(PDF/SVG via cairo). That motivates the scope decision below.

---

## 1. macOS build (do this first)

```sh
scripts/macos/build-macos.sh          # brew deps + cmake + swift build
cd swift
OPENSCAD_BUILD_DIR="$PWD/../build-macos" swift run scad2stl in.scad out.stl --fn 64
swift test
```

The `Package.swift` is already platform-conditional (libc++ + Homebrew prefix on
macOS, libstdc++ + `--start-group` on Linux). Once this runs, the same package
links into a macOS app target unchanged. This is the fastest way to a real
running build of the genuine kernel on Apple hardware.

---

## 2. iOS — scope decision (read before cross-compiling)

Cross-compiling the **full** stack (incl. glib + fontconfig + cairo) is multi-day
work. Two routes:

- **A. Slim iOS core (recommended for v1).** Patch the kernel's CMake to make
  `text()`, mesh `import`, and 2D *export* optional, dropping
  glib/fontconfig/cairo/harfbuzz/freetype/libzip. iOS v1 then needs only
  GMP/MPFR/CGAL/boost/eigen/manifold/clipper2/double-conversion/libxml2 — all
  cross-compilable without the hostile ports. You keep **full 3D CSG incl.
  `minkowski()`** and STL/OFF/OBJ export. (This CMake change is not yet made —
  it's the next task if you choose this route. It can be validated on Linux by
  building with those features off before touching iOS.)
- **B. Full parity.** Cross-compile everything, including glib (Meson iOS cross
  file) and a Fontconfig→CoreText replacement for `FontCache`. Most faithful,
  much slower.

---

## 3. iOS build steps (once deps exist)

```sh
# 3a. Foundation deps (GMP/MPFR) for both slices:
scripts/ios/build-ios-deps.sh
#  -> deps-ios/device, deps-ios/sim

# 3b. The remaining CMake-cross deps + boost go into the SAME per-slice prefix.
#     (See the dependency table; build each with the ios toolchain / b2 and
#      `--prefix=deps-ios/<slice>`.) For route A you can skip the hard ones.

# 3c. Build the kernel per slice against that prefix:
scripts/ios/build-ios-kernel.sh device "$PWD/deps-ios/device"
scripts/ios/build-ios-kernel.sh sim    "$PWD/deps-ios/sim"

# 3d. Bundle into an xcframework:
scripts/ios/make-xcframework.sh
#  -> build-ios/OpenSCADKernel.xcframework
```

The vendored toolchain is `cmake/ios/ios.toolchain.cmake` (leetal/ios-cmake,
BSD-3). `build-ios-kernel.sh` maps device→`OS64`, sim→`SIMULATORARM64`.

---

## 4. Consuming the xcframework from SwiftPM

For an Apple app, swap the Linux/macOS "link the .a's" recipe for a binary
target. Sketch (a separate `Package-ios.swift` or an `#if os(iOS)` branch):

```swift
.binaryTarget(
    name: "OpenSCADKernelBinary",
    path: "build-ios/OpenSCADKernel.xcframework"
),
.target(
    name: "OpenSCADKernel",
    dependencies: ["OpenSCADKernelBinary"],
    linkerSettings: [
        // The xcframework holds the OpenSCAD archives; the cross-compiled
        // third-party deps (gmp/mpfr/boost/...) link from deps-ios prefixes,
        // or are merged into the xcframework's fat lib via libtool in
        // make-xcframework.sh. Add the needed -l / -L here, plus:
        .linkedLibrary("c++"),
    ]
),
```

The Swift facade (`OpenSCADKernel.swift`) and the C ABI header are unchanged
across all platforms — that's the whole point of the stable C boundary.

---

## 5. Status

- [x] iOS CMake toolchain vendored (`cmake/ios/ios.toolchain.cmake`).
- [x] macOS build script (`scripts/macos/build-macos.sh`), `Package.swift`
      made macOS/Linux conditional.
- [x] GMP/MPFR iOS cross-compile script (`scripts/ios/build-ios-deps.sh`).
- [x] Per-slice kernel build + xcframework scripts.
- [ ] **Decision needed:** slim iOS core (route A) vs full parity (route B).
- [ ] Cross-compile the remaining deps for iOS (route-dependent).
- [ ] Build on a Mac, produce the xcframework, link into an iOS app target.
