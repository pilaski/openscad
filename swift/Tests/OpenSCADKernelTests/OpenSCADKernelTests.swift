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
}
