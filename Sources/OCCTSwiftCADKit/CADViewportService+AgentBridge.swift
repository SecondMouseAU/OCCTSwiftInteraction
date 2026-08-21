// CADViewportService+AgentBridge.swift
// OCCTSwiftCADKit
//
// The agent-viewport selection bridge (OCCTSwiftInteraction#16): writes this service's live
// selection out to `selection.json` on every change, watches `<directory>/highlight_requests/`
// for a request an MCP-side agent dropped, and applies each well-formed one via
// `select(_:scheme:)` or `present(_:)`. Split into its own file per this repo's code-structure
// policy, following the same pattern as `+Selection.swift`/`+Escalation.swift`: the wire types
// live in `SelectionSidecar.swift`, this file is the behaviour.
//
// Full wire format: `okf/decisions/agent-viewport-selection-bridge.md` (OCCTSwiftInteraction#17).
//
// macOS-only: built on `OCCTSwiftIO.DirectoryWatcher`, itself gated to macOS (kqueue is a Darwin
// primitive), and `SelectionSidecar.swift`'s `HostLock` (`flock(2)`).

#if os(macOS)

    import Combine
    import Foundation
    import OCCTSwift
    import OCCTSwiftAIS
    import OCCTSwiftIO
    import OCCTSwiftTools
    import simd

    @MainActor
    extension CADViewportService {

        // MARK: - Lifecycle

        /// Starts writing this service's live selection to `<directory>/selection.json` and
        /// applying highlight requests dropped into `<directory>/highlight_requests/`, per the
        /// agent-viewport selection bridge ADR.
        ///
        /// Idempotent against a previous call: stops whatever the sidecar was doing first, so
        /// calling this again (e.g. against a new scene directory) never leaks the old watcher
        /// or `host.lock`.
        ///
        /// - Parameters:
        ///   - directory: the shared scene directory (the same one `manifest.json` lives in).
        ///     Created if absent, along with `highlight_requests/` and `highlight_requests/handled/`.
        ///   - hostName: this host application's name, written into `host.json`. The ADR's own
        ///     examples use the embedding app's name (`"ACADStudio"`); this package has no such
        ///     name of its own to default to sensibly, so a host embedding
        ///     `CADViewportService` should pass its own.
        ///   - hostVersion: this host application's version string, written into `host.json`.
        /// - Throws: `CADViewportError.sidecarHostAlreadyRunning` if another process already
        ///   holds `host.lock`; any `FileManager`/`Data` error from creating the directory
        ///   structure or writing `host.json`/`selection.json`.
        public func startSelectionSidecar(
            directory: URL,
            hostName: String = "OCCTSwiftInteraction",
            hostVersion: String = "0.0.0"
        ) throws {
            stopSelectionSidecar()

            let highlightRequestsDirectory = Self.highlightRequestsDirectory(in: directory)
            try FileManager.default.createDirectory(
                at: Self.handledDirectory(in: directory), withIntermediateDirectories: true)

            let lock = HostLock()
            try lock.acquire(at: directory.appendingPathComponent("host.lock"))
            sidecarHostLock = lock
            sidecarDirectory = directory

            let host = HostDescriptor(
                pid: Int(getpid()),
                startedAt: Self.isoNow(),
                hostName: hostName,
                hostVersion: hostVersion,
                schemaVersion: selectionSidecarSchemaVersion
            )
            try Self.writeJSON(host, to: directory.appendingPathComponent("host.json"))

            // The startup write is revision 0 itself, not an increment from some prior state,
            // per the ADR ("The host creates this file at startup (revision: 0, ...")).
            sidecarRevision = 0
            try writeSelectionSidecarDocument(selection: interactiveContext.selection)

            // `.dropFirst()`, matching `InteractiveContext.init`'s own `$pickResult`/
            // `$hoveredBodyID` subscriptions in `OCCTSwiftAIS`: a fresh `.sink` on a
            // `@Published` property receives the CURRENT value immediately, as its first
            // emission, which would otherwise double-count as a second "revision 1" write on
            // top of the explicit startup write immediately above. NOT `.receive(on:
            // RunLoop.main)`: matching `selectionSubscription`'s own reasoning in
            // `CADViewportService.swift`, this runs synchronously so `selection.json`'s
            // revision advances in lockstep with the selection change that caused it.
            //
            // Reads the emitted `newSelection` parameter, not `interactiveContext.selection`:
            // `@Published` publishes on `willSet`, so the stored property still reads the OLD
            // value for the duration of this synchronous callback (`syncSelection(with:)` in
            // `CADViewportService+Selection.swift` documents the identical gotcha).
            sidecarSelectionSubscription = interactiveContext.$selection
                .dropFirst()
                .sink { [weak self] newSelection in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.sidecarRevision += 1
                        do {
                            try self.writeSelectionSidecarDocument(selection: newSelection)
                        } catch {
                            // Roll the counter back rather than leave it ahead of what's
                            // actually on disk: a write failure here (disk full, permissions)
                            // must not let `sidecarRevision` diverge from `selection.json`'s
                            // own `revision` field, which is the whole point of the field. The
                            // next successful write picks up from the last one that actually
                            // landed, rather than skipping ahead by however many failed.
                            self.sidecarRevision -= 1
                        }
                    }
                }

            let watcher = DirectoryWatcher(url: highlightRequestsDirectory) { [weak self] in
                Task { @MainActor in
                    self?.processHighlightRequests()
                }
            }
            watcher.start()
            sidecarWatcher = watcher
        }

        /// Stops the sidecar: releases `host.lock`, stops watching `highlight_requests/`, and
        /// stops writing `selection.json`.
        ///
        /// Safe to call more than once, and safe to call when the sidecar was never started.
        public func stopSelectionSidecar() {
            sidecarWatcher?.stop()
            sidecarWatcher = nil
            sidecarSelectionSubscription?.cancel()
            sidecarSelectionSubscription = nil
            sidecarHostLock?.release()
            sidecarHostLock = nil
            sidecarDirectory = nil
        }

        // MARK: - selection.json

        /// Writes `selection` to `selection.json` at the CURRENT `sidecarRevision` (the caller
        /// is responsible for bumping it first for anything but the startup write, per the ADR:
        /// "incremented by exactly 1 on every write of this file, whether or not the selection
        /// set actually changed").
        ///
        /// Takes `selection` as a parameter rather than reading `interactiveContext.selection`:
        /// the sink that drives this from a real change fires during `@Published`'s `willSet`,
        /// when the context still reports the previous value (see the call site's own comment).
        func writeSelectionSidecarDocument(selection: Selection) throws {
            guard let directory = sidecarDirectory else { return }
            let entries =
                selection.subshapes
                .compactMap(selectionSidecarEntry)
                .sorted { lhs, rhs in
                    if lhs.bodyId != rhs.bodyId { return lhs.bodyId < rhs.bodyId }
                    if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
                    return lhs.index < rhs.index
                }
            let document = SelectionSidecarDocument(
                revision: sidecarRevision, updatedAt: Self.isoNow(), selections: entries)
            try Self.writeJSON(document, to: directory.appendingPathComponent("selection.json"))
        }

        /// One `Selection.subshapes` element, projected to the wire shape, or `nil` for a
        /// `SubShape` this service can't name a `bodyId` for (an object displayed directly into
        /// `interactiveContext`, never routed through `object(forBody:fallbackShape:)`): the
        /// same "can't enrich, so omit" rule `pickedEntity(for:)` already applies.
        private func selectionSidecarEntry(for subShape: OCCTSwiftTools.SubShape)
            -> SelectionSidecarEntry?
        {
            guard let bodyId = objectBodyIDs[subShape.object.id] else { return nil }
            switch subShape {
            case .body:
                return SelectionSidecarEntry(bodyId: bodyId, kind: "body", index: 0, uid: nil)
            case .face(_, let ref):
                return SelectionSidecarEntry(
                    bodyId: bodyId, kind: "face", index: ref.ordinal, uid: ref.uid?.wireString)
            case .edge(_, let ref):
                return SelectionSidecarEntry(
                    bodyId: bodyId, kind: "edge", index: ref.ordinal, uid: ref.uid?.wireString)
            case .vertex(_, let ref):
                return SelectionSidecarEntry(
                    bodyId: bodyId, kind: "vertex", index: ref.ordinal, uid: ref.uid?.wireString)
            }
        }

        // MARK: - highlight_requests/

        /// Scans `highlight_requests/` for pending request files and applies each one, in
        /// filename order.
        ///
        /// Internal rather than private so a test can drive it directly (deterministic, no
        /// polling for the real `DirectoryWatcher` to fire) alongside at least one test that
        /// goes through the real watcher end to end, per this repo's own convention for methods
        /// with a real production entry point elsewhere (`resolveFacePick` and siblings in
        /// `CADViewportService+Selection.swift` document the identical reasoning).
        func processHighlightRequests() {
            guard let directory = sidecarDirectory else { return }
            let highlightRequestsDirectory = Self.highlightRequestsDirectory(in: directory)
            let handledDirectory = Self.handledDirectory(in: directory)

            guard
                let entries = try? FileManager.default.contentsOfDirectory(
                    at: highlightRequestsDirectory,
                    includingPropertiesForKeys: [.creationDateKey])
            else { return }

            // Arrival order, not filename order: the ADR's `id` is an opaque string with no
            // ordering contract (OCCTMCP's own writer uses a UUID), so sorting by filename
            // text is arbitrary and can visibly misorder a numeric-looking id scheme
            // ("10.json" before "2.json"). Creation time survives the atomic
            // temp-name-then-rename write (rename preserves the original creation date), so it
            // reflects when each request actually landed, regardless of what its id looks
            // like. Falls back to filename order only if a date genuinely can't be read (rare,
            // and better than crashing the whole poll over one unreadable entry).
            let requestFiles =
                entries
                .filter { $0.pathExtension == "json" }
                .sorted { lhs, rhs in
                    let lhsDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]))?
                        .creationDate
                    let rhsDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]))?
                        .creationDate
                    if let lhsDate, let rhsDate, lhsDate != rhsDate {
                        return lhsDate < rhsDate
                    }
                    return lhs.lastPathComponent < rhs.lastPathComponent
                }

            for fileURL in requestFiles {
                guard let data = try? Data(contentsOf: fileURL),
                    let payload = try? JSONDecoder().decode(
                        HighlightRequestPayload.self, from: data)
                else {
                    // Corrupt: "a reader that finds a mismatch treats the file as foreign or
                    // corrupt and ignores it" (the ADR, about the id/filename check below, and
                    // the same posture applies to a file that doesn't even decode). Left in
                    // place rather than moved to handled/, since there is no well-formed
                    // request here to report an outcome for.
                    continue
                }
                let stem = fileURL.deletingPathExtension().lastPathComponent
                guard payload.id == stem else { continue }

                let outcome = applyHighlightRequest(payload)
                let handledURL = handledDirectory.appendingPathComponent("\(payload.id).json")
                guard (try? Self.writeJSON(outcome, to: handledURL)) != nil else { continue }
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

        /// Applies one well-formed `HighlightRequestPayload`, returning the outcome to record
        /// in `highlight_requests/handled/<id>.json`.
        private func applyHighlightRequest(_ request: HighlightRequestPayload) -> HandledOutcome {
            guard let scheme = Self.selectionScheme(fromWireValue: request.scheme) else {
                return HandledOutcome(
                    outcome: "rejected", reason: "unknown scheme '\(request.scheme)'")
            }

            switch resolveHighlightTarget(
                bodyId: request.bodyId, kind: request.kind, index: request.index)
            {
            case .rejected(let reason):
                return HandledOutcome(outcome: "rejected", reason: reason)

            case .wholeBody(let subShape):
                // `PickedEntity` has no `.body` case (OCCTSwiftInteraction#3's settled design,
                // see `PickedEntity.swift`), so a whole-body request can't build the
                // `EscalationRequest` a question needs.
                if let question = request.question, !question.isEmpty {
                    return HandledOutcome(
                        outcome: "rejected",
                        reason:
                            "escalation requests need a face, edge, or vertex, not kind \"body\""
                    )
                }
                interactiveContext.select(subShape, scheme: scheme)
                return HandledOutcome(outcome: "applied", reason: nil)

            case .entity(let entity):
                // Tagged before selecting/presenting, not after: both `select(_:scheme:)` and
                // `beginPresenting(_:)` synchronously trigger `syncSelection`, which prunes
                // `agentHighlightedEntities` down to whatever ends up in the new `selection`.
                // Tagging first means a `.remove`/`.xor` request that drops this entity also
                // drops the tag in the same step, rather than leaving it stale.
                agentHighlightedEntities.append(entity)
                if let question = request.question, !question.isEmpty {
                    let escalation = EscalationRequest(
                        id: request.id, entities: [entity], question: question)
                    // `beginPresenting` is synchronous: pendingEscalation is set and the
                    // entity is selected before this method returns, which is what
                    // "applied" below reports. The continuation half (awaiting an actual
                    // answer) is spun off separately: this sidecar doesn't block request
                    // processing on a human answering.
                    beginPresenting(escalation)
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        _ = await self.awaitResponse(to: escalation)
                    }
                } else {
                    select(entity, scheme: scheme)
                }
                return HandledOutcome(outcome: "applied", reason: nil)
            }
        }

        /// What a highlight request's `bodyId`/`kind`/`index` resolves to.
        private enum ResolvedHighlightTarget {
            case entity(PickedEntity)
            case wholeBody(OCCTSwiftTools.SubShape)
            case rejected(String)
        }

        /// Resolves `bodyId`/`kind`/`index` directly against the body's own identity tables.
        ///
        /// Reads `faceIdentity`/`edgeIdentity`/`vertexIdentity`, the same tables
        /// `OCCTSwiftTools.SubShapePickResolver` resolves a render-path pick through. A
        /// highlight request's `index` is already an identity-table ordinal (the MCP-side
        /// client's own graph-node index, per the ADR's design note), not a further-indirected
        /// render-path (triangle/segment/point) index, so this looks the ordinal up directly via
        /// `shape(forOrdinal:)`/`uid(forOrdinal:)` rather than routing through the resolver's
        /// triangle/segment/point-index entry points, which solve a different indirection.
        private func resolveHighlightTarget(bodyId: String, kind: String, index: Int)
            -> ResolvedHighlightTarget
        {
            guard let bodyShape = bodyShapes[bodyId] else {
                return .rejected("body '\(bodyId)' is not currently loaded")
            }
            switch kind {
            case "body":
                return .wholeBody(.body(object(forBody: bodyId, fallbackShape: bodyShape)))

            case "face":
                guard let table = faceIdentity[bodyId], let shape = table.shape(forOrdinal: index)
                else {
                    return .rejected("face index \(index) does not resolve on body '\(bodyId)'")
                }
                let ref = OCCTSwiftTools.SubShapeRef(
                    shape: shape, uid: table.uid(forOrdinal: index), ordinal: index)
                guard
                    let entity = enrichFace(ref: ref, bodyID: bodyId, triangleIndex: nil).map(
                        PickedEntity.face)
                else {
                    return .rejected(
                        "face at index \(index) on body '\(bodyId)' could not be resolved to geometry"
                    )
                }
                return .entity(entity)

            case "edge":
                guard let table = edgeIdentity[bodyId], let shape = table.shape(forOrdinal: index)
                else {
                    return .rejected("edge index \(index) does not resolve on body '\(bodyId)'")
                }
                let ref = OCCTSwiftTools.SubShapeRef(
                    shape: shape, uid: table.uid(forOrdinal: index), ordinal: index)
                guard
                    let entity = enrichEdge(ref: ref, bodyID: bodyId).map(PickedEntity.edge)
                else {
                    return .rejected(
                        "edge at index \(index) on body '\(bodyId)' could not be resolved to geometry"
                    )
                }
                return .entity(entity)

            case "vertex":
                guard let table = vertexIdentity[bodyId],
                    let shape = table.shape(forOrdinal: index)
                else {
                    return .rejected("vertex index \(index) does not resolve on body '\(bodyId)'")
                }
                let ref = OCCTSwiftTools.SubShapeRef(
                    shape: shape, uid: table.uid(forOrdinal: index), ordinal: index)
                guard
                    let entity = enrichVertex(ref: ref, bodyID: bodyId, renderPosition: nil).map(
                        PickedEntity.vertex)
                else {
                    return .rejected(
                        "vertex at index \(index) on body '\(bodyId)' could not be resolved to geometry"
                    )
                }
                return .entity(entity)

            default:
                return .rejected("unknown kind '\(kind)'")
            }
        }

        // MARK: - Helpers

        /// `nonisolated`: pure path arithmetic, no actor-isolated state, so a caller building a
        /// request file path (a test, or a future client in another process) doesn't need
        /// `@MainActor` just to compute where it goes.
        nonisolated static func highlightRequestsDirectory(in directory: URL) -> URL {
            directory.appendingPathComponent("highlight_requests", isDirectory: true)
        }

        nonisolated static func handledDirectory(in directory: URL) -> URL {
            highlightRequestsDirectory(in: directory).appendingPathComponent(
                "handled", isDirectory: true)
        }

        private static func selectionScheme(fromWireValue value: String) -> SelectionScheme? {
            switch value {
            case "replace": return .replace
            case "add": return .add
            case "remove": return .remove
            case "xor": return .xor
            default: return nil
            }
        }

        private static func isoNow() -> String {
            ISO8601DateFormatter().string(from: Date())
        }

        /// Encodes `value` and writes it to `url` via a temp-name-then-`rename(2)`.
        ///
        /// `Data.write(to:options:.atomic)`, per the ADR's atomicity rule. Creates `url`'s
        /// containing directory first if needed.
        private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(value)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }

#endif
