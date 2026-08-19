import OCCTSwiftViewport
import SwiftUI
import simd

/// SwiftUI integration for `ManipulatorWidget`.
///
/// `attachManipulator(_:)` wraps a viewport view (e.g. `MetalViewportView`) with
/// a `.highPriorityGesture(DragGesture)` that hit-tests the widget on touch-down,
/// then either drives the widget's drag (`beginDrag` / `updateDrag` / `endDrag`)
/// or forwards the gesture to the viewport's camera (`handleOrbit` / `endOrbit`)
/// when the user dragged outside any handle.
///
/// The widget must already be `install(in:)`-ed in an `InteractiveContext`;
/// the modifier reads `widget.context` to find the viewport.
extension View {
    public func attachManipulator(_ widget: ManipulatorWidget) -> some View {
        modifier(ManipulatorGestureModifier(widget: widget))
    }
}

/// State and decision logic for the manipulator gesture, factored out so it
/// can be unit-tested independently of SwiftUI's gesture machinery.
@MainActor
final class ManipulatorGestureCoordinator {

    enum Mode: Equatable {
        case idle
        case widget(ManipulatorWidget.Axis)
        case camera
    }

    let widget: ManipulatorWidget
    private(set) var mode: Mode = .idle
    private var lastTranslation: CGSize = .zero

    init(widget: ManipulatorWidget) {
        self.widget = widget
    }

    /// Called once per gesture update. `viewSize` is the gesture-receiving
    /// view's size (used to convert point-space `location` to NDC).
    func onChanged(
        location: CGPoint,
        translation: CGSize,
        in viewSize: CGSize
    ) {
        guard let context = widget.context else { return }
        let camera = context.viewport.cameraState
        let aspect = context.viewport.lastAspectRatio
        let ndc = ndcFromPoint(location, in: viewSize)

        switch mode {
        case .idle:
            if let axis = widget.hitTest(ndc: ndc, camera: camera, aspect: aspect) {
                widget.beginDrag(axis: axis, ndc: ndc, camera: camera, aspect: aspect)
                mode = .widget(axis)
            } else {
                mode = .camera
                lastTranslation = translation
            }

        case .widget:
            widget.updateDrag(ndc: ndc, camera: camera, aspect: aspect)

        case .camera:
            let delta = CGSize(
                width: translation.width - lastTranslation.width,
                height: translation.height - lastTranslation.height
            )
            context.viewport.handleOrbit(translation: delta)
            lastTranslation = translation
        }
    }

    func onEnded() {
        guard let context = widget.context else {
            mode = .idle
            return
        }
        switch mode {
        case .widget:
            widget.endDrag(commit: true)
        case .camera:
            context.viewport.endOrbit(velocity: .zero)
        case .idle:
            break
        }
        mode = .idle
        lastTranslation = .zero
    }
}

/// Map a SwiftUI gesture point (origin top-left, Y-down) to NDC ([-1, 1] with
/// Y-up).
///
/// Returns `.zero` for a degenerate `viewSize`.
func ndcFromPoint(_ p: CGPoint, in viewSize: CGSize) -> SIMD2<Float> {
    guard viewSize.width > 0, viewSize.height > 0 else { return .zero }
    let nx = Float((p.x / viewSize.width) * 2.0 - 1.0)
    let ny = Float(1.0 - (p.y / viewSize.height) * 2.0)
    return SIMD2<Float>(nx, ny)
}

struct ManipulatorGestureModifier: ViewModifier {
    @ObservedObject var widget: ManipulatorWidget
    @State private var coordinator: ManipulatorGestureCoordinator?
    @State private var viewSize: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { viewSize = geo.size }
                        .onChange(of: geo.size) { _, new in viewSize = new }
                }
            )
            .highPriorityGesture(dragGesture)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let coord = coordinator(for: widget)
                coord.onChanged(
                    location: value.location,
                    translation: value.translation,
                    in: viewSize
                )
            }
            .onEnded { _ in
                coordinator?.onEnded()
            }
    }

    private func coordinator(for widget: ManipulatorWidget) -> ManipulatorGestureCoordinator {
        if let existing = coordinator, existing.widget === widget { return existing }
        let new = ManipulatorGestureCoordinator(widget: widget)
        coordinator = new
        return new
    }
}
