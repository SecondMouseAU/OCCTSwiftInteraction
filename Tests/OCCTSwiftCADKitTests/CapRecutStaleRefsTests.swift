import Combine
import Foundation
import OCCTSwift
import OCCTSwiftAIS
import OCCTSwiftTools
import Testing
import simd

@testable import OCCTSwiftCADKit

/// Regression coverage for OCCTSwiftInteraction#85: what still named a body's old sub-shapes after
/// a cap recut once the selection itself followed it (#77).
///
/// - **The agent's attention marker** (`agentAttention`) is carried onto the image of the entity
///   it holds. With no image it is cleared, label and all, as when its body is removed. A
///   sub-shape the cut divides leaves it on the piece with the lowest ordinal, since the marker
///   holds one entity.
/// - **A pending escalation's `entities`** are each replaced by their images, as a selected
///   sub-shape is. One with no image leaves `entities`; the escalation itself stays pending and
///   answerable, because a cap changes what is drawn, not the model.
/// - **On a body without a graph**, refs compare by ordinal, so an image at the old ordinal
///   compared equal to the entity it replaced and `selection` kept the old shape and area.
///
/// The geometry and the names are `CapRecutSelectionTests`'s: a 4x4x4 box centred on the origin,
/// cut at X = 0 keeping the +X half, and every sub-shape named by where it is, never by an ordinal.
///
/// Every test fails without the fix except the one marked "guard".
@Suite("Agent marker, escalation and graphless details follow a cap recut")
struct CapRecutStaleRefsTests {
    typealias Box = CapRecutSelectionTests.Box
    typealias Faces = CapRecutSelectionTests.Faces
    typealias Kind = CapRecutSelectionTests.Kind
    typealias RemapCase = CapRecutSelectionTests.RemapCase
    typealias Recut = CapRecutSelectionTests

    /// Every case `CapRecutSelectionTests` holds the selection to, faces, edges and vertices.
    static let cases = RemapCase.faces + RemapCase.pointsAndLines

    // MARK: - Geometry

    /// A 6x6x4 block centred on the origin with a slot 2 wide cut from Y = -1 out through +Y, so its
    /// +Z face is one U-shaped face. `slotCap` keeps Y >= 1, the two prongs' tips, and divides that
    /// face into two pieces.
    enum Slotted {
        static let top = Box(SIMD3(-3, -3, 2), SIMD3(3, 3, 2))
        static let leftTip = Box(SIMD3(-3, 1, 2), SIMD3(-1, 3, 2))
        static let rightTip = Box(SIMD3(1, 1, 2), SIMD3(3, 3, 2))

        static func shape() -> Shape? {
            guard
                let block = Shape.box(
                    origin: SIMD3(-3, -3, -2), width: 6, height: 6, depth: 4),
                let slot = Shape.box(origin: SIMD3(-1, -1, -3), width: 2, height: 5, depth: 6)
            else { return nil }
            return block.subtracting(slot)
        }
    }

    /// A service holding the slotted block as body `"slotted"`, or `nil` if the kernel cannot make
    /// it.
    @MainActor
    static func slottedService() -> CADViewportService? {
        guard let shape = Slotted.shape() else {
            Issue.record("the slotted block did not build")
            return nil
        }
        let service = CADViewportService()
        service.load(shape, id: "slotted")
        return service
    }

    /// The pieces the cut at Y = 1 divides the slotted block's +Z face into, each with the ref the
    /// current table gives it.
    @MainActor
    static func tips(of service: CADViewportService) -> [(box: Box, ref: SubShapeRef)] {
        [Slotted.leftTip, Slotted.rightTip].compactMap { box in
            service.ref(.face, ofBody: "slotted", at: box).map { (box, $0) }
        }
    }

    // MARK: - The agent's attention marker

    @MainActor
    @Test(
        "The attention marker follows the recut, and is cleared when it has no image",
        arguments: cases)
    func attentionFollowsTheRecut(_ testCase: RemapCase) throws {
        guard let service = CADViewportService.withBoxes(ids: ["ref", "cand"]) else { return }
        let planeID = Recut.start(testCase.transition, on: service)
        let entity = try #require(
            service.entity(testCase.kind, ofBody: "ref", at: testCase.selected),
            "sanity check: \(testCase.selected) exists")
        service.setAgentAttention(entity, label: "this one")

