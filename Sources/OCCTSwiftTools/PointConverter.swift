// PointConverter.swift
// OCCTSwiftTools
//
// Converts a raw point cloud (`[SIMD3<Float>]`) to a point-only `ViewportBody`
// for rendering. Sibling to `CurveConverter` / `SurfaceConverter` /
// `WireConverter`; keeps the "given X domain object, produce a ViewportBody"
// layering consistent.
//
// The body produced has empty `vertexData` / `indices` / `edges`, its
// `vertices` carry the cloud points, and `primitiveKind == .point` so the
// renderer dispatches to the point-cloud pipeline added in OCCTSwiftViewport
// v1.0.2 (issue #28). Per-point colours and the world-space point radius
// flow through `vertexColors` and `pointRadius`.

import OCCTSwiftViewport
import simd

/// Converts raw point clouds to point-only `ViewportBody` values.
public enum PointConverter {

    /// Build a `ViewportBody` whose `vertices` carry the input point cloud,
    /// rendered as point sprites by OCCTSwiftViewport's point-cloud pipeline.
    ///
    /// - Parameters:
    ///   - points: point positions, in viewport-space coordinates.
    ///   - id: stable id for the body.
    ///   - color: fallback colour applied to every point when
    ///     `perPointColors` is nil. RGBA, defaults to a soft amber.
    ///   - pointRadius: world-space radius for each point sprite. The
    ///     renderer projects this to screen-space pixels and clamps to
    ///     `[1, 64]` px (Apple's `[[point_size]]` upper bound).
    ///   - perPointColors: optional per-point colours. Must match
    ///     `points.count` when non-nil. Stored on the body's `vertexColors`
    ///     and sampled by the renderer when populated; otherwise every
    ///     point uses `color`.
    /// - Returns: The point-cloud body, or `nil` if `perPointColors` is non-nil and its length
    ///   doesn't match `points.count`. Empty input is valid and returns an empty body, useful for
    ///   clearing a prior point set without removing the body itself.
    public static func pointsToBody(
        _ points: [SIMD3<Float>],
        id: String,
        color: SIMD4<Float> = SIMD4<Float>(1.0, 0.85, 0.2, 1.0),
        pointRadius: Float = 0.05,
        perPointColors: [SIMD4<Float>]? = nil
    ) -> ViewportBody? {
        if let perPointColors, perPointColors.count != points.count {
            return nil
        }
        return ViewportBody(
            id: id,
            vertexData: [],
            indices: [],
            edges: [],
            vertices: points,
            vertexColors: perPointColors ?? [],
            color: color,
            pointRadius: pointRadius,
            primitiveKind: .point
        )
    }
}
