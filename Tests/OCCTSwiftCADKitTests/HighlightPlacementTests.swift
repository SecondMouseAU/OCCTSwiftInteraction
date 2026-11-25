import Foundation
import OCCTSwift
import OCCTSwiftAIS
import OCCTSwiftTools
import OCCTSwiftViewport
import Testing
import simd

@testable import OCCTSwiftCADKit

/// Coverage for the normals a face highlight copies under a body `transform` that is more than a
/// translation (the #73 placement, pre-PR finding f2 on OCCTSwiftInteraction#80).
///
/// `.sideBySide` only translates, which leaves a normal alone, so the side-by-side suite cannot
/// tell a correct normal from a wrong one. No public API writes a rotation or a scale to a model
/// body today, so these tests write `transform` through the internal `modelBodies` seam.
///
/// The body is a 4x4x4 box with its +X and +Y faces selected. Every check is in world space:
/// each highlight vertex must be a vertex of the face under the transform, carrying the body's own
/// normal turned by the inverse transpose of the transform's linear part and normalised, and each
/// highlight normal must be a unit vector perpendicular to the triangle it belongs to.
@Suite("Selection highlights on a body under a rotation and a scale")
struct HighlightPlacementTests {
    typealias Geometry = HighlightGeometry

    // MARK: - Dimensions

    enum Placement: CaseIterable, Sendable, CustomTestStringConvertible {
        case rotation
        case rotationThenScale
        case rotationThenScaleThenTranslation

        var testDescription: String {
            switch self {
            case .rotation: "a rotation about Z"
            case .rotationThenScale: "a rotation about Z, then a non-uniform scale"
            case .rotationThenScaleThenTranslation:
                "a rotation about a tilted axis, then a non-uniform scale and a translation"
            }
        }

        /// Whether the scale makes the inverse transpose of the linear part turn a normal
        /// differently from the linear part itself.
        ///
        /// A scale applied after a rotation does, because the rotated normals no longer lie along
        /// the scale's axes.
        var scalesNonUniformly: Bool { self != .rotation }

        var transform: simd_float4x4 {
            let scale = simd_float4x4(diagonal: SIMD4<Float>(1, 3, 0.5, 1))
            var translation = matrix_identity_float4x4
            translation.columns.3 = SIMD4<Float>(5, -2, 1, 1)
            let aboutZ = simd_float4x4(simd_quatf(angle: .pi / 6, axis: SIMD3<Float>(0, 0, 1)))
            let tilted = simd_float4x4(
                simd_quatf(angle: 0.7, axis: simd_normalize(SIMD3<Float>(1, 2, 3))))
            switch self {
            case .rotation: return aboutZ
            case .rotationThenScale: return scale * aboutZ
            case .rotationThenScaleThenTranslation: return translation * scale * tilted
            }
        }
    }

    // MARK: - Helpers

    /// A highlight or body vertex: a world position and a normal, both in double precision.
    struct Vertex {
        var position: SIMD3<Double>
        var normal: SIMD3<Double>
    }

    /// The face of body `id` that lies flat at `value` along `axis` (0 for X, 1 for Y), or `nil`.
    @MainActor
    private func face(
        ofBody id: String, flatAt value: Double, axis: Int, in service: CADViewportService
    ) -> SubShapeRef? {
        guard let table = service.faceIdentity[id] else { return nil }
        for ordinal in table.shapes.indices {
            guard let shape = table.shape(forOrdinal: ordinal),
                let bounds = Face(shape)?.bounds,
                abs(bounds.min[axis] - value) < 1e-6, abs(bounds.max[axis] - value) < 1e-6
            else { continue }
            return SubShapeRef(shape: shape, uid: table.uid(forOrdinal: ordinal), ordinal: ordinal)
        }
        return nil
    }

    /// The inverse transpose of the linear part of `transform`, in double precision.
    private static func normalMatrix(_ transform: simd_float4x4) -> simd_double3x3 {
        linearPart(transform).inverse.transpose
    }

    private static func linearPart(_ transform: simd_float4x4) -> simd_double3x3 {
        func column(_ c: SIMD4<Float>) -> SIMD3<Double> {
            SIMD3(Double(c.x), Double(c.y), Double(c.z))
        }
        return simd_double3x3(
            column(transform.columns.0), column(transform.columns.1), column(transform.columns.2))
    }

    /// Each vertex of each triangle `body` draws on `face`, in the body's own frame.
    private static func localVertices(onFace face: Shape, of body: _ViewportBody)
        -> [(position: SIMD3<Float>, normal: SIMD3<Double>)]
    {
        let data = body.vertexData
        return Geometry.triangles(onFace: face, of: body).flatMap { triangle in
            (0..<3).compactMap { corner -> (SIMD3<Float>, SIMD3<Double>)? in
                let base = Int(body.indices[triangle * 3 + corner]) * 6
                guard base + 6 <= data.count else { return nil }
                return (
                    SIMD3(data[base], data[base + 1], data[base + 2]),
                    SIMD3(Double(data[base + 3]), Double(data[base + 4]), Double(data[base + 5]))
                )
            }
        }
    }

