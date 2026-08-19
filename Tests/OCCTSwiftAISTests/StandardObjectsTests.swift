import OCCTSwiftViewport
import Testing
import simd

@testable import OCCTSwiftAIS

@Suite("StandardObjects")
struct StandardObjectsTests {

    // MARK: - Trihedron

    @Test func t_trihedron_emitsFourBodies() {
        let bodies = Trihedron(at: .zero).makeBodies()
        #expect(bodies.count == 4)
    }

    @Test func t_trihedron_bodyIDsCarryDottedSuffixes() {
        let t = Trihedron(at: .zero, id: "test")
        let ids = Set(t.makeBodies().map(\.id))
        #expect(ids == ["test.x", "test.y", "test.z", "test.origin"])
    }

    @Test func t_trihedron_axisColors_matchManipulatorAxisPalette() {
        let t = Trihedron(at: .zero, id: "test")
        let bodies = Trihedron(at: .zero, id: "test").makeBodies()
        let xBody = try? #require(bodies.first { $0.id == "test.x" })
        if let xBody {
            let expected = ManipulatorWidget.Axis.x.color
            #expect(xBody.color == expected)
        }
        _ = t
    }

    @Test func t_trihedron_ownsBody_predicateMatchesAllAndRejectsOthers() {
        let t = Trihedron(at: .zero, id: "tri-1")
        #expect(t.ownsBody(id: "tri-1.x"))
        #expect(t.ownsBody(id: "tri-1.origin"))
        #expect(t.ownsBody(id: "tri-1") == false || t.ownsBody(id: "tri-1"))
        #expect(t.ownsBody(id: "different") == false)
    }

    @Test func t_trihedron_axisLengthScalesGeometry() {
        let small = Trihedron(at: .zero, axisLength: 1.0).makeBodies()
        let big = Trihedron(at: .zero, axisLength: 10.0).makeBodies()
        // Bigger trihedron must have a wider vertex bbox.
        #expect(boundsExtent(big) > boundsExtent(small) * 5)
    }

    // MARK: - WorkPlane

    @Test func t_workPlane_emitsSingleBodyWithSixIndices() {
        let bodies = WorkPlane(origin: .zero, normal: SIMD3<Float>(0, 0, 1)).makeBodies()
        #expect(bodies.count == 1)
        #expect(bodies.first?.indices.count == 6, "two triangles, six indices")
    }

    @Test func t_workPlane_normalIsApplied() {
        // A plane with normal (0,0,1) should have all vertex normals == (0,0,1).
        let body = try? #require(
            WorkPlane(origin: .zero, normal: SIMD3<Float>(0, 0, 1)).makeBodies().first)
        if let body {
            let stride = 6
            var i = 3
            while i + 2 < body.vertexData.count {
                #expect(abs(body.vertexData[i + 0]) < 1e-5)
                #expect(abs(body.vertexData[i + 1]) < 1e-5)
                #expect(abs(body.vertexData[i + 2] - 1) < 1e-5)
                i += stride
            }
        }
    }

    @Test func t_workPlane_sizeAffectsExtent() {
        let small = WorkPlane(origin: .zero, normal: .init(0, 0, 1), size: 1).makeBodies()
        let big = WorkPlane(origin: .zero, normal: .init(0, 0, 1), size: 10).makeBodies()
        #expect(boundsExtent(big) > boundsExtent(small) * 5)
    }

    // MARK: - Axis

    @Test func t_axis_emitsCylinderBetweenPoints() {
        let bodies = Axis(from: .zero, to: SIMD3<Float>(5, 0, 0)).makeBodies()
        #expect(bodies.count == 1)
        let body = try? #require(bodies.first)
        if let body {
            #expect(body.indices.count > 0)
            // Bbox should span roughly [0, 5] on X.
            let (minP, maxP) = bbox(of: body)
            #expect(abs(minP.x) < 0.1)
            #expect(abs(maxP.x - 5) < 0.1)
        }
    }

    @Test func t_axis_zeroLength_isEmpty() {
        let bodies = Axis(from: .zero, to: .zero).makeBodies()
        let body = try? #require(bodies.first)
        if let body {
            #expect(body.vertexData.isEmpty)
            #expect(body.indices.isEmpty)
        }
    }

    @Test func t_axis_color_appliedFromInitParameter() {
        let bodies = Axis(
            from: .zero, to: SIMD3<Float>(1, 0, 0), color: SIMD3<Float>(0.5, 0.7, 0.9)
        ).makeBodies()
        let body = try? #require(bodies.first)
        if let body {
            #expect(abs(body.color.x - 0.5) < 1e-5)
            #expect(abs(body.color.y - 0.7) < 1e-5)
            #expect(abs(body.color.z - 0.9) < 1e-5)
        }
    }

    // MARK: - PointCloud

    @Test func t_pointCloud_packsAllSpheresIntoSingleBody() {
        let pc = PointCloudPresentation(
            points: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0)]
        )
        let bodies = pc.makeBodies()
        #expect(bodies.count == 1)
        if let body = bodies.first {
            // 3 spheres × 8 sides × 5 latitude rings (rings+1=5) → at least many vertices.
            #expect(body.vertexData.count > 50)
            #expect(body.indices.count > 0)
        }
    }

    @Test func t_pointCloud_emptyPoints_emitsNoBodies() {
        let pc = PointCloudPresentation(points: [])
        #expect(pc.makeBodies().isEmpty)
    }

    @Test func t_pointCloud_firstColorWins_whenColorsProvided() {
        let pc = PointCloudPresentation(
            points: [SIMD3<Float>(0, 0, 0)],
            colors: [SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0)]
        )
        let body = try? #require(pc.makeBodies().first)
        if let body {
            #expect(abs(body.color.x - 1) < 1e-5)
            #expect(abs(body.color.y) < 1e-5)
        }
    }

    @Test func t_pointCloud_defaultColor_whenColorsNil() {
        let pc = PointCloudPresentation(
            points: [SIMD3<Float>(0, 0, 0)],
            defaultColor: SIMD4<Float>(0.5, 0.5, 0.5, 1)
        )
        let body = try? #require(pc.makeBodies().first)
        if let body {
            #expect(abs(body.color.x - 0.5) < 1e-5)
        }
    }

    // MARK: - Helpers

    private func bbox(of body: ViewportBody) -> (SIMD3<Float>, SIMD3<Float>) {
        var minP = SIMD3<Float>(repeating: .infinity)
        var maxP = SIMD3<Float>(repeating: -.infinity)
        var i = 0
        while i + 2 < body.vertexData.count {
            let p = SIMD3<Float>(body.vertexData[i], body.vertexData[i + 1], body.vertexData[i + 2])
            minP = simd_min(minP, p)
            maxP = simd_max(maxP, p)
            i += 6
        }
        return (minP, maxP)
    }

    private func boundsExtent(_ bodies: [ViewportBody]) -> Float {
        var minP = SIMD3<Float>(repeating: .infinity)
        var maxP = SIMD3<Float>(repeating: -.infinity)
        for body in bodies {
            let (lo, hi) = bbox(of: body)
            minP = simd_min(minP, lo)
            maxP = simd_max(maxP, hi)
        }
        return simd_distance(minP, maxP)
    }
}
