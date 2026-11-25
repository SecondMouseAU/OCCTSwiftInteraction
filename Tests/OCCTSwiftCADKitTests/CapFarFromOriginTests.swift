import OCCTSwift
import OCCTSwiftTools
import Testing
import simd

@testable import OCCTSwiftCADKit

/// Regression coverage for OCCTSwiftInteraction#84: a cap plane cuts a body however far the body
/// lies from the plane's origin.
///
/// The cap's split, like `Shape.split(atPlane:normal:)`, cuts with a face reaching twice the body's
/// bounding-box diagonal each way from the point of the plane it is given, and `sectionSweep` puts
/// the plane's origin on an axis through the world origin. The body here is a 4x4x4 box centred at
/// X = 100, whose diagonal (about 6.9) is far short of the 100 between it and that origin, and a
/// sweep along Z keeps the half above the plane.
///
/// Every sub-shape is named by its bounding box, as in `CapRecutSelectionTests`. Every test fails
/// without the fix.
@Suite("A cap plane cuts a body far from the plane's origin")
struct CapFarFromOriginTests {
    typealias Box = CapRecutSelectionTests.Box

    /// The box's +Y face, from Z = `z` up: whole for -2, and as a sweep at `z` leaves it.
    static func plusYFace(fromZ z: Double = -2) -> Box {
        Box(SIMD3(98, 2, z), SIMD3(102, 2, 2))
    }

    /// The cap face a sweep at Z = `z` gives the box.
    static func capFace(atZ z: Double) -> Box {
        Box(SIMD3(98, -2, z), SIMD3(102, 2, z))
    }

    /// A service holding the 4x4x4 box placed at X = 100, as body `far`.
    @MainActor
    private static func service() -> CADViewportService? {
        guard let box = Shape.box(width: 4, height: 4, depth: 4) else {
            Issue.record("Shape.box returned nil")
            return nil
        }
        let service = CADViewportService()
        service.load(box, id: "far", transform: [1, 0, 0, 0, 1, 0, 0, 0, 1, 100, 0, 0])
        return service
    }

    @MainActor
    @Test("A sweep plane through the world origin caps a box at X = 100")
    func sweepCapsTheFarBox() throws {
        guard let service = Self.service() else { return }
        service.sectionSweep(axis: SIMD3(0, 0, 1), position: 0)

        let bounds = try #require(service.shape(id: "far")?.bounds)
        #expect(
            abs(bounds.min.z) < 1e-6 && abs(bounds.max.z - 2) < 1e-6,
            "the cut keeps Z >= 0, so the shape runs from the plane to the top, not \(bounds)")
        let lowest = service.modelBody("far").flatMap {
            HighlightGeometry.worldCentroids(of: $0).map(\.z).min()
        }
        #expect(
            lowest.map { $0 > -1e-4 } == true,
            "the mesh drawn is the cut one, with no triangle below the plane")
        #expect(
            service.ref(.face, ofBody: "far", at: Self.capFace(atZ: 0)) != nil,
            "the body has a cap face at the plane")
    }

    @MainActor
    @Test("A face selected on the far box follows the sweep as it cuts, moves and goes")
    func selectionOnTheFarBoxIsRemapped() throws {
        guard let service = Self.service() else { return }
        let face = try #require(
            service.ref(.face, ofBody: "far", at: Self.plusYFace()), "sanity check: the +Y face")
        service.selectSub(.face, face, ofBody: "far")

        service.sectionSweep(axis: SIMD3(0, 0, 1), position: 0)
        CapRecutSelectionTests.expectSelection(
            service, .face, ofBody: "far", names: [Self.plusYFace(fromZ: 0)], "sweep at Z = 0")
        CapRecutSelectionTests.expectHighlight(
            service, .face, ofBody: "far", lights: [Self.plusYFace(fromZ: 0)], "sweep at Z = 0")

        service.sectionSweep(axis: SIMD3(0, 0, 1), position: 1)
        CapRecutSelectionTests.expectSelection(
            service, .face, ofBody: "far", names: [Self.plusYFace(fromZ: 1)], "sweep at Z = 1")
        CapRecutSelectionTests.expectHighlight(
            service, .face, ofBody: "far", lights: [Self.plusYFace(fromZ: 1)], "sweep at Z = 1")

        service.clippingPlanes = []
        CapRecutSelectionTests.expectSelection(
            service, .face, ofBody: "far", names: [Self.plusYFace()], "sweep removed")
        CapRecutSelectionTests.expectHighlight(
            service, .face, ofBody: "far", lights: [Self.plusYFace()], "sweep removed")
    }
}
