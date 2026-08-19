import Foundation
import OCCTSwift
import OCCTSwiftViewport
import simd

/// A dimension annotation: a measurement displayed in the scene as leader
/// lines plus a billboarded label.
///
/// Concrete subclasses: `LinearDimension` (v0.4); `AngularDimension` and
/// `RadialDimension` come in v0.5.
///
/// Dimensions render via the `MeasurementOverlay` SwiftUI Canvas overlay
/// inside `MetalViewportView`. AIS owns the topology-aware anchor resolution
/// (sub-shape → world point) and pushes the resulting `ViewportMeasurement`
/// through `InteractiveContext.add(_:)`.
public protocol Dimension: AnyObject, Sendable {
    /// Stable id used to track the dimension across `add` / `remove` cycles.
    var id: String { get }

    /// Human-readable label (e.g. `"5.32"`). Customise the label by passing
    /// `customLabel` to the dimension's initialiser.
    var label: String { get }

    /// World-space anchor points, in the order each concrete dimension type
    /// expects (e.g. `[start, end]` for `LinearDimension`).
    var anchorPoints: [SIMD3<Float>] { get }

    /// `ViewportMeasurement` form for handoff to the renderer's overlay.
    var viewportMeasurement: ViewportMeasurement { get }
}

// MARK: - LinearDimension

public final class LinearDimension: Dimension, @unchecked Sendable {

    public let id: String
    public let from: SubShape
    public let to: SubShape

    /// If non-nil, both anchors are orthogonally projected onto this plane
    /// before the distance is measured: the dimension reports the **in-plane**
    /// length rather than the straight 3D distance.
    public let plane: WorkPlane?

    /// Optional caller-supplied label; if nil the formatted distance is used.
    public var customLabel: String?

    public init(
        from: SubShape,
        to: SubShape,
        plane: WorkPlane? = nil,
        customLabel: String? = nil,
        id: String? = nil
    ) {
        self.id = id ?? "ais.dimension.linear.\(UUID().uuidString)"
        self.from = from
        self.to = to
        self.plane = plane
        self.customLabel = customLabel
    }

    /// `[from, to]`, or `[]` when either anchor fails to resolve.
    public var anchorPoints: [SIMD3<Float>] {
        guard let a = DimensionAnchor.resolve(from), let b = DimensionAnchor.resolve(to) else {
            return []
        }
        if let plane {
            return [
                DimensionAnchor.project(a, onto: plane), DimensionAnchor.project(b, onto: plane),
            ]
        }
        return [a, b]
    }

    /// Straight-line distance between the two anchors (after optional plane
    /// projection). `nan` if either anchor failed to resolve.
    public var distance: Float {
        let pts = anchorPoints
        guard pts.count == 2 else { return .nan }
        return simd_distance(pts[0], pts[1])
    }

    public var label: String {
        if let customLabel { return customLabel }
        return DimensionAnchor.formatDistance(distance)
    }

    public var viewportMeasurement: ViewportMeasurement {
        let pts = anchorPoints
        let start = pts.indices.contains(0) ? pts[0] : .zero
        let end = pts.indices.contains(1) ? pts[1] : .zero
        return .distance(DistanceMeasurement(id: id, start: start, end: end, label: customLabel))
    }
}

// MARK: - AngularDimension

public final class AngularDimension: Dimension, @unchecked Sendable {

    public let id: String
    public let armA: SubShape
    public let apex: SubShape
    public let armB: SubShape
    public var customLabel: String?

    public init(
        arms: (SubShape, SubShape),
        apex: SubShape,
        customLabel: String? = nil,
        id: String? = nil
    ) {
        self.id = id ?? "ais.dimension.angular.\(UUID().uuidString)"
        self.armA = arms.0
        self.apex = apex
        self.armB = arms.1
        self.customLabel = customLabel
    }

    /// `[armA, apex, armB]`: preserves the standard "vertex in the middle"
    /// convention that `ViewportMeasurement.angle` and most CAD apps expect.
    ///
    /// `[]` when any of the three anchors fails to resolve.
    public var anchorPoints: [SIMD3<Float>] {
        guard let a = DimensionAnchor.resolve(armA),
            let v = DimensionAnchor.resolve(apex),
            let b = DimensionAnchor.resolve(armB)
        else {
            return []
        }
        return [a, v, b]
    }

