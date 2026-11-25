import Combine
import Foundation
import OCCTSwift
import OCCTSwiftAIS
import OCCTSwiftTools
import OCCTSwiftViewport
import Testing
import simd

@testable import OCCTSwiftCADKit

/// Coverage for OCCTSwiftInteraction#81: a host that knows a face, edge or vertex by body id, kind
/// and ordinal (from its own model, not from a pick) selects it as a person's pick would be
/// selected, several at once and as one change.
///
/// Every sub-shape is named by where it is (`CapRecutSelectionTests.Box`), and an address's
/// ordinal is looked up by that geometry in `loadedIdentity(ofBody:)`, never written down, so a
/// test cannot pass by agreeing with itself about a number. The body is the 4x4x4 box centred on
/// the origin that `CapRecutSelectionTests` cuts, with the same cap at X = 0 keeping the +X half.
@Suite("Selecting sub-shapes known by body, kind and ordinal")
struct KnownSubShapeSelectionTests {
    typealias Box = CapRecutSelectionTests.Box
    typealias Faces = CapRecutSelectionTests.Faces
    typealias Edges = CapRecutSelectionTests.Edges
    typealias Vertices = CapRecutSelectionTests.Vertices
    typealias Kind = SubShapeAddress.Kind

    /// One sub-shape of each kind on the uncut box, none of which a cap at X = 0 removes.
    static func uncutSample(_ kind: Kind) -> Box {
        switch kind {
        case .face: Faces.plusY
        case .edge: Edges.alongX
        case .vertex: Vertices.kept
        }
    }

    /// What `uncutSample(kind)` is drawn as while the cap at X = 0 is on.
    static func cutSample(_ kind: Kind) -> Box {
        switch kind {
        case .face: Faces.plusYFromZero
        case .edge: Edges.alongXFromZero
        case .vertex: Vertices.kept
        }
    }

    // MARK: - Helpers

    /// The address of the sub-shape of `kind` at `box` on body `id`, found in the body's table as
    /// loaded.
    @MainActor
    static func address(
        _ kind: Kind, at box: Box, onBody id: String, in service: CADViewportService
    ) -> SubShapeAddress? {
        guard let identity = service.loadedIdentity(ofBody: id),
            let ordinal = shapes(kind, of: identity).firstIndex(where: {
                $0.map(box.matches) == true
            })
        else { return nil }
        return SubShapeAddress(bodyID: id, kind: kind, ordinal: ordinal)
    }

    static func shapes(_ kind: Kind, of identity: ShapeIdentity) -> [Shape?] {
        switch kind {
        case .face: identity.faces.shapes
        case .edge: identity.edges.shapes
        case .vertex: identity.vertices.shapes.map(Optional.some)
        }
    }

    static func uid(at address: SubShapeAddress, in identity: ShapeIdentity)
        -> BRepGraph.GraphUID?
    {
        switch address.kind {
        case .face: identity.faces.uid(forOrdinal: address.ordinal)
        case .edge: identity.edges.uid(forOrdinal: address.ordinal)
        case .vertex: identity.vertices.uid(forOrdinal: address.ordinal)
        }
    }

    static func kind(of entity: PickedEntity) -> Kind {
        switch entity {
        case .face: .face
        case .edge: .edge
        case .vertex: .vertex
        }
    }

