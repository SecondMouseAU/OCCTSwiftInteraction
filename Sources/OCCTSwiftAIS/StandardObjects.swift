import Foundation
import OCCTSwiftViewport
import simd

// Visual aids per SPEC.md §"Standard objects". Each constructs `ViewportBody`
// instances via `makeBodies()`; the caller appends them to their
// `InteractiveContext.bodies`. They aren't selectable: they ride on the
// `.userGeometry` pick layer but no `display(_:)` registration is implied,
// so picks on them produce no `Selection` updates.

// MARK: - Trihedron

/// Three colored axis arrows plus a small center sphere: the canonical
/// "world axes" affordance.
public final class Trihedron: @unchecked Sendable {
    public let id: String
    public let origin: SIMD3<Float>
    public let axisLength: Float
    public var sphereRadius: Float
    public var arrowRadius: Float

    public init(
        at origin: SIMD3<Float>,
        axisLength: Float = 1.0,
        id: String? = nil
    ) {
        self.id = id ?? "ais.scene.trihedron.\(UUID().uuidString)"
        self.origin = origin
        self.axisLength = axisLength
        self.sphereRadius = axisLength * 0.05
        self.arrowRadius = axisLength * 0.025
    }

    public func makeBodies() -> [ViewportBody] {
        var bodies: [ViewportBody] = []
        for axis in ManipulatorWidget.Axis.allCases {
            let body = ManipulatorGeometry.makeAxisArrow(
                id: "\(id).\(axisSuffix(axis))",
                origin: origin,
                direction: axis.direction,
                length: axisLength,
                radius: arrowRadius,
                color: axis.color
            )
            bodies.append(body)
        }
        bodies.append(
            StandardObjectGeometry.makeSphere(
                id: "\(id).origin",
                center: origin,
                radius: sphereRadius,
                color: SIMD4<Float>(0.85, 0.85, 0.85, 1)
            ))
        return bodies
    }

    /// Predicate matching every body this object would emit (`id` plus dotted
    /// suffix).
    ///
    /// Use to remove the object from a `bodies` array later.
    public func ownsBody(id bodyID: String) -> Bool {
        bodyID == id || bodyID.hasPrefix("\(id).")
    }
}

// MARK: - WorkPlane

/// A flat semi-transparent rectangle in the plane perpendicular to `normal`.
public final class WorkPlane: @unchecked Sendable {
    public let id: String
    public let origin: SIMD3<Float>
    public let normal: SIMD3<Float>
    public let size: Float
    public var color: SIMD4<Float>

    public init(
        origin: SIMD3<Float>,
        normal: SIMD3<Float>,
        size: Float = 100,
        color: SIMD4<Float> = SIMD4<Float>(0.5, 0.6, 0.85, 0.25),
        id: String? = nil
    ) {
        self.id = id ?? "ais.scene.workplane.\(UUID().uuidString)"
        self.origin = origin
        self.normal = simd_normalize(normal)
        self.size = size
        self.color = color
    }

    public func makeBodies() -> [ViewportBody] {
        [
            StandardObjectGeometry.makeQuad(
                id: id,
                origin: origin,
                normal: normal,
                size: size,
                color: color
            )
        ]
    }

    public func ownsBody(id bodyID: String) -> Bool { bodyID == id }
}

// MARK: - Axis

/// A thin cylinder between `from` and `to`.
///
/// Useful for marking reference lines (rotation axes, datum lines, etc.).
public final class Axis: @unchecked Sendable {
    public let id: String
    public let from: SIMD3<Float>
    public let to: SIMD3<Float>
    public let color: SIMD4<Float>
    public var radius: Float

    public init(
        from: SIMD3<Float>,
        to: SIMD3<Float>,
        color: SIMD3<Float> = SIMD3<Float>(1, 1, 1),
        radius: Float = 0.02,
        id: String? = nil
    ) {
        self.id = id ?? "ais.scene.axis.\(UUID().uuidString)"
        self.from = from
        self.to = to
        self.color = SIMD4<Float>(color, 1)
        self.radius = radius
    }

    public func makeBodies() -> [ViewportBody] {
        [
            StandardObjectGeometry.makeCylinder(
                id: id,
                from: from,
                to: to,
                radius: radius,
                color: color
            )
        ]
    }

