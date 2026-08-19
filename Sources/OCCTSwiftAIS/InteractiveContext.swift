import Combine
import Foundation
import OCCTSwift
import OCCTSwiftTools
import OCCTSwiftViewport
import simd

/// Per-scene interactive state.
///
/// One `InteractiveContext` ↔ one `ViewportController`.
///
/// The context owns the array of `ViewportBody`s rendered by `MetalViewportView`.
/// Bind it via `MetalViewportView(controller: ctx.viewport, bodies: $ctx.bodies)`
/// when `ctx` is a `@StateObject`.
///
/// ## Selection semantics
/// - `select(_:)` / `deselect(_:)` mutate the selection as a `Set`: adding the
///   same sub-shape twice is idempotent.
/// - A pick event from the viewport **replaces** the selection with the picked
///   sub-shape. Empty-space picks (`pickResult == nil`) leave the selection alone.
/// - Changing `selectionMode` clears the current selection.
@MainActor
public final class InteractiveContext: ObservableObject {

    // MARK: - Inputs

    public let viewport: ViewportController

    // MARK: - Scene

    /// Bodies fed to `MetalViewportView`.
    ///
    /// Bind via `$bodies`.
    @Published public var bodies: [ViewportBody] = []

    // MARK: - Selection

    @Published public var selectionMode: Set<SelectionMode> = [.body] {
        didSet {
            if oldValue != selectionMode { clearSelection() }
        }
    }

    @Published public private(set) var selection: Selection = Selection() {
        didSet {
            if oldValue != selection { updateSelectionVisuals() }
        }
    }
    @Published public private(set) var hover: SubShape? = nil

    /// Filters gating `handlePick` / `handleHover`, never programmatic
    /// `select(_:)`.
    ///
    /// See `SelectionFilter.swift` for the combination semantics (AND across
    /// installed filters, a deliberate departure from OCCT's OR).
    @Published public private(set) var filters: [any SelectionFilter] = []

    // MARK: - Style

    public var highlightStyle: HighlightStyle = .default

    /// Dimensions added via `add(_:)`.
    ///
    /// Strongly held so the dimension lives as long as it's displayed; weak
    /// refs would let user-discarded dimensions vanish from the scene.
    var dimensionRegistry: [ObjectIdentifier: any Dimension] = [:]

    // MARK: - Registry

