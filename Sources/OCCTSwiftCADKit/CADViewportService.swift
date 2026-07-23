import Foundation
import SwiftUI
import Combine
import simd
import OCCTSwift
import OCCTSwiftViewport
import OCCTSwiftTools
import OCCTSwiftAIS

/// Manages a loaded B-Rep `Shape`, drives the Metal viewport, and routes
/// face-picking results back to the caller.
///
/// Use `loadFile(from:)`/`loadShape(_:id:)`/`loadFromData(_:filename:)` to
/// import geometry. Caller-supplied geometry like stock boxes, toolpaths, or
/// flat-pattern outlines is staged via the `setOverlay(id:bodies:)` API; the
/// service composites them with the model bodies and any selection highlight
/// every time it rebuilds the viewport's body list.
///
/// AIS widgets (manipulator, dimensions, sub-shape selection) install against
/// `interactiveContext`; the bodies they append are composited with the
/// CADKit-owned bodies into a single rendered array.
@MainActor
@Observable
public final class CADViewportService {
    /// Viewport controller — exposes camera, display mode, picking config,
    /// etc. Construct with custom configuration via `init(configuration:)`.
    public let controller: _ViewportController

    /// AIS interactive context backed by this service's viewport. Use to
    /// install `ManipulatorWidget`, add dimensions, or display extra
    /// `InteractiveObject`s. Bodies appended via `display(_:)` /
    /// `appendInternalBody(_:)` are composited with the CADKit-owned bodies
    /// (model + overlays + selection highlight) and rendered through the
    /// same array that `CADViewportView` binds to.
    public let interactiveContext: InteractiveContext

    /// All bodies currently displayed in the viewport. Composed of: model
    /// bodies (from imported file) + overlay layers (caller-managed) +
    /// selection highlight (managed internally on pick) + AIS-owned bodies
    /// (manipulator handles, displayed shapes, dimensions). Mirrors
    /// `interactiveContext.bodies`.
    public private(set) var bodies: [_ViewportBody] = []

    /// The loaded OCCTSwift shape, or `nil` until something is loaded.
    ///
    /// Set by the deprecated single-shape `loadFile(from:progress:)`/`loadShape(_:id:)`.
    /// The multi-entity API (`load(_:id:transform:)`/`loadFile(from:id:progress:)`) doesn't
    /// set it directly — the public `loadedShape` getter falls back to it when exactly one
    /// entity is loaded that way, matching this property's "single-shape convenience"
    /// contract either way.
    private var legacyLoadedShape: OCCTSwift.Shape?

    /// The entity id `legacyLoadedShape` corresponds to (the given `id` for `loadShape`;
    /// the first resulting body's id for `loadFile(from:progress:)`, since that's what it
    /// also registers as its own entity). Lets `remove(id:)` invalidate `legacyLoadedShape`
    /// precisely when *that* entity is removed or replaced — e.g. `loadShape(box, id:
    /// "model")` followed by `load(otherBox, id: "model")` must stop `loadedShape` from
    /// still reporting the first `box` — without wrongly clearing it when a *different*
    /// entity is removed.
    private var legacyLoadedShapeEntityID: String?

    /// The loaded shape, when exactly one is loaded (however it was loaded). `nil` if
    /// nothing is loaded, or if more than one entity is loaded via the multi-entity API.
    @available(*, deprecated, message: "Use `loadedShapes`/`shape(id:)` instead — returns non-nil only when exactly one entity is loaded.")
    public var loadedShape: OCCTSwift.Shape? { currentSingleShape }

    /// Non-deprecated backing for `loadedShape`'s fallback logic, so `shapeBounds` and
    /// `focusOnLoadedShape()` can use the same lookup without tripping the deprecation
    /// warning on every internal read.
    private var currentSingleShape: OCCTSwift.Shape? {
        if let legacyLoadedShape { return legacyLoadedShape }
        guard entities.count == 1, let onlyID = entities.keys.first else { return nil }
        return shape(id: onlyID)
    }

    /// Every currently selected sub-shape (face, edge, or vertex), gated by
    /// `selectionModes`. Empty if nothing is selected. A real viewport pick always
    /// replaces the whole selection (matching `OCCTSwiftAIS`'s own point-pick behavior —
    /// scheme-based combination is for programmatic `select(_:scheme:)` calls, e.g. area
    /// selection); build multi-selection by calling `select(_:scheme:)` yourself.
    public private(set) var selection: [PickedEntity] = []

    /// The single selected entity, when the selection is exactly one. `nil` if nothing is
    /// selected, or more than one entity is selected.
    @available(*, deprecated, message: "Use `selection` instead — returns non-nil only when exactly one entity is selected.")
    public var selected: PickedEntity? {
        selection.count == 1 ? selection.first : nil
    }

    /// Which sub-shape kinds picking resolves. Defaults to `[.face]`, matching this
    /// service's behavior before edge/vertex picking existed — add `.edge`/`.vertex` to
    /// opt in. `.body` has no effect here (there is no whole-body `PickedEntity` case);
    /// it exists on `SelectionMode` for `OCCTSwiftAIS.InteractiveContext.selectionMode`,
    /// a separate, independent selection system this service does not share state with.
    public var selectionModes: Set<SelectionMode> = [.face]

    /// Currently selected face, or `nil` if nothing is picked or the current pick is an
    /// edge or vertex.
    @available(*, deprecated, message: "Use `selection` instead — returns non-nil only when the selection is exactly one face.")
    public var selectedFace: PickedFaceInfo? {
        if case .face(let info)? = selected { return info }
        return nil
    }

    /// Internal rather than private so tests can seed it directly — e.g. a synthetic body
    /// with empty `edgeIndices`/`vertices` to exercise the "not edge/vertex-pickable"
    /// degrade-gracefully path without a real non-pickable file on disk.
    var modelBodies: [_ViewportBody] = []
    /// Internal rather than private so tests can seed it directly when exercising
    /// `rebuildIdentity`/`resolveFacePick` against a synthetic multi-body scenario without
    /// a real multi-body file on disk.
    var metadata: [String: CADBodyMetadata] = [:]
    private var overlays: [String: [_ViewportBody]] = [:]
    /// Up to three highlight bodies — one per kind present in `selection` — since each
    /// kind renders with a different primitive (translucent triangle patch / polyline /
    /// point sprite) that can't share one `_ViewportBody`.
    private var selectionBodies: [_ViewportBody] = []
    private var ownedBodyIDs: Set<String> = []
    private var bodiesSubscription: AnyCancellable?

    // MARK: - Durable identity (per loaded body)

    /// The raw shape each model body was tessellated from, keyed by body id.
    private var bodyShapes: [String: OCCTSwift.Shape] = [:]

    /// One `BRepGraph` per loaded body, retained for its shape's lifetime — this is what
    /// makes `PickedFaceInfo.uid` populatable, and what a later absorb-history mechanic
    /// (mirroring `InteractiveContext.update(_:to:absorbing:operationName:)`) would need.
    /// Absent for a body whose graph failed to construct (a pathological shape); such a
    /// body's picks mint `uid == nil`.
    private var bodyGraphs: [String: BRepGraph] = [:]

    /// Face-ordinal → (`Shape`, `GraphUID`?) table per loaded body, keyed by body id.
    private var faceIdentity: [String: FaceIdentityTable] = [:]

