import SwiftUI

/// Presents the question, candidates, and context of an `EscalationRequest`, and reports how
/// it was answered via closures.
///
/// Mirrors `CADViewportView`'s own style (explicit values + callbacks, no direct binding to
/// `CADViewportService`) so the caller stays in control of composing it (a sheet, a sidebar
/// inspector, a bottom card) rather than this view owning presentation chrome.
///
/// Capped to a comfortable phone-width column rather than two separate macOS/iOS view types:
/// this single layout is usable as a floating panel on a larger surface too.
///
/// ```swift
/// if let request = viewport.pendingEscalation {
///     EscalationCardView(
///         request: request,
///         selection: viewport.selection,
///         onChoose: { viewport.respond(.chose(candidateID: $0)) },
///         onUseSelection: { viewport.respondWithCurrentSelection() },
///         onDefer: { viewport.respond(.deferred) },
///         onReject: { viewport.respond(.rejected(reason: $0)) }
///     )
/// }
/// ```
public struct EscalationCardView: View {
    public let request: EscalationRequest
    public let selection: [PickedEntity]
    public var onChoose: ((String) -> Void)?
    public var onUseSelection: (() -> Void)?
    public var onDefer: (() -> Void)?
    public var onReject: ((String?) -> Void)?

    public init(
        request: EscalationRequest,
        selection: [PickedEntity] = [],
        onChoose: ((String) -> Void)? = nil,
        onUseSelection: (() -> Void)? = nil,
        onDefer: (() -> Void)? = nil,
        onReject: ((String?) -> Void)? = nil
    ) {
        self.request = request
        self.selection = selection
        self.onChoose = onChoose
        self.onUseSelection = onUseSelection
        self.onDefer = onDefer
        self.onReject = onReject
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(request.question)
                .font(.headline)

            if let context = request.context, !context.isEmpty {
                contextView(context)
            }

            if !request.candidates.isEmpty {
                candidatesView
            }

            actionsView
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: 360)
    }

    private func contextView(_ context: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(context.keys.sorted(), id: \.self) { key in
                HStack {
                    Text(key).foregroundStyle(.secondary)
                    Spacer()
                    Text(context[key] ?? "")
                }
                .font(.caption)
            }
        }
    }

    private var candidatesView: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(request.candidates) { candidate in
                Button {
                    onChoose?(candidate.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.label)
                            .font(.subheadline)
                        if let detail = candidate.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var actionsView: some View {
        HStack {
            Button("Use selection") {
                onUseSelection?()
            }
            .disabled(selection.isEmpty)

            Spacer()

            Button("Defer") {
                onDefer?()
            }

            Button("Reject", role: .destructive) {
                onReject?(nil)
            }
        }
        .buttonStyle(.bordered)
        .font(.caption)
    }
}
