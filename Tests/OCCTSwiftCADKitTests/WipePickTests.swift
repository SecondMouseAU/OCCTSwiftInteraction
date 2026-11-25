import Foundation
import OCCTSwift
import OCCTSwiftTools
import OCCTSwiftViewport
import Testing
import simd

@testable import OCCTSwiftCADKit

/// Regression coverage for OCCTSwiftInteraction#58: a `.wipe` draws a subset of each compared
/// body's triangles, and a GPU pick names a triangle of that subset, while the face table and a
/// `.perTriangle` scalar field are indexed by the whole body's triangles.
///
/// Faces are checked by geometry: a picked triangle's centroid, taken off the body as drawn, must
/// lie on the face the pick resolved to. A 4x4x4 box's faces are axis-aligned squares, so a face's
/// bounding box holds no other face's triangle centroids. Each wiped case first checks that the
/// wipe drops a triangle ahead of one it draws, which is what puts the two orders out of step.
///
/// Every test fails without the fix except the one marked "guard", and the cases of
/// `pickAfterTheWipeChanges` that leave no wipe behind, which guard the fix's own bookkeeping.
@Suite("Picking on a body cut by a wipe")
struct WipePickTests {
    typealias Target = ComparisonVisibilityTests.Target
    typealias Mode = ComparisonVisibilityTests.Mode
    typealias Trigger = ComparisonVisibilityTests.Trigger
    typealias Domain = ComparisonScalarFieldTests.Domain
    typealias Keys = ComparisonScalarFieldTests

    // MARK: - Dimensions

    /// When the scalar field is set, relative to the wipe.
    enum FieldTiming: CaseIterable, Sendable, CustomTestStringConvertible {
        case beforeWipe
        case duringWipe

        var testDescription: String {
            switch self {
            case .beforeWipe: "set before the wipe"
            case .duringWipe: "set during the wipe"
            }
        }
    }

    struct ValueCase: Sendable, CustomTestStringConvertible {
        var target: Target
        var domain: Domain
        var timing: FieldTiming

        var testDescription: String {
            "\(domain.testDescription) on \(target.testDescription), \(timing.testDescription)"
        }

        static let all = Target.allCases.flatMap { target in
            Domain.allCases.flatMap { domain in
                FieldTiming.allCases.map { ValueCase(target: target, domain: domain, timing: $0) }
            }
        }
    }

    /// Something that rebuilds or ends the wipe after the first one applied.
    enum Change: Sendable, CustomTestStringConvertible {
        case moveWipe
        case setFieldDuringWipe
        case recompute(Trigger)
        case clear
        case switchTo(Mode)

        var testDescription: String {
            switch self {
            case .moveWipe: "the wipe moves"
            case .setFieldDuringWipe: "a field is set, which steps the wipe aside and back"
            case .recompute(let trigger): "\(trigger.testDescription)"
            case .clear: "the comparison is cleared"
            case .switchTo(let mode): "the comparison switches to \(mode.testDescription)"
            }
        }

        /// Whether the bodies are still wiped afterwards.
        var leavesWipe: Bool {
            switch self {
            case .moveWipe, .setFieldDuringWipe, .recompute: true
            case .clear, .switchTo: false
            }
        }

        /// Leaves out `.addUnrelatedHollowPlane`: the plane it adds is unrelated to visibility
        /// but hides every pick below Z = 100, which is the clip test's subject, not this one's.
        static let all: [Change] =
            [.moveWipe, .setFieldDuringWipe]
            + Trigger.allCases.filter { $0 != .addUnrelatedHollowPlane }.map(recompute)
            + [.clear, .switchTo(.overlay), .switchTo(.sideBySide)]
    }

    // MARK: - Helpers

    private static func wipe(at position: Double) -> ComparisonView {
        ComparisonView(
            referenceID: "ref", candidateID: "cand", mode: .wipe(axis: .x, position: position))
    }

    @MainActor
    private func body(_ service: CADViewportService, _ id: String) -> _ViewportBody? {
        service.modelBodies.first { $0.id == id }
    }

    private func triangleCount(_ body: _ViewportBody) -> Int {
        body.indices.count / 3
    }

    /// The centroid of `triangle` in `body`, in the body's own frame.
    private func centroid(of triangle: Int, in body: _ViewportBody) -> SIMD3<Double> {
        let corners = (0..<3).map { corner -> SIMD3<Double> in
            let vertex = Int(body.indices[triangle * 3 + corner])
            let (positions, stride) =
                body.usesDirectMesh ? (body.meshPositions, 3) : (body.vertexData, 6)
            return SIMD3(
                Double(positions[vertex * stride]), Double(positions[vertex * stride + 1]),
                Double(positions[vertex * stride + 2]))
        }
        return (corners[0] + corners[1] + corners[2]) / 3
    }

    /// Whether `point` lies on the face `shape`, judged by the face's bounding box.
    private func face(_ shape: Shape, contains point: SIMD3<Double>) -> Bool {
        guard let face = Face(shape), let bounds = face.bounds else { return false }
        let tolerance = 1e-4
        return all(point .>= bounds.min - tolerance) && all(point .<= bounds.max + tolerance)
    }

