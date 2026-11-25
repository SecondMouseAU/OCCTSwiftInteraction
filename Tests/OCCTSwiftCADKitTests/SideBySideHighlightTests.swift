import Foundation
import OCCTSwift
import OCCTSwiftAIS
import OCCTSwiftTools
import OCCTSwiftViewport
import Testing
import simd

@testable import OCCTSwiftCADKit

/// Regression coverage for OCCTSwiftInteraction#73: `.sideBySide` moves the candidate through its
/// body's `transform`, while a selection highlight copies the candidate's geometry out of its
/// vertex data, which the transform does not touch.
///
/// Every check is in world space, a position under its own body's `transform`: the highlight must
/// sit on what the candidate draws, wherever the offset has put it. The face is a box's +Y face.
///
/// Every test fails without the fix. Each also fails without #72's, since the highlight has to be
/// cut again when the offset appears, moves or goes.
@Suite("Selection highlights on a body moved side by side")
struct SideBySideHighlightTests {
    typealias Geometry = HighlightGeometry

    // MARK: - Dimensions

    /// When the candidate's sub-shape is selected.
    enum Timing: CaseIterable, Sendable, CustomTestStringConvertible {
        case beforeComparison
        case duringSideBySide
        case duringWipe

        var testDescription: String {
            switch self {
            case .beforeComparison: "selected before the comparison"
            case .duringSideBySide: "selected during side by side"
            case .duringWipe: "selected during a wipe, which then switches to side by side"
            }
        }
    }

    /// The highlight body that is not a triangle patch.
    enum Kind: CaseIterable, Sendable, CustomTestStringConvertible {
        case edge
        case vertex

        var testDescription: String {
            switch self {
            case .edge: "edge"
            case .vertex: "vertex"
            }
        }
    }

    struct PointCase: Sendable, CustomTestStringConvertible {
        var kind: Kind
        var timing: Timing

        var testDescription: String { "\(kind.testDescription), \(timing.testDescription)" }

        static let all = Kind.allCases.flatMap { kind in
            [Timing.beforeComparison, .duringSideBySide].map { PointCase(kind: kind, timing: $0) }
        }
    }

    /// How side by side ends, other than by clearing it.
    enum Ending: CaseIterable, Sendable, CustomTestStringConvertible {
        case switchToOverlay
        case switchToWipe
        case referenceRemoved

        var testDescription: String {
            switch self {
            case .switchToOverlay: "the comparison switches to overlay"
            case .switchToWipe: "the comparison switches to a wipe"
            case .referenceRemoved: "the reference is removed"
            }
        }
    }

    // MARK: - Helpers

    private static let sideBySide = ComparisonView(
        referenceID: "ref", candidateID: "cand", mode: .sideBySide)

    private static let wipe = ComparisonView(
        referenceID: "ref", candidateID: "cand", mode: .wipe(axis: .x, position: 0))

    /// The X translation of the candidate's body.
    @MainActor
    private func offset(_ service: CADViewportService) -> Float? {
        service.modelBody("cand")?.transform.columns.3.x
    }

    /// The world position of each end of each segment the body draws for `edgeIndex`.
    private func drawnEndpoints(ofEdge edgeIndex: Int, in body: _ViewportBody) -> [SIMD3<Double>] {
        var points: [SIMD3<Double>] = []
        var segment = 0
        for polyline in body.edges {
            for start in polyline.indices.dropLast() {
                defer { segment += 1 }
                guard segment < body.edgeIndices.count,
                    body.edgeIndices[segment] == Int32(edgeIndex)
                else { continue }
                points.append(Geometry.world(polyline[start], under: body.transform))
                points.append(Geometry.world(polyline[start + 1], under: body.transform))
            }
        }
        return points
    }

    /// The world position of each point a highlight body draws: its polylines' points, or its
    /// point sprites.
    private func drawnPoints(of highlight: _ViewportBody?) -> [SIMD3<Double>] {
        guard let highlight else { return [] }
        let local = highlight.edges.flatMap { $0 } + highlight.vertices
        return local.map { Geometry.world($0, under: highlight.transform) }
    }

