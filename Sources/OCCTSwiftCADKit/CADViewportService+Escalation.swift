// CADViewportService+Escalation.swift
// OCCTSwiftCADKit
//
// Split out of CADViewportService.swift for OCCTSwiftInteraction#13 (code-structure policy).
// The service's stored state stays in the core file; this is the escalation-card surface of the same
// type. A move, not a rewrite: the bodies below are unchanged.

import Combine
import Foundation
import OCCTSwift
import OCCTSwiftAIS
import OCCTSwiftTools
import OCCTSwiftViewport
import SwiftUI
import simd

@MainActor
extension CADViewportService {

    // MARK: - Escalation

    /// Presents a bounded question about specific geometry and suspends until it's answered.
    ///
    /// Highlights `request.entities` (replacing the current `selection`, exactly like a real
    /// pick would) so the question is grounded in visible geometry, and makes any supplied
    /// `EscalationCandidate.previewBodyID` visible. If a PREVIOUS escalation is still pending,
    /// it's resolved `.deferred` first, mirroring the "undo the previous one before applying
    /// the new one" pattern of `setComparison`, so a continuation never leaks.
    ///
    /// The caller answers via `respond(_:)` (typically from a SwiftUI action, see
    /// `EscalationCardView`) or `respondWithCurrentSelection()` for "the human picked
    /// something instead of choosing a candidate." If the calling `Task` is cancelled while
    /// this is suspended (a SwiftUI `.task` whose view disappears, an agent racing this
    /// against its own timeout), resolves `.deferred` on its own rather than leaving
    /// `pendingEscalation`/the continuation stuck forever with nothing left to cancel it.
    /// The `onCancel` of `withTaskCancellationHandler` isn't guaranteed to run on
    /// `MainActor`, so it hops via an unstructured `Task` into
    /// `respondIfStillPending(_:with:)`, which is safe to call from there even if that
    /// happens before `escalationContinuation` is set (it just no-ops): `@MainActor`'s
    /// cooperative, non-preemptive scheduling means that hop can't actually run until this
    /// method's own synchronous continuation-setup completes, so the ordering that matters
    /// (`escalationContinuation` set before any cancellation response can fire) always holds
    /// in practice.
    ///
    /// The `onCancel` hop captures `request.id`, not just "resolve whatever's pending",
    /// otherwise a STALE cancellation (this exact request already superseded by a newer
    /// `present(_:)` call before the hop got a chance to run) would wrongly resolve the NEWER,
    /// still-legitimately-pending request instead of being a no-op. Concretely: task A is
    /// cancelled, its `onCancel` hop is merely enqueued (not yet run); before it runs, a
    /// caller legitimately calls `present(requestB)`, which itself supersedes A (correctly,
    /// via the `respond(.deferred)` above) and installs B's own continuation; THEN A's queued
    /// hop finally executes: without the id check, it would silently resolve B as `.deferred`
    /// even though nothing about B was ever cancelled.
    @discardableResult
    public func present(_ request: EscalationRequest) async -> EscalationResponse {
        if pendingEscalation != nil {
            respond(.deferred)
        }
        pendingEscalation = request

        if let first = request.entities.first {
            select(first, scheme: .replace)
            for entity in request.entities.dropFirst() {
                select(entity, scheme: .add)
            }
        } else {
            clearSelection()
        }

        for candidate in request.candidates {
            if let bodyID = candidate.previewBodyID {
                setBodyVisible(true, bodyID: bodyID)
            }
        }

        let requestID = request.id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                escalationContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor in
                self.respondIfStillPending(requestID, with: .deferred)
            }
        }
    }

    /// Resolves the pending escalation (no-op if none is pending), resuming whichever
    /// `present(_:)` call is awaiting it.
    public func respond(_ response: EscalationResponse) {
        guard let continuation = escalationContinuation else { return }
        escalationContinuation = nil
        pendingEscalation = nil
        continuation.resume(returning: response)
    }

    /// Resolves the pending escalation only if it's still the one named by `requestID`.
    ///
    /// Guards against a STALE resolution (from the `onCancel` hop of `present(_:)`, which
    /// captures a request id rather than running synchronously at the moment of cancellation)
    /// wrongly terminating a newer, still-legitimately-pending escalation that has already
    /// superseded the one actually being cancelled. Direct callers of `respond(_:)` (a
    /// SwiftUI action, an agent) don't need this: they're always resolving whatever
    /// `pendingEscalation` currently is, which is exactly what's on screen.
    ///
    /// `internal` rather than `private`, like `resolveFacePick`/`resolveEdgePick`/
    /// `resolveVertexPick`, so a test can exercise the exact stale-hop scenario directly
    /// (call this with a superseded id and assert it's a no-op) rather than only through the
    /// real `Task` cancellation of `present(_:)`, whose `onCancel` hop and a superseding
    /// `present(_:)` call both racing on the SAME `@MainActor` serial executor don't actually
    /// force the "hop resolves after supersession" ordering this guards against. Confirmed
    /// empirically (a temporary probe) that a scheduling-only test of this passes identically
    /// with or without the guard, since the hop always finishes before a newly-spawned
    /// superseding `Task` gets a turn.
    func respondIfStillPending(_ requestID: String, with response: EscalationResponse) {
        guard pendingEscalation?.id == requestID else { return }
        respond(response)
    }

    /// Convenience for "the human answered by picking geometry": resolves with the CURRENT
    /// `selection` rather than requiring the caller to read and wrap it themselves.
    public func respondWithCurrentSelection() {
        respond(.picked(selection))
    }

    /// Auto-resolves the pending escalation as `.rejected` if it referenced any of the
    /// just-removed bodies, rather than leaving a `present(_:)` call suspended forever over
    /// geometry that no longer exists.
    func pruneEscalation(removingBodyIDs bodyIDs: [String]) {
        guard let request = pendingEscalation else { return }
        let removed = Set(bodyIDs)
        guard request.entities.contains(where: { removed.contains($0.bodyID) }) else { return }
        respond(.rejected(reason: "referenced geometry was removed"))
    }

    /// Sets a body's visibility by id, searching model bodies then every overlay layer:
    /// `EscalationCandidate.previewBodyID` isn't scoped to either, so `present(_:)` doesn't
    /// know in advance which one a given candidate's preview lives in.
    private func setBodyVisible(_ isVisible: Bool, bodyID: String) {
        if let index = modelBodies.firstIndex(where: { $0.id == bodyID }) {
            modelBodies[index].isVisible = isVisible
            rebuildBodies()
            return
        }
        for (overlayID, bodies) in overlays {
            if let index = bodies.firstIndex(where: { $0.id == bodyID }) {
                var updated = bodies
                updated[index].isVisible = isVisible
                overlays[overlayID] = updated
                rebuildBodies()
                return
            }
        }
    }
}