    /// Whether some triangle `id` draws comes after one the wipe dropped, so that its drawn
    /// index differs from its index in `baseline`.
    @MainActor
    private func drawsPastADroppedTriangle(
        _ service: CADViewportService, _ id: String, baseline: _ViewportBody
    ) -> Bool {
        guard let live = body(service, id) else { return false }
        return Keys.baselineTriangles(of: live, in: baseline).enumerated().contains {
            $0.element != $0.offset
        }
    }

    /// Expects every triangle the body `id` draws to resolve to the face it lies on.
    @MainActor
    private func expectEveryPickNamesItsFace(
        _ service: CADViewportService, _ id: String, _ comment: Comment,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let live = body(service, id), triangleCount(live) > 0 else {
            Issue.record("no triangles drawn for \(id)", sourceLocation: sourceLocation)
            return
        }
        let misses = (0..<triangleCount(live)).filter { triangle in
            guard let info = service.resolveFacePick(bodyID: id, triangleIndex: triangle) else {
                return true
            }
            return !face(info.shape, contains: centroid(of: triangle, in: live))
        }
        #expect(misses == [], comment, sourceLocation: sourceLocation)
    }

    // MARK: - The face a pick names

    @MainActor
    @Test(
        "A face pick on a wiped body names the face under the picked triangle",
        arguments: Target.allCases)
    func facePickNamesTheFaceUnderTheTriangle(_ target: Target) throws {
        guard let service = CADViewportService.withBoxes(ids: ["ref", "cand"]) else { return }
        let baseline = try #require(body(service, target.id))
        expectEveryPickNamesItsFace(service, target.id, "sanity check: right before the wipe")

        service.setComparison(Self.wipe(at: 1))
        #expect(
            drawsPastADroppedTriangle(service, target.id, baseline: baseline),
            "sanity check: the wipe drops a triangle ahead of one it draws")
        expectEveryPickNamesItsFace(
            service, target.id, "each listed triangle resolved to a face it does not lie on")
    }

    @MainActor
    @Test(
        "The clip pre-filter on a wiped body tests the picked triangle itself",
        arguments: Target.allCases)
    func clipPreFilterTestsThePickedTriangle(_ target: Target) throws {
        guard let service = CADViewportService.withBoxes(ids: ["ref", "cand"]) else { return }
        let baseline = try #require(body(service, target.id))
        service.setComparison(Self.wipe(at: 1))
        // Hollow, so it clips picks without retessellating: it hides everything below Z = 0.
        service.addClippingPlane(origin: .zero, normal: SIMD3(0, 0, 1), showCapSurface: false)
        let live = try #require(body(service, target.id))
        #expect(
            drawsPastADroppedTriangle(service, target.id, baseline: baseline),
            "sanity check: the wipe drops a triangle ahead of one it draws")

        var clipped: [Int] = []
        var wrong: [Int] = []
        for triangle in 0..<triangleCount(live) {
            let point = centroid(of: triangle, in: live)
            let info = service.resolveFacePick(bodyID: target.id, triangleIndex: triangle)
            if point.z < 0 {
                clipped.append(triangle)
                if info != nil { wrong.append(triangle) }
            } else if !(info.map { face($0.shape, contains: point) } ?? false) {
                wrong.append(triangle)
            }
        }
        #expect(
            !clipped.isEmpty && clipped.count < triangleCount(live),
            "sanity check: the plane hides some drawn triangles and not others")
        #expect(
            wrong == [],
            "a hidden triangle resolves to nothing and a visible one to the face it lies on")
    }

    // MARK: - The value a pick reports

    @MainActor
    @Test(
        "A pick on a wiped body reports the scalar value painted under the picked triangle",
        arguments: ValueCase.all)
    func pickedValueIsThePaintUnderTheCursor(_ testCase: ValueCase) throws {
        guard let service = CADViewportService.withBoxes(ids: ["ref", "cand"]) else { return }
        let id = testCase.target.id
        let baseline = try #require(body(service, id))
        let field = Keys.keyField(testCase.domain)

        if testCase.timing == .beforeWipe { service.setScalarField(field, forBody: id) }
        service.setComparison(Self.wipe(at: 1))
        if testCase.timing == .duringWipe { service.setScalarField(field, forBody: id) }
        #expect(
            drawsPastADroppedTriangle(service, id, baseline: baseline),
            "sanity check: the wipe drops a triangle ahead of one it draws")

        let live = try #require(body(service, id))
        try #require(live.triangleStyles.count == triangleCount(live), "sanity check: painted")
        let mismatched = (0..<triangleCount(live)).filter { triangle in
            let painted = Keys.key(paintedOn: live.triangleStyles[triangle]).map(Double.init)
            let reported = service.resolveFacePick(bodyID: id, triangleIndex: triangle)?
                .scalarValue
            return painted == nil || reported != painted
        }
        #expect(mismatched == [], "each listed triangle reports a value other than its paint")
    }

    // MARK: - The highlight a selection draws

    /// Selects each face in turn, by ordinal rather than through a pick, so this checks the
    /// highlight on its own.
    @MainActor
    @Test(
        "A face selected on a wiped body highlights exactly its drawn triangles",
        arguments: Target.allCases)
    func highlightCoversTheFacesDrawnTriangles(_ target: Target) throws {
        guard let service = CADViewportService.withBoxes(ids: ["ref", "cand"]) else { return }
        let id = target.id
        let baseline = try #require(body(service, id))
        service.setComparison(Self.wipe(at: 1))
        #expect(
            drawsPastADroppedTriangle(service, id, baseline: baseline),
            "sanity check: the wipe drops a triangle ahead of one it draws")
        let live = try #require(body(service, id))
        let table = try #require(service.faceIdentity[id])

        var highlightedFaces = 0
        for ordinal in 0..<6 {
            let shape = try #require(table.shape(forOrdinal: ordinal))
            let ref = SubShapeRef(
                shape: shape, uid: table.uid(forOrdinal: ordinal), ordinal: ordinal)
            let info = try #require(service.enrichFace(ref: ref, bodyID: id, triangleIndex: nil))
            service.select(.face(info), scheme: .replace)

            let drawnOnFace = (0..<triangleCount(live)).filter {
                face(shape, contains: centroid(of: $0, in: live))
            }
            let highlight = service.selectionBodies.first { $0.id == "selection_highlight_face" }
            let highlighted = highlight.map { body in
                (0..<triangleCount(body)).map { centroid(of: $0, in: body) }
            }
            if drawnOnFace.isEmpty {
                #expect(highlighted == nil, "face \(ordinal) draws nothing, so nothing is lit")
                continue
            }
            highlightedFaces += 1
            #expect(
                highlighted?.count == drawnOnFace.count,
                "face \(ordinal) lights as many triangles as it draws")
            #expect(
                highlighted?.allSatisfy { face(shape, contains: $0) } == true,
                "and every lit triangle lies on face \(ordinal)")
        }
        #expect(
            (1..<6).contains(highlightedFaces),
            "sanity check: some faces draw triangles and some draw none")
    }

    // MARK: - After the wipe changes

    @MainActor
    @Test(
        "A face pick stays right after the wipe is rebuilt or ended", arguments: Change.all)
    func pickAfterTheWipeChanges(_ change: Change) throws {
        guard let service = CADViewportService.withBoxes(ids: ["ref", "cand"]) else { return }
        let baselines = try Target.allCases.map { try #require(body(service, $0.id)) }
        service.setComparison(Self.wipe(at: 1))

        switch change {
        case .moveWipe:
            service.setComparison(Self.wipe(at: 0))
        case .setFieldDuringWipe:
            service.setScalarField(Keys.keyField(.perFace), forBody: "cand")
        case .recompute(let trigger):
            service.fire(trigger)
        case .clear:
            service.setComparison(nil)
        case .switchTo(let mode):
            service.setComparison(
                ComparisonView(referenceID: "ref", candidateID: "cand", mode: mode.comparisonMode))
        }

        for (target, baseline) in zip(Target.allCases, baselines) {
            if change.leavesWipe {
                #expect(
                    drawsPastADroppedTriangle(service, target.id, baseline: baseline),
                    "sanity check: \(target.id) is still wiped out of step")
            } else {
                #expect(
                    body(service, target.id)?.indices == baseline.indices,
                    "sanity check: \(target.id) is whole again")
            }
            expectEveryPickNamesItsFace(
                service, target.id, "each listed triangle resolved to a face it does not lie on")
        }
    }

    // MARK: - Neighbours

    /// Guard: passes without the fix.
    ///
    /// A wipe drops a body's edges and points, so an edge or vertex pick cannot land on it, and
    /// the resolvers read the live body, which agrees.
    @MainActor
    @Test(
        "Edge and vertex picks on a wiped body resolve to nothing, since a wipe draws neither",
        arguments: Target.allCases)
    func edgeAndVertexPicksFindNothingOnAWipedBody(_ target: Target) throws {
        guard let service = CADViewportService.withBoxes(ids: ["ref", "cand"]) else { return }
        let id = target.id
        service.selectionModes = [.face, .edge, .vertex]
        #expect(
            service.resolveEdgePick(bodyID: id, segmentIndex: 0) != nil,
            "sanity check: an edge picks before the wipe")
        #expect(
            service.resolveVertexPick(bodyID: id, pointIndex: 0) != nil,
            "sanity check: a vertex picks before the wipe")

        service.setComparison(Self.wipe(at: 1))
        let live = try #require(body(service, id))
        #expect(live.edges.isEmpty && live.vertices.isEmpty, "sanity check: none are drawn")
        #expect(service.resolveEdgePick(bodyID: id, segmentIndex: 0) == nil)
        #expect(service.resolveVertexPick(bodyID: id, pointIndex: 0) == nil)
    }
}
