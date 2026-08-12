import OCCTSwiftViewport
import Testing
import simd

@testable import OCCTSwiftTools

@Suite("PointConverter")
struct PointConverterTests {

    @Test func t_emptyInputProducesEmptyBody() {
        let body = PointConverter.pointsToBody([], id: "empty")
        #expect(body != nil, "empty input is valid (useful for clearing a body)")
        if let body {
            #expect(body.id == "empty")
            #expect(body.vertices.isEmpty)
            #expect(body.vertexData.isEmpty, "no triangulated mesh")
            #expect(body.indices.isEmpty)
            #expect(body.edges.isEmpty, "no wireframe")
        }
    }

    @Test func t_tenThousandPointCloud() {
        // Stress-size: the existing pre-PointConverter workaround capped at
        // ~256 because compounding spheres blew up vertex counts; this shape
        // has to handle 10k cleanly.
        var pts: [SIMD3<Float>] = []
        pts.reserveCapacity(10_000)
        for i in 0..<10_000 {
            let f = Float(i) * 0.001
            pts.append(SIMD3<Float>(f, f * 0.5, f * 0.25))
        }
        let body = PointConverter.pointsToBody(pts, id: "cloud-10k")
        #expect(body != nil)
        if let body {
            #expect(body.vertices.count == 10_000)
            #expect(body.vertexData.isEmpty)
            #expect(body.indices.isEmpty)
            #expect(body.edges.isEmpty)
            // First point round-trips exactly; last point round-trips within
            // single-precision tolerance (Float multiplications accumulate).
            #expect(body.vertices.first == SIMD3<Float>(0, 0, 0))
            if let last = body.vertices.last {
                let expected = SIMD3<Float>(9.999, 9.999 * 0.5, 9.999 * 0.25)
                let diff = simd_length(last - expected)
                #expect(diff < 1e-3)
            }
        }
    }

    @Test func t_perPointColorsLengthMustMatch() {
        let pts: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0),
        ]
        // Length mismatch → nil
        let mismatch = PointConverter.pointsToBody(
            pts, id: "bad",
            perPointColors: [SIMD4<Float>(1, 0, 0, 1), SIMD4<Float>(0, 1, 0, 1)]
        )
        #expect(mismatch == nil, "length mismatch must fail validation")

        // Length match → valid body
        let good = PointConverter.pointsToBody(
            pts, id: "ok",
            perPointColors: [
                SIMD4<Float>(1, 0, 0, 1),
                SIMD4<Float>(0, 1, 0, 1),
                SIMD4<Float>(0, 0, 1, 1),
            ]
        )
        #expect(good != nil, "matching lengths should produce a body")
    }

    @Test func t_defaultColorIsSoftAmber() {
        let body = PointConverter.pointsToBody([SIMD3(0, 0, 0)], id: "color")
        #expect(body != nil)
        if let body {
            // Default fallback color used when renderer doesn't sample per-point.
            #expect(body.color.x == 1.0)
            #expect(body.color.y == 0.85)
            #expect(body.color.z == 0.2)
            #expect(body.color.w == 1.0)
        }
    }

    @Test func t_customColorIsPreserved() {
        let body = PointConverter.pointsToBody(
            [SIMD3(0, 0, 0)],
            id: "custom",
            color: SIMD4<Float>(0.1, 0.2, 0.3, 0.5)
        )
        #expect(body?.color == SIMD4<Float>(0.1, 0.2, 0.3, 0.5))
    }

    // MARK: - Renderer-side fields wired through (Viewport #28 → Tools follow-up)

    @Test func t_primitiveKindIsPoint() {
        let body = PointConverter.pointsToBody([SIMD3(0, 0, 0)], id: "kind")
        #expect(
            body?.primitiveKind == .point,
            "PointConverter must mark the body so the renderer dispatches to the point pass")
    }

    @Test func t_pointRadiusRoundTrips() {
        let body = PointConverter.pointsToBody(
            [SIMD3(0, 0, 0)],
            id: "radius",
            pointRadius: 0.42
        )
        #expect(
            body?.pointRadius == 0.42, "explicit pointRadius must be carried through to the body")
    }

    @Test func t_defaultPointRadiusMatchesSignature() {
        let body = PointConverter.pointsToBody([SIMD3(0, 0, 0)], id: "default-radius")
        #expect(
            body?.pointRadius == 0.05,
            "default pointRadius must match the signature's documented default")
    }

    @Test func t_perPointColorsRoundTrip() {
        let pts: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)]
        let colors: [SIMD4<Float>] = [
            SIMD4(1, 0, 0, 1),
            SIMD4(0, 1, 0, 1),
            SIMD4(0, 0, 1, 1),
        ]
        let body = PointConverter.pointsToBody(pts, id: "rgb", perPointColors: colors)
        #expect(body?.vertexColors.count == 3, "perPointColors must populate vertexColors")
        #expect(body?.vertexColors == colors)
    }

    @Test func t_perPointColorsNilLeavesVertexColorsEmpty() {
        let body = PointConverter.pointsToBody(
            [SIMD3(0, 0, 0), SIMD3(1, 0, 0)],
            id: "no-colors"
        )
        #expect(
            body?.vertexColors.isEmpty == true,
            "nil perPointColors must leave vertexColors empty so the renderer falls back to body.color"
        )
    }
}
