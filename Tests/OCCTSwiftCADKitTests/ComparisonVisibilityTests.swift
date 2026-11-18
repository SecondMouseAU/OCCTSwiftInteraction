import Foundation
import OCCTSwift
import OCCTSwiftTools
import OCCTSwiftViewport
import Testing
import simd

@testable import OCCTSwiftCADKit

/// Regression coverage for OCCTSwiftInteraction#48: a caller-set visibility write made while an
/// `.overlay`, `.sideBySide` or `.wipe` comparison is active must survive `undoComparison`, which
/// restores whole bodies from the snapshot taken when the comparison began, and must hold for a
/// body that is also capped, which has a second snapshot (`clippingCapBackup`).
///
/// Every test but the three marked "guard" fails without the fix. A guard passes without it and
/// pins a neighbouring behaviour the fix relies on or must not disturb.
///
/// The mode and side dimensions do not change any case's outcome today, since the snapshot,
/// restore and write are mode-agnostic and side-symmetric. They are breadth, so a later
/// mode-specific restore cannot regress one mode silently.
@Suite("Visibility changed during a comparison")
struct ComparisonVisibilityTests {
    // MARK: - Dimensions

    /// The three modes that mutate `modelBodies` and so keep a `comparisonBackup`.
    enum Mode: CaseIterable, Sendable, CustomTestStringConvertible {
        case overlay
        case sideBySide
        case wipe

        var testDescription: String {
            switch self {
            case .overlay: "overlay"
            case .sideBySide: "side by side"
            case .wipe: "wipe"
            }
        }

        var comparisonMode: ComparisonMode {
            switch self {
            case .overlay: .overlay(referenceOpacity: 0.3)
            case .sideBySide: .sideBySide
            case .wipe: .wipe(axis: .x, position: 1)
            }
        }
    }

    /// Which side of the comparison the caller changes.
    enum Target: CaseIterable, Sendable, CustomTestStringConvertible {
        case reference
        case candidate

        var testDescription: String {
            switch self {
            case .reference: "the reference"
            case .candidate: "the candidate"
            }
        }

        var id: String {
            switch self {
            case .reference: "ref"
            case .candidate: "cand"
            }
        }

        var other: String {
            switch self {
            case .reference: "cand"
            case .candidate: "ref"
            }
        }
    }

    /// The caller's change: hide something that was visible, or show something that was hidden.
    enum Intent: CaseIterable, Sendable, CustomTestStringConvertible {
        case hide
        case show

        var testDescription: String {
            switch self {
            case .hide: "hide"
            case .show: "show"
            }
        }

        /// Visibility when the scenario starts.
        var startsVisible: Bool { self == .hide }

        /// Visibility the caller leaves the entity at.
        var endsVisible: Bool { self == .show }
    }

    /// Things that run `updateCapSurfaces()` without being about the entity under test.
    enum Trigger: CaseIterable, Sendable, CustomTestStringConvertible {
        case resetClippingPlanes
        case loadUnrelatedEntity
        case addUnrelatedHollowPlane

        var testDescription: String {
            switch self {
            case .resetClippingPlanes: "clippingPlanes = clippingPlanes"
            case .loadUnrelatedEntity: "load an unrelated entity"
            case .addUnrelatedHollowPlane: "add an unrelated hollow plane"
            }
        }
    }

    /// Which of the two snapshot-taking operations happens first.
    enum SetupOrder: CaseIterable, Sendable, CustomTestStringConvertible {
        case capThenComparison
        case comparisonThenCap

        var testDescription: String {
            switch self {
            case .capThenComparison: "cap, then comparison"
            case .comparisonThenCap: "comparison, then cap"
            }
        }
    }

    /// When, between the two operations, the caller changes visibility.
    enum WritePoint: CaseIterable, Sendable, CustomTestStringConvertible {
        case afterFirstOperation
        case afterBothOperations

        var testDescription: String {
            switch self {
            case .afterFirstOperation: "between the two"
            case .afterBothOperations: "after both"
            }
        }
    }

    /// Which of the two is undone first.
    enum Teardown: CaseIterable, Sendable, CustomTestStringConvertible {
        case clearComparisonFirst
        case removeCapFirst

        var testDescription: String {
            switch self {
            case .clearComparisonFirst: "clear comparison, then remove cap"
            case .removeCapFirst: "remove cap, then clear comparison"
            }
        }
    }

    struct SingleCase: Sendable, CustomTestStringConvertible {
        var mode: Mode
        var target: Target
        var intent: Intent

        var testDescription: String {
            "\(intent.testDescription) \(target.testDescription), \(mode.testDescription)"
        }

