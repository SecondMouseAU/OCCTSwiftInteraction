import Foundation
import OCCTSwift
import OCCTSwiftTools
import OCCTSwiftViewport
import Testing
import simd

@testable import OCCTSwiftAIS

@MainActor
@Suite("STEP integration: committed stock fixtures", .serialized)
struct STEPStockIntegrationTests {

    /// The stock fixtures committed under `Tests/OCCTSwiftAISTests/Fixtures/`.
    ///
    /// Each is a small (~16 KB) STEP file representing a rectangular block of
    /// 6 mm-thick raw stock.
    nonisolated static let stockFixtures: [String] = [
        "101-CAM_test_1_6mm_stock",
        "101-CAM_Test_2_6mm_stock",
        "101-CAM_test_3_6mm_stock",
    ]

    private func fixtureURL(_ name: String) throws -> URL {
        try #require(
            Bundle.module.url(forResource: name, withExtension: "step", subdirectory: "Fixtures"),
            "missing fixture \(name).step"
        )
    }

    private func loadStock(_ name: String) async throws -> (CADLoadResult, OCCTSwift.Shape) {
        let url = try fixtureURL(name)
        let result = try await CADFileLoader.load(from: url, format: .step)
        let shape = try #require(result.shapes.first, "STEP \(name) had no shapes")
        return (result, shape)
    }

    // MARK: - Loading + topology

    @Test(arguments: stockFixtures)
    func t_load_succeedsAndYieldsExactlyOneShape(name: String) async throws {
        let (result, _) = try await loadStock(name)
        #expect(
            result.shapes.count == 1, "expected one shape in \(name), got \(result.shapes.count)")
        #expect(!result.bodies.isEmpty, "expected at least one body in \(name)")
    }

    @Test(arguments: stockFixtures)
    func t_stockHasNoCircularEdges(name: String) async throws {
        // The CAM simulation's stock blanks are pure rectangular blocks; any
        // circular edge would mean we're not looking at a raw stock.
        let (_, shape) = try await loadStock(name)
        for i in 0..<shape.edgeCount {
            guard let edge = shape.edge(at: i) else { continue }
            #expect(
                edge.isCircle == false,
                "\(name): stock edge \(i) shouldn't be circular (rectangular block)")
        }
    }

    @Test(arguments: stockFixtures)
    func t_stockTopology_matchesRectangularBlock(name: String) async throws {
        let (_, shape) = try await loadStock(name)
        // 6mm stock = a rectangular block. Six faces, twelve edges, eight vertices.
        #expect(
            shape.subShapeCount(ofType: .face) == 6,
            "\(name): expected 6 faces (rectangular block), got \(shape.subShapeCount(ofType: .face))"
        )
        #expect(
            shape.edgeCount == 12,
            "\(name): expected 12 edges, got \(shape.edgeCount)")
        #expect(
            shape.vertexCount == 8,
            "\(name): expected 8 vertices, got \(shape.vertexCount)")
    }

    @Test(arguments: stockFixtures)
    func t_stockBounds_areNonDegenerateAndPositive(name: String) async throws {
        let (_, shape) = try await loadStock(name)
        // A stock fixture is a real solid, so a void bbox is itself a failure.
        let (lo, hi) = try #require(shape.bounds)
        let extents = SIMD3<Double>(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z)
        // All three extents positive (non-degenerate solid).
        #expect(extents.x > 1.0, "\(name): X extent should be positive, got \(extents.x)")
        #expect(extents.y > 1.0, "\(name): Y extent should be positive, got \(extents.y)")
        #expect(extents.z > 1.0, "\(name): Z extent should be positive, got \(extents.z)")
        // None of the extents wildly exceed the bbox diagonal of a typical
        // CAM stock plate (a few hundred mm).
        let diag = sqrt(extents.x * extents.x + extents.y * extents.y + extents.z * extents.z)
        #expect(diag < 10000, "\(name): bbox diagonal \(diag) suspiciously large")
    }

    // MARK: - Display + face round-trip

    @Test(arguments: stockFixtures)
    func t_display_producesNonTrivialMesh(name: String) async throws {
        let (_, shape) = try await loadStock(name)
        let ctx = InteractiveContext(viewport: ViewportController())
        let obj = ctx.display(shape)
        let body = try #require(ctx.sourceBody(for: obj))
        #expect(body.indices.count > 0, "tessellation produced no triangles for \(name)")
        #expect(body.indices.count % 3 == 0)
        #expect(
            body.faceIndices.count == body.indices.count / 3,
            "faceIndices should be parallel to triangles for \(name)")
        #expect(!body.vertices.isEmpty, "vertex picking buffer should be populated")
        #expect(!body.edgeIndices.isEmpty, "edge picking buffer should be populated")
    }

    @Test(arguments: stockFixtures)
    func t_handlePick_kindFace_roundTripsToFace(name: String) async throws {
        let (_, shape) = try await loadStock(name)
        let ctx = InteractiveContext(viewport: ViewportController())
        ctx.selectionMode = [.face]
        let obj = ctx.display(shape)
        let body = try #require(ctx.sourceBody(for: obj))
        try #require(!body.faceIndices.isEmpty)

        // Synthesise a face pick on triangle 0 (whatever face that lands on).
        let primIdx = 0
        let expectedFace = Int(body.faceIndices[primIdx])
        let raw =
            UInt32(0)
            | (UInt32(primIdx & 0x3FFF) << 16)
            | (UInt32(PrimitiveKind.face.rawValue) << 30)
        let pick = try #require(PickResult(rawValue: raw, indexMap: [0: body.id]))

        ctx.handlePick(pick)

        #expect(containsFace(ctx.selection.subshapes, obj, ordinal: expectedFace))
        #expect(ctx.selection.faces.count == 1)
    }

    @Test(arguments: stockFixtures)
    func t_handlePick_kindVertex_roundTripsToVertex(name: String) async throws {
        let (_, shape) = try await loadStock(name)
        let ctx = InteractiveContext(viewport: ViewportController())
        ctx.selectionMode = [.vertex]
        let obj = ctx.display(shape)
        let body = try #require(ctx.sourceBody(for: obj))
        try #require(!body.vertexIndices.isEmpty)

        let primIdx = 0
        let expectedVertex = Int(body.vertexIndices[primIdx])
        let raw =
            UInt32(0)
            | (UInt32(primIdx & 0x3FFF) << 16)
            | (UInt32(PrimitiveKind.vertex.rawValue) << 30)
        let pick = try #require(PickResult(rawValue: raw, indexMap: [0: body.id]))

        ctx.handlePick(pick)

        #expect(containsVertex(ctx.selection.subshapes, obj, ordinal: expectedVertex))
        #expect(ctx.selection.vertices.count == 1)
        let resolved = try #require(ctx.selection.vertices.first)
        let direct = try #require(shape.vertex(at: expectedVertex))
        #expect(simd_distance(resolved, direct) < 1e-5)
    }

    // MARK: - Dimensions on real geometry

    @Test(arguments: stockFixtures)
    func t_linearDimensionAcrossOppositeFaces_matchesStockExtent(name: String) async throws {
        let (_, shape) = try await loadStock(name)
        let ctx = InteractiveContext(viewport: ViewportController())
        let obj = ctx.display(shape)

        // For a 6-face block, opposite faces have parallel normals. Group faces
        // by (rounded) normal direction; pick a pair, dimension between them.
        var byNormal: [SIMD3<Int>: Int] = [:]
        for i in 0..<shape.subShapeCount(ofType: .face) {
            guard let faceShape = shape.subShape(type: .face, index: i),
                let face = OCCTSwift.Face(faceShape),
                let normal = face.normal
            else { continue }
            // Quantise so opposite normals collide on the same key.
            let absNx: Double = normal.x < 0 ? -normal.x : normal.x
            let absNy: Double = normal.y < 0 ? -normal.y : normal.y
            let absNz: Double = normal.z < 0 ? -normal.z : normal.z
            let key = SIMD3<Int>(
                Int((absNx * 100).rounded()),
                Int((absNy * 100).rounded()),
                Int((absNz * 100).rounded()))
            byNormal[key, default: 0] += 1
        }
        // Should have three pairs of opposing faces.
        #expect(
            byNormal.values.allSatisfy { $0 == 2 },
            "\(name): expected three pairs of opposing faces, got \(byNormal)")

        // Build a dimension across the first parallel pair found.
        let firstPair = try #require(findOppositeFacePair(in: shape))
        let dim = LinearDimension(
            from: .face(obj, ref: try faceRef(obj, firstPair.0)),
            to: .face(obj, ref: try faceRef(obj, firstPair.1))
        )
        ctx.add(dim)
        // Distance must approximate one of the box's three extents.
        let (lo, hi) = try #require(shape.bounds)
        let extents: [Float] = [Float(hi.x - lo.x), Float(hi.y - lo.y), Float(hi.z - lo.z)]
        let matchesExtent = extents.contains { abs(dim.distance - $0) < 0.05 }
        #expect(
            matchesExtent,
            "\(name): dimension distance \(dim.distance) doesn't match any extent in \(extents)")
    }

    /// Find the first pair of face indices whose face normals are anti-parallel.
    ///
    /// Returns nil if none found (shouldn't happen for a rectangular block).
    private func findOppositeFacePair(in shape: OCCTSwift.Shape) -> (Int, Int)? {
        let count = shape.subShapeCount(ofType: .face)
        var normals: [(idx: Int, n: SIMD3<Double>)] = []
        for i in 0..<count {
            guard let faceShape = shape.subShape(type: .face, index: i),
                let face = OCCTSwift.Face(faceShape),
                let normal = face.normal
            else { continue }
            normals.append((i, normal))
        }
        for i in 0..<normals.count {
            for j in (i + 1)..<normals.count {
                let dot = simd_dot(normals[i].n, normals[j].n)
                if dot < -0.95 {  // ~anti-parallel
                    return (normals[i].idx, normals[j].idx)
                }
            }
        }
        return nil
    }

    // MARK: - Selection mutation cycle (sanity check)

    @Test func t_update_survivesMutationThatNeverTouchesTheSelectedFace() async throws {
        let (_, shape) = try await loadStock(Self.stockFixtures[0])
        let ctx = InteractiveContext(viewport: ViewportController())
        ctx.selectionMode = [.face]
        let obj = ctx.display(shape)
        let body = try #require(ctx.sourceBody(for: obj))
        try #require(!body.faceIndices.isEmpty)

        let primIdx = 0
        let expectedFace = Int(body.faceIndices[primIdx])
        let raw = UInt32(primIdx & 0x3FFF) << 16 | (UInt32(PrimitiveKind.face.rawValue) << 30)
        let pick = try #require(PickResult(rawValue: raw, indexMap: [0: body.id]))
        ctx.handlePick(pick)
        #expect(containsFace(ctx.selection.subshapes, obj, ordinal: expectedFace))

        // A tool positioned well outside the stock's bounds: the boolean
        // subtract is a geometric no-op, so the selected face's node has no
        // history record and survives via `findDerivedOrSelf`'s untouched case.
        let (lo, hi) = try #require(shape.bounds)
        let farAway = try #require(
            OCCTSwift.Shape.box(
                origin: SIMD3<Double>(hi.x + 1000, hi.y + 1000, hi.z + 1000),
                width: 1, height: 1, depth: 1
            ))
        let (result, history) = try #require(shape.subtractedWithFullHistory(farAway))

        let updated = try #require(
            ctx.update(obj, to: result, absorbing: history, operationName: "no-op-cut"))
        #expect(
            !ctx.selection.isEmpty, "a face never touched by the mutation should survive the update"
        )
        #expect(ctx.selection.subshapes.allSatisfy { $0.object == updated })
    }
}

