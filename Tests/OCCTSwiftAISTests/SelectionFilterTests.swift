import OCCTSwift
import OCCTSwiftViewport
import Testing
import simd

@testable import OCCTSwiftAIS

@MainActor
@Suite("SelectionFilter")
struct SelectionFilterTests {

    private func makeContext() -> InteractiveContext {
        InteractiveContext(viewport: ViewportController())
    }

    private func makeBox() throws -> OCCTSwift.Shape {
        try #require(OCCTSwift.Shape.box(width: 10, height: 5, depth: 3))
    }

    private func makeCylinder() throws -> OCCTSwift.Shape {
        try #require(OCCTSwift.Shape.cylinder(radius: 4, height: 8))
    }

    // MARK: - SurfaceTypeFilter

    @Test func t_surfaceTypeFilter_acceptsCylindricalFace_rejectsPlanarFace() throws {
        let cyl = try makeCylinder()
        let filter = SurfaceTypeFilter([.cylinder])

        var sawCylindrical = false
        var sawPlanar = false
        for i in 0..<cyl.subShapeCount(ofType: .face) {
            let faceShape = try #require(cyl.subShape(type: .face, index: i))
            let obj = InteractiveObject(shape: cyl)
            let candidate = SubShape.face(obj, ref: SubShapeRef(shape: faceShape, ordinal: i))
            let face = try #require(Face(faceShape))
            switch face.surfaceType {
            case .cylinder:
                #expect(filter.accepts(candidate))
                sawCylindrical = true
            case .plane:
                #expect(!filter.accepts(candidate))
                sawPlanar = true
            default:
                break
            }
        }
        #expect(sawCylindrical, "cylinder fixture should have a cylindrical face")
        #expect(sawPlanar, "cylinder fixture should have planar end caps")
    }

