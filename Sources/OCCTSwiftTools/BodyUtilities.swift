// BodyUtilities.swift
// OCCTSwiftTools
//
// Utility functions for creating and transforming ViewportBody values.

import OCCTSwiftViewport
import simd

/// Utility functions for creating and transforming ViewportBody values.
public enum BodyUtilities {

    /// Creates a small sphere marker at a given 3D position.
    /// - Parameters:
    ///   - position: Center position of the marker sphere.
    ///   - radius: Radius of the sphere.
    ///   - id: Body identifier.
    ///   - color: RGBA color.
    ///   - segments: Number of longitudinal segments (default 8).
    ///   - rings: Number of latitudinal rings (default 4).
    /// - Returns: A sphere `ViewportBody` centered at `position`.
    public static func makeMarkerSphere(
        at position: SIMD3<Float>,
        radius: Float,
        id: String,
        color: SIMD4<Float>,
        segments: Int = 8,
        rings: Int = 4
    ) -> ViewportBody {
        var sphere = ViewportBody.sphere(
            id: id, radius: radius, segments: segments, rings: rings, color: color
        )
        let stride = 6
        var verts: [Float] = []
        verts.reserveCapacity(sphere.vertexData.count)
        for i in Swift.stride(from: 0, to: sphere.vertexData.count, by: stride) {
            verts.append(sphere.vertexData[i] + position.x)
            verts.append(sphere.vertexData[i + 1] + position.y)
            verts.append(sphere.vertexData[i + 2] + position.z)
            verts.append(sphere.vertexData[i + 3])
            verts.append(sphere.vertexData[i + 4])
            verts.append(sphere.vertexData[i + 5])
        }
        sphere.vertexData = verts
        return sphere
    }

    /// Returns a new ViewportBody with all vertices and edges offset by (dx, dy, dz).
    public static func offsetBody(
        _ body: ViewportBody,
        dx: Float,
        dy: Float = 0,
        dz: Float = 0
    ) -> ViewportBody {
        var result = body
        let stride = 6
        var verts: [Float] = []
        verts.reserveCapacity(result.vertexData.count)
        for i in Swift.stride(from: 0, to: result.vertexData.count, by: stride) {
            verts.append(result.vertexData[i] + dx)
            verts.append(result.vertexData[i + 1] + dy)
            verts.append(result.vertexData[i + 2] + dz)
            verts.append(result.vertexData[i + 3])
            verts.append(result.vertexData[i + 4])
            verts.append(result.vertexData[i + 5])
        }
        result.vertexData = verts
        result.edges = result.edges.map { polyline in
            polyline.map { p in SIMD3(p.x + dx, p.y + dy, p.z + dz) }
        }
        return result
    }

    /// Offsets a ViewportBody's vertices and edges in place by (dx, dy, dz).
    public static func offsetBody(
        _ body: inout ViewportBody,
        dx: Float,
        dy: Float = 0,
        dz: Float = 0
    ) {
        body = offsetBody(body, dx: dx, dy: dy, dz: dz)
    }
}