        static let all = Mode.allCases.flatMap { mode in
            Target.allCases.flatMap { target in
                Intent.allCases.map { SingleCase(mode: mode, target: target, intent: $0) }
            }
        }
    }

    struct SwitchCase: Sendable, CustomTestStringConvertible {
        var from: Mode
        var to: Mode
        var intent: Intent

        var testDescription: String {
            "\(intent.testDescription) in \(from.testDescription), switch to \(to.testDescription)"
        }

        static let all = Mode.allCases.flatMap { from in
            Mode.allCases.flatMap { to in
                Intent.allCases.map { SwitchCase(from: from, to: to, intent: $0) }
            }
        }
    }

    struct TriggerCase: Sendable, CustomTestStringConvertible {
        var mode: Mode
        var trigger: Trigger
        var intent: Intent

        var testDescription: String {
            "\(intent.testDescription), \(mode.testDescription), then \(trigger.testDescription)"
        }

        static let all = Mode.allCases.flatMap { mode in
            Trigger.allCases.flatMap { trigger in
                Intent.allCases.map { TriggerCase(mode: mode, trigger: trigger, intent: $0) }
            }
        }
    }

    struct OverlapCase: Sendable, CustomTestStringConvertible {
        var mode: Mode
        var setup: SetupOrder
        var writePoint: WritePoint
        var teardown: Teardown
        var intent: Intent

        var testDescription: String {
            "\(intent.testDescription) \(writePoint.testDescription), \(mode.testDescription), "
                + "\(setup.testDescription), \(teardown.testDescription)"
        }

        static let all = Mode.allCases.flatMap { mode in
            SetupOrder.allCases.flatMap { setup in
                WritePoint.allCases.flatMap { writePoint in
                    Teardown.allCases.flatMap { teardown in
                        Intent.allCases.map {
                            OverlapCase(
                                mode: mode, setup: setup, writePoint: writePoint,
                                teardown: teardown, intent: $0)
                        }
                    }
                }
            }
        }
    }

    /// What the caller does about visibility around a body a plane clips away entirely.
    enum CallerAction: CaseIterable, Sendable, CustomTestStringConvertible {
        case nothing
        case hidesBeforeSetup
        case hidesAfterSetup

        var testDescription: String {
            switch self {
            case .nothing: "the caller changes nothing"
            case .hidesBeforeSetup: "the caller hides it first"
            case .hidesAfterSetup: "the caller hides it last"
            }
        }
    }

    struct FullClipCase: Sendable, CustomTestStringConvertible {
        var mode: Mode
        var setup: SetupOrder
        var caller: CallerAction
        var teardown: Teardown

        var testDescription: String {
            "\(mode.testDescription), \(setup.testDescription), \(caller.testDescription), "
                + "\(teardown.testDescription)"
        }

