import Testing
import simd
import OCCTSwift
import OCCTSwiftViewport
import OCCTSwiftTools
@testable import OCCTSwiftCADKit

@Suite("Smoke")
struct SmokeTests {
    @MainActor
    @Test("interactiveContext shares the service viewport, and CADKit/AIS bodies coexist on rebuild")
    func interactiveContextMergeProtocol() {
        let service = CADViewportService()

        #expect(service.interactiveContext.viewport === service.controller)

        let aisHandle = _ViewportBody(
            id: "ais.handle.x",
            vertexData: [0, 0, 0, 1, 0, 0],
            indices: [0],
            edges: [],
            color: SIMD4<Float>(1, 0, 0, 1)
        )
        service.interactiveContext.bodies.append(aisHandle)

        let stock = _ViewportBody(
            id: "stock.box",
            vertexData: [0, 0, 0, 0, 1, 0],
            indices: [0],
            edges: [],
            color: SIMD4<Float>(0.5, 0.5, 0.5, 0.5)
        )
        service.setOverlay(id: "stock", bodies: [stock])

        #expect(service.interactiveContext.bodies.contains { $0.id == "ais.handle.x" })
        #expect(service.interactiveContext.bodies.contains { $0.id == "stock.box" })

        service.clearOverlay(id: "stock")

        #expect(service.interactiveContext.bodies.contains { $0.id == "ais.handle.x" })
        #expect(!service.interactiveContext.bodies.contains { $0.id == "stock.box" })
    }

    @Test("PickedFaceInfo round-trips through equality")
    func pickedFaceInfoEquality() {
        guard let box = Shape.box(width: 10, height: 5, depth: 3) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let bounds = FaceBounds(minX: 0, maxX: 10, minY: 0, maxY: 5)
        let info = PickedFaceInfo(
            shape: box,
            uid: nil,
            faceIndex: 3,
            bodyID: "model",
            isHorizontal: true,
            isVertical: false,
            bounds: bounds,
            zLevel: 12.5,
            area: 50,
            description: "Horizontal face at Z=12.5, 10.0x5.0mm"
        )
        #expect(info == info)
        #expect(bounds.width == 10)
        #expect(bounds.height == 5)
    }

    /// Regression for #25: a face shared between two shells must resolve to the same
    /// durable `GraphUID` from both shells' picks, even though each shell contributes its
    /// own copy of the face to the non-deduplicating `faceIndex` ordinal (0 and 3 here,
    /// mirroring the fixture in OCCTSwiftTools' `FaceIdentityTableTests`). Re-deriving the
    /// face via `loadedShape.faces()[faceIndex]` alone has no way to know these two
    /// ordinals name the same underlying `TopoDS_Face` — only the `uid` carries that.
    @MainActor
    @Test("Durable identity: a face shared between two shells resolves to the same GraphUID from both picks")
    func sharedFaceBetweenShellsResolvesToSameUID() {
        guard let box = Shape.box(width: 10, height: 10, depth: 10) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let boxFaces = box.subShapes(ofType: .face)
        #expect(boxFaces.count == 6)
        let sharedFace = boxFaces[0]

        guard let shellA = Shape.shellFromFaces([sharedFace, boxFaces[1], boxFaces[2]]),
              let shellB = Shape.shellFromFaces([sharedFace, boxFaces[3], boxFaces[4], boxFaces[5]]),
              let compound = Shape.compound([shellA, shellB]) else {
            Issue.record("failed to build the shared-face compound fixture")
            return
        }
        #expect(compound.faces().count == 7)
        #expect(compound.subShapes(ofType: .face).count == 6)

        // Independently learn the triangle -> faceIndex mapping the mesher assigns, so we
        // can pick triangles landing on the shared face's two copies (ordinals 0 and 3)
        // without reaching into CADViewportService's private metadata.
        let (_, referenceMeta, _) = CADFileLoader.shapeToBodyMetadataAndIdentity(
            compound, id: "shared", color: SIMD4<Float>(1, 1, 1, 1)
        )
        guard let referenceMeta else {
            Issue.record("shapeToBodyMetadataAndIdentity returned nil for the shared-face compound")
            return
        }
        guard let triForOrdinal0 = referenceMeta.faceIndices.firstIndex(of: 0),
              let triForOrdinal1 = referenceMeta.faceIndices.firstIndex(of: 1),
              let triForOrdinal3 = referenceMeta.faceIndices.firstIndex(of: 3) else {
            Issue.record("expected triangles landing on ordinals 0, 1 and 3")
            return
        }

        let service = CADViewportService()
        service.loadShape(compound, id: "shared")

        guard let pickA = service.resolveFacePick(bodyID: "shared", triangleIndex: triForOrdinal0) else {
            Issue.record("resolveFacePick returned nil for ordinal 0's triangle")
            return
        }
        guard let pickB = service.resolveFacePick(bodyID: "shared", triangleIndex: triForOrdinal3) else {
            Issue.record("resolveFacePick returned nil for ordinal 3's triangle")
            return
        }

        #expect(pickA.faceIndex == 0)
        #expect(pickB.faceIndex == 3)
        #expect(pickA.faceIndex != pickB.faceIndex)

        guard let uidA = pickA.uid, let uidB = pickB.uid else {
            Issue.record("expected both shared-face picks to carry a GraphUID")
            return
        }
        #expect(uidA == uidB)

        // Sanity check that the equality above isn't vacuous: an unshared face's pick
        // mints a different UID.
        guard let pickUnshared = service.resolveFacePick(bodyID: "shared", triangleIndex: triForOrdinal1),
              let uidUnshared = pickUnshared.uid else {
            Issue.record("expected ordinal 1 to resolve with a GraphUID")
            return
        }
        #expect(uidUnshared != uidA)
    }

