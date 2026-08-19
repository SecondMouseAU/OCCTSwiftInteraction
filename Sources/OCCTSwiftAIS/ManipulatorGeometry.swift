import OCCTSwiftViewport
import simd

/// Builds axis-arrow meshes for the translate manipulator.
///
/// Pure-Swift tessellation (cylinder shaft + cone head); no OCCT involvement.
enum ManipulatorGeometry {

    /// Build a single axis arrow as a `ViewportBody`.
    ///
    /// The arrow points along `direction` from `origin` with total length `length`.
    /// The shaft occupies `0 → length * 0.78`; the cone head occupies the remaining
    /// `0.22 * length`. `radius` is the shaft radius; the cone base is `2.4 * radius`.
    static func makeAxisArrow(
        id: String,
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        length: Float,
        radius: Float,
        color: SIMD4<Float>,
        sides: Int = 12
    ) -> ViewportBody {
        let dir = simd_normalize(direction)
        let (u, v) = orthonormalBasis(forNormal: dir)

        let shaftEnd: Float = length * 0.78
        let coneBaseRadius: Float = radius * 2.4

        var verts: [Float] = []
        var indices: [UInt32] = []

        // Shaft cylinder
        appendCylinderRing(
            into: &verts, origin: origin, axis: dir, u: u, v: v, radius: radius, sides: sides)
        appendCylinderRing(
            into: &verts, origin: origin + dir * shaftEnd, axis: dir, u: u, v: v, radius: radius,
            sides: sides)
        appendCylinderSideIndices(
            into: &indices, ringSize: sides, ringStart0: 0, ringStart1: UInt32(sides))

        // Cone head: base ring at shaftEnd, apex at length
        let baseStart = UInt32(verts.count / 6)
        appendCylinderRing(
            into: &verts, origin: origin + dir * shaftEnd, axis: dir, u: u, v: v,
            radius: coneBaseRadius, sides: sides)
        let apexIndex = UInt32(verts.count / 6)
        let apex = origin + dir * length
        verts.append(contentsOf: [apex.x, apex.y, apex.z, dir.x, dir.y, dir.z])
        for i in 0..<sides {
            indices.append(baseStart + UInt32(i))
            indices.append(baseStart + UInt32((i + 1) % sides))
            indices.append(apexIndex)
        }

        // Cone bottom cap (so the arrow is closed)
        let capCenterIndex = UInt32(verts.count / 6)
        let backNormal = -dir
        let capCenter = origin + dir * shaftEnd
        verts.append(contentsOf: [
            capCenter.x, capCenter.y, capCenter.z, backNormal.x, backNormal.y, backNormal.z,
        ])
        for i in 0..<sides {
            indices.append(capCenterIndex)
            indices.append(baseStart + UInt32((i + 1) % sides))
            indices.append(baseStart + UInt32(i))
        }

        return ViewportBody(
            id: id,
            vertexData: verts,
            indices: indices,
            edges: [],
            faceIndices: [],
            color: color,
            roughness: 0.3,
            metallic: 0.05,
            renderLayer: .overlay,
            pickLayer: .widget
        )
    }

    /// Conservative axis-aligned-bounding-box for an arrow in world space.
    ///
    /// Used by the CPU hit-test to avoid intersecting every triangle.
    static func axisArrowBoundingSphere(
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        length: Float
    ) -> (center: SIMD3<Float>, radius: Float) {
        let dir = simd_normalize(direction)
        let center = origin + dir * (length * 0.5)
        // Half-length along axis is the dominant dimension; keep some slack for the cone.
        let radius = length * 0.6
        return (center, radius)
    }

    /// Build a rotation handle ring (a thin torus) as a `ViewportBody`.
    ///
    /// The ring lies in the plane perpendicular to `axis`, centered on `pivot`.
    /// `radius` is the major radius (centerline of the tube); `tubeRadius` is
    /// the minor radius (tube cross-section). `sides` is the number of segments
    /// around the ring; `tubeSides` is the segments around the tube.
    static func makeRotationRing(
        id: String,
        pivot: SIMD3<Float>,
        axis: SIMD3<Float>,
        radius: Float,
        tubeRadius: Float,
        color: SIMD4<Float>,
        sides: Int = 48,
        tubeSides: Int = 8
    ) -> ViewportBody {
        let n = simd_normalize(axis)
        let (u, v) = orthonormalBasis(forNormal: n)

        var verts: [Float] = []
        verts.reserveCapacity(sides * tubeSides * 6)
        var indices: [UInt32] = []
        indices.reserveCapacity(sides * tubeSides * 6)

        for i in 0..<sides {
            let theta = (Float(i) / Float(sides)) * 2 * .pi
            // Radial direction (in ring plane) at this segment
            let radial = u * cos(theta) + v * sin(theta)
            let center = pivot + radial * radius
            for j in 0..<tubeSides {
                let phi = (Float(j) / Float(tubeSides)) * 2 * .pi
                // Tube normal: rotated combination of radial and axis
                let normal = radial * cos(phi) + n * sin(phi)
                let p = center + normal * tubeRadius
                verts.append(contentsOf: [p.x, p.y, p.z, normal.x, normal.y, normal.z])
            }
        }

        for i in 0..<sides {
            let i1 = (i + 1) % sides
            for j in 0..<tubeSides {
                let j1 = (j + 1) % tubeSides
                let a = UInt32(i * tubeSides + j)
                let b = UInt32(i1 * tubeSides + j)
                let c = UInt32(i1 * tubeSides + j1)
                let d = UInt32(i * tubeSides + j1)
                indices.append(contentsOf: [a, b, c, a, c, d])
            }
        }

        return ViewportBody(
            id: id,
            vertexData: verts,
            indices: indices,
            edges: [],
            faceIndices: [],
            color: color,
            roughness: 0.3,
            metallic: 0.05,
            renderLayer: .overlay,
            pickLayer: .widget
        )
    }

    // MARK: - Private helpers

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
            // Outward radial direction is the normal for shaft sides.
            verts.append(contentsOf: [p.x, p.y, p.z, r.x, r.y, r.z])
        }
        _ = axis
    }

    private static func appendCylinderSideIndices(
        into indices: inout [UInt32],
        ringSize: Int,
        ringStart0: UInt32,
        ringStart1: UInt32
    ) {
        for i in 0..<ringSize {
            let i0 = ringStart0 + UInt32(i)
            let i1 = ringStart0 + UInt32((i + 1) % ringSize)
            let j0 = ringStart1 + UInt32(i)
            let j1 = ringStart1 + UInt32((i + 1) % ringSize)
            indices.append(contentsOf: [i0, j0, j1, i0, j1, i1])
        }
    }

    /// Two orthogonal unit vectors spanning the plane perpendicular to `normal`.
    private static func orthonormalBasis(forNormal n: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>)
    {
        let nn = simd_normalize(n)
        let helper: SIMD3<Float> = abs(nn.x) < 0.9 ? .init(1, 0, 0) : .init(0, 1, 0)
        let u = simd_normalize(simd_cross(helper, nn))
        let v = simd_cross(nn, u)
        return (u, v)
    }
}
