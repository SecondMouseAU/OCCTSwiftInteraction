import Foundation
import OCCTSwift
import OCCTSwiftTools
import OCCTSwiftViewport
import SwiftUI

#if canImport(AppKit)
    import AppKit
#endif

/// SwiftUI wrapper around the Metal viewport, with a selection-info banner
/// and display-mode controls.
///
/// Bind to a `CADViewportService` for the standard pattern:
///
/// ```swift
/// @State private var viewport = CADViewportService()
///
/// var body: some View {
///     CADViewportView(
///         bodies: viewport.bodies,
///         controller: viewport.controller,
///         selection: viewport.selection,
///         onClearSelection: { viewport.clearSelection() }
///     )
/// }
/// ```
public struct CADViewportView: View {
    public let bodies: [_ViewportBody]
    @ObservedObject public var controller: _ViewportController
    public var selection: [PickedEntity]
    public var onClearSelection: (() -> Void)?
    /// Receives each primary mouse-down with whether its window was key.
    ///
    /// Wired by `init(service:)` to `CADViewportService.noteMouseDown(windowWasActive:)`.
    public var onMouseDown: ((_ windowWasActive: Bool) -> Void)?

    /// Hands the renderer a live view of `bodies`.
    ///
    /// `_MetalViewportView`'s `ViewportRenderer` captures the `Binding` it is given
    /// exactly once, at construction, and reads through that same reference on every
    /// frame. `.constant(bodies)` (the previous implementation) therefore froze the
    /// first render's bodies for good, so a selection highlight added later never
    /// reached the renderer.
    ///
    /// The box is a reference type, refreshed on every `body` evaluation, so the
    /// captured getter always returns the current array. Nothing is diffed: an
    /// in-place edit to `isVisible`, `transform` or `triangleStyles` is seen as
    /// readily as an added or removed body, and no `@State` write lands a frame late.
    ///
    /// `body` assigns `box.bodies` as a side effect, which SwiftUI discourages, and that is
    /// deliberate: the box is not observed state, so the write cannot trigger another update
    /// or loop, and it is the only way to refresh a reference the renderer captured once
    /// without a `@State` write that lands after the frame has already drawn. It is
    /// idempotent, so a re-evaluation is harmless.
    @State private var box: LiveBodies

    /// Reference-typed storage behind the binding handed to the renderer.
    ///
    /// The lock is belt and braces: `ViewportRenderer` is `@MainActor` and draws on the main
    /// actor, as does `body`, so today every access is already serialized. It keeps the
    /// `Sendable` claim honest if that ever changes. `_ViewportBody` is itself `Sendable`
    /// (`ViewportBody: Identifiable, Sendable` in OCCTSwiftViewport), so the array is safe
    /// to hand across isolation domains; keep that in mind if the type ever changes.
    final class LiveBodies: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [_ViewportBody]

        init(_ bodies: [_ViewportBody]) {
            self.stored = bodies
        }

        var bodies: [_ViewportBody] {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }

