import Foundation
import OCCTSwift
import OCCTSwiftViewport
import Testing
import simd

@testable import OCCTSwiftTools

/// `CADLoadResult.identity` (OCCTSwiftInteraction#7): identity built inside the load, keyed by
/// body id.
///
/// Before this, `CADFileLoader.load(from:format:)` returned `bodies`, `metadata` and `shapes` and
/// no tables, so every consumer that wanted identity after a file load paired `shapes[i]` with
/// `bodies[i]` itself. That pairing is not safe: the STL/IGES robust reload appends a shape even
/// when that input produced no body, shifting every later pairing so a body can be handed another
/// body's geometry. Two consumers found the hazard independently and guarded it two different
/// ways; a third did not guard it at all until told. Keying by body id inside the loader removes
/// the pairing rather than guarding it.
@Suite("CADFileLoader identity")
struct CADFileLoaderIdentityTests {

    /// Two solids of visibly different size, written to a BREP file.
    ///
    /// Lets a real multi-body load be driven end to end. The sizes differ so a shifted pairing
    /// changes the bounding box, which is what the pairing assertions key on.
    private static func writeTwoBodyBREP() throws -> (url: URL, dir: URL)? {
        guard let small = Shape.box(width: 4, height: 4, depth: 4),
            let largeUnplaced = Shape.box(width: 12, height: 12, depth: 12),
            let large = largeUnplaced.translated(by: SIMD3<Double>(40, 0, 0)),
            let compound = Shape.compound([small, large])
        else { return nil }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("int7-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("two-bodies.brep")
        try compound.writeBREP(to: url)
        return (url, dir)
    }

    /// Off by default, because building it costs a `BRepGraph` per body and the headless
    /// consumers of this API (reprojection, batch render, parts extraction) never pick.
    @Test func t_identityIsEmptyUnlessAsked() async throws {
        guard let fixture = try Self.writeTwoBodyBREP() else {
            Issue.record("failed to build the two-body BREP fixture")
            return
        }
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        let result = try await CADFileLoader.load(from: fixture.url, format: .brep)
        #expect(result.bodies.count == 2, "fixture really is multi-body")
        #expect(result.identity.isEmpty, "identity is opt-in")
    }

    /// The whole point: one entry per body, keyed by that body's own id, with the shape it was
    /// actually tessellated from.
    ///
    /// Pairing is asserted by geometry rather than by position: each body's mesh bounding box has
    /// to match its identity shape's bounds. A shifted pairing would hand the 4mm body the 12mm
    /// shape (and vice versa), which this catches; comparing indices would not, because a shift
    /// keeps the indices perfectly plausible.
    @Test func t_identityIsKeyedByBodyIDAndPairedWithTheRightGeometry() async throws {
        guard let fixture = try Self.writeTwoBodyBREP() else {
            Issue.record("failed to build the two-body BREP fixture")
            return
        }
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        let result = try await CADFileLoader.load(
            from: fixture.url, format: .brep, includeIdentity: true)

        #expect(result.bodies.count == 2)
        #expect(
            Set(result.identity.keys) == Set(result.bodies.map(\.id)),
            "exactly one identity entry per body, keyed by body id")

        for body in result.bodies {
            guard let identity = result.identity[body.id] else {
                Issue.record("no identity for body \(body.id)")
                continue
            }
            guard let bodyBox = body.boundingBox, let shapeBox = identity.shape.bounds else {
                Issue.record("missing bounds for body \(body.id)")
                continue
            }
            // The mesh is a linear approximation of the solid, so allow a tolerance far smaller
            // than the 36mm gap between the two fixture bodies.
            let dx = abs(Double(bodyBox.min.x) - shapeBox.min.x)
            let dy = abs(Double(bodyBox.min.y) - shapeBox.min.y)
            let dz = abs(Double(bodyBox.min.z) - shapeBox.min.z)
            #expect(
                dx < 0.5 && dy < 0.5 && dz < 0.5,
                "body \(body.id) paired with a shape whose bounds do not match its mesh")
            #expect(identity.graph != nil, "a closed solid should build a graph")
            #expect(identity.faces.shapes.count == 6)
        }
    }

    /// A pick resolves through the identity the load returned, with no consumer-side construction.
    ///
    /// This is the capability the issue says was missing: `load` returned no tables, so a real
    /// multi-body file load had no supported way to give a face pick a durable `GraphUID`.
    @Test func t_aPickResolvesThroughTheLoadedIdentityWithNoRebuild() async throws {
        guard let fixture = try Self.writeTwoBodyBREP() else {
            Issue.record("failed to build the two-body BREP fixture")
            return
        }
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        let result = try await CADFileLoader.load(
            from: fixture.url, format: .brep, includeIdentity: true)

        var resolvedUIDs: Set<BRepGraph.GraphUID> = []
        for body in result.bodies {
            guard let identity = result.identity[body.id],
                let meta = result.metadata[body.id]
            else {
                Issue.record("no identity or metadata for body \(body.id)")
                continue
            }
            guard
                let ref = SubShapePickResolver.resolveFace(
                    triangleIndex: 0, faceIndices: meta.faceIndices,
                    identity: identity.faces, shape: identity.shape)
            else {
                Issue.record("triangle 0 of \(body.id) did not resolve to a face")
                continue
            }
            guard let uid = ref.uid else {
                Issue.record("face pick on \(body.id) carried no durable uid")
                continue
            }
            resolvedUIDs.insert(uid)
        }
        #expect(
            resolvedUIDs.count == result.bodies.count,
            "each body's pick resolves to its own uid, minted from its own graph")
    }

    /// `loadFromManifest` takes the same switch, so the script-manifest path is not a second
    /// place a consumer has to rebuild tables from.
    @Test func t_manifestLoadTakesTheSameIdentitySwitch() throws {
        // Signature check rather than a full manifest fixture: this package's tests ship no
        // manifest on disk, and the parameter defaulting to `false` is the part worth pinning,
        // since a default of `true` would silently charge every existing caller a BRepGraph.
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("int7-absent-\(UUID().uuidString)")
            .appendingPathComponent("manifest.json")
        #expect(throws: (any Error).self) {
            _ = try CADFileLoader.loadFromManifest(at: missing, includeIdentity: true)
        }
        #expect(throws: (any Error).self) {
            _ = try CADFileLoader.loadFromManifest(at: missing)
        }
    }
}