    public func ownsBody(id bodyID: String) -> Bool { bodyID == id }
}

// MARK: - PointCloud

/// A cloud of points rendered as small spheres.
///
/// For v0.2.4, all points share one color (taken from the first entry of
/// `colors` if provided, else `defaultColor`). Per-point colors are deferred
/// until the renderer exposes per-vertex attributes.
public final class PointCloudPresentation: @unchecked Sendable {
    public let id: String
    public let points: [SIMD3<Float>]
    public let colors: [SIMD3<Float>]?
    public var pointRadius: Float
    public var defaultColor: SIMD4<Float>

    public init(
        points: [SIMD3<Float>],
        colors: [SIMD3<Float>]? = nil,
        pointRadius: Float = 0.05,
        defaultColor: SIMD4<Float> = SIMD4<Float>(1, 0.85, 0.2, 1),
        id: String? = nil
    ) {
        self.id = id ?? "ais.scene.pointcloud.\(UUID().uuidString)"
        self.points = points
        self.colors = colors
        self.pointRadius = pointRadius
        self.defaultColor = defaultColor
    }

    public func makeBodies() -> [ViewportBody] {
        guard !points.isEmpty else { return [] }
        let color: SIMD4<Float>
        if let colors, let first = colors.first {
            color = SIMD4<Float>(first, 1)
        } else {
            color = defaultColor
        }
        return [
            StandardObjectGeometry.makeSpheresInOneBody(
                id: id,
                centers: points,
                radius: pointRadius,
                color: color
            )
        ]
    }

    public func ownsBody(id bodyID: String) -> Bool { bodyID == id }
}

// MARK: - Geometry helpers

enum StandardObjectGeometry {

    /// Two-triangle quad in the plane perpendicular to `normal`, centered on
    /// `origin`. `size` is the side length; the quad is `size × size`.
    static func makeQuad(
        id: String,
        origin: SIMD3<Float>,
        normal: SIMD3<Float>,
        size: Float,
        color: SIMD4<Float>
    ) -> ViewportBody {
        let n = simd_normalize(normal)
        let (u, v) = orthonormalBasis(forNormal: n)
        let half = size * 0.5
        let p0 = origin + (-u - v) * half
        let p1 = origin + (u - v) * half
        let p2 = origin + (u + v) * half
        let p3 = origin + (-u + v) * half

        let verts: [Float] = [
            p0.x, p0.y, p0.z, n.x, n.y, n.z,
            p1.x, p1.y, p1.z, n.x, n.y, n.z,
            p2.x, p2.y, p2.z, n.x, n.y, n.z,
            p3.x, p3.y, p3.z, n.x, n.y, n.z,
        ]
        let indices: [UInt32] = [0, 1, 2, 0, 2, 3]
        return ViewportBody(
            id: id,
            vertexData: verts,
            indices: indices,
            edges: [],
            faceIndices: [],
            color: color,
            roughness: 0.85,
            metallic: 0.0
        )
    }

    /// Thin cylinder between two world points.
    static func makeCylinder(
        id: String,
        from a: SIMD3<Float>,
        to b: SIMD3<Float>,
        radius: Float,
        color: SIMD4<Float>,
        sides: Int = 12
    ) -> ViewportBody {
        let axis = b - a
        let length = simd_length(axis)
        guard length > 1e-6 else {
            return ViewportBody(
                id: id, vertexData: [], indices: [], edges: [], faceIndices: [], color: color
            )
        }
        let dir = axis / length
        let (u, v) = orthonormalBasis(forNormal: dir)
        var verts: [Float] = []
        var indices: [UInt32] = []
        appendCylinderRing(
            into: &verts, origin: a, axis: dir, u: u, v: v, radius: radius, sides: sides)
        appendCylinderRing(
            into: &verts, origin: b, axis: dir, u: u, v: v, radius: radius, sides: sides)
        for i in 0..<sides {
            let i1 = (i + 1) % sides
            let i0 = UInt32(i)
            let i1u = UInt32(i1)
            let j0 = UInt32(i + sides)
            let j1u = UInt32(i1 + sides)
            indices.append(contentsOf: [i0, j0, j1u, i0, j1u, i1u])
        }
        return ViewportBody(
            id: id,
            vertexData: verts,
            indices: indices,
            edges: [],
            faceIndices: [],
            color: color,
            roughness: 0.5,
            metallic: 0.05
        )
    }

