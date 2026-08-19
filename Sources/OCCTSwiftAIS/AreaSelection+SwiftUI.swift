import OCCTSwiftViewport
import SwiftUI

/// Which interaction a drag gesture performs once `.attachAreaSelection(_:)`
/// is installed. `.navigate` (the default) passes the drag straight through
/// to camera orbit (exactly as if the modifier weren't attached at all),
/// since there's no hit-test to arbitrate on the way `ManipulatorWidget` does
/// for gizmo handles; switching to `.rectangle`/`.lasso` is an explicit,
/// app-driven choice (a "select tool" toggle), matching how most CAD apps
/// separate a navigate tool from a select tool.
public enum AreaSelectionTool: Sendable, Equatable {
    case navigate
    case rectangle
    case lasso
}

/// Drag-gesture state for rectangle/lasso area selection.
///
/// Bind one to a viewport view via `.attachAreaSelection(_:)`.
@MainActor
public final class AreaSelectionController: ObservableObject {
    public let context: InteractiveContext

    public var tool: AreaSelectionTool = .navigate
    public var mode: AreaSelectionMode = .enclosed
    public var scheme: SelectionScheme = .replace

    /// Current drag path, in the gesture-receiving view's local coordinates
    /// (top-left origin, Y-down, same as `DragGesture's` own locations).
    ///
    /// `[start, current]` while dragging a rectangle; the full point sequence
    /// while dragging a lasso. Read by the rubber-band/lasso overlay.
    @Published fileprivate(set) var dragPoints: [CGPoint] = []

    public init(context: InteractiveContext) {
        self.context = context
    }
}

extension View {
    /// Wrap a viewport view (e.g. `MetalViewportView`) with rectangle/lasso
    /// area-selection drag handling and a live rubber-band/lasso overlay.
    ///
    /// While `controller.tool == .navigate`, drags pass through to camera
    /// orbit unchanged.
    public func attachAreaSelection(_ controller: AreaSelectionController) -> some View {
        modifier(AreaSelectionGestureModifier(controller: controller))
    }
}

/// State and decision logic for the area-selection gesture, factored out so
/// it can be unit-tested independently of SwiftUI's gesture machinery,
/// mirroring `ManipulatorGestureCoordinator's` split for the same reason.
@MainActor
final class AreaSelectionGestureCoordinator {
    let controller: AreaSelectionController
    private var lastTranslation: CGSize = .zero
    private var viewportSize: CGSize = .zero

    init(controller: AreaSelectionController) {
        self.controller = controller
    }

    func onChanged(
        location: CGPoint, startLocation: CGPoint, translation: CGSize, in viewSize: CGSize
    ) {
        viewportSize = viewSize
        switch controller.tool {
        case .navigate:
            let delta = CGSize(
                width: translation.width - lastTranslation.width,
                height: translation.height - lastTranslation.height
            )
            controller.context.viewport.handleOrbit(translation: delta)
            lastTranslation = translation

        case .rectangle:
            controller.dragPoints = [startLocation, location]

        case .lasso:
            controller.dragPoints.append(location)
        }
    }

    func onEnded() {
        defer {
            controller.dragPoints = []
            lastTranslation = .zero
        }
        switch controller.tool {
        case .navigate:
            controller.context.viewport.endOrbit(velocity: .zero)

        case .rectangle:
            guard let start = controller.dragPoints.first, let end = controller.dragPoints.last
            else { return }
            controller.context.selectRectangle(
                from: start, to: end, mode: controller.mode, scheme: controller.scheme,
                viewportSize: viewportSize
            )

        case .lasso:
            controller.context.selectPolygon(
                controller.dragPoints, mode: controller.mode, scheme: controller.scheme,
                viewportSize: viewportSize
            )
        }
    }
}

struct AreaSelectionGestureModifier: ViewModifier {
    @ObservedObject var controller: AreaSelectionController
    @State private var coordinator: AreaSelectionGestureCoordinator?
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
            .overlay(rubberBandOverlay.allowsHitTesting(false))
            .highPriorityGesture(dragGesture)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let coord = coordinator(for: controller)
                coord.onChanged(
                    location: value.location, startLocation: value.startLocation,
                    translation: value.translation, in: viewSize
                )
            }
            .onEnded { _ in
                coordinator?.onEnded()
            }
    }

    private func coordinator(for controller: AreaSelectionController)
        -> AreaSelectionGestureCoordinator
    {
        if let existing = coordinator, existing.controller === controller { return existing }
        let new = AreaSelectionGestureCoordinator(controller: controller)
        coordinator = new
        return new
    }

    @ViewBuilder
    private var rubberBandOverlay: some View {
        switch controller.tool {
        case .navigate:
            EmptyView()

        case .rectangle:
            if controller.dragPoints.count >= 2 {
                let a = controller.dragPoints[0]
                let b = controller.dragPoints[1]
                let rect = CGRect(
                    x: min(a.x, b.x), y: min(a.y, b.y),
                    width: abs(a.x - b.x), height: abs(a.y - b.y)
                )
                ZStack {
                    Rectangle().fill(Color.accentColor.opacity(0.15))
                    Rectangle().stroke(Color.accentColor, lineWidth: 1)
                }
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
            }

        case .lasso:
            if controller.dragPoints.count >= 2 {
                ZStack {
                    LassoShape(points: controller.dragPoints).fill(Color.accentColor.opacity(0.15))
                    LassoShape(points: controller.dragPoints).stroke(
                        Color.accentColor, lineWidth: 1)
                }
            }
        }
    }
}

/// A closed polyline through `points`: the lasso's rubber-band outline.
private struct LassoShape: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for p in points.dropFirst() { path.addLine(to: p) }
        path.closeSubpath()
        return path
    }
}
