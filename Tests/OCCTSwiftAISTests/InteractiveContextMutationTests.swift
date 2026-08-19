import OCCTSwift
import OCCTSwiftViewport
import Testing
import simd

@testable import OCCTSwiftAIS

/// Acceptance-criteria coverage for issue #31: `InteractiveContext` retains one
/// `BRepGraph` instance per displayed object across mutations, and durable
/// identity survives shared-face topology that a render-path ordinal alone
/// cannot distinguish.
@MainActor
@Suite("InteractiveContext mutation lifecycle")
struct InteractiveContextMutationTests {

    private func makeContext() -> InteractiveContext {
        InteractiveContext(viewport: ViewportController())
    }

    // MARK: - Living graph persists across repeated update() calls

    @Test func t_update_retainsSameGraphAcrossTwoSuccessiveMutations() throws {
        let base = try #require(Shape.box(origin: SIMD3(0, 0, 0), width: 10, height: 10, depth: 10))
        let ctx = makeContext()
        ctx.selectionMode = [.face]
        var obj = ctx.display(base)

        // Select the bottom face (z=0): neither cut below touches it.
        let faces = base.faces()
        let bottomIndex = try #require(
            facesWithCentroids(of: base).min { $0.centroid.z < $1.centroid.z }?.index)
        let identity0 = try #require(ctx.faceIdentityTable(for: obj))
        let bottomShape = try #require(identity0.shape(forOrdinal: bottomIndex))
        let bottomUID = try #require(identity0.uid(forOrdinal: bottomIndex))
        ctx.select(
            .face(obj, ref: SubShapeRef(shape: bottomShape, uid: bottomUID, ordinal: bottomIndex)))
        #expect(ctx.selection.count == 1)
        _ = faces

