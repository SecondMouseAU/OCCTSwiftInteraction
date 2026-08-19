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
    /// solid with a shared face must resolve to the correct sub-shape.
    ///
    /// Face identity keys on OCCT's `IsSame` (OCCTSwiftInteraction#1): same TShape,
    /// same Location, orientation may differ. A face shared between two shells is
    /// therefore ONE identity, not two, and `faces()`, deduplicated through
    /// `TopTools_IndexedMapOfShape`, is the enumeration that encodes it. The
    /// contract under test is unchanged by that decision: picks landing on either
    /// shell's copy of the shared face must resolve to the same durable identity,
    /// and neither shell's copy may go missing on the way to the GPU.
    @Test func t_sharedFaceBetweenShells_everyPickResolvesToCorrectSubShape() throws {
        let box = try #require(Shape.box(width: 10, height: 10, depth: 10))
        let boxFaces = box.subShapes(ofType: .face)
        #expect(boxFaces.count == 6)
        let sharedFace = boxFaces[0]

        let shellA = try #require(Shape.shellFromFaces([sharedFace, boxFaces[1], boxFaces[2]]))
        let shellB = try #require(
            Shape.shellFromFaces([sharedFace, boxFaces[3], boxFaces[4], boxFaces[5]]))
        let compound = try #require(Shape.compound([shellA, shellB]))

        // Under `IsSame` the shared face is one face, so both deduplicated
        // enumerations report 6 (they are one traversal now: OCCTSwift #541/#613
        // routed `faces()` through the same `TopTools_IndexedMapOfShape` that
        // backs `subShapes(ofType:)`). The occurrence count lives on
        // `orientedFaces()` instead: 7, one entry per (face, owning shell) pair.
        // Both numbers are right and answer different questions.
        // `FaceIdentityTable` is built from the 6, per the decision.
        #expect(compound.faces().count == 6)
        #expect(compound.subShapes(ofType: .face).count == 6)
        #expect(compound.orientedFaces().count == 7)

        let ctx = makeContext()
        ctx.selectionMode = [.face]
        let obj = ctx.display(compound)
        let identity = try #require(ctx.faceIdentityTable(for: obj))
        #expect(identity.shapes.count == 6)

        // Locate the shared face by identity, not by position: an ordinal is an
        // artifact of enumeration order, `isSame` is the decision's own primitive
        // and is what makes this assertion survive a reordering of the fixture.
        let sharedOrdinal = try #require(
            identity.shapes.firstIndex { $0?.isSame(as: sharedFace) == true })
        let sharedUID = try #require(identity.uid(forOrdinal: sharedOrdinal))
        // Sanity: everything below is non-vacuous, no OTHER face carries that uid.
        for ordinal in identity.shapes.indices where ordinal != sharedOrdinal {
            #expect(identity.uid(forOrdinal: ordinal) != sharedUID)
        }

        let body = try #require(ctx.sourceBody(for: obj))
        #expect(!body.faceIndices.isEmpty)
        #expect(body.faceIndices.count == body.indices.count / 3)

        // `vertexData` is interleaved [px, py, pz, nx, ny, nz] with stride 6.
        func meshVertices(of triangle: Int) -> [UInt32] {
            Array(body.indices[(triangle * 3)..<(triangle * 3 + 3)])
        }
        func centroid(of triangle: Int) -> SIMD3<Float> {
            let corners = meshVertices(of: triangle).map { vertex -> SIMD3<Float> in
                let base = Int(vertex) * 6
                return SIMD3(
                    body.vertexData[base], body.vertexData[base + 1], body.vertexData[base + 2])
            }
            return (corners[0] + corners[1] + corners[2]) / 3
        }
        /// Split `triangles` into connected components by shared mesh vertex.
        /// Each owning shell tessellates the shared face into its own triangles
        /// over its own vertices, so one component per shell's copy.
        func copiesByVertexConnectivity(_ triangles: [Int]) -> [[Int]] {
            var pending = triangles
            var components: [[Int]] = []
            while let seed = pending.popLast() {
                var component = [seed]
                var pool = Set(meshVertices(of: seed))
                var grew = true
                while grew {
                    grew = false
                    for (offset, triangle) in pending.enumerated().reversed()
                    where !pool.isDisjoint(with: meshVertices(of: triangle)) {
                        component.append(triangle)
                        pool.formUnion(meshVertices(of: triangle))
                        pending.remove(at: offset)
                        grew = true
                    }
                }
                components.append(component.sorted())
            }
            return components.sorted { ($0.first ?? 0) < ($1.first ?? 0) }
        }

        // THE regression. Under dedup, "both ordinals agree" is true by
        // construction and so proves nothing; what can still silently break is a
        // shell's copy of the shared face never reaching the mesh at all. The
        // mesher walks face OCCURRENCES and stamps each with the deduplicated
        // index, so the shared ordinal must own two independent triangulations.
        let sharedTriangles = body.faceIndices.indices.filter {
            Int(body.faceIndices[$0]) == sharedOrdinal
        }
        let copies = copiesByVertexConnectivity(sharedTriangles)
        #expect(
            copies.count == 2,
            "both shells' copies of the shared face should be tessellated, got \(copies.count)")
        if copies.count == 2 {
            // And the second copy is the shared face again rather than a
            // neighbour mis-stamped with its ordinal: same triangles, same place.
            // This reads mesh geometry, not the identity table, so it is not
            // circular with the uid assertions below.
            let placesA = copies[0].map(centroid).sorted { ($0.x, $0.y, $0.z) < ($1.x, $1.y, $1.z) }
            let placesB = copies[1].map(centroid).sorted { ($0.x, $0.y, $0.z) < ($1.x, $1.y, $1.z) }
            #expect(placesA.count == placesB.count)
            for (a, b) in zip(placesA, placesB) {
                #expect(
                    simd_distance(a, b) < 1e-4,
                    "the two copies should cover the same face, got \(a) versus \(b)")
            }
        }
        var copyByTriangle: [Int: Int] = [:]
        for (copyIdx, copy) in copies.enumerated() {
            for triangle in copy { copyByTriangle[triangle] = copyIdx }
        }

        // Drive it through the real pick path: every ordinal must resolve to a
        // genuine face, and EVERY triangle of the shared face, from both shells'
        // copies, must resolve to the one shared uid via `handlePick` rather than
        // only via the table.
        var seenOrdinals: Set<Int> = []
        var uidsByCopy: [[BRepGraph.GraphUID?]] = Array(repeating: [], count: copies.count)
        for (triIdx, faceOrdinalRaw) in body.faceIndices.enumerated() {
            let ordinal = Int(faceOrdinalRaw)
            guard ordinal >= 0 else { continue }
            let isShared = ordinal == sharedOrdinal
            // Every triangle of the shared face; one per ordinal otherwise, which
            // is all the reachability coverage the unshared faces need.
            guard isShared || !seenOrdinals.contains(ordinal) else { continue }
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
            guard isShared else { continue }
            #expect(
                ref.shape.isSame(as: sharedFace),
                "triangle \(triIdx) carries the shared ordinal so it should resolve to that face")
            if let copyIdx = copyByTriangle[triIdx] { uidsByCopy[copyIdx].append(ref.uid) }
        }
        #expect(
            seenOrdinals.count == 6,
            "every one of the 6 distinct faces should be reachable by a pick")
        for (copyIdx, uids) in uidsByCopy.enumerated() {
            #expect(!uids.isEmpty, "copy \(copyIdx) of the shared face should have been picked")
            #expect(
                uids.allSatisfy { $0 == sharedUID },
                "picks landing on either shell's copy of the shared face must resolve to the same durable identity"
            )
        }
    }
}
