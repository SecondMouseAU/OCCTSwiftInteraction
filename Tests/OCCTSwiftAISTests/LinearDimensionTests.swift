import OCCTSwift
import OCCTSwiftViewport
import Testing
import simd

@testable import OCCTSwiftAIS

@MainActor
@Suite("LinearDimension")
struct LinearDimensionTests {

    private func makeContext() -> InteractiveContext {
        InteractiveContext(viewport: ViewportController())
    }

    private func makeBox() throws -> OCCTSwift.Shape {
        try #require(OCCTSwift.Shape.box(width: 10, height: 5, depth: 3))
    }

    // MARK: - Anchor resolution

    @Test func t_vertexAnchor_resolvesToVertexPosition() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let p0 = try #require(obj.shape.vertex(at: 0))
        let p1 = try #require(obj.shape.vertex(at: 1))

        let dim = LinearDimension(
            from: .vertex(obj, ref: try vertexRef(obj, 0)),
            to: .vertex(obj, ref: try vertexRef(obj, 1))
        )
        let pts = dim.anchorPoints
        #expect(pts.count == 2)
        #expect(simd_distance(pts[0], SIMD3<Float>(Float(p0.x), Float(p0.y), Float(p0.z))) < 1e-5)
        #expect(simd_distance(pts[1], SIMD3<Float>(Float(p1.x), Float(p1.y), Float(p1.z))) < 1e-5)
    }

    @Test func t_distance_betweenTwoVertices_matchesEuclidean() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let dim = LinearDimension(
            from: .vertex(obj, ref: try vertexRef(obj, 0)),
            to: .vertex(obj, ref: try vertexRef(obj, 6))  // diagonal corner of a box
        )
        let pts = dim.anchorPoints
        let expected = simd_distance(pts[0], pts[1])
        #expect(abs(dim.distance - expected) < 1e-5)
    }

    @Test func t_label_formatsDistance() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        // Two adjacent corners along the width axis (10 units).
        let dim = LinearDimension(
            from: .vertex(obj, ref: try vertexRef(obj, 0)),
            to: .vertex(obj, ref: try vertexRef(obj, 1))
        )
        // dim.distance should be ~10 → label formatted with 1 decimal.
        let formatted = dim.label
        #expect(!formatted.isEmpty)
        #expect(
            formatted == "10.0" || formatted == "5.00" || formatted == "3.00",
            "expected an axis-aligned edge length, got \(formatted)")
    }

    @Test func t_customLabel_overridesFormatted() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let dim = LinearDimension(
            from: .vertex(obj, ref: try vertexRef(obj, 0)),
            to: .vertex(obj, ref: try vertexRef(obj, 1)),
            customLabel: "WIDTH"
        )
        #expect(dim.label == "WIDTH")
    }

    @Test func t_edgeAnchor_resolvesToEdgeMidpoint() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        guard let edge = obj.shape.edge(at: 0) else {
            Issue.record("box should have at least one edge")
            return
        }
        let ends = edge.endpoints
        let expectedMid = SIMD3<Float>(
            Float((ends.start.x + ends.end.x) * 0.5),
            Float((ends.start.y + ends.end.y) * 0.5),
            Float((ends.start.z + ends.end.z) * 0.5)
        )
        let dim = LinearDimension(
            from: .edge(obj, ref: try edgeRef(obj, 0)),
            to: .edge(obj, ref: try edgeRef(obj, 0))
        )
        let pts = dim.anchorPoints
        #expect(simd_distance(pts[0], expectedMid) < 1e-5)
        #expect(simd_distance(pts[1], expectedMid) < 1e-5)
        #expect(dim.distance < 1e-5, "same edge to itself → zero distance")
    }

    @Test func t_faceAnchor_resolvesToFaceBboxCenter() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let dim = LinearDimension(
            from: .face(obj, ref: try faceRef(obj, 0)),
            to: .face(obj, ref: try faceRef(obj, 1))
        )
        let pts = dim.anchorPoints
        // For a box, opposite faces' centers are separated by exactly one of
        // the box dimensions (10, 5, or 3, depending on which faces 0 / 1 are).
        // Just verify the distance is one of the box's extents.
        let candidates: [Float] = [10, 5, 3]
        #expect(
            candidates.contains { abs(dim.distance - $0) < 0.5 },
            "face-to-face distance \(dim.distance) should match a box dimension")
        _ = pts
    }

    @Test func t_bodyAnchor_resolvesToBodyBboxCenter() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let (lo, hi) = try #require(obj.shape.bounds)
        let expected = SIMD3<Float>(
            Float((lo.x + hi.x) * 0.5),
            Float((lo.y + hi.y) * 0.5),
            Float((lo.z + hi.z) * 0.5)
        )
        let dim = LinearDimension(
            from: .body(obj),
            to: .body(obj)
        )
        let pts = dim.anchorPoints
        #expect(simd_distance(pts[0], expected) < 1e-5)
        #expect(dim.distance < 1e-5)
    }

    // MARK: - Plane projection

    @Test func t_planeProjection_anchorsLandOnPlane_andDistanceShrinks() throws {
        // Find a pair of box vertices with significantly different Z so that
        // projection onto Z=0 actually changes the distance; OCCT's vertex
        // enumeration order isn't load-bearing on the test.
        let ctx = makeContext()
        let shape = try #require(OCCTSwift.Shape.box(width: 6, height: 4, depth: 8))
        let obj = ctx.display(shape)
        let plane = WorkPlane(origin: .zero, normal: SIMD3<Float>(0, 0, 1))

        var pickedPair: (Int, Int)?
        outer: for i in 0..<obj.shape.vertexCount {
            for j in (i + 1)..<obj.shape.vertexCount {
                guard let pi = obj.shape.vertex(at: i),
                    let pj = obj.shape.vertex(at: j)
                else { continue }
                if abs(pi.z - pj.z) > 1.0 {
                    pickedPair = (i, j)
                    break outer
                }
            }
        }
        let (a, b) = try #require(pickedPair)

        let unprojected = LinearDimension(
            from: .vertex(obj, ref: try vertexRef(obj, a)),
            to: .vertex(obj, ref: try vertexRef(obj, b))
        )
        let projected = LinearDimension(
            from: .vertex(obj, ref: try vertexRef(obj, a)),
            to: .vertex(obj, ref: try vertexRef(obj, b)),
            plane: plane
        )

        // Projection cannot grow the distance (orthogonal projection).
        #expect(projected.distance <= unprojected.distance + 1e-5)
        // And with a >1.0 ΔZ it must actually shrink.
        #expect(projected.distance < unprojected.distance - 0.01)
        // Both anchors should lie on the Z=0 plane.
        for p in projected.anchorPoints {
            #expect(abs(p.z) < 1e-5, "projected anchor z=\(p.z) should be 0")
        }
    }

    @Test func t_anchorProject_zeroesNormalComponent() {
        let plane = WorkPlane(origin: .zero, normal: SIMD3<Float>(0, 0, 1))
        let p = SIMD3<Float>(3, 4, 7)
        let projected = DimensionAnchor.project(p, onto: plane)
        #expect(abs(projected.x - 3) < 1e-5)
        #expect(abs(projected.y - 4) < 1e-5)
        #expect(abs(projected.z) < 1e-5)
    }

    // MARK: - InteractiveContext glue

    @Test func t_add_pushesViewportMeasurement() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let dim = LinearDimension(
            from: .vertex(obj, ref: try vertexRef(obj, 0)),
            to: .vertex(obj, ref: try vertexRef(obj, 1))
        )
        ctx.add(dim)
        #expect(ctx.viewport.measurements.count == 1)
        #expect(ctx.viewport.measurements.first?.id == dim.id)
        #expect(ctx.dimensions.count == 1)
    }

    @Test func t_add_isIdempotentForSameInstance() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let dim = LinearDimension(
            from: .vertex(obj, ref: try vertexRef(obj, 0)),
            to: .vertex(obj, ref: try vertexRef(obj, 1))
        )
        ctx.add(dim)
        ctx.add(dim)
        ctx.add(dim)
        #expect(ctx.viewport.measurements.count == 1)
        #expect(ctx.dimensions.count == 1)
    }

    @Test func t_remove_dropsMeasurementAndUnregisters() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let dim = LinearDimension(
            from: .vertex(obj, ref: try vertexRef(obj, 0)),
            to: .vertex(obj, ref: try vertexRef(obj, 1))
        )
        ctx.add(dim)
        ctx.remove(dim)
        #expect(ctx.viewport.measurements.isEmpty)
        #expect(ctx.dimensions.isEmpty)
    }

    @Test func t_removeAll_dropsDimensionsToo() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let a = LinearDimension(
            from: .vertex(obj, ref: try vertexRef(obj, 0)),
            to: .vertex(obj, ref: try vertexRef(obj, 1)))
        let b = LinearDimension(
            from: .vertex(obj, ref: try vertexRef(obj, 2)),
            to: .vertex(obj, ref: try vertexRef(obj, 3)))
        ctx.add(a)
        ctx.add(b)
        #expect(ctx.viewport.measurements.count == 2)
        ctx.removeAll()
        #expect(ctx.viewport.measurements.isEmpty)
        #expect(ctx.dimensions.isEmpty)
    }

    @Test func t_refreshDimensionMeasurement_updatesInPlace() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let dim = LinearDimension(
            from: .vertex(obj, ref: try vertexRef(obj, 0)),
            to: .vertex(obj, ref: try vertexRef(obj, 1)),
            customLabel: "before"
        )
        ctx.add(dim)
        if case .distance(let m) = ctx.viewport.measurements.first {
            #expect(m.label == "before")
        }
        dim.customLabel = "after"
        ctx.refreshDimensionMeasurement(dim)
        if case .distance(let m) = ctx.viewport.measurements.first {
            #expect(m.label == "after")
        }
    }

    // MARK: - viewportMeasurement payload

    @Test func t_viewportMeasurement_isDistanceVariant() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let dim = LinearDimension(
            from: .vertex(obj, ref: try vertexRef(obj, 0)),
            to: .vertex(obj, ref: try vertexRef(obj, 1))
        )
        if case .distance(let m) = dim.viewportMeasurement {
            #expect(m.id == dim.id)
            #expect(m.label == nil, "nil label on the measurement → renderer formats")
        } else {
            Issue.record("expected .distance variant")
        }
    }
}
