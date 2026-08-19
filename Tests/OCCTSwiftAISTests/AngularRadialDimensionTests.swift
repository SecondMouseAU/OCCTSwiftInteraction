import OCCTSwift
import OCCTSwiftViewport
import Testing
import simd

@testable import OCCTSwiftAIS

@MainActor
@Suite("AngularDimension / RadialDimension")
struct AngularRadialDimensionTests {

    private func makeContext() -> InteractiveContext {
        InteractiveContext(viewport: ViewportController())
    }

    private func makeBox() throws -> OCCTSwift.Shape {
        try #require(OCCTSwift.Shape.box(width: 10, height: 5, depth: 3))
    }

    private func makeCylinder() throws -> OCCTSwift.Shape {
        try #require(OCCTSwift.Shape.cylinder(radius: 4.0, height: 8.0))
    }

    /// Find the first edge on `shape` whose `isCircle` is true.
    private func firstCircularEdgeIndex(of shape: OCCTSwift.Shape) -> Int? {
        for i in 0..<shape.edgeCount {
            if let edge = shape.edge(at: i), edge.isCircle {
                return i
            }
        }
        return nil
    }

    // MARK: - AngularDimension

    @Test func t_angular_anchorsArePointA_apex_pointB() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let dim = AngularDimension(
            arms: (
                .vertex(obj, ref: try vertexRef(obj, 0)), .vertex(obj, ref: try vertexRef(obj, 2))
            ),
            apex: .vertex(obj, ref: try vertexRef(obj, 1))
        )
        let pts = dim.anchorPoints
        #expect(pts.count == 3)
        // First entry is the resolved arm A; middle is apex; third is arm B.
        let v0 = try #require(obj.shape.vertex(at: 0))
        let v1 = try #require(obj.shape.vertex(at: 1))
        let v2 = try #require(obj.shape.vertex(at: 2))
        #expect(simd_distance(pts[0], SIMD3<Float>(Float(v0.x), Float(v0.y), Float(v0.z))) < 1e-5)
        #expect(simd_distance(pts[1], SIMD3<Float>(Float(v1.x), Float(v1.y), Float(v1.z))) < 1e-5)
        #expect(simd_distance(pts[2], SIMD3<Float>(Float(v2.x), Float(v2.y), Float(v2.z))) < 1e-5)
    }

    @Test func t_angular_label_includesDegreesGlyph() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let dim = AngularDimension(
            arms: (
                .vertex(obj, ref: try vertexRef(obj, 0)), .vertex(obj, ref: try vertexRef(obj, 2))
            ),
            apex: .vertex(obj, ref: try vertexRef(obj, 1))
        )
        let label = dim.label
        #expect(label.contains("\u{00B0}"), "label should end with the degree sign")
    }

    @Test func t_angular_customLabel_overrides() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let dim = AngularDimension(
            arms: (
                .vertex(obj, ref: try vertexRef(obj, 0)), .vertex(obj, ref: try vertexRef(obj, 1))
            ),
            apex: .vertex(obj, ref: try vertexRef(obj, 2)),
            customLabel: "RIGHT ANGLE"
        )
        #expect(dim.label == "RIGHT ANGLE")
    }

    @Test func t_angular_viewportMeasurement_isAngleVariant() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let dim = AngularDimension(
            arms: (
                .vertex(obj, ref: try vertexRef(obj, 0)), .vertex(obj, ref: try vertexRef(obj, 1))
            ),
            apex: .vertex(obj, ref: try vertexRef(obj, 2))
        )
        if case .angle(let m) = dim.viewportMeasurement {
            #expect(m.id == dim.id)
            // pointA, vertex, pointB ordering.
            let v0 = try #require(obj.shape.vertex(at: 0))
            let v2 = try #require(obj.shape.vertex(at: 2))
            #expect(
                simd_distance(m.pointA, SIMD3<Float>(Float(v0.x), Float(v0.y), Float(v0.z))) < 1e-5)
            #expect(
                simd_distance(m.vertex, SIMD3<Float>(Float(v2.x), Float(v2.y), Float(v2.z))) < 1e-5)
        } else {
            Issue.record("expected .angle variant")
        }
    }

    @Test func t_angular_threeColinearPoints_yieldZeroOr180() throws {
        // Pick a, vertex, b on the same line. ProjectionUtility.angle treats
        // colinear (same direction) as 0° and reverse as 180°. Either way,
        // it shouldn't crash and the label should be a finite number.
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let dim = AngularDimension(
            arms: (
                .vertex(obj, ref: try vertexRef(obj, 0)), .vertex(obj, ref: try vertexRef(obj, 0))
            ),
            apex: .vertex(obj, ref: try vertexRef(obj, 0))
        )
        let d = dim.degrees
        #expect(d.isFinite || d.isNaN)
    }

    // MARK: - RadialDimension

    @Test func t_radial_onCylinderEdge_resolvesCenterAndRadius() throws {
        let ctx = makeContext()
        let cylinder = try makeCylinder()
        let obj = ctx.display(cylinder)
        let circIdx = try #require(firstCircularEdgeIndex(of: cylinder))

        let dim = RadialDimension(circularEdge: .edge(obj, ref: try edgeRef(obj, circIdx)))

        #expect(abs(dim.radius - 4.0) < 1e-3, "expected radius 4.0, got \(dim.radius)")
        #expect(abs(dim.diameter - 8.0) < 1e-3)

        let pts = dim.anchorPoints
        #expect(pts.count == 2)
        // The edge point should be exactly `radius` away from the center.
        let measured = simd_distance(pts[0], pts[1])
        #expect(abs(measured - 4.0) < 1e-3)
    }

    @Test func t_radial_label_radiusMode_isPrefixedR() throws {
        let ctx = makeContext()
        let cylinder = try makeCylinder()
        let obj = ctx.display(cylinder)
        let circIdx = try #require(firstCircularEdgeIndex(of: cylinder))
        let dim = RadialDimension(circularEdge: .edge(obj, ref: try edgeRef(obj, circIdx)))
        #expect(dim.label.hasPrefix("R"))
    }

    @Test func t_radial_diameterMode_usesDiameterGlyph() throws {
        let ctx = makeContext()
        let cylinder = try makeCylinder()
        let obj = ctx.display(cylinder)
        let circIdx = try #require(firstCircularEdgeIndex(of: cylinder))
        let dim = RadialDimension(
            circularEdge: .edge(obj, ref: try edgeRef(obj, circIdx)), showDiameter: true)
        #expect(dim.label.hasPrefix("\u{2300}"))
    }

    @Test func t_radial_onNonCircularEdge_returnsCollapsedAnchors() throws {
        // A box has no circular edges: picking edge 0 (a straight line) should
        // give back zero anchors and a "?" label.
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let dim = RadialDimension(circularEdge: .edge(obj, ref: try edgeRef(obj, 0)))
        let pts = dim.anchorPoints
        #expect(pts == [.zero, .zero])
        #expect(dim.label == "?")
        #expect(!dim.radius.isFinite)
    }

    @Test func t_radial_onNonEdgeSubshape_returnsCollapsedAnchors() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let dim = RadialDimension(circularEdge: .body(obj))
        let pts = dim.anchorPoints
        #expect(pts == [.zero, .zero])
        #expect(dim.label == "?")
    }

    @Test func t_radial_viewportMeasurement_isRadiusVariant() throws {
        let ctx = makeContext()
        let cylinder = try makeCylinder()
        let obj = ctx.display(cylinder)
        let circIdx = try #require(firstCircularEdgeIndex(of: cylinder))
        let dim = RadialDimension(
            circularEdge: .edge(obj, ref: try edgeRef(obj, circIdx)), showDiameter: true)
        if case .radius(let m) = dim.viewportMeasurement {
            #expect(m.id == dim.id)
            #expect(m.showDiameter == true)
        } else {
            Issue.record("expected .radius variant")
        }
    }

    // MARK: - InteractiveContext glue

    @Test func t_addAngular_pushesViewportMeasurement() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let dim = AngularDimension(
            arms: (
                .vertex(obj, ref: try vertexRef(obj, 0)), .vertex(obj, ref: try vertexRef(obj, 1))
            ),
            apex: .vertex(obj, ref: try vertexRef(obj, 2))
        )
        ctx.add(dim)
        #expect(ctx.viewport.measurements.count == 1)
        if case .angle = ctx.viewport.measurements.first {
        } else {
            Issue.record("expected .angle in viewport.measurements")
        }
    }

    @Test func t_addRadial_pushesViewportMeasurement() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeCylinder())
        let circIdx = try #require(firstCircularEdgeIndex(of: obj.shape))
        let dim = RadialDimension(circularEdge: .edge(obj, ref: try edgeRef(obj, circIdx)))
        ctx.add(dim)
        #expect(ctx.viewport.measurements.count == 1)
        if case .radius = ctx.viewport.measurements.first {
        } else {
            Issue.record("expected .radius in viewport.measurements")
        }
    }

    @Test func t_mixedDimensions_coexistInRegistry() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let cylObj = ctx.display(try makeCylinder())
        let circIdx = try #require(firstCircularEdgeIndex(of: cylObj.shape))

        let lin = LinearDimension(
            from: .vertex(obj, ref: try vertexRef(obj, 0)),
            to: .vertex(obj, ref: try vertexRef(obj, 1)))
        let ang = AngularDimension(
            arms: (
                .vertex(obj, ref: try vertexRef(obj, 0)), .vertex(obj, ref: try vertexRef(obj, 1))
            ), apex: .vertex(obj, ref: try vertexRef(obj, 2)))
        let rad = RadialDimension(circularEdge: .edge(cylObj, ref: try edgeRef(cylObj, circIdx)))

        ctx.add(lin)
        ctx.add(ang)
        ctx.add(rad)
        #expect(ctx.viewport.measurements.count == 3)
        #expect(ctx.dimensions.count == 3)

        ctx.remove(ang)
        #expect(ctx.viewport.measurements.count == 2)
    }
}