    /// Selects the candidate's first edge or vertex through the pick resolver, and returns it.
    @MainActor
    private func selectCandidate(_ kind: Kind, in service: CADViewportService) -> PickedEntity? {
        switch kind {
        case .edge:
            guard let info = service.resolveEdgePick(bodyID: "cand", segmentIndex: 0) else {
                return nil
            }
            service.select(.edge(info), scheme: .replace)
            return .edge(info)
        case .vertex:
            guard let info = service.resolveVertexPick(bodyID: "cand", pointIndex: 0) else {
                return nil
            }
            service.select(.vertex(info), scheme: .replace)
            return .vertex(info)
        }
    }

    /// The world positions the candidate draws for `entity`, an edge or the vertex at point 0.
    @MainActor
    private func drawnPoints(of entity: PickedEntity, in service: CADViewportService)
        -> [SIMD3<Double>]
    {
        guard let body = service.modelBody("cand") else { return [] }
        switch entity {
        case .edge(let info):
            return drawnEndpoints(ofEdge: info.edgeIndex, in: body)
        case .vertex:
            return body.vertices.prefix(1).map { Geometry.world($0, under: body.transform) }
        case .face:
            return []
        }
    }

    /// Expects the highlight of `kind` to draw exactly the points the candidate draws for
    /// `entity`.
    @MainActor
    private func expectPointHighlight(
        _ service: CADViewportService, _ kind: Kind, lights entity: PickedEntity, _ step: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let drawn = drawnPoints(of: entity, in: service)
        let lit = drawnPoints(of: service.selectionHighlight(kind.testDescription))
        let (missing, extra) = Geometry.unpaired(drawn, lit)
        #expect(
            !drawn.isEmpty && missing.isEmpty && extra.isEmpty,
            """
            \(step): the \(kind.testDescription) highlight should draw the \(drawn.count) points \
            the candidate draws, but \(missing.count) are missing and \(extra.count) are elsewhere
            """,
            sourceLocation: sourceLocation)
    }

    // MARK: - Faces

    @MainActor
    @Test(
        "A face selected on the candidate is lit where the candidate draws it, offset or not",
        arguments: Timing.allCases)
    func faceHighlightFollowsTheOffset(_ timing: Timing) throws {
        guard let service = CADViewportService.withBoxes(ids: ["ref", "cand"]) else { return }
        let face = try #require(service.plusYFace(ofBody: "cand"))
        let faces = [(bodyID: "cand", face: face)]

        switch timing {
        case .beforeComparison:
            service.selectFace(face, ofBody: "cand")
        case .duringWipe:
            service.setComparison(Self.wipe)
            service.selectFace(face, ofBody: "cand")
        case .duringSideBySide:
            break
        }
        service.setComparison(Self.sideBySide)
        #expect(offset(service) != 0, "sanity check: side by side moves the candidate")
        if timing == .duringSideBySide { service.selectFace(face, ofBody: "cand") }
        expectFaceHighlight(service, lights: faces, "side by side")

        service.setComparison(nil)
        #expect(offset(service) == 0, "sanity check: the candidate is back in place")
        expectFaceHighlight(service, lights: faces, "cleared")
    }

    @MainActor
    @Test("A selection on both sides lights each face where its own body draws it")
    func selectionOnBothSidesLightsEachFaceInPlace() throws {
        guard let service = CADViewportService.withBoxes(ids: ["ref", "cand"]) else { return }
        let faces = try ["ref", "cand"].map { id in
            (bodyID: id, face: try #require(service.plusYFace(ofBody: id)))
        }
        service.selectFace(faces[0].face, ofBody: "ref", scheme: .replace)
        service.selectFace(faces[1].face, ofBody: "cand", scheme: .add)

        service.setComparison(Self.sideBySide)
        #expect(offset(service) != 0, "sanity check: side by side moves the candidate")
        #expect(
            service.modelBody("ref")?.transform == matrix_identity_float4x4,
            "sanity check: and leaves the reference in place")
        expectFaceHighlight(service, lights: faces, "side by side")

        service.setComparison(nil)
        expectFaceHighlight(service, lights: faces, "cleared")
    }

    @MainActor
    @Test(
        "A face lit on the candidate leaves the offset when side by side ends",
        arguments: Ending.allCases)
    func faceHighlightLeavesTheOffset(_ ending: Ending) throws {
        guard let service = CADViewportService.withBoxes(ids: ["ref", "cand"]) else { return }
        let face = try #require(service.plusYFace(ofBody: "cand"))
        let faces = [(bodyID: "cand", face: face)]
        service.setComparison(Self.sideBySide)
        service.selectFace(face, ofBody: "cand")
        expectFaceHighlight(service, lights: faces, "side by side")

        switch ending {
        case .switchToOverlay:
            service.setComparison(
                ComparisonView(
                    referenceID: "ref", candidateID: "cand",
                    mode: .overlay(referenceOpacity: 0.3)))
        case .switchToWipe:
            service.setComparison(Self.wipe)
        case .referenceRemoved:
            service.remove(id: "ref")
        }

        #expect(offset(service) == 0, "sanity check: the candidate is back in place")
        expectFaceHighlight(service, lights: faces, ending.testDescription)
    }

    /// A cap that narrows the reference moves the candidate.
    ///
    /// The gap scales with the wider entity, so `updateCapSurfaces()` reapplies side by side at a
    /// new offset. The candidate lies wholly on the kept side, so it is not recut and its face
    /// keeps its ordinal.
    @MainActor
    @Test("A face lit on the candidate follows the offset when a cap moves it")
    func faceHighlightFollowsACapMovingTheOffset() throws {
        let service = CADViewportService()
        guard let wide = Shape.box(width: 10, height: 4, depth: 4),
            let box = Shape.box(width: 4, height: 4, depth: 4)
        else {
            Issue.record("Shape.box returned nil")
            return
        }
        service.load(wide, id: "ref", transform: [1, 0, 0, 0, 1, 0, 0, 0, 1, -10, 0, 0])
        service.load(box, id: "cand")
        #expect(
            abs((service.entityMinX("ref") ?? 0) + 15) < 1e-6,
            "sanity check: the reference spans X = -15 to -5")
        let face = try #require(service.plusYFace(ofBody: "cand"))
        let faces = [(bodyID: "cand", face: face)]
        service.selectFace(face, ofBody: "cand")
        service.setComparison(Self.sideBySide)
        let uncapped = try #require(offset(service))
        let generation = service.modelBody("cand")?.generation
        expectFaceHighlight(service, lights: faces, "side by side")

        let plane = service.addClippingPlane(
            origin: SIMD3(-12, 0, 0), normal: SIMD3(1, 0, 0), showCapSurface: true)
        #expect(
            offset(service).map { abs($0 - uncapped) > 0.1 } == true,
            "sanity check: the cap narrows the reference, which moves the candidate")
        #expect(
            service.modelBody("cand")?.generation == generation,
            "sanity check: the candidate itself is not recut")
        expectFaceHighlight(service, lights: faces, "a cap moves the offset")

        service.removeClippingPlane(id: plane)
        #expect(
            offset(service).map { abs($0 - uncapped) < 1e-5 } == true,
            "sanity check: the offset is back where it was")
        expectFaceHighlight(service, lights: faces, "the cap is removed")
    }

    // MARK: - Edges and vertices

    @MainActor
    @Test(
        "An edge or vertex selected on the candidate is lit where the candidate draws it",
        arguments: PointCase.all)
    func pointHighlightFollowsTheOffset(_ testCase: PointCase) throws {
        guard let service = CADViewportService.withBoxes(ids: ["ref", "cand"]) else { return }
        service.selectionModes = [.face, .edge, .vertex]

        var entity: PickedEntity?
        if testCase.timing == .beforeComparison {
            entity = selectCandidate(testCase.kind, in: service)
        }
        service.setComparison(Self.sideBySide)
        #expect(offset(service) != 0, "sanity check: side by side moves the candidate")
        if testCase.timing == .duringSideBySide {
            entity = selectCandidate(testCase.kind, in: service)
        }
        let selected = try #require(entity, "sanity check: the candidate's first one picks")
        expectPointHighlight(service, testCase.kind, lights: selected, "side by side")

        service.setComparison(nil)
        #expect(offset(service) == 0, "sanity check: the candidate is back in place")
        expectPointHighlight(service, testCase.kind, lights: selected, "cleared")
    }
}
