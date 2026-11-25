import Foundation
import OCCTSwift
import OCCTSwiftTools
import OCCTSwiftViewport
import Testing
import simd

@testable import OCCTSwiftCADKit

/// Regression coverage for OCCTSwiftInteraction#82: a cap recut, and the restore when the cap goes,
/// mesh a body as its load did.
///
/// A body loaded through `load(_:id:transform:)` is meshed at `meshDeflection` as it stood at the
/// load, and a file-loaded body with `CADFileLoader`'s own settings for the format, which ignore
/// `meshDeflection`. The restored body is compared with the load, and the cut with the same cut of
/// a freshly made shape meshed with the load's settings, by triangle count.
///
/// Every comparison mesh is of a fresh shape. OCCT keeps a shape's triangulation on its faces and
/// meshes a face again only when what it holds is coarser than asked for, so meshing one of the
/// service's own shapes would both read back what the service left there and change what it meshes
/// next.
@Suite("A cap recut meshes a body as its load did")
struct CapMeshingTests {
    /// The number of triangles `body` draws, 0 for `nil`.
    static func triangleCount(_ body: _ViewportBody?) -> Int {
        body.map { $0.indices.count / 3 } ?? 0
    }

    /// The number of triangles `shape` meshes to with `deflection` (`nil` for the loader's
    /// default).
    static func triangleCount(of shape: Shape, deflection: Double?) -> Int {
        triangleCount(
            CADFileLoader.shapeToBodyAndMetadata(
                shape, id: "fresh", color: .one, deflection: deflection
            ).0)
    }

    /// The piece of `shape` a cap plane through `origin` with unit normal `normal` keeps.
    static func keptPiece(of shape: Shape, origin: SIMD3<Double>, normal: SIMD3<Double>) -> Shape? {
        shape.split(atPlane: origin, normal: normal)?.first { piece in
            guard let bounds = piece.bounds else { return false }
            return simd_dot(normal, (bounds.min + bounds.max) / 2 - origin) >= 0
        }
    }

    /// What `meshDeflection` is set to after the load and before the cap.
    enum Later: CaseIterable, Sendable, CustomTestStringConvertible {
        case unchanged
        case cleared
        case finer

        var deflection: Double? {
            switch self {
            case .unchanged: 2.0
            case .cleared: nil
            // Finer than the sphere's angular limit, which already decides the mesh at 0.5.
            case .finer: 0.05
            }
        }

        var testDescription: String {
            switch self {
            case .unchanged: "meshDeflection left at the load's"
            case .cleared: "meshDeflection cleared after the load"
            case .finer: "meshDeflection made finer after the load"
            }
        }
    }

    /// Fails without the fix in every case.
    ///
    /// A fix that meshes at the current `meshDeflection` rather than the load's passes only
    /// `.unchanged`.
    @MainActor
    @Test(
        "A shape loaded at a meshDeflection is recut and restored at that deflection",
        arguments: Later.allCases)
    func recutKeepsTheLoadDeflection(_ later: Later) throws {
        let service = CADViewportService()
        service.meshDeflection = 2.0
        service.load(try #require(Shape.sphere(radius: 10)), id: "s")
        let loaded = Self.triangleCount(service.modelBody("s"))
        func freshSphere() throws -> Shape { try #require(Shape.sphere(radius: 10)) }
        try #require(
            loaded == Self.triangleCount(of: try freshSphere(), deflection: 2.0)
                && loaded != Self.triangleCount(of: try freshSphere(), deflection: nil),
            "sanity check: the sphere was loaded at 2.0, which meshes unlike the loader's default")
        if later != .unchanged {
            try #require(
                loaded != Self.triangleCount(of: try freshSphere(), deflection: later.deflection),
                "sanity check: the setting after the load meshes the sphere differently")
        }
        service.meshDeflection = later.deflection

        let planeID = service.addHalfCap()
        try #require(
            service.shape(id: "s")?.bounds.map { $0.min.x > -5 } == true,
            "sanity check: the sphere is capped")
        let freshCut = try #require(
            Self.keptPiece(of: try freshSphere(), origin: .zero, normal: SIMD3(1, 0, 0)))
        #expect(
            Self.triangleCount(service.modelBody("s"))
                == Self.triangleCount(of: freshCut, deflection: 2.0),
            "the cut is meshed at the deflection the sphere was loaded at")

        service.removeClippingPlane(id: planeID)
        #expect(
            Self.triangleCount(service.modelBody("s")) == loaded,
            "the restored sphere is meshed as it was loaded")
    }

    /// Guard: passes without the fix.
    ///
    /// A file load and the old re-mesh both used the loader's default. This fails a fix that meshes
    /// the cut at the current `meshDeflection`.
    @MainActor
    @Test("A file-loaded body is recut and restored with its load's settings, not meshDeflection")
    func fileLoadKeepsItsSettings() async throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "multibody-three-solids", withExtension: "brep",
                subdirectory: "Fixtures"))
        let service = CADViewportService()
        service.meshDeflection = 2.0
        _ = try await service.loadFile(from: url, id: "asm")
        // The fixture's cylinder: radius 3 and height 8 about the Z axis, at X = 30 and Z = -4...4.
        let id = "asm-1"
        func freshCylinder() -> Shape? {
            Shape.cylinder(radius: 3, height: 8)?.translated(by: SIMD3(30, 0, -4))
        }
        let (freshDefault, freshCoarse, freshToCut) = try #require(
            freshCylinder().flatMap { a in
                freshCylinder().flatMap { b in freshCylinder().map { (a, b, $0) } }
            })
        let loaded = Self.triangleCount(service.modelBody(id))
        try #require(
            loaded == Self.triangleCount(of: freshDefault, deflection: nil)
                && loaded != Self.triangleCount(of: freshCoarse, deflection: 2.0),
            "sanity check: the file load ignored meshDeflection, which meshes differently")

        let origin = SIMD3<Double>(30, 0, 0)
        let normal = SIMD3<Double>(1, 0, 0)
        let planeID = service.addClippingPlane(origin: origin, normal: normal, showCapSurface: true)
        try #require(
            service.bodyShapes[id]?.bounds.map { $0.min.x > 29 } == true,
            "sanity check: the cylinder is capped")
        let freshCut = try #require(Self.keptPiece(of: freshToCut, origin: origin, normal: normal))
        #expect(
            Self.triangleCount(service.modelBody(id))
                == Self.triangleCount(of: freshCut, deflection: nil),
            "the cut is meshed with the file load's settings")

        service.removeClippingPlane(id: planeID)
        #expect(
            Self.triangleCount(service.modelBody(id)) == loaded,
            "the restored cylinder is meshed as it was loaded")
    }
}
