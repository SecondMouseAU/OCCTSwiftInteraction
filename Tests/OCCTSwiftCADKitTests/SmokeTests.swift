import OCCTSwift
import OCCTSwiftAIS
import OCCTSwiftTools
import OCCTSwiftViewport
import Testing
import simd

@testable import OCCTSwiftCADKit

@Suite("Smoke")
struct SmokeTests {
    @MainActor
    @Test(
        "interactiveContext shares the service viewport, and CADKit/AIS bodies coexist on rebuild")
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

    /// The source-compatibility half of OCCTSwiftInteraction#2.
    ///
    /// `InteractiveObject`, `SubShapeRef` and `SubShape` moved to `OCCTSwiftTools`, with
    /// typealiases left in `OCCTSwiftAIS`. This target imports both, which is the realistic
    /// consumer shape, so it is where a name that resolved ambiguously would show up. Written
    /// against the unqualified names on purpose, plus one explicit round trip between the two
    /// spellings to pin that they denote the same type rather than two similar ones.
    @Test("The moved sub-shape types resolve when both targets are imported")
    func movedSubShapeTypesResolveFromBothTargets() throws {
        let box = try #require(Shape.box(width: 2, height: 2, depth: 2))
        let object = OCCTSwiftTools.InteractiveObject(shape: box)
        let ref = OCCTSwiftTools.SubShapeRef(shape: box, ordinal: 0)
        let sub: OCCTSwiftTools.SubShape = .face(object, ref: ref)

        #expect(sub.object == object)
        #expect(sub.ref == ref)

        let viaTools: OCCTSwiftTools.SubShapeRef = ref
        let viaAIS: OCCTSwiftAIS.SubShapeRef = viaTools
        #expect(viaAIS.ordinal == 0)
    }

    /// Regression for #25, updated for OCCTSwift v2.0.0 (issue #54). Originally, a face shared
    /// between two shells was one node in a `BRepGraph` but appeared once *per shell* in the
    /// render-path traversal `faceIndex` used, which is exactly why `FaceIdentityTable`/`uid`
    /// exist: to capture the correspondence directly rather than let a consumer assume the
    /// render-path ordinal agrees with `subShapes(ofType: .face)`'s independently deduplicated
    /// one.
    ///
    /// OCCTSwift v2.0.0 (#541/#613) closed that specific divergence upstream: `Shape.faces()` is
    /// now itself the deduplicated enumeration, and `Mesh.Triangle.faceIndex` moved onto that
    /// same enumeration in the same release (mirrors OCCTSwiftTools' own
    /// `FaceIdentityTableTests` update for the identical fixture, issue #51). The shared face's
    /// two shell-local triangulations now carry the *same* `faceIndex` (measured: both land on
    /// ordinal 0, not 0 and 3 as they used to) rather than two different ones, so this test now
    /// proves durable identity is still correct once the render path has already collapsed them:
    /// every triangle landing on the shared face's ordinal, from either shell's contribution,
    /// resolves to one `uid`, and a genuinely different face's ordinal still resolves to a
    /// different one.
    @MainActor
    @Test(
        "Durable identity: a face shared between two shells resolves to the same GraphUID from both picks"
    )
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
            let compound = Shape.compound([shellA, shellB])
        else {
            Issue.record("failed to build the shared-face compound fixture")
            return
        }
        // Post-v2.0.0, Shape.faces() is itself the deduplicated enumeration, so it now agrees
        // with subShapes(ofType: .face) instead of double-counting the shared face (was 7 vs 6
        // pre-2.0.0). orientedFaces() (#614) is the new spelling of the old occurrence count.
        #expect(compound.faces().count == 6)
        #expect(compound.subShapes(ofType: .face).count == 6)
        #expect(compound.orientedFaces().count == 7)

        // Independently learn the triangle -> faceIndex mapping the mesher assigns, so we can
        // pick triangles landing on the shared face's ordinal without reaching into
        // CADViewportService's private metadata. Since #613, both shells' triangulations of the
        // shared face carry the identical faceIndex, so, unlike pre-2.0.0, we need two
        // *distinct triangle positions that both hold that same value*, not two different values.
        let (_, referenceMeta, _) = CADFileLoader.shapeToBodyMetadataAndIdentity(
            compound, id: "shared", color: SIMD4<Float>(1, 1, 1, 1)
        )
        guard let referenceMeta else {
            Issue.record("shapeToBodyMetadataAndIdentity returned nil for the shared-face compound")
            return
        }
        let sharedOrdinal: Int32 = 0
        let sharedPositions = referenceMeta.faceIndices.indices.filter {
            referenceMeta.faceIndices[$0] == sharedOrdinal
        }
        guard sharedPositions.count >= 2,
            let triForShellA = sharedPositions.first,
            let triForShellB = sharedPositions.last,
            triForShellA != triForShellB
        else {
            Issue.record(
                "expected at least two distinct triangle positions (one per shell) landing on the shared face's ordinal"
            )
            return
        }
        guard
            let triForDistinctFace = referenceMeta.faceIndices.firstIndex(where: {
                $0 != sharedOrdinal
            })
        else {
            Issue.record("expected at least one triangle landing on a non-shared face")
            return
        }

        let service = CADViewportService()
        service.load(compound, id: "shared")

        guard let pickA = service.resolveFacePick(bodyID: "shared", triangleIndex: triForShellA)
        else {
            Issue.record("resolveFacePick returned nil for the shared face's first triangulation")
            return
        }
        guard let pickB = service.resolveFacePick(bodyID: "shared", triangleIndex: triForShellB)
        else {
            Issue.record("resolveFacePick returned nil for the shared face's second triangulation")
            return
        }

        #expect(pickA.faceIndex == Int(sharedOrdinal))
        #expect(pickB.faceIndex == Int(sharedOrdinal))

        guard let uidA = pickA.uid, let uidB = pickB.uid else {
            Issue.record("expected both shared-face picks to carry a GraphUID")
            return
        }
        #expect(uidA == uidB)

