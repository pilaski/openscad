//
//  OpenSCADView.swift — SwiftUI views for displaying OpenSCAD models.
//
//  `OpenSCADMeshView`   : draw an already-rendered `Mesh` with orbit/zoom.
//  `OpenSCADSourceView` : render `.scad` source off the main thread and show
//                         it, with loading + error states. Re-renders whenever
//                         source / fn / normals change (lower fn = fast preview).
//
#if canImport(SceneKit) && canImport(SwiftUI)
import SwiftUI
import SceneKit
import OpenSCADKernel

@available(iOS 14, macOS 11, tvOS 14, *)
public struct OpenSCADMeshView: View {
    private let scene: SCNScene
    private let background: Color

    public init(mesh: Mesh,
                modelColor: OSKColor = .lightGray,
                background: Color = Color(white: 0.12)) {
        self.scene = makeOpenSCADScene(from: mesh, modelColor: modelColor)
        self.background = background
    }

    public var body: some View {
        SceneView(
            scene: scene,
            pointOfView: scene.rootNode.childNode(withName: "camera", recursively: false),
            options: [.allowsCameraControl]
        )
        .background(background)
    }
}

/// Identity of a render request; `.task(id:)` re-runs when any field changes.
private struct RenderKey: Equatable {
    let source: String
    let fn: Double
    let normals: Bool
}

@available(iOS 14, macOS 11, tvOS 14, *)
public struct OpenSCADSourceView: View {
    private let source: String
    private let fn: Double
    private let smoothNormals: Bool
    private let modelColor: OSKColor
    private let background: Color

    @State private var mesh: Mesh?
    @State private var errorMessage: String?
    @State private var isRendering = false

    /// - Parameters:
    ///   - source: OpenSCAD program text.
    ///   - fn: `$fn` override; pass a small value (e.g. 24) for a fast preview,
    ///         0 for full model resolution.
    ///   - smoothNormals: request per-vertex smooth normals (default true).
    public init(source: String,
                fn: Double = 0,
                smoothNormals: Bool = true,
                modelColor: OSKColor = .lightGray,
                background: Color = Color(white: 0.12)) {
        self.source = source
        self.fn = fn
        self.smoothNormals = smoothNormals
        self.modelColor = modelColor
        self.background = background
    }

    public var body: some View {
        ZStack {
            if let mesh {
                OpenSCADMeshView(mesh: mesh, modelColor: modelColor, background: background)
            } else {
                background
            }

            if isRendering {
                ProgressView()
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.85))
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .task(id: RenderKey(source: source, fn: fn, normals: smoothNormals)) {
            await render()
        }
    }

    private func render() async {
        isRendering = true
        defer { isRendering = false }

        let src = source, fn = self.fn, normals = smoothNormals
        do {
            let rendered = try await Task.detached(priority: .userInitiated) {
                try OpenSCAD.renderMesh(source: src, fn: fn, normals: normals)
            }.value
            if Task.isCancelled { return }   // a newer edit superseded this one
            mesh = rendered
            errorMessage = nil
        } catch is CancellationError {
            // superseded; keep showing the previous mesh
        } catch {
            errorMessage = "\(error)"
        }
    }
}
#endif
