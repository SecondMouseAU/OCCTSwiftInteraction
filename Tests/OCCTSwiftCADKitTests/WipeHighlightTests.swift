import Foundation
import OCCTSwift
import OCCTSwiftAIS
import OCCTSwiftTools
import OCCTSwiftViewport
import Testing
import simd

@testable import OCCTSwiftCADKit

/// Regression coverage for OCCTSwiftInteraction#72: the selection highlight is cut from the model
/// bodies as drawn, so it has to be cut again whenever a comparison changes them, not only when
/// the selection changes.
///
/// Every check is by geometry: the face highlight must light exactly the triangles the body draws
/// on the selected face, compared by world-space centroid. The face is a box's +Y face, which a
/// wipe at X = 0 cuts in two (one triangle each side), a wipe at X = 1 leaves wholly with the
/// reference and a wipe at X = -1 wholly with the candidate.
///
/// Every test fails without the fix except the one marked "guard".
@Suite("Selection highlights while a wipe moves or ends")
struct WipeHighlightTests {
    typealias Target = ComparisonVisibilityTests.Target
    typealias Trigger = ComparisonVisibilityTests.Trigger
    typealias Geometry = HighlightGeometry

    // MARK: - Dimensions

    /// When the face is selected, relative to the first wipe.
    enum Timing: CaseIterable, Sendable, CustomTestStringConvertible {
        case beforeWipe
        case duringWipe

        var testDescription: String {
            switch self {
            case .beforeWipe: "selected before the wipe"
            case .duringWipe: "selected during the wipe"
            }
        }
    }

    struct MoveCase: Sendable, CustomTestStringConvertible {
        var target: Target
        var timing: Timing

        var testDescription: String { "\(target.testDescription), \(timing.testDescription)" }

        static let all = Target.allCases.flatMap { target in
            Timing.allCases.map { MoveCase(target: target, timing: $0) }
        }
    }

    /// How the wipe ends.
    enum Ending: CaseIterable, Sendable, CustomTestStringConvertible {
        case clear
        case switchToOverlay
        case switchToDeviation
        case otherSideRemoved

        var testDescription: String {
            switch self {
            case .clear: "the comparison is cleared"
            case .switchToOverlay: "the comparison switches to overlay"
            case .switchToDeviation: "the comparison switches to deviation"
            case .otherSideRemoved: "the other side is removed"
            }
        }
    }

    struct EndingCase: Sendable, CustomTestStringConvertible {
        var target: Target
        var ending: Ending

        var testDescription: String { "\(target.testDescription), \(ending.testDescription)" }

        static let all = Target.allCases.flatMap { target in
            Ending.allCases.map { EndingCase(target: target, ending: $0) }
        }
    }

    /// Something that steps the wipe aside and applies it again, leaving the same bodies drawn.
    enum StepAside: Sendable, CustomTestStringConvertible {
        case setField
        case recompute(Trigger)

        var testDescription: String {
            switch self {
            case .setField: "a scalar field is set"
            case .recompute(let trigger): trigger.testDescription
            }
        }

        static let all: [StepAside] = [.setField] + Trigger.allCases.map(recompute)
    }

    // MARK: - Helpers

    private static func wipe(at position: Double) -> ComparisonView {
        ComparisonView(
            referenceID: "ref", candidateID: "cand", mode: .wipe(axis: .x, position: position))
    }

    /// How many triangles body `id` draws on `face`.
    @MainActor
    private func drawnCount(_ service: CADViewportService, _ id: String, _ face: SubShapeRef)
        -> Int
    {
        service.modelBody(id).map { Geometry.worldCentroids(onFace: face.shape, of: $0).count } ?? 0
    }

    // MARK: - Set and moved