        static let all = Mode.allCases.flatMap { mode in
            SetupOrder.allCases.flatMap { setup in
                CallerAction.allCases.flatMap { caller in
                    Teardown.allCases.map {
                        FullClipCase(mode: mode, setup: setup, caller: caller, teardown: $0)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    @MainActor
    private func view(_ mode: Mode) -> ComparisonView {
        ComparisonView(referenceID: "ref", candidateID: "cand", mode: mode.comparisonMode)
    }

    @MainActor
    private func body(_ service: CADViewportService, _ id: String) -> _ViewportBody? {
        service.modelBodies.first { $0.id == id }
    }

    @MainActor
    private func isRendered(_ service: CADViewportService, _ id: String) -> Bool? {
        service.interactiveContext.bodies.first { $0.id == id }?.isVisible
    }

    @MainActor
    private func triangleCount(_ service: CADViewportService, _ id: String) -> Int? {
        body(service, id).map { $0.indices.count / 3 }
    }

    /// Whether the comparison's own mutation is visible on the bodies, so a test can tell the
    /// scenario really is in effect (and that a clear really undid it).
    @MainActor
    private func comparisonIsApplied(_ mode: Mode, _ service: CADViewportService) -> Bool {
        switch mode {
        case .overlay:
            return (body(service, "ref")?.color.w ?? 1) < 1
        case .sideBySide:
            return (body(service, "cand")?.transform.columns.3.x ?? 0) > 0.1
        case .wipe:
            let refCount = triangleCount(service, "ref") ?? 0
            let candCount = triangleCount(service, "cand") ?? 0
            // Each side keeps one half of a mesh that has the same full count on both, so a wiped
            // pair keeps strictly fewer triangles than an unwiped one.
            return refCount + candCount < 2 * (fullTriangleCount() ?? 0)
        }
    }

    /// The triangle count of a pristine, uncut, unwiped box.
    @MainActor
    private func fullTriangleCount() -> Int? {
        guard let box = Shape.box(width: 4, height: 4, depth: 4) else { return nil }
        let (body, _) = CADFileLoader.shapeToBodyAndMetadata(
            box, id: "probe", color: SIMD4<Float>(1, 1, 1, 1))
        return body.map { $0.indices.count / 3 }
    }

    @MainActor
    private func fire(_ trigger: Trigger, on service: CADViewportService) {
        switch trigger {
        case .resetClippingPlanes:
            service.clippingPlanes = service.clippingPlanes
        case .loadUnrelatedEntity:
            service.loadUnrelatedEntity()
        case .addUnrelatedHollowPlane:
            service.addUnrelatedHollowPlane()
        }
    }

    // MARK: - Clearing the comparison

    @MainActor
    @Test(
        "A visibility change made during a comparison survives clearing it",
        arguments: SingleCase.all)
    func visibilityChangeSurvivesClear(_ testCase: SingleCase) {
        guard let service = CADViewportService.withBoxes(ids: ["ref", "cand"]) else { return }
        let id = testCase.target.id
        service.visibility[id] = testCase.intent.startsVisible
        let pristineTriangles = triangleCount(service, id)

        service.setComparison(view(testCase.mode))
        #expect(comparisonIsApplied(testCase.mode, service), "sanity check: the comparison applied")
        #expect(service.modelBodyIsVisible(id) == testCase.intent.startsVisible)

        service.visibility[id] = testCase.intent.endsVisible
        service.setComparison(nil)

        #expect(
            service.modelBodyIsVisible(id) == testCase.intent.endsVisible,
            "the caller's change must survive")
        #expect(service.visibility[id] == testCase.intent.endsVisible)
        #expect(
            isRendered(service, id) == testCase.intent.endsVisible, "and so must the rendered body")
        #expect(
            service.modelBodyIsVisible(testCase.target.other) == true,
            "the other side of the comparison is not affected")

        #expect(
            !comparisonIsApplied(testCase.mode, service), "the clear still undid the comparison")
        #expect(triangleCount(service, id) == pristineTriangles)
        #expect(body(service, "ref")?.color.w == 1)
        #expect(body(service, "cand")?.transform == matrix_identity_float4x4)
    }

    @MainActor
    @Test(
        "A visibility change made during a comparison survives switching its mode",
        arguments: SwitchCase.all)
    func visibilityChangeSurvivesModeSwitch(_ testCase: SwitchCase) {
        guard let service = CADViewportService.withBoxes(ids: ["ref", "cand"]) else { return }
        let intent = testCase.intent
        service.visibility["ref"] = intent.startsVisible

        service.setComparison(view(testCase.from))
        service.visibility["ref"] = intent.endsVisible
        service.setComparison(view(testCase.to))

        #expect(comparisonIsApplied(testCase.to, service), "sanity check: the new mode applied")
        #expect(
            service.modelBodyIsVisible("ref") == intent.endsVisible,
            "the switch must not undo the change")

