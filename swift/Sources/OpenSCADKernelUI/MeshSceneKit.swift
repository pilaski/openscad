//
//  MeshSceneKit.swift — turn an OpenSCAD `Mesh` into SceneKit geometry/scene.
//
//  Apple platforms only; the whole file is gated on SceneKit so the target
//  compiles to an empty module on Linux (and CI there stays green).
//
#if canImport(SceneKit)
import Foundation
import SceneKit
import OpenSCADKernel

#if canImport(UIKit)
import UIKit
public typealias OSKColor = UIColor
private typealias OSKFloat = Float          // iOS SCNVector3 components are Float
#elseif canImport(AppKit)
import AppKit
public typealias OSKColor = NSColor
private typealias OSKFloat = CGFloat         // macOS SCNVector3 components are CGFloat
#endif

@inline(__always)
private func v3(_ x: Float, _ y: Float, _ z: Float) -> SCNVector3 {
    SCNVector3(OSKFloat(x), OSKFloat(y), OSKFloat(z))
}

public extension Mesh {

    /// Build an `SCNGeometry` directly from the flat buffers — no copy into
    /// SceneKit's own vertex types, the `Data` wraps the arrays as-is.
    /// Returns `nil` for an empty mesh.
    func makeSCNGeometry(color: OSKColor = .lightGray) -> SCNGeometry? {
        guard !isEmpty, vertexCount > 0 else { return nil }

        let stride = MemoryLayout<Float>.size * 3
        let positionData = positions.withUnsafeBytes { Data($0) }
        let vertexSource = SCNGeometrySource(
            data: positionData,
            semantic: .vertex,
            vectorCount: vertexCount,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: stride
        )

        var sources = [vertexSource]
        if let normals, normals.count == vertexCount * 3 {
            let normalData = normals.withUnsafeBytes { Data($0) }
            sources.append(SCNGeometrySource(
                data: normalData,
                semantic: .normal,
                vectorCount: vertexCount,
                usesFloatComponents: true,
                componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: stride
            ))
        }

        let indexData = indices.withUnsafeBytes { Data($0) }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: triangleCount,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let geometry = SCNGeometry(sources: sources, elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .blinn
        material.diffuse.contents = color
        material.isDoubleSided = true   // tolerate inconsistent winding from CSG
        geometry.materials = [material]
        return geometry
    }

    /// Axis-aligned bounding box of the model (OpenSCAD/Z-up space).
    /// Returns `nil` if the mesh has no vertices.
    func boundingBox() -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard vertexCount > 0 else { return nil }
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for i in 0..<vertexCount {
            let p = SIMD3<Float>(positions[3*i], positions[3*i+1], positions[3*i+2])
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        return (lo, hi)
    }
}

/// Build a ready-to-display `SCNScene`: the model (rotated Z-up → SceneKit's
/// Y-up), framing camera (named "camera"), and lights.
public func makeOpenSCADScene(from mesh: Mesh,
                              modelColor: OSKColor = .lightGray) -> SCNScene {
    let scene = SCNScene()

    // Z-up (OpenSCAD) -> Y-up (SceneKit): rotate the model -90° about X.
    let modelNode = SCNNode()
    modelNode.geometry = mesh.makeSCNGeometry(color: modelColor)
    modelNode.eulerAngles = v3(-.pi / 2, 0, 0)
    scene.rootNode.addChildNode(modelNode)

    // Frame the camera around the model's bounding sphere.
    let bbox = mesh.boundingBox() ?? (SIMD3<Float>(repeating: -1), SIMD3<Float>(repeating: 1))
    let centerModel = (bbox.min + bbox.max) * 0.5
    let radius = max(simd_length((bbox.max - bbox.min) * 0.5), 0.001)

    // Same -90°-about-X mapping applied to the center: (x, z, -y).
    let worldCenter = v3(centerModel.x, centerModel.z, -centerModel.y)

    let camera = SCNCamera()
    let fovDeg: Float = 50
    camera.fieldOfView = CGFloat(fovDeg)
    let dist = radius / sin(fovDeg * .pi / 180 / 2) * 1.3
    camera.zNear = Double(max(0.01, dist - radius * 2))
    camera.zFar = Double(dist + radius * 4)

    let cameraNode = SCNNode()
    cameraNode.name = "camera"
    cameraNode.camera = camera
    cameraNode.position = v3(Float(worldCenter.x),
                             Float(worldCenter.y),
                             Float(worldCenter.z) + dist)
    cameraNode.look(at: worldCenter)
    scene.rootNode.addChildNode(cameraNode)

    // Key light rides with the camera; soft ambient fill.
    let keyLight = SCNLight()
    keyLight.type = .omni
    cameraNode.addChildNode({ let n = SCNNode(); n.light = keyLight; return n }())

    let ambient = SCNLight()
    ambient.type = .ambient
    ambient.intensity = 250
    let ambientNode = SCNNode()
    ambientNode.light = ambient
    scene.rootNode.addChildNode(ambientNode)

    return scene
}
#endif
