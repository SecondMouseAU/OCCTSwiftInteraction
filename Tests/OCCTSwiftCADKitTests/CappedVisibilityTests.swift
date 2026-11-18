import OCCTSwift
import OCCTSwiftViewport
import Testing
import simd

@testable import OCCTSwiftCADKit

/// Regression coverage for OCCTSwiftInteraction#46: a caller-set visibility write on a capped
/// body must survive `updateCapSurfaces()`, which restores from the snapshot taken at first-cap
/// time, and must be what a later restore returns the body to.
@Suite("Capped entity visibility")
struct CappedVisibilityTests {
    /// Things that run `updateCapSurfaces()` without being about the entity under test.
    enum Trigger: CaseIterable, Sendable, CustomTestStringConvertible {
        case resetClippingPlanes
        case loadUnrelatedEntity
        case addUnrelatedPlane
        case moveCapPlane

        var testDescription: String {
            switch self {
            case .resetClippingPlanes: "clippingPlanes = clippingPlanes"
            case .loadUnrelatedEntity: "load an unrelated entity"
            case .addUnrelatedPlane: "add an unrelated hollow plane"
            case .moveCapPlane: "move the cap plane"
            }
        }
    }

    /// How the caller's visibility intent evolves around the cap.
    enum Scenario: CaseIterable, Sendable, CustomTestStringConvertible {
        case visibleThroughout
        case hiddenAfterCapping
        case hiddenBeforeCapping
        case hiddenBeforeThenShownAfterCapping

        var testDescription: String {
            switch self {
            case .visibleThroughout: "visible throughout"
            case .hiddenAfterCapping: "hidden after capping"
            case .hiddenBeforeCapping: "hidden before capping"
            case .hiddenBeforeThenShownAfterCapping: "hidden before capping, shown after"
            }
        }

        var finalVisibility: Bool {
            switch self {
            case .visibleThroughout, .hiddenBeforeThenShownAfterCapping: true
            case .hiddenAfterCapping, .hiddenBeforeCapping: false
            }
        }
    }

    // MARK: - Helpers

    @MainActor
    private func fire(_ trigger: Trigger, on service: CADViewportService) {
        switch trigger {
        case .resetClippingPlanes:
            service.clippingPlanes = service.clippingPlanes
        case .loadUnrelatedEntity:
            service.loadUnrelatedEntity()
        case .addUnrelatedPlane:
            service.addUnrelatedHollowPlane()
        case .moveCapPlane:
            guard !service.clippingPlanes.isEmpty else {
                Issue.record("expected a cap plane to move")
                return
            }
            service.clippingPlanes[0].origin = SIMD3(1, 0, 0)
        }
    }

    // MARK: - Hiding

    @MainActor
    @Test(
        "Hiding a capped entity survives an unrelated cap recompute", arguments: Trigger.allCases)
    func hiddenCappedEntityStaysHidden(trigger: Trigger) {
        guard let service = CADViewportService.withBoxes(ids: ["part"]) else { return }
        service.addHalfCap()
        #expect(
            (service.entityMinX("part") ?? -2) > -0.5, "sanity check: the entity is actually capped"
        )

        service.visibility["part"] = false
        #expect(service.modelBodyIsVisible("part") == false)

        fire(trigger, on: service)

