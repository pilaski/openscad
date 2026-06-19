// swift-tools-version:5.9
import PackageDescription

// Absolute path to the CMake build directory holding the prebuilt static libs
// (libopenscad_kernel.a + libopenscadinternal.a + svg/manifold/Clipper2).
// Override with OPENSCAD_BUILD_DIR when building elsewhere.
import Foundation
let buildDir = ProcessInfo.processInfo.environment["OPENSCAD_BUILD_DIR"]
    ?? "/home/claire/.openclaw/workspace/repos/openscad/build"

// Link the real OpenSCAD kernel. Archives are wrapped in --start-group/--end-group
// to resolve the circular references between the kernel, svg, manifold and Clipper2.
let kernelLinkFlags: [String] = [
    "-L\(buildDir)",
    "-Xlinker", "--start-group",
    "-Xlinker", "\(buildDir)/libopenscad_kernel.a",
    "-Xlinker", "\(buildDir)/libopenscadinternal.a",
    "-Xlinker", "\(buildDir)/libsvg.a",
    "-Xlinker", "\(buildDir)/submodules/manifold/src/libmanifold.a",
    "-Xlinker", "\(buildDir)/submodules/Clipper2/CPP/libClipper2.a",
    "-Xlinker", "--end-group",
    // System libraries (from the CMake link line).
    "-lboost_regex", "-lboost_program_options", "-lboost_container",
    "-lharfbuzz", "-lfontconfig", "-lglib-2.0", "-ldouble-conversion",
    "-lgmpxx", "-lmpfr", "-lgmp", "-lzip", "-lcairo", "-l3MF", "-lfreetype",
    "-ltbb", "-lxml2",
    "-lstdc++", "-lm",
]

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