    private struct Entry {
        let object: InteractiveObject
        let bodyID: String
        let metadata: CADBodyMetadata?
        /// Per-ordinal (Shape, GraphUID) correspondence captured at tessellation
        /// time, one table per pickable kind (OCCTSwiftTools#43/#44).
        let faceIdentity: FaceIdentityTable?
        let edgeIdentity: EdgeIdentityTable?
        let vertexIdentity: VertexIdentityTable?
        /// Living per-object graph, built once at `display(_:style:)` and
        /// retained across `update(_:to:absorbing:operationName:)` calls so
        /// `GraphUID`s minted at pick time keep resolving; see Remap.swift.
        let graph: BRepGraph?
        var style: PresentationStyle
    }
    private var entriesByID: [UUID: Entry] = [:]
    private var entriesByBodyID: [String: UUID] = [:]

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    public init(viewport: ViewportController) {
        self.viewport = viewport

        viewport.$pickResult
            .dropFirst()
            .sink { [weak self] result in
                MainActor.assumeIsolated {
                    self?.handlePick(result)
                }
            }
            .store(in: &cancellables)

        viewport.$hoveredBodyID
            .dropFirst()
            .sink { [weak self] bodyID in
                MainActor.assumeIsolated {
                    self?.handleHover(bodyID: bodyID)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Display

    /// Display a shape with topology-aware selection enabled.
    ///
    /// Builds a `BRepGraph` from `shape` and retains it for the object's
    /// lifetime; see `update(_:to:absorbing:operationName:)` for how it's used
    /// to carry a selection across a later mutation. Graph construction can
    /// fail on pathological shapes; when it does, the object still displays but
    /// picks against it mint `SubShapeRef`s with `uid == nil` (ordinal-only:
    /// `remap` then has nothing durable to resolve them by).
    @discardableResult
    public func display(_ shape: Shape, style: PresentationStyle = .default) -> InteractiveObject {
        let object = InteractiveObject(shape: shape)
        let bodyID = "ais.\(object.id.uuidString)"
        let rgba = SIMD4<Float>(style.color, 1.0 - style.transparency)

        let graph = BRepGraph(shape: shape)
        graph?.isHistoryEnabled = true

        let (body, metadata, faceIdentity, edgeIdentity, vertexIdentity) =
            CADFileLoader.shapeToBodyMetadataAndIdentities(
                shape, id: bodyID, color: rgba, graph: graph
            )

        if var body {
            body.isVisible = style.visible
            bodies.append(body)
        }

        entriesByID[object.id] = Entry(
            object: object, bodyID: bodyID, metadata: metadata,
            faceIdentity: faceIdentity, edgeIdentity: edgeIdentity, vertexIdentity: vertexIdentity,
            graph: graph, style: style
        )
        entriesByBodyID[bodyID] = object.id
        return object
    }

    /// Update a displayed object after a modelling operation that rebuilds its
    /// shape: a boolean, a fillet, a chamfer, anything produced via one of
    /// OCCTSwift's `*WithFullHistory` methods run against `object.shape`.
    ///
    /// Absorbs the operation's history into the object's living `BRepGraph`
    /// (built once in `display(_:style:)`, retained here across calls: the
    /// input and result share one graph instance, so every `GraphUID` already
    /// held stays resolvable; see `BRepGraph.add(_:absorbing:inputRoots:operationName:)`),
    /// rebuilds the displayed mesh for `newShape`, and remaps any current
    /// `selection` / `hover` sub-shapes referencing `object` forward via
    /// `remap(_:using:rebindingTo:)`.
    ///
    /// `object.id` is unchanged; the returned `InteractiveObject` carries
    /// `newShape`. Returns `nil` if `object` isn't displayed, has no living
    /// graph (construction failed at `display` time), or the absorb fails;
    /// in any of those cases the caller should `remove` and `display` fresh,
    /// accepting that the selection doesn't survive.
    ///
    /// Sub-shapes whose node was deleted by the operation are dropped from the
    /// selection silently; call `isDeleted(_:in:)` beforehand (using the same
    /// `graph`, obtainable from this same call's absorb) to distinguish that
    /// from "wasn't selected".
    @discardableResult
    public func update(
        _ object: InteractiveObject,
        to newShape: Shape,
        absorbing history: ShapeHistoryRef,
        operationName: String
    ) -> InteractiveObject? {
        guard let entry = entriesByID[object.id], let graph = entry.graph else { return nil }
        guard let inputRoot = graph.findNode(for: entry.object.shape) else { return nil }
        let rootRef = BRepGraph.NodeRef(kind: inputRoot.kind, index: inputRoot.index)
        guard
            graph.add(
                newShape, absorbing: history, inputRoots: [rootRef], operationName: operationName)
                != nil
        else {
            return nil
        }

        let updated = InteractiveObject(id: object.id, shape: newShape)
        let rgba = SIMD4<Float>(entry.style.color, 1.0 - entry.style.transparency)
        let (body, metadata, faceIdentity, edgeIdentity, vertexIdentity) =
            CADFileLoader.shapeToBodyMetadataAndIdentities(
                newShape, id: entry.bodyID, color: rgba, graph: graph
            )

        if let i = bodies.firstIndex(where: { $0.id == entry.bodyID }) {
            if var body {
                body.isVisible = entry.style.visible
                bodies[i] = body
            } else {
                bodies.remove(at: i)
            }
        }

        entriesByID[object.id] = Entry(
            object: updated, bodyID: entry.bodyID, metadata: metadata,
            faceIdentity: faceIdentity, edgeIdentity: edgeIdentity, vertexIdentity: vertexIdentity,
            graph: graph, style: entry.style
        )

        let ownSubshapes = selection.subshapes.filter { $0.object.id == object.id }
        let otherSubshapes = selection.subshapes.subtracting(ownSubshapes)
        let remapped = remap(Selection(ownSubshapes), using: graph, rebindingTo: updated)
        selection = Selection(otherSubshapes.union(remapped.subshapes))

        if let h = hover, h.object.id == object.id {
            let remappedHover = remap(Selection([h]), using: graph, rebindingTo: updated)
            hover = remappedHover.subshapes.first
        }

        return updated
    }

    public func remove(_ object: InteractiveObject) {
        guard let entry = entriesByID.removeValue(forKey: object.id) else { return }
        entriesByBodyID.removeValue(forKey: entry.bodyID)
        bodies.removeAll { $0.id == entry.bodyID }

        let dropped = selection.subshapes.filter { $0.object.id == object.id }
        if !dropped.isEmpty {
            selection = Selection(selection.subshapes.subtracting(dropped))
        }
        if let h = hover, h.object.id == object.id {
            hover = nil
        }
    }

    public func removeAll() {
        bodies.removeAll()
        entriesByID.removeAll()
        entriesByBodyID.removeAll()
        selection = Selection()
        hover = nil
        dimensionRegistry.removeAll()
        viewport.measurements.removeAll()
    }

    // MARK: - Selection mutation

    /// Add a sub-shape to the current selection.
    ///
    /// Idempotent.
    public func select(_ subshape: SubShape) {
        var s = selection.subshapes
        s.insert(subshape)
        selection = Selection(s)
    }

    public func deselect(_ subshape: SubShape) {
        var s = selection.subshapes
        s.remove(subshape)
        selection = Selection(s)
    }

    public func clearSelection() {
        selection = Selection()
    }

    /// Replace `selection` wholesale.
    ///
    /// Used by `AreaSelection.swift` after combining a rectangle/lasso match
    /// set with the existing selection per `SelectionScheme`; kept internal
    /// since `select`/`deselect`/`clearSelection` are the intended public
    /// mutation surface.
    func setSelection(_ newSelection: Selection) {
        selection = newSelection
    }

    // MARK: - Selection filters

    /// Add a selection filter.
    ///
    /// Installed filters gate `handlePick` and `handleHover`, never
    /// programmatic `select(_:)`. A candidate a filter rejects is treated
    /// exactly like an empty-space pick: the current selection is left
    /// unchanged, not cleared.
    public func addFilter(_ filter: any SelectionFilter) {
        filters.append(filter)
    }

    /// Remove a previously-installed filter, by reference identity.
    public func removeFilter(_ filter: any SelectionFilter) {
        filters.removeAll { $0 === filter }
    }

    /// Remove every installed filter, restoring unrestricted picking.
    public func removeAllFilters() {
        filters.removeAll()
    }

    /// Whether `candidate` passes every currently-installed filter.
    ///
    /// **Combination semantics: a deliberate departure from OCCT.** OCCT's
    /// `AIS_InteractiveContext::AddFilter` combines multiple installed filters
    /// with OR (a candidate is kept if *any* installed filter accepts it), which
    /// reads as a surprising default for narrowing what's selectable: the
    /// second filter you add can only ever *widen* what's pickable, never narrow
    /// it further. Here, installed filters combine with **AND**: a candidate
    /// must pass *every* installed filter. Express OR explicitly with
    /// `AnyOfFilter` when you actually want it.
    func passesInstalledFilters(_ candidate: SubShape) -> Bool {
        filters.allSatisfy { $0.accepts(candidate) }
    }

    // MARK: - Style

    public func setStyle(_ style: PresentationStyle, for object: InteractiveObject) {
        guard var entry = entriesByID[object.id] else { return }
        entry.style = style
        entriesByID[object.id] = entry

        if let i = bodies.firstIndex(where: { $0.id == entry.bodyID }) {
            bodies[i].color = SIMD4<Float>(style.color, 1.0 - style.transparency)
            bodies[i].isVisible = style.visible
        }
    }

    public func setHighlightStyle(_ style: HighlightStyle) {
        self.highlightStyle = style
        updateSelectionVisuals()
    }

    // MARK: - Internal accessors (used by ManipulatorWidget, AreaSelection)

    /// Every currently-displayed object, in no particular order.
    func displayedObjects() -> [InteractiveObject] {
        entriesByID.values.map(\.object)
    }

    /// Whether `object` is displayed and its `PresentationStyle.visible` flag
    /// is set.
    ///
    /// Area selection skips hidden objects: it shouldn't select what isn't
    /// visible on screen.
    func isVisible(_ object: InteractiveObject) -> Bool {
        entriesByID[object.id]?.style.visible ?? false
    }

    /// The body ID currently associated with `object`, or nil if not displayed.
    func bodyID(for object: InteractiveObject) -> String? {
        entriesByID[object.id]?.bodyID
    }

    /// The source `ViewportBody` for `object`, or nil if the object is not displayed
    /// or its tessellation produced no mesh.
    func sourceBody(for object: InteractiveObject) -> ViewportBody? {
        guard let id = entriesByID[object.id]?.bodyID else { return nil }
        return bodies.first { $0.id == id }
    }

    /// The identity tables captured for `object` at display/update time, or
    /// nil if not displayed or no graph was available to mint uids.
    ///
    /// Used by `remap(_:using:rebindingTo:)` in Remap.swift to assign a
    /// correct render-path ordinal to a remapped sub-shape (rather than
    /// falling back to the graph's raw node index, which isn't a
    /// tessellation ordinal), and by area selection to enumerate every
    /// candidate sub-shape's `Shape`.
    func faceIdentityTable(for object: InteractiveObject) -> FaceIdentityTable? {
        entriesByID[object.id]?.faceIdentity
    }

    func edgeIdentityTable(for object: InteractiveObject) -> EdgeIdentityTable? {
        entriesByID[object.id]?.edgeIdentity
    }

    func vertexIdentityTable(for object: InteractiveObject) -> VertexIdentityTable? {
        entriesByID[object.id]?.vertexIdentity
    }

    /// Append a body created by an internal subsystem (manipulator, dimension, …).
    ///
    /// The body is **not** registered as a selectable `InteractiveObject` and
    /// is invisible to selection / hover wiring.
    func appendInternalBody(_ body: ViewportBody) {
        bodies.append(body)
    }

    /// Remove every body whose id satisfies `predicate`.
    func removeInternalBodies(where predicate: (String) -> Bool) {
        bodies.removeAll { predicate($0.id) }
    }

    // MARK: - Highlight overlay (renderer-backed, OCCTSwiftViewport ≥ 0.55.1)

    /// Body-level selection → `viewport.selectedBodyIDs`.
    ///
    /// Face-level selection → per-triangle styles on the source body's
    /// `triangleStyles`. No overlay bodies, no normal-offset push.
    private func updateSelectionVisuals() {
        let selectedBodyIDs: Set<String> = Set(
            selection.subshapes.compactMap { sub -> String? in
                guard case .body(let obj) = sub else { return nil }
                return entriesByID[obj.id]?.bodyID
            }
        )
        viewport.selectedBodyIDs = selectedBodyIDs

        // Per-triangle highlight indexes by the render-path ordinal: that's
        // the only part of SubShapeRef the mesh knows about.
        var facesByObjectID: [UUID: Set<Int>] = [:]
        for sub in selection.subshapes {
            guard case .face(let obj, let ref) = sub else { continue }
            facesByObjectID[obj.id, default: []].insert(ref.ordinal)
        }

        let highlightRGBA = SIMD4<Float>(highlightStyle.selectionColor, 1.0)

        for (objectID, entry) in entriesByID {
            guard let bodyIdx = bodies.firstIndex(where: { $0.id == entry.bodyID }) else {
                continue
            }
            let triangleCount = bodies[bodyIdx].indices.count / 3
            guard triangleCount > 0, let metadata = entry.metadata,
                metadata.faceIndices.count == triangleCount
            else {
                if !bodies[bodyIdx].triangleStyles.isEmpty {
                    bodies[bodyIdx].triangleStyles = []
                }
                continue
            }
            let selectedFaces = facesByObjectID[objectID] ?? []
            if selectedFaces.isEmpty {
                if !bodies[bodyIdx].triangleStyles.isEmpty {
                    bodies[bodyIdx].triangleStyles = []
                }
            } else {
                let highlight = TriangleStyle(color: highlightRGBA)
                var styles = Array(repeating: TriangleStyle.none, count: triangleCount)
                for triIdx in 0..<triangleCount {
                    let faceIdx = Int(metadata.faceIndices[triIdx])
                    if selectedFaces.contains(faceIdx) {
                        styles[triIdx] = highlight
                    }
                }
                bodies[bodyIdx].triangleStyles = styles
            }
        }
    }

    // MARK: - Pick / hover wiring

    /// Internal entry point, also called from tests with a synthesised `PickResult`.
    func handlePick(_ result: PickResult?) {
        guard let result,
            let id = entriesByBodyID[result.bodyID],
            let entry = entriesByID[id]
        else { return }

        if let sub = resolveSubShape(from: result, entry: entry), passesInstalledFilters(sub) {
            selection = Selection([sub])
        }
    }

    func handleHover(bodyID: String?) {
        guard let bodyID,
            let id = entriesByBodyID[bodyID],
            let entry = entriesByID[id]
        else {
            hover = nil
            return
        }
        // Renderer publishes hover at body granularity; face/edge hover requires
        // a per-triangle hover stream that doesn't exist yet.
        let candidate: SubShape? = selectionMode.contains(.body) ? .body(entry.object) : nil
        hover = candidate.flatMap { passesInstalledFilters($0) ? $0 : nil }
    }

    private func resolveSubShape(from result: PickResult, entry: Entry) -> SubShape? {
        switch result.kind {
        case .face:
            return resolveFaceSubShape(from: result, entry: entry)
        case .edge:
            return resolveEdgeSubShape(from: result, entry: entry)
        case .vertex:
            return resolveVertexSubShape(from: result, entry: entry)
        }
    }

    private func resolveFaceSubShape(from result: PickResult, entry: Entry) -> SubShape? {
        if selectionMode.contains(.face),
            let metadata = entry.metadata,
            result.triangleIndex >= 0,
            result.triangleIndex < metadata.faceIndices.count
        {
            let faceIdx = Int(metadata.faceIndices[result.triangleIndex])
            // Prefer the FaceIdentityTable's Shape (captured at tessellation
            // time, always the exact face that ordinal came from) over
            // re-deriving it from the object's own sub-shape enumeration,
            // which need not agree once a face is shared between shells.
            if faceIdx >= 0,
                let faceShape = entry.faceIdentity?.shape(forOrdinal: faceIdx)
                    ?? entry.object.shape.subShape(type: .face, index: faceIdx)
            {
                let uid = entry.faceIdentity?.uid(forOrdinal: faceIdx)
                return .face(
                    entry.object, ref: SubShapeRef(shape: faceShape, uid: uid, ordinal: faceIdx))
            }
        }
        if selectionMode.contains(.body) {
            return .body(entry.object)
        }
        return nil
    }

    private func resolveEdgeSubShape(from result: PickResult, entry: Entry) -> SubShape? {
        guard selectionMode.contains(.edge) else { return nil }
        guard let body = bodies.first(where: { $0.id == entry.bodyID }) else { return nil }
        guard result.triangleIndex >= 0,
            result.triangleIndex < body.edgeIndices.count
        else { return nil }
        let edgeIdx = Int(body.edgeIndices[result.triangleIndex])
        guard edgeIdx >= 0,
            let edgeShape = entry.edgeIdentity?.shape(forOrdinal: edgeIdx)
                ?? entry.object.shape.subShape(type: .edge, index: edgeIdx)
        else { return nil }
        let uid = entry.edgeIdentity?.uid(forOrdinal: edgeIdx)
        return .edge(entry.object, ref: SubShapeRef(shape: edgeShape, uid: uid, ordinal: edgeIdx))
    }

    private func resolveVertexSubShape(from result: PickResult, entry: Entry) -> SubShape? {
        guard selectionMode.contains(.vertex) else { return nil }
        guard let body = bodies.first(where: { $0.id == entry.bodyID }) else { return nil }
        guard result.triangleIndex >= 0,
            result.triangleIndex < body.vertexIndices.count
        else { return nil }
        let vIdx = Int(body.vertexIndices[result.triangleIndex])
        guard vIdx >= 0,
            let vertexShape = entry.vertexIdentity?.shape(forOrdinal: vIdx)
                ?? entry.object.shape.subShape(type: .vertex, index: vIdx)
        else { return nil }
        let uid = entry.vertexIdentity?.uid(forOrdinal: vIdx)
        return .vertex(entry.object, ref: SubShapeRef(shape: vertexShape, uid: uid, ordinal: vIdx))
    }

}