    /// Edge-ordinal → (`Shape`, `GraphUID`?) table per loaded body, keyed by body id.
    private var edgeIdentity: [String: EdgeIdentityTable] = [:]

    /// Vertex-ordinal → (`Shape`, `GraphUID`?) table per loaded body, keyed by body id.
    private var vertexIdentity: [String: VertexIdentityTable] = [:]

    // MARK: - Scalar fields

    /// The scalar field currently painted on each body, keyed by body id.
    private var scalarFields: [String: ScalarField] = [:]

    /// The body id `scalarFieldLegend` reports on — the most recent `setScalarField(_:forBody:)`
    /// call that set a non-nil field. `nil` once that body's field is cleared or the body
    /// itself is removed/reloaded.
    private var lastScalarFieldBodyID: String?

    // MARK: - Multi-body / assembly (entities loaded via `load`/`loadFile(from:id:)`)

    /// A distinct, addressable entity loaded via the multi-entity API — the model-body
    /// ids it owns (more than one for a multi-body file loaded under one entity id) and
    /// its own visibility flag.
    private struct Entity {
        var bodyIDs: [String]
        var isVisible: Bool = true
    }

    /// Every currently loaded entity, keyed by entity id — whether loaded via
    /// `load(_:id:transform:)`/`loadFile(from:id:progress:)`, or via the deprecated
    /// single-shape `loadFile(from:progress:)`/`loadShape(_:id:)` (each of which registers
    /// its own resulting body/bodies here too, one entity per body, since it has no
    /// caller-supplied grouping concept of its own). This is the single source of truth
    /// `remove(id:)`/`loadedShapes`/`visibility`/etc. read — kept accurate regardless of
    /// which loading API was used is what makes mixing the two APIs in one session safe
    /// (e.g. `loadShape(_:id:"model")` then `load(_:id:"model")` correctly replaces the
    /// first load rather than leaving a stray duplicate body).
    private var entities: [String: Entity] = [:]

    public init(configuration: _ViewportConfiguration = .init(
        rotationStyle: .turntable,
        displayMode: .shadedWithEdges,
        lightingConfiguration: .threePoint,
        showViewCube: true,
        showAxes: true,
        showGrid: true,
        pickingConfiguration: _PickingConfiguration(isEnabled: true)
    )) {
        let controller = _ViewportController(configuration: configuration)
        self.controller = controller
        self.interactiveContext = InteractiveContext(viewport: controller)
        controller.onPick = { [weak self] result in
            Task { @MainActor in
                self?.handlePick(result)
            }
        }
        self.bodiesSubscription = interactiveContext.$bodies
            .receive(on: RunLoop.main)
            .sink { [weak self] new in
                self?.bodies = new
            }
    }

    // MARK: - File Import

    /// Load a CAD file (STEP/.stp, STL, BREP) from disk into the viewport.
    /// Returns the loaded `Shape`. Camera is automatically focused on the
    /// shape's bounding box.
    ///
    /// Pass an `ImportProgress` (e.g. `ImportProgressClosure`) to observe
    /// STEP/IGES import progress and/or request cooperative cancellation;
    /// cancellation surfaces as `ImportError.cancelled`.
    ///
    /// Single-shape convenience: replaces every model body, including any loaded via
    /// `load(_:id:transform:)`/`loadFile(from:id:progress:)` — registers each resulting
    /// body as its own entity (see `entities`' own documentation), so `remove(id:)`/
    /// `loadedShapes`/etc. see it too.
    @available(*, deprecated, message: "Use loadFile(from:id:progress:) instead for multi-entity loading. This overload still replaces every model body.")
    @discardableResult
    public func loadFile(
        from url: URL,
        progress: ImportProgress? = nil
    ) async throws -> OCCTSwift.Shape {
        let ext = url.pathExtension.lowercased()
        let format: CADFileFormat
        switch ext {
        case "step", "stp": format = .step
        case "stl": format = .stl
        case "brep": format = .brep
        default: throw CADViewportError.unsupportedFormat(ext)
        }

        let result = try await CADFileLoader.load(from: url, format: format, progress: progress)
        guard let firstShape = result.shapes.first else {
            throw CADViewportError.emptyFile
        }

        resetAllModelState()
        self.legacyLoadedShape = firstShape
        self.legacyLoadedShapeEntityID = result.bodies.first?.id
        self.modelBodies = result.bodies
        self.metadata = result.metadata
        rebuildIdentity(bodies: result.bodies, shapes: result.shapes)
        for body in result.bodies {
            entities[body.id] = Entity(bodyIDs: [body.id])
        }
        clearSelection()
        rebuildBodies()
        focusOnLoadedShape()
        return firstShape
    }

    /// Display an in-memory shape (e.g. one constructed programmatically via
    /// OCCTSwift) without going through the file loader.
    ///
    /// Single-shape convenience: replaces every model body, including any loaded via
    /// `load(_:id:transform:)`/`loadFile(from:id:progress:)` — registers as its own entity
    /// under `id` (see `entities`' own documentation), so `remove(id:)`/`loadedShapes`/etc.
    /// see it too.
    @available(*, deprecated, message: "Use load(_:id:transform:) instead for multi-entity loading. This overload still replaces every model body.")
    public func loadShape(_ shape: OCCTSwift.Shape, id: String = "model") {
        resetAllModelState()
        self.legacyLoadedShape = shape
        self.legacyLoadedShapeEntityID = id
        let graph = BRepGraph(shape: shape)
        let (body, meta, faceTable, edgeTable, vertexTable) = CADFileLoader.shapeToBodyMetadataAndIdentities(
            shape,
            id: id,
            color: SIMD4<Float>(0.7, 0.7, 0.75, 1.0),
            graph: graph
        )
        if let body {
            self.modelBodies = [body]
        }
        if let meta {
            self.metadata[id] = meta
        }
        self.bodyShapes[id] = shape
        if let graph {
            self.bodyGraphs[id] = graph
        }
        if let faceTable {
            self.faceIdentity[id] = faceTable
        }
        if let edgeTable {
            self.edgeIdentity[id] = edgeTable
        }
        if let vertexTable {
            self.vertexIdentity[id] = vertexTable
        }
        entities[id] = Entity(bodyIDs: [id])
        clearSelection()
        rebuildBodies()
        focusOnLoadedShape()
    }

    /// Full clean slate for every collection a load populates, including `entities` and
    /// `legacyLoadedShape`. Used by the deprecated single-shape `loadFile(from:progress:)`/
    /// `loadShape(_:id:)` (which replace *everything*, not just their own prior load) and by
    /// `removeAll()`. Centralising this is what makes it safe to mix the deprecated and
    /// multi-entity APIs in one session — e.g. `loadShape(_:id:"model")` followed by
    /// `load(_:id:"model")` correctly replaces the first load's body rather than leaving a
    /// stray duplicate, since both register in the same `entities` registry.
    private func resetAllModelState() {
        modelBodies.removeAll()
        metadata.removeAll()
        bodyShapes.removeAll()
        bodyGraphs.removeAll()
        faceIdentity.removeAll()
        edgeIdentity.removeAll()
        vertexIdentity.removeAll()
        entities.removeAll()
        scalarFields.removeAll()
        lastScalarFieldBodyID = nil
        legacyLoadedShape = nil
        legacyLoadedShapeEntityID = nil
    }