    /// Single small sphere as its own body.
    static func makeSphere(
        id: String,
        center: SIMD3<Float>,
        radius: Float,
        color: SIMD4<Float>,
        sides: Int = 12,
        rings: Int = 6
    ) -> ViewportBody {
        var verts: [Float] = []
        var indices: [UInt32] = []
        appendSphere(
            into: &verts, indices: &indices, vertexOffset: 0,
            center: center, radius: radius, sides: sides, rings: rings)
        return ViewportBody(
            id: id,
            vertexData: verts,
            indices: indices,
            edges: [],
            faceIndices: [],
            color: color,
            roughness: 0.4,
            metallic: 0.0
        )
    }

    /// One body containing N small spheres tessellated as a single mesh.
    static func makeSpheresInOneBody(
        id: String,
        centers: [SIMD3<Float>],
        radius: Float,
        color: SIMD4<Float>,
        sides: Int = 8,
        rings: Int = 4
    ) -> ViewportBody {
        var verts: [Float] = []
        var indices: [UInt32] = []
        let stride = 6
        for c in centers {
            let offset = UInt32(verts.count / stride)
            appendSphere(
                into: &verts, indices: &indices, vertexOffset: offset,
                center: c, radius: radius, sides: sides, rings: rings)
        }
        return ViewportBody(
            id: id,
            vertexData: verts,
            indices: indices,
            edges: [],
            faceIndices: [],
            color: color,
            roughness: 0.4,
            metallic: 0.0
        )
    }

    // MARK: - Internal mesh primitives

    private static func appendCylinderRing(
        into verts: inout [Float],
        origin: SIMD3<Float>,
        axis: SIMD3<Float>,
        u: SIMD3<Float>,
        v: SIMD3<Float>,
        radius: Float,
        sides: Int
    ) {
        for i in 0..<sides {
            let theta = (Float(i) / Float(sides)) * 2 * .pi
            let r = u * cos(theta) + v * sin(theta)
            let p = origin + r * radius
            verts.append(contentsOf: [p.x, p.y, p.z, r.x, r.y, r.z])
        }
        _ = axis
    }

    private static func appendSphere(
        into verts: inout [Float],
        indices: inout [UInt32],
        vertexOffset: UInt32,
        center: SIMD3<Float>,
        radius: Float,
        sides: Int,
        rings: Int
    ) {
        // (rings + 1) latitude rings × sides longitude → (rings+1)*sides vertices.
        // Triangles between adjacent rings.
        let latCount = rings + 1
        for j in 0...rings {
            let phi = (Float(j) / Float(rings)) * .pi  // 0..π
            let cy = cos(phi)
            let sy = sin(phi)
            for i in 0..<sides {
                let theta = (Float(i) / Float(sides)) * 2 * .pi
                let n = SIMD3<Float>(sin(theta) * sy, cy, cos(theta) * sy)
                let p = center + n * radius
                verts.append(contentsOf: [p.x, p.y, p.z, n.x, n.y, n.z])
            }
        }
        for j in 0..<rings {
            for i in 0..<sides {
                let i1 = (i + 1) % sides
                let a = vertexOffset + UInt32(j * sides + i)
                let b = vertexOffset + UInt32(j * sides + i1)
                let c = vertexOffset + UInt32((j + 1) * sides + i1)
                let d = vertexOffset + UInt32((j + 1) * sides + i)
                indices.append(contentsOf: [a, b, c, a, c, d])
            }
        }
        _ = latCount
    }

    static func orthonormalBasis(forNormal n: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        let nn = simd_normalize(n)
        let helper: SIMD3<Float> = abs(nn.x) < 0.9 ? .init(1, 0, 0) : .init(0, 1, 0)
        let u = simd_normalize(simd_cross(helper, nn))
        let v = simd_cross(nn, u)
        return (u, v)
    }
}

// MARK: - Internal helpers

private func axisSuffix(_ axis: ManipulatorWidget.Axis) -> String {
    switch axis {
    case .x: return "x"
    case .y: return "y"
    case .z: return "z"
    }
}