    @Test func t_surfaceTypeFilter_acceptsNonFaceCandidatesUnconditionally() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let filter = SurfaceTypeFilter([.cylinder])
        #expect(filter.accepts(.body(obj)))
    }

    // MARK: - CurveTypeFilter

    @Test func t_curveTypeFilter_acceptsCircularEdge_rejectsLine() throws {
        let cyl = try makeCylinder()
        let filter = CurveTypeFilter([.circle])

        var sawCircle = false
        var sawLine = false
        for i in 0..<cyl.edgeCount {
            let edgeShape = try #require(cyl.subShape(type: .edge, index: i))
            let obj = InteractiveObject(shape: cyl)
            let candidate = SubShape.edge(obj, ref: SubShapeRef(shape: edgeShape, ordinal: i))
            let edge = try #require(Edge(edgeShape))
            switch edge.curveType {
            case .circle:
                #expect(filter.accepts(candidate))
                sawCircle = true
            case .line:
                #expect(!filter.accepts(candidate))
                sawLine = true
            default:
                break
            }
        }
        #expect(sawCircle, "cylinder fixture should have circular rim edges")
        // A seam line may or may not be present depending on OCCT's cylinder construction.
        _ = sawLine
    }

    // MARK: - ShapeTypeFilter

    @Test func t_shapeTypeFilter_restrictsByKind() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let faceShape = try #require(obj.shape.subShape(type: .face, index: 0))
        let filter = ShapeTypeFilter([.face])

        #expect(filter.accepts(.face(obj, ref: SubShapeRef(shape: faceShape, ordinal: 0))))
        #expect(!filter.accepts(.body(obj)))
    }

    // MARK: - Composition

    @Test func t_allOfFilter_requiresEveryFilterToAccept() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeCylinder())
        let faces = obj.shape.faces()
        let cylindricalIdx = try #require(faces.firstIndex { $0.surfaceType == .cylinder })
        let cylindricalShape = try #require(Shape.fromFace(faces[cylindricalIdx]))
        let candidate = SubShape.face(
            obj, ref: SubShapeRef(shape: cylindricalShape, ordinal: cylindricalIdx))

        // AllOf(cylindrical-surface, radius < 10) accepts a radius-4 cylinder face.
        let smallRadius = AllOfFilter([
            SurfaceTypeFilter([.cylinder]),
            PredicateFilter { sub in
                // A face with no bounding box has no radius to compare, so it
                // fails the filter rather than reading as radius zero.
                guard case .face(_, let ref) = sub, let face = Face(ref.shape),
                    let bounds = face.bounds
                else { return false }
                // Loose bbox-based proxy for radius.
                return bounds.max.x - bounds.min.x < 20
            },
        ])
        #expect(smallRadius.accepts(candidate))

        // AllOf(cylindrical-surface, always-false) rejects everything.
        let neverAccepts = AllOfFilter([
            SurfaceTypeFilter([.cylinder]), PredicateFilter { _ in false },
        ])
        #expect(!neverAccepts.accepts(candidate))
    }

    @Test func t_anyOfFilter_acceptsIfAnyFilterAccepts() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        #expect(
            AnyOfFilter([ShapeTypeFilter([.edge]), ShapeTypeFilter([.body])]).accepts(.body(obj)))
        #expect(
            !AnyOfFilter([ShapeTypeFilter([.edge]), ShapeTypeFilter([.vertex])]).accepts(.body(obj))
        )
    }

    @Test func t_notFilter_invertsAnotherFilter() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let bodyOnly = ShapeTypeFilter([.body])
        #expect(bodyOnly.accepts(.body(obj)))
        #expect(!NotFilter(bodyOnly).accepts(.body(obj)))
    }

    @Test func t_predicateFilter_usesSuppliedClosure() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let alwaysTrue = PredicateFilter { _ in true }
        let alwaysFalse = PredicateFilter { _ in false }
        #expect(alwaysTrue.accepts(.body(obj)))
        #expect(!alwaysFalse.accepts(.body(obj)))
    }

    // MARK: - InteractiveContext wiring: pick + hover

    @Test func t_handlePick_filterRejectsPlanarFace_leavesSelectionUnchanged() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.face]
        let obj = ctx.display(try makeCylinder())
        ctx.addFilter(SurfaceTypeFilter([.cylinder]))

        let body = try #require(ctx.sourceBody(for: obj))
        // Find a triangle whose face ordinal is a planar cap.
        let identity = try #require(ctx.faceIdentityTable(for: obj))
        guard
            let planarOrdinal = (0..<identity.shapes.count).first(where: { ord in
                guard let shape = identity.shape(forOrdinal: ord), let face = Face(shape) else {
                    return false
                }
                return face.surfaceType == .plane
            }), let triIdx = body.faceIndices.firstIndex(where: { Int($0) == planarOrdinal })
        else {
            Issue.record("expected a planar face ordinal reachable by a triangle")
            return
        }

        let raw = UInt32(triIdx) << 16
        let pick = try #require(PickResult(rawValue: raw, indexMap: [0: body.id]))
        ctx.handlePick(pick)

        #expect(
            ctx.selection.isEmpty,
            "a filtered-out pick should leave the selection unchanged (still empty)")
    }

    @Test func t_handlePick_filterAcceptsCylindricalFace_selects() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.face]
        let obj = ctx.display(try makeCylinder())
        ctx.addFilter(SurfaceTypeFilter([.cylinder]))

        let body = try #require(ctx.sourceBody(for: obj))
        let identity = try #require(ctx.faceIdentityTable(for: obj))
        guard
            let cylOrdinal = (0..<identity.shapes.count).first(where: { ord in
                guard let shape = identity.shape(forOrdinal: ord), let face = Face(shape) else {
                    return false
                }
                return face.surfaceType == .cylinder
            }), let triIdx = body.faceIndices.firstIndex(where: { Int($0) == cylOrdinal })
        else {
            Issue.record("expected a cylindrical face ordinal reachable by a triangle")
            return
        }

        let raw = UInt32(triIdx) << 16
        let pick = try #require(PickResult(rawValue: raw, indexMap: [0: body.id]))
        ctx.handlePick(pick)

        #expect(containsFace(ctx.selection.subshapes, obj, ordinal: cylOrdinal))
    }

    @Test func t_handlePick_rejectedPick_doesNotClobberExistingSelection() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.body]
        let a = ctx.display(try makeBox())
        let b = ctx.display(try makeCylinder())
        ctx.select(.body(a))
        ctx.addFilter(ShapeTypeFilter([]))  // rejects every kind

        let bodyB = try #require(ctx.sourceBody(for: b))
        let pick = try #require(PickResult(rawValue: 0, indexMap: [0: bodyB.id]))
        ctx.handlePick(pick)

        #expect(
            ctx.selection.subshapes == [.body(a)],
            "a rejected pick behaves like an empty-space pick")
    }

    @Test func t_handleHover_filterGatesHoverSameAsSelection() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.body]
        let obj = ctx.display(try makeBox())
        let body = try #require(ctx.sourceBody(for: obj))

        ctx.handleHover(bodyID: body.id)
        #expect(ctx.hover == .body(obj))

        ctx.addFilter(ShapeTypeFilter([]))  // rejects every kind
        ctx.handleHover(bodyID: body.id)
        #expect(ctx.hover == nil, "a filtered-out candidate should not produce a hover highlight")
    }

    @Test func t_removeAllFilters_restoresUnrestrictedPicking() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.body]
        let obj = ctx.display(try makeBox())
        let body = try #require(ctx.sourceBody(for: obj))
        ctx.addFilter(ShapeTypeFilter([]))

        ctx.handlePick(try #require(PickResult(rawValue: 0, indexMap: [0: body.id])))
        #expect(ctx.selection.isEmpty)

        ctx.removeAllFilters()
        ctx.handlePick(try #require(PickResult(rawValue: 0, indexMap: [0: body.id])))
        #expect(ctx.selection.subshapes == [.body(obj)])
    }

    @Test func t_removeFilter_byIdentity_removesOnlyThatOne() throws {
        let ctx = makeContext()
        let rejectAll = ShapeTypeFilter([])
        let acceptAll = ShapeTypeFilter([.body, .face, .edge, .vertex])
        ctx.addFilter(rejectAll)
        ctx.addFilter(acceptAll)
        #expect(ctx.filters.count == 2)

        ctx.removeFilter(rejectAll)
        #expect(ctx.filters.count == 1)
        #expect(ctx.filters.first === acceptAll)
    }

    @Test func t_multipleInstalledFilters_combineWithAND_notOR() throws {
        // A deliberate departure from OCCT's OR semantics: see
        // InteractiveContext.passesInstalledFilters. Installing an
        // accept-everything filter alongside a reject-everything filter must
        // still reject, since AND requires ALL filters to accept.
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        ctx.addFilter(ShapeTypeFilter([.body, .face, .edge, .vertex]))  // accepts everything
        ctx.addFilter(ShapeTypeFilter([]))  // accepts nothing
        #expect(ctx.passesInstalledFilters(.body(obj)) == false)
    }

    // MARK: - Widget pick-layer isolation

    @Test func t_installedFilters_doNotAffectWidgetPickRouting() throws {
        let aspect: Float = 16.0 / 9.0
        let camera: CameraState = .isometric
        let vpMatrix = camera.projectionMatrix(aspectRatio: aspect) * camera.viewMatrix

        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        ctx.addFilter(ShapeTypeFilter([]))  // maximally restrictive

        let widget = ManipulatorWidget(target: obj)
        widget.size = 2.0
        widget.install(in: ctx)

        // Widget picks route through viewport.widgetPickResult, never through
        // InteractiveContext.handlePick / passesInstalledFilters: a restrictive
        // context-level filter must not affect the widget at all.
        let midpoint = ManipulatorWidget.Axis.x.direction * widget.size * 0.5
        let ndc3 = try #require(ProjectionUtility.worldToNDC(point: midpoint, vpMatrix: vpMatrix))
        let hit = widget.hitTest(ndc: SIMD2<Float>(ndc3.x, ndc3.y), camera: camera, aspect: aspect)
        #expect(
            hit == .x, "widget hit-testing should be unaffected by context-level selection filters")

        // And a pick landing on a widget body still produces no user selection,
        // exactly as without any filters installed.
        let widgetBodyID = widget.bodyID(for: .x)
        let pick = try #require(PickResult(rawValue: 0, indexMap: [0: widgetBodyID]))
        ctx.handlePick(pick)
        #expect(ctx.selection.isEmpty)
    }
}