        service.setComparison(nil)
        #expect(
            service.modelBodyIsVisible("ref") == intent.endsVisible,
            "nor must the clear that follows")
        #expect(service.visibility["ref"] == intent.endsVisible)
    }

    @MainActor
    @Test(
        "A visibility change made during a comparison survives an unrelated cap recompute",
        arguments: TriggerCase.all)
    func visibilityChangeSurvivesUnrelatedRecompute(_ testCase: TriggerCase) {
        guard let service = CADViewportService.withBoxes(ids: ["ref", "cand"]) else { return }
        service.visibility["ref"] = testCase.intent.startsVisible

        service.setComparison(view(testCase.mode))
        service.visibility["ref"] = testCase.intent.endsVisible
        fire(testCase.trigger, on: service)

        #expect(service.comparison != nil, "sanity check: the comparison is still active")
        #expect(
            comparisonIsApplied(testCase.mode, service),
            "sanity check: the recompute reapplied the comparison")
        #expect(
            service.modelBodyIsVisible("ref") == testCase.intent.endsVisible,
            "undoing and reapplying the comparison around the recompute must not revert it")

        service.setComparison(nil)
        #expect(service.modelBodyIsVisible("ref") == testCase.intent.endsVisible)
        #expect(service.visibility["ref"] == testCase.intent.endsVisible)
    }

    // MARK: - A body that is both capped and in a comparison

    /// Every ordering of the cap and the comparison, so no order can regress.
    ///
    /// Not every case needs the fix. Without it, 18 of the 48 cases fail: the 12 where the
    /// comparison starts first and the write lands between it and the cap, and the 6 where a hide
    /// is written after both and the comparison is cleared first. The rest pass, because the write
    /// precedes the comparison snapshot or because `updateCapSurfaces` restores `isVisible` from
    /// the correct cap snapshot.
    @MainActor
    @Test(
        "A visibility change on a body that is both capped and compared survives either teardown",
        arguments: OverlapCase.all)
    func visibilityChangeSurvivesCapAndComparison(_ testCase: OverlapCase) {
        guard let service = CADViewportService.withBoxes(ids: ["ref", "cand"]) else { return }
        service.visibility["ref"] = testCase.intent.startsVisible

        func write() { service.visibility["ref"] = testCase.intent.endsVisible }

        var planeID = ""
        switch testCase.setup {
        case .capThenComparison:
            planeID = service.addHalfCap()
            if testCase.writePoint == .afterFirstOperation { write() }
            service.setComparison(view(testCase.mode))
        case .comparisonThenCap:
            service.setComparison(view(testCase.mode))
            if testCase.writePoint == .afterFirstOperation { write() }
            planeID = service.addHalfCap()
        }
        if testCase.writePoint == .afterBothOperations { write() }

        #expect((service.entityMinX("ref") ?? -2) > -0.5, "sanity check: the body is capped")
        #expect(service.comparison != nil, "sanity check: the comparison is active")
        #expect(comparisonIsApplied(testCase.mode, service), "sanity check: it applied")
        #expect(service.modelBodyIsVisible("ref") == testCase.intent.endsVisible)
        #expect(service.visibility["ref"] == testCase.intent.endsVisible)

        switch testCase.teardown {
        case .clearComparisonFirst:
            service.setComparison(nil)
            #expect(
                service.modelBodyIsVisible("ref") == testCase.intent.endsVisible,
                "clearing the comparison on a capped body must keep the caller's change")
            service.removeClippingPlane(id: planeID)
        case .removeCapFirst:
            service.removeClippingPlane(id: planeID)
            #expect(
                service.modelBodyIsVisible("ref") == testCase.intent.endsVisible,
                "removing the cap under a comparison must keep the caller's change")
            service.setComparison(nil)
        }

        #expect(service.modelBodyIsVisible("ref") == testCase.intent.endsVisible)
        #expect(service.visibility["ref"] == testCase.intent.endsVisible)
        #expect(isRendered(service, "ref") == testCase.intent.endsVisible)
        #expect(
            abs((service.entityMinX("ref") ?? 0) - (-2)) < 0.01,
            "sanity check: removing the plane restored the original geometry")
        #expect(!comparisonIsApplied(testCase.mode, service), "and the comparison is gone")
    }

    /// Guard: passes without the #48 fix.
    ///
    /// A body hidden only because a plane clips it away entirely is snapshotted hidden by the
    /// comparison and visible by the cap, which keeps the caller's intent; the cap snapshot has to
    /// win on every restore, and a caller's own hide has to outlast both. Without the fix the
    /// comparison snapshot holds the clip's hide either way, so this pins that interaction (and
    /// #46's cap write) rather than the #48 write.
    @MainActor
    @Test(
        "A body a plane clips away entirely returns to the caller's visibility with a comparison active",
        arguments: FullClipCase.all)
    func fullyClippedBodyUnderComparison(_ testCase: FullClipCase) {
        guard let service = CADViewportService.withBoxes(ids: ["ref", "cand"]) else { return }
        if testCase.caller == .hidesBeforeSetup { service.visibility["ref"] = false }

        var planeID = ""
        switch testCase.setup {
        case .capThenComparison:
            planeID = service.addFullClip()
            service.setComparison(view(testCase.mode))
        case .comparisonThenCap:
            service.setComparison(view(testCase.mode))
            planeID = service.addFullClip()
        }
        if testCase.caller == .hidesAfterSetup { service.visibility["ref"] = false }

        let callerWantsItShown = testCase.caller == .nothing
        #expect(service.modelBodyIsVisible("ref") == false, "sanity check: the plane clips it away")
        #expect(comparisonIsApplied(testCase.mode, service), "sanity check: the comparison is on")
        #expect(
            service.visibility["ref"] == callerWantsItShown,
            "the caller's intent is not the clip's hide")

        switch testCase.teardown {
        case .clearComparisonFirst:
            service.setComparison(nil)
            #expect(service.modelBodyIsVisible("ref") == false, "the plane still clips it away")
            service.removeClippingPlane(id: planeID)
        case .removeCapFirst:
            service.removeClippingPlane(id: planeID)
            #expect(
                service.modelBodyIsVisible("ref") == callerWantsItShown,
                "once the plane goes the caller's visibility wins, with the comparison still on")
            service.setComparison(nil)
        }

        #expect(service.modelBodyIsVisible("ref") == callerWantsItShown)
        #expect(isRendered(service, "ref") == callerWantsItShown)
        #expect(service.visibility["ref"] == callerWantsItShown)
        #expect(!comparisonIsApplied(testCase.mode, service), "and the comparison is gone")
    }

    // MARK: - Other writers and neighbours

    @MainActor
    @Test(
        "An escalation preview that shows a hidden body survives clearing the comparison",
        arguments: Mode.allCases)
    func escalationPreviewSurvivesClear(mode: Mode) {
        guard let service = CADViewportService.withBoxes(ids: ["ref", "cand"]) else { return }
        service.visibility["ref"] = false

        service.setComparison(view(mode))
        #expect(
            service.modelBodyIsVisible("ref") == false,
            "sanity check: the caller's hide is in force")

        let request = EscalationRequest(
            id: "req1", entities: [], question: "Which one?",
            candidates: [EscalationCandidate(id: "c", label: "C", previewBodyID: "ref")])
        service.beginPresenting(request)
        #expect(service.modelBodyIsVisible("ref") == true)

        service.setComparison(nil)
        #expect(service.modelBodyIsVisible("ref") == true, "the preview's show must not be undone")
    }

    @MainActor
    @Test(
        "Hiding a multi-body entity during a comparison keeps every one of its bodies hidden",
        arguments: Mode.allCases)
    func multiBodyEntityStaysHidden(mode: Mode) async throws {
        let service = CADViewportService()
        guard let box = Shape.box(width: 4, height: 4, depth: 4) else {
            Issue.record("Shape.box returned nil")
            return
        }
        service.load(box, id: "ref")
        let url = try #require(
            Bundle.module.url(
                forResource: "multibody-three-solids", withExtension: "brep",
                subdirectory: "Fixtures"))
        _ = try await service.loadFile(from: url, id: "asm")
        let bodyIDs = try #require(service.entities["asm"]?.bodyIDs)
        #expect(bodyIDs.count == 3, "sanity check: the fixture has three bodies")

        service.setComparison(
            ComparisonView(referenceID: "ref", candidateID: "asm", mode: mode.comparisonMode))
        service.visibility["asm"] = false
        service.setComparison(nil)

        for bodyID in bodyIDs {
            #expect(service.modelBodyIsVisible(bodyID) == false, "\(bodyID) must stay hidden")
        }
        #expect(service.modelBodyIsVisible("ref") == true)
    }

    /// Guard: passes without the fix, since an entity outside the comparison is in no snapshot.
    @MainActor
    @Test(
        "Hiding an entity outside the comparison is unaffected by clearing it",
        arguments: Mode.allCases)
    func uninvolvedEntityStaysHidden(mode: Mode) {
        guard let service = CADViewportService.withBoxes(ids: ["ref", "cand", "other"]) else {
            return
        }

        service.setComparison(view(mode))
        service.visibility["other"] = false
        service.setComparison(nil)

        #expect(service.modelBodyIsVisible("other") == false)
        #expect(service.modelBodyIsVisible("ref") == true)
        #expect(service.modelBodyIsVisible("cand") == true)
    }

    @MainActor
    @Test(
        "Removing the reference mid-comparison keeps the candidate's hide",
        arguments: Mode.allCases)
    func removingTheReferenceKeepsTheCandidateHidden(mode: Mode) {
        guard let service = CADViewportService.withBoxes(ids: ["ref", "cand"]) else { return }

        service.setComparison(view(mode))
        service.visibility["cand"] = false
        service.remove(id: "ref")

        #expect(service.comparison == nil, "sanity check: removing a side clears the comparison")
        #expect(service.modelBodyIsVisible("cand") == false)
        #expect(service.visibility["cand"] == false)
    }

    /// Guard: passes without the fix, since `.deviation` keeps no `comparisonBackup`.
    @MainActor
    @Test("A hide made during a deviation comparison survives clearing it")
    func hideDuringDeviationSurvivesClear() {
        guard let service = CADViewportService.withBoxes(ids: ["ref", "cand"]) else { return }

        service.setComparison(
            ComparisonView(referenceID: "ref", candidateID: "cand", mode: .deviation))
        service.visibility["cand"] = false
        service.setComparison(nil)

        #expect(service.modelBodyIsVisible("cand") == false)
        #expect(service.visibility["cand"] == false)
    }
}