    /// Angle at the apex, in degrees.
    ///
    /// NaN if either arm coincides with the apex.
    public var degrees: Float {
        let pts = anchorPoints
        guard pts.count == 3 else { return .nan }
        return ProjectionUtility.angle(pts[0], vertex: pts[1], pts[2])
    }

    public var label: String {
        if let customLabel { return customLabel }
        let d = degrees
        if !d.isFinite { return "?" }
        return String(format: "%.1f\u{00B0}", d)
    }

    public var viewportMeasurement: ViewportMeasurement {
        let pts = anchorPoints
        let a = pts.indices.contains(0) ? pts[0] : .zero
        let v = pts.indices.contains(1) ? pts[1] : .zero
        let b = pts.indices.contains(2) ? pts[2] : .zero
        return .angle(AngleMeasurement(id: id, pointA: a, vertex: v, pointB: b, label: customLabel))
    }
}

// MARK: - RadialDimension

public final class RadialDimension: Dimension, @unchecked Sendable {

    public let id: String
    public let circularEdge: SubShape

    /// If true, the rendered label uses ⌀ and the diameter; otherwise R and the radius.
    public var showDiameter: Bool

    public var customLabel: String?

    public init(
        circularEdge: SubShape,
        showDiameter: Bool = false,
        customLabel: String? = nil,
        id: String? = nil
    ) {
        self.id = id ?? "ais.dimension.radial.\(UUID().uuidString)"
        self.circularEdge = circularEdge
        self.showDiameter = showDiameter
        self.customLabel = customLabel
    }

    /// `[center, pointOnEdge]`.
    ///
    /// Returns `[.zero, .zero]` when the sub-shape isn't an edge or its
    /// underlying curve isn't circular.
    public var anchorPoints: [SIMD3<Float>] {
        guard let (center, edgePoint, _) = DimensionAnchor.resolveCircle(circularEdge) else {
            return [.zero, .zero]
        }
        return [center, edgePoint]
    }

    public var radius: Float {
        DimensionAnchor.resolveCircle(circularEdge)?.2 ?? .nan
    }

    public var diameter: Float { radius * 2 }

    public var label: String {
        if let customLabel { return customLabel }
        let value = showDiameter ? diameter : radius
        if !value.isFinite { return "?" }
        let prefix = showDiameter ? "\u{2300}" : "R"
        return prefix + DimensionAnchor.formatDistance(value)
    }

    public var viewportMeasurement: ViewportMeasurement {
        let pts = anchorPoints
        let center = pts.indices.contains(0) ? pts[0] : .zero
        let edge = pts.indices.contains(1) ? pts[1] : .zero
        return .radius(
            RadiusMeasurement(
                id: id,
                center: center,
                edgePoint: edge,
                showDiameter: showDiameter,
                label: customLabel
            ))
    }
}

// MARK: - Anchor resolution

/// Maps a `SubShape` to a world-space anchor point.
///
/// Used by dimension types.
enum DimensionAnchor {

    /// nil when the sub-shape has no resolvable anchor, e.g. a shape whose
    /// bounding box is void.
    static func resolve(_ subshape: SubShape) -> SIMD3<Float>? {
        switch subshape {
        case .body(let obj):
            return resolveBody(obj)
        case .face(_, let ref):
            return resolveFace(ref)
        case .edge(_, let ref):
            return resolveEdge(ref)
        case .vertex(_, let ref):
            return resolveVertex(ref)
        }
    }

    private static func resolveBody(_ obj: InteractiveObject) -> SIMD3<Float>? {
        // Bbox center of the source shape.
        guard let bounds = obj.shape.bounds else { return nil }
        let center = (bounds.min + bounds.max) * 0.5
        return SIMD3<Float>(Float(center.x), Float(center.y), Float(center.z))
    }

    private static func resolveFace(_ ref: SubShapeRef) -> SIMD3<Float>? {
        // Bbox center of the face: cheap, robust for axis-aligned faces.
        // Curved faces would be better served by the area-weighted centroid
        // (`ShapeMeasurements.faceCentroids` from OCCTSwift) but that's an
        // O(faces) computation; bbox center is constant time per face.
        guard let face = OCCTSwift.Face(ref.shape), let bounds = face.bounds else { return nil }
        let center = (bounds.min + bounds.max) * 0.5
        return SIMD3<Float>(Float(center.x), Float(center.y), Float(center.z))
    }

