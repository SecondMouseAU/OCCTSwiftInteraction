// CurveConverter.swift
// OCCTSwiftTools
//
// Converts OCCTSwift Curve2D/Curve3D objects to ViewportBody for rendering.

import OCCTSwift
import OCCTSwiftViewport
import simd

/// Converts OCCTSwift curve objects to edge-only ViewportBody values.
public enum CurveConverter {

    /// Converts a Curve2D to an edge-only ViewportBody projected onto the XZ ground plane (Y=0).
    public static func curve2DToBody(
        _ curve: Curve2D,
        id: String,
        color: SIMD4<Float>
    ) -> ViewportBody {
        let points2D = curve.drawAdaptive()
        let polyline: [SIMD3<Float>] = points2D.map {
            SIMD3<Float>(Float($0.x), 0, Float($0.y))
        }
        return ViewportBody(
            id: id, vertexData: [], indices: [],
            edges: [polyline], color: color
        )
    }

    /// Converts a Curve3D to an edge-only ViewportBody in 3D space.
    public static func curve3DToBody(
        _ curve: Curve3D,
        id: String,
        color: SIMD4<Float>
    ) -> ViewportBody {
        let points3D = curve.drawAdaptive()
        let polyline: [SIMD3<Float>] = points3D.map {
            SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z))
        }
        return ViewportBody(
            id: id, vertexData: [], indices: [],
            edges: [polyline], color: color
        )
    }
}
