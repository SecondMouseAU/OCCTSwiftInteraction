import Combine
import Foundation
import OCCTSwift
import OCCTSwiftAIS
import OCCTSwiftTools
import OCCTSwiftViewport
import Testing
import simd

@testable import OCCTSwiftCADKit

/// Regression coverage for OCCTSwiftInteraction#77: a cap recut gives a body a new mesh and new
/// identity tables, so the selection on it has to be remapped onto the new topology before its
/// highlight is cut again.
///
/// Every sub-shape is named by its world-space bounding box, never by an ordinal, because the
/// ordinals are what the recut renumbers. The body is a 4x4x4 box centred on the origin, and the
/// cap plane starts at X = 0 keeping the +X half: it cuts the +Y face in two, leaves the +X face
/// alone and removes the -X face. Moving it to X = 1 cuts again; removing it restores the box.
///
/// A selected sub-shape maps to its image on the new body: itself when the cut left it alone, its
/// pieces when the cut divided it, the whole sub-shape again when the cap goes, and nothing when
/// the cap removed it entirely (it leaves the selection). What the cut made (the cap face, an edge
/// or vertex where the plane crossed the box) maps to what the next cut of the same plane made
/// from the same source sub-shape, and to nothing once the cap goes.
///
/// Every test fails without the fix except the one marked "guard".
@Suite("Selection remapped when a cap recuts its body")
struct CapRecutSelectionTests {
    typealias Mode = ComparisonVisibilityTests.Mode
    typealias Target = ComparisonVisibilityTests.Target
    typealias Trigger = ComparisonVisibilityTests.Trigger
    typealias Geometry = HighlightGeometry

    // MARK: - Geometry

    /// An axis-aligned box naming a sub-shape by where it is.
    struct Box: Sendable, CustomStringConvertible {
        var min: SIMD3<Double>
        var max: SIMD3<Double>

        init(_ min: SIMD3<Double>, _ max: SIMD3<Double>) {
            self.min = min
            self.max = max
        }

        /// A vertex, whose box is a point.
        init(point: SIMD3<Double>) {
            self.init(point, point)
        }

        var description: String { "\(min)...\(max)" }

        /// Whether `shape` is the sub-shape this box names.
        ///
        /// An edge is named by its two ends, since its bounding box is padded by its mesh
        /// deflection; every edge here is a straight segment along an axis, so its ends are the
        /// box's corners.
        func matches(_ shape: Shape) -> Bool {
            func near(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Bool { simd_length(a - b) < 1e-4 }
            if shape.shapeType == .edge, let ends = Edge(shape)?.endpoints {
                return (near(ends.start, min) && near(ends.end, max))
                    || (near(ends.start, max) && near(ends.end, min))
            }
            guard let bounds = shape.bounds else { return false }
            return near(bounds.min, min) && near(bounds.max, max)
        }
    }

    enum Faces {
        static let plusY = Box(SIMD3(-2, 2, -2), SIMD3(2, 2, 2))
        /// The +Y face's piece the cap at X = 0 keeps.
        static let plusYFromZero = Box(SIMD3(0, 2, -2), SIMD3(2, 2, 2))
        /// The +Y face's piece the cap at X = 1 keeps.
        static let plusYFromOne = Box(SIMD3(1, 2, -2), SIMD3(2, 2, 2))
        static let plusX = Box(SIMD3(2, -2, -2), SIMD3(2, 2, 2))
        static let minusX = Box(SIMD3(-2, -2, -2), SIMD3(-2, 2, 2))
        static let capAtZero = Box(SIMD3(0, -2, -2), SIMD3(0, 2, 2))
        static let capAtOne = Box(SIMD3(1, -2, -2), SIMD3(1, 2, 2))
        static let plusZ = Box(SIMD3(-2, -2, 2), SIMD3(2, 2, 2))
        /// The +Z face's piece that caps at X = 0 and Y = 0 together keep.
        static let plusZQuarter = Box(SIMD3(0, 0, 2), SIMD3(2, 2, 2))
    }

