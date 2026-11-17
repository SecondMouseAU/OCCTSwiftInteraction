import OCCTSwiftViewport
import SwiftUI

/// Where `CADViewportView` puts its display-mode controls relative to the viewport's view cube.
///
/// Rationale: [docs/module-notes/OCCTSwiftCADKit.md](../../docs/module-notes/OCCTSwiftCADKit.md).
enum ViewportControlsLayout {
    /// Gap between the controls and the viewport's edges, and between the controls and the cube.
    static let margin: CGFloat = 8

    /// The view cube's side as `MetalViewportView.viewCubeOverlay` frames it, mirrored from
    /// OCCTSwiftViewport, which does not expose it.
    static let viewCubeSide: CGFloat = 96

    /// The gap between the view cube and the viewport's edges, mirrored the same way.
    static let viewCubeMargin: CGFloat = 12

    /// Extra space under the controls: the cube's footprint when it shares their corner, else zero.
    static func bottomClearance(
        viewCubeVisible: Bool, viewCubePosition: _ViewCubePosition
    ) -> CGFloat {
        guard viewCubeVisible, viewCubePosition == .bottomTrailing else { return 0 }
        return viewCubeMargin + viewCubeSide
    }
}
