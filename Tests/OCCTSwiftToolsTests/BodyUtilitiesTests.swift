import OCCTSwiftViewport
import Testing
import simd

@testable import OCCTSwiftTools

@Suite("BodyUtilities")
struct BodyUtilitiesTests {

    @Test func t_makeMarkerSphereProducesGeometry() {
        let body = BodyUtilities.makeMarkerSphere(
            at: SIMD3<Float>(1, 2, 3),
            radius: 0.5, id: "marker",
            color: SIMD4<Float>(1, 0, 0, 1)
        )
        #expect(body.id == "marker")
        #expect(body.vertexData.count > 0)
        #expect(body.vertexData.count % 6 == 0)
        // First vertex should be offset by the requested position.
        // (Exact equality depends on sphere() construction order; just sanity-check it's near (1,2,3) ± radius.)
        let firstX = body.vertexData[0]
        let firstY = body.vertexData[1]
        let firstZ = body.vertexData[2]
        #expect(abs(firstX - 1) <= 0.5 + 1e-4)
        #expect(abs(firstY - 2) <= 0.5 + 1e-4)
        #expect(abs(firstZ - 3) <= 0.5 + 1e-4)
    }

    @Test func t_offsetBodyValueShiftsAllVerticesAndEdges() {
        let original = BodyUtilities.makeMarkerSphere(
            at: .zero, radius: 1, id: "src", color: SIMD4<Float>(1, 1, 1, 1)
        )
        let dx: Float = 10
        let dy: Float = -5
        let dz: Float = 2.5
        let shifted = BodyUtilities.offsetBody(original, dx: dx, dy: dy, dz: dz)

        #expect(shifted.vertexData.count == original.vertexData.count)
        // Verify position triplets shifted exactly; normals (channels 3..5) preserved.
        for i in stride(from: 0, to: original.vertexData.count, by: 6) {
            #expect(shifted.vertexData[i] == original.vertexData[i] + dx)
            #expect(shifted.vertexData[i + 1] == original.vertexData[i + 1] + dy)
            #expect(shifted.vertexData[i + 2] == original.vertexData[i + 2] + dz)
            #expect(shifted.vertexData[i + 3] == original.vertexData[i + 3])
            #expect(shifted.vertexData[i + 4] == original.vertexData[i + 4])
            #expect(shifted.vertexData[i + 5] == original.vertexData[i + 5])
        }
    }

    @Test func t_offsetBodyInoutMatchesValueOverload() {
        var inoutCopy = BodyUtilities.makeMarkerSphere(
            at: .zero, radius: 1, id: "inout", color: SIMD4<Float>(1, 1, 1, 1)
        )
        let valueShifted = BodyUtilities.offsetBody(inoutCopy, dx: 3, dy: 4, dz: 5)
        BodyUtilities.offsetBody(&inoutCopy, dx: 3, dy: 4, dz: 5)
        #expect(inoutCopy.vertexData == valueShifted.vertexData)
    }
}
