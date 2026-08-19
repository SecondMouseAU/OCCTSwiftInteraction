import OCCTSwift
import OCCTSwiftAIS
import OCCTSwiftTools
import OCCTSwiftViewport
import Testing
import simd

@testable import OCCTSwiftCADKit

/// One selection store, not two synchronised ones.
///
/// Phase 3 of ecosystem#43 (OCCTSwiftInteraction#3): `CADViewportService` stopped keeping a
/// selection alongside the `InteractiveContext` it already owned, and started driving that one
/// instead. These tests hold down the property that makes it one system rather than two
/// synchronised ones: there is a single store, and every route into it is visible from both
/// sides.
@Suite("Shared selection state")
struct SharedSelectionTests {

    @MainActor
    private func loadedService(id: String = "box") -> (CADViewportService, PickedEntity)? {
        guard let box = Shape.box(width: 10, height: 8, depth: 6) else { return nil }
        let service = CADViewportService()
        service.selectionModes = [.face, .edge, .vertex]
        service.load(box, id: id)
        guard let pick = service.resolveFacePick(bodyID: id, triangleIndex: 0) else { return nil }
        return (service, .face(pick))
    }

    /// The headline.
    ///
    /// `selectionModes` is not a copy of `interactiveContext.selectionMode`, it IS it.
    /// Before this change the two defaulted to different values in the same service,
    /// which is what "a separate, independent selection system this service does not share
    /// state with" meant in practice.
    @MainActor
    @Test("selectionModes and interactiveContext.selectionMode are one setting, not two")
    func selectionModesIsTheContextsSelectionMode() {
        let service = CADViewportService()

        #expect(service.selectionModes == [.face], "this service's own default wins at init")
        #expect(service.interactiveContext.selectionMode == [.face])

        service.selectionModes = [.face, .edge]
        #expect(service.interactiveContext.selectionMode == [.face, .edge])

        service.interactiveContext.selectionMode = [.vertex, .body]
        #expect(service.selectionModes == [.vertex, .body])
    }

    @MainActor
    @Test("A CADKit selection is the interactive context's selection")
    func selectingThroughTheServiceUpdatesTheContext() {
        guard let (service, entity) = loadedService() else {
            Issue.record("fixture setup failed")
            return
        }

        service.select(entity)

        #expect(service.selection == [entity])
        #expect(service.interactiveContext.selection.count == 1)
        guard let subShape = service.interactiveContext.selection.subshapes.first else {
            Issue.record("the context holds no sub-shape for a selection made through CADKit")
            return
        }
        guard case .face(_, let ref) = subShape else {
            Issue.record("expected a face sub-shape")
            return
        }
        #expect(ref == entity.ref, "same identity, not a re-derived one")
    }