        // First mutation: cut a channel across the TOP face.
        let tool1 = try #require(Shape.box(origin: SIMD3(-1, 4, 8), width: 12, height: 2, depth: 4))
        let (result1, history1) = try #require(base.subtractedWithFullHistory(tool1))
        obj = try #require(
            ctx.update(obj, to: result1, absorbing: history1, operationName: "cut-top"))
        #expect(ctx.selection.count == 1, "bottom face untouched by cut-top should survive")
        #expect(ctx.selection.subshapes.allSatisfy { $0.object == obj })

        // Second mutation, chained on the FIRST result: cut a channel across a
        // SIDE face (x=0..10, y=0, z=0..10 face), still not the bottom.
        let tool2 = try #require(
            Shape.box(origin: SIMD3(3, -1, -1), width: 4, height: 2, depth: 12))
        let (result2, history2) = try #require(result1.subtractedWithFullHistory(tool2))
        let updated = try #require(
            ctx.update(obj, to: result2, absorbing: history2, operationName: "cut-side"))

        // Surviving across TWO successive absorbs only works if `update` reused
        // the SAME BRepGraph instance both times: a fresh graph on the
        // second call would reject the first call's uid as foreign (#295) and
        // the selection would silently empty out.
        #expect(ctx.selection.count == 1, "bottom face should survive a second successive mutation")
        #expect(ctx.selection.subshapes.allSatisfy { $0.object == updated })
        if case .face(_, let ref)? = ctx.selection.subshapes.first {
            #expect(ref.uid != nil)
            let resolvedFace: Face? = OCCTSwift.Face(ref.shape)
            let face = try #require(resolvedFace)
            // Bottom face normal should still point roughly along -Z.
            let normal = try #require(face.normal)
            #expect(
                normal.z < -0.9 || normal.z > 0.9,
                "expected the axis-aligned bottom face, got normal \(normal)")
        } else {
            Issue.record("expected a surviving .face sub-shape")
        }
    }

    @Test func t_update_returnsNilForUndisplayedObject() throws {
        let ctx = makeContext()
        let shape = try #require(Shape.box(width: 4, height: 4, depth: 4))
        let obj = InteractiveObject(shape: shape)  // never displayed
        let tool = try #require(Shape.box(width: 1, height: 1, depth: 1))
        let (result, history) = try #require(shape.subtractedWithFullHistory(tool))
        let updated = ctx.update(obj, to: result, absorbing: history, operationName: "noop")
        #expect(updated == nil)
    }

    // MARK: - Shared-face regression (OCCTSwiftTools#42 fixture, consumed end-to-end)

    /// Mirrors OCCTSwiftTools' own `t_sharedFaceBetweenShellsResolvesToOneGraphUID`
    /// fixture (two shells built from a box's faces, one face shared between
    /// them) but drives it through `InteractiveContext.display` + real synthesized
    /// picks rather than calling `FaceIdentityTable` directly: this is the
    /// consumer-side regression #31 calls for: every face pick on a multi-shell
    /// solid with a shared face must resolve to the correct sub-shape, not a
    /// neighbour shifted by the shared face's index collapse.
    @Test func t_sharedFaceBetweenShells_everyPickResolvesToCorrectSubShape() throws {
        let box = try #require(Shape.box(width: 10, height: 10, depth: 10))
        let boxFaces = box.subShapes(ofType: .face)
        #expect(boxFaces.count == 6)
        let sharedFace = boxFaces[0]

        let shellA = try #require(Shape.shellFromFaces([sharedFace, boxFaces[1], boxFaces[2]]))
        let shellB = try #require(
            Shape.shellFromFaces([sharedFace, boxFaces[3], boxFaces[4], boxFaces[5]]))
        let compound = try #require(Shape.compound([shellA, shellB]))

        // Raw render-path traversal counts the shared face once per shell (7);
        // `subShapes(ofType:)` collapses it to 6: the exact divergence #42/#31
        // are about. FaceIdentityTable.shapes is built from the former.
        #expect(compound.faces().count == 7)
        #expect(compound.subShapes(ofType: .face).count == 6)

        let ctx = makeContext()
        ctx.selectionMode = [.face]
        let obj = ctx.display(compound)
        let identity = try #require(ctx.faceIdentityTable(for: obj))
        #expect(identity.shapes.count == 7)

        // Ordinal 0 (shellA's copy) and ordinal 3 (shellB's copy, right after
        // shellA's 3 faces) must carry the SAME durable uid.
        let uid0 = try #require(identity.uid(forOrdinal: 0))
        let uid3 = try #require(identity.uid(forOrdinal: 3))
        #expect(uid0 == uid3)
        // Sanity: the equality above isn't vacuous, an unshared ordinal differs.
        let uid1 = try #require(identity.uid(forOrdinal: 1))
        #expect(uid1 != uid0)

        // Drive it through the real pick path for EVERY ordinal: each must
        // resolve to a genuine face, and the two shared-face ordinals must
        // resolve to the same uid via `handlePick`, not just via the table.
        let body = try #require(ctx.sourceBody(for: obj))
        #expect(!body.faceIndices.isEmpty)
        var seenOrdinals: Set<Int> = []
        var uidByOrdinal: [Int: BRepGraph.GraphUID] = [:]
        for (triIdx, faceOrdinalRaw) in body.faceIndices.enumerated() {
            let ordinal = Int(faceOrdinalRaw)
            guard ordinal >= 0, !seenOrdinals.contains(ordinal) else { continue }
            seenOrdinals.insert(ordinal)

            let raw = UInt32(triIdx) << 16
            let pick = try #require(PickResult(rawValue: raw, indexMap: [0: body.id]))
            ctx.handlePick(pick)

            guard case .face(let pickedObj, let ref)? = ctx.selection.subshapes.first else {
                Issue.record(
                    "triangle \(triIdx) (ordinal \(ordinal)) should resolve to a .face sub-shape")
                continue
            }
            #expect(pickedObj == obj)
            let resolvedFace: Face? = OCCTSwift.Face(ref.shape)
            #expect(resolvedFace != nil, "ordinal \(ordinal) should resolve to a genuine face")
            uidByOrdinal[ordinal] = ref.uid
        }
        #expect(
            seenOrdinals.count == 7,
            "every one of the 7 render-path ordinals should be reachable by a pick")
        #expect(
            uidByOrdinal[0] != nil && uidByOrdinal[0] == uidByOrdinal[3],
            "picks landing on either shell's copy of the shared face must resolve to the same durable identity"
        )
    }
}
