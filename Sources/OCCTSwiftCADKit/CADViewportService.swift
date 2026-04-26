import Foundation
import SwiftUI
import simd
import OCCTSwift
import OCCTSwiftViewport
import OCCTSwiftTools

/// Manages a loaded B-Rep `Shape`, drives the Metal viewport, and routes
/// face-picking results back to the caller.
///
/// Use `loadFile(from:)`/`loadShape(_:id:)`/`loadFromData(_:filename:)` to
/// import geometry. Caller-supplied geometry like stock boxes, toolpaths, or
/// flat-pattern outlines is staged via the `setOverlay(id:bodies:)` API; the
/// service composites them with the model bodies and any selection highlight
/// every time it rebuilds the viewport's body list.
@MainActor
@Observable
public final class CADViewportService {
    /// Viewport controller — exposes camera, display mode, picking config,
    /// etc. Construct with custom configuration via `init(configuration:)`.
    public let controller: _ViewportController

    /// All bodies currently displayed in the viewport. Composed of: model
    /// bodies (from imported file) + overlay layers (caller-managed) +
    /// selection highlight (managed internally on pick).
    public private(set) var bodies: [_ViewportBody] = []

    /// The loaded OCCTSwift shape. `nil` until something is loaded.
    public private(set) var loadedShape: OCCTSwift.Shape?

    /// Currently selected face. `nil` if nothing is picked.
    public private(set) var selectedFace: PickedFaceInfo?

    private var modelBodies: [_ViewportBody] = []
    private var metadata: [String: CADBodyMetadata] = [:]
    private var overlays: [String: [_ViewportBody]] = [:]
    private var selectionBody: _ViewportBody?

    public init(configuration: _ViewportConfiguration = .init(
        rotationStyle: .turntable,
        displayMode: .shadedWithEdges,
        lightingConfiguration: .threePoint,
        showViewCube: true,
        showAxes: true,
        showGrid: true,
        pickingConfiguration: _PickingConfiguration(isEnabled: true)
    )) {
        self.controller = _ViewportController(configuration: configuration)
        self.controller.onPick = { [weak self] result in
            Task { @MainActor in
                self?.handlePick(result)
            }
        }
    }

    // MARK: - File Import

    /// Load a CAD file (STEP/.stp, STL, BREP) from disk into the viewport.
    /// Returns the loaded `Shape`. Camera is automatically focused on the
    /// shape's bounding box.
    @discardableResult
    public func loadFile(from url: URL) async throws -> OCCTSwift.Shape {
        let ext = url.pathExtension.lowercased()
        let format: CADFileFormat
        switch ext {
        case "step", "stp": format = .step
        case "stl": format = .stl
        case "brep": format = .brep
        default: throw CADViewportError.unsupportedFormat(ext)
        }

        let result = try await CADFileLoader.load(from: url, format: format)
        guard let firstShape = result.shapes.first else {
            throw CADViewportError.emptyFile
        }

        self.loadedShape = firstShape
        self.modelBodies = result.bodies
        self.metadata = result.metadata
        clearSelection()
        rebuildBodies()
        focusOnLoadedShape()
        return firstShape
    }

    /// Display an in-memory shape (e.g. one constructed programmatically via
    /// OCCTSwift) without going through the file loader.
    public func loadShape(_ shape: OCCTSwift.Shape, id: String = "model") {
        self.loadedShape = shape
        let (body, meta) = CADFileLoader.shapeToBodyAndMetadata(
            shape,
            id: id,
            color: SIMD4<Float>(0.7, 0.7, 0.75, 1.0)
        )
        if let body {
            self.modelBodies = [body]
        }
        if let meta {
            self.metadata[id] = meta
        }
        clearSelection()
        rebuildBodies()
        focusOnLoadedShape()
    }

    /// Convenience for callers that have file `Data` rather than a URL
    /// (e.g. `.fileImporter` results, drag-and-drop on iOS).
    @discardableResult
    public func loadFromData(_ data: Data, filename: String) async throws -> OCCTSwift.Shape {
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent(filename)
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        return try await loadFile(from: tempURL)
    }

    private func focusOnLoadedShape() {
        guard let shape = loadedShape else { return }
        let b = shape.bounds
        let center = SIMD3<Float>(
            Float((b.min.x + b.max.x) / 2),
            Float((b.min.y + b.max.y) / 2),
            Float((b.min.z + b.max.z) / 2)
        )
        let maxDim = Float(max(b.max.x - b.min.x, max(b.max.y - b.min.y, b.max.z - b.min.z)))
        controller.focusOn(point: center, distance: maxDim * 2.5)
    }

    // MARK: - Shape Info

    public struct ShapeBounds: Sendable, Equatable {
        public let minX: Double, minY: Double, minZ: Double
        public let maxX: Double, maxY: Double, maxZ: Double
        public var sizeX: Double { maxX - minX }
        public var sizeY: Double { maxY - minY }
        public var sizeZ: Double { maxZ - minZ }
    }

