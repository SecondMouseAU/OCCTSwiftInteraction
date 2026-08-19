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
