import Foundation
import OCCTSwift
import OCCTSwiftAIS
import OCCTSwiftTools
import OCCTSwiftViewport
import Testing
import simd

@testable import OCCTSwiftCADKit

/// Regression coverage for OCCTSwiftInteraction#78: a selection highlight lights only what is
/// drawn, so a body that is hidden keeps its selection but lights none of it, and lights it again
/// when it is shown.
///
/// Two 4x4x4 boxes: `part` at the origin, which is hidden and shown, and `other` at X = 50, which
/// stays visible throughout, so a check also catches a fix that drops more than the hidden body's
/// highlight. A cap plane at X = 10 clips `part` away entirely and leaves `other` alone. Every
/// check is by geometry: the highlight must light exactly what the visible bodies draw for their
/// selected sub-shapes, in world space.
///
/// Every test fails without the fix.
@Suite("Selection highlights on a hidden body")
struct HiddenHighlightTests {
    typealias Geometry = HighlightGeometry

    // MARK: - Dimensions

    enum Kind: CaseIterable, Sendable, CustomTestStringConvertible {
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

    /// What hides `part`, and its undoing.
    enum Hider: CaseIterable, Sendable, CustomTestStringConvertible {
        case visibility
        case fullClip

        var testDescription: String {
            switch self {
            case .visibility: "hidden through visibility"
            case .fullClip: "clipped away entirely by a cap plane"
            }
        }
    }

    /// When the sub-shapes are selected, relative to hiding `part`.
    enum Timing: CaseIterable, Sendable, CustomTestStringConvertible {
        case beforeHiding
        case whileHidden

        var testDescription: String {
            switch self {
            case .beforeHiding: "selected before it is hidden"
            case .whileHidden: "selected while it is hidden"
            }
        }
    }

    struct HideCase: Sendable, CustomTestStringConvertible {
        var kind: Kind
        var hider: Hider
        var timing: Timing

        var testDescription: String {
            "\(kind.testDescription), \(hider.testDescription), \(timing.testDescription)"
        }

        static let all = Kind.allCases.flatMap { kind in
            Hider.allCases.flatMap { hider in
                Timing.allCases.map { HideCase(kind: kind, hider: hider, timing: $0) }
            }
        }
    }

    // MARK: - Helpers

    /// A service holding `part` at the origin and `other` at X = 50, with every kind selectable.
    @MainActor
    private func makeService() -> CADViewportService? {
        guard let part = Shape.box(width: 4, height: 4, depth: 4),
            let other = Shape.box(width: 4, height: 4, depth: 4)
        else {
            Issue.record("Shape.box returned nil")
            return nil
        }
        let service = CADViewportService()
        service.load(part, id: "part")
        service.load(other, id: "other", transform: [1, 0, 0, 0, 1, 0, 0, 0, 1, 50, 0, 0])
        service.selectionModes = [.face, .edge, .vertex]
        return service
    }

    /// A sub-shape of `kind` on body `id`: its +Y face, or what its first segment or point picks.
    @MainActor
    private func entity(_ kind: Kind, onBody id: String, in service: CADViewportService)
        -> PickedEntity?
    {
        switch kind {
        case .face:
            guard let ref = service.plusYFace(ofBody: id),
                let info = service.enrichFace(ref: ref, bodyID: id, triangleIndex: nil)
            else { return nil }
            return .face(info)
        case .edge:
            return service.resolveEdgePick(bodyID: id, segmentIndex: 0).map(PickedEntity.edge)
        case .vertex:
            return service.resolveVertexPick(bodyID: id, pointIndex: 0).map(PickedEntity.vertex)
        }
    }

    /// Selects every entity in `entities`, replacing the selection.
    @MainActor
    private func select(_ entities: [PickedEntity], in service: CADViewportService) {
        for (index, entity) in entities.enumerated() {
            service.select(entity, scheme: index == 0 ? .replace : .add)
        }
    }

    /// Expects the highlight to light exactly what the model bodies draw for `lit`, and nothing
    /// else.
    ///
    /// Every entity in `lit` is of one kind, and the highlight of that kind is the one compared.
    @MainActor
    private func expectHighlight(
        _ service: CADViewportService, lights lit: [PickedEntity], _ step: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let first = lit.first else {
            Issue.record("\(step): nothing to compare against", sourceLocation: sourceLocation)
            return
        }
        let drawn = lit.flatMap { service.drawnPoints(of: $0) }
        let (missing, extra) = Geometry.unpaired(drawn, service.litPoints(ofKindOf: first))
        #expect(
            !drawn.isEmpty && missing.isEmpty && extra.isEmpty,
            """
            \(step): the highlight should light the \(drawn.count) points drawn for \
            \(lit.map(\.bodyID)), but \(missing.count) are unlit and \(extra.count) lit points \
            are not drawn there
            """,
            sourceLocation: sourceLocation)
    }

    // MARK: - Hidden and shown

    @MainActor
    @Test(
        "A hidden body's selection lights nothing, and lights again when the body is shown",
        arguments: HideCase.all)
    func highlightFollowsVisibility(_ testCase: HideCase) throws {
        guard let service = makeService() else { return }
        // Resolved before anything is hidden: a pick on clipped geometry does not resolve.
        let part = try #require(entity(testCase.kind, onBody: "part", in: service))
        let other = try #require(entity(testCase.kind, onBody: "other", in: service))

        if testCase.timing == .beforeHiding {
            select([part, other], in: service)
            expectHighlight(service, lights: [part, other], "before hiding")
        }

        var plane: String?
        switch testCase.hider {
        case .visibility: service.visibility["part"] = false
        case .fullClip: plane = service.addFullClip()
        }
        #expect(service.modelBodyIsVisible("part") == false, "sanity check: part is hidden")
        #expect(service.modelBodyIsVisible("other") == true, "sanity check: other is not")
        if testCase.timing == .whileHidden { select([part, other], in: service) }
        #expect(service.selection.count == 2, "hiding keeps the selection")
        expectHighlight(service, lights: [other], "part hidden")

        switch testCase.hider {
        case .visibility: service.visibility["part"] = true
        case .fullClip: plane.map(service.removeClippingPlane(id:))
        }
        #expect(service.modelBodyIsVisible("part") == true, "sanity check: part is shown")
        expectHighlight(service, lights: [part, other], "part shown again")
    }

    /// An escalation preview that names a model body shows it (`setBodyVisible`), which is the
    /// other public way a model body's visibility changes.
    ///
    /// Presenting selects the request's entities before it shows the preview, so the highlight is
    /// cut while `part` is still hidden, and only the visibility change can cut it again.
    @MainActor
    @Test(
        "A hidden body's selection lights again when an escalation preview shows the body",
        arguments: Kind.allCases)
    func escalationPreviewLightsTheHighlight(_ kind: Kind) throws {
        guard let service = makeService() else { return }
        let part = try #require(entity(kind, onBody: "part", in: service))
        let other = try #require(entity(kind, onBody: "other", in: service))
        select([part, other], in: service)
        service.visibility["part"] = false
        expectHighlight(service, lights: [other], "part hidden")

        let request = EscalationRequest(
            id: "req1", entities: [part, other], question: "Which one?",
            candidates: [EscalationCandidate(id: "c", label: "C", previewBodyID: "part")])
        service.beginPresenting(request)
        #expect(service.modelBodyIsVisible("part") == true, "sanity check: the preview shows part")
        #expect(service.selection.count == 2, "sanity check: the selection is unchanged")
        expectHighlight(service, lights: [part, other], "the preview shows part")
    }
}