// MARK: - WIP fixtures (large, gitignored, skip when missing)

@MainActor
@Suite("STEP integration: local WIP fixtures (skip-on-missing)", .serialized)
struct STEPWIPIntegrationTests {

    /// The WIP fixtures expected to live in the repo's `test_files/` directory.
    ///
    /// Anyone without them gets a graceful skip: these files are too big
    /// (~5–8 MB each) to commit.
    nonisolated static let wipFixtures: [String] = [
        "101-CAM_test_1_6mm_wip",
        "101-CAM_Test_2_6mm_wip",
        "101-CAM_test_3_6mm_wip",
    ]

    /// Look up a WIP file by walking up from the test bundle to the package
    /// root, then into `test_files/`.
    ///
    /// Returns nil if not present.
    private func wipURL(_ name: String) -> URL? {
        let bundleURL = Bundle.module.bundleURL
        // Walk up looking for the package root (one with `Package.swift`).
        var dir = bundleURL.deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent("test_files").appendingPathComponent(
                "\(name).step")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            let pkgManifest = dir.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: pkgManifest.path) {
                let alt = dir.appendingPathComponent("test_files").appendingPathComponent(
                    "\(name).step")
                if FileManager.default.fileExists(atPath: alt.path) { return alt }
                return nil
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// Walk the WIP shape's edges and return the first `isCircle` index, if any.
    private func firstCircularEdgeIndex(of shape: OCCTSwift.Shape) -> Int? {
        for i in 0..<shape.edgeCount {
            if let edge = shape.edge(at: i), edge.isCircle { return i }
        }
        return nil
    }

    @Test(arguments: wipFixtures)
    func t_wipFile_hasCircularEdgesFromCutterPath(name: String) async throws {
        guard let url = wipURL(name) else { return }
        let result = try await CADFileLoader.load(from: url, format: .step)
        let shape = try #require(result.shapes.first)
        let circIdx = firstCircularEdgeIndex(of: shape)
        #expect(
            circIdx != nil,
            "\(name): WIP from a 6mm cutter simulation must have at least one circular edge")
    }

