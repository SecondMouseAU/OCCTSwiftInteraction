// SelectionChange.swift
// OCCTSwiftCADKit
//
// OCCTSwiftInteraction#31: who changed the selection, published from the one place that sees
// every path (`syncSelection(with:)`).

import Foundation

/// What caused a change to `CADViewportService.selection`.
///
/// Anything this service cannot attribute, including a change a host makes straight on
/// `interactiveContext` (area selection, a pick on a body the context displays itself, a
/// `selectionMode` change that clears the selection), reports as `.programmatic`.
public enum SelectionChangeSource: Sendable, Equatable {
    /// A pick on a body this service resolved into a face, edge or vertex.
    case viewportPick
    /// A pick that hit nothing, or hit something this service's mode or clip planes rejected.
    case emptySpaceClick
    /// `select(_:scheme:)`, `clearSelection()`, or any other direct change.
    case programmatic
    /// A `highlight_requests/<id>.json` request that targeted the selection (or carried a
    /// question), named by the request's id.
    case agentHighlight(requestID: String)
    /// The selected entity's body was removed or reloaded.
    case bodyRemoved(bodyID: String)
    /// A cap-enabled clipping plane cut the selected entity's body again, or stopped cutting it,
    /// and the selection on that body was remapped onto its new topology (OCCTSwiftInteraction#77).
    ///
    /// The body's sub-shapes are renumbered and its durable uids minted afresh, so a pick stored
    /// from before this change no longer names anything on it, exactly as after `bodyRemoved`.
    ///
    /// Published for every recut body with a selected face, edge or vertex, even when `previous`
    /// and `current` compare equal, which they can on a body whose graph failed to build (refs
    /// then compare by ordinal): `current` holds the entities re-enriched from the new body, with
    /// its shapes and measurements (OCCTSwiftInteraction#85).
    case bodyRecut(bodyID: String)
}

/// One change to `CADViewportService.selection`, with the state on either side of it.
public struct SelectionChange: Sendable, Equatable {
    /// `selection` before the change, which a `$selection` sink cannot read back.
    public let previous: [PickedEntity]
    public let current: [PickedEntity]
    public let source: SelectionChangeSource
}