        #expect(service.modelBodyIsVisible("part") == false, "the explicit hide must not be undone")
        #expect(service.visibility["part"] == false)
        #expect(
            service.interactiveContext.bodies.first { $0.id == "part" }?.isVisible == false,
            "the rendered body must stay hidden too")
        #expect((service.entityMinX("part") ?? -2) > -0.5, "the cap itself must still be applied")
    }

    @MainActor
    @Test(
        "Hiding one capped entity leaves its neighbour's visibility alone",
        arguments: Trigger.allCases)
    func hidingOneCappedEntityLeavesTheOtherAlone(trigger: Trigger) {
        guard let service = CADViewportService.withBoxes(ids: ["a", "b"]) else { return }
        service.addHalfCap()

        service.visibility["a"] = false
        fire(trigger, on: service)

        #expect(service.modelBodyIsVisible("a") == false)
        #expect(service.modelBodyIsVisible("b") == true)
    }

    // MARK: - Un-hiding

    @MainActor
    @Test(
        "Showing an entity that was hidden before it was capped survives an unrelated recompute",
        arguments: Trigger.allCases)
    func shownCappedEntityStaysShown(trigger: Trigger) {
        guard let service = CADViewportService.withBoxes(ids: ["part"]) else { return }
        service.visibility["part"] = false
        service.addHalfCap()
        #expect(
            service.modelBodyIsVisible("part") == false,
            "sanity check: capping keeps the caller's hide")

        service.visibility["part"] = true
        #expect(service.modelBodyIsVisible("part") == true)

        fire(trigger, on: service)

        #expect(service.modelBodyIsVisible("part") == true, "the explicit show must not be undone")
        #expect(service.visibility["part"] == true)
    }

    // MARK: - Restore on plane removal

    @MainActor
    @Test(
        "Removing the cap returns the body to the visibility the caller last set",
        arguments: Scenario.allCases)
    func removingTheCapRestoresCallerVisibility(scenario: Scenario) {
        guard let service = CADViewportService.withBoxes(ids: ["part"]) else { return }

        if scenario == .hiddenBeforeCapping || scenario == .hiddenBeforeThenShownAfterCapping {
            service.visibility["part"] = false
        }
        let planeID = service.addHalfCap()
        switch scenario {
        case .hiddenAfterCapping: service.visibility["part"] = false
        case .hiddenBeforeThenShownAfterCapping: service.visibility["part"] = true
        case .visibleThroughout, .hiddenBeforeCapping: break
        }

        service.removeClippingPlane(id: planeID)

        #expect(service.modelBodyIsVisible("part") == scenario.finalVisibility)
        #expect(service.visibility["part"] == scenario.finalVisibility)
        #expect(
            abs((service.entityMinX("part") ?? 0) - (-2)) < 0.01,
            "sanity check: removing the plane restored the original geometry")
    }

    @MainActor
    @Test("A body hidden only because a cap plane fully clipped it comes back when the plane goes")
    func fullyClippedBodyComesBackWhenPlaneIsRemoved() {
        guard let service = CADViewportService.withBoxes(ids: ["part"]) else { return }
        let planeID = service.addFullClip()
        #expect(
            service.modelBodyIsVisible("part") == false,
            "sanity check: the plane clips the whole box away")
        #expect(service.visibility["part"] == true, "the caller never asked for a hide")

        service.removeClippingPlane(id: planeID)

        #expect(service.modelBodyIsVisible("part") == true)
    }

    @MainActor
    @Test("A caller hide placed on a fully clipped body outlasts the plane")
    func callerHideOnFullyClippedBodyOutlastsThePlane() {
        guard let service = CADViewportService.withBoxes(ids: ["part"]) else { return }
        let planeID = service.addFullClip()

        service.visibility["part"] = false
        service.removeClippingPlane(id: planeID)

        #expect(service.modelBodyIsVisible("part") == false)
        #expect(service.visibility["part"] == false)
    }

    // MARK: - Escalation previews

    @MainActor
    @Test("Showing a capped model body as an escalation preview survives the cap changing")
    func escalationPreviewOnCappedBodyStaysShown() {
        guard let service = CADViewportService.withBoxes(ids: ["part"]) else { return }
        service.visibility["part"] = false
        let planeID = service.addHalfCap()
        #expect(
            service.modelBodyIsVisible("part") == false,
            "sanity check: capping keeps the caller's hide")

        let request = EscalationRequest(
            id: "req1", entities: [], question: "Which one?",
            candidates: [EscalationCandidate(id: "c", label: "C", previewBodyID: "part")])
        service.beginPresenting(request)
        #expect(service.modelBodyIsVisible("part") == true)

        fire(.moveCapPlane, on: service)
        #expect(
            service.modelBodyIsVisible("part") == true,
            "moving the cut must not re-hide the preview")

        service.removeClippingPlane(id: planeID)
        #expect(
            service.modelBodyIsVisible("part") == true,
            "removing the cap must not re-hide the preview")
    }
}