    /// Regression for #25 review: `rebuildIdentity` is `loadFile`'s multi-body identity
    /// builder, and reimplements `FaceIdentityTable` construction locally (rather than
    /// calling `shapeToBodyMetadataAndIdentity`, to avoid re-tessellating every body).
    /// `sharedFaceBetweenShellsResolvesToSameUID` above only exercises `loadShape`'s
    /// single-body path through the library's own identity builder — this test drives
    /// `rebuildIdentity` directly against more than one body, including the shared-face
    /// fixture, to prove the local reimplementation collapses the shared face to one
    /// `GraphUID` the same way. `metadata` is seeded directly since `loadFile` needs a real
    /// multi-body file on disk, which this package's tests don't ship.
    @MainActor
    @Test("rebuildIdentity resolves durable identity correctly across multiple bodies")
    func rebuildIdentityMultiBodyResolvesDurableIdentity() {
        guard let plainBox = Shape.box(width: 4, height: 4, depth: 4) else {
            Issue.record("Shape.box returned nil")
            return
        }
        guard let sharedBox = Shape.box(width: 10, height: 10, depth: 10) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let boxFaces = sharedBox.subShapes(ofType: .face)
        let sharedFace = boxFaces[0]
        guard let shellA = Shape.shellFromFaces([sharedFace, boxFaces[1], boxFaces[2]]),
              let shellB = Shape.shellFromFaces([sharedFace, boxFaces[3], boxFaces[4], boxFaces[5]]),
              let compound = Shape.compound([shellA, shellB]) else {
            Issue.record("failed to build the shared-face compound fixture")
            return
        }

        let (plainBody, plainMeta) = CADFileLoader.shapeToBodyAndMetadata(
            plainBox, id: "multi-0", color: SIMD4<Float>(1, 1, 1, 1)
        )
        let (compoundBody, compoundMeta) = CADFileLoader.shapeToBodyAndMetadata(
            compound, id: "multi-1", color: SIMD4<Float>(1, 1, 1, 1)
        )
        guard let plainBody, let plainMeta, let compoundBody, let compoundMeta else {
            Issue.record("shapeToBodyAndMetadata returned nil building the multi-body fixture")
            return
        }
        guard let triForOrdinal0 = compoundMeta.faceIndices.firstIndex(of: 0),
              let triForOrdinal3 = compoundMeta.faceIndices.firstIndex(of: 3) else {
            Issue.record("expected triangles landing on ordinals 0 and 3")
            return
        }

        let service = CADViewportService()
        service.metadata = ["multi-0": plainMeta, "multi-1": compoundMeta]
        service.rebuildIdentity(bodies: [plainBody, compoundBody], shapes: [plainBox, compound])

        guard let pickA = service.resolveFacePick(bodyID: "multi-1", triangleIndex: triForOrdinal0),
              let pickB = service.resolveFacePick(bodyID: "multi-1", triangleIndex: triForOrdinal3) else {
            Issue.record("resolveFacePick failed against rebuildIdentity's output")
            return
        }
        guard let uidA = pickA.uid, let uidB = pickB.uid else {
            Issue.record("expected both shared-face picks to carry a GraphUID")
            return
        }
        #expect(uidA == uidB)

        // The other body must resolve independently, keyed by its own id, and not collide
        // with "multi-1"'s identity.
        guard let plainPick = service.resolveFacePick(bodyID: "multi-0", triangleIndex: 0) else {
            Issue.record("resolveFacePick failed for the second body")
            return
        }
        #expect(plainPick.bodyID == "multi-0")
        if let plainUID = plainPick.uid {
            #expect(plainUID != uidA)
        }
    }

