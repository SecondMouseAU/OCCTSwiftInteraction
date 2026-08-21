// AgentBridgeTests.swift
// OCCTSwiftCADKitTests
//
// Coverage for OCCTSwiftInteraction#16: startSelectionSidecar/stopSelectionSidecar, per the
// acceptance criteria in the issue and the wire format in
// okf/decisions/agent-viewport-selection-bridge.md (#17).

import Foundation
import OCCTSwift
import OCCTSwiftAIS
import OCCTSwiftTools
import OCCTSwiftViewport
import Testing

@testable import OCCTSwiftCADKit

/// A fresh, empty directory under the system temp dir, removed by the caller's own `defer`.
private func makeTempDirectory() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
        "occtmcp-agent-bridge-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Writes `payload` to `highlight_requests/<id>.json` under `directory`, atomically, as the
/// ADR requires of the MCP-side client.
private func writeHighlightRequest(
    _ payload: HighlightRequestPayload, id: String, in directory: URL
) throws {
    let url = CADViewportService.highlightRequestsDirectory(in: directory)
        .appendingPathComponent("\(id).json")
    let data = try JSONEncoder().encode(payload)
    try data.write(to: url, options: .atomic)
}

@Suite("Agent selection sidecar")
struct AgentBridgeTests {

    // MARK: - selection.json

    @MainActor
    @Test("startSelectionSidecar writes selection.json and bumps revision on every change")
    func selectionSidecarWritesAndBumpsRevision() throws {
        let box = try #require(Shape.box(width: 4, height: 4, depth: 4))
        let service = CADViewportService()
        service.load(box, id: "box")

        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try service.startSelectionSidecar(directory: dir)
        defer { service.stopSelectionSidecar() }

        let selectionURL = dir.appendingPathComponent("selection.json")
        let initialData = try #require(FileManager.default.contents(atPath: selectionURL.path))
        let initialDoc = try JSONDecoder().decode(SelectionSidecarDocument.self, from: initialData)
        #expect(initialDoc.revision == 0)
        #expect(initialDoc.selections.isEmpty)

        let pick = try #require(service.resolveFacePick(bodyID: "box", triangleIndex: 0))
        service.select(.face(pick))

        let updatedData = try #require(FileManager.default.contents(atPath: selectionURL.path))
        let updatedDoc = try JSONDecoder().decode(SelectionSidecarDocument.self, from: updatedData)
        #expect(updatedDoc.revision == 1)
        #expect(updatedDoc.selections.count == 1)
        #expect(updatedDoc.selections[0].bodyId == "box")
        #expect(updatedDoc.selections[0].kind == "face")
        #expect(updatedDoc.selections[0].index == pick.faceIndex)

        // A second change bumps revision again, even though this clears back to empty rather
        // than changing which entity is selected: the ADR says every write bumps it, not only
        // a write whose selection set differs from the last one.
        service.clearSelection()
        let clearedData = try #require(FileManager.default.contents(atPath: selectionURL.path))
        let clearedDoc = try JSONDecoder().decode(SelectionSidecarDocument.self, from: clearedData)
        #expect(clearedDoc.revision == 2)
        #expect(clearedDoc.selections.isEmpty)
    }

    // MARK: - highlight_requests/ (no question)

    @MainActor
    @Test("A well-formed request with no question selects the entity and is marked applied")
    func highlightRequestNoQuestionSelectsAndIsApplied() throws {
        let box = try #require(Shape.box(width: 10, height: 8, depth: 6))
        let service = CADViewportService()
        service.load(box, id: "box")
        let pick = try #require(service.resolveFacePick(bodyID: "box", triangleIndex: 0))

        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try service.startSelectionSidecar(directory: dir)
        defer { service.stopSelectionSidecar() }

        let requestID = "req-face"
        try writeHighlightRequest(
            HighlightRequestPayload(
                id: requestID, bodyId: "box", kind: "face", index: pick.faceIndex,
                scheme: "replace", question: nil),
            id: requestID, in: dir)

        service.processHighlightRequests()

        #expect(service.selection.contains(.face(pick)))

        let requestURL = CADViewportService.highlightRequestsDirectory(in: dir)
            .appendingPathComponent("\(requestID).json")
        #expect(
            !FileManager.default.fileExists(atPath: requestURL.path),
            "the request must be moved out of highlight_requests/, not left in place")

