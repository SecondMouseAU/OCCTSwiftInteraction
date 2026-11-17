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

    /// A service holding one 4x4x4 box centred on the origin.
    @MainActor
    private func makeService(ids: [String] = ["part"]) -> CADViewportService? {
        let service = CADViewportService()
        for id in ids {
            guard let box = Shape.box(width: 4, height: 4, depth: 4) else {
                Issue.record("Shape.box returned nil")
                return nil
            }
            service.load(box, id: id)
        }
        return service
    }

    /// Adds the cap plane at X = 0 that cuts the negative-X half off every box.
    @MainActor
    @discardableResult
    private func addCap(to service: CADViewportService) -> String {
        service.addClippingPlane(origin: .zero, normal: SIMD3(1, 0, 0), showCapSurface: true)
    }

    @MainActor
    private func isShown(_ service: CADViewportService, _ id: String = "part") -> Bool? {
        service.modelBodies.first { $0.id == id }?.isVisible
    }

    @MainActor
    private func minX(_ service: CADViewportService, _ id: String = "part") -> Double? {
        service.shape(id: id)?.bounds?.min.x
    }

    @MainActor
    private func fire(_ trigger: Trigger, on service: CADViewportService) {
        switch trigger {
        case .resetClippingPlanes:
            service.clippingPlanes = service.clippingPlanes
        case .loadUnrelatedEntity:
            guard let small = Shape.box(width: 1, height: 1, depth: 1) else {
                Issue.record("Shape.box returned nil")
                return
            }
            let farAway: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1, 50, 0, 0]
            service.load(small, id: "unrelated", transform: farAway)
        case .addUnrelatedPlane:
            service.addClippingPlane(
                origin: SIMD3(0, 0, 100), normal: SIMD3(0, 0, 1), showCapSurface: false)
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
        guard let service = makeService() else { return }
        addCap(to: service)
        #expect((minX(service) ?? -2) > -0.5, "sanity check: the entity is actually capped")

        service.visibility["part"] = false
        #expect(isShown(service) == false)

        fire(trigger, on: service)

        #expect(isShown(service) == false, "the explicit hide must not be undone")
        #expect(service.visibility["part"] == false)
        #expect(
            service.interactiveContext.bodies.first { $0.id == "part" }?.isVisible == false,
            "the rendered body must stay hidden too")
        #expect((minX(service) ?? -2) > -0.5, "the cap itself must still be applied")
    }

    @MainActor
    @Test(
        "Hiding one capped entity leaves its neighbour's visibility alone",
        arguments: Trigger.allCases)
    func hidingOneCappedEntityLeavesTheOtherAlone(trigger: Trigger) {
        guard let service = makeService(ids: ["a", "b"]) else { return }
        addCap(to: service)

        service.visibility["a"] = false
        fire(trigger, on: service)

        #expect(isShown(service, "a") == false)
        #expect(isShown(service, "b") == true)
    }

    // MARK: - Un-hiding

    @MainActor
    @Test(
        "Showing an entity that was hidden before it was capped survives an unrelated recompute",
        arguments: Trigger.allCases)
    func shownCappedEntityStaysShown(trigger: Trigger) {
        guard let service = makeService() else { return }
        service.visibility["part"] = false
        addCap(to: service)
        #expect(isShown(service) == false, "sanity check: capping keeps the caller's hide")

        service.visibility["part"] = true
        #expect(isShown(service) == true)

        fire(trigger, on: service)

        #expect(isShown(service) == true, "the explicit show must not be undone")
        #expect(service.visibility["part"] == true)
    }

    // MARK: - Restore on plane removal

    @MainActor
    @Test(
        "Removing the cap returns the body to the visibility the caller last set",
        arguments: Scenario.allCases)
    func removingTheCapRestoresCallerVisibility(scenario: Scenario) {
        guard let service = makeService() else { return }

        if scenario == .hiddenBeforeCapping || scenario == .hiddenBeforeThenShownAfterCapping {
            service.visibility["part"] = false
        }
        let planeID = addCap(to: service)
        switch scenario {
        case .hiddenAfterCapping: service.visibility["part"] = false
        case .hiddenBeforeThenShownAfterCapping: service.visibility["part"] = true
        case .visibleThroughout, .hiddenBeforeCapping: break
        }

        service.removeClippingPlane(id: planeID)

        #expect(isShown(service) == scenario.finalVisibility)
        #expect(service.visibility["part"] == scenario.finalVisibility)
        #expect(
            abs((minX(service) ?? 0) - (-2)) < 0.01,
            "sanity check: removing the plane restored the original geometry")
    }

    @MainActor
    @Test("A body hidden only because a cap plane fully clipped it comes back when the plane goes")
    func fullyClippedBodyComesBackWhenPlaneIsRemoved() {
        guard let service = makeService() else { return }
        let planeID = service.addClippingPlane(
            origin: SIMD3(10, 0, 0), normal: SIMD3(1, 0, 0), showCapSurface: true)
        #expect(isShown(service) == false, "sanity check: the plane clips the whole box away")
        #expect(service.visibility["part"] == true, "the caller never asked for a hide")

        service.removeClippingPlane(id: planeID)

        #expect(isShown(service) == true)
    }

    @MainActor
    @Test("A caller hide placed on a fully clipped body outlasts the plane")
    func callerHideOnFullyClippedBodyOutlastsThePlane() {
        guard let service = makeService() else { return }
        let planeID = service.addClippingPlane(
            origin: SIMD3(10, 0, 0), normal: SIMD3(1, 0, 0), showCapSurface: true)

        service.visibility["part"] = false
        service.removeClippingPlane(id: planeID)

        #expect(isShown(service) == false)
        #expect(service.visibility["part"] == false)
    }

    // MARK: - Escalation previews

    @MainActor
    @Test("Showing a capped model body as an escalation preview survives the cap changing")
    func escalationPreviewOnCappedBodyStaysShown() {
        guard let service = makeService() else { return }
        service.visibility["part"] = false
        let planeID = addCap(to: service)
        #expect(isShown(service) == false, "sanity check: capping keeps the caller's hide")

        let request = EscalationRequest(
            id: "req1", entities: [], question: "Which one?",
            candidates: [EscalationCandidate(id: "c", label: "C", previewBodyID: "part")])
        service.beginPresenting(request)
        #expect(isShown(service) == true)

        fire(.moveCapPlane, on: service)
        #expect(isShown(service) == true, "moving the cut must not re-hide the preview")

        service.removeClippingPlane(id: planeID)
        #expect(isShown(service) == true, "removing the cap must not re-hide the preview")
    }
}
