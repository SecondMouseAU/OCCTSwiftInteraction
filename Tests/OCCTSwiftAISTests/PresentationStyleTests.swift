import Testing

@testable import OCCTSwiftAIS

/// Regression for OCCTSwiftInteraction#16: the agent-viewport selection bridge needs a
/// `PresentationStyle` for a highlight request that a viewer can tell apart from an ordinary
/// selection at a glance.
@Suite("PresentationStyle")
struct PresentationStyleTests {

    @Test("agentHighlight's color differs from HighlightStyle.default's selection color")
    func agentHighlightColorDiffersFromDefaultSelectionColor() {
        #expect(PresentationStyle.agentHighlight.color != HighlightStyle.default.selectionColor)
    }

    @Test("agentHighlight also differs from the ordinary .highlighted/.hovered presets")
    func agentHighlightDiffersFromOtherPresets() {
        #expect(PresentationStyle.agentHighlight != PresentationStyle.highlighted)
        #expect(PresentationStyle.agentHighlight != PresentationStyle.hovered)
        #expect(PresentationStyle.agentHighlight.color != PresentationStyle.highlighted.color)
    }

    @Test("agentHighlight reads hollow (.wireframe), not filled like .highlighted")
    func agentHighlightIsWireframe() {
        #expect(PresentationStyle.agentHighlight.displayMode == .wireframe)
        #expect(PresentationStyle.highlighted.displayMode != .wireframe)
    }
}