    /// Regression for #25 review: `OCCTSwiftTools.CADFileLoader`'s STL/IGES robust-reload
    /// fallback (`reloadRobustAndBridge`) can append a shape for every input even when that
    /// input's body tessellation fails, which shifts `CADLoadResult.shapes` out of
    /// positional alignment with `.bodies` for everything after the failure. `rebuildIdentity`
    /// can't repair that alignment from the outside, so it must detect the resulting count
    /// mismatch and refuse to build identity at all — absent rather than silently wrong.
    @MainActor
    @Test("rebuildIdentity clears identity rather than risk misaligned pairing when bodies/shapes counts differ")
    func rebuildIdentityGuardsAgainstCountMismatch() {
        guard let box = Shape.box(width: 4, height: 4, depth: 4) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let (body, meta) = CADFileLoader.shapeToBodyAndMetadata(
            box, id: "mismatch-0", color: SIMD4<Float>(1, 1, 1, 1)
        )
        guard let body, let meta else {
            Issue.record("shapeToBodyAndMetadata returned nil")
            return
        }

        let service = CADViewportService()
        service.metadata = ["mismatch-0": meta]
        // shapes.count (2) > bodies.count (1): the exact mismatch reloadRobustAndBridge can
        // produce after a partial tessellation failure mid-batch.
        service.rebuildIdentity(bodies: [body], shapes: [box, box])

        #expect(service.resolveFacePick(bodyID: "mismatch-0", triangleIndex: 0) == nil)
    }

    /// Regression for #27 review: like `rebuildIdentityMultiBodyResolvesDurableIdentity`
    /// above, but for edges and vertices — `makeEdgeIdentityTable`/`makeVertexIdentityTable`
    /// (the multi-body `loadFile` path's hand-rolled builders) had zero coverage; every
    /// other edge/vertex test only drove `loadShape`'s single-body path through the
    /// library's own `shapeToBodyMetadataAndIdentities`.
    @MainActor
    @Test("rebuildIdentity resolves edge and vertex durable identity across multiple bodies")
    func rebuildIdentityMultiBodyResolvesEdgeAndVertexIdentity() {
        guard let smallBox = Shape.box(width: 2, height: 2, depth: 2) else {
            Issue.record("Shape.box returned nil")
            return
        }
        guard let box = Shape.box(width: 4, height: 4, depth: 4) else {
            Issue.record("Shape.box returned nil")
            return
        }

        let (body0, meta0) = CADFileLoader.shapeToBodyAndMetadata(
            smallBox, id: "multi-0", color: SIMD4<Float>(1, 1, 1, 1)
        )
        let (body1, meta1) = CADFileLoader.shapeToBodyAndMetadata(
            box, id: "multi-1", color: SIMD4<Float>(1, 1, 1, 1)
        )
        guard let body0, let meta0, let body1, let meta1 else {
            Issue.record("shapeToBodyAndMetadata returned nil building the multi-body fixture")
            return
        }

        let service = CADViewportService()
        service.selectionModes = [.face, .edge, .vertex]
        service.metadata = ["multi-0": meta0, "multi-1": meta1]
        service.modelBodies = [body0, body1]
        service.rebuildIdentity(bodies: [body0, body1], shapes: [smallBox, box])

        guard let edgePick = service.resolveEdgePick(bodyID: "multi-1", segmentIndex: 0) else {
            Issue.record("resolveEdgePick failed against rebuildIdentity's output")
            return
        }
        #expect(edgePick.bodyID == "multi-1")
        #expect(edgePick.uid != nil)

        guard let vertexPick = service.resolveVertexPick(bodyID: "multi-1", pointIndex: 0) else {
            Issue.record("resolveVertexPick failed against rebuildIdentity's output")
            return
        }
        #expect(vertexPick.bodyID == "multi-1")
        #expect(vertexPick.uid != nil)

        // The other body must resolve independently and not collide.
        guard let otherEdgePick = service.resolveEdgePick(bodyID: "multi-0", segmentIndex: 0) else {
            Issue.record("resolveEdgePick failed for the second body")
            return
        }
        #expect(otherEdgePick.bodyID == "multi-0")
        if let otherUID = otherEdgePick.uid {
            #expect(otherUID != edgePick.uid)
        }
    }

