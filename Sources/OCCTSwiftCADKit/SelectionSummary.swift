import Foundation
import OCCTSwift
import simd

/// Aggregate measures over a multi-selection (`CADViewportService.selection`). `nil` when
/// the selection is empty: there's nothing to summarize.
public struct SelectionSummary: Sendable, Equatable {
    public let faceCount: Int
    public let edgeCount: Int
    public let vertexCount: Int

    /// Sum of `PickedFaceInfo.area` over every selected face.
    public let totalArea: Double

    /// Sum of `PickedEdgeInfo.length` over every selected edge.
    public let totalLength: Double

    /// Combined axis-aligned bounds of every selected entity (a face/edge's own bounds; a
    /// vertex's position, as a zero-size bounds). `nil` only if the selection is empty.
    public let bounds: CADViewportService.ShapeBounds?

    public init(
        faceCount: Int,
        edgeCount: Int,
        vertexCount: Int,
        totalArea: Double,
        totalLength: Double,
        bounds: CADViewportService.ShapeBounds?
    ) {
        self.faceCount = faceCount
        self.edgeCount = edgeCount
        self.vertexCount = vertexCount
        self.totalArea = totalArea
        self.totalLength = totalLength
        self.bounds = bounds
    }
}
