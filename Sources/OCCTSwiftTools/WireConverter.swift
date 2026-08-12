// WireConverter.swift
// OCCTSwiftTools
//
// Converts OCCTSwift Wire objects to ViewportBody for rendering.

import OCCTSwift
import OCCTSwiftViewport
import simd

/// Converts OCCTSwift Wire objects to edge-only ViewportBody values.
public enum WireConverter {

    /// Default per-edge point cap for ordered-edge wire extraction.
    public static let defaultMaxPointsPerEdge: Int = 10000

    /// Default linear deflection for the Shape-fallback edge extraction.
    public static let defaultEdgeDeflection: Double = 0.005

    /// Converts a Wire to an edge-only ViewportBody by extracting ordered edge polylines.
    ///
    /// - Parameters:
    ///   - wire: the source `Wire` to convert.
    ///   - id: stable id for the resulting body.
    ///   - color: RGBA color for the body's edges.
    ///   - maxPointsPerEdge: Hard cap on points per edge polyline. Lower it to
    ///     coarsen dense curved edges (e.g. helical threads) that otherwise render as an
    ///     illegible, slow grey haze. Defaults to `defaultMaxPointsPerEdge` (10000).
    ///   - edgeDeflection: Linear deflection used only by the Shape-based fallback
    ///     path (when ordered-edge extraction yields nothing). Defaults to
    ///     `defaultEdgeDeflection` (0.005); coarsen for dense geometry. See issue #24.
    /// - Returns: An edge-only body built from ordered-edge polylines, falling back to
    ///   Shape-based edge extraction if the wire yields no ordered-edge polylines.
    public static func wireToBody(
        _ wire: Wire,
        id: String,
        color: SIMD4<Float>,
        maxPointsPerEdge: Int = defaultMaxPointsPerEdge,
        edgeDeflection: Double = defaultEdgeDeflection
    ) -> ViewportBody {
        let edgeCount = wire.orderedEdgeCount
        var polylines: [[SIMD3<Float>]] = []

        for i in 0..<edgeCount {
            if let pts = wire.orderedEdgePoints(at: i, maxPoints: maxPointsPerEdge) {
                let floatPts = pts.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }
                if floatPts.count >= 2 {
                    polylines.append(floatPts)
                }
            }
        }

        // Fallback: if orderedEdgePoints didn't work, wrap as Shape for edge extraction
        if polylines.isEmpty, let shape = Shape.fromWire(wire) {
            let count = shape.edgeCount
            for i in 0..<count {
                if let pts = shape.edgePolyline(
                    at: i, deflection: edgeDeflection, maxPoints: maxPointsPerEdge
                ) {
                    let floatPts = pts.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }
                    if floatPts.count >= 2 {
                        polylines.append(floatPts)
                    }
                }
            }
        }

        return ViewportBody(
            id: id, vertexData: [], indices: [],
            edges: polylines, color: color
        )
    }
}
