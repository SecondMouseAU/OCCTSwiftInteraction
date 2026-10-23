import OCCTSwift
import Testing

@testable import OCCTSwiftCADKit

@Suite("Mesh deflection")
struct MeshDeflectionTests {
    @MainActor
    private func triangleCount(deflection: Double?) -> Int {
        let service = CADViewportService()
        service.meshDeflection = deflection
        guard let sphere = Shape.sphere(radius: 10) else { return 0 }
        service.load(sphere, id: "s")
        return service.modelBodies.first { $0.id == "s" }.map { $0.indices.count / 3 } ?? 0
    }

    @MainActor
    @Test("a coarser meshDeflection yields fewer triangles than the default")
    func coarserDeflectionMeshesCoarser() {
        let fine = triangleCount(deflection: nil)
        let coarse = triangleCount(deflection: 2.0)
        #expect(fine > 0)
        #expect(coarse > 0)
        #expect(coarse < fine)
    }
}
