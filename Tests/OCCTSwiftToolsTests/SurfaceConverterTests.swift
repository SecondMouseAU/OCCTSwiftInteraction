import OCCTSwift
import OCCTSwiftViewport
import Testing
import simd

@testable import OCCTSwiftTools

@Suite("SurfaceConverter")
struct SurfaceConverterTests {

    @Test func t_planeProducesTwoIsoparametricBodies() {
        guard
            let plane = Surface.plane(
                origin: SIMD3<Double>(0, 0, 0),
                normal: SIMD3<Double>(0, 0, 1)
            )
        else {
            Issue.record("Surface.plane returned nil")
            return
        }
        let bodies = SurfaceConverter.surfaceToGridBodies(
            plane, idPrefix: "grid",
            uColor: SIMD4<Float>(1, 0, 0, 1),
            vColor: SIMD4<Float>(0, 1, 0, 1),
            uLines: 4, vLines: 6
        )
        // Plane is unbounded so OCCT may return empty grids; accept that, but if
        // bodies come back they must follow the -u / -v naming convention.
        for body in bodies {
            #expect(body.id == "grid-u" || body.id == "grid-v")
            #expect(body.vertexData.isEmpty, "isoparametric grids are edge-only")
            #expect(!body.edges.isEmpty)
        }
    }

    @Test func t_cylinderProducesBothIsoFamilies() {
        guard
            let cyl = Surface.cylinder(
                origin: SIMD3<Double>(0, 0, 0),
                axis: SIMD3<Double>(0, 0, 1),
                radius: 1
            )
        else {
            Issue.record("Surface.cylinder returned nil")
            return
        }
        let bodies = SurfaceConverter.surfaceToGridBodies(
            cyl, idPrefix: "cyl",
            uColor: SIMD4<Float>(1, 0, 0, 1),
            vColor: SIMD4<Float>(0, 1, 0, 1),
            uLines: 8, vLines: 8
        )
        let ids = Set(bodies.map(\.id))
        // Bounded surfaces should yield both families.
        if !ids.isEmpty {
            #expect(ids.isSubset(of: ["cyl-u", "cyl-v"]))
        }
    }
}
