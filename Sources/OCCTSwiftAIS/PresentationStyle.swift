import simd

public enum DisplayMode: Hashable, Sendable {
    case shaded
    case wireframe
    case shadedWithEdges
}

/// Visual treatment for a displayed `InteractiveObject`.
public struct PresentationStyle: Sendable, Equatable {
    public var color: SIMD3<Float>
    public var transparency: Float
    public var displayMode: DisplayMode
    public var visible: Bool

    public init(
        color: SIMD3<Float> = SIMD3<Float>(0.7, 0.7, 0.7),
        transparency: Float = 0,
        displayMode: DisplayMode = .shadedWithEdges,
        visible: Bool = true
    ) {
        self.color = color
        self.transparency = transparency
        self.displayMode = displayMode
        self.visible = visible
    }

    public static let `default` = PresentationStyle()

    public static let ghosted = PresentationStyle(
        color: SIMD3<Float>(0.6, 0.6, 0.6),
        transparency: 0.7,
        displayMode: .shaded
    )

    public static let highlighted = PresentationStyle(
        color: SIMD3<Float>(1.0, 0.65, 0.0),
        displayMode: .shadedWithEdges
    )

    public static let hovered = PresentationStyle(
        color: SIMD3<Float>(0.3, 0.8, 1.0),
        displayMode: .shadedWithEdges
    )

    /// An agent's highlight request, distinct from `.highlighted` (a human's ordinary
    /// selection) and `.hovered`, so a viewer can tell "the agent is pointing at this" from
    /// "I selected this" at a glance (OCCTSwiftInteraction#16, the agent-viewport selection
    /// bridge ADR at `okf/decisions/agent-viewport-selection-bridge.md` in
    /// `OCCTSwiftInteraction`).
    ///
    /// `.wireframe` reads as hollow, in contrast to `.highlighted`'s filled
    /// `.shadedWithEdges`. A dashed stroke and a diamond-shaped point handle, the fuller
    /// visual vocabulary the ADR's consumers describe, are `OCCTSwiftViewport` renderer
    /// capabilities (line style, point-sprite shape) that do not exist yet; this color plus
    /// `.wireframe` is the identity signal available today, and the one
    /// `CADViewportService.startSelectionSidecar(directory:)` applies to a highlight request
    /// resolved with no `question` (`CADViewportService+AgentBridge.swift`).
    public static let agentHighlight = PresentationStyle(
        color: SIMD3<Float>(0.85, 0.2, 0.95),
        displayMode: .wireframe
    )
}

/// Colors used by the highlight overlay for selected and hovered sub-shapes.
public struct HighlightStyle: Sendable, Equatable {
    public var selectionColor: SIMD3<Float>
    public var hoverColor: SIMD3<Float>
    public var outlineWidth: Float

    public init(
        selectionColor: SIMD3<Float> = SIMD3<Float>(1.0, 0.65, 0.0),
        hoverColor: SIMD3<Float> = SIMD3<Float>(0.3, 0.8, 1.0),
        outlineWidth: Float = 2.0
    ) {
        self.selectionColor = selectionColor
        self.hoverColor = hoverColor
        self.outlineWidth = outlineWidth
    }

    public static let `default` = HighlightStyle()
}