    enum Edges {
        /// The edge along X where the +Y and +Z faces meet, which the cap at X = 0 cuts.
        static let alongX = Box(SIMD3(-2, 2, 2), SIMD3(2, 2, 2))
        static let alongXFromZero = Box(SIMD3(0, 2, 2), SIMD3(2, 2, 2))
        static let alongXFromOne = Box(SIMD3(1, 2, 2), SIMD3(2, 2, 2))
        /// An edge of the -X face, which the cap at X = 0 removes.
        static let onMinusX = Box(SIMD3(-2, 2, -2), SIMD3(-2, 2, 2))
        /// An edge of the +X face, which no cap here touches.
        static let onPlusX = Box(SIMD3(2, 2, -2), SIMD3(2, 2, 2))
        /// Where the cap at X = 0 crosses the +Y face.
        static let sectionAtZero = Box(SIMD3(0, 2, -2), SIMD3(0, 2, 2))
        static let sectionAtOne = Box(SIMD3(1, 2, -2), SIMD3(1, 2, 2))
    }

    enum Vertices {
        static let kept = Box(point: SIMD3(2, 2, 2))
        static let removed = Box(point: SIMD3(-2, 2, 2))
        /// Where the cap at X = 0 crosses the edge along X.
        static let sectionAtZero = Box(point: SIMD3(0, 2, 2))
        static let sectionAtOne = Box(point: SIMD3(1, 2, 2))
    }

    // MARK: - Dimensions

    enum Kind: Sendable, CustomTestStringConvertible {
        case face
        case edge
        case vertex

        var testDescription: String {
            switch self {
            case .face: "face"
            case .edge: "edge"
            case .vertex: "vertex"
            }
        }
    }

    /// What happens to the cap after the selection is made.
    enum Transition: Sendable, CustomTestStringConvertible {
        /// Selected on the uncut box, then the cap at X = 0 is added.
        case apply
        /// Selected with the cap at X = 0, then the cap moves to X = 1.
        case move
        /// Selected with the cap at X = 0, then the cap is removed.
        case remove

        var testDescription: String {
            switch self {
            case .apply: "cap applied"
            case .move: "cap moved"
            case .remove: "cap removed"
            }
        }
    }

    /// Whether a comparison is active while the cap changes, and which side is selected.
    enum Setting: Sendable, CustomTestStringConvertible {
        case alone
        case comparison(Mode, Target)

        static let all: [Setting] =
            [.alone]
            + Mode.allCases.flatMap { mode in Target.allCases.map { .comparison(mode, $0) } }

        var testDescription: String {
            switch self {
            case .alone: "no comparison"
            case .comparison(let mode, let target):
                "during \(mode.testDescription), on \(target.testDescription)"
            }
        }

        var bodyID: String {
            switch self {
            case .alone: "ref"
            case .comparison(_, let target): target.id
            }
        }
    }

    struct RemapCase: Sendable, CustomTestStringConvertible {
        var kind: Kind
        var transition: Transition
        var selected: Box
        var expected: [Box]
        var label: String

        var testDescription: String {
            "\(kind.testDescription) \(label), \(transition.testDescription)"
        }

        static let faces: [RemapCase] = [
            RemapCase(
                kind: .face, transition: .apply, selected: Faces.plusY,
                expected: [Faces.plusYFromZero], label: "the cut divides"),
            RemapCase(
                kind: .face, transition: .apply, selected: Faces.plusX, expected: [Faces.plusX],
                label: "the cut leaves alone"),
            RemapCase(
                kind: .face, transition: .apply, selected: Faces.minusX, expected: [],
                label: "the cap removes"),
            RemapCase(
                kind: .face, transition: .move, selected: Faces.plusYFromZero,
                expected: [Faces.plusYFromOne], label: "piece of a cut face"),
            RemapCase(
                kind: .face, transition: .move, selected: Faces.capAtZero,
                expected: [Faces.capAtOne], label: "the cap face"),
            RemapCase(
                kind: .face, transition: .move, selected: Faces.plusX, expected: [Faces.plusX],
                label: "neither cut touches"),
            RemapCase(
                kind: .face, transition: .remove, selected: Faces.plusYFromZero,
                expected: [Faces.plusY], label: "piece of a cut face"),
            RemapCase(
                kind: .face, transition: .remove, selected: Faces.plusX, expected: [Faces.plusX],
                label: "the cut left alone"),
            RemapCase(
                kind: .face, transition: .remove, selected: Faces.capAtZero, expected: [],
                label: "the cap face"),
        ]

