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
}
