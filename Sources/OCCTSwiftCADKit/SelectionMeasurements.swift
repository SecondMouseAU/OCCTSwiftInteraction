import Foundation
import OCCTSwift
import simd

/// Aggregate measures over a multi-selection (`CADViewportService.selectionMeasurements`).
/// `nil` when the selection is empty: there is nothing to measure.
///
/// Named `SelectionSummary` until OCCTSwiftInteraction#3. `OCCTSwiftUXKit` has an unrelated
/// public `SelectionSummary` of its own (the selection pill's caption and SF Symbol, built from
/// `EntityRef` values, with no OCCT dependency at all), and the two shared nothing but the
/// spelling: no field, no input, no consumer in common. The bakeoff on that issue found nothing
/// to merge, so the collision is resolved by naming, the same way OCCTSwiftViewport's
/// `SelectionFilter` was in phase 1 of ecosystem#43. This is the measurement half; that one is
/// the caption half.
public struct SelectionMeasurements: Sendable, Equatable {
    public let faceCount: Int
    public let edgeCount: Int
    public let vertexCount: Int

    /// Sum of `PickedFaceInfo.area` over every selected face.
    public let totalArea: Double

    /// Sum of `PickedEdgeInfo.length` over every selected edge.
    public let totalLength: Double

    /// Combined axis-aligned bounds of every selected entity (a face/edge's own bounds; a
    /// vertex's position, as a zero-size bounds). `nil` if the selection is empty, or if no
    /// selected entity contributed a bounding box.
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

/// Renamed to `SelectionMeasurements` in OCCTSwiftInteraction#3, to stop colliding by name with
/// the unrelated `OCCTSwiftUXKit.SelectionSummary`.
@available(*, deprecated, renamed: "SelectionMeasurements")
public typealias SelectionSummary = SelectionMeasurements