        static let pointsAndLines: [RemapCase] = [
            RemapCase(
                kind: .edge, transition: .apply, selected: Edges.alongX,
                expected: [Edges.alongXFromZero], label: "the cut divides"),
            RemapCase(
                kind: .edge, transition: .apply, selected: Edges.onPlusX,
                expected: [Edges.onPlusX], label: "the cut leaves alone"),
            RemapCase(
                kind: .edge, transition: .apply, selected: Edges.onMinusX, expected: [],
                label: "the cap removes"),
            RemapCase(
                kind: .edge, transition: .move, selected: Edges.alongXFromZero,
                expected: [Edges.alongXFromOne], label: "piece of a cut edge"),
            RemapCase(
                kind: .edge, transition: .move, selected: Edges.sectionAtZero,
                expected: [Edges.sectionAtOne], label: "where the plane crosses a face"),
            RemapCase(
                kind: .edge, transition: .remove, selected: Edges.alongXFromZero,
                expected: [Edges.alongX], label: "piece of a cut edge"),
            RemapCase(
                kind: .edge, transition: .remove, selected: Edges.sectionAtZero, expected: [],
                label: "where the plane crosses a face"),
            RemapCase(
                kind: .vertex, transition: .apply, selected: Vertices.kept,
                expected: [Vertices.kept], label: "the cut leaves alone"),
            RemapCase(
                kind: .vertex, transition: .apply, selected: Vertices.removed, expected: [],
                label: "the cap removes"),
            RemapCase(
                kind: .vertex, transition: .move, selected: Vertices.sectionAtZero,
                expected: [Vertices.sectionAtOne], label: "where the plane crosses an edge"),
            RemapCase(
                kind: .vertex, transition: .remove, selected: Vertices.sectionAtZero,
                expected: [], label: "where the plane crosses an edge"),
            RemapCase(
                kind: .vertex, transition: .remove, selected: Vertices.kept,
                expected: [Vertices.kept], label: "the cut left alone"),
        ]
    }

    // MARK: - Helpers

    /// Two boxes, `ref` and `cand`, with the comparison `setting` names applied.
    @MainActor
    private static func service(_ setting: Setting) -> CADViewportService? {
        guard let service = CADViewportService.withBoxes(ids: ["ref", "cand"]) else { return nil }
        if case .comparison(let mode, _) = setting {
            service.setComparison(
                ComparisonView(referenceID: "ref", candidateID: "cand", mode: mode.comparisonMode))
        }
        return service
    }

    /// Selects `selected` with the cap where `transition` starts, then runs `transition`.
    @MainActor
    private static func run(
        _ transition: Transition, on service: CADViewportService, selecting selected: Box,
        _ kind: Kind, ofBody id: String
    ) throws {
        let planeID: String? = transition == .apply ? nil : service.addHalfCap()
        let ref = try #require(
            service.ref(kind, ofBody: id, at: selected), "sanity check: \(selected) exists")
        service.selectSub(kind, ref, ofBody: id)
        try #require(service.interactiveContext.selection.count == 1, "sanity check: selected")
        switch transition {
        case .apply:
            service.addHalfCap()
        case .move:
            let index = try #require(service.clippingPlanes.firstIndex { $0.id == planeID })
            service.clippingPlanes[index].origin = SIMD3(1, 0, 0)
        case .remove:
            service.removeClippingPlane(id: try #require(planeID))
        }
    }