    /// Builds a `BRepGraph` and `FaceIdentityTable` per body from a multi-body file load's
    /// raw shapes, keyed by body id. `CADFileLoader.load(from:format:)` has no
    /// identity-table overload — it owns the STL/IGES robust-reload fallback, which this
    /// package shouldn't reimplement just to get identity — so the table is built directly
    /// from `shape.faces()` instead of re-tessellating each body through
    /// `shapeToBodyMetadataAndIdentity`. `shape.faces()` is the same non-deduplicating
    /// traversal the mesher used to assign `CADBodyMetadata.faceIndices` in the first place
    /// (see `FaceIdentityTable`'s own documentation), so ordinals line up without a second
    /// tessellation pass.
    ///
    /// Requires `bodies` and `shapes` to correspond positionally (`shapes[i]` is the shape
    /// `bodies[i]` was tessellated from) — true for `CADFileLoader.load(from:format:)`'s
    /// primary bridge, where both arrays are appended together only on tessellation success.
    /// Its STL/IGES robust-reload fallback (`reloadRobustAndBridge`) can violate this: it
    /// appends to `shapes` on every input even when that input's body tessellation fails, so
    /// a body-tessellation failure part-way through a multibody robust reload shifts `shapes`
    /// out of alignment with `bodies` for every subsequent entry. Detectable from the outside
    /// only via the count mismatch it produces (`shapes.count > bodies.count`) — when that
    /// happens, this method skips building identity entirely rather than risk pairing a body
    /// with the wrong shape, matching this pack's own rule that `uid`/`shape` should be
    /// absent rather than wrong.
    func rebuildIdentity(bodies: [_ViewportBody], shapes: [OCCTSwift.Shape]) {
        guard bodies.count == shapes.count else {
            self.bodyShapes = [:]
            self.bodyGraphs = [:]
            self.faceIdentity = [:]
            self.edgeIdentity = [:]
            self.vertexIdentity = [:]
            return
        }

        var newShapes: [String: OCCTSwift.Shape] = [:]
        var newGraphs: [String: BRepGraph] = [:]
        var newFaceIdentity: [String: FaceIdentityTable] = [:]
        var newEdgeIdentity: [String: EdgeIdentityTable] = [:]
        var newVertexIdentity: [String: VertexIdentityTable] = [:]

        for (index, body) in bodies.enumerated() {
            let shape = shapes[index]
            newShapes[body.id] = shape
            let graph = BRepGraph(shape: shape)
            if let graph {
                newGraphs[body.id] = graph
            }
            newFaceIdentity[body.id] = Self.makeFaceIdentityTable(shape: shape, graph: graph)
            newEdgeIdentity[body.id] = Self.makeEdgeIdentityTable(shape: shape, graph: graph)
            newVertexIdentity[body.id] = Self.makeVertexIdentityTable(shape: shape, graph: graph)
        }

        self.bodyShapes = newShapes
        self.bodyGraphs = newGraphs
        self.faceIdentity = newFaceIdentity
        self.edgeIdentity = newEdgeIdentity
        self.vertexIdentity = newVertexIdentity
    }

    /// Mirrors `OCCTSwiftTools.CADFileLoader`'s own (private) `makeFaceIdentityTable`: map
    /// every `shape.faces()` ordinal to its `Shape`, and, when a graph is available, to the
    /// `GraphUID` minted via `graph.findNode(for:)` on that same face `Shape` so `IsSame`
    /// semantics hold.
    private static func makeFaceIdentityTable(shape: OCCTSwift.Shape, graph: BRepGraph?) -> FaceIdentityTable {
        let faceShapes = shape.faces().compactMap { OCCTSwift.Shape.fromFace($0) }
        guard let graph else {
            return FaceIdentityTable(shapes: faceShapes)
        }
        let uids: [BRepGraph.GraphUID?] = faceShapes.map { faceShape in
            guard let node = graph.findNode(for: faceShape) else { return nil }
            return graph.uid(ofNodeKind: Int(node.kind.rawValue), index: node.index)
        }
        return FaceIdentityTable(shapes: faceShapes, uids: uids)
    }

    /// Mirrors `OCCTSwiftTools.CADFileLoader`'s own (private) `makeEdgeIdentityTable`: map
    /// every `shape.edges()` ordinal (the same `TopTools_IndexedMapOfShape` traversal
    /// `edgeIndices` is built from) to its `Shape` and, when available, `GraphUID`.
    private static func makeEdgeIdentityTable(shape: OCCTSwift.Shape, graph: BRepGraph?) -> EdgeIdentityTable {
        let edgeShapes = shape.edges().compactMap { OCCTSwift.Shape.fromEdge($0) }
        guard let graph else {
            return EdgeIdentityTable(shapes: edgeShapes)
        }
        let uids: [BRepGraph.GraphUID?] = edgeShapes.map { edgeShape in
            guard let node = graph.findNode(for: edgeShape) else { return nil }
            return graph.uid(ofNodeKind: Int(node.kind.rawValue), index: node.index)
        }
        return EdgeIdentityTable(shapes: edgeShapes, uids: uids)
    }

    /// Mirrors `OCCTSwiftTools.CADFileLoader`'s own (private) `makeVertexIdentityTable`: map
    /// every `shape.subShapes(ofType: .vertex)` ordinal (the same `TopTools_IndexedMapOfShape`
    /// traversal `vertexIndices` is built from) to its `Shape` and, when available, `GraphUID`.
    private static func makeVertexIdentityTable(shape: OCCTSwift.Shape, graph: BRepGraph?) -> VertexIdentityTable {
        let vertexShapes = shape.subShapes(ofType: .vertex)
        guard let graph else {
            return VertexIdentityTable(shapes: vertexShapes)
        }
        let uids: [BRepGraph.GraphUID?] = vertexShapes.map { vertexShape in
            guard let node = graph.findNode(for: vertexShape) else { return nil }
            return graph.uid(ofNodeKind: Int(node.kind.rawValue), index: node.index)
        }
        return VertexIdentityTable(shapes: vertexShapes, uids: uids)
    }

    /// Convenience for callers that have file `Data` rather than a URL
    /// (e.g. `.fileImporter` results, drag-and-drop on iOS).
    @available(*, deprecated, message: "Use loadFromData(_:filename:id:progress:) instead for multi-entity loading. This overload still replaces every model body.")
    @discardableResult
    public func loadFromData(
        _ data: Data,
        filename: String,
        progress: ImportProgress? = nil
    ) async throws -> OCCTSwift.Shape {
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent(filename)
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        return try await loadFile(from: tempURL, progress: progress)
    }