    private static func resolveEdge(_ ref: SubShapeRef) -> SIMD3<Float>? {
        guard let edge = OCCTSwift.Edge(ref.shape) else { return nil }
        let ends = edge.endpoints
        let mid = (ends.start + ends.end) * 0.5
        return SIMD3<Float>(Float(mid.x), Float(mid.y), Float(mid.z))
    }

    private static func resolveVertex(_ ref: SubShapeRef) -> SIMD3<Float>? {
        guard let p = ref.shape.vertices().first else { return nil }
        return SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z))
    }

    /// If `subshape` is a circular edge, return
    /// `(center, pointOnCircle, radius)` in world space.
    ///
    /// The `pointOnCircle` is the edge's start endpoint, guaranteed to lie
    /// on the circle when the edge is a circular arc / closed circle.
    static func resolveCircle(_ subshape: SubShape) -> (SIMD3<Float>, SIMD3<Float>, Float)? {
        guard case .edge(_, let ref) = subshape,
            let edge = OCCTSwift.Edge(ref.shape),
            edge.isCircle,
            let curve = edge.curve3D
        else {
            return nil
        }
        let props = curve.circleProperties
        let center = SIMD3<Float>(
            Float(props.center.x), Float(props.center.y), Float(props.center.z))
        let radius = Float(props.radius)
        let edgePoint = SIMD3<Float>(
            Float(edge.endpoints.start.x),
            Float(edge.endpoints.start.y),
            Float(edge.endpoints.start.z)
        )
        return (center, edgePoint, radius)
    }

    /// Project `point` orthogonally onto `plane` (signed perpendicular drop).
    static func project(_ point: SIMD3<Float>, onto plane: WorkPlane) -> SIMD3<Float> {
        let n = simd_normalize(plane.normal)
        let signed = simd_dot(point - plane.origin, n)
        return point - n * signed
    }

    static func formatDistance(_ value: Float) -> String {
        if !value.isFinite { return "?" }
        if value >= 100 {
            return String(format: "%.0f", value)
        } else if value >= 10 {
            return String(format: "%.1f", value)
        } else {
            return String(format: "%.2f", value)
        }
    }
}

// MARK: - InteractiveContext glue

extension InteractiveContext {

    /// Add a dimension to the scene.
    ///
    /// The dimension's `viewportMeasurement` is pushed to
    /// `viewport.measurements`, where the renderer's overlay picks it up
    /// automatically. Idempotent for the same instance.
    ///
    /// A dimension whose anchors do not resolve (empty `anchorPoints`) is
    /// registered but draws nothing, rather than being drawn at the world
    /// origin. Call `refreshDimensionMeasurement(_:)` once its anchors can
    /// resolve to make it appear.
    @discardableResult
    public func add<D: Dimension>(_ dimension: D) -> D {
        let oid = ObjectIdentifier(dimension)
        if dimensionRegistry[oid] != nil {
            // Already added: refresh the measurement in case anchors changed.
            refreshDimensionMeasurement(dimension)
            return dimension
        }
        dimensionRegistry[oid] = dimension
        if !dimension.anchorPoints.isEmpty {
            viewport.measurements.append(dimension.viewportMeasurement)
        }
        return dimension
    }

    /// Remove a previously-added dimension.
    public func remove(_ dimension: any Dimension) {
        let oid = ObjectIdentifier(dimension)
        guard dimensionRegistry.removeValue(forKey: oid) != nil else { return }
        let id = dimension.id
        viewport.measurements.removeAll { $0.id == id }
    }

    /// All dimensions currently displayed in this context.
    public var dimensions: [any Dimension] {
        Array(dimensionRegistry.values)
    }

    /// Re-fetch a dimension's `viewportMeasurement` and replace it in place
    /// in `viewport.measurements`.
    ///
    /// Call this if the underlying anchors moved (e.g. a target shape
    /// mutated); for a static scene you don't need it.
    ///
    /// Anchors that stopped resolving drop the measurement from the overlay,
    /// and anchors that started resolving add it back.
    public func refreshDimensionMeasurement(_ dimension: any Dimension) {
        let id = dimension.id
        let resolves = !dimension.anchorPoints.isEmpty
        if let i = viewport.measurements.firstIndex(where: { $0.id == id }) {
            if resolves {
                viewport.measurements[i] = dimension.viewportMeasurement
            } else {
                viewport.measurements.remove(at: i)
            }
        } else if resolves, dimensionRegistry[ObjectIdentifier(dimension)] != nil {
            viewport.measurements.append(dimension.viewportMeasurement)
        }
    }
}
