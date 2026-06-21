// swift-tools-version:5.9
import PackageDescription

// Absolute path to the CMake build directory holding the prebuilt static libs
// (libopenscad_kernel.a + libopenscadinternal.a + svg/manifold/Clipper2).
// Override with OPENSCAD_BUILD_DIR when building elsewhere.
import Foundation

// Default build dir resolves relative to this manifest so a bare `swift build`
// works without OPENSCAD_BUILD_DIR: <repo>/build-macos on macOS, <repo>/build
// on Linux. Override with OPENSCAD_BUILD_DIR to point elsewhere.
let repoRoot = URL(fileURLWithPath: #filePath)   // <repo>/swift/Package.swift
    .deletingLastPathComponent()                  // <repo>/swift
    .deletingLastPathComponent()                  // <repo>
#if os(macOS)
let defaultBuildDir = repoRoot.appendingPathComponent("build-macos").path
#else
let defaultBuildDir = repoRoot.appendingPathComponent("build").path
#endif
let buildDir = ProcessInfo.processInfo.environment["OPENSCAD_BUILD_DIR"] ?? defaultBuildDir

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
    "-lgmpxx", "-lmpfr", "-lgmp", "-lzip", "-lcairo", "-lfreetype",
    "-ltbb", "-lxml2",
    // NOTE: -l3MF is platform-conditional below. The Linux host builds the
    // kernel against real lib3mf; macOS uses OpenSCAD's dummy 3MF stubs (lib3mf
    // is not in core Homebrew), so there is no lib3MF to link there.
]

#if os(macOS)
// macOS: ld64 has no --start-group (it resolves archives multi-pass anyway).
// System deps come from Homebrew; C++ runtime is libc++.
let brewPrefix = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"]
    ?? "/opt/homebrew"   // Apple-silicon default; Intel brew is /usr/local
// gettext is keg-only on Homebrew; -lintl lives under opt/gettext, not lib.
// (Linux glibc bundles libintl, so it only needs linking on macOS.)
var kernelLinkFlags: [String] = [
    "-L\(buildDir)", "-L\(brewPrefix)/lib", "-L\(brewPrefix)/opt/gettext/lib",
]
kernelLinkFlags += kernelArchives
kernelLinkFlags += kernelSystemLibs
kernelLinkFlags += ["-lintl"]
kernelLinkFlags += ["-lc++"]
#else
// Linux: GNU ld; wrap archives in --start-group to resolve circular refs.
var kernelLinkFlags: [String] = ["-L\(buildDir)", "-Xlinker", "--start-group"]
for a in kernelArchives { kernelLinkFlags += ["-Xlinker", a] }
kernelLinkFlags += ["-Xlinker", "--end-group"]
kernelLinkFlags += kernelSystemLibs
kernelLinkFlags += ["-l3MF"]   // Linux kernel links real lib3mf (apt)
kernelLinkFlags += ["-lstdc++", "-lm"]
#endif

let package = Package(
    name: "OpenSCADKernel",
    platforms: [
        .macOS(.v11), .iOS(.v14), .tvOS(.v14),
    ],
    products: [
        .library(name: "OpenSCADKernel", targets: ["OpenSCADKernel"]),
        // SwiftUI/SceneKit views (Apple platforms; empty module elsewhere).
        .library(name: "OpenSCADKernelUI", targets: ["OpenSCADKernelUI"]),
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
        // SwiftUI + SceneKit view layer. Source is gated on canImport(SceneKit),
        // so this compiles to an empty module on Linux.
        .target(
            name: "OpenSCADKernelUI",
            dependencies: ["OpenSCADKernel"]
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
