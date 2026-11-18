import OCCTSwift
import OCCTSwiftViewport
import Testing
import simd

@testable import OCCTSwiftCADKit

/// Fixtures shared by the suites that check a caller's visibility against the snapshots
/// `updateCapSurfaces` and `undoComparison` restore from (OCCTSwiftInteraction#46, #48).
@MainActor
extension CADViewportService {
    /// A service holding one 4x4x4 box centred on the origin per id, or `nil` if the kernel
    /// cannot make one.
    static func withBoxes(ids: [String]) -> CADViewportService? {
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
    @discardableResult
    func addHalfCap() -> String {
        addClippingPlane(origin: .zero, normal: SIMD3(1, 0, 0), showCapSurface: true)
    }

    /// Adds a cap plane at X = 10 that clips every box away entirely.
    @discardableResult
    func addFullClip() -> String {
        addClippingPlane(origin: SIMD3(10, 0, 0), normal: SIMD3(1, 0, 0), showCapSurface: true)
    }

    /// Loads a small box far from the others, which runs `updateCapSurfaces()` without being about
    /// any entity under test.
    func loadUnrelatedEntity() {
        guard let small = Shape.box(width: 1, height: 1, depth: 1) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let farAway: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1, 50, 0, 0]
        load(small, id: "unrelated", transform: farAway)
    }

    /// Adds a hollow plane no box comes near, which runs `updateCapSurfaces()` without being about
    /// any entity under test.
    @discardableResult
    func addUnrelatedHollowPlane() -> String {
        addClippingPlane(origin: SIMD3(0, 0, 100), normal: SIMD3(0, 0, 1), showCapSurface: false)
    }

    /// Whether the model body `id` is currently visible, or `nil` if there is no such body.
    func modelBodyIsVisible(_ id: String) -> Bool? {
        modelBodies.first { $0.id == id }?.isVisible
    }

    /// The smallest X of the shape the entity `id` owns, or `nil` if it has none.
    func entityMinX(_ id: String) -> Double? {
        shape(id: id)?.bounds?.min.x
    }
}
