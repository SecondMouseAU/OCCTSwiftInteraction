import OCCTSwiftAIS
import OCCTSwiftCADKit
import Testing

/// A file importing both modules can write a bare `Axis` (#60).
///
/// The guard is this file compiling at all: while CADKit also declared a top-level `Axis`, every
/// bare `Axis` below was "ambiguous for type lookup". Keep both imports plain, as a consumer has
/// them, and keep `Axis` unqualified.
@Suite("Axis name collision")
struct AxisNameCollisionTests {
    @Test("With AIS and CADKit both imported, a bare Axis is AIS's scene object")
    func bareAxisResolvesToTheAISSceneObject() {
        let axis: Axis = Axis(from: .zero, to: SIMD3<Float>(1, 0, 0))
        #expect(axis.makeBodies().count == 1)
    }
}
