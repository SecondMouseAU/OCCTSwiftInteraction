import OCCTSwift
import OCCTSwiftTools
import OCCTSwiftViewport
import Testing
import simd

@testable import OCCTSwiftCADKit

/// Regression coverage for OCCTSwiftInteraction#86: when the re-mesh of a capped body fails, the
/// body drawn and the tables a pick reads are one body's, and the selection names it.
///
/// No public API makes the re-mesh fail, so each test swaps `capMesher`, the internal seam
/// `replaceBody` meshes through, for one that fails. The body is a 4x4x4 box centred on the origin
/// with the cap at X = 0 keeping the +X half, as in `CapRecutSelectionTests`, and a piece of the +Y
/// face is selected while it is capped.
///
/// Every test fails without the fix but the one marked "Guard".
@Suite("A failed re-mesh of a capped body leaves its mesh and tables agreeing")
struct CapRemeshFailureTests {
    typealias Faces = CapRecutSelectionTests.Faces

    /// Which re-mesh fails.
    enum Failure: CaseIterable, Sendable, CustomTestStringConvertible {
        /// The cap moves to X = 1 and the re-mesh of the new cut fails.
        case recut
        /// The cap is removed and the re-mesh of the uncut box fails.
        case restore

        var testDescription: String {
            switch self {
            case .recut: "the cap moves and its re-mesh fails"
            case .restore: "the cap is removed and the restore's re-mesh fails"
            }
        }
    }

    /// Expects the mesh body `id` draws, its metadata and its identity tables to describe one body:
    /// each triangle on the face, and each edge segment on the edge, the tables give its ordinal.
    ///
    /// A box's faces are axis-aligned squares and its edges axis-aligned segments, so "on" is a
    /// bounding-box test for a face and a segment test for an edge.
    @MainActor
    static func expectMeshAgreesWithTables(
        _ service: CADViewportService, ofBody id: String, _ step: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let body = service.modelBody(id), let faces = service.faceIdentity[id],
            let edges = service.edgeIdentity[id]
        else {
            Issue.record(
                "\(step): body \(id) or its tables are missing", sourceLocation: sourceLocation)
            return
        }
        #expect(
            service.metadata[id]?.faceIndices == body.faceIndices,
            "\(step): the metadata's face ordinals are the mesh's", sourceLocation: sourceLocation)