    /// Expects the selection of `kind` on body `id` to name exactly the sub-shapes at `expected`, each
    /// through the ordinal and uid the body's current identity table gives it.
    @MainActor
    private static func expectSelection(
        _ service: CADViewportService, _ kind: Kind, ofBody id: String, names expected: [Box],
        _ step: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let refs = service.selected(kind, ofBody: id)
        let named = refs.map { ref in expected.firstIndex { $0.matches(ref.shape) } }
        #expect(
            refs.count == expected.count && Set(named.compactMap { $0 }).count == expected.count,
            """
            \(step): the selection should name \(expected), but names \
            \(refs.map { $0.shape.bounds.map { "\($0.min)...\($0.max)" } ?? "nothing" })
            """,
            sourceLocation: sourceLocation)
        guard let table = service.identityTable(kind, ofBody: id) else {
            Issue.record("\(step): body \(id) has no \(kind) table", sourceLocation: sourceLocation)
            return
        }
        for ref in refs {
            let current =
                table.shapes.indices.contains(ref.ordinal) ? table.shapes[ref.ordinal] : nil
            #expect(
                current?.isSame(as: ref.shape) == true,
                "\(step): ordinal \(ref.ordinal) should name the selected \(kind) in the new table",
                sourceLocation: sourceLocation)
            let uid = table.uids.flatMap {
                $0.indices.contains(ref.ordinal) ? $0[ref.ordinal] : nil
            }
            #expect(
                uid != nil && ref.uid == uid,
                "\(step): the uid should be the new graph's, the one the table gives the ordinal",
                sourceLocation: sourceLocation)
        }
    }

    /// Expects the highlight of `kind` on body `id` to light exactly the sub-shapes at `expected`,
    /// as the body draws them now.
    @MainActor
    private static func expectHighlight(
        _ service: CADViewportService, _ kind: Kind, ofBody id: String, lights expected: [Box],
        _ step: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let refs = expected.compactMap { service.ref(kind, ofBody: id, at: $0) }
        guard refs.count == expected.count else {
            Issue.record(
                "\(step): sanity check: every expected \(kind) exists",
                sourceLocation: sourceLocation)
            return
        }
        switch kind {
        case .face:
            expectFaceHighlight(
                service, lights: refs.map { (bodyID: id, face: $0) }, step,
                sourceLocation: sourceLocation)
        case .edge:
            guard let body = service.modelBody(id) else { return }
            let drawn = refs.flatMap { Geometry.worldEndpoints(ofEdge: $0.ordinal, in: body) }
            let lit = Geometry.worldPoints(of: service.selectionHighlight("edge"))
            let (missing, extra) = Geometry.unpaired(drawn, lit)
            #expect(
                missing.isEmpty && extra.isEmpty,
                "\(step): the edge highlight should light the selected edges where they are drawn",
                sourceLocation: sourceLocation)
        case .vertex:
            let drawn = expected.map(\.min)
            let lit = Geometry.worldPoints(of: service.selectionHighlight("vertex"))
            let (missing, extra) = Geometry.unpaired(drawn, lit)
            #expect(
                missing.isEmpty && extra.isEmpty,
                "\(step): the vertex highlight should light exactly the selected vertices",
                sourceLocation: sourceLocation)
        }
    }

    // MARK: - Faces

    @MainActor
    @Test(
        "A selected face maps to its image when the cap is applied, moved or removed",
        arguments: Setting.all, RemapCase.faces)
    func faceFollowsTheRecut(_ setting: Setting, _ testCase: RemapCase) throws {
        guard let service = Self.service(setting) else { return }
        let id = setting.bodyID
        try Self.run(
            testCase.transition, on: service, selecting: testCase.selected, .face, ofBody: id)
        Self.expectSelection(service, .face, ofBody: id, names: testCase.expected, "after")
        Self.expectHighlight(service, .face, ofBody: id, lights: testCase.expected, "after")
    }

    // MARK: - Edges and vertices

    @MainActor
    @Test(
        "A selected edge or vertex maps to its image when the cap is applied, moved or removed",
        arguments: RemapCase.pointsAndLines)
    func edgeOrVertexFollowsTheRecut(_ testCase: RemapCase) throws {
        guard let service = Self.service(.alone) else { return }
        service.selectionModes = [.face, .edge, .vertex]
        try Self.run(
            testCase.transition, on: service, selecting: testCase.selected, testCase.kind,
            ofBody: "ref")
        Self.expectSelection(
            service, testCase.kind, ofBody: "ref", names: testCase.expected, "after")
        Self.expectHighlight(
            service, testCase.kind, ofBody: "ref", lights: testCase.expected, "after")
    }

    // MARK: - Several planes

    @MainActor
    @Test("A face cut by two cap planes maps to the piece both keep, and back to itself")
    func faceFollowsTwoPlanes() throws {
        guard let service = Self.service(.alone) else { return }
        let face = try #require(service.ref(.face, ofBody: "ref", at: Faces.plusZ))
        service.selectSub(.face, face, ofBody: "ref")

        service.addHalfCap()
        let second = service.addClippingPlane(
            origin: .zero, normal: SIMD3(0, 1, 0), showCapSurface: true)
        Self.expectSelection(service, .face, ofBody: "ref", names: [Faces.plusZQuarter], "two caps")
        Self.expectHighlight(
            service, .face, ofBody: "ref", lights: [Faces.plusZQuarter], "two caps")

        service.clippingPlanes = service.clippingPlanes.filter { $0.id == second }
        Self.expectSelection(
            service, .face, ofBody: "ref", names: [Box(SIMD3(-2, 0, 2), SIMD3(2, 2, 2))],
            "first cap removed")

        service.clippingPlanes = []
        Self.expectSelection(service, .face, ofBody: "ref", names: [Faces.plusZ], "both removed")
        Self.expectHighlight(service, .face, ofBody: "ref", lights: [Faces.plusZ], "both removed")
    }

    // MARK: - What the selection reports

    #if os(macOS)
        @MainActor
        @Test("selection and selection.json report the new ordinal and uid after a recut")
        func projectionAndSidecarReportTheNewIdentity() throws {
            guard let service = Self.service(.alone) else { return }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "cap-recut-selection-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            try service.startSelectionSidecar(directory: dir)
            defer { service.stopSelectionSidecar() }

            let face = try #require(service.ref(.face, ofBody: "ref", at: Faces.plusY))
            service.selectSub(.face, face, ofBody: "ref")
            service.addHalfCap()

            let piece = try #require(service.ref(.face, ofBody: "ref", at: Faces.plusYFromZero))
            guard service.selection.count == 1, case .face(let info) = service.selection[0] else {
                Issue.record("expected one selected face, got \(service.selection)")
                return
            }
            #expect(info.faceIndex == piece.ordinal, "faceIndex is the piece's new ordinal")
            #expect(info.uid != nil && info.uid == piece.uid, "uid is the new graph's")
            #expect(abs(info.area - 8) < 1e-6, "area is the piece's, half the 16 of the whole face")

            let data = try #require(
                FileManager.default.contents(
                    atPath: dir.appendingPathComponent("selection.json").path))
            let document = try JSONDecoder().decode(SelectionSidecarDocument.self, from: data)
            #expect(document.selections.count == 1)
            #expect(document.selections.first?.index == piece.ordinal, "index is the new ordinal")
            #expect(
                document.selections.first?.uid == piece.uid?.wireString,
                "uid is the new graph's")
        }
    #endif

    @MainActor
    @Test("A recut publishes one change per recut body that had a selection, as bodyRecut")
    func recutPublishesBodyRecut() throws {
        guard let service = Self.service(.alone) else { return }
        let face = try #require(service.ref(.face, ofBody: "ref", at: Faces.plusY))
        service.selectSub(.face, face, ofBody: "ref")
        var changes: [SelectionChange] = []
        let subscription = service.selectionChanges.sink { changes.append($0) }
        defer { subscription.cancel() }

        // Recuts both boxes; only `ref` has anything selected.
        let planeID = service.addHalfCap()
        #expect(changes.map(\.source) == [.bodyRecut(bodyID: "ref")], "cap applied")
        #expect(changes.last?.current == service.selection)

        changes = []
        service.removeClippingPlane(id: planeID)
        #expect(changes.map(\.source) == [.bodyRecut(bodyID: "ref")], "cap removed")
    }

    // MARK: - Agent highlight

    @MainActor
    @Test("A face the agent highlighted keeps the agent's highlight through a recut")
    func agentHighlightSurvivesTheRecut() throws {
        guard let service = Self.service(.alone) else { return }
        let face = try #require(service.ref(.face, ofBody: "ref", at: Faces.plusY))
        service.selectSub(.face, face, ofBody: "ref")
        service.agentHighlightedEntities = service.selection
        service.refreshSelectionBodies()

        service.addHalfCap()

        #expect(
            !service.selection.isEmpty && service.agentHighlightedEntities == service.selection,
            "the remapped face is still tagged as the agent's")
        let piece = try #require(service.ref(.face, ofBody: "ref", at: Faces.plusYFromZero))
        let drawn = service.modelBody("ref").map {
            Geometry.worldCentroids(onFace: piece.shape, of: $0)
        }
        let lit = service.selectionBodies.first { $0.id == "agent_highlight_face" }.map(
            Geometry.worldCentroids(of:))
        let (missing, extra) = Geometry.unpaired(drawn ?? [], lit ?? [])
        #expect(
            drawn?.isEmpty == false && missing.isEmpty && extra.isEmpty,
            "the agent's highlight lights the piece")
        #expect(service.selectionHighlight("face") == nil, "nothing is lit as an ordinary pick")
    }

    // MARK: - The cut itself

    /// A shape and a plane to cut it with, for holding the cap's own split to
    /// `Shape.split(atPlane:normal:)`.
    enum SplitCase: CaseIterable, Sendable, CustomTestStringConvertible {
        case boxCutThrough
        case boxMissed
        case boxCutAtAnAngle
        case boxPlaneOnAFace
        case solidsInACompound
        case shell
        case loneFace

        var testDescription: String {
            switch self {
            case .boxCutThrough: "a box, cut through"
            case .boxMissed: "a box, a plane that misses it"
            case .boxCutAtAnAngle: "a box, a plane at an angle"
            case .boxPlaneOnAFace: "a box, a plane on one of its faces"
            case .solidsInACompound: "three solids in a compound, cut across two of them"
            case .shell: "a shell, cut through"
            case .loneFace: "a lone face, cut through"
            }
        }

        var plane: (origin: SIMD3<Double>, normal: SIMD3<Double>) {
            switch self {
            case .boxCutThrough, .shell, .loneFace: (.zero, SIMD3(1, 0, 0))
            case .boxMissed: (SIMD3(10, 0, 0), SIMD3(1, 0, 0))
            case .boxCutAtAnAngle: (.zero, simd_normalize(SIMD3(1, 1, 0)))
            case .boxPlaneOnAFace: (SIMD3(0, 0, 2), SIMD3(0, 0, 1))
            case .solidsInACompound: (SIMD3(0, 2, 0), SIMD3(0, 1, 0))
            }
        }

        func shape() -> Shape? {
            guard let box = Shape.box(width: 4, height: 4, depth: 4) else { return nil }
            switch self {
            case .boxCutThrough, .boxMissed, .boxCutAtAnAngle, .boxPlaneOnAFace:
                return box
            case .solidsInACompound:
                // `fuseAll` (a general fuse) of touching boxes leaves three solids in a compound.
                guard let base = Shape.box(width: 6, height: 2, depth: 2),
                    let prong = Shape.box(width: 2, height: 4, depth: 2),
                    let left = prong.translated(by: SIMD3(-2, 3, 0)),
                    let right = prong.translated(by: SIMD3(2, 3, 0))
                else { return nil }
                return Shape.fuseAll([base, left, right])
            case .shell:
                return box.subShapes(ofType: .shell).first
            case .loneFace:
                return box.faces().first.flatMap(Shape.fromFace)
            }
        }
    }

    /// The cap repeats the OCCT calls of `Shape.split(atPlane:normal:)` to keep the history, so
    /// after an OCCTSwift bump this is what notices the two diverging.
    @MainActor
    @Test(
        "The cap's split gives the pieces Shape.split(atPlane:normal:) gives, in order",
        arguments: SplitCase.allCases)
    func capSplitMatchesUpstreamSplit(_ testCase: SplitCase) throws {
        let shape = try #require(testCase.shape())
        let (origin, normal) = testCase.plane
        let upstream = try #require(shape.split(atPlane: origin, normal: normal))
        let ours = try #require(
            CADViewportService().split(shape, atPlane: origin, normal: normal, planeID: "p")
        ).pieces

        // Rounded, since the first split can raise the tolerances of the input both splits share.
        func summary(_ piece: Shape) -> String {
            let box = piece.bounds.map { bounds in
                [bounds.min, bounds.max].map { point in
                    [point.x, point.y, point.z].map { String(format: "%.3f", $0) }
                        .joined(separator: " ")
                }
                .joined(separator: " ... ")
            }
            return "\(piece.shapeType) \(piece.faces().count) faces \(box ?? "no bounds")"
        }
        #expect(ours.map(summary) == upstream.map(summary))
    }

    // MARK: - Unrelated recomputes

    /// Guard: passes without the fix.
    ///
    /// A recompute that leaves a capped body's cut as it was does not recut it (#45), so it must
    /// not touch the selection on it either.
    @MainActor
    @Test(
        "A recompute that does not recut the body leaves its selection alone",
        arguments: Trigger.allCases)
    func unrelatedRecomputeLeavesTheSelection(_ trigger: Trigger) throws {
        guard let service = Self.service(.alone) else { return }
        service.addHalfCap()
        let piece = try #require(service.ref(.face, ofBody: "ref", at: Faces.plusYFromZero))
        service.selectSub(.face, piece, ofBody: "ref")
        let before = service.selection
        var changes: [SelectionChange] = []
        let subscription = service.selectionChanges.sink { changes.append($0) }
        defer { subscription.cancel() }

        service.fire(trigger)

        #expect(changes.isEmpty, "no selection change is published")
        #expect(service.selection == before)
        Self.expectSelection(service, .face, ofBody: "ref", names: [Faces.plusYFromZero], "after")
    }
}

