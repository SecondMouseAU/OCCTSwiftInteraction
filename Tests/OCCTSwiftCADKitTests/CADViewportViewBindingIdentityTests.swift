import OCCTSwiftViewport
import Testing
import simd

@testable import OCCTSwiftCADKit

/// Regression coverage for the `.constant(bodies)` binding bug: the renderer captures its
/// binding once, so the binding must keep reading the current bodies after later updates.
@Suite("CADViewportView live bodies")
struct CADViewportViewBindingIdentityTests {
    private func makeBody(id: String) -> _ViewportBody {
        _ViewportBody(
            id: id,
            vertexData: [0, 0, 0, 0, 1, 0],
            indices: [0],
            edges: [],
            color: SIMD4<Float>(1, 1, 1, 1)
        )
    }

    @Test("a binding captured early reads bodies added later")
    func capturedBindingSeesAddedBody() {
        let box = CADViewportView.LiveBodies([makeBody(id: "model")])
        let captured = box.binding

        box.bodies = [makeBody(id: "model"), makeBody(id: "selection_highlight_face")]

        #expect(captured.wrappedValue.map(\.id) == ["model", "selection_highlight_face"])
    }

    @Test("a binding captured early reads an in-place isVisible edit")
    func capturedBindingSeesVisibilityEdit() {
        let box = CADViewportView.LiveBodies([makeBody(id: "model")])
        let captured = box.binding
        #expect(captured.wrappedValue.first?.isVisible == true)

        var edited = box.bodies
        edited[0].isVisible = false
        box.bodies = edited

        #expect(captured.wrappedValue.first?.isVisible == false)
    }

    @Test("a binding captured early reads an in-place transform edit")
    func capturedBindingSeesTransformEdit() {
        let box = CADViewportView.LiveBodies([makeBody(id: "model")])
        let captured = box.binding

        var edited = box.bodies
        var moved = matrix_identity_float4x4
        moved.columns.3.x = 5
        edited[0].transform = moved
        box.bodies = edited

        #expect(captured.wrappedValue.first?.transform.columns.3.x == 5)
    }

    @Test("a binding captured early reads a removal")
    func capturedBindingSeesRemoval() {
        let box = CADViewportView.LiveBodies([makeBody(id: "a"), makeBody(id: "b")])
        let captured = box.binding

        box.bodies = [makeBody(id: "a")]

        #expect(captured.wrappedValue.map(\.id) == ["a"])
    }
}