        // Sanity check that the equality above isn't vacuous: a genuinely different face's pick
        // mints a different UID.
        guard
            let pickDistinct = service.resolveFacePick(
                bodyID: "shared", triangleIndex: triForDistinctFace),
            let uidDistinct = pickDistinct.uid
        else {
            Issue.record("expected the distinct face's triangle to resolve with a GraphUID")
            return
        }
        #expect(uidDistinct != uidA)
    }

    /// Regression for #25 review: `installIdentity` is how a multi-body `loadFile` gets durable
    /// identity into this service.
    ///
    /// `sharedFaceBetweenShellsResolvesToSameUID` above only exercises the single-body path
    /// of a single-body load; this test drives more than one body at once, including the shared-face
    /// fixture, to prove the shared face still collapses to one `GraphUID` per body and that
    /// two bodies' identity does not collide. `metadata` is seeded directly since `loadFile`
    /// needs a real multi-body file on disk, which this package's tests don't ship.
    ///
    /// Rewritten for OCCTSwiftInteraction#7: this service no longer builds the tables itself
    /// (that was the second of three copies of `OCCTSwiftTools.CADFileLoader`'s private
    /// helpers), so the test seeds `OCCTSwiftTools.ShapeIdentity` values keyed by body id, the
    /// same shape `CADLoadResult.identity` hands it in production. No positional pairing.
    ///
    /// Updated for OCCTSwift v2.0.0 (issue #54): see `sharedFaceBetweenShellsResolvesToSameUID`
    /// above for why the shared face's two triangulations are now found by *value*, not by two
    /// different ordinals.
    @MainActor
    @Test("installIdentity resolves durable identity correctly across multiple bodies")
    func installIdentityMultiBodyResolvesDurableIdentity() {
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
            let compound = Shape.compound([shellA, shellB])
        else {
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
        // Since OCCTSwift v2.0.0 (#541/#613), the shared face's two shell-local triangulations
        // carry the identical faceIndex (see sharedFaceBetweenShellsResolvesToSameUID above for
        // the measured mapping), pick two distinct triangle positions that both hold ordinal 0,
        // rather than two different ordinals (0 and 3, as pre-2.0.0).
        let sharedOrdinal: Int32 = 0
        let sharedPositions = compoundMeta.faceIndices.indices.filter {
            compoundMeta.faceIndices[$0] == sharedOrdinal
        }
        guard sharedPositions.count >= 2,
            let triForShellA = sharedPositions.first,
            let triForShellB = sharedPositions.last,
            triForShellA != triForShellB
        else {
            Issue.record(
                "expected at least two distinct triangle positions landing on the shared face's ordinal"
            )
            return
        }

        let service = CADViewportService()
        service.metadata = ["multi-0": plainMeta, "multi-1": compoundMeta]
        service.installIdentity([
            plainBody.id: ShapeIdentity(shape: plainBox),
            compoundBody.id: ShapeIdentity(shape: compound),
        ])

        guard let pickA = service.resolveFacePick(bodyID: "multi-1", triangleIndex: triForShellA),
            let pickB = service.resolveFacePick(bodyID: "multi-1", triangleIndex: triForShellB)
        else {
            Issue.record("resolveFacePick failed against installIdentity's output")
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

    /// Regression for #25 review, re-aimed by OCCTSwiftInteraction#7.
    ///
    /// The original subject was `rebuildIdentity`'s count-mismatch guard: the STL/IGES
    /// robust-reload fallback of `OCCTSwiftTools.CADFileLoader` (`reloadRobustAndBridge`)
    /// appends a shape for every input even when that input's body tessellation fails, so
    /// `CADLoadResult.shapes` shifts out of positional alignment with `.bodies` for everything
    /// after the failure, and this service, pairing them positionally from the outside, had to
    /// detect the resulting count mismatch and drop identity wholesale.
    ///
    /// That guard is gone because the hazard is: `CADLoadResult.identity` is keyed by body id
    /// inside the loader, in the same branch that creates each body, so no positional pairing
    /// happens here at all. The unit test that a body never gets another body's geometry now
    /// lives where the pairing does, in `CADFileLoaderIdentityTests`.
    ///
    /// What is still this service's own property, and what this test now holds down: a body
    /// with no identity entry (whatever the reason) resolves to no pick rather than to a
    /// wrong one. Absent rather than wrong, at the level where it can still happen.
    @MainActor
    @Test("a body with no identity entry resolves to no pick rather than a wrong one")
    func bodyWithoutIdentityResolvesToNoPick() {
        guard let box = Shape.box(width: 4, height: 4, depth: 4) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let (body, meta) = CADFileLoader.shapeToBodyAndMetadata(
            box, id: "no-identity-0", color: SIMD4<Float>(1, 1, 1, 1)
        )
        guard let body, let meta else {
            Issue.record("shapeToBodyAndMetadata returned nil")
            return
        }

        let service = CADViewportService()
        service.modelBodies = [body]
        service.metadata = ["no-identity-0": meta]
        // Deliberately no installIdentity call: the body displays and its triangles are
        // pickable, but nothing tells the service what shape they came from.
        #expect(service.resolveFacePick(bodyID: "no-identity-0", triangleIndex: 0) == nil)

        // And once identity IS installed, the same pick resolves, so the nil above is the
        // missing entry rather than some other reason the pick could not land.
        service.installIdentity(["no-identity-0": ShapeIdentity(shape: box)])
        #expect(service.resolveFacePick(bodyID: "no-identity-0", triangleIndex: 0) != nil)
    }

    /// Regression for #27 review: like `installIdentityMultiBodyResolvesDurableIdentity`
    /// above, but for edges and vertices.
    ///
    /// The hand-rolled `makeEdgeIdentityTable`/`makeVertexIdentityTable` this used to cover are
    /// gone (OCCTSwiftInteraction#7); the multi-body edge and vertex path is still worth holding
    /// down, since every other edge/vertex test drives the single-body load path.
    @MainActor
    @Test("installIdentity resolves edge and vertex durable identity across multiple bodies")
    func installIdentityMultiBodyResolvesEdgeAndVertexIdentity() {
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
        service.installIdentity([
            body0.id: ShapeIdentity(shape: smallBox),
            body1.id: ShapeIdentity(shape: box),
        ])

        guard let edgePick = service.resolveEdgePick(bodyID: "multi-1", segmentIndex: 0) else {
            Issue.record("resolveEdgePick failed against installIdentity's output")
            return
        }
        #expect(edgePick.bodyID == "multi-1")
        #expect(edgePick.uid != nil)

        guard let vertexPick = service.resolveVertexPick(bodyID: "multi-1", pointIndex: 0) else {
            Issue.record("resolveVertexPick failed against installIdentity's output")
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

    /// Regression for #27 review: `resolveVertexPick` implements in full the documented
    /// "empty means identity mapping" fallback of `ViewportBody.vertexIndices`.
    ///
    /// This used to be the one place it was implemented, which is what
    /// OCCTSwiftInteraction#2 consolidated: `OCCTSwiftAIS` bounds-checked against
    /// `vertexIndices.count` directly and so never resolved a vertex pick when it was empty.
    /// The behaviour now lives once in `OCCTSwiftTools.SubShapePickResolver.resolveVertex`
    /// and both targets get it. This test still earns its keep as the CADKit-side end of that
    /// path, alongside the unit coverage in `SubShapePickResolverTests` and the AIS-side
    /// `t_handlePick_vertexWithEmptyVertexIndices_identityMaps`.
    ///
    /// Prove the fallback actually works: a body with `vertices` populated but
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
        service.load(box, id: "box")

        guard let realBody = service.modelBodies.first(where: { $0.id == "box" }),
            !realBody.vertices.isEmpty
        else {
            Issue.record("expected a vertex-pickable model body for \"box\"")
            return
        }

        // Same vertices, but with vertexIndices cleared: forcing the identity-mapping path.
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
        service.load(box, id: "box")

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
        #expect(edgePick.uid != nil, "a load always builds a graph for a valid box")

        guard let vertexPick = service.resolveVertexPick(bodyID: "box", pointIndex: 0) else {
            Issue.record("resolveVertexPick returned nil for a valid point")
            return
        }
        #expect(vertexPick.bodyID == "box")
        #expect(vertexPick.uid != nil)

        // Vertex enumeration order isn't part of the contract, so just check the resolved
        // position is within the box's own bounds rather than asserting an exact corner.
        guard let bounds = box.bounds else {
            Issue.record("expected a 4mm box to have bounds")
            return
        }
        #expect(
            vertexPick.position.x >= bounds.min.x - 0.01
                && vertexPick.position.x <= bounds.max.x + 0.01)
        #expect(
            vertexPick.position.y >= bounds.min.y - 0.01
                && vertexPick.position.y <= bounds.max.y + 0.01)
        #expect(
            vertexPick.position.z >= bounds.min.z - 0.01
                && vertexPick.position.z <= bounds.max.z + 0.01)
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
        service.load(box, id: "box")

        #expect(service.resolveEdgePick(bodyID: "box", segmentIndex: 0) == nil)
        #expect(service.resolveVertexPick(bodyID: "box", pointIndex: 0) == nil)

        service.selectionModes = [.face, .edge, .vertex]
        #expect(service.resolveEdgePick(bodyID: "box", segmentIndex: 0) != nil)
        #expect(service.resolveVertexPick(bodyID: "box", pointIndex: 0) != nil)

        service.selectionModes = [.edge, .vertex]
        #expect(service.resolveFacePick(bodyID: "box", triangleIndex: 0) == nil)
    }

    /// Regression for the acceptance criterion of #27: a body with no
    /// `edgeIndices`/`vertices` populated (e.g. a loose-mesh body, per `ViewportBody`'s own
    /// "not edge/vertex-pickable" documentation) must degrade to `nil` rather than
    /// mis-pick, face picking on the same body is unaffected.
    @MainActor
    @Test("Bodies without edgeIndices/vertices degrade gracefully rather than mis-pick")
    func bodiesWithoutEdgeOrVertexDataDegradeGracefully() {
        guard let box = Shape.box(width: 4, height: 4, depth: 4) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.selectionModes = [.face, .edge, .vertex]
        service.load(box, id: "meshOnly")

        // Simulate a body whose render data carries no edge/vertex info (e.g. a
        // loose-mesh STL body) by swapping in a synthetic body with empty edges/vertices.
        // metadata/bodyShapes/identity tables are unaffected by this and still reflect the
        // real box the load just tessellated, so face picking should still work.
        let meshOnlyBody = _ViewportBody(
            id: "meshOnly",
            vertexData: [0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 1],
            indices: [0, 1, 2],
            edges: [],
            color: SIMD4<Float>(1, 1, 1, 1)
        )
        service.modelBodies = [meshOnlyBody]

        #expect(
            service.resolveFacePick(bodyID: "meshOnly", triangleIndex: 0) != nil,
            "face picking is unaffected")
        #expect(service.resolveEdgePick(bodyID: "meshOnly", segmentIndex: 0) == nil)
        #expect(service.resolveVertexPick(bodyID: "meshOnly", pointIndex: 0) == nil)
    }

    @Test("CADViewportError messages format correctly")
    func errorMessages() {
        #expect(
            CADViewportError.unsupportedFormat("xyz").errorDescription
                == "Unsupported file format: .xyz")
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
    /// independently removable, rather than the single-shape convenience of `load(_:id:)`/
    /// `loadFile` "replace everything" behavior.
    @MainActor
    @Test("Multiple entities load, coexist, and remove independently")
    func multipleEntitiesCoexistAndRemoveIndependently() {
        guard let boxA = Shape.box(width: 4, height: 4, depth: 4),
            let boxB = Shape.box(width: 2, height: 2, depth: 2)
        else {
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
            let bigBox = Shape.box(width: 8, height: 8, depth: 8)
        else {
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
        guard let bounds = reloaded.bounds else {
            Issue.record("expected the reloaded box to have bounds")
            return
        }
        #expect(bounds.max.x - bounds.min.x > 7, "expected the second (bigger) load to have won")
    }

    /// Regression for #58: a shape with a void bounding box reports no bounds rather than a
    /// zero-size box at the world origin, and `focus(on:)` declines to reframe on it.
    ///
    /// Before OCCTSwift 3.0.0 the kernel fabricated `(0,0,0)-(0,0,0)` here, which this
    /// service could not tell from a real zero-size shape at the origin, so the camera got
    /// aimed at the origin instead.
    @MainActor
    @Test("A shape with no bounding box reports nil bounds, and focus declines to reframe")
    func voidBoundsDeclineRatherThanDefaultToTheOrigin() {
        guard let empty = Shape.builderMakeCompound() else {
            Issue.record("Shape.builderMakeCompound returned nil")
            return
        }
        #expect(empty.bounds == nil, "an empty compound has a void Bnd_Box")

        let service = CADViewportService()
        service.load(empty, id: "empty")
        #expect(service.shapeBounds == nil)

        // `load(_:id:transform:)` never auto-focuses, so any camera animation running after
        // this line would have to be `focus(on:)`'s own.
        service.focus(on: ["empty"])
        #expect(
            !service.controller.cameraController.isAnimating,
            "nothing to frame, so the camera should be left where it is")

        // Control, so the check above is discriminating rather than asserting an inert
        // viewport: the same call on a shape that does have bounds reframes.
        guard let box = Shape.box(width: 4, height: 4, depth: 4) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let framing = CADViewportService()
        framing.load(box, id: "box")
        framing.focus(on: ["box"])
        #expect(framing.controller.cameraController.isAnimating)
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
        service.load(
            box, id: "translated",
            transform: [
                1, 0, 0,
                0, 1, 0,
                0, 0, 1,
                10, 20, 30,
            ])

        guard let plain = service.shape(id: "untransformed"),
            let moved = service.shape(id: "translated")
        else {
            Issue.record("expected both entities to be loaded")
            return
        }
        guard let plainBounds = plain.bounds, let movedBounds = moved.bounds else {
            Issue.record("expected both loaded boxes to have bounds")
            return
        }
        #expect(abs((movedBounds.min.x - plainBounds.min.x) - 10) < 0.01)
        #expect(abs((movedBounds.min.y - plainBounds.min.y) - 20) < 0.01)
        #expect(abs((movedBounds.min.z - plainBounds.min.z) - 30) < 0.01)
    }

    /// Regression for #28: per-entity visibility toggles the bodies that entity owns.
    @MainActor
    @Test("visibility toggles the right entity's bodies")
    func visibilityTogglesEntityBodies() {
        guard let boxA = Shape.box(width: 2, height: 2, depth: 2),
            let boxB = Shape.box(width: 2, height: 2, depth: 2)
        else {
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

    /// Regression for #29: `select(_:scheme:)` must mirror the exact combination semantics
    /// of `OCCTSwiftAIS.SelectionScheme` (`.replace` assigns, `.add`/`.remove`/`.xor` combine
    /// against the current selection), just applied one entity at a time rather than to a
    /// batch region match.
    @MainActor
    @Test("select(_:scheme:) implements replace/add/remove/xor correctly")
    func selectSchemeSemantics() {
        guard let box = Shape.box(width: 10, height: 8, depth: 6) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(box, id: "box")

        guard let meta = service.metadata["box"], meta.faceIndices.count >= 2 else {
            Issue.record("expected at least two triangles for a box")
            return
        }
        // Find two triangles landing on different face ordinals.
        let firstFaceIndex = meta.faceIndices[0]
        guard let secondTri = meta.faceIndices.firstIndex(where: { $0 != firstFaceIndex }) else {
            Issue.record("expected a box to have more than one face ordinal")
            return
        }
        guard let pickA = service.resolveFacePick(bodyID: "box", triangleIndex: 0),
            let pickB = service.resolveFacePick(bodyID: "box", triangleIndex: secondTri)
        else {
            Issue.record("resolveFacePick returned nil for a valid triangle")
            return
        }
        let entityA = PickedEntity.face(pickA)
        let entityB = PickedEntity.face(pickB)
        #expect(entityA != entityB, "the two picks must be genuinely different faces")

        // .replace (default)
        service.select(entityA)
        #expect(service.selection == [entityA])

        // .add
        service.select(entityB, scheme: .add)
        #expect(service.selection.count == 2)
        #expect(service.selection.contains(entityA))
        #expect(service.selection.contains(entityB))

        // .add again with an already-selected entity is idempotent
        service.select(entityA, scheme: .add)
        #expect(service.selection.count == 2)

        // .remove
        service.select(entityA, scheme: .remove)
        #expect(service.selection == [entityB])

        // .xor: not present -> added
        service.select(entityA, scheme: .xor)
        #expect(service.selection.count == 2)
        // .xor: present -> removed
        service.select(entityA, scheme: .xor)
        #expect(service.selection == [entityB])

        // .replace always collapses to just the given entity
        service.select(entityA)  // back to .replace
        #expect(service.selection == [entityA])
    }

    /// Regression for #29: `selectionMeasurements` reports sensible aggregates: count by kind,
    /// total face area, total edge length, and combined bounds.
    @MainActor
    @Test("selectionMeasurements reports sensible aggregates")
    func selectionMeasurementsReportsAggregates() {
        guard let box = Shape.box(width: 10, height: 8, depth: 6) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.selectionModes = [.face, .edge, .vertex]
        service.load(box, id: "box")

        #expect(service.selectionMeasurements == nil, "empty selection has no summary")

        guard let facePick = service.resolveFacePick(bodyID: "box", triangleIndex: 0) else {
            Issue.record("resolveFacePick returned nil")
            return
        }
        service.select(.face(facePick))

        guard let summary1 = service.selectionMeasurements else {
            Issue.record("expected a summary for a non-empty selection")
            return
        }
        #expect(summary1.faceCount == 1)
        #expect(summary1.edgeCount == 0)
        #expect(summary1.vertexCount == 0)
        #expect(abs(summary1.totalArea - facePick.area) < 0.01)
        #expect(summary1.bounds != nil)

        guard let edgePick = service.resolveEdgePick(bodyID: "box", segmentIndex: 0) else {
            Issue.record("resolveEdgePick returned nil")
            return
        }
        service.select(.edge(edgePick), scheme: .add)

        guard let summary2 = service.selectionMeasurements else {
            Issue.record("expected a summary after adding an edge")
            return
        }
        #expect(summary2.faceCount == 1)
        #expect(summary2.edgeCount == 1)
        #expect(abs(summary2.totalLength - edgePick.length) < 0.01)
        // Combined bounds must be at least as large as the face-only bounds.
        guard let b1 = summary1.bounds, let b2 = summary2.bounds else {
            Issue.record("expected bounds on both summaries")
            return
        }
        #expect(b2.sizeX >= b1.sizeX - 0.01)
    }

    /// Regression for #29 review: a vertex-only selection must produce a zero-size (but
    /// non-nil) bounds: the "point" case the bounds math of `selectionMeasurements` has to
    /// handle alongside faces/edges, which contribute a real extent.
    @MainActor
    @Test("selectionMeasurements reports a zero-size bounds for a vertex-only selection")
    func selectionMeasurementsVertexOnlyBounds() {
        guard let box = Shape.box(width: 10, height: 8, depth: 6) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.selectionModes = [.vertex]
        service.load(box, id: "box")

        guard let vertexPick = service.resolveVertexPick(bodyID: "box", pointIndex: 0) else {
            Issue.record("resolveVertexPick returned nil")
            return
        }
        service.select(.vertex(vertexPick))

        guard let summary = service.selectionMeasurements, let bounds = summary.bounds else {
            Issue.record("expected a summary with bounds for a vertex-only selection")
            return
        }
        #expect(summary.vertexCount == 1)
        #expect(summary.faceCount == 0)
        #expect(bounds.sizeX == 0 && bounds.sizeY == 0 && bounds.sizeZ == 0)
        #expect(abs(bounds.minX - vertexPick.position.x) < 0.01)
    }

    /// Regression for the acceptance criterion of #29: the selection survives operations
    /// unrelated to it, and drops only the entries that reference a removed entity,
    /// "reporting deletions accurately" rather than silently keeping a dangling pick or
    /// wiping the whole selection for an unrelated change.
    @MainActor
    @Test("Selection survives removal of unrelated entities, drops only the affected ones")
    func selectionSurvivesUnrelatedRemovalDropsAffectedEntries() {
        guard let boxA = Shape.box(width: 4, height: 4, depth: 4),
            let boxB = Shape.box(width: 6, height: 6, depth: 6)
        else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(boxA, id: "partA")
        service.load(boxB, id: "partB")

        guard let pickA = service.resolveFacePick(bodyID: "partA", triangleIndex: 0),
            let pickB = service.resolveFacePick(bodyID: "partB", triangleIndex: 0)
        else {
            Issue.record("resolveFacePick returned nil")
            return
        }
        service.select(.face(pickA))
        service.select(.face(pickB), scheme: .add)
        #expect(service.selection.count == 2)

        service.remove(id: "partA")

        #expect(
            service.selection == [.face(pickB)],
            "partA's pick must be dropped, partB's must survive")

        service.remove(id: "partB")
        #expect(service.selection.isEmpty)
    }

    /// Regression for #29: multi-selection highlights render as separate per-kind bodies
    /// (face/edge/vertex) covering the WHOLE selection, not just the latest pick.
    @MainActor
    @Test("Selection highlights cover every selected kind, not just the latest pick")
    func selectionHighlightsCoverWholeSelection() {
        guard let box = Shape.box(width: 10, height: 8, depth: 6) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.selectionModes = [.face, .edge, .vertex]
        service.load(box, id: "box")

        guard let facePick = service.resolveFacePick(bodyID: "box", triangleIndex: 0),
            let edgePick = service.resolveEdgePick(bodyID: "box", segmentIndex: 0),
            let vertexPick = service.resolveVertexPick(bodyID: "box", pointIndex: 0)
        else {
            Issue.record("resolve*Pick returned nil for a valid index")
            return
        }
        service.select(.face(facePick))
        service.select(.edge(edgePick), scheme: .add)
        service.select(.vertex(vertexPick), scheme: .add)

        let ids = Set(service.interactiveContext.bodies.map(\.id))
        #expect(ids.contains("selection_highlight_face"))
        #expect(ids.contains("selection_highlight_edge"))
        #expect(ids.contains("selection_highlight_vertex"))
    }

    /// Regression for #28 review: every loader shares one `entities` registry precisely so
    /// this doesn't happen: loading the same id twice must replace, not duplicate.
    ///
    /// Before the fix, the single-shape convenience's default id ("model") never registered
    /// in `entities`, so a later `load(_, id: "model")` had nothing to detect and remove,
    /// leaving two "model" bodies rendered simultaneously.
    @MainActor
    @Test(
        "Loading the same id twice replaces rather than duplicates, and shapeBounds tracks it"
    )
    func loadingSameIDTwiceReplacesRatherThanDuplicates() {
        guard let boxA = Shape.box(width: 4, height: 4, depth: 4),
            let boxB = Shape.box(width: 6, height: 6, depth: 6)
        else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()

        service.load(boxA, id: "model")
        #expect(service.modelBodies.filter { $0.id == "model" }.count == 1)

        _ = service.load(boxB, id: "model")  // same id again
        #expect(
            service.modelBodies.filter { $0.id == "model" }.count == 1,
            "must replace, not duplicate")
        #expect(service.entityID(forBodyID: "model") == "model")

        // The `shapeBounds` convenience must track the replacement too, not keep reporting
        // boxA (4mm) after boxB (6mm) has taken over "model".
        guard let bounds = service.shapeBounds else {
            Issue.record("expected shapeBounds to be non-nil with exactly one entity loaded")
            return
        }
        #expect(
            abs(bounds.sizeX - 6) < 0.01,
            "shapeBounds must reflect boxB (6mm), not the replaced boxA (4mm)")
    }

    /// Removing an entity must clear it from **every** collection a load populated, not only
    /// from `modelBodies`.
    ///
    /// Originally #28 review cover for the deprecated single-shape loaders, which replaced
    /// everything. Those are gone as of 2.0.0, but `remove(id:)` carries exactly the same
    /// hazard and nothing else asserts it: previously `metadata`/`bodyShapes` for an orphaned
    /// entity leaked and `entities` still listed it, so `loadedShapes`/`entityID(forBodyID:)`
    /// reported a body that could no longer actually be picked.
    ///
    /// Distinct from the selection-pruning cover below, which is about `selection` rather
    /// than about the entity collections leaking.
    @MainActor
    @Test("remove(id:) clears the entity from every collection, not just modelBodies")
    func removeClearsEveryCollectionNotJustModelBodies() {
        guard let boxA = Shape.box(width: 4, height: 4, depth: 4),
            let boxB = Shape.box(width: 6, height: 6, depth: 6)
        else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()

        _ = service.load(boxA, id: "orphanEntity")
        _ = service.load(boxB, id: "model")
        #expect(
            service.resolveFacePick(bodyID: "orphanEntity", triangleIndex: 0) != nil,
            "the entity must be pickable first, or its removal proves nothing")

        service.remove(id: "orphanEntity")

        #expect(
            Set(service.loadedShapes.keys) == ["model"],
            "orphanEntity must be fully gone, not just from modelBodies")
        #expect(service.entityID(forBodyID: "orphanEntity") == nil)
        #expect(service.resolveFacePick(bodyID: "orphanEntity", triangleIndex: 0) == nil)
        #expect(service.shape(id: "model") != nil, "the unrelated entity must survive")
    }

    /// `removeAll()` must leave nothing behind in any of the collections a load populates,
    /// not only in `modelBodies`.
    ///
    /// Originally #28 review cover for the deprecated single-shape backing, which could
    /// report a stale shape after "removing everything". That API is gone as of 2.0.0, but
    /// the invariant it was protecting is not, and nothing else asserts it: an entity left in
    /// `entities` after `removeAll()` still answers `shape(id:)` and still resolves picks.
    @MainActor
    @Test("removeAll() leaves no entity, body or selection behind")
    func removeAllLeavesNothingBehind() {
        guard let box = Shape.box(width: 4, height: 4, depth: 4) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(box, id: "model")
        if let pick = service.resolveFacePick(bodyID: "model", triangleIndex: 0) {
            service.select(.face(pick))
        }

        #expect(service.shape(id: "model") != nil)
        #expect(!service.modelBodies.isEmpty)
        #expect(
            !service.selection.isEmpty, "a selection must exist for its clearing to mean anything")

        service.removeAll()

        #expect(service.loadedShapes.isEmpty)
        #expect(service.modelBodies.isEmpty)
        #expect(service.selection.isEmpty)
        #expect(service.shape(id: "model") == nil, "the entity must be gone, not just its body")
    }

    /// Regression for #30: a per-face scalar field must paint the correct triangles
    /// (every triangle belonging to a given face ordinal gets that face's color) and the
    /// body's `generation` changes (`applyTriangleStyles` rebuilds the body rather than
    /// mutating `triangleStyles` in place; see its own doc comment for why an in-place
    /// mutation was empirically confirmed to not actually update the rendered output on
    /// an already-rendered body against the pinned floor of `OCCTSwiftViewport`).
    @MainActor
    @Test("setScalarField(_:forBody:) paints per-face values onto the correct triangles")
    func scalarFieldPerFacePaintsCorrectTriangles() {
        guard let box = Shape.box(width: 10, height: 8, depth: 6) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(box, id: "box")

        guard let bodyBefore = service.modelBodies.first(where: { $0.id == "box" }) else {
            Issue.record("expected a model body for \"box\"")
            return
        }
        let generationBefore = bodyBefore.generation
        let faceCount = Set(bodyBefore.faceIndices.map { $0 }).count
        #expect(faceCount == 6, "a box has 6 faces")

        // One distinct value per face ordinal, using custom stops so colors are exact
        // and easy to assert on rather than sampled from a continuous ramp.
        let values = (0..<faceCount).map { Double($0) }
        let field = ScalarField(
            domain: .perFace,
            values: values,
            range: 0...Double(faceCount - 1),
            colorMap: .custom(
                values.map { ($0, SIMD4<Float>(Float($0) / Float(faceCount - 1), 0, 0, 1)) }),
            label: "test field"
        )
        service.setScalarField(field, forBody: "box")

        guard let bodyAfter = service.modelBodies.first(where: { $0.id == "box" }) else {
            Issue.record("expected a model body for \"box\" after setScalarField")
            return
        }
        #expect(
            bodyAfter.generation != generationBefore,
            "must mint a fresh generation so the renderer actually rebuilds, see the doc comment on applyTriangleStyles"
        )
        #expect(bodyAfter.triangleStyles.count == bodyAfter.indices.count / 3)

        for tri in 0..<(bodyAfter.indices.count / 3) {
            let faceIndex = Int(bodyAfter.faceIndices[tri])
            let expectedRed = Float(faceIndex) / Float(faceCount - 1)
            #expect(abs(bodyAfter.triangleStyles[tri].color.x - expectedRed) < 0.001)
            #expect(bodyAfter.triangleStyles[tri].color.w == 1, "fully opaque, per the design")
        }

        #expect(service.scalarField(forBody: "box") != nil)

        // Clearing removes every style.
        service.setScalarField(nil, forBody: "box")
        guard let bodyCleared = service.modelBodies.first(where: { $0.id == "box" }) else {
            Issue.record("expected a model body for \"box\" after clearing")
            return
        }
        #expect(bodyCleared.triangleStyles.isEmpty)
        #expect(service.scalarField(forBody: "box") == nil)
    }

    /// Regression for #30: a per-triangle field paints directly by triangle index, not by
    /// face: two triangles on the SAME face can carry different values.
    @MainActor
    @Test("setScalarField(_:forBody:) paints per-triangle values directly by triangle index")
    func scalarFieldPerTrianglePaintsDirectly() {
        guard let box = Shape.box(width: 10, height: 8, depth: 6) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(box, id: "box")

        guard let body = service.modelBodies.first(where: { $0.id == "box" }) else {
            Issue.record("expected a model body for \"box\"")
            return
        }
        let triCount = body.indices.count / 3
        let values = (0..<triCount).map { Double($0) }
        let field = ScalarField(
            domain: .perTriangle,
            values: values,
            colorMap: .viridis,
            label: "per-triangle test"
        )
        service.setScalarField(field, forBody: "box")

        guard let bodyAfter = service.modelBodies.first(where: { $0.id == "box" }) else {
            Issue.record("expected a model body for \"box\" after setScalarField")
            return
        }
        // Two triangles on the same face (ordinal 0 and 1, typically the same face for a
        // box mesh) must NOT necessarily share a color under a per-triangle field.
        #expect(
            bodyAfter.triangleStyles[0].color != bodyAfter.triangleStyles[1].color || triCount < 2)
    }

    /// Regression for #30: `.diverging(center:)` must distinguish signed values about the
    /// center: below-center and above-center map to genuinely different colors (not a
    /// one-ended ramp that treats +2 and -2 the same).
    @MainActor
    @Test("Diverging color map distinguishes signed values about a center")
    func divergingColorMapDistinguishesSignedValues() {
        let colorMap = ColorMap.diverging(center: 0)
        let range = -2.0...2.0

        let below = colorMap.color(for: -2, in: range)
        let center = colorMap.color(for: 0, in: range)
        let above = colorMap.color(for: 2, in: range)

        #expect(below != above, "opposite-signed extremes must not share a color")
        #expect(below != center)
        #expect(above != center)
        // Below center should be blue-leaning (more blue than red); above should be red-leaning.
        #expect(below.z > below.x, "below center should lean blue")
        #expect(above.x > above.z, "above center should lean red")
    }

    /// Regression for #30: `.threshold(levels:)` assigns discrete bands, not a continuous
    /// ramp: two values in the same band must share a color; crossing a level boundary
    /// must change it.
    @MainActor
    @Test("Threshold color map assigns discrete pass/warn/fail bands")
    func thresholdColorMapAssignsDiscreteBands() {
        let colorMap = ColorMap.threshold(levels: [0.5, 1.0])
        let range = 0.0...1.5

        let pass1 = colorMap.color(for: 0.1, in: range)
        let pass2 = colorMap.color(for: 0.4, in: range)
        let warn = colorMap.color(for: 0.7, in: range)
        let fail = colorMap.color(for: 1.2, in: range)

        #expect(pass1 == pass2, "same band must share a color")
        #expect(pass1 != warn)
        #expect(warn != fail)
    }

    /// Regression for #30's acceptance criterion: picking a face reports its scalar value.
    @MainActor
    @Test("Picking a face reports its scalar value from the body's field")
    func pickingFaceReportsScalarValue() {
        guard let box = Shape.box(width: 10, height: 8, depth: 6) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(box, id: "box")

        guard let meta = service.metadata["box"] else {
            Issue.record("expected metadata for \"box\"")
            return
        }
        let faceCount = Set(meta.faceIndices.map { $0 }).count
        let values = (0..<faceCount).map { Double($0) * 1.5 }
        service.setScalarField(
            ScalarField(
                domain: .perFace, values: values, colorMap: .turbo, label: "deviation", unit: "mm"),
            forBody: "box"
        )

        guard let pick = service.resolveFacePick(bodyID: "box", triangleIndex: 0) else {
            Issue.record("resolveFacePick returned nil")
            return
        }
        guard let scalarValue = pick.scalarValue else {
            Issue.record("expected a non-nil scalarValue once a field is set")
            return
        }
        #expect(abs(scalarValue - values[pick.faceIndex]) < 0.001)

        // No field set on a different body -> nil.
        guard let boxB = Shape.box(width: 2, height: 2, depth: 2) else {
            Issue.record("Shape.box returned nil")
            return
        }
        service.load(boxB, id: "boxB")
        guard let pickB = service.resolveFacePick(bodyID: "boxB", triangleIndex: 0) else {
            Issue.record("resolveFacePick returned nil for boxB")
            return
        }
        #expect(pickB.scalarValue == nil)
    }

    /// Regression for #30: `scalarFieldLegend` reports the range, unit, label, and sampled
    /// color stops for the most recently set field.
    @MainActor
    @Test("scalarFieldLegend reports range, unit, and sampled stops")
    func scalarFieldLegendReportsRangeAndStops() {
        guard let box = Shape.box(width: 10, height: 8, depth: 6) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(box, id: "box")

        #expect(service.scalarFieldLegend == nil, "no field set yet")

        let values = [0.0, 1.0, 2.0, -0.5, 0.3, 1.8]
        service.setScalarField(
            ScalarField(
                domain: .perFace, values: values, colorMap: .magma, label: "deviation", unit: "mm"),
            forBody: "box"
        )

        guard let legend = service.scalarFieldLegend else {
            Issue.record("expected a legend once a field is set")
            return
        }
        #expect(legend.label == "deviation")
        #expect(legend.unit == "mm")
        #expect(abs(legend.range.lowerBound - (-0.5)) < 0.001)
        #expect(abs(legend.range.upperBound - 2.0) < 0.001)
        #expect(legend.stops.count == 9)
        #expect(legend.stops.first!.value <= legend.stops.last!.value)

        service.setScalarField(nil, forBody: "box")
        #expect(service.scalarFieldLegend == nil, "clearing the field clears the legend")
    }

    /// Regression for #30 review: removing/replacing a body must drop its stale scalar
    /// field rather than let it silently linger against a body it no longer describes.
    @MainActor
    @Test("Removing a body clears its scalar field and legend reference")
    func removingBodyClearsScalarField() {
        guard let box = Shape.box(width: 4, height: 4, depth: 4) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(box, id: "box")
        service.setScalarField(
            ScalarField(
                domain: .perFace, values: [1, 2, 3, 4, 5, 6], colorMap: .viridis, label: "test"),
            forBody: "box"
        )
        #expect(service.scalarField(forBody: "box") != nil)
        #expect(service.scalarFieldLegend != nil)

        service.remove(id: "box")

        #expect(service.scalarField(forBody: "box") == nil)
        #expect(service.scalarFieldLegend == nil)
    }

    // MARK: - Comparison (#31)

    @Test("ComparisonView and ComparisonMode round-trip through equality")
    func comparisonViewEquality() {
        let a = ComparisonView(
            referenceID: "ref", candidateID: "cand", mode: .wipe(axis: .z, position: 1.5))
        let b = ComparisonView(
            referenceID: "ref", candidateID: "cand", mode: .wipe(axis: .z, position: 1.5))
        let c = ComparisonView(
            referenceID: "ref", candidateID: "cand", mode: .wipe(axis: .z, position: 2.0))
        #expect(a == b)
        #expect(a != c)
    }

    @MainActor
    @Test("setComparison(.overlay) ghosts the reference and restores full opacity on clear")
    func comparisonOverlayGhostsReferenceAndRestores() {
        guard let mesh = Shape.box(width: 4, height: 4, depth: 4),
            let solid = Shape.box(width: 4, height: 4, depth: 4)
        else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(mesh, id: "reference")
        service.load(solid, id: "candidate")
        #expect(service.modelBodies.first { $0.id == "reference" }?.color.w == 1.0)

        service.setComparison(
            ComparisonView(
                referenceID: "reference", candidateID: "candidate",
                mode: .overlay(referenceOpacity: 0.3)))
        #expect(service.comparison?.mode == .overlay(referenceOpacity: 0.3))
        #expect(service.modelBodies.first { $0.id == "reference" }?.color.w == 0.3)
        #expect(
            service.modelBodies.first { $0.id == "candidate" }?.color.w == 1.0,
            "candidate is untouched by overlay")

        service.setComparison(nil)
        #expect(service.comparison == nil)
        #expect(service.modelBodies.first { $0.id == "reference" }?.color.w == 1.0)
    }

    @MainActor
    @Test("overlay referenceOpacity is clamped to 0...1")
    func comparisonOverlayClampsOpacity() {
        guard let mesh = Shape.box(width: 2, height: 2, depth: 2),
            let solid = Shape.box(width: 2, height: 2, depth: 2)
        else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(mesh, id: "reference")
        service.load(solid, id: "candidate")

        service.setComparison(
            ComparisonView(
                referenceID: "reference", candidateID: "candidate",
                mode: .overlay(referenceOpacity: 5)))
        #expect(service.modelBodies.first { $0.id == "reference" }?.color.w == 1.0)

        service.setComparison(
            ComparisonView(
                referenceID: "reference", candidateID: "candidate",
                mode: .overlay(referenceOpacity: -3)))
        #expect(service.modelBodies.first { $0.id == "reference" }?.color.w == 0.0)
    }

    @MainActor
    @Test("setComparison(.sideBySide) offsets the candidate away from the reference along X")
    func comparisonSideBySideOffsetsCandidate() {
        guard let mesh = Shape.box(width: 4, height: 4, depth: 4),
            let solid = Shape.box(width: 2, height: 2, depth: 2)
        else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(mesh, id: "reference")
        service.load(solid, id: "candidate")

        service.setComparison(
            ComparisonView(referenceID: "reference", candidateID: "candidate", mode: .sideBySide))

        guard let candidateBody = service.modelBodies.first(where: { $0.id == "candidate" }) else {
            Issue.record("expected candidate body")
            return
        }
        // Shape.box centers its box at the origin: reference (width 4) bounds -2...2,
        // candidate (width 2) bounds -1...1. Gap is 15% of the larger size (4 * 0.15 = 0.6),
        // so candidate should be pushed so its min.x lands at reference's max.x + gap = 2.6,
        // i.e. translated by 2.6 - (-1) = 3.6.
        #expect(abs(candidateBody.transform.columns.3.x - 3.6) < 0.01)
        #expect(
            service.modelBodies.first { $0.id == "reference" }?.transform
                == matrix_identity_float4x4, "reference itself is untouched")

        service.setComparison(nil)
        #expect(
            service.modelBodies.first { $0.id == "candidate" }?.transform
                == matrix_identity_float4x4)
    }

    @MainActor
    @Test(
        "setComparison(.wipe) keeps reference triangles below the plane and candidate triangles above it"
    )
    func comparisonWipeSplitsTrianglesByPlane() {
        guard let mesh = Shape.box(width: 4, height: 4, depth: 4),
            let solid = Shape.box(width: 4, height: 4, depth: 4)
        else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(mesh, id: "reference")
        service.load(solid, id: "candidate")

        guard let originalReference = service.modelBodies.first(where: { $0.id == "reference" })
        else {
            Issue.record("expected reference body")
            return
        }
        let originalTriangleCount = originalReference.indices.count / 3
        #expect(originalTriangleCount > 0)

        // Shape.box centers its box at the origin, so position: 0 splits it through the middle.
        service.setComparison(
            ComparisonView(
                referenceID: "reference", candidateID: "candidate",
                mode: .wipe(axis: .x, position: 0)))

        guard let wipedReference = service.modelBodies.first(where: { $0.id == "reference" }),
            let wipedCandidate = service.modelBodies.first(where: { $0.id == "candidate" })
        else {
            Issue.record("expected both bodies after wipe")
            return
        }

        func triangleCentroidXs(of body: _ViewportBody) -> [Float] {
            let triCount = body.indices.count / 3
            return (0..<triCount).map { tri -> Float in
                let i0 = Int(body.indices[tri * 3])
                let i1 = Int(body.indices[tri * 3 + 1])
                let i2 = Int(body.indices[tri * 3 + 2])
                let x0 = body.vertexData[i0 * 6]
                let x1 = body.vertexData[i1 * 6]
                let x2 = body.vertexData[i2 * 6]
                return (x0 + x1 + x2) / 3
            }
        }

        let referenceXs = triangleCentroidXs(of: wipedReference)
        let candidateXs = triangleCentroidXs(of: wipedCandidate)
        #expect(!referenceXs.isEmpty)
        #expect(!candidateXs.isEmpty)
        #expect(
            referenceXs.allSatisfy { $0 < 0 }, "reference keeps only triangles below the wipe plane"
        )
        #expect(
            candidateXs.allSatisfy { $0 >= 0 },
            "candidate keeps only triangles at/above the wipe plane")
        #expect(referenceXs.count < originalTriangleCount, "some triangles were filtered out")
        #expect(candidateXs.count < originalTriangleCount, "some triangles were filtered out")
        #expect(wipedReference.triangleStyles.isEmpty, "neither box had a scalar field set")

        service.setComparison(nil)
        #expect(
            service.modelBodies.first { $0.id == "reference" }?.indices.count
                == originalReference.indices.count,
            "clearing restores the original, unfiltered geometry")
    }

    @MainActor
    @Test(
        "setComparison(.deviation) is a marker only; clearing it clears the candidate's scalar field"
    )
    func comparisonDeviationClearsScalarFieldOnUndo() {
        guard let mesh = Shape.box(width: 4, height: 4, depth: 4),
            let solid = Shape.box(width: 4, height: 4, depth: 4)
        else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(mesh, id: "reference")
        service.load(solid, id: "candidate")

        service.setScalarField(
            ScalarField(
                domain: .perFace, values: [1, 2, 3, 4, 5, 6], colorMap: .viridis, label: "deviation"
            ),
            forBody: "candidate"
        )
        service.setComparison(
            ComparisonView(referenceID: "reference", candidateID: "candidate", mode: .deviation))
        #expect(service.comparison?.mode == .deviation)
        #expect(
            service.scalarField(forBody: "candidate") != nil,
            "deviation doesn't touch the field the caller already set")

        service.setComparison(nil)
        #expect(
            service.scalarField(forBody: "candidate") == nil,
            "clearing a deviation comparison clears the candidate's field")
    }

    @MainActor
    @Test("Switching comparison modes undoes the previous mode before applying the new one")
    func comparisonSwitchingModesUndoesPrevious() {
        guard let mesh = Shape.box(width: 4, height: 4, depth: 4),
            let solid = Shape.box(width: 4, height: 4, depth: 4)
        else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(mesh, id: "reference")
        service.load(solid, id: "candidate")

        service.setComparison(
            ComparisonView(
                referenceID: "reference", candidateID: "candidate",
                mode: .overlay(referenceOpacity: 0.2)))
        #expect(service.modelBodies.first { $0.id == "reference" }?.color.w == 0.2)

        service.setComparison(
            ComparisonView(referenceID: "reference", candidateID: "candidate", mode: .sideBySide))
        #expect(
            service.modelBodies.first { $0.id == "reference" }?.color.w == 1.0,
            "overlay's opacity change must be undone before sideBySide applies")
        #expect(
            (service.modelBodies.first { $0.id == "candidate" }?.transform.columns.3.x ?? 0) > 0,
            "sideBySide should have offset the candidate")
    }

    @MainActor
    @Test("Removing an entity referenced by the active comparison clears it")
    func comparisonClearedWhenReferencedEntityRemoved() {
        guard let mesh = Shape.box(width: 4, height: 4, depth: 4),
            let solid = Shape.box(width: 4, height: 4, depth: 4)
        else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(mesh, id: "reference")
        service.load(solid, id: "candidate")
        service.setComparison(
            ComparisonView(
                referenceID: "reference", candidateID: "candidate",
                mode: .overlay(referenceOpacity: 0.5)))
        #expect(service.comparison != nil)

        service.remove(id: "candidate")
        #expect(service.comparison == nil)
    }

    /// Regression for an adversarial-review finding on this PR: removing (or reloading,
    /// which internally removes-then-re-adds) one side of an active comparison must restore
    /// the OTHER, surviving side's mutated body, not just clear `comparison` and leave that
    /// body permanently ghosted.
    ///
    /// An earlier version of `pruneComparison` dropped `comparisonBackup` outright instead
    /// of restoring from it first.
    @MainActor
    @Test("Removing one side of an active overlay comparison restores the surviving side's opacity")
    func comparisonRemovingOneSideRestoresSurvivingOverlay() {
        guard let mesh = Shape.box(width: 4, height: 4, depth: 4),
            let solid = Shape.box(width: 4, height: 4, depth: 4)
        else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(mesh, id: "reference")
        service.load(solid, id: "candidate")

        // .overlay only mutates the reference; removing the untouched candidate must still
        // restore the reference, not just clear `comparison`.
        service.setComparison(
            ComparisonView(
                referenceID: "reference", candidateID: "candidate",
                mode: .overlay(referenceOpacity: 0.3)))
        #expect(service.modelBodies.first { $0.id == "reference" }?.color.w == 0.3)

        service.remove(id: "candidate")

        #expect(service.comparison == nil)
        #expect(
            service.modelBodies.first { $0.id == "reference" }?.color.w == 1.0,
            "the surviving reference must be un-ghosted, not stuck at the comparison's opacity")
    }

    @MainActor
    @Test(
        "Removing one side of an active wipe restores the surviving side's full, unfiltered geometry"
    )
    func comparisonRemovingOneSideRestoresSurvivingWipeGeometry() {
        guard let mesh = Shape.box(width: 4, height: 4, depth: 4),
            let solid = Shape.box(width: 4, height: 4, depth: 4)
        else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(mesh, id: "reference")
        service.load(solid, id: "candidate")

        guard
            let originalCandidateTriangleCount = service.modelBodies.first(where: {
                $0.id == "candidate"
            })?.indices.count
        else {
            Issue.record("expected candidate body")
            return
        }

        service.setComparison(
            ComparisonView(
                referenceID: "reference", candidateID: "candidate",
                mode: .wipe(axis: .x, position: 0)))
        let candidateAfterWipe = service.modelBodies.first { $0.id == "candidate" }?.indices.count
        #expect(
            candidateAfterWipe != nil && candidateAfterWipe! < originalCandidateTriangleCount,
            "sanity check: wipe actually filtered the candidate")

        service.remove(id: "reference")

        #expect(service.comparison == nil)
        #expect(
            service.modelBodies.first { $0.id == "candidate" }?.indices.count
                == originalCandidateTriangleCount,
            "the surviving candidate must have its full, unfiltered geometry back, not stay wipe-filtered forever"
        )
    }

    /// Regression for an adversarial-review finding on this PR: `applySideBySide` used to
    /// compute its offset from `shape(id:)`, which deliberately returns only the FIRST
    /// body's shape of an entity, fine for the "roughly frame the camera" use in
    /// `focus(on:)`, but wrong for an offset that has to clear every body of a multi-body
    /// entity.
    ///
    /// Constructs a synthetic two-body "candidate" entity (this package's tests don't ship
    /// a multi-body file on disk) via the internal `entities`/`Entity`/`installIdentity`
    /// test seams.
    @MainActor
    @Test("applySideBySide accounts for every body of a multi-body entity, not just the first")
    func comparisonSideBySideAccountsForMultiBodyEntity() {
        guard let referenceBox = Shape.box(width: 2, height: 2, depth: 2),
            let candidateNear = Shape.box(width: 2, height: 2, depth: 2),
            let candidateFarUnplaced = Shape.box(width: 2, height: 2, depth: 2)
        else {
            Issue.record("Shape.box returned nil")
            return
        }
        guard
            let candidateFar = candidateFarUnplaced.transformed(matrix: [
                1, 0, 0,
                0, 1, 0,
                0, 0, 1,
                20, 0, 0,
            ])
        else {
            Issue.record("Shape.transformed returned nil")
            return
        }

        let service = CADViewportService()
        service.load(referenceBox, id: "reference")

        let candidateNearBody = _ViewportBody(
            id: "candidate-0", vertexData: [0, 0, 0, 0, 0, 1], indices: [0], edges: [],
            color: SIMD4<Float>(0.7, 0.7, 0.75, 1.0)
        )
        let candidateFarBody = _ViewportBody(
            id: "candidate-1", vertexData: [20, 0, 0, 0, 0, 1], indices: [0], edges: [],
            color: SIMD4<Float>(0.7, 0.7, 0.75, 1.0)
        )
        service.modelBodies.append(candidateNearBody)
        service.modelBodies.append(candidateFarBody)
        service.entities["candidate"] = CADViewportService.Entity(bodyIDs: [
            "candidate-0", "candidate-1",
        ])

        guard service.modelBodies.contains(where: { $0.id == "reference" }) else {
            Issue.record("expected reference body to already be loaded")
            return
        }
        service.installIdentity([
            "reference": ShapeIdentity(shape: referenceBox),
            "candidate-0": ShapeIdentity(shape: candidateNear),
            "candidate-1": ShapeIdentity(shape: candidateFar),
        ])

        service.setComparison(
            ComparisonView(referenceID: "reference", candidateID: "candidate", mode: .sideBySide))

        let nearTransform = service.modelBodies.first { $0.id == "candidate-0" }?.transform
        let farTransform = service.modelBodies.first { $0.id == "candidate-1" }?.transform
        #expect(nearTransform != nil)
        #expect(
            nearTransform?.columns.3.x == farTransform?.columns.3.x,
            "every body of the entity gets the same offset")

        // reference bounds -1...1 (width 2, centered). candidate entity bounds -1...21 (near
        // body -1...1, far body translated to 19...21); union size 22. gap = max(2, 22) * 0.15
        // = 3.3. delta = (referenceMax(1) + gap(3.3)) - candidateMin(-1) = 5.3. If the offset
        // were computed from candidateNear's bounds alone (the bug), it would come out much
        // smaller and candidateFar would stay exactly where it already was, still overlapping
        // nothing useful to compare against.
        #expect(abs((nearTransform?.columns.3.x ?? 0) - 5.3) < 0.01)
    }

    // MARK: - Clipping (#32)

    @Test("ClippingPlane round-trips through equality")
    func clippingPlaneEquality() {
        let a = ClippingPlane(id: "p1", origin: SIMD3(0, 0, 1), normal: SIMD3(0, 0, 1))
        let b = ClippingPlane(id: "p1", origin: SIMD3(0, 0, 1), normal: SIMD3(0, 0, 1))
        let c = ClippingPlane(id: "p1", origin: SIMD3(0, 0, 2), normal: SIMD3(0, 0, 1))
        #expect(a == b)
        #expect(a != c)
    }

    @MainActor
    @Test(
        "addClippingPlane converts origin/normal into the viewport's normal/distance plane equation"
    )
    func clippingPlaneSyncsToController() {
        let service = CADViewportService()
        let id = service.addClippingPlane(
            origin: SIMD3(0, 0, 5), normal: SIMD3(0, 0, 1), showCapSurface: false)

        #expect(service.clippingPlanes.count == 1)
        #expect(service.controller.clipPlanes.count == 1)
        guard let clipPlane = service.controller.clipPlanes.first else {
            Issue.record("expected a synced ClipPlane")
            return
        }
        #expect(abs(clipPlane.normal.z - 1) < 0.001)
        #expect(
            abs(clipPlane.distance - (-5)) < 0.001,
            "dot(normal, origin) + distance = 0 at the plane's own origin")
        #expect(clipPlane.isEnabled)

        service.removeClippingPlane(id: id)
        #expect(service.clippingPlanes.isEmpty)
        #expect(service.controller.clipPlanes.isEmpty)
    }

    @MainActor
    @Test("Multiple clipping planes compose in the viewport's global clip array")
    func clippingPlanesCompose() {
        let service = CADViewportService()
        service.addClippingPlane(origin: .zero, normal: SIMD3(1, 0, 0), showCapSurface: false)
        service.addClippingPlane(origin: .zero, normal: SIMD3(0, 1, 0), showCapSurface: false)
        #expect(service.clippingPlanes.count == 2)
        #expect(service.controller.clipPlanes.count == 2)
    }

    @MainActor
    @Test("sectionSweep moves a single dedicated plane rather than accumulating a new one per call")
    func sectionSweepReusesSamePlane() {
        let service = CADViewportService()
        service.sectionSweep(axis: SIMD3(0, 0, 1), position: 0)
        #expect(service.clippingPlanes.count == 1)
        let firstID = service.clippingPlanes[0].id

        service.sectionSweep(axis: SIMD3(0, 0, 1), position: 5)
        #expect(service.clippingPlanes.count == 1)
        #expect(service.clippingPlanes[0].id == firstID)
        #expect(abs(service.clippingPlanes[0].origin.z - 5) < 0.001)
    }

    @MainActor
    @Test(
        "A showCapSurface: false clipping plane hides geometry but doesn't touch the underlying shape"
    )
    func clippingWithoutCapDoesNotTruncateShape() {
        guard let box = Shape.box(width: 4, height: 4, depth: 4) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(box, id: "box")
        guard let originalBounds = service.shape(id: "box")?.bounds else {
            Issue.record("expected box shape")
            return
        }

        service.addClippingPlane(origin: .zero, normal: SIMD3(1, 0, 0), showCapSurface: false)

        guard let boundsAfter = service.shape(id: "box")?.bounds else {
            Issue.record("expected box shape after adding a non-capping plane")
            return
        }
        #expect(
            abs(boundsAfter.min.x - originalBounds.min.x) < 0.001,
            "a hollow clip must not modify the underlying shape")
        #expect(abs(boundsAfter.max.x - originalBounds.max.x) < 0.001)
    }

    @MainActor
    @Test("A cap-enabled clipping plane truncates the body's actual geometry, not just a GPU clip")
    func clippingCapSurfaceTruncatesGeometry() {
        guard let box = Shape.box(width: 4, height: 4, depth: 4) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(box, id: "box")

        guard let originalBounds = service.shape(id: "box")?.bounds else {
            Issue.record("expected box shape")
            return
        }
        #expect(abs(originalBounds.min.x - (-2)) < 0.01)
        #expect(abs(originalBounds.max.x - 2) < 0.01)

        let planeID = service.addClippingPlane(
            origin: SIMD3(0, 0, 0), normal: SIMD3(1, 0, 0), showCapSurface: true)
        #expect(service.clippingPlanes.contains { $0.id == planeID })

        guard let cappedBounds = service.shape(id: "box")?.bounds else {
            Issue.record("expected box shape after capping")
            return
        }
        #expect(cappedBounds.min.x > -0.5, "the negative-X half should have been cut away")
        #expect(abs(cappedBounds.max.x - 2) < 0.01, "the kept side's extent is unchanged")

        service.removeClippingPlane(id: planeID)
        guard let restoredBounds = service.shape(id: "box")?.bounds else {
            Issue.record("expected box shape after removing the plane")
            return
        }
        #expect(
            abs(restoredBounds.min.x - (-2)) < 0.01,
            "removing the plane restores the original geometry")
    }

    @MainActor
    @Test(
        "Face picking on a clipped-away region returns nil even though the GPU pick pass doesn't itself respect clip planes"
    )
    func clippingHidesPicksOnClippedGeometry() {
        guard let box = Shape.box(width: 4, height: 4, depth: 4) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(box, id: "box")

        guard let body = service.modelBodies.first(where: { $0.id == "box" }) else {
            Issue.record("expected box body")
            return
        }
        let triCount = body.indices.count / 3
        var negativeXTriangle: Int?
        var positiveXTriangle: Int?
        for tri in 0..<triCount {
            let i0 = Int(body.indices[tri * 3])
            let i1 = Int(body.indices[tri * 3 + 1])
            let i2 = Int(body.indices[tri * 3 + 2])
            let x =
                (body.vertexData[i0 * 6] + body.vertexData[i1 * 6] + body.vertexData[i2 * 6]) / 3
            if x < -0.1 && negativeXTriangle == nil { negativeXTriangle = tri }
            if x > 0.1 && positiveXTriangle == nil { positiveXTriangle = tri }
        }
        guard let negTri = negativeXTriangle, let posTri = positiveXTriangle else {
            Issue.record("expected triangles on both sides of X=0")
            return
        }

        // Before clipping, both resolve.
        #expect(service.resolveFacePick(bodyID: "box", triangleIndex: negTri) != nil)
        #expect(service.resolveFacePick(bodyID: "box", triangleIndex: posTri) != nil)

        // A hollow (non-capping) clip leaves the tessellation untouched: same triangle
        // indices mean the same thing before and after; only the GPU (visually) and now
        // resolveFacePick (for picking) hide the negative-X side.
        service.addClippingPlane(origin: .zero, normal: SIMD3(1, 0, 0), showCapSurface: false)

        #expect(
            service.resolveFacePick(bodyID: "box", triangleIndex: negTri) == nil,
            "clipped-away geometry must not be pickable")
        #expect(
            service.resolveFacePick(bodyID: "box", triangleIndex: posTri) != nil,
            "the kept side stays pickable")
    }

    @MainActor
    @Test("Clearing a comparison preserves an independently active cap-enabled clipping plane")
    func clearingComparisonPreservesActiveCap() {
        guard let mesh = Shape.box(width: 4, height: 4, depth: 4),
            let solid = Shape.box(width: 4, height: 4, depth: 4)
        else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(mesh, id: "reference")
        service.load(solid, id: "candidate")

        service.addClippingPlane(origin: .zero, normal: SIMD3(1, 0, 0), showCapSurface: true)

        guard let cappedReferenceBounds = service.shape(id: "reference")?.bounds else {
            Issue.record("expected reference shape")
            return
        }
        #expect(
            cappedReferenceBounds.min.x > -0.5,
            "sanity check: capping actually truncated the reference")

        service.setComparison(
            ComparisonView(
                referenceID: "reference", candidateID: "candidate",
                mode: .overlay(referenceOpacity: 0.3)))
        #expect(service.modelBodies.first { $0.id == "reference" }?.color.w == 0.3)

        service.setComparison(nil)

        #expect(
            service.modelBodies.first { $0.id == "reference" }?.color.w == 1.0,
            "overlay must be undone")
        guard let stillCappedBounds = service.shape(id: "reference")?.bounds else {
            Issue.record("expected reference shape after clearing the comparison")
            return
        }
        #expect(
            stillCappedBounds.min.x > -0.5,
            "the cap must still be applied after the comparison clears")
    }

    /// Regression for #44: reloading an entity under an id already in use goes through the
    /// same loader (`load(_:id:transform:)` calls `remove(id:)` then re-adds), which now ends
    /// in `updateCapSurfaces()` rather than a bare `rebuildBodies()`, so a reload picks up an
    /// already-active cap immediately too, with no manual `clippingPlanes` re-set needed.
    @MainActor
    @Test(
        "Reloading a different shape under the same id picks up an already-active cap immediately")
    func clippingCapRefreshesAutomaticallyOnReload() {
        guard let bigBox = Shape.box(width: 4, height: 4, depth: 4),
            let smallBox = Shape.box(width: 2, height: 2, depth: 2)
        else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(bigBox, id: "part")
        service.addClippingPlane(origin: .zero, normal: SIMD3(1, 0, 0), showCapSurface: true)

        guard let firstCapped = service.shape(id: "part")?.bounds else {
            Issue.record("expected capped bounds")
            return
        }
        #expect(abs(firstCapped.max.x - 2) < 0.01, "bigBox's half-width")

        // Reload under the same id, different geometry: no further clipping-plane call.
        service.load(smallBox, id: "part")

        guard let secondCapped = service.shape(id: "part")?.bounds else {
            Issue.record("expected capped bounds after reload")
            return
        }
        #expect(
            abs(secondCapped.max.x - 1) < 0.01,
            "capping should reflect the NEW (small) box, immediately, not the stale cached one")
    }

    /// Regression for an adversarial-review finding on this PR: `updateCapSurfaces` used to
    /// retessellate (and mint a fresh `BRepGraph` for) EVERY loaded body whenever any
    /// cap-enabled plane existed, not just the ones a plane actually cuts through, silently
    /// invalidating durable `GraphUID`s for bodies nowhere near any plane.
    @MainActor
    @Test("A cap-enabled clipping plane doesn't disturb an unrelated body's durable identity")
    func cappingDoesNotDisturbUnrelatedBodyIdentity() {
        guard let nearBox = Shape.box(width: 4, height: 4, depth: 4),
            let farBox = Shape.box(width: 4, height: 4, depth: 4)
        else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(nearBox, id: "near")
        service.load(
            farBox, id: "far",
            transform: [
                1, 0, 0,
                0, 1, 0,
                0, 0, 1,
                100, 0, 0,
            ])

        guard let farBodyBefore = service.modelBodies.first(where: { $0.id == "far" }) else {
            Issue.record("expected far body")
            return
        }
        guard let pickBefore = service.resolveFacePick(bodyID: "far", triangleIndex: 0),
            let uidBefore = pickBefore.uid
        else {
            Issue.record("expected a durable identity pick on the far body")
            return
        }

        // A plane at x=0, normal +x only intersects "near" (bounds -2...2); "far" (translated
        // to ~98...102) is entirely on the kept side and should be left completely untouched.
        service.addClippingPlane(origin: .zero, normal: SIMD3(1, 0, 0), showCapSurface: true)

        let farBodyAfter = service.modelBodies.first(where: { $0.id == "far" })
        #expect(
            farBodyAfter?.generation == farBodyBefore.generation,
            "an untouched body must not be retessellated at all")

        guard let pickAfter = service.resolveFacePick(bodyID: "far", triangleIndex: 0),
            let uidAfter = pickAfter.uid
        else {
            Issue.record("expected a durable identity pick on the far body after capping")
            return
        }
        #expect(
            uidAfter == uidBefore,
            "an unrelated body's durable identity must survive a clipping-plane change")
    }

    /// Regression for an adversarial-review finding on this PR: the own restore-then-recompute
    /// of `updateCapSurfaces` used to ignore an independently active comparison, so a SECOND,
    /// unrelated clipping-plane mutation (moving the plane, adding another one, etc.) would
    /// silently discard whatever `.overlay`/`.sideBySide`/`.wipe` had done to a body that also
    /// happened to be capped.
    @MainActor
    @Test(
        "A second, unrelated clipping-plane mutation doesn't discard an active overlay comparison")
    func secondClippingMutationPreservesActiveOverlayComparison() {
        guard let mesh = Shape.box(width: 4, height: 4, depth: 4),
            let solid = Shape.box(width: 4, height: 4, depth: 4)
        else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(mesh, id: "reference")
        service.load(solid, id: "candidate")

        let planeID = service.addClippingPlane(
            origin: .zero, normal: SIMD3(1, 0, 0), showCapSurface: true)
        service.setComparison(
            ComparisonView(
                referenceID: "reference", candidateID: "candidate",
                mode: .overlay(referenceOpacity: 0.3)))
        #expect(service.modelBodies.first { $0.id == "reference" }?.color.w == 0.3)

        // A SECOND, independent clipping-plane mutation (moving the same plane).
        service.clippingPlanes = service.clippingPlanes.map { plane in
            var moved = plane
            if moved.id == planeID { moved.origin = SIMD3(0.5, 0, 0) }
            return moved
        }

        #expect(service.comparison != nil, "the comparison itself must still be reported as active")
        #expect(
            service.modelBodies.first { $0.id == "reference" }?.color.w == 0.3,
            "the ghosting must survive an unrelated clipping-plane change")
        guard let stillCappedBounds = service.shape(id: "reference")?.bounds else {
            Issue.record("expected reference shape")
            return
        }
        #expect(
            stillCappedBounds.min.x > 0.3, "the moved plane should still be capping the reference")
    }

    @MainActor
    @Test("A second clipping-plane mutation doesn't compound a sideBySide comparison's offset")
    func secondClippingMutationDoesNotCompoundSideBySideOffset() {
        guard let mesh = Shape.box(width: 4, height: 4, depth: 4),
            let solid = Shape.box(width: 4, height: 4, depth: 4)
        else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(mesh, id: "reference")
        service.load(solid, id: "candidate")

        // Hollow (non-capping) planes on axes that don't touch either box's own geometry:
        // isolates the test to whether the OFFSET ITSELF compounds, rather than a plane that
        // (correctly) changes reference/candidate's bounds and so legitimately changes the
        // recomputed offset.
        service.addClippingPlane(
            origin: SIMD3(0, 0, 100), normal: SIMD3(0, 0, 1), showCapSurface: false)
        service.setComparison(
            ComparisonView(referenceID: "reference", candidateID: "candidate", mode: .sideBySide))
        let firstOffset = service.modelBodies.first { $0.id == "candidate" }?.transform.columns.3.x

        service.addClippingPlane(
            origin: SIMD3(0, 100, 0), normal: SIMD3(0, 1, 0), showCapSurface: false)

        let secondOffset = service.modelBodies.first { $0.id == "candidate" }?.transform.columns.3.x
        #expect(firstOffset != nil && secondOffset != nil)
        #expect(
            abs((secondOffset ?? 0) - (firstOffset ?? 0)) < 0.01,
            "the sideBySide offset must not compound across an unrelated clipping-plane change")
    }

    /// Regression for an adversarial-review finding on this PR: `replaceBody` used to preserve
    /// every caller-configurable field except the scalar field, so a genuinely re-cut body
    /// kept reporting its OLD `ScalarField` even though the new tessellation's face/triangle
    /// ordinals have no defined correspondence to the old ones.
    @MainActor
    @Test(
        "Capping a body with an active scalar field clears the (now-mismatched) field rather than painting stale values"
    )
    func cappingClearsScalarFieldOnGenuinelyCutBody() {
        guard let box = Shape.box(width: 4, height: 4, depth: 4) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(box, id: "box")
        service.setScalarField(
            ScalarField(
                domain: .perFace, values: [1, 2, 3, 4, 5, 6], colorMap: .viridis, label: "test"),
            forBody: "box"
        )
        #expect(service.scalarField(forBody: "box") != nil)

        service.addClippingPlane(origin: .zero, normal: SIMD3(1, 0, 0), showCapSurface: true)

        #expect(
            service.scalarField(forBody: "box") == nil,
            "the field's ordinals no longer correspond to the new (cut) tessellation")
    }

    // MARK: - Escalation (#33)

    private func makeFacePick(bodyID: String, faceIndex: Int = 0) -> PickedEntity? {
        guard let box = Shape.box(width: 4, height: 4, depth: 4) else { return nil }
        let bounds = FaceBounds(minX: 0, maxX: 4, minY: 0, maxY: 4)
        return .face(
            PickedFaceInfo(
                shape: box,
                uid: nil,
                faceIndex: faceIndex,
                bodyID: bodyID,
                isHorizontal: true,
                isVertical: false,
                bounds: bounds,
                zLevel: 0,
                area: 16,
                description: "test face"
            ))
    }

    @Test("EscalationRequest/EscalationCandidate/EscalationResponse round-trip through equality")
    func escalationValueTypesEquality() {
        guard let entity = makeFacePick(bodyID: "box") else {
            Issue.record("Shape.box returned nil")
            return
        }
        let a = EscalationRequest(
            id: "req1", entities: [entity], question: "Through-hole or blind pocket?",
            candidates: [
                EscalationCandidate(id: "through", label: "Through-hole"),
                EscalationCandidate(id: "blind", label: "Blind pocket"),
            ])
        let b = EscalationRequest(
            id: "req1", entities: [entity], question: "Through-hole or blind pocket?",
            candidates: [
                EscalationCandidate(id: "through", label: "Through-hole"),
                EscalationCandidate(id: "blind", label: "Blind pocket"),
            ])
        let c = EscalationRequest(
            id: "req2", entities: [entity], question: "Through-hole or blind pocket?")
        #expect(a == b)
        #expect(a != c)

        #expect(EscalationResponse.chose(candidateID: "through") == .chose(candidateID: "through"))
        #expect(EscalationResponse.chose(candidateID: "through") != .chose(candidateID: "blind"))
        #expect(EscalationResponse.deferred == .deferred)
        #expect(EscalationResponse.rejected(reason: "no") == .rejected(reason: "no"))
        #expect(EscalationResponse.rejected(reason: "no") != .rejected(reason: nil))
    }

    @MainActor
    @Test("present highlights the request's entities and awaits a response")
    func presentHighlightsEntitiesAndAwaitsResponse() async {
        guard let box = Shape.box(width: 4, height: 4, depth: 4),
            let entity = makeFacePick(bodyID: "box")
        else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(box, id: "box")

        let request = EscalationRequest(
            id: "req1",
            entities: [entity],
            question: "Through-hole or blind pocket?",
            candidates: [
                EscalationCandidate(id: "through", label: "Through-hole"),
                EscalationCandidate(id: "blind", label: "Blind pocket"),
            ]
        )

        let responseTask = Task { @MainActor in await service.present(request) }
        await Task.yield()

        #expect(service.pendingEscalation?.id == "req1")
        #expect(service.selection == [entity])

        service.respond(.chose(candidateID: "through"))
        let response = await responseTask.value

        #expect(response == .chose(candidateID: "through"))
        #expect(service.pendingEscalation == nil)
    }

    @MainActor
    @Test("present highlights every entity in a multi-entity request, in order")
    func presentHighlightsMultipleEntities() async {
        guard let box = Shape.box(width: 4, height: 4, depth: 4),
            let entityA = makeFacePick(bodyID: "box", faceIndex: 0),
            let entityB = makeFacePick(bodyID: "box", faceIndex: 1)
        else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(box, id: "box")

        let request = EscalationRequest(
            id: "req1", entities: [entityA, entityB], question: "Which of these is correct?")
        let responseTask = Task { @MainActor in await service.present(request) }
        await Task.yield()

        #expect(service.selection == [entityA, entityB])

        service.respond(.deferred)
        _ = await responseTask.value
    }

    @MainActor
    @Test("respondWithCurrentSelection resolves with whatever is currently selected")
    func respondWithCurrentSelectionUsesSelection() async {
        guard let box = Shape.box(width: 4, height: 4, depth: 4),
            let requestEntity = makeFacePick(bodyID: "box", faceIndex: 0),
            let pickedEntity = makeFacePick(bodyID: "box", faceIndex: 1)
        else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(box, id: "box")

        let request = EscalationRequest(
            id: "req1", entities: [requestEntity], question: "Is this right?")
        let responseTask = Task { @MainActor in await service.present(request) }
        await Task.yield()

        // The human picks something else instead of answering via a candidate.
        service.select(pickedEntity, scheme: .replace)
        service.respondWithCurrentSelection()

        let response = await responseTask.value
        #expect(response == .picked([pickedEntity]))
    }

    @MainActor
    @Test("Presenting a new escalation while one is pending resolves the previous one as deferred")
    func presentingWhilePendingDefersThePrevious() async {
        guard let box = Shape.box(width: 4, height: 4, depth: 4),
            let entity = makeFacePick(bodyID: "box")
        else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(box, id: "box")

        let firstRequest = EscalationRequest(
            id: "first", entities: [entity], question: "First question?")
        let firstResponseTask = Task { @MainActor in await service.present(firstRequest) }
        await Task.yield()

        let secondRequest = EscalationRequest(
            id: "second", entities: [entity], question: "Second question?")
        let secondResponseTask = Task { @MainActor in await service.present(secondRequest) }
        await Task.yield()

        let firstResponse = await firstResponseTask.value
        #expect(
            firstResponse == .deferred,
            "the first request must not be left hanging when a second one is presented")

        service.respond(.deferred)
        let secondResponse = await secondResponseTask.value
        #expect(secondResponse == .deferred)
        #expect(service.pendingEscalation == nil)
    }

    /// Regression for an adversarial-review finding on this PR: `present(_:)` didn't respond
    /// to the awaiting `Task` being cancelled, the real, common case of a SwiftUI `.task`
    /// whose view disappears, or an agent racing `present(_:)` against its own timeout.
    ///
    /// Before the fix, cancellation had no effect at all: `pendingEscalation` and the
    /// continuation stayed stuck forever unless something else (a fresh `present(_:)`,
    /// entity removal, `removeAll()`) happened to resolve it later.
    @MainActor
    @Test(
        "Cancelling the awaiting task resolves the pending escalation rather than leaking it",
        .timeLimit(.minutes(1)))
    func cancellingAwaitingTaskResolvesEscalation() async {
        guard let box = Shape.box(width: 4, height: 4, depth: 4),
            let entity = makeFacePick(bodyID: "box")
        else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(box, id: "box")

        let request = EscalationRequest(id: "req1", entities: [entity], question: "Is this right?")
        let responseTask = Task { @MainActor in await service.present(request) }
        await Task.yield()
        #expect(service.pendingEscalation != nil)

        responseTask.cancel()

        let response = await responseTask.value
        #expect(response == .deferred)
        #expect(
            service.pendingEscalation == nil,
            "cancellation must not leave the escalation stuck pending forever")
    }

    @MainActor
    @Test("Removing an entity referenced by a pending escalation auto-resolves it as rejected")
    func removingReferencedEntityRejectsPendingEscalation() async {
        guard let box = Shape.box(width: 4, height: 4, depth: 4),
            let entity = makeFacePick(bodyID: "box")
        else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(box, id: "box")

        let request = EscalationRequest(id: "req1", entities: [entity], question: "Is this right?")
        let responseTask = Task { @MainActor in await service.present(request) }
        await Task.yield()

        service.remove(id: "box")

        let response = await responseTask.value
        #expect(response == .rejected(reason: "referenced geometry was removed"))
        #expect(service.pendingEscalation == nil)
    }

    @MainActor
    @Test("removeAll() auto-resolves a pending escalation as rejected")
    func removeAllRejectsPendingEscalation() async {
        guard let box = Shape.box(width: 4, height: 4, depth: 4),
            let entity = makeFacePick(bodyID: "box")
        else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(box, id: "box")

        let request = EscalationRequest(id: "req1", entities: [entity], question: "Is this right?")
        let responseTask = Task { @MainActor in await service.present(request) }
        await Task.yield()

        service.removeAll()

        let response = await responseTask.value
        #expect(response == .rejected(reason: "referenced geometry was removed"))
    }

    @MainActor
    @Test("present makes a candidate's preview body visible")
    func presentShowsCandidatePreviewBody() async {
        guard let box = Shape.box(width: 4, height: 4, depth: 4),
            let entity = makeFacePick(bodyID: "box")
        else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(box, id: "box")

        let previewBody = _ViewportBody(
            id: "preview.through",
            vertexData: [0, 0, 0, 0, 0, 1],
            indices: [0],
            edges: [],
            color: SIMD4<Float>(0.2, 0.8, 0.2, 1.0),
            isVisible: false
        )
        service.setOverlay(id: "candidatePreviews", bodies: [previewBody])
        // `service.bodies` mirrors `interactiveContext.bodies` asynchronously via a Combine
        // sink (`.receive(on: RunLoop.main)`); read the latter directly for a synchronous
        // check, matching this file's other `interactiveContext.bodies` assertions.
        #expect(
            service.interactiveContext.bodies.first { $0.id == "preview.through" }?.isVisible
                == false)

        let request = EscalationRequest(
            id: "req1",
            entities: [entity],
            question: "Through-hole or blind pocket?",
            candidates: [
                EscalationCandidate(
                    id: "through", label: "Through-hole", previewBodyID: "preview.through")
            ]
        )
        let responseTask = Task { @MainActor in await service.present(request) }
        await Task.yield()

        #expect(
            service.interactiveContext.bodies.first { $0.id == "preview.through" }?.isVisible
                == true)

        service.respond(.deferred)
        _ = await responseTask.value
    }

    // MARK: - Independent-review fixes (#43-#47)

    /// Regression for #43: `scalarFieldLegend` only ever tracked the single most-recently-set
    /// body, going `nil` when THAT body's field cleared even if a different, still-loaded
    /// body has an active field currently painted, contradicting the property's own doc
    /// ("nil if no field is currently set on any body").
    @MainActor
    @Test("scalarFieldLegend falls back to another still-active field rather than going nil")
    func scalarFieldLegendFallsBackToAnotherActiveField() {
        guard let boxA = Shape.box(width: 4, height: 4, depth: 4),
            let boxB = Shape.box(width: 4, height: 4, depth: 4)
        else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(boxA, id: "A")
        service.load(boxB, id: "B")

        let fieldA = ScalarField(
            domain: .perFace, values: [1, 2, 3, 4, 5, 6], colorMap: .viridis, label: "A field")
        let fieldB = ScalarField(
            domain: .perFace, values: [1, 2, 3, 4, 5, 6], colorMap: .viridis, label: "B field")
        service.setScalarField(fieldA, forBody: "A")
        service.setScalarField(fieldB, forBody: "B")
        #expect(service.scalarFieldLegend?.label == "B field")

        // Clearing the NON-last body's field must not disturb the legend at all.
        service.setScalarField(nil, forBody: "A")
        #expect(service.scalarFieldLegend?.label == "B field")

        // Re-establish both, then clear the LAST-set body's field: must fall back to the
        // other still-active field rather than going nil.
        service.setScalarField(fieldA, forBody: "A")
        service.setScalarField(fieldB, forBody: "B")
        service.setScalarField(nil, forBody: "B")
        #expect(
            service.scalarFieldLegend?.label == "A field",
            "must fall back to A's still-active field, not go nil")

        // Clearing the LAST remaining field must still correctly go nil.
        service.setScalarField(nil, forBody: "A")
        #expect(service.scalarFieldLegend == nil)
    }

    /// Regression for #44: none of CADKit's loading entry points applied already-active
    /// clipping planes to newly-loaded geometry: a new entity displayed uncut, or cut but
    /// hollow with no cap surface, until some unrelated later clip-plane change happened to
    /// trigger the sync.
    @MainActor
    @Test("A newly-loaded entity picks up an already-active cap-enabled clipping plane immediately")
    func newlyLoadedEntityPicksUpActiveCapImmediately() {
        guard let firstBox = Shape.box(width: 4, height: 4, depth: 4),
            let secondBox = Shape.box(width: 4, height: 4, depth: 4)
        else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(firstBox, id: "first")
        service.addClippingPlane(origin: .zero, normal: SIMD3(1, 0, 0), showCapSurface: true)

        guard let firstCapped = service.shape(id: "first")?.bounds else {
            Issue.record("expected capped bounds")
            return
        }
        #expect(firstCapped.min.x > -0.5, "sanity check: the first body is already capped")

        // Load a SECOND entity while the plane is already active: no further clipping call.
        service.load(secondBox, id: "second")

        guard let secondCapped = service.shape(id: "second")?.bounds else {
            Issue.record("expected capped bounds for the newly-loaded entity")
            return
        }
        #expect(
            secondCapped.min.x > -0.5,
            "the newly-loaded entity should be capped immediately, without any further clipping-plane call"
        )
    }

    @MainActor
    @Test(
        "A load into an existing scene picks up an already-active cap immediately"
    )
    func loadIntoExistingScenePicksUpActiveCapImmediately() {
        guard let box = Shape.box(width: 4, height: 4, depth: 4) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.addClippingPlane(origin: .zero, normal: SIMD3(1, 0, 0), showCapSurface: true)

        service.load(box, id: "model")

        guard let capped = service.shape(id: "model")?.bounds else {
            Issue.record("expected capped bounds")
            return
        }
        #expect(capped.min.x > -0.5, "a load should pick up the already-active cap immediately")
    }

    /// Regression for #45: `updateCapSurfaces()` unconditionally restored-then-recapped every
    /// body already tracked as capped on every call, even when that body's relationship to
    /// every plane hadn't changed at all, minting a fresh `BRepGraph`/`GraphUID` (and a
    /// wasted double retessellation) on every unrelated clipping-plane mutation anywhere in
    /// the scene, not just ones that actually affected that body.
    @MainActor
    @Test(
        "An actively-capped body's durable identity and generation survive an unrelated clipping-plane change"
    )
    func activelyCappedBodyIdentitySurvivesUnrelatedUpdate() {
        guard let boxA = Shape.box(width: 4, height: 4, depth: 4),
            let boxB = Shape.box(width: 4, height: 4, depth: 4)
        else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(boxA, id: "A")
        service.addClippingPlane(origin: .zero, normal: SIMD3(1, 0, 0), showCapSurface: true)

        guard let pickBefore = service.resolveFacePick(bodyID: "A", triangleIndex: 0),
            let uidBefore = pickBefore.uid
        else {
            Issue.record("expected a durable identity pick on the capped body")
            return
        }
        let generationBefore = service.modelBodies.first { $0.id == "A" }?.generation

        // An unrelated clipping-plane mutation: a second entity loaded far away, plus a second
        // plane positioned so far below both bodies (kept region z >= -100) that it clips
        // neither away: a plane whose kept half-space simply happens to contain everything,
        // rather than one that would (as any half-space plane far from the geometry it
        // doesn't pass through does on ONE side) hide the whole body instead of leaving it
        // untouched.
        service.load(
            boxB, id: "B",
            transform: [
                1, 0, 0,
                0, 1, 0,
                0, 0, 1,
                100, 0, 0,
            ])
        service.addClippingPlane(
            origin: SIMD3(0, 0, -100), normal: SIMD3(0, 0, 1), showCapSurface: true)

        let generationAfter = service.modelBodies.first { $0.id == "A" }?.generation
        #expect(
            generationAfter == generationBefore,
            "A's cap outcome hasn't changed at all: it must not be rebuilt")

        guard let pickAfter = service.resolveFacePick(bodyID: "A", triangleIndex: 0),
            let uidAfter = pickAfter.uid
        else {
            Issue.record(
                "expected a durable identity pick on the capped body after the unrelated update")
            return
        }
        #expect(
            uidAfter == uidBefore,
            "an actively-capped body's durable identity must survive an unrelated clipping-plane change"
        )
    }

    /// Regression for #46, the most serious finding in this batch: an active `.deviation`
    /// comparison was silently destroyed by ANY unrelated clipping-plane mutation anywhere in
    /// the scene (even one touching no cap planes at all), because `updateCapSurfaces()`
    /// routed `.deviation` through the same destructive undo-then-reapply cycle as the
    /// body-mutating modes, but the "undo" of `.deviation` (`setScalarField(nil, forBody:)`)
    /// has no corresponding restore.
    ///
    /// `comparison?.mode` kept reporting `.deviation` as active even though the candidate's
    /// scalar field had actually been silently cleared.
    @MainActor
    @Test("An active .deviation comparison survives an unrelated clipping-plane mutation")
    func deviationComparisonSurvivesUnrelatedClippingMutation() {
        guard let mesh = Shape.box(width: 4, height: 4, depth: 4),
            let solid = Shape.box(width: 4, height: 4, depth: 4)
        else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(mesh, id: "reference")
        service.load(solid, id: "candidate")

        service.setScalarField(
            ScalarField(
                domain: .perFace, values: [1, 2, 3, 4, 5, 6], colorMap: .viridis, label: "deviation"
            ),
            forBody: "candidate"
        )
        service.setComparison(
            ComparisonView(referenceID: "reference", candidateID: "candidate", mode: .deviation))
        #expect(service.scalarField(forBody: "candidate") != nil)

        // Unrelated clipping-plane mutation: doesn't touch reference/candidate, and isn't
        // even a capping plane; syncClippingPlanes() calls updateCapSurfaces() regardless.
        service.addClippingPlane(
            origin: SIMD3(0, 0, 100), normal: SIMD3(0, 0, 1), showCapSurface: false)

        #expect(
            service.comparison?.mode == .deviation, "the comparison must still report as active")
        #expect(
            service.scalarField(forBody: "candidate") != nil,
            "the deviation field must survive an unrelated clipping-plane change")
    }

    /// Regression for #47: the task-cancellation fix for `present(_:)` (from an earlier
    /// review round on #33) resolved `.deferred` unconditionally from its `onCancel` hop,
    /// with no way to tell whether the escalation it was originally about was still the one
    /// pending.
    ///
    /// A STALE cancellation hop, delayed enough that a newer `present(_:)` call had already
    /// legitimately superseded the one being cancelled, would wrongly resolve the NEWER,
    /// still-pending escalation instead, silently delivering a wrong (but plausible-looking)
    /// answer to whoever was awaiting it, with no crash or hang to signal anything went wrong.
    ///
    /// This exercises the REAL end-to-end cancellation pathway (confirms it doesn't crash or
    /// hang, and that everything still resolves correctly under real `Task` scheduling), but
    /// an adversarial review found it does NOT actually force the specific stale-ordering race
    /// it's named for: the own `onCancel` hop of `present(_:)` reliably finishes before a
    /// newly-spawned superseding `present(_:)` task gets a turn on the same `@MainActor`
    /// serial executor, so this test would pass identically with or without the id-check fix.
    /// `respondIfStillPendingIgnoresSupersededRequestID` below forces the exact scenario
    /// deterministically instead, by calling the guard directly rather than depending on
    /// scheduling timing: that's the test that actually proves the fix.
    @MainActor
    @Test(
        "A stale cancellation for an already-superseded escalation doesn't resolve a newer pending one",
        .timeLimit(.minutes(1)))
    func staleCancellationDoesNotResolveNewerEscalation() async {
        guard let box = Shape.box(width: 4, height: 4, depth: 4),
            let entity = makeFacePick(bodyID: "box")
        else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(box, id: "box")

        let requestA = EscalationRequest(id: "A", entities: [entity], question: "A?")
        let taskA = Task { @MainActor in await service.present(requestA) }
        await Task.yield()
        #expect(service.pendingEscalation?.id == "A")

        taskA.cancel()  // enqueues an onCancel hop for A, but doesn't necessarily run it yet

        // Before that stale hop runs, a NEW request legitimately supersedes A.
        let requestB = EscalationRequest(id: "B", entities: [entity], question: "B?")
        let taskB = Task { @MainActor in await service.present(requestB) }
        await Task.yield()
        #expect(service.pendingEscalation?.id == "B", "B should now be the pending escalation")

        let responseA = await taskA.value
        #expect(responseA == .deferred, "A resolves deferred, superseded by B's present(_:) call")

        // Give A's stale onCancel hop every chance to run, if it hasn't already.
        await Task.yield()
        await Task.yield()
        await Task.yield()

        #expect(
            service.pendingEscalation?.id == "B",
            "B must still be pending: a stale cancellation for A must not resolve B")

        service.respond(.chose(candidateID: "yes"))
        let responseB = await taskB.value
        #expect(
            responseB == .chose(candidateID: "yes"),
            "B must resolve with its own real answer, not a stale .deferred bleeding over from A's cancellation"
        )
    }

    /// Deterministic counterpart to the test above: forces the EXACT stale-hop-after-
    /// supersession scenario directly (via the `internal` `respondIfStillPending`, exposed
    /// for exactly this reason) rather than hoping `Task` cancellation happens to interleave
    /// in the right order, which the scheduling-based test above was found NOT to reliably
    /// force.
    ///
    /// This is the test that actually proves #47's fix does something.
    @MainActor
    @Test("respondIfStillPending is a no-op for a request id that's already been superseded")
    func respondIfStillPendingIgnoresSupersededRequestID() async {
        guard let box = Shape.box(width: 4, height: 4, depth: 4),
            let entity = makeFacePick(bodyID: "box")
        else {
            Issue.record("Shape.box returned nil")
            return
        }
        let service = CADViewportService()
        service.load(box, id: "box")

        let requestA = EscalationRequest(id: "A", entities: [entity], question: "A?")
        let taskA = Task { @MainActor in await service.present(requestA) }
        await Task.yield()
        #expect(service.pendingEscalation?.id == "A")

        // B legitimately supersedes A: present's own guard resolves A .deferred and installs B.
        let requestB = EscalationRequest(id: "B", entities: [entity], question: "B?")
        let taskB = Task { @MainActor in await service.present(requestB) }
        await Task.yield()
        #expect(service.pendingEscalation?.id == "B")
        let responseA = await taskA.value
        #expect(responseA == .deferred)

        // Directly simulate A's cancellation hop firing AFTER it's already been superseded:
        // exactly what present(_:)'s onCancel would produce if it ran late.
        service.respondIfStillPending("A", with: .deferred)
        #expect(
            service.pendingEscalation?.id == "B",
            "a stale hop for the already-superseded A must not touch B")

        service.respond(.chose(candidateID: "yes"))
        let responseB = await taskB.value
        #expect(responseB == .chose(candidateID: "yes"), "B must resolve with its own real answer")
    }

    /// Regression for OCCTSwiftUX#12 / OCCTSwiftCADKit#19 (ecosystem#18), the camera half of
    /// the OCCTSwift#302 multibody ripple.
    ///
    /// `loadFile(from:id:progress:)` registers a multibody file as ONE entity owning N bodies,
    /// and framing used to run off `shape(id:)`, which returns only that entity's first body.
    /// So the camera zoomed to body 0 and the rest of the assembly rendered off screen.
    ///
    /// Asserts the union rather than the camera because `focus(on:)` animates toward the
    /// framing over 0.3s, so `cameraState` read straight afterwards is mid-interpolation.
    ///
    /// Seeds the two-body entity through the internal `entities`/`installIdentity` seams: this
    /// package ships no multi-body file on disk.
    @MainActor
    @Test("Framing spans every body of a multi-body entity, not just the first")
    func framingSpansEveryBodyOfAMultiBodyEntity() {
        guard let near = Shape.box(width: 2, height: 2, depth: 2),
            let farUnplaced = Shape.box(width: 2, height: 2, depth: 2)
        else {
            Issue.record("Shape.box returned nil")
            return
        }
        guard
            let far = farUnplaced.transformed(matrix: [
                1, 0, 0,
                0, 1, 0,
                0, 0, 1,
                20, 0, 0,
            ])
        else {
            Issue.record("Shape.transformed returned nil")
            return
        }
        guard let nearBounds = near.bounds, let farBounds = far.bounds else {
            Issue.record("expected both boxes to have bounds")
            return
        }

        let service = CADViewportService()
        service.modelBodies.append(
            _ViewportBody(
                id: "asm-0", vertexData: [0, 0, 0, 0, 0, 1], indices: [0], edges: [],
                color: SIMD4<Float>(0.7, 0.7, 0.75, 1.0)))
        service.modelBodies.append(
            _ViewportBody(
                id: "asm-1", vertexData: [20, 0, 0, 0, 0, 1], indices: [0], edges: [],
                color: SIMD4<Float>(0.7, 0.7, 0.75, 1.0)))
        service.installIdentity([
            "asm-0": ShapeIdentity(shape: near),
            "asm-1": ShapeIdentity(shape: far),
        ])
        service.entities["asm"] = CADViewportService.Entity(bodyIDs: ["asm-0", "asm-1"])

        guard let box = service.combinedBounds(ofEntities: ["asm"]) else {
            Issue.record("expected a two-body entity to produce bounds")
            return
        }

        #expect(box.min.x == min(nearBounds.min.x, farBounds.min.x))
        #expect(box.max.x == max(nearBounds.max.x, farBounds.max.x))

        // The discriminating pair: framing body 0 alone would stop at its own far face, well
        // short of the second body 20 units away. Both must hold, or the union collapsed back
        // to one body.
        #expect(
            box.max.x > nearBounds.max.x,
            "the union must reach past the first body, or the camera frames body 0 only")
        #expect(
            box.max.x - box.min.x > 20,
            "the span must cover both bodies and the gap between them")
    }

    /// The single-body case is unchanged: one entity with one body frames exactly that body.
    ///
    /// Guards against the multi-body fix widening the common case.
    @MainActor
    @Test("Framing a single-body entity still matches that body's own bounds")
    func framingSingleBodyEntityIsUnchanged() {
        guard let box = Shape.box(width: 4, height: 4, depth: 4), let expected = box.bounds else {
            Issue.record("Shape.box returned nil, or had no bounds")
            return
        }
        let service = CADViewportService()
        service.load(box, id: "solo")

        guard let actual = service.combinedBounds(ofEntities: ["solo"]) else {
            Issue.record("expected a loaded single body to produce bounds")
            return
        }
        // Compared with a tolerance, not for exact equality: `load` tessellates the shape, and
        // the bounding box read afterwards is computed over the triangulation, so it lands
        // within a rounding step of the pre-tessellation one rather than on it. The point of
        // this test is that the single-body case still frames that one body, not that OCCT
        // returns bit-identical doubles either side of a mesh.
        for i in 0..<3 {
            #expect(abs(actual.min[i] - expected.min[i]) < 1e-9)
            #expect(abs(actual.max[i] - expected.max[i]) < 1e-9)
        }

        #expect(
            service.combinedBounds(ofEntities: ["never-loaded"]) == nil,
            "an unloaded id contributes nothing")
    }
}