    @MainActor
    @Test("Clearing through the interactive context clears the service's selection")
    func clearingThroughTheContextClearsTheService() {
        guard let (service, entity) = loadedService() else {
            Issue.record("fixture setup failed")
            return
        }
        service.select(entity)
        #expect(!service.selection.isEmpty)

        service.interactiveContext.clearSelection()

        #expect(
            service.selection.isEmpty,
            "the service projects the context's selection, so clearing there clears here")
        #expect(
            !service.interactiveContext.bodies.contains { $0.id == "selection_highlight_face" },
            "the highlight body must go with it")
    }

    /// Selecting through the context directly (an app's own code, or area selection) reaches
    /// the service's projection, enriched on demand rather than only when the service resolved
    /// the pick itself.
    @MainActor
    @Test("Selecting through the interactive context enriches into the service's selection")
    func selectingThroughTheContextEnrichesOnDemand() {
        guard let (service, entity) = loadedService() else {
            Issue.record("fixture setup failed")
            return
        }
        service.select(entity)
        guard let subShape = service.interactiveContext.selection.subshapes.first else {
            Issue.record("no sub-shape to re-select")
            return
        }
        service.interactiveContext.clearSelection()
        #expect(service.selection.isEmpty)

        // Nothing cached now: this has to go through the on-demand enrichment path.
        service.interactiveContext.select(subShape)

        #expect(service.selection.count == 1)
        guard case .face(let info)? = service.selection.first else {
            Issue.record("expected an enriched face")
            return
        }
        #expect(info.bodyID == "box")
        #expect(info.description.hasSuffix("mm"), "enrichment ran, not just identity")
        #expect(info.area > 0)
    }

    /// Changing the mode set clears the selection.
    ///
    /// That is the interactive context's documented behaviour for `selectionMode`, and now
    /// that this service shares that state it inherits the behaviour too.
    @MainActor
    @Test("Changing selectionModes clears the selection")
    func changingSelectionModesClearsTheSelection() {
        guard let (service, entity) = loadedService() else {
            Issue.record("fixture setup failed")
            return
        }
        service.select(entity)
        #expect(!service.selection.isEmpty)

        service.selectionModes = [.edge]

        #expect(service.selection.isEmpty)
    }

    /// The order guarantee that replaced insertion order when the store became a `Set`.
    @MainActor
    @Test("selection is ordered by body id, then kind, then ordinal")
    func selectionIsDeterministicallyOrdered() {
        guard let boxA = Shape.box(width: 10, height: 8, depth: 6),
            let boxB = Shape.box(width: 4, height: 4, depth: 4)
        else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.selectionModes = [.face, .edge, .vertex]
        service.load(boxA, id: "aaa")
        service.load(boxB, id: "zzz")

        guard let faceA = service.resolveFacePick(bodyID: "aaa", triangleIndex: 0),
            let edgeA = service.resolveEdgePick(bodyID: "aaa", segmentIndex: 0),
            let faceZ = service.resolveFacePick(bodyID: "zzz", triangleIndex: 0)
        else {
            Issue.record("resolve*Pick returned nil")
            return
        }

        // Selected in an order that disagrees with the expected one on every axis.
        service.select(.face(faceZ))
        service.select(.edge(edgeA), scheme: .add)
        service.select(.face(faceA), scheme: .add)

        #expect(
            service.selection == [.face(faceA), .edge(edgeA), .face(faceZ)],
            "body id first (aaa before zzz), then kind (face before edge)")
    }

    /// A pick on a body the interactive context displays itself belongs to that context.
    ///
    /// The service must not treat "I could not resolve that" as "deselect", or one shared
    /// selection would mean an AIS-displayed object could never stay selected.
    @MainActor
    @Test("A pick on an AIS-displayed body does not clear the shared selection")
    func pickOnAnAISBodyDoesNotClearTheSelection() {
        guard let box = Shape.box(width: 10, height: 8, depth: 6),
            let stock = Shape.box(width: 20, height: 20, depth: 20)
        else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(box, id: "part")
        let stockObject = service.interactiveContext.display(stock)
        // The one body in the rendered array that the context displays as its own object; the
        // model body belongs to the service.
        guard
            let stockBodyID = service.interactiveContext.bodies.map(\.id).first(where: {
                service.interactiveContext.displaysBody(withID: $0)
            })
        else {
            Issue.record("the displayed object has no body in the viewport")
            return
        }
        service.interactiveContext.select(.body(stockObject))
        #expect(service.interactiveContext.selection.count == 1)

        // rawValue 0 decodes as object index 0, primitive 0, kind `.face`.
        guard let stockPick = _PickResult(rawValue: 0, indexMap: [0: stockBodyID]) else {
            Issue.record("failed to synthesise a pick result")
            return
        }
        service.handlePick(stockPick)

        #expect(
            service.interactiveContext.selection.count == 1,
            "the service must leave a pick it does not own alone")

        // An empty-space pick still deselects, which is this service's contract, and now
        // applies to the whole shared selection.
        service.handlePick(nil)
        #expect(service.interactiveContext.selection.isEmpty)
    }

    /// `PickedFaceInfo` and its siblings survive as presentation types built from
    /// `SubShapeRef`, so `shape`/`uid`/`faceIndex` have to keep agreeing with the ref they now
    /// forward to, and the deprecated memberwise initialiser has to keep building one.
    @MainActor
    @Test("The picked-info types forward identity to their SubShapeRef")
    func pickedInfoForwardsToItsRef() {
        guard let (service, entity) = loadedService() else {
            Issue.record("fixture setup failed")
            return
        }
        guard case .face(let info) = entity else {
            Issue.record("expected a face")
            return
        }
        #expect(info.faceIndex == info.ref.ordinal)
        #expect(info.uid == info.ref.uid)
        #expect(entity.ref == info.ref)

        let rebuilt = PickedFaceInfo(
            shape: info.shape,
            uid: info.uid,
            faceIndex: info.faceIndex,
            bodyID: info.bodyID,
            isHorizontal: info.isHorizontal,
            isVertical: info.isVertical,
            bounds: info.bounds,
            zLevel: info.zLevel,
            area: info.area,
            description: info.description
        )
        #expect(rebuilt == info, "the source-compatible initialiser mints an equivalent ref")
        _ = service
    }

    /// Two picks with the same ordinal on different bodies and no durable uid must stay
    /// distinct. `SubShapeRef.==` alone cannot tell them apart (it falls back to the ordinal),
    /// which is why `isSamePick` qualifies it with the body.
    @Test("Same ordinal on different bodies is not the same pick")
    func sameOrdinalOnDifferentBodiesIsNotTheSamePick() {
        guard let box = Shape.box(width: 4, height: 4, depth: 4),
            let face = box.subShape(type: .face, index: 0)
        else {
            Issue.record("Shape.box returned nil")
            return
        }
        let ref = SubShapeRef(shape: face, uid: nil, ordinal: 0)
        let bounds = FaceBounds(minX: 0, maxX: 4, minY: 0, maxY: 4)
        func info(_ bodyID: String) -> PickedFaceInfo {
            PickedFaceInfo(
                ref: ref, bodyID: bodyID, isHorizontal: true, isVertical: false,
                bounds: bounds, zLevel: 0, area: 16, description: "test face")
        }
        #expect(info("a") != info("b"))
        #expect(info("a") == info("a"))
    }

    /// The deprecated `SelectionSummary` spelling still resolves, so a consumer is warned
    /// rather than broken.
    ///
    /// Renamed because `OCCTSwiftUXKit` has an unrelated public type of the same name; see the
    /// bakeoff on OCCTSwiftInteraction#3.
    @MainActor
    @Test("SelectionSummary still resolves as the old name for SelectionMeasurements")
    func deprecatedSelectionSummaryAliasResolves() {
        guard let (service, entity) = loadedService() else {
            Issue.record("fixture setup failed")
            return
        }
        service.select(entity)
        // Deliberately spelled with the deprecated name: the point of the test is that it
        // still names the same type, so the warning here is the expected outcome.
        guard let measurements: SelectionSummary = service.selectionMeasurements else {
            Issue.record("expected measurements for a one-face selection")
            return
        }
        #expect(measurements.faceCount == 1)
        #expect(measurements == service.selectionMeasurements)
    }
}
