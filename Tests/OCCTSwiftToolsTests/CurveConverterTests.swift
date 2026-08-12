import OCCTSwift
import OCCTSwiftViewport
import Testing
import simd

@testable import OCCTSwiftTools

@Suite("CurveConverter")
struct CurveConverterTests {

    @Test func t_curve2DProjectsToYZeroPlane() {
        guard let circle = Curve2D.circle(center: SIMD2<Double>(0, 0), radius: 5) else {
            Issue.record("Curve2D.circle returned nil")
            return
        }
        let body = CurveConverter.curve2DToBody(
            circle, id: "c2d", color: SIMD4<Float>(1, 0, 0, 1)
        )
        #expect(body.id == "c2d")
        #expect(body.vertexData.isEmpty, "edge-only body has no triangulated vertex data")
        #expect(body.indices.isEmpty)
        #expect(body.edges.count == 1, "single polyline for the circle")
        let polyline = body.edges[0]
        #expect(polyline.count >= 4, "drawAdaptive should sample the circle")
        // Y must be exactly 0: the converter projects 2D curves onto the XZ ground plane.
        for p in polyline {
            #expect(p.y == 0)
        }
    }

    @Test func t_curve3DPreservesAllAxes() {
        guard
            let segment = Curve3D.segment(
                from: SIMD3<Double>(0, 0, 0),
                to: SIMD3<Double>(1, 2, 3)
            )
        else {
            Issue.record("Curve3D.segment returned nil")
            return
        }
        let body = CurveConverter.curve3DToBody(
            segment, id: "c3d", color: SIMD4<Float>(0, 1, 0, 1)
        )
        #expect(body.edges.count == 1)
        let polyline = body.edges[0]
        #expect(polyline.count >= 2)
        // Endpoints should match the segment exactly.
        let start = polyline.first!
        let end = polyline.last!
        #expect(start.x == 0 && start.y == 0 && start.z == 0)
        #expect(abs(end.x - 1) < 1e-5 && abs(end.y - 2) < 1e-5 && abs(end.z - 3) < 1e-5)
    }
}