    /// Regression for #27 review: `resolveVertexPick` deliberately implements
    /// `ViewportBody.vertexIndices`' documented "empty means identity mapping" fallback in
    /// full (unlike `OCCTSwiftAIS.InteractiveContext.resolveVertexSubShape`, which
    /// bounds-checks against `vertexIndices.count` directly and so never resolves when it's
    /// empty). Prove the fallback actually works: a body with `vertices` populated but
    /// `vertexIndices` empty must still resolve, using `pointIndex` as the ordinal itself.
    @MainActor
    @Test("resolveVertexPick falls back to identity mapping when vertexIndices is empty")
    func resolveVertexPickFallsBackToIdentityMappingWhenVertexIndicesEmpty() {
        guard let box = Shape.box(width: 4, height: 4, depth: 4) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.selectionModes = [.vertex]
        service.loadShape(box, id: "box")

        guard let realBody = service.modelBodies.first(where: { $0.id == "box" }), !realBody.vertices.isEmpty else {
            Issue.record("expected a vertex-pickable model body for \"box\"")
            return
        }

        // Same vertices, but with vertexIndices cleared — forcing the identity-mapping path.
        let noIndicesBody = _ViewportBody(
            id: "box",
            vertexData: realBody.vertexData,
            indices: realBody.indices,
            edges: realBody.edges,
            faceIndices: realBody.faceIndices,
            edgeIndices: realBody.edgeIndices,
            vertices: realBody.vertices,
            vertexIndices: [],
            color: realBody.color
        )
        service.modelBodies = [noIndicesBody]

        guard let pick = service.resolveVertexPick(bodyID: "box", pointIndex: 0) else {
            Issue.record("resolveVertexPick returned nil with vertexIndices empty")
            return
        }
        #expect(pick.vertexIndex == 0, "with vertexIndices empty, pointIndex is the ordinal itself")
    }

    /// Regression for #27: edge and vertex picks must carry the same durable-identity shape
    /// (`shape`/`uid`) established for faces in #25.
    @MainActor
    @Test("Edge and vertex picks resolve with durable identity")
    func edgeAndVertexPicksResolveWithDurableIdentity() {
        guard let box = Shape.box(width: 10, height: 8, depth: 6) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.selectionModes = [.face, .edge, .vertex]
        service.loadShape(box, id: "box")

        guard let body = service.modelBodies.first(where: { $0.id == "box" }) else {
            Issue.record("expected a model body for \"box\"")
            return
        }
        #expect(!body.edgeIndices.isEmpty, "a box should be edge-pickable")
        #expect(!body.vertices.isEmpty, "a box should be vertex-pickable")

        guard let edgePick = service.resolveEdgePick(bodyID: "box", segmentIndex: 0) else {
            Issue.record("resolveEdgePick returned nil for a valid segment")
            return
        }
        #expect(edgePick.bodyID == "box")
        #expect(edgePick.length > 0)
        #expect(edgePick.uid != nil, "loadShape always builds a graph for a valid box")

        guard let vertexPick = service.resolveVertexPick(bodyID: "box", pointIndex: 0) else {
            Issue.record("resolveVertexPick returned nil for a valid point")
            return
        }
        #expect(vertexPick.bodyID == "box")
        #expect(vertexPick.uid != nil)

        // Vertex enumeration order isn't part of the contract, so just check the resolved
        // position is within the box's own bounds rather than asserting an exact corner.
        let bounds = box.bounds
        #expect(vertexPick.position.x >= bounds.min.x - 0.01 && vertexPick.position.x <= bounds.max.x + 0.01)
        #expect(vertexPick.position.y >= bounds.min.y - 0.01 && vertexPick.position.y <= bounds.max.y + 0.01)
        #expect(vertexPick.position.z >= bounds.min.z - 0.01 && vertexPick.position.z <= bounds.max.z + 0.01)
    }

