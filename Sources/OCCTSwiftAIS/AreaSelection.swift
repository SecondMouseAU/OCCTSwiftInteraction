import Foundation
import OCCTSwift
import OCCTSwiftViewport
import simd

/// How a rectangle/lasso area selection decides whether a candidate sub-shape
/// counts as "inside" the region.
public enum AreaSelectionMode: Sendable {
    /// Every one of the candidate's representative screen-space points must
    /// fall inside the region.
    case enclosed
    /// At least one of the candidate's representative points falls inside the
    /// region.
    case intersecting
}

/// How an area selection combines with the existing `Selection`.
///
/// Mirrors OCCT's `AIS_SelectionScheme`.
public enum SelectionScheme: Sendable {
    case replace
    case add
    case remove
    case xor
}

extension InteractiveContext {

    /// Select every candidate sub-shape (honouring `selectionMode` and
    /// installed `filters`, same as a point pick) whose screen-space
    /// projection falls inside the rectangle spanned by `from`/`to`.
    ///
    /// **Implementation note: a departure from a GPU-pixel-scan approach.**
    /// OCCTSwiftViewport's GPU pick path only resolves one screen pixel at a
    /// time (`ViewportRenderer.performPick(at:completion:)`); there is no
    /// batch/region readback of the pick texture to build on, and the pick
    /// texture itself is GPU-private (not CPU-readable), so a "GPU-based
    /// `.intersecting`" implementation isn't available without a new
    /// OCCTSwiftViewport-side API. This projects each candidate's own
    /// vertices into screen space via the existing public
    /// `ProjectionUtility.worldToScreen(point:vpMatrix:viewportSize:)` instead
    /// (CPU-side, vertex-based). Two consequences, both worth knowing:
    ///
    /// - **No occlusion handling.** A sub-shape hidden behind another one can
    ///   still be selected if its projected vertices land in the region; this
    ///   is not "what you can see," unlike a GPU-pixel read would be.
    /// - **Vertex-only approximation.** Enclosure/intersection is tested
    ///   against each candidate's *vertices*, not its full rasterized
    ///   silhouette. A large, curved, or planar face whose vertices all sit
    ///   outside the region, while the region itself sits entirely inside the
    ///   face's interior, will not be detected as intersecting. Curved edges
    ///   are approximated by their endpoints only.
    ///
    /// - Parameters:
    ///   - from: One screen-space corner of the rectangle (view-local
    ///     coordinates: top-left origin, same convention `worldToScreen`
    ///     produces and `DragGesture`'s locations use).
    ///   - to: The opposite corner.
    ///   - mode: `.enclosed` or `.intersecting`.
    ///   - scheme: How the matched set combines with the current `selection`.
    ///   - viewportSize: The current view's size, for NDC → screen conversion.
    public func selectRectangle(
        from: CGPoint,
        to: CGPoint,
        mode: AreaSelectionMode = .enclosed,
        scheme: SelectionScheme = .replace,
        viewportSize: CGSize
    ) {
        let rect = CGRect(
            x: Swift.min(from.x, to.x), y: Swift.min(from.y, to.y),
            width: abs(to.x - from.x), height: abs(to.y - from.y)
        )
        applyAreaSelection(scheme: scheme, viewportSize: viewportSize) { points in
            AreaSelectionGeometry.matches(points, rect: rect, mode: mode)
        }
    }

    /// Select every candidate sub-shape whose screen-space projection falls
    /// inside the freeform polygon through `points` (implicitly closed).
    ///
    /// See `selectRectangle(from:to:mode:scheme:viewportSize:)` for the
    /// implementation notes and limitations shared by both.
    public func selectPolygon(
        _ points: [CGPoint],
        mode: AreaSelectionMode = .enclosed,
        scheme: SelectionScheme = .replace,
        viewportSize: CGSize
    ) {
        guard points.count >= 3 else { return }
        applyAreaSelection(scheme: scheme, viewportSize: viewportSize) { candidatePoints in
            AreaSelectionGeometry.matches(candidatePoints, polygon: points, mode: mode)
        }
    }