    @Test(arguments: wipFixtures)
    func t_wipFile_radialDimensionOnCutterFootprint_resolves(name: String) async throws {
        guard let url = wipURL(name) else { return }
        let result = try await CADFileLoader.load(from: url, format: .step)
        let shape = try #require(result.shapes.first)
        guard let circIdx = firstCircularEdgeIndex(of: shape) else {
            Issue.record("\(name): no circular edges to dimension")
            return
        }

        let ctx = InteractiveContext(viewport: ViewportController())
        let obj = ctx.display(shape)
        let rad = RadialDimension(circularEdge: .edge(obj, ref: try edgeRef(obj, circIdx)))
        ctx.add(rad)

        // Radius is finite and positive: the round-trip through
        // `Edge.curve3D.circleProperties` produced a valid circle.
        #expect(rad.radius.isFinite)
        #expect(rad.radius > 0)
        #expect(rad.label.hasPrefix("R"), "default radius label, got \(rad.label)")
        // The viewport carries the measurement so the renderer will draw it.
        if case .radius = ctx.viewport.measurements.first {
        } else {
            Issue.record("expected a .radius measurement on viewport.measurements")
        }
    }

    @Test(arguments: wipFixtures)
    func t_wipFile_loadsAndIsMoreComplexThanStock(name: String) async throws {
        guard let url = wipURL(name) else {
            // Skip silently: file not present locally.
            return
        }
        let result = try await CADFileLoader.load(from: url, format: .step)
        let shape = try #require(result.shapes.first)
        // Machined parts should have substantially more topology than 6 faces.
        #expect(
            shape.subShapeCount(ofType: .face) > 6,
            "\(name): WIP should have more faces than stock (got \(shape.subShapeCount(ofType: .face)))"
        )
        #expect(shape.edgeCount > 12)
        #expect(shape.vertexCount > 8)

        // Display + sanity: the body has a non-trivial mesh and the picking
        // buffers are populated via Tools v0.5.0+.
        let ctx = InteractiveContext(viewport: ViewportController())
        let obj = ctx.display(shape)
        let body = try #require(ctx.sourceBody(for: obj))
        #expect(body.indices.count > 100, "\(name): expected a mesh of more than ~30 triangles")
        #expect(!body.vertices.isEmpty)
        #expect(!body.edgeIndices.isEmpty)

        // Pick triangle 0; the round-trip lands on a real face.
        let primIdx = 0
        let expectedFace = Int(body.faceIndices[primIdx])
        let raw =
            UInt32(0)
            | (UInt32(primIdx & 0x3FFF) << 16)
            | (UInt32(PrimitiveKind.face.rawValue) << 30)
        let pick = try #require(PickResult(rawValue: raw, indexMap: [0: body.id]))
        ctx.selectionMode = [.face]
        ctx.handlePick(pick)
        #expect(ctx.selection.faces.count == 1)
        #expect(containsFace(ctx.selection.subshapes, obj, ordinal: expectedFace))
    }
}
