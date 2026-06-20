import COpenSCADKernel
import Foundation

/// Output mesh/format produced by the OpenSCAD kernel.
public enum OpenSCADFormat {
    case binarySTL
    case asciiSTL
    case off
    case obj
    case threeMF

    var raw: OSKFormat {
        switch self {
        case .binarySTL: return OSK_FORMAT_BINSTL
        case .asciiSTL:  return OSK_FORMAT_ASCIISTL
        case .off:       return OSK_FORMAT_OFF
        case .obj:       return OSK_FORMAT_OBJ
        case .threeMF:   return OSK_FORMAT_3MF
        }
    }

    /// File extension inferred for `renderFile` when no explicit format is given.
    var fileExtension: String {
        switch self {
        case .binarySTL, .asciiSTL: return "stl"
        case .off:     return "off"
        case .obj:     return "obj"
        case .threeMF: return "3mf"
        }
    }
}

/// An indexed triangle mesh, ready to feed a 3D view (SceneKit / RealityKit /
/// Metal) with no file round-trip. Buffers use a flat, GPU-friendly layout.
public struct Mesh: Sendable {
    /// Vertex positions, 3 floats (x, y, z) per vertex.
    public let positions: [Float]
    /// Per-vertex unit normals, 3 floats per vertex; `nil` if not requested.
    public let normals: [Float]?
    /// Triangle list: 3 indices into the vertex arrays per triangle.
    public let indices: [UInt32]

    public var vertexCount: Int { positions.count / 3 }
    public var triangleCount: Int { indices.count / 3 }
    public var isEmpty: Bool { indices.isEmpty }
}

/// An error surfaced by the OpenSCAD kernel (parse failure, evaluation error, …).
public struct OpenSCADError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "OpenSCADError(\(code)): \(message)" }
}

/// Swift facade over the real OpenSCAD geometry kernel (headless).
///
/// Wraps the pure-C ABI in `openscad_kernel.h`. The kernel uses global parser
/// state, so renders are serialized internally.
public enum OpenSCAD {
    private static let lock = NSLock()
    private static var didInit = false

    /// Initialize the kernel once (builtins, parser, fonts). Idempotent.
    public static func initialize(applicationPath: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard !didInit else { return }
        if let p = applicationPath {
            p.withCString { osk_init($0) }
        } else {
            osk_init(nil)
        }
        didInit = true
    }

    /// A short identifier for the active backend/version.
    public static var backend: String {
        String(cString: osk_backend())
    }

    /// Render OpenSCAD source to encoded bytes in memory.
    /// - Parameters:
    ///   - source: OpenSCAD program text.
    ///   - format: desired output format (default binary STL).
    ///   - fn: if > 0, forces `$fn` for the whole model.
    public static func render(source: String,
                              format: OpenSCADFormat = .binarySTL,
                              fn: Double = 0) throws -> Data {
        initialize()
        lock.lock(); defer { lock.unlock() }

        var buffer: UnsafeMutablePointer<UInt8>? = nil
        var length: Int = 0
        var errPtr: UnsafeMutablePointer<CChar>? = nil

        let rc = source.withCString { src in
            osk_render_string(src, format.raw, nil, fn, &buffer, &length, &errPtr)
        }
        if rc != 0 {
            let msg = errPtr.map { String(cString: $0) } ?? "render failed"
            osk_string_free(errPtr)
            throw OpenSCADError(code: rc, message: msg)
        }
        defer { osk_buffer_free(buffer) }
        guard let buffer else { return Data() }
        return Data(bytes: buffer, count: length)
    }

    /// Render OpenSCAD source straight to an in-memory triangle mesh — the path
    /// to use for an interactive 3D view (no STL round-trip).
    /// - Parameters:
    ///   - source: OpenSCAD program text.
    ///   - fn: if > 0, forces `$fn` for the whole model; lower it for a fast
    ///         low-resolution preview.
    ///   - normals: compute per-vertex smooth normals (default true).
    public static func renderMesh(source: String,
                                  fn: Double = 0,
                                  normals: Bool = true) throws -> Mesh {
        initialize()
        lock.lock(); defer { lock.unlock() }

        var mesh = OSKMesh()
        var errPtr: UnsafeMutablePointer<CChar>? = nil

        let rc = source.withCString { src in
            osk_render_mesh(src, nil, fn, normals ? 1 : 0, &mesh, &errPtr)
        }
        if rc != 0 {
            let msg = errPtr.map { String(cString: $0) } ?? "render failed"
            osk_string_free(errPtr)
            throw OpenSCADError(code: rc, message: msg)
        }
        defer { osk_mesh_free(&mesh) }

        let vcount = mesh.vertex_count
        let tcount = mesh.triangle_count

        let positions: [Float] = (vcount > 0 && mesh.positions != nil)
            ? Array(UnsafeBufferPointer(start: mesh.positions, count: vcount * 3))
            : []
        let normalArray: [Float]? = (vcount > 0 && mesh.normals != nil)
            ? Array(UnsafeBufferPointer(start: mesh.normals, count: vcount * 3))
            : nil
        let indices: [UInt32] = (tcount > 0 && mesh.indices != nil)
            ? Array(UnsafeBufferPointer(start: mesh.indices, count: tcount * 3))
            : []

        return Mesh(positions: positions, normals: normalArray, indices: indices)
    }

    /// Render an OpenSCAD source file to an output file. Format is inferred from
    /// the output extension unless `format` is supplied.
    public static func renderFile(input: String,
                                  output: String,
                                  format: OpenSCADFormat? = nil,
                                  fn: Double = 0) throws {
        initialize()
        lock.lock(); defer { lock.unlock() }

        var errPtr: UnsafeMutablePointer<CChar>? = nil
        let fmtArg: Int32 = format.map { Int32($0.raw.rawValue) } ?? -1

        let rc = input.withCString { inP in
            output.withCString { outP in
                osk_render_file(inP, outP, fmtArg, fn, &errPtr)
            }
        }
        if rc != 0 {
            let msg = errPtr.map { String(cString: $0) } ?? "render failed"
            osk_string_free(errPtr)
            throw OpenSCADError(code: rc, message: msg)
        }
    }
}
