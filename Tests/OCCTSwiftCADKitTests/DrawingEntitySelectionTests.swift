// DrawingEntitySelectionTests.swift
// OCCTSwiftCADKitTests
//
// Coverage for OCCTSwiftInteraction#45: a pick on a 2D drawing entity travels the agent-viewport
// selection bridge as a `drawing-entity` entry in `selection.json`, per the ADR at
// okf/decisions/agent-viewport-selection-bridge.md ("The `drawing-entity` kind").

#if os(macOS)

    import Combine
    import Foundation
    import OCCTSwift
    import OCCTSwiftAIS
    import OCCTSwiftTools
    import Testing

    @testable import OCCTSwiftCADKit

    /// A fresh, empty directory under the system temp dir, removed by the caller's own `defer`.
    private func makeTempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "occt-drawing-entity-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func readDocument(in dir: URL) throws -> SelectionSidecarDocument {
        let url = dir.appendingPathComponent("selection.json")
        let data = try #require(FileManager.default.contents(atPath: url.path))
        return try JSONDecoder().decode(SelectionSidecarDocument.self, from: data)
    }

    /// The keys an encoded value carries, read back as plain JSON so an absent key is not
    /// confused with a key holding null.
    private func jsonKeys<T: Encodable>(of value: T) throws -> Set<String> {
        let data = try JSONEncoder().encode(value)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(object.keys)
    }

    private let dimension = DrawingEntityPick(
        drawing: "6575N383", entity: "2C1", entityType: "DIMENSION")
    private let line = DrawingEntityPick(
        drawing: "6575N383", entity: "ENTITIES:12", entityType: "LINE")

    @Suite("Drawing entity picks in selection.json")
    struct DrawingEntitySelectionTests {

        // MARK: - Wire shape

        @Test("A drawing-entity entry round-trips with entity and entityType and no uid")
        func drawingEntryRoundTrips() throws {
            let entry = SelectionSidecarEntry(
                bodyId: "6575N383", kind: "drawing-entity", index: 0, uid: nil,
                entity: "2C1", entityType: "DIMENSION")
            let data = try JSONEncoder().encode(entry)
            let decoded = try JSONDecoder().decode(SelectionSidecarEntry.self, from: data)
            #expect(decoded == entry)
            #expect(
                try jsonKeys(of: entry) == ["bodyId", "kind", "index", "entity", "entityType"],
                "uid is absent, not null, for a drawing pick")
        }

        @Test("A model entry encodes without the drawing fields, so old documents stay identical")
        func modelEntryHasNoDrawingFields() throws {
            let face = SelectionSidecarEntry(bodyId: "part1", kind: "face", index: 3, uid: "u-1")
            #expect(try jsonKeys(of: face) == ["bodyId", "kind", "index", "uid"])
            let body = SelectionSidecarEntry(bodyId: "part1", kind: "body", index: 0, uid: nil)
            #expect(try jsonKeys(of: body) == ["bodyId", "kind", "index"])
        }

        @Test("A document written before drawing picks existed still decodes")
        func olderDocumentStillDecodes() throws {
            let json = """
                { "revision": 7, "updatedAt": "2026-08-21T10:15:32Z", "selections": [
                  { "bodyId": "part1", "kind": "face", "index": 3, "uid": "b7e2f6a1" },
                  { "bodyId": "part1", "kind": "edge", "index": 1 },
                  { "bodyId": "part1", "kind": "body", "index": 0 } ] }
                """
            let document = try JSONDecoder().decode(
                SelectionSidecarDocument.self, from: Data(json.utf8))
            #expect(document.revision == 7)
            #expect(document.selections.count == 3)
            #expect(document.selections.allSatisfy { $0.entity == nil && $0.entityType == nil })
            let first = try #require(document.selections.first)
            #expect(first.uid == "b7e2f6a1")
        }

        @Test("A model pick and a drawing pick share one document under one revision")
        func mixedDocumentDecodes() throws {
            let json = """
                { "revision": 42, "updatedAt": "2026-11-18T10:15:40Z", "selections": [
                  { "bodyId": "part1", "kind": "face", "index": 3, "uid": "b7e2f6a1" },
                  { "bodyId": "6575N383", "kind": "drawing-entity", "index": 0,
                    "entity": "2C1", "entityType": "DIMENSION" } ] }
                """
            let document = try JSONDecoder().decode(
                SelectionSidecarDocument.self, from: Data(json.utf8))
            #expect(document.revision == 42)
            #expect(document.selections.map(\.kind) == ["face", "drawing-entity"])
            let drawing = try #require(document.selections.last)
            #expect(drawing.entity == "2C1")
            #expect(drawing.entityType == "DIMENSION")
            #expect(drawing.uid == nil)
        }

        /// What a reader built before this kind existed sees.
        ///
        /// The entry shape without `entity` or `entityType`. JSON decoding ignores keys a type
        /// does not declare, which is the whole reason the new fields need no `schemaVersion`
        /// bump.
        private struct PreDrawingEntry: Decodable {
            var bodyId: String
            var kind: String
            var index: Int
            var uid: String?
        }

        private struct PreDrawingDocument: Decodable {
            var revision: Int
            var selections: [PreDrawingEntry]
        }

        @MainActor
        @Test("A reader that predates the kind decodes what the writer emits")
        func olderReaderKeepsTheModelPicks() throws {
            let box = try #require(Shape.box(width: 4, height: 4, depth: 4))
            let service = CADViewportService()
            service.load(box, id: "box")
            let pick = try #require(service.resolveFacePick(bodyID: "box", triangleIndex: 0))

            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            try service.startSelectionSidecar(directory: dir)
            defer { service.stopSelectionSidecar() }
            service.select(.face(pick))
            service.setDrawingSelection([dimension])

            let data = try #require(
                FileManager.default.contents(
                    atPath: dir.appendingPathComponent("selection.json").path))
            let old = try JSONDecoder().decode(PreDrawingDocument.self, from: data)
            #expect(old.revision == 2)
            #expect(old.selections.map(\.kind) == ["face", "drawing-entity"])
            let model = try #require(old.selections.first)
            #expect(model.bodyId == "box")
            #expect(model.index == pick.faceIndex)
            let drawing = try #require(old.selections.last)
            #expect(drawing.uid == nil)
        }

        @Test("An entry of a kind nobody knows decodes and the other entries survive")
        func unknownKindDecodes() throws {
            let json = """
                { "revision": 9, "updatedAt": "2026-11-18T10:15:40Z", "selections": [
                  { "bodyId": "part1", "kind": "face", "index": 3 },
                  { "bodyId": "x", "kind": "toolpath-move", "index": 4, "future": [1, 2] },
                  { "bodyId": "part1", "kind": "vertex", "index": 0 } ] }
                """
            let document = try JSONDecoder().decode(
                SelectionSidecarDocument.self, from: Data(json.utf8))
            #expect(document.selections.map(\.kind) == ["face", "toolpath-move", "vertex"])
        }

        @Test("The schema version is still 1: a new kind is additive")
        func schemaVersionIsNotBumped() {
            #expect(selectionSidecarSchemaVersion == 1)
        }

        @Test("normalization drops empty names and keeps the first of a repeated entity")
        func normalizationDropsEmptyAndRepeated() {
            let picks = [
                DrawingEntityPick(drawing: "", entity: "A", entityType: nil),
                DrawingEntityPick(drawing: "case", entity: "", entityType: nil),
                DrawingEntityPick(drawing: "case", entity: "2C1", entityType: "DIMENSION"),
                DrawingEntityPick(drawing: "case", entity: "2C1", entityType: "TEXT"),
                DrawingEntityPick(drawing: "other", entity: "2C1", entityType: nil),
            ]
            let normalized = DrawingEntityPick.normalized(picks)
            #expect(
                normalized == [
                    DrawingEntityPick(drawing: "case", entity: "2C1", entityType: "DIMENSION"),
                    DrawingEntityPick(drawing: "other", entity: "2C1", entityType: nil),
                ])
        }

        // MARK: - Publishing through the sidecar

        @MainActor
        @Test("A drawing pick is published as a drawing-entity entry under a bumped revision")
        func drawingPickIsPublished() throws {
            let service = CADViewportService()
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            try service.startSelectionSidecar(directory: dir)
            defer { service.stopSelectionSidecar() }
            #expect(try readDocument(in: dir).revision == 0)

            service.setDrawingSelection([dimension])

            let document = try readDocument(in: dir)
            #expect(document.revision == 1)
            #expect(!document.updatedAt.isEmpty)
            #expect(
                document.selections == [
                    SelectionSidecarEntry(
                        bodyId: "6575N383", kind: "drawing-entity", index: 0, uid: nil,
                        entity: "2C1", entityType: "DIMENSION")
                ])
            #expect(service.drawingSelection == [dimension])
        }

        @MainActor
        @Test("The drawing and model picks are independent sets in one document")
        func drawingAndModelPicksAreIndependent() throws {
            let box = try #require(Shape.box(width: 4, height: 4, depth: 4))
            let service = CADViewportService()
            service.load(box, id: "box")
            let pick = try #require(service.resolveFacePick(bodyID: "box", triangleIndex: 0))

            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            try service.startSelectionSidecar(directory: dir)
            defer { service.stopSelectionSidecar() }

            service.select(.face(pick))
            #expect(try readDocument(in: dir).revision == 1)

            service.setDrawingSelection([dimension])
            var document = try readDocument(in: dir)
            #expect(document.revision == 2)
            #expect(
                document.selections.map(\.kind) == ["face", "drawing-entity"],
                "model entries first, then drawing entries, one document")

            // A change to the model set carries the drawing pick along.
            service.clearSelection()
            document = try readDocument(in: dir)
            #expect(document.revision == 3)
            #expect(document.selections.map(\.kind) == ["drawing-entity"])

            // And a change to the drawing set carries the model pick along.
            service.select(.face(pick))
            service.setDrawingSelection([])
            document = try readDocument(in: dir)
            #expect(document.revision == 5)
            #expect(document.selections.map(\.kind) == ["face"])
        }

        @MainActor
        @Test("Setting the drawing selection replaces the whole drawing set, ordered by entity")
        func drawingSetIsReplacedWhole() throws {
            let service = CADViewportService()
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            try service.startSelectionSidecar(directory: dir)
            defer { service.stopSelectionSidecar() }

            service.setDrawingSelection([line, dimension])
            var document = try readDocument(in: dir)
            #expect(
                document.selections.compactMap(\.entity) == ["2C1", "ENTITIES:12"],
                "ordered by drawing then entity, whatever order the host passed")

            let text = DrawingEntityPick(drawing: "6575N383", entity: "31", entityType: "TEXT")
            service.setDrawingSelection([text])
            document = try readDocument(in: dir)
            #expect(document.selections.compactMap(\.entity) == ["31"])
            #expect(service.drawingSelection == [text])
        }

        @MainActor
        @Test("Drawing picks are ordered by drawing before entity")
        func drawingPicksAreOrderedByDrawingFirst() throws {
            let service = CADViewportService()
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            try service.startSelectionSidecar(directory: dir)
            defer { service.stopSelectionSidecar() }

            service.setDrawingSelection([
                DrawingEntityPick(drawing: "B", entity: "1"),
                DrawingEntityPick(drawing: "A", entity: "9"),
                DrawingEntityPick(drawing: "A", entity: "2"),
            ])
            let entries = try readDocument(in: dir).selections
            #expect(entries.map(\.bodyId) == ["A", "A", "B"])
            #expect(entries.compactMap(\.entity) == ["2", "9", "1"])
        }

        @MainActor
        @Test("A change to entityType alone is a change, and is written")
        func entityTypeChangeIsWritten() throws {
            let service = CADViewportService()
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            try service.startSelectionSidecar(directory: dir)
            defer { service.stopSelectionSidecar() }

            service.setDrawingSelection([dimension])
            service.setDrawingSelection([
                DrawingEntityPick(drawing: "6575N383", entity: "2C1", entityType: "TEXT")
            ])
            let document = try readDocument(in: dir)
            #expect(document.revision == 2)
            #expect(document.selections.first?.entityType == "TEXT")
        }

        @MainActor
        @Test("Re-asserting the held drawing picks, in any order, writes nothing")
        func unchangedSetDoesNotBumpRevision() throws {
            let service = CADViewportService()
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            try service.startSelectionSidecar(directory: dir)
            defer { service.stopSelectionSidecar() }

            service.setDrawingSelection([dimension, line])
            let revision = service.sidecarRevision
            #expect(revision == 1)

            service.setDrawingSelection([dimension, line])
            service.setDrawingSelection([line, dimension])
            #expect(service.sidecarRevision == revision)
            #expect(try readDocument(in: dir).revision == revision)

            service.setDrawingSelection([dimension])
            #expect(service.sidecarRevision == revision + 1, "a real change still writes")
        }

        @MainActor
        @Test("Empty names and repeated entities never reach the file")
        func invalidPicksAreNotPublished() throws {
            let service = CADViewportService()
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            try service.startSelectionSidecar(directory: dir)
            defer { service.stopSelectionSidecar() }

            service.setDrawingSelection([
                DrawingEntityPick(drawing: "", entity: "A", entityType: nil),
                DrawingEntityPick(drawing: "6575N383", entity: "", entityType: nil),
                dimension,
                DrawingEntityPick(drawing: "6575N383", entity: "2C1", entityType: "TEXT"),
            ])
            let document = try readDocument(in: dir)
            #expect(document.selections.count == 1)
            #expect(document.selections.first?.entityType == "DIMENSION")
            #expect(service.drawingSelection == [dimension])
        }

        @MainActor
        @Test("A drawing selection held before the sidecar starts is in the startup write")
        func heldSelectionIsInTheStartupWrite() throws {
            let service = CADViewportService()
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }

            service.setDrawingSelection([dimension])
            #expect(service.drawingSelection == [dimension])
            #expect(service.sidecarRevision == 0, "no sidecar, so nothing was written")

            try service.startSelectionSidecar(directory: dir)
            defer { service.stopSelectionSidecar() }
            let document = try readDocument(in: dir)
            #expect(document.revision == 0)
            #expect(document.selections.compactMap(\.entity) == ["2C1"])
        }

        @MainActor
        @Test("Stopping the sidecar lets go of the model selection it was holding")
        func stopReleasesTheHeldModelSelection() throws {
            let box = try #require(Shape.box(width: 4, height: 4, depth: 4))
            let service = CADViewportService()
            service.load(box, id: "box")
            let pick = try #require(service.resolveFacePick(bodyID: "box", triangleIndex: 0))
            service.select(.face(pick))

            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            try service.startSelectionSidecar(directory: dir)
            #expect(!service.sidecarModelSelection.subshapes.isEmpty)

            service.stopSelectionSidecar()
            #expect(service.sidecarModelSelection.subshapes.isEmpty)
        }

        @MainActor
        @Test("The startup write carries a held model pick beside a held drawing pick")
        func startupWriteCarriesBothKinds() throws {
            let box = try #require(Shape.box(width: 4, height: 4, depth: 4))
            let service = CADViewportService()
            service.load(box, id: "box")
            let pick = try #require(service.resolveFacePick(bodyID: "box", triangleIndex: 0))
            service.select(.face(pick))
            service.setDrawingSelection([dimension])

            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            try service.startSelectionSidecar(directory: dir)
            defer { service.stopSelectionSidecar() }

            let document = try readDocument(in: dir)
            #expect(document.revision == 0)
            #expect(document.selections.map(\.kind) == ["face", "drawing-entity"])
        }

        @MainActor
        @Test("After the sidecar stops, a drawing pick is held but not written")
        func stoppedSidecarDoesNotWrite() throws {
            let service = CADViewportService()
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            try service.startSelectionSidecar(directory: dir)
            service.stopSelectionSidecar()

            service.setDrawingSelection([dimension])
            #expect(service.drawingSelection == [dimension])
            #expect(try readDocument(in: dir).selections.isEmpty)
        }

        // MARK: - Where the write reads its model selection, and when it fails

        /// Selects a face while a subscriber, installed by `subscribe`, clears the drawing pick
        /// from inside the change, and returns the kinds `selection.json` ends up carrying.
        ///
        /// Combine does not promise an order between subscribers to one `@Published` value, and a
        /// fresh service draws a fresh order, so a caller repeats this to cover both orders.
        @MainActor
        private func kindsAfterAClearDuringSelect(
            subscribingWith subscribe: (CADViewportService) -> AnyCancellable
        ) throws -> [String] {
            let box = try #require(Shape.box(width: 4, height: 4, depth: 4))
            let service = CADViewportService()
            service.load(box, id: "box")
            let pick = try #require(service.resolveFacePick(bodyID: "box", triangleIndex: 0))

            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            try service.startSelectionSidecar(directory: dir)
            defer { service.stopSelectionSidecar() }
            service.setDrawingSelection([dimension])

            let token = subscribe(service)
            defer { token.cancel() }
            service.select(.face(pick))

            #expect(service.selection == [.face(pick)])
            return try readDocument(in: dir).selections.map(\.kind)
        }

        @MainActor
        @Test("A drawing write inside a selectionChanges handler already carries the new selection")
        func writeInsideSelectionChangesCarriesTheNewSelection() throws {
            // The pattern the ADR suggests: a click in the viewport clears the drawing pick.
            // Combine draws a fresh subscriber order per service, so repeat to cover both.
            for _ in 0..<20 {
                let box = try #require(Shape.box(width: 4, height: 4, depth: 4))
                let service = CADViewportService()
                service.load(box, id: "box")
                let pick = try #require(service.resolveFacePick(bodyID: "box", triangleIndex: 0))

                let dir = makeTempDirectory()
                defer { try? FileManager.default.removeItem(at: dir) }
                try service.startSelectionSidecar(directory: dir)
                defer { service.stopSelectionSidecar() }
                service.setDrawingSelection([dimension])

                var writtenInHandler: [[String]] = []
                let token = service.selectionChanges.sink { _ in
                    service.setDrawingSelection([])
                    let document = try? readDocument(in: dir)
                    writtenInHandler.append(document?.selections.map(\.kind) ?? [])
                }
                defer { token.cancel() }
                service.select(.face(pick))

                #expect(writtenInHandler == [["face"]], "never the previous model selection")
                #expect(try readDocument(in: dir).selections.map(\.kind) == ["face"])
            }
        }

        @MainActor
        @Test("A drawing write from a raw context subscriber ends with the new selection")
        func rawContextSubscriberEndsWithTheNewSelection() throws {
            // Runs while `interactiveContext.selection` still reads the previous value
            // (`@Published` publishes on `willSet`). Depending on whether this subscriber or the
            // sidecar's own sink runs first, the write may carry the previous model selection for
            // one revision, and the next write corrects it. Only the final file is asserted; the
            // handler-time guarantee is pinned by the selectionChanges test above.
            for _ in 0..<20 {
                let kinds = try kindsAfterAClearDuringSelect { service in
                    service.interactiveContext.$selection.dropFirst().sink { _ in
                        service.setDrawingSelection([])
                    }
                }
                #expect(kinds == ["face"])
            }
        }

        @MainActor
        @Test("A start that fails partway leaves no half-started sidecar to write into")
        func failedStartLeavesNothingRunning() throws {
            let service = CADViewportService()
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }

            // host.json cannot be written over a non-empty directory of the same name.
            let blocker = dir.appendingPathComponent("host.json", isDirectory: true)
            try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
            try Data().write(to: blocker.appendingPathComponent("occupied"))
            #expect(throws: (any Error).self) {
                try service.startSelectionSidecar(directory: dir)
            }
            #expect(service.sidecarDirectory == nil)

            let anotherHost = HostLock()
            try anotherHost.acquire(at: dir.appendingPathComponent("host.lock"))
            defer { anotherHost.release() }

            service.setDrawingSelection([dimension])
            let selectionURL = dir.appendingPathComponent("selection.json")
            #expect(!FileManager.default.fileExists(atPath: selectionURL.path))
        }

        @MainActor
        @Test(
            "A failed write leaves the held set as it was, so the same call can be retried",
            .enabled(if: geteuid() != 0, "root ignores the directory permissions this relies on"))
        func failedWriteDoesNotAdvanceTheHeldSet() throws {
            let service = CADViewportService()
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            try service.startSelectionSidecar(directory: dir)
            defer { service.stopSelectionSidecar() }

            // An atomic write needs to create its temp file in the directory.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o555], ofItemAtPath: dir.path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: dir.path)
            }
            service.setDrawingSelection([dimension])
            #expect(service.drawingSelection.isEmpty, "the file did not take it, so neither did we")
            #expect(service.sidecarRevision == 0)

            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: dir.path)
            service.setDrawingSelection([dimension])
            #expect(service.drawingSelection == [dimension])
            let document = try readDocument(in: dir)
            #expect(document.revision == 1)
            #expect(document.selections.compactMap(\.entity) == ["2C1"])
        }

        // MARK: - The agent side

        /// Drives one request through the real apply path and returns its recorded outcome.
        @MainActor
        private func run(
            _ request: HighlightRequestPayload, service: CADViewportService, in dir: URL
        ) throws -> HandledOutcome {
            let requestURL = CADViewportService.highlightRequestsDirectory(in: dir)
                .appendingPathComponent("\(request.id).json")
            try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)
            service.processHighlightRequests()
            let handledURL = CADViewportService.handledDirectory(in: dir)
                .appendingPathComponent("\(request.id).json")
            let data = try #require(FileManager.default.contents(atPath: handledURL.path))
            return try JSONDecoder().decode(HandledOutcome.self, from: data)
        }

        @MainActor
        @Test("A drawing pick supersedes a highlight request composed before it")
        func drawingPickSupersedesAnOlderRequest() throws {
            let box = try #require(Shape.box(width: 10, height: 8, depth: 6))
            let service = CADViewportService()
            service.load(box, id: "box")

            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            try service.startSelectionSidecar(directory: dir)
            defer { service.stopSelectionSidecar() }

            let composedAgainst = try readDocument(in: dir).revision
            service.setDrawingSelection([dimension])

            let outcome = try run(
                HighlightRequestPayload(
                    id: "stale", bodyId: "box", kind: "face", index: 0, scheme: "replace",
                    question: nil, ifRevision: composedAgainst),
                service: service, in: dir)
            #expect(outcome.outcome == "superseded")
            #expect(service.agentAttention == nil)
        }

        @MainActor
        @Test("A highlight request for a drawing entity is rejected with its own reason")
        func drawingEntityIsNotAHighlightTarget() throws {
            let box = try #require(Shape.box(width: 10, height: 8, depth: 6))
            let service = CADViewportService()
            service.load(box, id: "box")

            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            try service.startSelectionSidecar(directory: dir)
            defer { service.stopSelectionSidecar() }
            service.setDrawingSelection([dimension])
            let revision = service.sidecarRevision

            // A case that is not a scene body must not be reported as a missing body: the
            // requester would go looking for a body that was never the point.
            let missing = try run(
                HighlightRequestPayload(
                    id: "d1", bodyId: "6575N383", kind: "drawing-entity", index: 0,
                    scheme: "replace", question: nil, target: "selection"),
                service: service, in: dir)
            #expect(missing.outcome == "rejected")
            #expect(missing.reason?.contains("not a highlight target") == true)

            // A case sharing a loaded body's name is still not a highlight target.
            let shared = try run(
                HighlightRequestPayload(
                    id: "d2", bodyId: "box", kind: "drawing-entity", index: 0,
                    scheme: "replace", question: nil, target: "selection"),
                service: service, in: dir)
            #expect(shared.outcome == "rejected")
            #expect(shared.reason?.contains("not a highlight target") == true)

            #expect(service.selection.isEmpty)
            #expect(service.agentAttention == nil)
            #expect(
                service.drawingSelection == [dimension], "an agent never changes a drawing pick")
            #expect(service.sidecarRevision == revision)
        }

        @MainActor
        @Test("A drawing-entity request meets the usual checks first, then its own rejection")
        func drawingEntityRequestFollowsTheUsualCheckOrder() throws {
            let service = CADViewportService()
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            try service.startSelectionSidecar(directory: dir)
            defer { service.stopSelectionSidecar() }
            service.setDrawingSelection([dimension])

            let stale = try run(
                HighlightRequestPayload(
                    id: "o1", bodyId: "6575N383", kind: "drawing-entity", index: 0,
                    scheme: "replace", question: nil, ifRevision: 0),
                service: service, in: dir)
            #expect(stale.outcome == "superseded")

            let target = try run(
                HighlightRequestPayload(
                    id: "o2", bodyId: "6575N383", kind: "drawing-entity", index: 0,
                    scheme: "replace", question: nil, target: "bogus"),
                service: service, in: dir)
            #expect(target.outcome == "rejected")
            #expect(target.reason?.contains("unknown target") == true)

            let asked = try run(
                HighlightRequestPayload(
                    id: "o3", bodyId: "6575N383", kind: "drawing-entity", index: 0,
                    scheme: "replace", question: "Is this the one?"),
                service: service, in: dir)
            #expect(asked.outcome == "rejected")
            #expect(asked.reason?.contains("not a highlight target") == true)
            #expect(service.pendingEscalation == nil)
        }
    }

#endif