        let offFace = body.faceIndices.indices.filter { triangle in
            let ordinal = Int(body.faceIndices[triangle])
            guard let bounds = faces.shape(forOrdinal: ordinal).flatMap({ Face($0)?.bounds }) else {
                return true
            }
            let local = HighlightGeometry.localCentroid(of: triangle, in: body)
            let point = SIMD3<Double>(Double(local.x), Double(local.y), Double(local.z))
            return !(all(point .>= bounds.min - 1e-4) && all(point .<= bounds.max + 1e-4))
        }
        #expect(
            offFace.isEmpty,
            "\(step): \(offFace.count) triangles lie off the face their ordinal names in the table",
            sourceLocation: sourceLocation)

        let ordinals = Set(body.edgeIndices.map(Int.init))
        let offEdge = ordinals.filter { ordinal in
            guard let ends = edges.shape(forOrdinal: ordinal).flatMap({ Edge($0)?.endpoints })
            else { return true }
            return HighlightGeometry.worldEndpoints(ofEdge: ordinal, in: body).contains { point in
                let along = ends.end - ends.start
                let t = simd_clamp(
                    simd_dot(point - ends.start, along) / simd_length_squared(along), 0, 1)
                return simd_distance(point, ends.start + t * along) > 1e-4
            }
        }
        #expect(
            offEdge.isEmpty,
            "\(step): edges \(offEdge.sorted()) are drawn off the edge the table gives them",
            sourceLocation: sourceLocation)
    }

    @MainActor
    @Test(
        "The uncut box comes back whole, with its own tables, and the selection follows it",
        arguments: Failure.allCases)
    func failedRemeshRestoresTheUncutBody(_ failure: Failure) throws {
        guard let service = CADViewportService.withBoxes(ids: ["ref"]) else { return }
        let planeID = service.addHalfCap()
        let piece = try #require(
            service.ref(.face, ofBody: "ref", at: Faces.plusYFromZero), "sanity check: capped")
        service.selectSub(.face, piece, ofBody: "ref")
        service.capMesher = { _, _, _, _ in (nil, nil) }

        switch failure {
        case .recut:
            let index = try #require(service.clippingPlanes.firstIndex { $0.id == planeID })
            service.clippingPlanes[index].origin = SIMD3(1, 0, 0)
        case .restore:
            service.removeClippingPlane(id: planeID)
        }

        let drawnMinX = service.modelBody("ref").flatMap {
            HighlightGeometry.worldCentroids(of: $0).map(\.x).min()
        }
        #expect(
            drawnMinX.map { abs($0 + 2) < 1e-4 } == true,
            "the uncut mesh is drawn, with the -X face the cap cut away")
        #expect(
            service.shape(id: "ref")?.bounds.map { abs($0.min.x + 2) < 1e-6 } == true,
            "the shape picks resolve against is the uncut box")
        #expect(service.capOrigins["ref"] == nil, "no cut's origins are left behind")
        Self.expectMeshAgreesWithTables(service, ofBody: "ref", "after the failure")
        CapRecutSelectionTests.expectSelection(
            service, .face, ofBody: "ref", names: [Faces.plusY], "after the failure")
        CapRecutSelectionTests.expectHighlight(
            service, .face, ofBody: "ref", lights: [Faces.plusY], "after the failure")

        // Once the re-mesh works again, the next recompute caps the box as usual.
        service.capMesher = CADViewportService.meshForCap
        switch failure {
        case .recut: service.clippingPlanes = service.clippingPlanes
        case .restore: service.addClippingPlane(origin: SIMD3(1, 0, 0), normal: SIMD3(1, 0, 0))
        }
        Self.expectMeshAgreesWithTables(service, ofBody: "ref", "recapped")
        CapRecutSelectionTests.expectSelection(
            service, .face, ofBody: "ref", names: [Faces.plusYFromOne], "recapped")
        CapRecutSelectionTests.expectHighlight(
            service, .face, ofBody: "ref", lights: [Faces.plusYFromOne], "recapped")
    }

    /// Guard: passes without the fix, which put back the mesh it hid.
    ///
    /// It fails a fix that puts back the whole uncut body even when no cut was ever installed.
    ///
    /// A plane that hides a body entirely leaves its mesh and tables as they were, and a scalar
    /// field set on that mesh is still the right one for it, so a cap that then fails to mesh only
    /// shows the body again.
    @MainActor
    @Test("A body a plane hid entirely comes back as it was, field and all, when its cap fails")
    func failedCapOfAHiddenBodyShowsItAgain() throws {
        guard let service = CADViewportService.withBoxes(ids: ["ref"]) else { return }
        let face = try #require(service.ref(.face, ofBody: "ref", at: Faces.plusY))
        service.selectSub(.face, face, ofBody: "ref")
        service.setScalarField(
            ScalarField(
                domain: .perFace, values: [0, 1, 2, 3, 4, 5], colorMap: .viridis, label: "f"),
            forBody: "ref")
        let planeID = service.addFullClip()
        try #require(service.modelBodyIsVisible("ref") == false, "sanity check: hidden")
        service.capMesher = { _, _, _, _ in (nil, nil) }

        let index = try #require(service.clippingPlanes.firstIndex { $0.id == planeID })
        service.clippingPlanes[index].origin = .zero

        #expect(service.modelBodyIsVisible("ref") == true, "the body is shown again")
        #expect(service.scalarFields["ref"] != nil, "the field set on its mesh stays")
        #expect(
            service.modelBody("ref")?.triangleStyles.isEmpty == false, "and its mesh stays painted")
        Self.expectMeshAgreesWithTables(service, ofBody: "ref", "after the failure")
        CapRecutSelectionTests.expectSelection(
            service, .face, ofBody: "ref", names: [Faces.plusY], "after the failure")
    }
}