    /// Regression for #27: `selectionModes` defaults to `[.face]` (preserving pre-#27
    /// behavior) and gates every kind, including turning face picking itself off.
    @MainActor
    @Test("selectionModes gates which kinds resolve, defaulting to face-only")
    func selectionModesGatesEdgeAndVertexPicking() {
        guard let box = Shape.box(width: 4, height: 4, depth: 4) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        #expect(service.selectionModes == [.face])
        service.loadShape(box, id: "box")

        #expect(service.resolveEdgePick(bodyID: "box", segmentIndex: 0) == nil)
        #expect(service.resolveVertexPick(bodyID: "box", pointIndex: 0) == nil)

        service.selectionModes = [.face, .edge, .vertex]
        #expect(service.resolveEdgePick(bodyID: "box", segmentIndex: 0) != nil)
        #expect(service.resolveVertexPick(bodyID: "box", pointIndex: 0) != nil)

        service.selectionModes = [.edge, .vertex]
        #expect(service.resolveFacePick(bodyID: "box", triangleIndex: 0) == nil)
    }

    /// Regression for #27's acceptance criterion: a body with no `edgeIndices`/`vertices`
    /// populated (e.g. a loose-mesh body, per `ViewportBody`'s own "not edge/vertex-pickable"
    /// documentation) must degrade to `nil` rather than mis-pick — face picking on the same
    /// body is unaffected.
    @MainActor
    @Test("Bodies without edgeIndices/vertices degrade gracefully rather than mis-pick")
    func bodiesWithoutEdgeOrVertexDataDegradeGracefully() {
        guard let box = Shape.box(width: 4, height: 4, depth: 4) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.selectionModes = [.face, .edge, .vertex]
        service.loadShape(box, id: "meshOnly")

        // Simulate a body whose render data carries no edge/vertex info (e.g. a
        // loose-mesh STL body) by swapping in a synthetic body with empty edges/vertices.
        // metadata/bodyShapes/identity tables are unaffected by this and still reflect the
        // real box loadShape just tessellated, so face picking should still work.
        let meshOnlyBody = _ViewportBody(
            id: "meshOnly",
            vertexData: [0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 1],
            indices: [0, 1, 2],
            edges: [],
            color: SIMD4<Float>(1, 1, 1, 1)
        )
        service.modelBodies = [meshOnlyBody]

        #expect(service.resolveFacePick(bodyID: "meshOnly", triangleIndex: 0) != nil, "face picking is unaffected")
        #expect(service.resolveEdgePick(bodyID: "meshOnly", segmentIndex: 0) == nil)
        #expect(service.resolveVertexPick(bodyID: "meshOnly", pointIndex: 0) == nil)
    }

    @Test("CADViewportError messages format correctly")
    func errorMessages() {
        #expect(CADViewportError.unsupportedFormat("xyz").errorDescription == "Unsupported file format: .xyz")
        #expect(CADViewportError.emptyFile.errorDescription == "File contains no geometry")
        #expect(CADViewportError.loadFailed("bad").errorDescription == "Load failed: bad")
    }

    @Test("CADViewportService.ShapeBounds reports size correctly")
    func shapeBoundsSize() {
        let b = CADViewportService.ShapeBounds(
            minX: -1, minY: -2, minZ: -3,
            maxX: 4, maxY: 5, maxZ: 6
        )
        #expect(b.sizeX == 5)
        #expect(b.sizeY == 7)
        #expect(b.sizeZ == 9)
    }