    /// Multi-entity counterpart to the deprecated `loadFromData(_:filename:progress:)`: for
    /// callers that have file `Data` rather than a URL. See `loadFile(from:id:progress:)`.
    ///
    /// `id` is required — a defaulted one would make calls like
    /// `loadFromData(data, filename: "part.step")` ambiguous against the deprecated
    /// 3-argument overload, since both would become callable with identical arguments.
    @discardableResult
    public func loadFromData(
        _ data: Data,
        filename: String,
        id: String,
        progress: ImportProgress? = nil
    ) async throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent(filename)
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        return try await loadFile(from: tempURL, id: id, progress: progress)
    }

    // MARK: - Multi-body / Assembly

    /// Load a CAD file as a distinct, addressable entity. Unlike the deprecated
    /// `loadFile(from:progress:)`, this adds to the currently loaded entities rather than
    /// replacing them, so multiple parts (or several of an assembly's occurrences) can
    /// coexist. A file with several bodies (e.g. a multibody STEP/STL) registers one
    /// entity whose body ids are `"<id>-0"`, `"<id>-1"`, etc.
    ///
    /// Camera is **not** auto-focused (unlike the deprecated single-shape overload) — call
    /// `focus(on:)` once you've loaded what should be visible.
    ///
    /// - Parameters:
    ///   - url: file URL on disk.
    ///   - id: the entity id. Loading again under an id already in use replaces that entity.
    ///   - progress: optional `ImportProgress` (e.g. `ImportProgressClosure`).
    /// - Returns: `id`, echoed back.
    /// - Throws: `CADViewportError.unsupportedFormat(ext)` for an unsupported extension;
    ///   `CADViewportError.emptyFile` if the file contains no geometry;
    ///   `ImportError.cancelled` if cancelled via `progress`.
    @discardableResult
    public func loadFile(
        from url: URL,
        id: String,
        progress: ImportProgress? = nil
    ) async throws -> String {
        let ext = url.pathExtension.lowercased()
        let format: CADFileFormat
        switch ext {
        case "step", "stp": format = .step
        case "stl": format = .stl
        case "brep": format = .brep
        default: throw CADViewportError.unsupportedFormat(ext)
        }

        let result = try await CADFileLoader.load(from: url, format: format, progress: progress)
        guard !result.bodies.isEmpty else {
            throw CADViewportError.emptyFile
        }

        remove(id: id)

        var bodyIDs: [String] = []
        for (index, originalBody) in result.bodies.enumerated() {
            let bodyID = "\(id)-\(index)"
            if let originalMeta = result.metadata[originalBody.id] {
                metadata[bodyID] = originalMeta
            }
            var body = originalBody
            body.id = bodyID
            modelBodies.append(body)
            bodyIDs.append(bodyID)
        }
        addIdentity(bodyIDs: bodyIDs, shapes: result.bodies.count == result.shapes.count ? result.shapes : [])

        entities[id] = Entity(bodyIDs: bodyIDs)
        rebuildBodies()
        return id
    }

    /// Display an in-memory shape as a distinct, addressable entity. Unlike the deprecated
    /// `loadShape(_:id:)`, this adds to the currently loaded entities rather than replacing
    /// them.
    ///
    /// Pass `transform` to place the shape before tessellating it — e.g. an assembly
    /// occurrence's location. Matches `OCCTSwift.Shape.transformed(matrix:)`'s layout: a
    /// rigid 12-element affine matrix, `[r00,r01,r02, r10,r11,r12, r20,r21,r22, tx,ty,tz]`
    /// (row-major 3x3 rotation, then translation). `nil` (default) leaves the shape as-is.
    ///
    /// Camera is **not** auto-focused — call `focus(on:)` once you've loaded what should
    /// be visible.
    ///
    /// - Returns: `id`, echoed back.
    @discardableResult
    public func load(_ shape: OCCTSwift.Shape, id: String, transform: [Double]? = nil) -> String {
        let placedShape = transform.flatMap { shape.transformed(matrix: $0) } ?? shape

        remove(id: id)

        let graph = BRepGraph(shape: placedShape)
        let (body, meta, faceTable, edgeTable, vertexTable) = CADFileLoader.shapeToBodyMetadataAndIdentities(
            placedShape,
            id: id,
            color: SIMD4<Float>(0.7, 0.7, 0.75, 1.0),
            graph: graph
        )

        guard let body else {
            entities[id] = Entity(bodyIDs: [])
            rebuildBodies()
            return id
        }

        modelBodies.append(body)
        if let meta {
            metadata[id] = meta
        }
        bodyShapes[id] = placedShape
        if let graph {
            bodyGraphs[id] = graph
        }
        if let faceTable {
            faceIdentity[id] = faceTable
        }
        if let edgeTable {
            edgeIdentity[id] = edgeTable
        }
        if let vertexTable {
            vertexIdentity[id] = vertexTable
        }

        entities[id] = Entity(bodyIDs: [id])
        rebuildBodies()
        return id
    }

    /// Additive counterpart to `rebuildIdentity`: builds identity for one entity's bodies
    /// and merges it in with whatever other entities' identity already exists, rather than
    /// wiping everything (which is what `rebuildIdentity`, used by the deprecated
    /// single-entity `loadFile(from:progress:)`, does). Same defensive count-mismatch
    /// guard as `rebuildIdentity`: if `bodyIDs` and `shapes` don't correspond positionally
    /// (or an empty `shapes` was passed because the caller already detected a mismatch),
    /// identity is skipped for this batch — the bodies still display, without
    /// durable-identity picks, rather than risk pairing a body with the wrong shape.
    private func addIdentity(bodyIDs: [String], shapes: [OCCTSwift.Shape]) {
        guard bodyIDs.count == shapes.count else { return }
        for (index, bodyID) in bodyIDs.enumerated() {
            let shape = shapes[index]
            bodyShapes[bodyID] = shape
            let graph = BRepGraph(shape: shape)
            if let graph {
                bodyGraphs[bodyID] = graph
            }
            faceIdentity[bodyID] = Self.makeFaceIdentityTable(shape: shape, graph: graph)
            edgeIdentity[bodyID] = Self.makeEdgeIdentityTable(shape: shape, graph: graph)
            vertexIdentity[bodyID] = Self.makeVertexIdentityTable(shape: shape, graph: graph)
        }
    }

    /// Removes a loaded entity (and its bodies) from the viewport. No-op if `id` isn't
    /// currently loaded. Clears the current selection if it referenced this entity.
    ///
    /// Also invalidates `legacyLoadedShape` if it was this entity's — otherwise the
    /// deprecated `loadedShape`/`shapeBounds` could keep reporting a shape whose entity was
    /// just removed or replaced (e.g. `loadShape(box, id: "model")` followed by
    /// `load(otherBox, id: "model")`, which calls this internally before adding the new
    /// body under the same id).
    public func remove(id: String) {
        guard let entity = entities.removeValue(forKey: id) else { return }
        if legacyLoadedShapeEntityID == id {
            legacyLoadedShape = nil
            legacyLoadedShapeEntityID = nil
        }
        removeBodies(entity.bodyIDs)
        pruneSelection(removingBodyIDs: entity.bodyIDs)
    }

    /// Removes every currently loaded entity — whichever API loaded it (see `entities`'
    /// own documentation) — and clears the deprecated single-shape `loadedShape`'s legacy
    /// backing too. A full clean slate, equivalent to a fresh `CADViewportService`.
    public func removeAll() {
        let hadSelection = !selection.isEmpty
        resetAllModelState()
        if hadSelection {
            clearSelection() // also calls rebuildBodies()
        } else {
            rebuildBodies()
        }
    }

    private func removeBodies(_ bodyIDs: [String]) {
        for bodyID in bodyIDs {
            modelBodies.removeAll { $0.id == bodyID }
            metadata.removeValue(forKey: bodyID)
            bodyShapes.removeValue(forKey: bodyID)
            bodyGraphs.removeValue(forKey: bodyID)
            faceIdentity.removeValue(forKey: bodyID)
            edgeIdentity.removeValue(forKey: bodyID)
            vertexIdentity.removeValue(forKey: bodyID)
            scalarFields.removeValue(forKey: bodyID)
            if lastScalarFieldBodyID == bodyID {
                lastScalarFieldBodyID = nil
            }
        }
    }

    /// Drops only the selection entries that referenced a removed body, leaving everything
    /// else selected — the selection survives operations unrelated to it, and honestly
    /// reports (by no longer containing them) the entries that didn't.
    private func pruneSelection(removingBodyIDs bodyIDs: [String]) {
        let removed = Set(bodyIDs)
        guard selection.contains(where: { removed.contains($0.bodyID) }) else {
            rebuildBodies()
            return
        }
        selection.removeAll { removed.contains($0.bodyID) }
        rebuildSelectionHighlights() // also calls rebuildBodies()
    }

    /// Currently loaded entities' shapes, keyed by entity id — see `entities`' own
    /// documentation for why this reflects every loading API, not just the multi-entity one.
    public var loadedShapes: [String: OCCTSwift.Shape] {
        entities.keys.reduce(into: [:]) { result, id in
            result[id] = shape(id: id)
        }
    }

    /// The shape a loaded entity owns — its first body's shape, for a multi-body entity
    /// (e.g. a multibody file loaded under one id). `nil` if `id` isn't currently loaded,
    /// or its shape failed to tessellate.
    public func shape(id: String) -> OCCTSwift.Shape? {
        guard let entity = entities[id], let firstBodyID = entity.bodyIDs.first else { return nil }
        return bodyShapes[firstBodyID]
    }

    /// The entity id that owns a body id (e.g. from a pick's `PickedEntity.bodyID`), or
    /// `nil` if the body isn't tracked by the multi-entity API.
    public func entityID(forBodyID bodyID: String) -> String? {
        entities.first { $0.value.bodyIDs.contains(bodyID) }?.key
    }

    /// Per-entity visibility. Reading returns every loaded entity's current flag; setting
    /// applies each given key's value (a key not currently loaded is ignored).
    public var visibility: [String: Bool] {
        get { entities.mapValues(\.isVisible) }
        set {
            for (id, isVisible) in newValue where entities[id] != nil {
                setVisible(isVisible, forEntity: id)
            }
        }
    }

    private func setVisible(_ isVisible: Bool, forEntity id: String) {
        guard var entity = entities[id] else { return }
        entity.isVisible = isVisible
        entities[id] = entity
        for i in modelBodies.indices where entity.bodyIDs.contains(modelBodies[i].id) {
            modelBodies[i].isVisible = isVisible
        }
        rebuildBodies()
    }

    /// Frames the camera on the union of bounds of the given entities. No-op if none of
    /// `ids` are currently loaded.
    public func focus(on ids: [String]) {
        let shapes = ids.compactMap { shape(id: $0) }
        guard !shapes.isEmpty else { return }

        var minPt = SIMD3<Double>(repeating: .infinity)
        var maxPt = SIMD3<Double>(repeating: -.infinity)
        for s in shapes {
            let b = s.bounds
            minPt = SIMD3(min(minPt.x, b.min.x), min(minPt.y, b.min.y), min(minPt.z, b.min.z))
            maxPt = SIMD3(max(maxPt.x, b.max.x), max(maxPt.y, b.max.y), max(maxPt.z, b.max.z))
        }
        let center = SIMD3<Float>(
            Float((minPt.x + maxPt.x) / 2),
            Float((minPt.y + maxPt.y) / 2),
            Float((minPt.z + maxPt.z) / 2)
        )
        let maxDim = Float(max(maxPt.x - minPt.x, max(maxPt.y - minPt.y, maxPt.z - minPt.z)))
        controller.focusOn(point: center, distance: maxDim * 2.5)
    }

    // MARK: - Scalar Fields

    /// Paints (or clears, with `nil`) a scalar field over a loaded body — rebuilds that
    /// body's `TriangleStyle` buffer to reflect it. Currently rebuilds the whole body (a
    /// fresh `generation`, so a full vertex/index/edge re-upload alongside the style
    /// buffer) rather than mutating `triangleStyles` in place, because `OCCTSwiftViewport`
    /// (pinned floor 1.1.26) doesn't actually apply an in-place style-only mutation to an
    /// already-rendered body — its renderer only rebuilds a body's GPU buffers when
    /// `generation` changes, which an in-place mutation never does. See
    /// `applyTriangleStyles`'s own doc comment for how this was confirmed.
    public func setScalarField(_ field: ScalarField?, forBody id: String) {
        guard let field else {
            scalarFields.removeValue(forKey: id)
            if lastScalarFieldBodyID == id {
                lastScalarFieldBodyID = nil
            }
            applyTriangleStyles(nil, forBody: id)
            return
        }
        scalarFields[id] = field
        lastScalarFieldBodyID = id
        applyTriangleStyles(field, forBody: id)
    }

    /// The scalar field currently painted on a body, or `nil`.
    public func scalarField(forBody id: String) -> ScalarField? {
        scalarFields[id]
    }

    /// Legend for the most recently set (still-active) scalar field — label, unit, range,
    /// and evenly-spaced color stops a UI can lay out as a gradient bar or discrete
    /// swatches. `nil` if no field is currently set on any body.
    public var scalarFieldLegend: ScalarFieldLegend? {
        guard let bodyID = lastScalarFieldBodyID, let field = scalarFields[bodyID],
              let range = field.effectiveRange else {
            return nil
        }
        let stopCount = 9
        let stops = (0..<stopCount).map { i -> LegendStop in
            let t = Double(i) / Double(stopCount - 1)
            let value = range.lowerBound + t * (range.upperBound - range.lowerBound)
            return LegendStop(value: value, color: field.colorMap.color(for: value, in: range))
        }
        return ScalarFieldLegend(label: field.label, unit: field.unit, range: range, stops: stops)
    }

    /// Builds a `TriangleStyle` per triangle from `field` (`nil`, or a field whose
    /// `effectiveRange` is `nil`, clears every style back to empty — not a full array of
    /// `.none`; `ViewportBody.triangleStyles`'s own contract distinguishes "empty" (skips
    /// the highlight pass for this body entirely) from "populated but all zero-alpha"
    /// (still builds a style buffer and runs the pass, just compositing nothing) — and
    /// writes it into `id`'s body. See this method's implementation comment below for why
    /// that's a full body reconstruction rather than an in-place `triangleStyles` mutation.
    private func applyTriangleStyles(_ field: ScalarField?, forBody id: String) {
        guard let index = modelBodies.firstIndex(where: { $0.id == id }) else { return }
        let body = modelBodies[index]
        let triCount = body.indices.count / 3
        var styles: [TriangleStyle] = []

        if let field, let range = field.effectiveRange {
            styles = [TriangleStyle](repeating: .none, count: triCount)
            switch field.domain {
            case .perTriangle:
                for tri in 0..<triCount where tri < field.values.count {
                    let value = field.values[tri]
                    guard !value.isNaN else { continue }
                    styles[tri] = TriangleStyle(color: field.colorMap.color(for: value, in: range))
                }
            case .perFace:
                for tri in 0..<triCount where tri < body.faceIndices.count {
                    let faceIndex = Int(body.faceIndices[tri])
                    guard faceIndex >= 0, faceIndex < field.values.count else { continue }
                    let value = field.values[faceIndex]
                    guard !value.isNaN else { continue }
                    styles[tri] = TriangleStyle(color: field.colorMap.color(for: value, in: range))
                }
            }
        }

        // Rebuilds the body rather than mutating `triangleStyles` in place, even though
        // `_ViewportBody.triangleStyles`'s own doc comment says an in-place mutation
        // "forces the renderer to upload a fresh per-triangle style buffer" while
        // preserving the rest of the body's GPU state. Empirically verified (against
        // OCCTSwiftViewport's pinned 1.1.26 via its OffscreenRenderer, on an
        // already-rendered body) that this isn't actually true today:
        // `ViewportRenderer`/`OffscreenRenderer.ensureBuffers(for:)` gate ALL buffer
        // work — including the triangle-style buffer — behind a check that only looks
        // at `body.generation`, which an in-place `triangleStyles` mutation never
        // changes (`generation` is a `let`, fixed at `init`). A body already on screen
        // when this ran would silently keep whatever style buffer it had before,
        // regardless of the new styles just computed above. Reconstructing the body
        // mints a fresh `generation`, which does force a real rebuild — at the cost of
        // a full vertex/index/edge re-upload alongside the style buffer, since
        // OCCTSwiftViewport has no coarser-than-"whole body" cache key to target. This
        // is a workaround for what looks like an upstream bug, not a design choice; once
        // OCCTSwiftViewport's caching can distinguish a style-only change, this should
        // go back to the in-place mutation to actually deliver the cheap update its own
        // API promises.
        modelBodies[index] = _ViewportBody(
            id: body.id,
            vertexData: body.vertexData,
            indices: body.indices,
            edges: body.edges,
            arcs: body.arcs,
            faceIndices: body.faceIndices,
            edgeIndices: body.edgeIndices,
            vertices: body.vertices,
            vertexIndices: body.vertexIndices,
            vertexColors: body.vertexColors,
            triangleStyles: styles,
            color: body.color,
            roughness: body.roughness,
            metallic: body.metallic,
            material: body.material,
            pointRadius: body.pointRadius,
            primitiveKind: body.primitiveKind,
            isVisible: body.isVisible,
            isPickable: body.isPickable,
            renderLayer: body.renderLayer,
            pickLayer: body.pickLayer,
            transform: body.transform,
            meshPositions: body.meshPositions,
            meshNormals: body.meshNormals
        )
        rebuildBodies()
    }

    /// The scalar value at a resolved face pick, if a field is set on that body — `nil`
    /// domain matches `PickedFaceInfo.faceIndex`/`triangleIndex` per `ScalarField.Domain`.
    private func scalarValue(forBody bodyID: String, faceIndex: Int, triangleIndex: Int) -> Double? {
        guard let field = scalarFields[bodyID] else { return nil }
        switch field.domain {
        case .perFace:
            return faceIndex >= 0 && faceIndex < field.values.count ? field.values[faceIndex] : nil
        case .perTriangle:
            return triangleIndex >= 0 && triangleIndex < field.values.count ? field.values[triangleIndex] : nil
        }
    }

    private func focusOnLoadedShape() {
        guard let shape = currentSingleShape else { return }
        let b = shape.bounds
        let center = SIMD3<Float>(
            Float((b.min.x + b.max.x) / 2),
            Float((b.min.y + b.max.y) / 2),
            Float((b.min.z + b.max.z) / 2)
        )
        let maxDim = Float(max(b.max.x - b.min.x, max(b.max.y - b.min.y, b.max.z - b.min.z)))
        controller.focusOn(point: center, distance: maxDim * 2.5)
    }

    // MARK: - Shape Info

    public struct ShapeBounds: Sendable, Equatable {
        public let minX: Double, minY: Double, minZ: Double
        public let maxX: Double, maxY: Double, maxZ: Double
        public var sizeX: Double { maxX - minX }
        public var sizeY: Double { maxY - minY }
        public var sizeZ: Double { maxZ - minZ }
    }

    public var shapeBounds: ShapeBounds? {
        guard let shape = currentSingleShape else { return nil }
        let b = shape.bounds
        return ShapeBounds(
            minX: b.min.x, minY: b.min.y, minZ: b.min.z,
            maxX: b.max.x, maxY: b.max.y, maxZ: b.max.z
        )
    }

    // MARK: - Overlay Layers

    /// Add or replace a named overlay layer. The bodies are composited with
    /// the model + selection highlight on every viewport rebuild. Use this
    /// for stock boxes, toolpath polylines, flat-pattern outlines, bend
    /// strips, custom annotations — anything that isn't part of the imported
    /// model.
    public func setOverlay(id: String, bodies: [_ViewportBody]) {
        overlays[id] = bodies
        rebuildBodies()
    }

    /// Remove a named overlay layer.
    public func clearOverlay(id: String) {
        overlays.removeValue(forKey: id)
        rebuildBodies()
    }

    /// Remove every overlay layer. Model bodies and selection are unaffected.
    public func clearAllOverlays() {
        overlays.removeAll()
        rebuildBodies()
    }

    /// Sorted list of overlay layer ids currently in the viewport.
    public var overlayIDs: [String] { overlays.keys.sorted() }

    // MARK: - Selection

    /// Clear the current selection (and any highlight bodies).
    public func clearSelection() {
        selection = []
        selectionBodies = []
        rebuildBodies()
    }

    /// Adds, removes, or replaces `entity` in `selection` per `scheme` — mirrors
    /// `OCCTSwiftAIS.SelectionScheme`'s exact combination semantics (`.replace` assigns,
    /// `.add`/`.remove`/`.xor` combine against the current selection), just applied to one
    /// entity here rather than a batch region match. Membership uses `PickedEntity`'s own
    /// `Equatable` (`uid`-preferring, so the same durable face/edge/vertex is recognized as
    /// already-selected regardless of which ephemeral ordinal it was picked at).
    public func select(_ entity: PickedEntity, scheme: SelectionScheme = .replace) {
        switch scheme {
        case .replace:
            selection = [entity]
        case .add:
            if !selection.contains(entity) {
                selection.append(entity)
            }
        case .remove:
            selection.removeAll { $0 == entity }
        case .xor:
            if let index = selection.firstIndex(of: entity) {
                selection.remove(at: index)
            } else {
                selection.append(entity)
            }
        }
        rebuildSelectionHighlights()
    }

    /// Aggregate measures over `selection` — count by kind, total face area, total edge
    /// length, and combined bounds. `nil` when nothing is selected.
    public var selectionSummary: SelectionSummary? {
        guard !selection.isEmpty else { return nil }

        var faceCount = 0, edgeCount = 0, vertexCount = 0
        var totalArea = 0.0, totalLength = 0.0
        var minPt = SIMD3<Double>(repeating: .infinity)
        var maxPt = SIMD3<Double>(repeating: -.infinity)

        func absorb(_ bounds: (min: SIMD3<Double>, max: SIMD3<Double>)) {
            minPt = SIMD3(min(minPt.x, bounds.min.x), min(minPt.y, bounds.min.y), min(minPt.z, bounds.min.z))
            maxPt = SIMD3(max(maxPt.x, bounds.max.x), max(maxPt.y, bounds.max.y), max(maxPt.z, bounds.max.z))
        }

        for entity in selection {
            switch entity {
            case .face(let info):
                faceCount += 1
                totalArea += info.area
                if let face = Face(info.shape) {
                    absorb(face.bounds)
                }
            case .edge(let info):
                edgeCount += 1
                totalLength += info.length
                // Uses the endpoints already captured on PickedEdgeInfo at pick time,
                // rather than re-deriving via Edge(info.shape) — cheaper, and immune to
                // that conversion failing for a straight line (bounds is exact either way;
                // a curved edge's true bounds can bow slightly outside its endpoints, but
                // this is a selection-level aggregate, not a precision measurement).
                absorb((
                    min: SIMD3(min(info.startPoint.x, info.endPoint.x), min(info.startPoint.y, info.endPoint.y), min(info.startPoint.z, info.endPoint.z)),
                    max: SIMD3(max(info.startPoint.x, info.endPoint.x), max(info.startPoint.y, info.endPoint.y), max(info.startPoint.z, info.endPoint.z))
                ))
            case .vertex(let info):
                vertexCount += 1
                absorb((min: info.position, max: info.position))
            }
        }

        let bounds: ShapeBounds? = minPt.x.isFinite ? ShapeBounds(
            minX: minPt.x, minY: minPt.y, minZ: minPt.z,
            maxX: maxPt.x, maxY: maxPt.y, maxZ: maxPt.z
        ) : nil

        return SelectionSummary(
            faceCount: faceCount,
            edgeCount: edgeCount,
            vertexCount: vertexCount,
            totalArea: totalArea,
            totalLength: totalLength,
            bounds: bounds
        )
    }

    private func handlePick(_ result: _PickResult?) {
        guard let result, let entity = resolveEntityPick(result) else {
            clearSelection()
            return
        }

        // A real viewport pick always replaces — matches OCCTSwiftAIS's own point-pick
        // behavior. `select(_:scheme:)` is how a caller builds a multi-selection
        // programmatically (there's no modifier-key state in a GPU pick result to infer a
        // scheme from).
        select(entity, scheme: .replace)
    }

    /// Dispatches a GPU pick to the resolver for its kind, gated by `selectionModes`.
    private func resolveEntityPick(_ result: _PickResult) -> PickedEntity? {
        switch result.kind {
        case .face:
            return resolveFacePick(bodyID: result.bodyID, triangleIndex: result.triangleIndex).map(PickedEntity.face)
        case .edge:
            return resolveEdgePick(bodyID: result.bodyID, segmentIndex: result.triangleIndex).map(PickedEntity.edge)
        case .vertex:
            return resolveVertexPick(bodyID: result.bodyID, pointIndex: result.triangleIndex).map(PickedEntity.vertex)
        }
    }

    /// Resolves a triangle-level GPU pick to durable face identity via the picked body's
    /// `FaceIdentityTable`. `internal` rather than `private` so it can be exercised
    /// directly in tests without round-tripping through the viewport's async pick
    /// callback — `handlePick` is the only production caller.
    func resolveFacePick(bodyID: String, triangleIndex: Int) -> PickedFaceInfo? {
        guard selectionModes.contains(.face) else { return nil }
        guard let meta = metadata[bodyID],
              triangleIndex >= 0, triangleIndex < meta.faceIndices.count else {
            return nil
        }

        let faceIndex = Int(meta.faceIndices[triangleIndex])
        guard faceIndex >= 0 else { return nil }

        let identity = faceIdentity[bodyID]
        var faceShape = identity?.shape(forOrdinal: faceIndex)
        if faceShape == nil, let faces = bodyShapes[bodyID]?.faces(), faceIndex < faces.count {
            faceShape = OCCTSwift.Shape.fromFace(faces[faceIndex])
        }
        guard let faceShape, let face = Face(faceShape) else { return nil }
        let uid = identity?.uid(forOrdinal: faceIndex)

        let isHoriz = face.isHorizontal()
        let isVert = face.isVertical()
        let faceBounds = face.bounds
        let faceArea = face.area()
        let zLevel = face.zLevel.map { Float($0) }

        let bounds = FaceBounds(
            minX: Float(faceBounds.min.x),
            maxX: Float(faceBounds.max.x),
            minY: Float(faceBounds.min.y),
            maxY: Float(faceBounds.max.y)
        )

        let typeStr = isHoriz ? "Horizontal" : (isVert ? "Vertical" : "Angled")
        let sizeStr = String(format: "%.1fx%.1f", bounds.width, bounds.height)
        let zStr = zLevel.map { String(format: " at Z=%.1f", $0) } ?? ""
        let desc = "\(typeStr) face\(zStr), \(sizeStr)mm"

        return PickedFaceInfo(
            shape: faceShape,
            uid: uid,
            faceIndex: faceIndex,
            bodyID: bodyID,
            isHorizontal: isHoriz,
            isVertical: isVert,
            bounds: bounds,
            zLevel: zLevel,
            area: faceArea,
            description: desc,
            scalarValue: scalarValue(forBody: bodyID, faceIndex: faceIndex, triangleIndex: triangleIndex)
        )
    }

    /// Resolves a line-segment-level GPU pick to durable edge identity via the picked
    /// body's `EdgeIdentityTable`. Reads `edgeIndices` off the `_ViewportBody` itself
    /// (unlike faces, `CADBodyMetadata` carries edge data as per-polyline groups, not a
    /// flat per-segment array) — a body with no `edgeIndices` populated (not edge-pickable,
    /// per `ViewportBody`'s own documentation) degrades to `nil` here rather than
    /// mis-picking. `internal` for the same testability reason as `resolveFacePick`.
    func resolveEdgePick(bodyID: String, segmentIndex: Int) -> PickedEdgeInfo? {
        guard selectionModes.contains(.edge) else { return nil }
        guard let body = modelBodies.first(where: { $0.id == bodyID }),
              segmentIndex >= 0, segmentIndex < body.edgeIndices.count else {
            return nil
        }

        let edgeIndex = Int(body.edgeIndices[segmentIndex])
        guard edgeIndex >= 0 else { return nil }

        let identity = edgeIdentity[bodyID]
        var edgeShape = identity?.shape(forOrdinal: edgeIndex)
        if edgeShape == nil, let edges = bodyShapes[bodyID]?.edges(), edgeIndex < edges.count {
            edgeShape = OCCTSwift.Shape.fromEdge(edges[edgeIndex])
        }
        guard let edgeShape, let edge = Edge(edgeShape) else { return nil }
        let uid = identity?.uid(forOrdinal: edgeIndex)

        let endpoints = edge.endpoints
        let typeStr: String
        switch edge.curveType {
        case .line: typeStr = "Line"
        case .circle: typeStr = "Circle"
        case .ellipse: typeStr = "Ellipse"
        case .hyperbola: typeStr = "Hyperbola"
        case .parabola: typeStr = "Parabola"
        case .bezierCurve: typeStr = "Bezier"
        case .bsplineCurve: typeStr = "B-spline"
        case .offsetCurve: typeStr = "Offset curve"
        case .other: typeStr = "Curve"
        }
        let desc = "\(typeStr) edge, \(String(format: "%.1f", edge.length))mm"

        return PickedEdgeInfo(
            shape: edgeShape,
            uid: uid,
            edgeIndex: edgeIndex,
            bodyID: bodyID,
            curveType: edge.curveType,
            length: edge.length,
            startPoint: endpoints.start,
            endPoint: endpoints.end,
            description: desc
        )
    }

    /// Resolves a point-sprite-level GPU pick to durable vertex identity via the picked
    /// body's `VertexIdentityTable`. A body with no `vertices` populated (not
    /// vertex-pickable) degrades to `nil` here rather than mis-picking. `internal` for the
    /// same testability reason as `resolveFacePick`.
    func resolveVertexPick(bodyID: String, pointIndex: Int) -> PickedVertexInfo? {
        guard selectionModes.contains(.vertex) else { return nil }
        guard let body = modelBodies.first(where: { $0.id == bodyID }),
              pointIndex >= 0, pointIndex < body.vertices.count else {
            return nil
        }

        // `vertexIndices` empty means identity mapping (pointIndex is the ordinal itself),
        // per ViewportBody's own documentation. Deliberately more complete here than
        // OCCTSwiftAIS's own resolveVertexSubShape, which bounds-checks against
        // `vertexIndices.count` directly and so never resolves a pick when it's empty —
        // unreached in practice since CADFileLoader always populates both arrays in
        // lockstep for a real body, but this implements the documented fallback in full.
        let vertexIndex = pointIndex < body.vertexIndices.count ? Int(body.vertexIndices[pointIndex]) : pointIndex
        guard vertexIndex >= 0 else { return nil }

        let identity = vertexIdentity[bodyID]
        var vertexShape = identity?.shape(forOrdinal: vertexIndex)
        if vertexShape == nil, let vertices = bodyShapes[bodyID]?.subShapes(ofType: .vertex),
           vertexIndex < vertices.count {
            vertexShape = vertices[vertexIndex]
        }
        guard let vertexShape else { return nil }
        let uid = identity?.uid(forOrdinal: vertexIndex)

        let renderPosition = body.vertices[pointIndex]
        let position = vertexShape.vertices().first ?? SIMD3<Double>(
            Double(renderPosition.x), Double(renderPosition.y), Double(renderPosition.z)
        )
        let desc = String(format: "Vertex at (%.1f, %.1f, %.1f)mm", position.x, position.y, position.z)

        return PickedVertexInfo(
            shape: vertexShape,
            uid: uid,
            vertexIndex: vertexIndex,
            bodyID: bodyID,
            position: position,
            description: desc
        )
    }

    /// Rebuilds the highlight bodies from the whole `selection` (not just the latest
    /// pick), grouped by kind — up to three bodies: a translucent yellow triangle patch
    /// aggregating every selected face's own triangles, a bright cyan polyline aggregating
    /// every selected edge's own segments, and a bright magenta point sprite body for every
    /// selected vertex's own position. Bodies loaded via `load(_:id:transform:)` are always
    /// in world-space already (the transform is baked into the shape before tessellation,
    /// not applied as a separate `_ViewportBody.transform`), so combining geometry gathered
    /// from different source bodies into one aggregate highlight body is safe.
    private func rebuildSelectionHighlights() {
        let stride = 6 // interleaved [px,py,pz,nx,ny,nz]
        var faceVerts: [Float] = []
        var faceIndices: [UInt32] = []
        var faceVertCount: UInt32 = 0
        var edgeSegments: [[SIMD3<Float>]] = []
        var vertexPoints: [SIMD3<Float>] = []

        for entity in selection {
            switch entity {
            case .face(let info):
                guard let body = modelBodies.first(where: { $0.id == info.bodyID }),
                      let meta = metadata[info.bodyID] else { continue }
                let faceIndex = Int32(info.faceIndex)
                let triCount = body.indices.count / 3
                for tri in 0..<triCount {
                    guard tri < meta.faceIndices.count, meta.faceIndices[tri] == faceIndex else { continue }
                    let i0 = Int(body.indices[tri * 3])
                    let i1 = Int(body.indices[tri * 3 + 1])
                    let i2 = Int(body.indices[tri * 3 + 2])
                    for idx in [i0, i1, i2] {
                        let base = idx * stride
                        guard base + stride <= body.vertexData.count else { continue }
                        faceVerts.append(contentsOf: body.vertexData[base..<(base + stride)])
                        faceIndices.append(faceVertCount)
                        faceVertCount += 1
                    }
                }

            case .edge(let info):
                guard let body = modelBodies.first(where: { $0.id == info.bodyID }) else { continue }
                let edgeIndex = Int32(info.edgeIndex)
                var segmentCursor = 0
                for polyline in body.edges {
                    let segmentCount = max(polyline.count - 1, 0)
                    guard segmentCount > 0 else { continue }
                    for s in 0..<segmentCount {
                        defer { segmentCursor += 1 }
                        guard segmentCursor < body.edgeIndices.count,
                              body.edgeIndices[segmentCursor] == edgeIndex else { continue }
                        edgeSegments.append([polyline[s], polyline[s + 1]])
                    }
                }

            case .vertex(let info):
                vertexPoints.append(SIMD3<Float>(
                    Float(info.position.x), Float(info.position.y), Float(info.position.z)
                ))
            }
        }

        var bodies: [_ViewportBody] = []
        if !faceIndices.isEmpty {
            bodies.append(_ViewportBody(
                id: "selection_highlight_face",
                vertexData: faceVerts,
                indices: faceIndices,
                edges: [],
                color: SIMD4<Float>(1.0, 0.9, 0.0, 0.5)
            ))
        }
        if !edgeSegments.isEmpty {
            bodies.append(_ViewportBody(
                id: "selection_highlight_edge",
                vertexData: [],
                indices: [],
                edges: edgeSegments,
                color: SIMD4<Float>(0.1, 0.9, 1.0, 1.0)
            ))
        }
        if !vertexPoints.isEmpty {
            bodies.append(_ViewportBody(
                id: "selection_highlight_vertex",
                vertexData: [],
                indices: [],
                edges: [],
                vertices: vertexPoints,
                vertexIndices: (0..<vertexPoints.count).map(Int32.init),
                color: SIMD4<Float>(1.0, 0.15, 0.9, 1.0),
                pointRadius: 6,
                primitiveKind: .point
            ))
        }

        selectionBodies = bodies
        rebuildBodies()
    }

    // MARK: - Private

    private func rebuildBodies() {
        var fresh: [_ViewportBody] = []
        fresh.append(contentsOf: modelBodies)
        for key in overlays.keys.sorted() {
            fresh.append(contentsOf: overlays[key] ?? [])
        }
        fresh.append(contentsOf: selectionBodies)

        let newIDs = Set(fresh.map { $0.id })
        let toRemove = ownedBodyIDs.union(newIDs)

        var combined = interactiveContext.bodies
        combined.removeAll { toRemove.contains($0.id) }
        combined.append(contentsOf: fresh)

        interactiveContext.bodies = combined
        ownedBodyIDs = newIDs
    }
}