    /// Expects `entities` to name exactly the sub-shapes `expected` lists, by body, kind and
    /// geometry, each through the ordinal and uid the body's current table gives it.
    @MainActor
    static func expectEntities(
        _ entities: [PickedEntity], in service: CADViewportService,
        name expected: [(bodyID: String, kind: Kind, box: Box)], _ step: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        var unmatched = expected
        for entity in entities {
            let index = unmatched.firstIndex {
                $0.bodyID == entity.bodyID && $0.kind == kind(of: entity)
                    && $0.box.matches(entity.ref.shape)
            }
            guard let index else {
                let place = entity.ref.shape.bounds.map { "\($0.min)...\($0.max)" } ?? "nowhere"
                Issue.record(
                    """
                    \(step): \(kind(of: entity)) \(entity.ref.ordinal) of \(entity.bodyID) at \
                    \(place) was not expected
                    """,
                    sourceLocation: sourceLocation)
                continue
            }
            unmatched.remove(at: index)
            guard let current = service.currentRef(of: entity) else {
                Issue.record(
                    "\(step): \(entity.bodyID) has no \(kind(of: entity)) \(entity.ref.ordinal)",
                    sourceLocation: sourceLocation)
                continue
            }
            #expect(
                current.shape.isSame(as: entity.ref.shape),
                "\(step): the ordinal names the selected sub-shape in the body's current table",
                sourceLocation: sourceLocation)
            #expect(
                current.uid != nil && entity.ref.uid == current.uid,
                "\(step): the uid is the current graph's, the one the table gives the ordinal",
                sourceLocation: sourceLocation)
        }
        #expect(
            unmatched.isEmpty,
            "\(step): \(unmatched.map { "\($0.kind) at \($0.box) of \($0.bodyID)" }) not named",
            sourceLocation: sourceLocation)
    }

    /// Expects the highlight of each kind to light exactly what the body draws for the selected
    /// sub-shapes of that kind.
    @MainActor
    static func expectHighlight(
        _ service: CADViewportService, _ step: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for kind in Kind.allCases {
            let selected = service.selection.filter { Self.kind(of: $0) == kind }
            let drawn = selected.flatMap(service.drawnPoints(of:))
            let lit: [SIMD3<Double>]
            switch kind {
            case .face: lit = service.highlightedFaceCentroids
            case .edge: lit = HighlightGeometry.worldPoints(of: service.selectionHighlight("edge"))
            case .vertex:
                lit = HighlightGeometry.worldPoints(of: service.selectionHighlight("vertex"))
            }
            let (missing, extra) = HighlightGeometry.unpaired(drawn, lit)
            #expect(
                (selected.isEmpty || !drawn.isEmpty) && missing.isEmpty && extra.isEmpty,
                "\(step): the \(kind) highlight lights what the body draws for the selection",
                sourceLocation: sourceLocation)
        }
    }

    /// Expects `ours` to carry every field `pick` carries.
    static func expectSameEnrichment(
        _ ours: PickedEntity, _ pick: PickedEntity,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(ours.bodyID == pick.bodyID, sourceLocation: sourceLocation)
        #expect(ours.ref.ordinal == pick.ref.ordinal, sourceLocation: sourceLocation)
        #expect(ours.ref.uid != nil && ours.ref.uid == pick.ref.uid, sourceLocation: sourceLocation)
        #expect(ours.ref.shape.isSame(as: pick.ref.shape), sourceLocation: sourceLocation)
        switch (ours, pick) {
        case (.face(let a), .face(let b)):
            #expect(a.description == b.description, sourceLocation: sourceLocation)
            #expect(a.bounds == b.bounds, sourceLocation: sourceLocation)
            #expect(a.area == b.area, sourceLocation: sourceLocation)
            #expect(a.zLevel == b.zLevel, sourceLocation: sourceLocation)
            #expect(a.isHorizontal == b.isHorizontal, sourceLocation: sourceLocation)
            #expect(a.isVertical == b.isVertical, sourceLocation: sourceLocation)
            #expect(a.scalarValue == b.scalarValue, sourceLocation: sourceLocation)
        case (.edge(let a), .edge(let b)):
            #expect(a.description == b.description, sourceLocation: sourceLocation)
            #expect(a.curveType == b.curveType, sourceLocation: sourceLocation)
            #expect(a.length == b.length, sourceLocation: sourceLocation)
            #expect(a.startPoint == b.startPoint, sourceLocation: sourceLocation)
            #expect(a.endPoint == b.endPoint, sourceLocation: sourceLocation)
        case (.vertex(let a), .vertex(let b)):
            #expect(a.description == b.description, sourceLocation: sourceLocation)
            #expect(a.position == b.position, sourceLocation: sourceLocation)
        default:
            Issue.record("\(ours) and \(pick) are different kinds", sourceLocation: sourceLocation)
        }
    }

    // MARK: - Each kind

    @MainActor
    @Test(
        "A face, edge or vertex selected by address is selected as its pick would be",
        arguments: Kind.allCases)
    func selectsByAddress(_ kind: Kind) throws {
        let service = try #require(CADViewportService.withBoxes(ids: ["ref"]))
        let box = Self.uncutSample(kind)
        let address = try #require(Self.address(kind, at: box, onBody: "ref", in: service))
        let loaded = try #require(service.loadedIdentity(ofBody: "ref"))

        let unresolved = service.select([address])

        #expect(unresolved.isEmpty)
        Self.expectEntities(
            service.selection, in: service, name: [("ref", kind, box)], "selected")
        let entity = try #require(service.selection.first)
        #expect(entity.ref.ordinal == address.ordinal, "uncut, the ordinal is the address's own")
        #expect(
            entity.ref.uid != nil && entity.ref.uid == Self.uid(at: address, in: loaded),
            "uncut, the uid is the load's graph's")
        Self.expectHighlight(service, "selected")
    }

    /// The enrichment is the pick's own, under a cap too, where the address names the uncut face
    /// and the pick lands on the piece of it the cap keeps.
    @MainActor
    @Test(
        "pickedEntities(at:) gives every field a viewport pick of the same sub-shape gives",
        arguments: Kind.allCases, [false, true])
    func enrichmentMatchesAPick(_ kind: Kind, capped: Bool) throws {
        let service = try #require(CADViewportService.withBoxes(ids: ["ref"]))
        service.selectionModes = [.face, .edge, .vertex]
        let address = try #require(
            Self.address(kind, at: Self.uncutSample(kind), onBody: "ref", in: service))
        if capped { service.addHalfCap() }
        let drawn = capped ? Self.cutSample(kind) : Self.uncutSample(kind)

        let ours = service.pickedEntities(at: address)
        let pick = try #require(
            service.pick(kind, at: drawn, onBody: "ref"), "sanity check: a pick lands")

        #expect(ours.count == 1, "one entity, the sub-shape or the one piece the cap keeps")
        guard let ours = ours.first else { return }
        Self.expectSameEnrichment(ours, pick)
        #expect(drawn.matches(ours.ref.shape), "the entity is the sub-shape as drawn")
    }

    // MARK: - Several at once

    @MainActor
    @Test("Addresses on several bodies are selected together")
    func selectsAcrossBodies() throws {
        let service = try #require(CADViewportService.withBoxes(ids: ["ref"]))
        let box = try #require(Shape.box(width: 4, height: 4, depth: 4))
        service.load(box, id: "far", transform: [1, 0, 0, 0, 1, 0, 0, 0, 1, 10, 0, 0])
        let farFace = Box(SIMD3(8, 2, -2), SIMD3(12, 2, 2))
        let farVertex = Box(point: SIMD3(12, 2, 2))
        let wanted: [(bodyID: String, kind: Kind, box: Box)] = [
            ("ref", .face, Faces.plusX), ("far", .face, farFace), ("ref", .edge, Edges.alongX),
            ("far", .vertex, farVertex),
        ]
        let addresses = try wanted.map {
            try #require(Self.address($0.kind, at: $0.box, onBody: $0.bodyID, in: service))
        }

        #expect(service.select(addresses).isEmpty)

        Self.expectEntities(service.selection, in: service, name: wanted, "four on two bodies")
        Self.expectHighlight(service, "four on two bodies")
    }

    /// `loadFile(from:id:)` records a loaded identity for each body of a multibody file, and an
    /// address names one body of it.
    @MainActor
    @Test("Each body of a multibody file has its loaded identity, and addresses select across them")
    func multibodyFileBodies() async throws {
        let service = CADViewportService()
        let url = try #require(
            Bundle.module.url(
                forResource: "multibody-three-solids", withExtension: "brep",
                subdirectory: "Fixtures"))
        _ = try await service.loadFile(from: url, id: "asm")
        let bodyIDs = try #require(service.entities["asm"]?.bodyIDs)
        try #require(bodyIDs == ["asm-0", "asm-1", "asm-2"])
        for bodyID in bodyIDs {
            let loaded = service.loadedIdentity(ofBody: bodyID)
            #expect(
                loaded?.shape === service.bodyShapes[bodyID],
                "\(bodyID): the loaded identity is the body's own")
        }

        // asm-0 is the 4x4x4 box at the origin, asm-2 the 6x6x6 box at X = 57...63.
        let wanted: [(bodyID: String, kind: Kind, box: Box)] = [
            ("asm-0", .face, Faces.plusY), ("asm-2", .vertex, Box(point: SIMD3(63, 3, 3))),
        ]
        let addresses = try wanted.map {
            try #require(Self.address($0.kind, at: $0.box, onBody: $0.bodyID, in: service))
        }
        #expect(service.select(addresses).isEmpty)
        Self.expectEntities(service.selection, in: service, name: wanted, "two bodies of one file")
    }

    enum EntryPoint: CaseIterable, Sendable, CustomTestStringConvertible {
        case entities
        case addresses

        var testDescription: String {
            switch self {
            case .entities: "select(_ entities:scheme:)"
            case .addresses: "select(_ addresses:scheme:)"
            }
        }
    }

    /// The acceptance of #81: a ledger row with four references selects them as one change.
    @MainActor
    @Test(
        "Selecting four at once publishes one change, cuts the highlight once and writes selection.json once",
        arguments: EntryPoint.allCases)
    func onePublication(_ entryPoint: EntryPoint) throws {
        // What one single-entity selection costs in viewport rebuilds, the yardstick below.
        let yardstick = try #require(CADViewportService.withBoxes(ids: ["ref"]))
        let one = try #require(
            Self.address(.face, at: Faces.plusX, onBody: "ref", in: yardstick))
        let single = try #require(yardstick.pickedEntities(at: one).first)
        var rebuildsForOne = 0
        let yardstickSink = yardstick.interactiveContext.$bodies.dropFirst().sink { _ in
            rebuildsForOne += 1
        }
        yardstick.select(single)
        yardstickSink.cancel()
        try #require(rebuildsForOne > 0, "sanity check: a selection rebuilds the viewport")

        let service = try #require(CADViewportService.withBoxes(ids: ["ref"]))
        let wanted: [(bodyID: String, kind: Kind, box: Box)] = [
            ("ref", .face, Faces.plusX), ("ref", .face, Faces.plusY), ("ref", .edge, Edges.alongX),
            ("ref", .vertex, Vertices.kept),
        ]
        let addresses = try wanted.map {
            try #require(Self.address($0.kind, at: $0.box, onBody: $0.bodyID, in: service))
        }
        #if os(macOS)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "known-subshape-selection-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            try service.startSelectionSidecar(directory: dir)
            defer { service.stopSelectionSidecar() }
            let revisionBefore = service.sidecarRevision
        #endif
        var changes: [SelectionChange] = []
        let changeSink = service.selectionChanges.sink { changes.append($0) }
        defer { changeSink.cancel() }
        var rebuilds = 0
        let rebuildSink = service.interactiveContext.$bodies.dropFirst().sink { _ in rebuilds += 1 }
        defer { rebuildSink.cancel() }

        switch entryPoint {
        case .entities:
            service.select(addresses.flatMap(service.pickedEntities(at:)), scheme: .replace)
        case .addresses:
            service.select(addresses, scheme: .replace)
        }

        Self.expectEntities(service.selection, in: service, name: wanted, "four selected")
        #expect(changes.count == 1, "one change is published, not one per sub-shape")
        #expect(changes.first?.source == .programmatic)
        #expect(changes.first?.current == service.selection)
        #expect(changes.first?.previous == [])
        #expect(
            rebuilds == rebuildsForOne,
            "the highlight is cut and published once, as for one sub-shape")
        Self.expectHighlight(service, "four selected")
        #if os(macOS)
            #expect(service.sidecarRevision == revisionBefore + 1, "selection.json is written once")
            let data = try #require(
                FileManager.default.contents(
                    atPath: dir.appendingPathComponent("selection.json").path))
            let document = try JSONDecoder().decode(SelectionSidecarDocument.self, from: data)
            #expect(document.revision == revisionBefore + 1)
            #expect(
                document.selections.map(\.index).sorted()
                    == service.selection.map(\.ref.ordinal).sorted()
                    && document.selections.count == 4,
                "the one write holds all four")
        #endif
    }

    // MARK: - Schemes

    @MainActor
    @Test("Add, remove and xor apply to every address at once, and a repeated address counts once")
    func otherSchemes() throws {
        let service = try #require(CADViewportService.withBoxes(ids: ["ref"]))
        func at(_ box: Box) throws -> SubShapeAddress {
            try #require(Self.address(.face, at: box, onBody: "ref", in: service))
        }
        let (plusX, plusY, plusZ) = (try at(Faces.plusX), try at(Faces.plusY), try at(Faces.plusZ))
        let minusX = try at(Faces.minusX)
        service.select([plusX])
        var changes: [SelectionChange] = []
        let sink = service.selectionChanges.sink { changes.append($0) }
        defer { sink.cancel() }

        service.select([plusY, plusZ], scheme: .add)
        Self.expectEntities(
            service.selection, in: service,
            name: [
                ("ref", .face, Faces.plusX), ("ref", .face, Faces.plusY),
                ("ref", .face, Faces.plusZ),
            ],
            "added")

        service.select([plusX, plusY], scheme: .remove)
        Self.expectEntities(
            service.selection, in: service, name: [("ref", .face, Faces.plusZ)], "removed")

        // +Z is toggled off; -X is listed twice and toggled on once.
        service.select([plusZ, minusX, minusX], scheme: .xor)
        Self.expectEntities(
            service.selection, in: service, name: [("ref", .face, Faces.minusX)], "toggled")

        #expect(changes.count == 3, "one change per call")
        Self.expectHighlight(service, "toggled")
    }

    // MARK: - Invalid input

    @MainActor
    @Test(
        "An address that names nothing is skipped and returned, and the rest are selected as one change"
    )
    func invalidAddressesAreSkipped() throws {
        let service = try #require(CADViewportService.withBoxes(ids: ["ref"]))
        let loaded = try #require(service.loadedIdentity(ofBody: "ref"))
        let face = try #require(Self.address(.face, at: Faces.plusY, onBody: "ref", in: service))
        let edge = try #require(Self.address(.edge, at: Edges.alongX, onBody: "ref", in: service))
        let unknownBody = SubShapeAddress(bodyID: "nope", kind: .face, ordinal: 0)
        let pastTheEnd = SubShapeAddress(
            bodyID: "ref", kind: .vertex, ordinal: loaded.vertices.shapes.count)
        let negative = SubShapeAddress(bodyID: "ref", kind: .edge, ordinal: -1)
        var changes: [SelectionChange] = []
        let sink = service.selectionChanges.sink { changes.append($0) }
        defer { sink.cancel() }

        let unresolved = service.select([unknownBody, face, pastTheEnd, edge, negative])

        #expect(unresolved == [unknownBody, pastTheEnd, negative], "returned in the order given")
        Self.expectEntities(
            service.selection, in: service,
            name: [("ref", .face, Faces.plusY), ("ref", .edge, Edges.alongX)], "the rest")
        #expect(changes.count == 1)
        for address in [unknownBody, pastTheEnd, negative] {
            #expect(service.pickedEntities(at: address).isEmpty, "\(address) names nothing")
        }
    }

    @MainActor
    @Test("With nothing found, replace clears the selection and any other scheme changes nothing")
    func nothingFound() throws {
        let service = try #require(CADViewportService.withBoxes(ids: ["ref"]))
        let face = try #require(Self.address(.face, at: Faces.plusY, onBody: "ref", in: service))
        let unknown = SubShapeAddress(bodyID: "nope", kind: .face, ordinal: 0)
        service.select([face])
        #if os(macOS)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "known-subshape-nothing-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            try service.startSelectionSidecar(directory: dir)
            defer { service.stopSelectionSidecar() }
            let revisionBefore = service.sidecarRevision
        #endif
        var changes: [SelectionChange] = []
        let sink = service.selectionChanges.sink { changes.append($0) }
        defer { sink.cancel() }

        for scheme in [SelectionScheme.add, .remove, .xor] {
            #expect(service.select([unknown], scheme: scheme) == [unknown])
            service.select([PickedEntity](), scheme: scheme)
        }
        #expect(changes.isEmpty, "nothing changed, so nothing is published")
        #if os(macOS)
            #expect(service.sidecarRevision == revisionBefore, "and nothing is written")
        #endif
        Self.expectEntities(
            service.selection, in: service, name: [("ref", .face, Faces.plusY)], "unchanged")

        #expect(service.select([unknown], scheme: .replace) == [unknown])
        #expect(service.selection.isEmpty, "replace with nothing found clears")
        #expect(changes.count == 1)
    }

    // MARK: - While a cap is active

    struct CapCase: Sendable, CustomTestStringConvertible {
        var kind: Kind
        /// The sub-shape as loaded.
        var address: Box
        /// What it is drawn as with the cap at X = 0 on; empty when the cap removed it.
        var drawn: [Box]
        var label: String

        var testDescription: String { "\(kind) \(label)" }

        static let all: [CapCase] = [
            CapCase(
                kind: .face, address: Faces.plusY, drawn: [Faces.plusYFromZero],
                label: "the cut divides"),
            CapCase(
                kind: .face, address: Faces.plusX, drawn: [Faces.plusX],
                label: "the cut leaves alone"),
            CapCase(kind: .face, address: Faces.minusX, drawn: [], label: "the cap removes"),
            CapCase(
                kind: .edge, address: Edges.alongX, drawn: [Edges.alongXFromZero],
                label: "the cut divides"),
            CapCase(kind: .edge, address: Edges.onMinusX, drawn: [], label: "the cap removes"),
            CapCase(
                kind: .vertex, address: Vertices.kept, drawn: [Vertices.kept],
                label: "the cut leaves alone"),
            CapCase(kind: .vertex, address: Vertices.removed, drawn: [], label: "the cap removes"),
        ]
    }

    /// The address names the box as loaded, read before the cap; the selection names it as drawn.
    @MainActor
    @Test(
        "While a cap is active an address selects what the cap left of its sub-shape",
        arguments: CapCase.all)
    func whileCapActive(_ testCase: CapCase) throws {
        let service = try #require(CADViewportService.withBoxes(ids: ["ref"]))
        let address = try #require(
            Self.address(testCase.kind, at: testCase.address, onBody: "ref", in: service))
        service.addHalfCap()
        try #require(service.capOrigins["ref"] != nil, "sanity check: the cap cut the box")

        let unresolved = service.select([address])

        #expect(unresolved == (testCase.drawn.isEmpty ? [address] : []))
        Self.expectEntities(
            service.selection, in: service,
            name: testCase.drawn.map { ("ref", testCase.kind, $0) }, "capped")
        Self.expectHighlight(service, "capped")
    }

    @MainActor
    @Test("A cap leaves loadedIdentity(ofBody:) as loaded, and a reload or removal replaces it")
    func loadedIdentityAcrossRecut() throws {
        let service = CADViewportService()
        let box = try #require(Shape.box(width: 4, height: 4, depth: 4))
        let graph = try #require(BRepGraph(shape: box))
        service.load(box, id: "ref", graph: graph)
        let before = try #require(service.loadedIdentity(ofBody: "ref"))
        #expect(before.shape === box && before.graph === graph, "the host's shape and graph")

        service.addHalfCap()
        let during = try #require(service.loadedIdentity(ofBody: "ref"))
        #expect(during.shape === box && during.graph === graph, "unchanged by the cap")
        for kind in Kind.allCases {
            let (old, new) = (Self.shapes(kind, of: before), Self.shapes(kind, of: during))
            let same = zip(old, new).allSatisfy { pair in
                switch pair {
                case (let a?, let b?): a.isSame(as: b)
                case (nil, nil): true
                default: false
                }
            }
            #expect(
                old.count == new.count && same, "\(kind): the same sub-shapes at the same ordinals")
        }
        let plusY = try #require(Self.address(.face, at: Faces.plusY, onBody: "ref", in: service))
        let uncutPlusY = try #require(before.faces.shape(forOrdinal: plusY.ordinal))
        #expect(
            service.faceIdentity["ref"]?.shapes.contains { $0?.isSame(as: uncutPlusY) == true }
                == false,
            "sanity check: the body as drawn no longer has the uncut +Y face")

        service.clippingPlanes = []
        #expect(service.loadedIdentity(ofBody: "ref")?.graph === graph, "unchanged by the restore")

        let other = try #require(Shape.box(width: 2, height: 2, depth: 2))
        service.load(other, id: "ref")
        #expect(service.loadedIdentity(ofBody: "ref")?.shape === other, "a reload replaces it")
        service.remove(id: "ref")
        #expect(service.loadedIdentity(ofBody: "ref") == nil, "a removal drops it")
        service.load(other, id: "again")
        service.removeAll()
        #expect(service.loadedIdentity(ofBody: "again") == nil, "removeAll drops it")
        #expect(service.loadedIdentity(ofBody: "nope") == nil)
    }

    /// A selection made by address is an ordinary selection, so it follows a later recut as a pick
    /// does (#77).
    @MainActor
    @Test("A face selected by address under a cap becomes the whole face when the cap goes")
    func followsLaterRecut() throws {
        let service = try #require(CADViewportService.withBoxes(ids: ["ref"]))
        let address = try #require(
            Self.address(.face, at: Faces.plusY, onBody: "ref", in: service))
        let planeID = service.addHalfCap()
        service.select([address])
        Self.expectEntities(
            service.selection, in: service, name: [("ref", .face, Faces.plusYFromZero)], "capped")

        service.removeClippingPlane(id: planeID)

        Self.expectEntities(
            service.selection, in: service, name: [("ref", .face, Faces.plusY)], "cap removed")
        #expect(
            service.selection.first?.ref.ordinal == address.ordinal, "back at its loaded ordinal")
        Self.expectHighlight(service, "cap removed")
    }
}

