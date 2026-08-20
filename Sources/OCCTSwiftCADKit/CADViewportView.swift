import OCCTSwift
import OCCTSwiftTools
import OCCTSwiftViewport
import SwiftUI

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

    public init(
        bodies: [_ViewportBody],
        controller: _ViewportController,
        selection: [PickedEntity] = [],
        onClearSelection: (() -> Void)? = nil
    ) {
        self.bodies = bodies
        self.controller = controller
        self.selection = selection
        self.onClearSelection = onClearSelection
    }

    public var body: some View {
        GeometryReader { proxy in
            _MetalViewportView(controller: controller, bodies: .constant(bodies))
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .clipped()
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
