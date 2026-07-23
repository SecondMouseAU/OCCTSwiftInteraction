import Foundation

/// A bounded question about specific geometry, presented via `CADViewportService.present(_:)`.
/// Grounds the question in the viewport by highlighting `entities` when presented, and lets
/// the human answer either by choosing one of `candidates` or by picking geometry directly
/// (`CADViewportService.respondWithCurrentSelection()`) — the useful answer is often "none of
/// those, this one."
public struct EscalationRequest: Sendable, Identifiable, Equatable {
    public let id: String

    /// What the question is about — highlighted in the viewport when presented (mirrors
    /// `CADViewportService.select(_:scheme:)`'s own multi-selection highlight).
    public let entities: [PickedEntity]

    public let question: String

    /// Candidate answers, if any. Empty when the only sensible answer is "pick the right
    /// geometry yourself" — a candidate list isn't required.
    public let candidates: [EscalationCandidate]

    /// Free-form supporting context (measurements, gate output) for display alongside the
    /// question.
    public let context: [String: String]?

    public init(
        id: String,
        entities: [PickedEntity],
        question: String,
        candidates: [EscalationCandidate] = [],
        context: [String: String]? = nil
    ) {
        self.id = id
        self.entities = entities
        self.question = question
        self.candidates = candidates
        self.context = context
    }
}

/// One candidate answer to an `EscalationRequest`.
public struct EscalationCandidate: Sendable, Identifiable, Equatable {
    public let id: String
    public let label: String
    public let detail: String?

    /// Id of an already-loaded/staged `_ViewportBody` (a model body or one staged via
    /// `setOverlay(id:bodies:)`) to show while this candidate is being considered. `nil` if
    /// this candidate has no preview geometry of its own.
    public let previewBodyID: String?

    public init(id: String, label: String, detail: String? = nil, previewBodyID: String? = nil) {
        self.id = id
        self.label = label
        self.detail = detail
        self.previewBodyID = previewBodyID
    }
}

/// How an `EscalationRequest` was answered.
public enum EscalationResponse: Sendable, Equatable {
    /// The human chose one of the request's `candidates`, by id.
    case chose(candidateID: String)

    /// The human answered by picking geometry instead of choosing a candidate.
    case picked([PickedEntity])

    /// The human postponed answering.
    case deferred

    /// The human rejected the question itself (not just its candidates).
    case rejected(reason: String?)
}