    /// Each vertex of each triangle `body` draws on `face`, placed in world space by hand: the
    /// position by `body.transform`, the normal by the inverse transpose of its linear part,
    /// normalised.
    private static func expectedVertices(onFace face: Shape, of body: _ViewportBody) -> [Vertex] {
        let normalMatrix = normalMatrix(body.transform)
        return localVertices(onFace: face, of: body).map { local in
            Vertex(
                position: Geometry.world(local.position, under: body.transform),
                normal: simd_normalize(normalMatrix * local.normal))
        }
    }

    /// Each vertex of the face highlight, as it is stored: it carries no transform of its own.
    private static func vertices(of highlight: _ViewportBody) -> [Vertex] {
        let data = highlight.vertexData.map(Double.init)
        return Swift.stride(from: 0, to: data.count - 5, by: 6).map { base in
            Vertex(
                position: SIMD3(data[base], data[base + 1], data[base + 2]),
                normal: SIMD3(data[base + 3], data[base + 4], data[base + 5]))
        }
    }

    /// The vertices of `expected` with no partner in `actual`, and those of `actual` left over,
    /// pairing each at most once and only when both position and normal agree within `tolerance`.
    private static func unpaired(_ expected: [Vertex], _ actual: [Vertex], tolerance: Double = 1e-4)
        -> (missing: Int, extra: Int)
    {
        var extra = actual
        var missing = 0
        for vertex in expected {
            if let partner = extra.firstIndex(where: {
                simd_distance($0.position, vertex.position) <= tolerance
                    && simd_distance($0.normal, vertex.normal) <= tolerance
            }) {
                extra.remove(at: partner)
            } else {
                missing += 1
            }
        }
        return (missing, extra.count)
    }

    // MARK: - Tests

    @MainActor
    @Test(
        "A face highlight carries each vertex's normal turned by the inverse transpose, normalised",
        arguments: Placement.allCases)
    func faceHighlightNormalsFollowTheTransform(_ placement: Placement) throws {
        guard let service = CADViewportService.withBoxes(ids: ["part"]) else { return }
        let index = try #require(service.modelBodies.firstIndex { $0.id == "part" })
        service.modelBodies[index].transform = placement.transform
        let faces = try [(2.0, 0), (2.0, 1)].map { value, axis in
            try #require(face(ofBody: "part", flatAt: value, axis: axis, in: service))
        }
        for (position, face) in faces.enumerated() {
            service.selectFace(face, ofBody: "part", scheme: position == 0 ? .replace : .add)
        }
        let body = try #require(service.modelBody("part"))
        let highlight = try #require(service.selectionHighlight("face"))
        #expect(
            highlight.transform == matrix_identity_float4x4,
            "sanity check: the highlight is stored in world space")

        let expected = faces.flatMap { Self.expectedVertices(onFace: $0.shape, of: body) }
        if placement.scalesNonUniformly {
            let linear = Self.linearPart(body.transform)
            let normalMatrix = Self.normalMatrix(body.transform)
            let locals = faces.flatMap { Self.localVertices(onFace: $0.shape, of: body) }
            let turnedElsewhere = locals.allSatisfy {
                simd_distance(
                    simd_normalize(linear * $0.normal), simd_normalize(normalMatrix * $0.normal))
                    > 0.1
            }
            #expect(
                !locals.isEmpty && turnedElsewhere,
                "sanity check: the linear part alone would turn every normal somewhere else")
        }

        let actual = Self.vertices(of: highlight)
        let (missing, extra) = Self.unpaired(expected, actual)
        #expect(
            !expected.isEmpty && missing == 0 && extra == 0,
            """
            the highlight should carry the \(expected.count) vertices drawn on the faces, placed \
            and turned, but \(missing) are missing and \(extra) are elsewhere or turned wrongly
            """)

        // Independent of the formula above: a normal is a unit vector perpendicular to its face.
        let corners = highlight.indices.map { actual[Int($0)] }
        var badNormals = 0
        for start in Swift.stride(from: 0, to: corners.count - 2, by: 3) {
            let edges = [
                corners[start + 1].position - corners[start].position,
                corners[start + 2].position - corners[start].position,
            ].map(simd_normalize)
            for corner in corners[start..<(start + 3)] {
                let isUnit = abs(simd_length(corner.normal) - 1) <= 1e-4
                let isPerpendicular = edges.allSatisfy { abs(simd_dot($0, corner.normal)) <= 1e-4 }
                if !(isUnit && isPerpendicular) { badNormals += 1 }
            }
        }
        #expect(
            !corners.isEmpty && badNormals == 0,
            "\(badNormals) of \(corners.count) highlight normals are not unit normals of the face")
    }
}