    private func applyAreaSelection(
        scheme: SelectionScheme,
        viewportSize: CGSize,
        test: ([CGPoint]) -> Bool
    ) {
        let camera = viewport.cameraState
        let vpMatrix =
            camera.projectionMatrix(aspectRatio: viewport.lastAspectRatio) * camera.viewMatrix

        var matched: Set<SubShape> = []
        for object in displayedObjects() {
            guard isVisible(object) else { continue }

            // A shape whose bounding box is void has no screen-space
            // projection to test, so it is simply not a candidate: same
            // treatment as a sub-shape whose identity table is missing below.
            if selectionMode.contains(.body), let bounds = object.shape.bounds {
                let corners = boundingBoxCorners(lo: bounds.min, hi: bounds.max)
                let points = project(corners, vpMatrix: vpMatrix, viewportSize: viewportSize)
                let candidate = SubShape.body(object)
                if test(points), passesInstalledFilters(candidate) {
                    matched.insert(candidate)
                }
            }

            if selectionMode.contains(.face), let table = faceIdentityTable(for: object) {
                for ordinal in 0..<table.shapes.count {
                    guard let shape = table.shape(forOrdinal: ordinal) else { continue }
                    let points = project(
                        shape.vertices(), vpMatrix: vpMatrix, viewportSize: viewportSize)
                    let uid = table.uid(forOrdinal: ordinal)
                    let candidate = SubShape.face(
                        object, ref: SubShapeRef(shape: shape, uid: uid, ordinal: ordinal))
                    if test(points), passesInstalledFilters(candidate) {
                        matched.insert(candidate)
                    }
                }
            }

            if selectionMode.contains(.edge), let table = edgeIdentityTable(for: object) {
                for ordinal in 0..<table.shapes.count {
                    guard let shape = table.shape(forOrdinal: ordinal) else { continue }
                    let points = project(
                        shape.vertices(), vpMatrix: vpMatrix, viewportSize: viewportSize)
                    let uid = table.uid(forOrdinal: ordinal)
                    let candidate = SubShape.edge(
                        object, ref: SubShapeRef(shape: shape, uid: uid, ordinal: ordinal))
                    if test(points), passesInstalledFilters(candidate) {
                        matched.insert(candidate)
                    }
                }
            }

            if selectionMode.contains(.vertex), let table = vertexIdentityTable(for: object) {
                for ordinal in 0..<table.shapes.count {
                    guard let shape = table.shape(forOrdinal: ordinal) else { continue }
                    let points = project(
                        shape.vertices(), vpMatrix: vpMatrix, viewportSize: viewportSize)
                    let uid = table.uid(forOrdinal: ordinal)
                    let candidate = SubShape.vertex(
                        object, ref: SubShapeRef(shape: shape, uid: uid, ordinal: ordinal))
                    if test(points), passesInstalledFilters(candidate) {
                        matched.insert(candidate)
                    }
                }
            }
        }

        switch scheme {
        case .replace: setSelection(Selection(matched))
        case .add: setSelection(Selection(selection.subshapes.union(matched)))
        case .remove: setSelection(Selection(selection.subshapes.subtracting(matched)))
        case .xor: setSelection(Selection(selection.subshapes.symmetricDifference(matched)))
        }
    }

    private func project(
        _ worldPoints: [SIMD3<Double>], vpMatrix: simd_float4x4, viewportSize: CGSize
    ) -> [CGPoint] {
        worldPoints.compactMap {
            ProjectionUtility.worldToScreen(
                point: SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)),
                vpMatrix: vpMatrix, viewportSize: viewportSize
            )
        }
    }

    private func boundingBoxCorners(lo: SIMD3<Double>, hi: SIMD3<Double>) -> [SIMD3<Double>] {
        [
            SIMD3(lo.x, lo.y, lo.z), SIMD3(hi.x, lo.y, lo.z),
            SIMD3(lo.x, hi.y, lo.z), SIMD3(hi.x, hi.y, lo.z),
            SIMD3(lo.x, lo.y, hi.z), SIMD3(hi.x, lo.y, hi.z),
            SIMD3(lo.x, hi.y, hi.z), SIMD3(hi.x, hi.y, hi.z),
        ]
    }
}

/// Screen-space enclosure/intersection tests, shared by rectangle and lasso
/// selection.
enum AreaSelectionGeometry {

    static func matches(_ points: [CGPoint], rect: CGRect, mode: AreaSelectionMode) -> Bool {
        guard !points.isEmpty else { return false }
        switch mode {
        case .enclosed: return points.allSatisfy { rect.contains($0) }
        case .intersecting: return points.contains { rect.contains($0) }
        }
    }

    static func matches(_ points: [CGPoint], polygon: [CGPoint], mode: AreaSelectionMode) -> Bool {
        guard !points.isEmpty else { return false }
        switch mode {
        case .enclosed: return points.allSatisfy { pointInPolygon($0, polygon) }
        case .intersecting: return points.contains { pointInPolygon($0, polygon) }
        }
    }

    /// Standard ray-casting point-in-polygon test. `polygon` is treated as
    /// implicitly closed (last point connects back to the first).
    private static func pointInPolygon(_ point: CGPoint, _ polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let pi = polygon[i]
            let pj = polygon[j]
            if (pi.y > point.y) != (pj.y > point.y),
                point.x < (pj.x - pi.x) * (point.y - pi.y) / (pj.y - pi.y) + pi.x
            {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}