        let handledURL = CADViewportService.handledDirectory(in: dir)
            .appendingPathComponent("\(requestID).json")
        let handledData = try #require(FileManager.default.contents(atPath: handledURL.path))
        let outcome = try JSONDecoder().decode(HandledOutcome.self, from: handledData)
        #expect(outcome.outcome == "applied")
    }

    @MainActor
    @Test("A highlight request resolves edge and vertex kinds too, by identity-table ordinal")
    func highlightRequestResolvesEdgeAndVertexKinds() throws {
        let box = try #require(Shape.box(width: 10, height: 8, depth: 6))
        let service = CADViewportService()
        service.selectionModes = [.face, .edge, .vertex]
        service.load(box, id: "box")
        let edgePick = try #require(service.resolveEdgePick(bodyID: "box", segmentIndex: 0))
        let vertexPick = try #require(service.resolveVertexPick(bodyID: "box", pointIndex: 0))

        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try service.startSelectionSidecar(directory: dir)
        defer { service.stopSelectionSidecar() }

        try writeHighlightRequest(
            HighlightRequestPayload(
                id: "req-edge", bodyId: "box", kind: "edge", index: edgePick.edgeIndex,
                scheme: "replace", question: nil),
            id: "req-edge", in: dir)
        service.processHighlightRequests()
        #expect(service.selection.contains(.edge(edgePick)))

        try writeHighlightRequest(
            HighlightRequestPayload(
                id: "req-vertex", bodyId: "box", kind: "vertex", index: vertexPick.vertexIndex,
                scheme: "add", question: nil),
            id: "req-vertex", in: dir)
        service.processHighlightRequests()
        #expect(service.selection.contains(.vertex(vertexPick)))
        #expect(service.selection.contains(.edge(edgePick)), "add must not drop the prior pick")
    }

    // MARK: - highlight_requests/ (with question)

    @MainActor
    @Test("A request with a question presents an escalation instead of a plain select")
    func highlightRequestWithQuestionPresentsEscalation() throws {
        let box = try #require(Shape.box(width: 10, height: 8, depth: 6))
        let service = CADViewportService()
        service.load(box, id: "box")
        let pick = try #require(service.resolveFacePick(bodyID: "box", triangleIndex: 0))

        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try service.startSelectionSidecar(directory: dir)
        defer { service.stopSelectionSidecar() }
        defer { service.respond(.deferred) }  // resolve the continuation so nothing leaks

        let requestID = "req-question"
        try writeHighlightRequest(
            HighlightRequestPayload(
                id: requestID, bodyId: "box", kind: "face", index: pick.faceIndex,
                scheme: "replace", question: "Through-hole or blind pocket?"),
            id: requestID, in: dir)

        service.processHighlightRequests()

        let pending = try #require(service.pendingEscalation)
        #expect(pending.question == "Through-hole or blind pocket?")
        #expect(pending.entities == [.face(pick)])
        #expect(service.selection.contains(.face(pick)))

        let handledURL = CADViewportService.handledDirectory(in: dir)
            .appendingPathComponent("\(requestID).json")
        let handledData = try #require(FileManager.default.contents(atPath: handledURL.path))
        let outcome = try JSONDecoder().decode(HandledOutcome.self, from: handledData)
        #expect(outcome.outcome == "applied")
    }

    // MARK: - Rejections

    @MainActor
    @Test("A request naming a body that isn't loaded is rejected with a reason, and moved")
    func highlightRequestUnknownBodyIsRejected() throws {
        let service = CADViewportService()
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try service.startSelectionSidecar(directory: dir)
        defer { service.stopSelectionSidecar() }

        let requestID = "req-bad-body"
        try writeHighlightRequest(
            HighlightRequestPayload(
                id: requestID, bodyId: "no-such-body", kind: "face", index: 0,
                scheme: "replace", question: nil),
            id: requestID, in: dir)

        service.processHighlightRequests()

        let requestURL = CADViewportService.highlightRequestsDirectory(in: dir)
            .appendingPathComponent("\(requestID).json")
        #expect(!FileManager.default.fileExists(atPath: requestURL.path))

        let handledURL = CADViewportService.handledDirectory(in: dir)
            .appendingPathComponent("\(requestID).json")
        let handledData = try #require(FileManager.default.contents(atPath: handledURL.path))
        let outcome = try JSONDecoder().decode(HandledOutcome.self, from: handledData)
        #expect(outcome.outcome == "rejected")
        #expect(outcome.reason != nil)
    }

    @MainActor
    @Test("A request whose face index doesn't resolve is rejected with a reason, and moved")
    func highlightRequestBadIndexIsRejected() throws {
        let box = try #require(Shape.box(width: 4, height: 4, depth: 4))
        let service = CADViewportService()
        service.load(box, id: "box")

        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try service.startSelectionSidecar(directory: dir)
        defer { service.stopSelectionSidecar() }

        let requestID = "req-bad-index"
        try writeHighlightRequest(
            HighlightRequestPayload(
                id: requestID, bodyId: "box", kind: "face", index: 999_999,
                scheme: "replace", question: nil),
            id: requestID, in: dir)

        service.processHighlightRequests()

        #expect(service.selection.isEmpty, "a rejected request must not select anything")

        let handledURL = CADViewportService.handledDirectory(in: dir)
            .appendingPathComponent("\(requestID).json")
        let handledData = try #require(FileManager.default.contents(atPath: handledURL.path))
        let outcome = try JSONDecoder().decode(HandledOutcome.self, from: handledData)
        #expect(outcome.outcome == "rejected")
        #expect(outcome.reason != nil)
    }

    @MainActor
    @Test("A malformed (foreign id) request file is left in place, not moved to handled/")
    func malformedRequestFileIsLeftAlone() throws {
        let service = CADViewportService()
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try service.startSelectionSidecar(directory: dir)
        defer { service.stopSelectionSidecar() }

        // The filename stem ("mismatched") doesn't match the payload's own `id` ("other-id"):
        // per the ADR, a reader treats this as foreign/corrupt and ignores it.
        let requestURL = CADViewportService.highlightRequestsDirectory(in: dir)
            .appendingPathComponent("mismatched.json")
        let payload = HighlightRequestPayload(
            id: "other-id", bodyId: "box", kind: "face", index: 0, scheme: "replace",
            question: nil)
        try JSONEncoder().encode(payload).write(to: requestURL, options: .atomic)

        service.processHighlightRequests()

        #expect(FileManager.default.fileExists(atPath: requestURL.path), "must not be moved")
        let handledURL = CADViewportService.handledDirectory(in: dir)
            .appendingPathComponent("mismatched.json")
        #expect(!FileManager.default.fileExists(atPath: handledURL.path))
    }

    // MARK: - host.json / host.lock

    @MainActor
    @Test("startSelectionSidecar writes host.json and holds an exclusive lock on host.lock")
    func hostLockIsExclusiveWhileRunning() throws {
        let service = CADViewportService()
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try service.startSelectionSidecar(
            directory: dir, hostName: "TestHost", hostVersion: "9.9.9")

        let hostData = try #require(
            FileManager.default.contents(atPath: dir.appendingPathComponent("host.json").path))
        let host = try JSONDecoder().decode(HostDescriptor.self, from: hostData)
        #expect(host.hostName == "TestHost")
        #expect(host.hostVersion == "9.9.9")
        #expect(host.pid == Int(getpid()))
        #expect(host.schemaVersion == 1)

        let lockPath = dir.appendingPathComponent("host.lock").path
        let probeFD = open(lockPath, O_RDWR)
        #expect(probeFD >= 0)
        defer { close(probeFD) }

        #expect(
            flock(probeFD, LOCK_EX | LOCK_NB) != 0,
            "a second, independent exclusive-lock attempt must fail while the first host runs")

        service.stopSelectionSidecar()

        #expect(
            flock(probeFD, LOCK_EX | LOCK_NB) == 0,
            "the lock must be released once the sidecar stops")
        flock(probeFD, LOCK_UN)
    }

    @MainActor
    @Test("A second startSelectionSidecar call on the same service is safe (stops the first)")
    func restartingSidecarDoesNotLeakTheOldLock() throws {
        let service = CADViewportService()
        let dirA = makeTempDirectory()
        let dirB = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dirA) }
        defer { try? FileManager.default.removeItem(at: dirB) }

        try service.startSelectionSidecar(directory: dirA)
        try service.startSelectionSidecar(directory: dirB)
        defer { service.stopSelectionSidecar() }

        // dirA's lock must have been released by the restart, not leaked.
        let lockPathA = dirA.appendingPathComponent("host.lock").path
        let probeFD = open(lockPathA, O_RDWR)
        #expect(probeFD >= 0)
        defer { close(probeFD) }
        #expect(flock(probeFD, LOCK_EX | LOCK_NB) == 0)
        flock(probeFD, LOCK_UN)
    }

    // MARK: - Agent-highlight rendering (PresentationStyle.agentHighlight, OCCTSwiftInteraction#16)

    @MainActor
    @Test(
        "A highlight-request selection renders as agent_highlight_face, not selection_highlight_face"
    )
    func highlightRequestRendersDistinctlyFromAnOrdinaryPick() throws {
        let box = try #require(Shape.box(width: 10, height: 8, depth: 6))
        let service = CADViewportService()
        service.load(box, id: "box")
        let pick = try #require(service.resolveFacePick(bodyID: "box", triangleIndex: 0))

        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try service.startSelectionSidecar(directory: dir)
        defer { service.stopSelectionSidecar() }

        try writeHighlightRequest(
            HighlightRequestPayload(
                id: "req-render", bodyId: "box", kind: "face", index: pick.faceIndex,
                scheme: "replace", question: nil),
            id: "req-render", in: dir)
        service.processHighlightRequests()

        let ids = Set(service.interactiveContext.bodies.map(\.id))
        #expect(ids.contains("agent_highlight_face"))
        #expect(!ids.contains("selection_highlight_face"))

        // Control: an ordinary pick (.replace here drops the agent tag, since it isn't
        // re-tagged) renders the long-standing selection color instead.
        let meta = try #require(service.metadata["box"])
        let firstFaceOrdinal = meta.faceIndices[0]
        let otherTriangle = try #require(
            meta.faceIndices.firstIndex { $0 != firstFaceOrdinal },
            "expected a box to have more than one face ordinal")
        let otherPick = try #require(
            service.resolveFacePick(bodyID: "box", triangleIndex: otherTriangle))
        service.select(.face(otherPick))
        let idsAfterPlainSelect = Set(service.interactiveContext.bodies.map(\.id))
        #expect(idsAfterPlainSelect.contains("selection_highlight_face"))
        #expect(!idsAfterPlainSelect.contains("agent_highlight_face"))
    }

    // MARK: - Real DirectoryWatcher (timing-sensitive; see CLAUDE.md notes on running the full suite repeatedly)

    @MainActor
    @Test(
        "The real DirectoryWatcher notices a dropped request and applies it without a manual poke")
    func realWatcherNoticesAndAppliesADroppedRequest() async throws {
        let box = try #require(Shape.box(width: 10, height: 8, depth: 6))
        let service = CADViewportService()
        service.load(box, id: "box")
        let pick = try #require(service.resolveFacePick(bodyID: "box", triangleIndex: 0))

        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try service.startSelectionSidecar(directory: dir)
        defer { service.stopSelectionSidecar() }

        let requestID = "req-watched"
        try writeHighlightRequest(
            HighlightRequestPayload(
                id: requestID, bodyId: "box", kind: "face", index: pick.faceIndex,
                scheme: "replace", question: nil),
            id: requestID, in: dir)

        let handledURL = CADViewportService.handledDirectory(in: dir)
            .appendingPathComponent("\(requestID).json")

        var handled = false
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: handledURL.path) {
                handled = true
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)  // 50ms, up to ~5s total
        }

        #expect(handled, "expected the real DirectoryWatcher to notice the dropped request")
        #expect(service.selection.contains(.face(pick)))
    }
}