    /// Regression for #28: several entities must display simultaneously, addressable and
    /// independently removable, rather than the deprecated single-shape `loadShape`/
    /// `loadFile` "replace everything" behavior.
    @MainActor
    @Test("Multiple entities load, coexist, and remove independently")
    func multipleEntitiesCoexistAndRemoveIndependently() {
        guard let boxA = Shape.box(width: 4, height: 4, depth: 4),
              let boxB = Shape.box(width: 2, height: 2, depth: 2) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()

        #expect(service.load(boxA, id: "partA") == "partA")
        #expect(service.load(boxB, id: "partB") == "partB")

        #expect(service.modelBodies.contains { $0.id == "partA" })
        #expect(service.modelBodies.contains { $0.id == "partB" })
        #expect(Set(service.loadedShapes.keys) == ["partA", "partB"])
        #expect(service.shape(id: "partA") != nil)
        #expect(service.shape(id: "partB") != nil)
        #expect(service.shape(id: "nonexistent") == nil)

        service.remove(id: "partA")
        #expect(!service.modelBodies.contains { $0.id == "partA" })
        #expect(service.modelBodies.contains { $0.id == "partB" })
        #expect(Set(service.loadedShapes.keys) == ["partB"])

        service.removeAll()
        #expect(service.modelBodies.isEmpty)
        #expect(service.loadedShapes.isEmpty)
    }

    /// Regression for #28: re-loading under an id already in use replaces that entity
    /// rather than accumulating duplicate bodies.
    @MainActor
    @Test("Loading again under an existing id replaces that entity")
    func loadingAgainUnderExistingIDReplacesEntity() {
        guard let smallBox = Shape.box(width: 2, height: 2, depth: 2),
              let bigBox = Shape.box(width: 8, height: 8, depth: 8) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(smallBox, id: "part")
        service.load(bigBox, id: "part")

        #expect(service.modelBodies.filter { $0.id == "part" }.count == 1)
        guard let reloaded = service.shape(id: "part") else {
            Issue.record("expected \"part\" to still be loaded")
            return
        }
        let bounds = reloaded.bounds
        #expect(bounds.max.x - bounds.min.x > 7, "expected the second (bigger) load to have won")
    }

    /// Regression for #28: `transform` places the shape before tessellating it.
    @MainActor
    @Test("load(_:id:transform:) places the shape via the given rigid transform")
    func loadAppliesTransform() {
        guard let box = Shape.box(width: 2, height: 2, depth: 2) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(box, id: "untransformed")
        service.load(box, id: "translated", transform: [
            1, 0, 0,
            0, 1, 0,
            0, 0, 1,
            10, 20, 30,
        ])

        guard let plain = service.shape(id: "untransformed"), let moved = service.shape(id: "translated") else {
            Issue.record("expected both entities to be loaded")
            return
        }
        let plainBounds = plain.bounds
        let movedBounds = moved.bounds
        #expect(abs((movedBounds.min.x - plainBounds.min.x) - 10) < 0.01)
        #expect(abs((movedBounds.min.y - plainBounds.min.y) - 20) < 0.01)
        #expect(abs((movedBounds.min.z - plainBounds.min.z) - 30) < 0.01)
    }

    /// Regression for #28: per-entity visibility toggles the bodies that entity owns.
    @MainActor
    @Test("visibility toggles the right entity's bodies")
    func visibilityTogglesEntityBodies() {
        guard let boxA = Shape.box(width: 2, height: 2, depth: 2),
              let boxB = Shape.box(width: 2, height: 2, depth: 2) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(boxA, id: "partA")
        service.load(boxB, id: "partB")

        #expect(service.visibility == ["partA": true, "partB": true])

        service.visibility = ["partA": false]

        #expect(service.modelBodies.first { $0.id == "partA" }?.isVisible == false)
        #expect(service.modelBodies.first { $0.id == "partB" }?.isVisible == true)
        #expect(service.visibility["partA"] == false)
    }

    /// Regression for #28: `loadedShape` (deprecated) still works for the single-shape
    /// case, whichever API loaded it, but goes `nil` once more than one entity is loaded.
    @MainActor
    @Test("Deprecated loadedShape reflects the single-entity case only")
    func deprecatedLoadedShapeReflectsSingleEntityCase() {
        guard let box = Shape.box(width: 2, height: 2, depth: 2) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        #expect(service.loadedShape == nil)

        service.load(box, id: "onlyOne")
        #expect(service.loadedShape != nil, "exactly one entity is loaded")

        service.load(box, id: "second")
        #expect(service.loadedShape == nil, "more than one entity is loaded")
    }