@MainActor
extension CADViewportService {
    /// The identity table for `kind` of body `id`, as shapes and uids.
    fileprivate func identityTable(_ kind: CapRecutSelectionTests.Kind, ofBody id: String)
        -> (shapes: [Shape?], uids: [BRepGraph.GraphUID?]?)?
    {
        switch kind {
        case .face: faceIdentity[id].map { ($0.shapes, $0.uids) }
        case .edge: edgeIdentity[id].map { ($0.shapes, $0.uids) }
        case .vertex: vertexIdentity[id].map { ($0.shapes.map(Optional.some), $0.uids) }
        }
    }

    /// The sub-shape of `kind` on body `id` whose bounding box is `box`, as the current table
    /// names it.
    fileprivate func ref(
        _ kind: CapRecutSelectionTests.Kind, ofBody id: String, at box: CapRecutSelectionTests.Box
    ) -> SubShapeRef? {
        guard let table = identityTable(kind, ofBody: id) else { return nil }
        for ordinal in table.shapes.indices {
            guard let shape = table.shapes[ordinal], box.matches(shape) else { continue }
            return SubShapeRef(shape: shape, uid: table.uids?[ordinal], ordinal: ordinal)
        }
        return nil
    }

    /// The refs of `kind` selected on body `id`, read from the interactive context.
    fileprivate func selected(_ kind: CapRecutSelectionTests.Kind, ofBody id: String)
        -> [SubShapeRef]
    {
        guard let objectID = bodyObjectIDs[id] else { return [] }
        return interactiveContext.selection.subshapes.compactMap { subShape in
            guard subShape.object.id == objectID else { return nil }
            switch (kind, subShape) {
            case (.face, .face(_, let ref)), (.edge, .edge(_, let ref)),
                (.vertex, .vertex(_, let ref)):
                return ref
            default:
                return nil
            }
        }
    }

    /// Selects `ref`, a sub-shape of `kind` on body `id`, as a selection made without a pick.
    fileprivate func selectSub(
        _ kind: CapRecutSelectionTests.Kind, _ ref: SubShapeRef, ofBody id: String
    ) {
        let entity: PickedEntity?
        switch kind {
        case .face: entity = enrichFace(ref: ref, bodyID: id, triangleIndex: nil).map { .face($0) }
        case .edge: entity = enrichEdge(ref: ref, bodyID: id).map { .edge($0) }
        case .vertex:
            entity = enrichVertex(ref: ref, bodyID: id, renderPosition: nil).map { .vertex($0) }
        }
        guard let entity else {
            Issue.record("\(kind) \(ref.ordinal) of \(id) did not enrich")
            return
        }
        select(entity, scheme: .replace)
    }
}