    public var shapeBounds: ShapeBounds? {
        guard let shape = loadedShape else { return nil }
        let b = shape.bounds
        return ShapeBounds(
            minX: b.min.x, minY: b.min.y, minZ: b.min.z,
            maxX: b.max.x, maxY: b.max.y, maxZ: b.max.z
        )
    }

    // MARK: - Overlay Layers

    /// Add or replace a named overlay layer. The bodies are composited with
    /// the model + selection highlight on every viewport rebuild. Use this
    /// for stock boxes, toolpath polylines, flat-pattern outlines, bend
    /// strips, custom annotations — anything that isn't part of the imported
    /// model.
    public func setOverlay(id: String, bodies: [_ViewportBody]) {
        overlays[id] = bodies
        rebuildBodies()
    }

    /// Remove a named overlay layer.
    public func clearOverlay(id: String) {
        overlays.removeValue(forKey: id)
        rebuildBodies()
    }

    /// Remove every overlay layer. Model bodies and selection are unaffected.
    public func clearAllOverlays() {
        overlays.removeAll()
        rebuildBodies()
    }

    /// Sorted list of overlay layer ids currently in the viewport.
    public var overlayIDs: [String] { overlays.keys.sorted() }

    // MARK: - Face Selection

    /// Clear the current face selection (and any highlight body).
    public func clearSelection() {
        selectedFace = nil
        selectionBody = nil
        rebuildBodies()
    }

    private func handlePick(_ result: _PickResult?) {
        guard let result = result else {
            clearSelection()
            return
        }

        guard let meta = metadata[result.bodyID] else {
            clearSelection()
            return
        }

        let triIndex = result.triangleIndex
        guard triIndex >= 0 && triIndex < meta.faceIndices.count else {
            clearSelection()
            return
        }

        let faceIndex = Int(meta.faceIndices[triIndex])

        guard let shape = loadedShape else { return }
        let faces = shape.faces()
        guard faceIndex >= 0 && faceIndex < faces.count else { return }
        let face = faces[faceIndex]

        let isHoriz = face.isHorizontal()
        let isVert = face.isVertical()
        let faceBounds = face.bounds
        let faceArea = face.area()
        let zLevel = face.zLevel.map { Float($0) }

        let bounds = FaceBounds(
            minX: Float(faceBounds.min.x),
            maxX: Float(faceBounds.max.x),
            minY: Float(faceBounds.min.y),
            maxY: Float(faceBounds.max.y)
        )

        let typeStr = isHoriz ? "Horizontal" : (isVert ? "Vertical" : "Angled")
        let sizeStr = String(format: "%.1fx%.1f", bounds.width, bounds.height)
        let zStr = zLevel.map { String(format: " at Z=%.1f", $0) } ?? ""
        let desc = "\(typeStr) face\(zStr), \(sizeStr)mm"

        selectedFace = PickedFaceInfo(
            faceIndex: faceIndex,
            bodyID: result.bodyID,
            isHorizontal: isHoriz,
            isVertical: isVert,
            bounds: bounds,
            zLevel: zLevel,
            area: faceArea,
            description: desc
        )

        buildSelectionHighlight(bodyID: result.bodyID, faceIndex: Int32(faceIndex))
    }

    private func buildSelectionHighlight(bodyID: String, faceIndex: Int32) {
        guard let body = modelBodies.first(where: { $0.id == bodyID }),
              let meta = metadata[bodyID] else {
            selectionBody = nil
            rebuildBodies()
            return
        }

        let stride = 6 // interleaved [px,py,pz,nx,ny,nz]
        var highlightVerts: [Float] = []
        var highlightIndices: [UInt32] = []
        var vertCount: UInt32 = 0

        let triCount = body.indices.count / 3
        for tri in 0..<triCount {
            guard tri < meta.faceIndices.count && meta.faceIndices[tri] == faceIndex else { continue }

            let i0 = Int(body.indices[tri * 3])
            let i1 = Int(body.indices[tri * 3 + 1])
            let i2 = Int(body.indices[tri * 3 + 2])

            for idx in [i0, i1, i2] {
                let base = idx * stride
                guard base + stride <= body.vertexData.count else { continue }
                highlightVerts.append(contentsOf: body.vertexData[base..<(base + stride)])
                highlightIndices.append(vertCount)
                vertCount += 1
            }
        }

        guard !highlightIndices.isEmpty else {
            selectionBody = nil
            rebuildBodies()
            return
        }

        selectionBody = _ViewportBody(
            id: "selection_highlight",
            vertexData: highlightVerts,
            indices: highlightIndices,
            edges: [],
            color: SIMD4<Float>(1.0, 0.9, 0.0, 0.5)
        )
        rebuildBodies()
    }

    // MARK: - Private

    private func rebuildBodies() {
        var all: [_ViewportBody] = []
        all.append(contentsOf: modelBodies)
        for key in overlays.keys.sorted() {
            all.append(contentsOf: overlays[key] ?? [])
        }
        if let sel = selectionBody { all.append(sel) }
        self.bodies = all
    }
}
