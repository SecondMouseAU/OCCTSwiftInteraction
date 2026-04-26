import Testing
import simd
@testable import OCCTSwiftCADKit

@Suite("Smoke")
struct SmokeTests {
    @Test("PickedFaceInfo round-trips through equality")
    func pickedFaceInfoEquality() {
        let bounds = FaceBounds(minX: 0, maxX: 10, minY: 0, maxY: 5)
        let info = PickedFaceInfo(
            faceIndex: 3,
            bodyID: "model",
            isHorizontal: true,
            isVertical: false,
            bounds: bounds,
            zLevel: 12.5,
            area: 50,
            description: "Horizontal face at Z=12.5, 10.0x5.0mm"
        )
        #expect(info == info)
        #expect(bounds.width == 10)
        #expect(bounds.height == 5)
    }

    @Test("CADViewportError messages format correctly")
    func errorMessages() {
        #expect(CADViewportError.unsupportedFormat("xyz").errorDescription == "Unsupported file format: .xyz")
        #expect(CADViewportError.emptyFile.errorDescription == "File contains no geometry")
        #expect(CADViewportError.loadFailed("bad").errorDescription == "Load failed: bad")
    }

    @Test("CADViewportService.ShapeBounds reports size correctly")
    func shapeBoundsSize() {
        let b = CADViewportService.ShapeBounds(
            minX: -1, minY: -2, minZ: -3,
            maxX: 4, maxY: 5, maxZ: 6
        )
        #expect(b.sizeX == 5)
        #expect(b.sizeY == 7)
        #expect(b.sizeZ == 9)
    }
}