        /// A read-only binding onto the box.
        ///
        /// The getter reads the box at call time, not at creation time. The renderer only reads bodies; the setter is a no-op so nothing can bypass the
        /// `body` update path.
        var binding: Binding<[_ViewportBody]> {
            Binding(get: { self.bodies }, set: { _ in })
        }
    }

    public init(
        bodies: [_ViewportBody],
        controller: _ViewportController,
        selection: [PickedEntity] = [],
        onClearSelection: (() -> Void)? = nil,
        onMouseDown: ((_ windowWasActive: Bool) -> Void)? = nil
    ) {
        self.bodies = bodies
        self.controller = controller
        self.selection = selection
        self.onClearSelection = onClearSelection
        self.onMouseDown = onMouseDown
        self._box = State(initialValue: LiveBodies(bodies))
    }

    /// The whole standard wiring in one place: bodies, controller, selection, clear, and the
    /// mouse-down report that stops the window-activating click deselecting.
    @MainActor
    public init(service: CADViewportService) {
        self.init(
            bodies: service.bodies,
            controller: service.controller,
            selection: service.selection,
            onClearSelection: { [weak service] in service?.clearSelection() },
            onMouseDown: { [weak service] active in
                service?.noteMouseDown(windowWasActive: active)
            }
        )
    }

    public var body: some View {
        box.bodies = bodies
        return GeometryReader { proxy in
            _MetalViewportView(controller: controller, bodies: box.binding)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .clipped()
        #if canImport(AppKit)
            .background(MouseDownProbe(onMouseDown: onMouseDown))
        #endif
        .overlay(alignment: .top) {
            if selection.count == 1, let entity = selection.first {
                selectionLabel(entity)
                    .padding(8)
            } else if selection.count > 1 {
                selectionSummaryLabel(count: selection.count)
                    .padding(8)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            viewportControls
                .padding(8)
        }
    }

    private func selectionSummaryLabel(count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checklist")
            Text("\(count) selected")
                .font(.caption)
            Button {
                onClearSelection?()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func selectionLabel(_ entity: PickedEntity) -> some View {
        HStack(spacing: 8) {
            Image(systemName: iconName(for: entity))
                .foregroundStyle(iconColor(for: entity))
            Text(description(for: entity))
                .font(.caption)
            Button {
                onClearSelection?()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func iconName(for entity: PickedEntity) -> String {
        switch entity {
        case .face(let info): return info.isHorizontal ? "square.fill" : "rectangle.portrait.fill"
        case .edge: return "line.diagonal"
        case .vertex: return "circle.fill"
        }
    }

    /// Matches the highlight color `CADViewportService` draws in the 3D scene for each kind.
    private func iconColor(for entity: PickedEntity) -> SwiftUI.Color {
        switch entity {
        case .face: return .yellow
        case .edge: return .cyan
        case .vertex: return .pink
        }
    }

    private func description(for entity: PickedEntity) -> String {
        switch entity {
        case .face(let info): return info.description
        case .edge(let info): return info.description
        case .vertex(let info): return info.description
        }
    }

    private var viewportControls: some View {
        HStack(spacing: 4) {
            Button {
                controller.displayMode = .shaded
            } label: {
                Image(systemName: "cube.fill")
                    .foregroundStyle(controller.displayMode == .shaded ? .blue : .secondary)
            }
            .buttonStyle(.plain)

            Button {
                controller.displayMode = .shadedWithEdges
            } label: {
                Image(systemName: "cube.transparent")
                    .foregroundStyle(
                        controller.displayMode == .shadedWithEdges ? .blue : .secondary)
            }
            .buttonStyle(.plain)

            Button {
                controller.displayMode = .wireframe
            } label: {
                Image(systemName: "square.dashed")
                    .foregroundStyle(controller.displayMode == .wireframe ? .blue : .secondary)
            }
            .buttonStyle(.plain)

            Divider().frame(height: 16)

            Button {
                controller.goToStandardView(.isometricFrontRight)
            } label: {
                Image(systemName: "rotate.3d")
            }
            .buttonStyle(.plain)
        }
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

#if canImport(AppKit)
    /// Reports whether the window was key at each primary mouse-down inside this view.
    ///
    /// A local event monitor sees the event in `NSApplication.sendEvent`, before the window has
    /// processed the activation, so `isKeyWindow` is still the pre-click answer. That is the
    /// information the viewport's own pick callback has lost by the time it fires
    /// (OCCTSwiftInteraction#28). The event is passed through untouched, so the click still
    /// activates the window and still picks.
    private struct MouseDownProbe: NSViewRepresentable {
        let onMouseDown: ((Bool) -> Void)?

        func makeNSView(context: Context) -> ProbeView { ProbeView() }

        func updateNSView(_ view: ProbeView, context: Context) {
            view.onMouseDown = onMouseDown
        }

        static func dismantleNSView(_ view: ProbeView, coordinator: ()) {
            view.removeMonitor()
        }

        final class ProbeView: NSView {
            var onMouseDown: ((Bool) -> Void)?
            private var monitor: Any?

            override func hitTest(_ point: NSPoint) -> NSView? { nil }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                removeMonitor()
                guard window != nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
                    [weak self] event in
                    if let self, let window = self.window, event.window === window,
                        self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                    {
                        self.onMouseDown?(window.isKeyWindow)
                    }
                    return event
                }
            }

            func removeMonitor() {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
        }
    }
#endif