@MainActor
extension CADViewportService {
    /// The ref the current table holds at the ordinal of `entity`, or `nil` if it holds none.
    fileprivate func currentRef(of entity: PickedEntity) -> SubShapeRef? {
        let ordinal = entity.ref.ordinal
        let shape: Shape?
        let uid: BRepGraph.GraphUID?
        switch entity {
        case .face:
            shape = faceIdentity[entity.bodyID]?.shape(forOrdinal: ordinal)
            uid = faceIdentity[entity.bodyID]?.uid(forOrdinal: ordinal)
        case .edge:
            shape = edgeIdentity[entity.bodyID]?.shape(forOrdinal: ordinal)
            uid = edgeIdentity[entity.bodyID]?.uid(forOrdinal: ordinal)
        case .vertex:
            shape = vertexIdentity[entity.bodyID]?.shape(forOrdinal: ordinal)
            uid = vertexIdentity[entity.bodyID]?.uid(forOrdinal: ordinal)
        }
        return shape.map { SubShapeRef(shape: $0, uid: uid, ordinal: ordinal) }
    }

    /// A viewport pick of the sub-shape of `kind` drawn at `box` on body `id`, through the pick
    /// resolvers, or `nil` if the body draws nothing of it.
    fileprivate func pick(
        _ kind: SubShapeAddress.Kind, at box: CapRecutSelectionTests.Box, onBody id: String
    ) -> PickedEntity? {
        guard let body = modelBody(id) else { return nil }
        switch kind {
        case .face:
            guard let table = faceIdentity[id],
                let shape = table.shapes.lazy.compactMap({ $0 }).first(where: box.matches),
                let triangle = HighlightGeometry.triangles(onFace: shape, of: body).first
            else { return nil }
            return resolveFacePick(bodyID: id, triangleIndex: triangle).map(PickedEntity.face)
        case .edge:
            guard let table = edgeIdentity[id],
                let ordinal = table.shapes.firstIndex(where: { $0.map(box.matches) == true }),
                let segment = body.edgeIndices.firstIndex(of: Int32(ordinal))
            else { return nil }
            return resolveEdgePick(bodyID: id, segmentIndex: segment).map(PickedEntity.edge)
        case .vertex:
            guard let table = vertexIdentity[id],
                let ordinal = table.shapes.firstIndex(where: box.matches),
                let point = body.vertices.indices.first(where: { point in
                    (point < body.vertexIndices.count ? Int(body.vertexIndices[point]) : point)
                        == ordinal
                })
            else { return nil }
            return resolveVertexPick(bodyID: id, pointIndex: point).map(PickedEntity.vertex)
        }
    }
}
