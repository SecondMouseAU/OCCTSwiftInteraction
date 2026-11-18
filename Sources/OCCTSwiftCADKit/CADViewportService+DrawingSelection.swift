// CADViewportService+DrawingSelection.swift
// OCCTSwiftCADKit
//
// OCCTSwiftInteraction#45: how a host publishes a pick on a 2D drawing entity through the
// agent-viewport selection bridge. Wire shape: `SelectionSidecar.swift`; contract and rules:
// `okf/decisions/agent-viewport-selection-bridge.md` and `docs/reference/CADViewportService.md`.
//
// macOS-only, matching the sidecar it publishes through.

#if os(macOS)

    import Foundation

    @MainActor
    extension CADViewportService {

        /// Replaces the drawing-entity picks published to `selection.json` with `picks`.
        ///
        /// The whole set: an empty array clears it, and adding a pick means passing the current
        /// ones too. Independent of the model selection, which the file carries beside it. The
        /// reference page has the rules for dropped picks, unchanged sets and failed writes.
        public func setDrawingSelection(_ picks: [DrawingEntityPick]) {
            let normalized = DrawingEntityPick.normalized(picks)
            guard Set(normalized) != Set(drawingSelection) else { return }
            let previous = drawingSelection
            drawingSelection = normalized
            guard sidecarDirectory != nil else { return }
            if !republishSelectionSidecar() { drawingSelection = previous }
        }

        /// The held drawing picks as wire entries, ordered by drawing then entity.
        func drawingSelectionSidecarEntries() -> [SelectionSidecarEntry] {
            drawingSelection
                .map(SelectionSidecarEntry.init(drawingPick:))
                .sorted { lhs, rhs in
                    if lhs.bodyId != rhs.bodyId { return lhs.bodyId < rhs.bodyId }
                    return (lhs.entity ?? "") < (rhs.entity ?? "")
                }
        }
    }

#endif