    @MainActor
    @Test(
        "A selected face lights exactly its drawn triangles as a wipe is set, moved and cleared",
        arguments: MoveCase.all)
    func highlightFollowsTheWipeAsItMoves(_ testCase: MoveCase) throws {
        guard let service = CADViewportService.withBoxes(ids: ["ref", "cand"]) else { return }
        let id = testCase.target.id
        let face = try #require(service.plusYFace(ofBody: id))
        let faces = [(bodyID: id, face: face)]
        let whole = drawnCount(service, id, face)

        if testCase.timing == .beforeWipe {
            service.selectFace(face, ofBody: id)
            expectFaceHighlight(service, lights: faces, "selected, before any wipe")
        }
        service.setComparison(Self.wipe(at: 0))
        #expect(
            (1..<whole).contains(drawnCount(service, id, face)),
            "sanity check: a wipe at X = 0 cuts the face")
        if testCase.timing == .duringWipe { service.selectFace(face, ofBody: id) }
        expectFaceHighlight(service, lights: faces, "wipe at X = 0")

        service.setComparison(Self.wipe(at: 1))
        expectFaceHighlight(service, lights: faces, "wipe moved to X = 1")
        service.setComparison(Self.wipe(at: -1))
        expectFaceHighlight(service, lights: faces, "wipe moved to X = -1")

        service.setComparison(nil)
        #expect(drawnCount(service, id, face) == whole, "sanity check: the face is whole again")
        expectFaceHighlight(service, lights: faces, "wipe cleared")
    }

    // MARK: - Ended

    @MainActor
    @Test(
        "A face selected during a wipe lights all of itself once the wipe ends",
        arguments: EndingCase.all)
    func highlightIsWholeOnceTheWipeEnds(_ testCase: EndingCase) throws {
        guard let service = CADViewportService.withBoxes(ids: ["ref", "cand"]) else { return }
        let id = testCase.target.id
        let face = try #require(service.plusYFace(ofBody: id))
        let faces = [(bodyID: id, face: face)]
        let whole = drawnCount(service, id, face)

        service.setComparison(Self.wipe(at: 0))
        service.selectFace(face, ofBody: id)
        #expect(
            (1..<whole).contains(drawnCount(service, id, face)),
            "sanity check: a wipe at X = 0 cuts the face")

        switch testCase.ending {
        case .clear:
            service.setComparison(nil)
        case .switchToOverlay:
            service.setComparison(
                ComparisonView(
                    referenceID: "ref", candidateID: "cand",
                    mode: .overlay(referenceOpacity: 0.3)))
        case .switchToDeviation:
            service.setComparison(
                ComparisonView(referenceID: "ref", candidateID: "cand", mode: .deviation))
        case .otherSideRemoved:
            service.remove(id: testCase.target.other)
        }

        #expect(drawnCount(service, id, face) == whole, "sanity check: the face is whole again")
        expectFaceHighlight(service, lights: faces, testCase.ending.testDescription)
    }

    // MARK: - Stepped aside and reapplied

    /// Guard: passes without the fix.
    ///
    /// A scalar field write (`writeThroughComparison(toBody:_:)`) and a cap recompute
    /// (`updateCapSurfaces()`) each undo the wipe and apply it again over the same bodies, so the
    /// highlight has to come out of that cycle cut from the wiped bodies, not the whole ones.
    @MainActor
    @Test(
        "A face lit during a wipe stays lit exactly when the wipe is stepped aside and back",
        arguments: StepAside.all)
    func highlightSurvivesSteppingTheWipeAside(_ change: StepAside) throws {
        guard let service = CADViewportService.withBoxes(ids: ["ref", "cand"]) else { return }
        service.setComparison(Self.wipe(at: 0))
        let faces = try Target.allCases.map { target in
            (bodyID: target.id, face: try #require(service.plusYFace(ofBody: target.id)))
        }
        for (index, entry) in faces.enumerated() {
            let scheme: SelectionScheme = index == 0 ? .replace : .add
            service.selectFace(entry.face, ofBody: entry.bodyID, scheme: scheme)
        }
        expectFaceHighlight(service, lights: faces, "before the step")
        let before = faces.map { drawnCount(service, $0.bodyID, $0.face) }

        switch change {
        case .setField:
            service.setScalarField(ComparisonScalarFieldTests.keyField(.perFace), forBody: "cand")
        case .recompute(let trigger):
            service.fire(trigger)
        }

        #expect(
            faces.map { drawnCount(service, $0.bodyID, $0.face) } == before,
            "sanity check: the wipe draws the same triangles on each face afterwards")
        expectFaceHighlight(service, lights: faces, change.testDescription)
    }
}
