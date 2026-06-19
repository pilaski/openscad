import Foundation
import OpenSCADKernel

// scad2stl — render an OpenSCAD file to STL/OFF/OBJ/3MF using the real kernel.
//
//   scad2stl <input.scad> <output.stl> [--fn N] [--ascii]

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: scad2stl <input.scad> <output> [--fn N] [--ascii]
      output format inferred from extension (.stl/.off/.obj/.3mf)
      --fn N   force $fn for the whole model
      --ascii  ASCII STL instead of binary (only for .stl)

    """.utf8))
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { usage() }

let input = args[0]
let output = args[1]
var fn: Double = 0
var ascii = false

var i = 2
while i < args.count {
    switch args[i] {
    case "--fn":
        guard i + 1 < args.count, let v = Double(args[i + 1]) else { usage() }
        fn = v; i += 2
    case "--ascii":
        ascii = true; i += 1
    default:
        FileHandle.standardError.write(Data("unknown argument: \(args[i])\n".utf8))
        usage()
    }
}

OpenSCAD.initialize(applicationPath: CommandLine.arguments.first)
FileHandle.standardError.write(Data("backend: \(OpenSCAD.backend)\n".utf8))

do {
    var format: OpenSCADFormat? = nil
    if output.lowercased().hasSuffix(".stl") {
        format = ascii ? .asciiSTL : .binarySTL
    }
    try OpenSCAD.renderFile(input: input, output: output, format: format, fn: fn)
    FileHandle.standardError.write(Data("wrote \(output)\n".utf8))
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
