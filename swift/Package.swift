// swift-tools-version:5.9
import PackageDescription

// Absolute path to the CMake build directory holding the prebuilt static libs
// (libopenscad_kernel.a + libopenscadinternal.a + svg/manifold/Clipper2).
// Override with OPENSCAD_BUILD_DIR when building elsewhere.
import Foundation
let buildDir = ProcessInfo.processInfo.environment["OPENSCAD_BUILD_DIR"]
    ?? "/home/claire/.openclaw/workspace/repos/openscad/build"

// The prebuilt OpenSCAD static archives (built by CMake), in dependency order.
let kernelArchives = [
    "\(buildDir)/libopenscad_kernel.a",
    "\(buildDir)/libopenscadinternal.a",
    "\(buildDir)/libsvg.a",
    "\(buildDir)/submodules/manifold/src/libmanifold.a",
    "\(buildDir)/submodules/Clipper2/CPP/libClipper2.a",
]

// System dependencies that the kernel pulls in (same set across platforms,
// just resolved from different prefixes).
let kernelSystemLibs = [
    "-lboost_regex", "-lboost_program_options", "-lboost_container",
    "-lharfbuzz", "-lfontconfig", "-lglib-2.0", "-ldouble-conversion",
    "-lgmpxx", "-lmpfr", "-lgmp", "-lzip", "-lcairo", "-l3MF", "-lfreetype",
    "-ltbb", "-lxml2",
]

#if os(macOS)
// macOS: ld64 has no --start-group (it resolves archives multi-pass anyway).
// System deps come from Homebrew; C++ runtime is libc++.
let brewPrefix = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"]
    ?? "/opt/homebrew"   // Apple-silicon default; Intel brew is /usr/local
var kernelLinkFlags: [String] = ["-L\(buildDir)", "-L\(brewPrefix)/lib"]
kernelLinkFlags += kernelArchives
kernelLinkFlags += kernelSystemLibs
kernelLinkFlags += ["-lc++"]
#else
// Linux: GNU ld; wrap archives in --start-group to resolve circular refs.
var kernelLinkFlags: [String] = ["-L\(buildDir)", "-Xlinker", "--start-group"]
for a in kernelArchives { kernelLinkFlags += ["-Xlinker", a] }
kernelLinkFlags += ["-Xlinker", "--end-group"]
kernelLinkFlags += kernelSystemLibs
kernelLinkFlags += ["-lstdc++", "-lm"]
#endif

let package = Package(
    name: "OpenSCADKernel",
    products: [
        .library(name: "OpenSCADKernel", targets: ["OpenSCADKernel"]),
        .executable(name: "scad2stl", targets: ["scad2stl"]),
    ],
    targets: [
        // C module exposing the openscad_kernel.h ABI + the link recipe.
        .target(
            name: "COpenSCADKernel",
            linkerSettings: [.unsafeFlags(kernelLinkFlags)]
        ),
        // Idiomatic Swift facade.
        .target(
            name: "OpenSCADKernel",
            dependencies: ["COpenSCADKernel"]
        ),
        // Command-line scad -> stl tool.
        .executableTarget(
            name: "scad2stl",
            dependencies: ["OpenSCADKernel"]
        ),
        .testTarget(
            name: "OpenSCADKernelTests",
            dependencies: ["OpenSCADKernel"]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
