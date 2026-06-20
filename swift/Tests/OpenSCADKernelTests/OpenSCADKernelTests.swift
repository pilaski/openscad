import XCTest
@testable import OpenSCADKernel

final class OpenSCADKernelTests: XCTestCase {
    func testBackendReported() {
        OpenSCAD.initialize()
        XCTAssertFalse(OpenSCAD.backend.isEmpty)
    }

    func testRenderDifferenceBinarySTL() throws {
        let src = """
        difference() {
          cube([20,20,10], center=true);
          cylinder(h=12, r=4, center=true, $fn=64);
        }
        """
        let data = try OpenSCAD.render(source: src, format: .binarySTL)
        // Binary STL: 80-byte header + uint32 triangle count + 50 bytes/triangle.
        XCTAssertGreaterThan(data.count, 84)
        let count = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 80, as: UInt32.self) }
        XCTAssertEqual(Int(count), 272, "expected 272 triangles for the reference difference model")
        XCTAssertEqual(data.count, 84 + Int(count) * 50, "binary STL size must match triangle count")
    }

    func testMinkowskiUsesCGAL() throws {
        // minkowski() is a CGAL-only op; proves the full geometry backend works.
        let src = """
        minkowski() {
          cube([10,10,2]);
          cylinder(r=2, h=1, $fn=32);
        }
        """
        let data = try OpenSCAD.render(source: src, format: .binarySTL)
        XCTAssertGreaterThan(data.count, 84)
    }

    func testParseErrorThrows() {
        XCTAssertThrowsError(try OpenSCAD.render(source: "this is not valid scad {{{"))
    }

    func testRenderMeshCube() throws {
        // A cube is 6 quad faces -> 12 triangles, 8 distinct corners.
        let mesh = try OpenSCAD.renderMesh(source: "cube([10,10,10]);")
        XCTAssertEqual(mesh.triangleCount, 12)
        XCTAssertEqual(mesh.vertexCount, 8)
        XCTAssertEqual(mesh.positions.count, 8 * 3)
        XCTAssertEqual(mesh.indices.count, 12 * 3)
        // Every index must address a real vertex.
        XCTAssertTrue(mesh.indices.allSatisfy { $0 < UInt32(mesh.vertexCount) })

        // Normals requested by default: present, unit length, one per vertex.
        let normals = try XCTUnwrap(mesh.normals)
        XCTAssertEqual(normals.count, 8 * 3)
        for i in 0..<mesh.vertexCount {
            let x = normals[3*i], y = normals[3*i+1], z = normals[3*i+2]
            let len = (x*x + y*y + z*z).squareRoot()
            XCTAssertEqual(len, 1.0, accuracy: 1e-4)
        }

        // The cube spans [0,10] on each axis.
        let xs = stride(from: 0, to: mesh.positions.count, by: 3).map { mesh.positions[$0] }
        XCTAssertEqual(xs.min() ?? -1, 0, accuracy: 1e-4)
        XCTAssertEqual(xs.max() ?? -1, 10, accuracy: 1e-4)
    }

    func testRenderMeshWithoutNormals() throws {
        let mesh = try OpenSCAD.renderMesh(source: "sphere(r=5, $fn=16);", normals: false)
        XCTAssertNil(mesh.normals)
        XCTAssertGreaterThan(mesh.triangleCount, 0)
        XCTAssertGreaterThan(mesh.vertexCount, 0)
    }

    func testRenderMeshPreviewResolution() throws {
        // Lower $fn -> fewer triangles. Proves the preview knob reaches the kernel.
        let lo = try OpenSCAD.renderMesh(source: "sphere(r=10);", fn: 12)
        let hi = try OpenSCAD.renderMesh(source: "sphere(r=10);", fn: 64)
        XCTAssertLessThan(lo.triangleCount, hi.triangleCount)
    }
}