    /// Regression for #28: a pick reports which entity was hit via `entityID(forBodyID:)`.
    @MainActor
    @Test("Picks report which entity was hit")
    func picksReportWhichEntityWasHit() {
        guard let box = Shape.box(width: 4, height: 4, depth: 4) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(box, id: "thePart")

        guard let pick = service.resolveFacePick(bodyID: "thePart", triangleIndex: 0) else {
            Issue.record("resolveFacePick returned nil for a valid triangle")
            return
        }
        let entity = PickedEntity.face(pick)
        #expect(entity.bodyID == "thePart")
        #expect(service.entityID(forBodyID: entity.bodyID) == "thePart")
        #expect(service.entityID(forBodyID: "no-such-body") == nil)
    }

    /// Regression for #28 review: the deprecated `loadShape`/`loadFile` and the new
    /// `load`/`loadFile(from:id:)` share one `entities` registry precisely so this doesn't
    /// happen — mixing the two APIs under the same id must replace, not duplicate. Before
    /// the fix, `loadShape`'s default id ("model") never registered in `entities`, so a
    /// later `load(_, id: "model")` had nothing to detect and remove, leaving two "model"
    /// bodies rendered simultaneously.
    @MainActor
    @Test("Mixing the deprecated single-shape API and the multi-entity API under the same id replaces rather than duplicates")
    func mixingDeprecatedAndMultiEntityAPIsUnderSameIDReplaces() {
        guard let boxA = Shape.box(width: 4, height: 4, depth: 4),
              let boxB = Shape.box(width: 6, height: 6, depth: 6) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()

        service.loadShape(boxA) // deprecated, default id "model"
        #expect(service.modelBodies.filter { $0.id == "model" }.count == 1)

        _ = service.load(boxB, id: "model") // new API, same id
        #expect(service.modelBodies.filter { $0.id == "model" }.count == 1, "must replace, not duplicate")
        #expect(service.entityID(forBodyID: "model") == "model")

        // The deprecated loadedShape/shapeBounds convenience must track the replacement
        // too — not keep reporting boxA (4mm) after boxB (6mm) has taken over "model".
        guard let bounds = service.shapeBounds else {
            Issue.record("expected shapeBounds to be non-nil with exactly one entity loaded")
            return
        }
        #expect(abs(bounds.sizeX - 6) < 0.01, "shapeBounds must reflect boxB (6mm), not the replaced boxA (4mm)")
    }

    /// Regression for #28 review: the deprecated single-shape `loadShape`/`loadFile`
    /// replace *everything*, including entities loaded via the new multi-entity API before
    /// them — previously only `modelBodies` was fully replaced; `metadata`/`bodyShapes`/etc.
    /// for an orphaned entity leaked, and `entities` still listed it (making `loadedShapes`/
    /// `entityID(forBodyID:)` report a body that could no longer actually be picked).
    @MainActor
    @Test("The deprecated single-shape API fully replaces prior multi-entity loads, not just modelBodies")
    func deprecatedSingleShapeAPIFullyReplacesPriorMultiEntityLoads() {
        guard let boxA = Shape.box(width: 4, height: 4, depth: 4),
              let boxB = Shape.box(width: 6, height: 6, depth: 6) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()

        _ = service.load(boxA, id: "orphanEntity")
        service.loadShape(boxB, id: "model") // deprecated, different id

        #expect(Set(service.loadedShapes.keys) == ["model"], "orphanEntity must be fully gone, not just from modelBodies")
        #expect(service.entityID(forBodyID: "orphanEntity") == nil)
        #expect(service.resolveFacePick(bodyID: "orphanEntity", triangleIndex: 0) == nil)
    }

    /// Regression for #28 review: `removeAll()` must clear the deprecated single-shape
    /// API's backing too, or `loadedShape` (deprecated) can report a stale shape after
    /// "removing everything."
    @MainActor
    @Test("removeAll() clears the deprecated single-shape loadedShape too")
    func removeAllClearsDeprecatedLoadedShape() {
        guard let box = Shape.box(width: 4, height: 4, depth: 4) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.loadShape(box) // deprecated

        #expect(service.loadedShape != nil)

        service.removeAll()

        #expect(service.loadedShape == nil)
        #expect(service.modelBodies.isEmpty)
    }
}