        try Recut.finish(testCase.transition, on: service, planeID: planeID)

        if testCase.expected.isEmpty {
            #expect(service.agentAttention == nil, "nothing on the body is the marker's image")
            #expect(service.agentAttentionLabel == nil, "the label goes with the marker")
        } else {
            Recut.expectRefs(
                service.agentAttention.map { [$0.ref] } ?? [], "the marker", in: service,
                testCase.kind, ofBody: "ref", names: testCase.expected, "after")
            #expect(service.agentAttentionLabel == "this one", "the label stays with the marker")
        }
        #expect(service.selection.isEmpty, "the marker moves without touching the selection")
    }

    @MainActor
    @Test("A marker on a face the cut divides stays on the piece with the lowest ordinal")
    func attentionOnADividedFace() throws {
        guard let service = Self.slottedService() else { return }
        let top = try #require(service.entity(.face, ofBody: "slotted", at: Slotted.top))
        service.setAgentAttention(top, label: "this face")

        service.addClippingPlane(origin: SIMD3(0, 1, 0), normal: SIMD3(0, 1, 0))

        let tips = Self.tips(of: service)
        try #require(tips.count == 2, "sanity check: the cut divides the face in two")
        let lowest = try #require(tips.min { $0.ref.ordinal < $1.ref.ordinal })
        Recut.expectRefs(
            service.agentAttention.map { [$0.ref] } ?? [], "the marker", in: service, .face,
            ofBody: "slotted", names: [lowest.box], "after")
        #expect(service.agentAttentionLabel == "this face")
    }

    #if os(macOS)
        /// The bridge's own view of the marker: `remove` clears it only when the request resolves
        /// to the entity it holds, and a request resolves against the body as it is drawn now.
        @MainActor
        @Test("After a recut, an attention remove naming the image's index clears the marker")
        func attentionRemoveMatchesAfterTheRecut() throws {
            guard let service = CADViewportService.withBoxes(ids: ["ref"]) else { return }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "cap-recut-attention-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            try service.startSelectionSidecar(directory: dir)
            defer { service.stopSelectionSidecar() }

            let face = try #require(service.ref(.face, ofBody: "ref", at: Faces.plusY))
            try Self.post(
                HighlightRequestPayload(
                    id: "point", bodyId: "ref", kind: "face", index: face.ordinal,
                    scheme: "replace"),
                in: dir, to: service)
            try #require(service.agentAttention != nil, "sanity check: the marker is set")

            service.addHalfCap()
            let piece = try #require(service.ref(.face, ofBody: "ref", at: Faces.plusYFromZero))
            let outcome = try Self.post(
                HighlightRequestPayload(
                    id: "unpoint", bodyId: "ref", kind: "face", index: piece.ordinal,
                    scheme: "remove"),
                in: dir, to: service)

            #expect(outcome.outcome == "applied")
            #expect(service.agentAttention == nil, "the marker named the piece, so it is cleared")
        }

        /// Writes `payload` as a highlight request, has `service` process it, and returns the
        /// outcome it recorded.
        @MainActor
        @discardableResult
        static func post(
            _ payload: HighlightRequestPayload, in dir: URL, to service: CADViewportService
        ) throws -> HandledOutcome {
            let url = CADViewportService.highlightRequestsDirectory(in: dir)
                .appendingPathComponent("\(payload.id).json")
            try JSONEncoder().encode(payload).write(to: url, options: .atomic)
            service.processHighlightRequests()
            let handled = CADViewportService.handledDirectory(in: dir)
                .appendingPathComponent("\(payload.id).json")
            let data = try #require(FileManager.default.contents(atPath: handled.path))
            return try JSONDecoder().decode(HandledOutcome.self, from: data)
        }
    #endif

    // MARK: - A pending escalation

    @MainActor
    @Test(
        "A pending escalation's entities follow the recut, and one with no image leaves them",
        arguments: cases)
    func escalationFollowsTheRecut(_ testCase: RemapCase) throws {
        guard let service = CADViewportService.withBoxes(ids: ["ref", "cand"]) else { return }
        let planeID = Recut.start(testCase.transition, on: service)
        let entity = try #require(
            service.entity(testCase.kind, ofBody: "ref", at: testCase.selected),
            "sanity check: \(testCase.selected) exists")
        let request = EscalationRequest(
            id: "which", entities: [entity], question: "This one?",
            candidates: [EscalationCandidate(id: "yes", label: "Yes")], context: ["k": "v"])
        service.beginPresenting(request)

        try Recut.finish(testCase.transition, on: service, planeID: planeID)

        let pending = try #require(service.pendingEscalation, "the escalation stays pending")
        #expect(pending.id == request.id && pending.question == request.question)
        #expect(pending.candidates == request.candidates && pending.context == request.context)
        Recut.expectRefs(
            pending.entities.map(\.ref), "the escalation", in: service, testCase.kind,
            ofBody: "ref", names: testCase.expected, "after")
    }

    @MainActor
    @Test("An escalation entity on a face the cut divides becomes both pieces")
    func escalationOnADividedFace() throws {
        guard let service = Self.slottedService() else { return }
        let top = try #require(service.entity(.face, ofBody: "slotted", at: Slotted.top))
        service.beginPresenting(EscalationRequest(id: "which", entities: [top], question: "?"))

        service.addClippingPlane(origin: SIMD3(0, 1, 0), normal: SIMD3(0, 1, 0))

        let entities = try #require(service.pendingEscalation?.entities)
        Recut.expectRefs(
            entities.map(\.ref), "the escalation", in: service, .face, ofBody: "slotted",
            names: [Slotted.leftTip, Slotted.rightTip], "after")
    }

    @MainActor
    @Test("An escalation whose entity the cap removes stays pending and answerable")
    func escalationWithNoImageIsStillAnswerable() async throws {
        guard let service = CADViewportService.withBoxes(ids: ["ref"]) else { return }
        let face = try #require(service.entity(.face, ofBody: "ref", at: Faces.minusX))
        let request = EscalationRequest(id: "which", entities: [face], question: "This one?")
        let answer = Task { @MainActor in await service.present(request) }
        await Task.yield()
        try #require(service.pendingEscalation?.id == "which", "sanity check: presented")

        service.addHalfCap()

        #expect(service.pendingEscalation?.id == "which", "still pending")
        #expect(service.pendingEscalation?.entities.isEmpty == true, "naming nothing")
        service.respond(.deferred)
        let response = await answer.value
        #expect(response == .deferred, "the caller gets the answer")
        #expect(service.pendingEscalation == nil)
    }

    // MARK: - Order

    @MainActor
    @Test("A subscriber to the recut's selection change finds the marker and escalation remapped")
    func markerAndEscalationAreRemappedBeforeTheChange() throws {
        guard let service = CADViewportService.withBoxes(ids: ["ref"]) else { return }
        let plusY = try #require(service.entity(.face, ofBody: "ref", at: Faces.plusY))
        let plusX = try #require(service.entity(.face, ofBody: "ref", at: Faces.plusX))
        service.beginPresenting(EscalationRequest(id: "which", entities: [plusY], question: "?"))
        service.setAgentAttention(plusX)
        var seen: [(escalation: [PickedEntity]?, attention: PickedEntity?)] = []
        let subscription = service.selectionChanges.sink { _ in
            seen.append((service.pendingEscalation?.entities, service.agentAttention))
        }
        defer { subscription.cancel() }

        service.addHalfCap()

        try #require(seen.count == 1, "sanity check: one change for the one recut body")
        Recut.expectRefs(
            seen[0].escalation?.map(\.ref) ?? [], "the escalation the subscriber saw", in: service,
            .face, ofBody: "ref", names: [Faces.plusYFromZero], "during the change")
        Recut.expectRefs(
            seen[0].attention.map { [$0.ref] } ?? [], "the marker the subscriber saw", in: service,
            .face, ofBody: "ref", names: [Faces.plusX], "during the change")
    }

    // MARK: - A body without a graph

    /// Reaches a body without a graph through a seam, since no public API makes one.
    ///
    /// The cap is moved through the public path, which recuts the body with a graph; then the new
    /// tables lose their uids, the selection is put back as it stood before the move, and the remap
    /// runs again on the graphless tables, as `updateCapSurfaces()` would have run it.
    @MainActor
    @Test("On a body without a graph, the selection reports the image's details at the old ordinal")
    func graphlessSelectionIsReEnriched() throws {
        guard let service = CADViewportService.withBoxes(ids: ["ref"]) else { return }
        let planeID = service.addHalfCap()
        service.dropGraph(ofBody: "ref")
        let piece = try #require(service.ref(.face, ofBody: "ref", at: Faces.plusYFromZero))
        service.selectSub(.face, piece, ofBody: "ref")
        let stale = try #require(service.selection.first, "sanity check: selected")
        let before = try #require(service.capRecutIdentity(ofBody: "ref"))

        let index = try #require(service.clippingPlanes.firstIndex { $0.id == planeID })
        service.clippingPlanes[index].origin = SIMD3(1, 0, 0)
        service.dropGraph(ofBody: "ref")
        service.select(stale, scheme: .replace)
        let image = try #require(service.ref(.face, ofBody: "ref", at: Faces.plusYFromOne))
        try #require(
            image.ordinal == piece.ordinal,
            "sanity check: the image keeps the old ordinal, which is the case this covers")
        var changes: [SelectionChange] = []
        let subscription = service.selectionChanges.sink { changes.append($0) }
        defer { subscription.cancel() }

        service.remapSelection(acrossRecutOf: ["ref": before])

        Recut.expectRefs(
            service.selection.map(\.ref), "selection", in: service, .face, ofBody: "ref",
            names: [Faces.plusYFromOne], "after")
        guard case .face(let info)? = service.selection.first else {
            Issue.record("expected one selected face, got \(service.selection)")
            return
        }
        #expect(abs(info.area - 4) < 1e-6, "the area is the image's, not the 8 of the old piece")
        #expect(changes.map(\.source) == [.bodyRecut(bodyID: "ref")], "published as a recut")
        #expect(changes.last?.current == service.selection)
        if case .face(let published)? = changes.last?.current.first {
            #expect(abs(published.area - 4) < 1e-6, "the change carries the image's details")
        }
    }

    // MARK: - Bodies the cap does not recut

    /// Guard: passes without the fix.
    ///
    /// A body the cap leaves whole keeps its tables, so the marker and an escalation on it name
    /// what they named.
    @MainActor
    @Test("The marker and an escalation on a body the cap does not recut are left alone")
    func untouchedBodyKeepsMarkerAndEscalation() throws {
        guard let service = CADViewportService.withBoxes(ids: ["ref"]) else { return }
        service.loadUnrelatedEntity()
        let far = Box(SIMD3(50.5, -0.5, -0.5), SIMD3(50.5, 0.5, 0.5))
        let face = try #require(service.entity(.face, ofBody: "unrelated", at: far))
        service.setAgentAttention(face, label: "far")
        service.beginPresenting(EscalationRequest(id: "which", entities: [face], question: "?"))

        service.addHalfCap()

        #expect(service.agentAttention == face && service.agentAttention?.ref.uid == face.ref.uid)
        #expect(service.agentAttentionLabel == "far")
        #expect(service.pendingEscalation?.entities == [face])
    }
}

@MainActor
extension CADViewportService {
    /// Rebuilds the identity tables of body `id` without uids, and drops its graph.
    ///
    /// As if the graph had failed to build, which no public API can make happen.
    func dropGraph(ofBody id: String) {
        bodyGraphs[id] = nil
        if let faces = faceIdentity[id] {
            faceIdentity[id] = FaceIdentityTable(shapes: faces.shapes)
        }
        if let edges = edgeIdentity[id] {
            edgeIdentity[id] = EdgeIdentityTable(shapes: edges.shapes)
        }
        if let vertices = vertexIdentity[id] {
            vertexIdentity[id] = VertexIdentityTable(shapes: vertices.shapes)
        }
    }
}
