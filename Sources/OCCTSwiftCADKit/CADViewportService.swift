import Combine
import Foundation
import OCCTSwift
import OCCTSwiftAIS
import OCCTSwiftTools
import OCCTSwiftViewport
import SwiftUI
import simd

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
    /// Viewport controller: exposes camera, display mode, picking config, etc.
    ///
    /// Construct with custom configuration via `init(configuration:)`.
    public let controller: _ViewportController

    /// AIS interactive context backed by this service's viewport.
    ///
    /// Use to install `ManipulatorWidget`, add dimensions, or display extra
    /// `InteractiveObject`s. Bodies appended via `display(_:)` / `appendInternalBody(_:)` are
    /// composited with the CADKit-owned bodies (model + overlays + selection highlight) and
    /// rendered through the same array that `CADViewportView` binds to.
    public let interactiveContext: InteractiveContext

    /// All bodies currently displayed in the viewport.
    ///
    /// Composed of: model bodies (from imported file) + overlay layers (caller-managed) +
    /// selection highlight (managed internally on pick) + AIS-owned bodies (manipulator
    /// handles, displayed shapes, dimensions). Mirrors `interactiveContext.bodies`.
    public private(set) var bodies: [_ViewportBody] = []

    /// The loaded OCCTSwift shape, or `nil` until something is loaded.
    ///
    /// Set by the deprecated single-shape `loadFile(from:progress:)`/`loadShape(_:id:)`.
    /// The multi-entity API (`load(_:id:transform:)`/`loadFile(from:id:progress:)`) doesn't
    /// set it directly; the public `loadedShape` getter falls back to it when exactly one
    /// entity is loaded that way, matching this property's "single-shape convenience"
    /// contract either way.
    private var legacyLoadedShape: OCCTSwift.Shape?

    /// The entity id `legacyLoadedShape` corresponds to (the given `id` for `loadShape`;
    /// the first resulting body's id for `loadFile(from:progress:)`, since that's what it
    /// also registers as its own entity).
    ///
    /// Lets `remove(id:)` invalidate `legacyLoadedShape` precisely when *that* entity is
    /// removed or replaced, e.g. `loadShape(box, id: "model")` followed by
    /// `load(otherBox, id: "model")` must stop `loadedShape` from still reporting the first
    /// `box`, without wrongly clearing it when a *different* entity is removed.
    private var legacyLoadedShapeEntityID: String?

    /// The loaded shape, when exactly one is loaded (however it was loaded). `nil` if
    /// nothing is loaded, or if more than one entity is loaded via the multi-entity API.
    @available(
        *, deprecated,
        message:
            "Use `loadedShapes`/`shape(id:)` instead: returns non-nil only when exactly one entity is loaded."
    )
    public var loadedShape: OCCTSwift.Shape? { currentSingleShape }

    /// Non-deprecated backing for the fallback logic behind `loadedShape`, so `shapeBounds`
    /// and `focusOnLoadedShape()` can use the same lookup without tripping the deprecation
    /// warning on every internal read.
    private var currentSingleShape: OCCTSwift.Shape? {
        if let legacyLoadedShape { return legacyLoadedShape }
        guard entities.count == 1, let onlyID = entities.keys.first else { return nil }
        return shape(id: onlyID)
    }

    /// Every currently selected sub-shape (face, edge, or vertex), gated by `selectionModes`.
    ///
    /// **A projection of `interactiveContext.selection`, not a second selection.** Since
    /// OCCTSwiftInteraction#3 (phase 3 of ecosystem#43) this service holds no selection state
    /// of its own: the state is the interactive context's `Set<SubShape>`, and this is that
    /// set enriched into `PickedEntity` values for display. It is mirrored into stored state
    /// rather than computed on read so SwiftUI observation still fires, exactly as `bodies`
    /// mirrors `interactiveContext.bodies`; nothing writes it except `syncSelection`.
    ///
    /// Two consequences worth knowing:
    ///
    /// - **Order is by (body id, kind, ordinal)**, not by when each entry was selected: the
    ///   underlying state is a `Set`, so insertion order no longer exists to preserve. The
    ///   order is deterministic, just not chronological.
    /// - **Whole-body selections do not appear here.** `SelectionMode.body` selects a
    ///   `SubShape.body` in the interactive context; read `interactiveContext.selection` (or
    ///   its `bodies` accessor) for those. This property is the sub-shape projection, and
    ///   `PickedEntity` has no whole-body case.
    ///
    /// Empty if nothing is selected. A real viewport pick always replaces the whole selection
    /// (matching the point-pick behavior of `OCCTSwiftAIS` itself: scheme-based combination is
    /// for programmatic `select(_:scheme:)` calls, e.g. area selection); build multi-selection
    /// by calling `select(_:scheme:)` yourself.
    public private(set) var selection: [PickedEntity] = []

    /// The single selected entity, when the selection is exactly one. `nil` if nothing is
    /// selected, or more than one entity is selected.
    @available(
        *, deprecated,
        message:
            "Use `selection` instead: returns non-nil only when exactly one entity is selected."
    )
    public var selected: PickedEntity? {
        selection.count == 1 ? selection.first : nil
    }

    /// Which sub-shape kinds picking resolves.
    ///
    /// **The same state as `interactiveContext.selectionMode`, not a copy of it.** Reading or
    /// writing either one reads or writes the other; before OCCTSwiftInteraction#3 these were
    /// two variables free to disagree, and by default they did (`[.face]` here, `[.body]`
    /// there, in a service that owns both).
    ///
    /// Initialised to `[.face]` in `init`, matching this service's behavior before edge/vertex
    /// picking existed, which overrides the interactive context's own `[.body]` default; add
    /// `.edge`/`.vertex` to opt in.
    ///
    /// `.body` now does something: it selects a `SubShape.body` in the interactive context for
    /// objects displayed there directly (`interactiveContext.display(_:style:)`), with AIS's
    /// whole-body fallback on a face pick that fails to resolve. It still produces no
    /// `PickedEntity`, because there is no whole-body case; see `selection`.
    ///
    /// Assigning a different set clears the selection, which is the interactive context's
    /// documented behaviour for `selectionMode` and now applies here too.
    public var selectionModes: Set<SelectionMode> {
        get { interactiveContext.selectionMode }
        set { interactiveContext.selectionMode = newValue }
    }

    /// Currently selected face, or `nil` if nothing is picked or the current pick is an
    /// edge or vertex.
    @available(
        *, deprecated,
        message:
            "Use `selection` instead: returns non-nil only when the selection is exactly one face."
    )
    public var selectedFace: PickedFaceInfo? {
        if case .face(let info)? = selected { return info }
        return nil
    }

    /// Internal rather than private so tests can seed it directly, e.g. a synthetic body
    /// with empty `edgeIndices`/`vertices` to exercise the "not edge/vertex-pickable"
    /// degrade-gracefully path without a real non-pickable file on disk.
    var modelBodies: [_ViewportBody] = []
    /// Internal rather than private so tests can seed it directly when exercising
    /// `rebuildIdentity`/`resolveFacePick` against a synthetic multi-body scenario without
    /// a real multi-body file on disk.
    var metadata: [String: CADBodyMetadata] = [:]
    private var overlays: [String: [_ViewportBody]] = [:]
    /// Up to three highlight bodies, one per kind present in `selection`, since each
    /// kind renders with a different primitive (translucent triangle patch / polyline /
    /// point sprite) that can't share one `_ViewportBody`.
    private var selectionBodies: [_ViewportBody] = []
    private var ownedBodyIDs: Set<String> = []
    private var bodiesSubscription: AnyCancellable?
    private var selectionSubscription: AnyCancellable?

    // MARK: - Bridge to the interactive context's selection state

    /// A stable `InteractiveObject.id` per model body id.
    ///
    /// The interactive context names what a selection belongs to with an `InteractiveObject`,
    /// while this service names it with a body id string, so driving that selection needs one
    /// object per body. Only the **id** is cached, never the object: `InteractiveObject`
    /// equality and hashing are id-only, so the `Shape` can be re-read from `bodyShapes` on
    /// every construction (and can change under a cap-plane split) without disturbing set
    /// membership.
    ///
    /// Deliberately not `interactiveContext.display(_:)`: that owns tessellation, and this
    /// service tessellates its own bodies with its own transforms, caps and comparison state.
    /// Registering them as context entries would also hand `updateSelectionVisuals` the
    /// `triangleStyles` array that `setScalarField(_:forBody:)` paints, and the two would
    /// overwrite each other.
    private var bodyObjectIDs: [String: UUID] = [:]

    /// Reverse of `bodyObjectIDs`, for projecting a `SubShape` back to the body it names.
    private var objectBodyIDs: [UUID: String] = [:]

    /// The enrichment computed for each currently selected sub-shape, keyed by the identity
    /// the interactive context holds.
    ///
    /// A cache, not state: every key is a `SubShape` currently in
    /// `interactiveContext.selection`, and `syncSelection` prunes it to exactly that set. It
    /// exists because two `PickedFaceInfo` fields cannot be recovered from a `SubShapeRef`
    /// after the fact: `scalarValue` for a `.perTriangle` field needs the triangle the pick
    /// landed on, and `description` is formatted at pick time. A sub-shape selected some other
    /// way (through the context directly, or by area selection) is enriched on demand instead,
    /// and gets `scalarValue == nil` for a per-triangle field.
    private var selectionInfo: [SubShape: PickedEntity] = [:]

    // MARK: - Durable identity (per loaded body)

    /// The raw shape each model body was tessellated from, keyed by body id.
    private var bodyShapes: [String: OCCTSwift.Shape] = [:]

    /// One `BRepGraph` per loaded body, retained for its shape's lifetime: this is what
    /// makes `PickedFaceInfo.uid` populatable, and what a later absorb-history mechanic
    /// (mirroring `InteractiveContext.update(_:to:absorbing:operationName:)`) would need.
    ///
    /// Absent for a body whose graph failed to construct (a pathological shape); such a
    /// body's picks mint `uid == nil`.
    private var bodyGraphs: [String: BRepGraph] = [:]

    /// Maps each face ordinal to (`Shape`, `GraphUID`?), keyed by body id.
    private var faceIdentity: [String: FaceIdentityTable] = [:]

    /// Maps each edge ordinal to (`Shape`, `GraphUID`?), keyed by body id.
    private var edgeIdentity: [String: EdgeIdentityTable] = [:]

    /// Maps each vertex ordinal to (`Shape`, `GraphUID`?), keyed by body id.
    private var vertexIdentity: [String: VertexIdentityTable] = [:]

    // MARK: - Scalar fields

    /// The scalar field currently painted on each body, keyed by body id.
    private var scalarFields: [String: ScalarField] = [:]

    /// The body id `scalarFieldLegend` reports on: the most recent `setScalarField(_:forBody:)`
    /// call that set a non-nil field.
    ///
    /// When THAT body's field is cleared or removed, falls back to another still-active entry
    /// in `scalarFields` (via `dropLastScalarFieldBodyID`) rather than going `nil` outright;
    /// `nil` only once `scalarFields` is entirely empty.
    private var lastScalarFieldBodyID: String?

    /// Clears `lastScalarFieldBodyID` if it currently points at `bodyID`, falling back to
    /// another remaining entry in `scalarFields` (an arbitrary choice among ties: dictionary
    /// order isn't meaningful) rather than unconditionally going `nil`.
    ///
    /// Callers must remove `bodyID` from `scalarFields` BEFORE calling this, so a fallback
    /// never re-selects the very body whose field is being cleared.
    private func dropLastScalarFieldBodyID(ifCurrently bodyID: String) {
        guard lastScalarFieldBodyID == bodyID else { return }
        lastScalarFieldBodyID = scalarFields.keys.first
    }

    // MARK: - Comparison

    /// The comparison most recently set via `setComparison(_:)`, or `nil`.
    public private(set) var comparison: ComparisonView?

    /// Bodies as they were immediately before the active comparison's `.overlay`/`.sideBySide`/
    /// `.wipe` mutated them, keyed by body id: lets `setComparison` restore geometry exactly on
    /// clear or mode switch without reloading.
    ///
    /// `.deviation` doesn't use this; it's undone via `setScalarField`'s own clear path instead.
    private var comparisonBackup: [String: _ViewportBody] = [:]

    // MARK: - Clipping

    /// Every currently configured clipping plane.
    ///
    /// Backing for the public `clippingPlanes` property.
    private var clippingPlaneStorage: [ClippingPlane] = []

    /// The plane id `sectionSweep(axis:position:)` owns, so repeated calls move the same
    /// plane rather than accumulating a new one each time. `nil` until the first call.
    private var sectionSweepPlaneID: String?

    /// Each body's ORIGINAL shape (before any cap-plane split), keyed by body id: populated
    /// lazily from `bodyShapes` the first time `updateCapSurfaces()` sees a body, and then
    /// always read from here afterward instead of `bodyShapes` (which `updateCapSurfaces`
    /// itself overwrites with the CAPPED shape, so capping stays correct/non-compounding
    /// across repeated calls, e.g. a scrubbed `sectionSweep`, rather than re-cutting an
    /// already-cut shape).
    private var clippingSourceShapes: [String: OCCTSwift.Shape] = [:]

    /// Bodies as they were immediately before `updateCapSurfaces()` last replaced them with a
    /// capped (or hidden) version, keyed by body id.
    ///
    /// Restored at the START of every `updateCapSurfaces()` call before recomputing, mirroring
    /// `comparisonBackup`'s pattern.
    private var clippingCapBackup: [String: _ViewportBody] = [:]

    // MARK: - Multi-body / assembly (entities loaded via `load`/`loadFile(from:id:)`)

    /// A distinct, addressable entity loaded via the multi-entity API: the model-body
    /// ids it owns (more than one for a multi-body file loaded under one entity id) and
    /// its own visibility flag.
    ///
    /// Internal rather than private, like `modelBodies`/`metadata`, so tests can seed a
    /// synthetic multi-body entity directly: this package's tests don't ship a multi-body
    /// file on disk, and `load(_:id:transform:)` only ever produces a single-body entity.
    struct Entity {
        var bodyIDs: [String]
        var isVisible: Bool = true
    }

    /// Every currently loaded entity, keyed by entity id: whether loaded via
    /// `load(_:id:transform:)`/`loadFile(from:id:progress:)`, or via the deprecated
    /// single-shape `loadFile(from:progress:)`/`loadShape(_:id:)` (each of which registers
    /// its own resulting body/bodies here too, one entity per body, since it has no
    /// caller-supplied grouping concept of its own).
    ///
    /// This is the single source of truth `remove(id:)`/`loadedShapes`/`visibility`/etc. read:
    /// kept accurate regardless of which loading API was used is what makes mixing the two
    /// APIs in one session safe (e.g. `loadShape(_:id:"model")` then `load(_:id:"model")`
    /// correctly replaces the first load rather than leaving a stray duplicate body).
    ///
    /// Internal rather than private so tests can seed a multi-body entity directly (see
    /// `Entity`'s own doc comment).
    var entities: [String: Entity] = [:]

    public init(
        configuration: _ViewportConfiguration = .init(
            rotationStyle: .turntable,
            displayMode: .shadedWithEdges,
            lightingConfiguration: .threePoint,
            showViewCube: true,
            showAxes: true,
            showGrid: true,
            pickingConfiguration: _PickingConfiguration(isEnabled: true)
        )
    ) {
        let controller = _ViewportController(configuration: configuration)
        self.controller = controller
        self.interactiveContext = InteractiveContext(viewport: controller)
        // This service's historical default, applied to the now-shared mode set. The
        // interactive context's own default is `[.body]`; an app that wants whole-body
        // selection back sets `selectionModes` itself.
        self.interactiveContext.selectionMode = [.face]
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
        // The one path by which a selection change reaches this service, whoever made it:
        // this service's own `select`/`clearSelection`, a direct `interactiveContext.select`,
        // an area selection, or a `selectionMode` change clearing the selection.
        //
        // Deliberately NOT `.receive(on: RunLoop.main)`, unlike the `$bodies` sink above: this
        // has to run synchronously so a caller reading `selection` immediately after
        // `select(_:scheme:)` sees the result. That means it fires during `willSet`, when
        // `interactiveContext.selection` still reads as the OLD value, so the new selection is
        // taken from the emitted value rather than read back off the context.
        self.selectionSubscription = interactiveContext.$selection
            .sink { [weak self] newSelection in
                MainActor.assumeIsolated {
                    self?.syncSelection(with: newSelection)
                }
            }
    }

    // MARK: - File Import

    /// Load a CAD file (STEP/.stp, STL, BREP) from disk into the viewport.
    ///
    /// Returns the loaded `Shape`. Camera is automatically focused on the shape's bounding box.
    ///
    /// Pass an `ImportProgress` (e.g. `ImportProgressClosure`) to observe
    /// STEP/IGES import progress and/or request cooperative cancellation;
    /// cancellation surfaces as `ImportError.cancelled`.
    ///
    /// Single-shape convenience: replaces every model body, including any loaded via
    /// `load(_:id:transform:)`/`loadFile(from:id:progress:)`. Registers each resulting
    /// body as its own entity (see `entities`' own documentation), so `remove(id:)`/
    /// `loadedShapes`/etc. see it too.
    @available(
        *, deprecated,
        message:
            "Use loadFile(from:id:progress:) instead for multi-entity loading. This overload still replaces every model body."
    )
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

        let result = try await CADFileLoader.load(
            from: url, format: format, progress: progress, includeIdentity: true)
        guard let firstShape = result.shapes.first else {
            throw CADViewportError.emptyFile
        }

        resetAllModelState()
        self.legacyLoadedShape = firstShape
        self.legacyLoadedShapeEntityID = result.bodies.first?.id
        self.modelBodies = result.bodies
        self.metadata = result.metadata
        installIdentity(result.identity)
        for body in result.bodies {
            entities[body.id] = Entity(bodyIDs: [body.id])
        }
        clearSelection()
        updateCapSurfaces()  // picks up whatever clipping/capping is already active, also rebuilds
        focusOnLoadedShape()
        return firstShape
    }

    /// Display an in-memory shape (e.g. one constructed programmatically via
    /// OCCTSwift) without going through the file loader.
    ///
    /// Single-shape convenience: replaces every model body, including any loaded via
    /// `load(_:id:transform:)`/`loadFile(from:id:progress:)`. Registers as its own entity
    /// under `id` (see `entities`' own documentation), so `remove(id:)`/`loadedShapes`/etc.
    /// see it too.
    @available(
        *, deprecated,
        message:
            "Use load(_:id:transform:) instead for multi-entity loading. This overload still replaces every model body."
    )
    public func loadShape(_ shape: OCCTSwift.Shape, id: String = "model") {
        resetAllModelState()
        self.legacyLoadedShape = shape
        self.legacyLoadedShapeEntityID = id
        let identity = ShapeIdentity(shape: shape)
        let (body, meta) = CADFileLoader.shapeToBodyAndMetadata(
            shape,
            id: id,
            color: SIMD4<Float>(0.7, 0.7, 0.75, 1.0)
        )
        if let body {
            self.modelBodies = [body]
        }
        if let meta {
            self.metadata[id] = meta
        }
        installIdentity([id: identity])
        entities[id] = Entity(bodyIDs: [id])
        clearSelection()
        updateCapSurfaces()  // picks up whatever clipping/capping is already active, also rebuilds
        focusOnLoadedShape()
    }

    /// Full clean slate for every collection a load populates, including `entities` and
    /// `legacyLoadedShape`.
    ///
    /// Used by the deprecated single-shape `loadFile(from:progress:)`/`loadShape(_:id:)`
    /// (which replace *everything*, not just their own prior load) and by `removeAll()`.
    /// Centralising this is what makes it safe to mix the deprecated and multi-entity APIs
    /// in one session, e.g. `loadShape(_:id:"model")` followed by `load(_:id:"model")`
    /// correctly replaces the first load's body rather than leaving a stray duplicate,
    /// since both register in the same `entities` registry.
    private func resetAllModelState() {
        modelBodies.removeAll()
        metadata.removeAll()
        bodyShapes.removeAll()
        bodyGraphs.removeAll()
        faceIdentity.removeAll()
        edgeIdentity.removeAll()
        vertexIdentity.removeAll()
        bodyObjectIDs.removeAll()
        objectBodyIDs.removeAll()
        entities.removeAll()
        scalarFields.removeAll()
        lastScalarFieldBodyID = nil
        legacyLoadedShape = nil
        legacyLoadedShapeEntityID = nil
        comparison = nil
        comparisonBackup.removeAll()
        clippingSourceShapes.removeAll()
        clippingCapBackup.removeAll()
        if pendingEscalation != nil {
            respond(.rejected(reason: "referenced geometry was removed"))
        }
    }

    /// Installs the durable identity the loader (or `ShapeIdentity(shape:)`) already built,
    /// keyed by body id.
    ///
    /// This service used to build the tables itself, from a hand-written copy of the private
    /// helpers in `OCCTSwiftTools.CADFileLoader` whose own comment said so. Construction is
    /// `ShapeIdentity`'s since OCCTSwiftInteraction#7, and a file load gets it back from
    /// `CADLoadResult.identity`.
    ///
    /// **There is no count-mismatch guard here any more, and that is the point.** The old
    /// `rebuildIdentity(bodies:shapes:)` paired `shapes[i]` with `bodies[i]` positionally, which
    /// `CADFileLoader`'s STL/IGES robust reload can break: it appends a shape even when that
    /// input produced no body, so every later pairing shifts and a body gets another body's
    /// geometry. From out here the only visible symptom was the count mismatch, so the guard
    /// dropped identity for every body, including correctly paired ones, rather than risk one
    /// wrong pairing. `CADLoadResult.identity` is keyed by body id inside the loader, in the same
    /// branch that creates each body, so no positional pairing happens anywhere and there is
    /// nothing left to detect.
    ///
    /// Additive: body ids not present in `identity` keep whatever they had, which is what the
    /// multi-entity `loadFile(from:id:)` needs. The deprecated single-entity loaders clear
    /// everything through `resetAllModelState()` first, so they get replace-all semantics without
    /// a second code path.
    ///
    /// Internal rather than private so tests can seed a synthetic multi-body scenario directly:
    /// this package's tests ship no multi-body file on disk.
    func installIdentity(_ identity: [String: ShapeIdentity]) {
        for (bodyID, entry) in identity {
            bodyShapes[bodyID] = entry.shape
            if let graph = entry.graph { bodyGraphs[bodyID] = graph }
            faceIdentity[bodyID] = entry.faces
            edgeIdentity[bodyID] = entry.edges
            vertexIdentity[bodyID] = entry.vertices
        }
    }

    /// Convenience for callers that have file `Data` rather than a URL
    /// (e.g. `.fileImporter` results, drag-and-drop on iOS).
    @available(
        *, deprecated,
        message:
            "Use loadFromData(_:filename:id:progress:) instead for multi-entity loading. This overload still replaces every model body."
    )
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
    /// callers that have file `Data` rather than a URL.
    ///
    /// See `loadFile(from:id:progress:)`.
    ///
    /// `id` is required: a defaulted one would make calls like
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

    /// Load a CAD file as a distinct, addressable entity.
    ///
    /// Unlike the deprecated `loadFile(from:progress:)`, this adds to the currently loaded
    /// entities rather than replacing them, so multiple parts (or several of an assembly's
    /// occurrences) can coexist. A file with several bodies (e.g. a multibody STEP/STL)
    /// registers one entity whose body ids are `"<id>-0"`, `"<id>-1"`, etc.
    ///
    /// Camera is **not** auto-focused (unlike the deprecated single-shape overload); call
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

        let result = try await CADFileLoader.load(
            from: url, format: format, progress: progress, includeIdentity: true)
        guard !result.bodies.isEmpty else {
            throw CADViewportError.emptyFile
        }

        remove(id: id)

        // The loader keys identity by ITS body ids; this entity renames every body to
        // "<id>-<index>", so identity is re-keyed alongside the rename rather than rebuilt.
        var bodyIDs: [String] = []
        var identity: [String: ShapeIdentity] = [:]
        for (index, originalBody) in result.bodies.enumerated() {
            let bodyID = "\(id)-\(index)"
            if let originalMeta = result.metadata[originalBody.id] {
                metadata[bodyID] = originalMeta
            }
            if let originalIdentity = result.identity[originalBody.id] {
                identity[bodyID] = originalIdentity
            }
            var body = originalBody
            body.id = bodyID
            modelBodies.append(body)
            bodyIDs.append(bodyID)
        }
        installIdentity(identity)

        entities[id] = Entity(bodyIDs: bodyIDs)
        updateCapSurfaces()  // picks up whatever clipping/capping is already active, also rebuilds
        return id
    }

    /// Display an in-memory shape as a distinct, addressable entity.
    ///
    /// Unlike the deprecated `loadShape(_:id:)`, this adds to the currently loaded entities
    /// rather than replacing them.
    ///
    /// Pass `transform` to place the shape before tessellating it, e.g. an assembly
    /// occurrence's location. Matches the layout of `OCCTSwift.Shape.transformed(matrix:)`: a
    /// rigid 12-element affine matrix, `[r00,r01,r02, r10,r11,r12, r20,r21,r22, tx,ty,tz]`
    /// (row-major 3x3 rotation, then translation). `nil` (default) leaves the shape as-is.
    ///
    /// Camera is **not** auto-focused; call `focus(on:)` once you've loaded what should
    /// be visible.
    ///
    /// - Returns: `id`, echoed back.
    @discardableResult
    public func load(_ shape: OCCTSwift.Shape, id: String, transform: [Double]? = nil) -> String {
        let placedShape = transform.flatMap { shape.transformed(matrix: $0) } ?? shape

        remove(id: id)

        let (body, meta) = CADFileLoader.shapeToBodyAndMetadata(
            placedShape,
            id: id,
            color: SIMD4<Float>(0.7, 0.7, 0.75, 1.0)
        )

        guard let body else {
            entities[id] = Entity(bodyIDs: [])
            // No-op for capping (nothing new to cut), but keeps this path consistent.
            updateCapSurfaces()
            return id
        }

        modelBodies.append(body)
        if let meta {
            metadata[id] = meta
        }
        // Built after the body, so a shape that produced nothing renderable does not pay for a
        // BRepGraph it can never be picked through.
        installIdentity([id: ShapeIdentity(shape: placedShape)])

        entities[id] = Entity(bodyIDs: [id])
        updateCapSurfaces()  // picks up whatever clipping/capping is already active, also rebuilds
        return id
    }

    /// Removes a loaded entity (and its bodies) from the viewport.
    ///
    /// No-op if `id` isn't currently loaded. Clears the current selection if it referenced
    /// this entity.
    ///
    /// Also invalidates `legacyLoadedShape` if it was this entity's, otherwise the
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
        pruneComparison(removingEntityIDs: [id])
        pruneEscalation(removingBodyIDs: entity.bodyIDs)
    }

    /// Removes every currently loaded entity, whichever API loaded it (see the documentation
    /// on `entities`), and clears the legacy backing for the deprecated single-shape
    /// `loadedShape` too.
    ///
    /// A full clean slate, equivalent to a fresh `CADViewportService`.
    public func removeAll() {
        resetAllModelState()
        clearSelection()  // also calls rebuildBodies()
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
            dropLastScalarFieldBodyID(ifCurrently: bodyID)
            clippingSourceShapes.removeValue(forKey: bodyID)
            clippingCapBackup.removeValue(forKey: bodyID)
        }
    }

    /// Drops only the selection entries that referenced a removed body, leaving everything
    /// else selected: the selection survives operations unrelated to it, and accurately
    /// reports (by no longer containing them) the entries that didn't.
    ///
    /// Prunes the interactive context's selection, which is where the state is. Keys on the
    /// body's `InteractiveObject` rather than on `PickedEntity.bodyID` as it used to, which is
    /// the same question asked in the vocabulary that now holds the answer, and it reaches
    /// whole-body selections on the removed body too (a `PickedEntity` scan never could).
    private func pruneSelection(removingBodyIDs bodyIDs: [String]) {
        let removedObjectIDs = Set(bodyIDs.compactMap { bodyObjectIDs[$0] })
        for subShape in interactiveContext.selection.subshapes
        where removedObjectIDs.contains(subShape.object.id) {
            // Each of these fires the `$selection` sink, which re-projects and rebuilds.
            interactiveContext.deselect(subShape)
        }
        for bodyID in bodyIDs {
            if let objectID = bodyObjectIDs.removeValue(forKey: bodyID) {
                objectBodyIDs.removeValue(forKey: objectID)
            }
        }
        // Unconditional, because this always rebuilt the viewport even when it pruned nothing:
        // its caller has just removed bodies that are still in the rendered array.
        rebuildBodies()
    }

    /// Clears the active comparison if it referenced one of the just-removed entities.
    ///
    /// Keeps `comparison` from silently going stale when either side of a comparison is
    /// removed or reloaded (`load`/`loadFile(from:id:)` both call `remove(id:)` before
    /// re-adding, so reloading either entity also goes through here).
    ///
    /// Routes through `undoComparison` rather than just dropping `comparisonBackup`: only
    /// the JUST-REMOVED entity's bodies are actually gone from `modelBodies` by the time this
    /// runs; the OTHER (surviving) side of a `.overlay`/`.sideBySide`/`.wipe` comparison was
    /// independently mutated (ghosted opacity, offset transform, or wipe-filtered triangles)
    /// and would otherwise stay that way forever with no active `comparison` to explain it.
    /// `undoComparison`'s restore loop already no-ops gracefully for the removed side (its
    /// body ids no longer match anything in `modelBodies`), so this is safe either way.
    private func pruneComparison(removingEntityIDs ids: [String]) {
        guard let current = comparison,
            ids.contains(current.referenceID) || ids.contains(current.candidateID)
        else { return }
        undoComparison(current)
        comparison = nil
        // Re-applies an active cap to the just-restored surviving side; also rebuilds.
        updateCapSurfaces()
    }

    /// Currently loaded entities' shapes, keyed by entity id.
    ///
    /// See `entities`' own documentation for why this reflects every loading API, not just
    /// the multi-entity one.
    public var loadedShapes: [String: OCCTSwift.Shape] {
        entities.keys.reduce(into: [:]) { result, id in
            result[id] = shape(id: id)
        }
    }

    /// The shape a loaded entity owns: its first body's shape, for a multi-body entity
    /// (e.g. a multibody file loaded under one id).
    ///
    /// `nil` if `id` isn't currently loaded, or its shape failed to tessellate.
    public func shape(id: String) -> OCCTSwift.Shape? {
        guard let entity = entities[id], let firstBodyID = entity.bodyIDs.first else { return nil }
        return bodyShapes[firstBodyID]
    }

    /// The entity id that owns a body id (e.g. from a pick's `PickedEntity.bodyID`), or
    /// `nil` if the body isn't tracked by the multi-entity API.
    public func entityID(forBodyID bodyID: String) -> String? {
        entities.first { $0.value.bodyIDs.contains(bodyID) }?.key
    }

    /// Per-entity visibility.
    ///
    /// Reading returns every loaded entity's current flag; setting applies each given key's
    /// value (a key not currently loaded is ignored).
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

    /// Frames the camera on the union of bounds of the given entities.
    ///
    /// No-op if none of `ids` are currently loaded, or if none of the loaded ones has a
    /// bounding box.
    public func focus(on ids: [String]) {
        let shapes = ids.compactMap { shape(id: $0) }
        guard !shapes.isEmpty else { return }

        var minPt = SIMD3<Double>(repeating: .infinity)
        var maxPt = SIMD3<Double>(repeating: -.infinity)
        for s in shapes {
            guard let b = s.bounds else { continue }
            minPt = SIMD3(min(minPt.x, b.min.x), min(minPt.y, b.min.y), min(minPt.z, b.min.z))
            maxPt = SIMD3(max(maxPt.x, b.max.x), max(maxPt.y, b.max.y), max(maxPt.z, b.max.z))
        }
        guard minPt.x.isFinite else { return }
        let center = SIMD3<Float>(
            Float((minPt.x + maxPt.x) / 2),
            Float((minPt.y + maxPt.y) / 2),
            Float((minPt.z + maxPt.z) / 2)
        )
        let maxDim = Float(max(maxPt.x - minPt.x, max(maxPt.y - minPt.y, maxPt.z - minPt.z)))
        controller.focusOn(point: center, distance: maxDim * 2.5)
    }

    // MARK: - Scalar Fields

    /// Paints (or clears, with `nil`) a scalar field over a loaded body: rebuilds that
    /// body's `TriangleStyle` buffer to reflect it.
    ///
    /// Currently rebuilds the whole body (a fresh `generation`, so a full vertex/index/edge
    /// re-upload alongside the style buffer) rather than mutating `triangleStyles` in place,
    /// because `OCCTSwiftViewport` (pinned floor 1.1.26) doesn't actually apply an in-place
    /// style-only mutation to an already-rendered body: its renderer only rebuilds a body's
    /// GPU buffers when `generation` changes, which an in-place mutation never does. See the
    /// doc comment on `applyTriangleStyles` for how this was confirmed.
    public func setScalarField(_ field: ScalarField?, forBody id: String) {
        guard let field else {
            scalarFields.removeValue(forKey: id)
            dropLastScalarFieldBodyID(ifCurrently: id)
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

    /// Legend for the most recently set (still-active) scalar field: label, unit, range,
    /// and evenly-spaced color stops a UI can lay out as a gradient bar or discrete
    /// swatches.
    ///
    /// `nil` if no field is currently set on any body.
    public var scalarFieldLegend: ScalarFieldLegend? {
        guard let bodyID = lastScalarFieldBodyID, let field = scalarFields[bodyID],
            let range = field.effectiveRange
        else {
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

    /// Builds a `TriangleStyle` per triangle from `field`.
    ///
    /// `nil`, or a field whose `effectiveRange` is `nil`, clears every style back to empty
    /// (not a full array of `.none`; `ViewportBody.triangleStyles`'s own contract
    /// distinguishes "empty" (skips the highlight pass for this body entirely) from
    /// "populated but all zero-alpha" (still builds a style buffer and runs the pass, just
    /// compositing nothing)) and writes it into `id`'s body. See this method's
    /// implementation comment below for why that's a full body reconstruction rather than
    /// an in-place `triangleStyles` mutation.
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
        // work (including the triangle-style buffer) behind a check that only looks
        // at `body.generation`, which an in-place `triangleStyles` mutation never
        // changes (`generation` is a `let`, fixed at `init`). A body already on screen
        // when this ran would silently keep whatever style buffer it had before,
        // regardless of the new styles just computed above. Reconstructing the body
        // mints a fresh `generation`, which does force a real rebuild, at the cost of
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

    /// The scalar value at a resolved face pick, if a field is set on that body.
    ///
    /// `nil` domain matches `PickedFaceInfo.faceIndex`/`triangleIndex` per `ScalarField.Domain`.
    /// `triangleIndex` is `nil` when the face was not reached through a pick (an area
    /// selection, or a selection made through `interactiveContext` directly), in which case a
    /// `.perTriangle` field has nothing to sample and reports no value. A `.perFace` field is
    /// unaffected: the face ordinal is enough.
    private func scalarValue(forBody bodyID: String, faceIndex: Int, triangleIndex: Int?)
        -> Double?
    {
        guard let field = scalarFields[bodyID] else { return nil }
        switch field.domain {
        case .perFace:
            return faceIndex >= 0 && faceIndex < field.values.count ? field.values[faceIndex] : nil
        case .perTriangle:
            guard let triangleIndex else { return nil }
            return triangleIndex >= 0 && triangleIndex < field.values.count
                ? field.values[triangleIndex] : nil
        }
    }

    // MARK: - Comparison

    /// Sets (or, with `nil`, clears) a comparison view between two already-loaded entities.
    ///
    /// Safe to call repeatedly (including with a different mode, or different `position`/
    /// `referenceOpacity` for the same mode) without reloading either entity; each call
    /// first undoes whatever the previous comparison did before applying the new one (or
    /// nothing, if clearing). No-op for an entity id that isn't currently loaded.
    public func setComparison(_ comparison: ComparisonView?) {
        if let previous = self.comparison {
            undoComparison(previous)
            // Cleared BEFORE calling updateCapSurfaces (rather than after, alongside the
            // assignment below): updateCapSurfaces reads `self.comparison` itself to preserve
            // an independently active comparison around its own cap recompute. Since THIS
            // method is the one driving the comparison change (about to apply a new value, or
            // none, itself), leaving `previous` in place here would make updateCapSurfaces
            // redundantly undo-then-reapply it a second time right before this method's own
            // code does the real work below.
            self.comparison = nil
            // Re-applies an active cap to the just-restored body; also rebuilds.
            updateCapSurfaces()
        }
        self.comparison = comparison
        guard let comparison else {
            rebuildBodies()
            return
        }
        switch comparison.mode {
        case .overlay, .sideBySide, .wipe:
            backUpComparisonBodies(comparison)
        case .deviation:
            break
        }
        applyComparison(comparison)
        rebuildBodies()
    }

    private func entityBodyIDs(_ entityID: String) -> [String] {
        entities[entityID]?.bodyIDs ?? []
    }

    private func backUpComparisonBodies(_ comparison: ComparisonView) {
        let ids = entityBodyIDs(comparison.referenceID) + entityBodyIDs(comparison.candidateID)
        for bodyID in ids {
            guard let index = modelBodies.firstIndex(where: { $0.id == bodyID }) else { continue }
            comparisonBackup[bodyID] = modelBodies[index]
        }
    }

    private func undoComparison(_ previous: ComparisonView) {
        switch previous.mode {
        case .deviation:
            setScalarField(nil, forBody: previous.candidateID)  // rebuilds bodies itself
        case .overlay, .sideBySide, .wipe:
            for (bodyID, original) in comparisonBackup {
                if let index = modelBodies.firstIndex(where: { $0.id == bodyID }) {
                    modelBodies[index] = original
                }
            }
        }
        comparisonBackup.removeAll()
    }

    private func applyComparison(_ comparison: ComparisonView) {
        switch comparison.mode {
        case .overlay(let opacity):
            applyOverlay(referenceID: comparison.referenceID, opacity: opacity)
        case .deviation:
            break  // caller drives this via setScalarField(_:forBody:) on the candidate
        case .sideBySide:
            applySideBySide(
                referenceID: comparison.referenceID, candidateID: comparison.candidateID)
        case .wipe(let axis, let position):
            applyWipe(
                referenceID: comparison.referenceID, candidateID: comparison.candidateID,
                axis: axis, position: position)
        }
    }

    /// Ghosts the reference entity by lowering its bodies' alpha.
    ///
    /// Safe as an in-place mutation (unlike `triangleStyles`, `ViewportBody.color` is read
    /// fresh into `BodyUniforms` every frame rather than baked into a cached buffer,
    /// confirmed via `BodyUniforms(body:)` on `ViewportRenderer`, which always reads
    /// `body.effectiveMaterial` live), and bodies below full opacity are already routed
    /// through the renderer's sorted transparent pass.
    private func applyOverlay(referenceID: String, opacity: Double) {
        let alpha = Float(max(0, min(1, opacity)))
        for bodyID in entityBodyIDs(referenceID) {
            guard let index = modelBodies.firstIndex(where: { $0.id == bodyID }) else { continue }
            modelBodies[index].color.w = alpha
        }
    }

    /// Union of bounds across every body of an entity.
    ///
    /// Unlike `shape(id:)` (which deliberately returns only the entity's first body's shape,
    /// fine for the "roughly frame the camera" use in `focus(on:)`), `applySideBySide` needs
    /// the offset to actually clear every body of a multi-body entity, not just whichever
    /// one happens to be first.
    ///
    /// `nil` when the entity isn't loaded, or when no body of it has a bounding box.
    private func entityBounds(_ entityID: String) -> (min: SIMD3<Double>, max: SIMD3<Double>)? {
        let shapes = entityBodyIDs(entityID).compactMap { bodyShapes[$0] }
        guard !shapes.isEmpty else { return nil }
        var minPt = SIMD3<Double>(repeating: .infinity)
        var maxPt = SIMD3<Double>(repeating: -.infinity)
        for s in shapes {
            guard let b = s.bounds else { continue }
            minPt = SIMD3(min(minPt.x, b.min.x), min(minPt.y, b.min.y), min(minPt.z, b.min.z))
            maxPt = SIMD3(max(maxPt.x, b.max.x), max(maxPt.y, b.max.y), max(maxPt.z, b.max.z))
        }
        guard minPt.x.isFinite else { return nil }
        return (minPt, maxPt)
    }

    /// Offsets the candidate's bodies along X so it sits beside the reference rather than
    /// overlapping it.
    ///
    /// A single shared camera/viewport means "linked cameras" is automatic. Via
    /// `ViewportBody.transform`, also read live per frame (not cache-gated), so this is a
    /// cheap in-place update, no re-tessellation.
    private func applySideBySide(referenceID: String, candidateID: String) {
        guard let referenceBounds = entityBounds(referenceID),
            let candidateBounds = entityBounds(candidateID)
        else { return }
        let referenceSizeX = referenceBounds.max.x - referenceBounds.min.x
        let candidateSizeX = candidateBounds.max.x - candidateBounds.min.x
        let gap = max(referenceSizeX, candidateSizeX) * 0.15
        let deltaX = Float((referenceBounds.max.x + gap) - candidateBounds.min.x)
        var translation = matrix_identity_float4x4
        translation.columns.3 = SIMD4<Float>(deltaX, 0, 0, 1)
        for bodyID in entityBodyIDs(candidateID) {
            guard let index = modelBodies.firstIndex(where: { $0.id == bodyID }) else { continue }
            modelBodies[index].transform = translation * modelBodies[index].transform
        }
    }

    /// Splits reference and candidate at a shared world-space plane (`axis`/`position`),
    /// keeping the reference's bodies on the lower side and the candidate's on the higher
    /// side.
    ///
    /// `ViewportController.clipPlanes` in `OCCTSwiftViewport` clips the whole scene uniformly
    /// (confirmed via `ViewportRenderer`: there's no per-body clip-plane field on
    /// `ViewportBody`), so it can't show reference and candidate on opposite sides of the same
    /// plane; this filters each body's own triangles instead. See `wipeFiltered` for what that
    /// drops.
    private func applyWipe(referenceID: String, candidateID: String, axis: Axis, position: Double) {
        let axisVector = axis.unitVector
        let planePosition = Float(position)
        for bodyID in entityBodyIDs(referenceID) {
            guard let index = modelBodies.firstIndex(where: { $0.id == bodyID }) else { continue }
            modelBodies[index] = wipeFiltered(
                modelBodies[index], axisVector: axisVector, position: planePosition, keepBelow: true
            )
        }
        for bodyID in entityBodyIDs(candidateID) {
            guard let index = modelBodies.firstIndex(where: { $0.id == bodyID }) else { continue }
            modelBodies[index] = wipeFiltered(
                modelBodies[index], axisVector: axisVector, position: planePosition,
                keepBelow: false)
        }
    }

    /// Rebuilds `body` keeping only the triangles whose centroid falls on one side of a
    /// world-space plane (unit `axisVector`, offset `position` along it): the mechanism
    /// behind `.wipe`.
    ///
    /// Filters `indices`/`faceIndices`/`triangleStyles` in lockstep by
    /// triangle; `vertexData` (or `meshPositions`/`meshNormals` for a direct-mesh body) is
    /// passed through unfiltered since the filtered `indices` simply reference fewer of its
    /// entries, no vertex remapping needed. Drops `edges`/`arcs`/`vertices`/`vertexIndices`/
    /// `vertexColors`: wireframe overlay and vertex-picking aren't preserved on a wiped body,
    /// only the shaded triangle mesh; filtering polylines/points against the same cut is
    /// unneeded complexity for a review affordance whose point is the shaded-surface split.
    /// A body with no triangles (e.g. `.point` primitive) passes through unchanged.
    private func wipeFiltered(
        _ body: _ViewportBody, axisVector: SIMD3<Float>, position: Float, keepBelow: Bool
    ) -> _ViewportBody {
        let triangleCount = body.indices.count / 3
        guard triangleCount > 0 else { return body }
        let direct = body.usesDirectMesh
        guard direct ? body.meshPositions.count >= 3 : body.vertexData.count >= 6 else {
            return body
        }

        func vertexPosition(_ vertexIndex: Int) -> SIMD3<Float> {
            if direct {
                return SIMD3<Float>(
                    body.meshPositions[vertexIndex * 3],
                    body.meshPositions[vertexIndex * 3 + 1],
                    body.meshPositions[vertexIndex * 3 + 2]
                )
            } else {
                return SIMD3<Float>(
                    body.vertexData[vertexIndex * 6],
                    body.vertexData[vertexIndex * 6 + 1],
                    body.vertexData[vertexIndex * 6 + 2]
                )
            }
        }

        let hasFaceIndices = body.faceIndices.count == triangleCount
        let hasStyles = body.triangleStyles.count == triangleCount
        var newIndices: [UInt32] = []
        newIndices.reserveCapacity(body.indices.count)
        var newFaceIndices: [Int32] = []
        var newStyles: [TriangleStyle] = []

        for triangle in 0..<triangleCount {
            let i0 = Int(body.indices[triangle * 3])
            let i1 = Int(body.indices[triangle * 3 + 1])
            let i2 = Int(body.indices[triangle * 3 + 2])
            let centroid = (vertexPosition(i0) + vertexPosition(i1) + vertexPosition(i2)) / 3
            let signedDistance = simd_dot(centroid, axisVector) - position
            guard (signedDistance < 0) == keepBelow else { continue }
            newIndices.append(body.indices[triangle * 3])
            newIndices.append(body.indices[triangle * 3 + 1])
            newIndices.append(body.indices[triangle * 3 + 2])
            if hasFaceIndices { newFaceIndices.append(body.faceIndices[triangle]) }
            if hasStyles { newStyles.append(body.triangleStyles[triangle]) }
        }

        return _ViewportBody(
            id: body.id,
            vertexData: body.vertexData,
            indices: newIndices,
            edges: [],
            arcs: [],
            faceIndices: newFaceIndices,
            edgeIndices: [],
            vertices: [],
            vertexIndices: [],
            vertexColors: [],
            triangleStyles: newStyles,
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
    }

    // MARK: - Clipping

    /// Every currently configured clipping plane.
    ///
    /// Setting replaces the whole array (a plane dropped from the new value is implicitly
    /// removed; add via `addClippingPlane`/`sectionSweep` to get an auto-generated `id`
    /// instead of inventing your own). `ViewportController.clipPlanes` in `OCCTSwiftViewport`
    /// only honors the first 4 *enabled* planes per frame; this property can hold more, but
    /// only the first 4 enabled ones actually clip.
    public var clippingPlanes: [ClippingPlane] {
        get { clippingPlaneStorage }
        set {
            clippingPlaneStorage = newValue
            syncClippingPlanes()
        }
    }

    /// Adds a clipping plane and returns its `id` (pass to `removeClippingPlane(id:)` or look
    /// up in `clippingPlanes` to adjust it later).
    @discardableResult
    public func addClippingPlane(
        origin: SIMD3<Double>, normal: SIMD3<Double>, showCapSurface: Bool = true
    ) -> String {
        let id = UUID().uuidString
        clippingPlaneStorage.append(
            ClippingPlane(id: id, origin: origin, normal: normal, showCapSurface: showCapSurface))
        syncClippingPlanes()
        return id
    }

    /// Removes a clipping plane.
    ///
    /// No-op if `id` isn't currently configured.
    public func removeClippingPlane(id: String) {
        guard clippingPlaneStorage.contains(where: { $0.id == id }) else { return }
        clippingPlaneStorage.removeAll { $0.id == id }
        if sectionSweepPlaneID == id {
            sectionSweepPlaneID = nil
        }
        syncClippingPlanes()
    }

    /// Convenience for the prismatic-axis inspection case: steps a single, dedicated plane
    /// along `axis` (need not be pre-normalized) to world coordinate `position`.
    ///
    /// The first call creates the plane (capping on by default); later calls move that SAME
    /// plane (preserving whatever `isEnabled`/`showCapSurface` it's since been set to) rather
    /// than accumulating a new one per call. Call `removeClippingPlane` with the id this
    /// method first returned via `clippingPlanes` if you need to stop sweeping and remove it.
    public func sectionSweep(axis: SIMD3<Double>, position: Double) {
        let unitAxis = simd_length(axis) > 0 ? simd_normalize(axis) : SIMD3<Double>(0, 0, 1)
        let origin = unitAxis * position
        if let id = sectionSweepPlaneID,
            let index = clippingPlaneStorage.firstIndex(where: { $0.id == id })
        {
            clippingPlaneStorage[index].origin = origin
            clippingPlaneStorage[index].normal = unitAxis
        } else {
            let id = UUID().uuidString
            clippingPlaneStorage.append(ClippingPlane(id: id, origin: origin, normal: unitAxis))
            sectionSweepPlaneID = id
        }
        syncClippingPlanes()
    }

    /// Pushes `clippingPlaneStorage` to the viewport's global, GPU-only clip mechanism
    /// (`controller.clipPlanes`: hides geometry on one side, interactively, with no
    /// per-body scoping; confirmed via `ViewportRenderer` in `OCCTSwiftViewport`, which
    /// applies the first 4 *enabled* planes uniformly to every body in the scene every
    /// frame) and recomputes capping.
    private func syncClippingPlanes() {
        if let id = sectionSweepPlaneID, !clippingPlaneStorage.contains(where: { $0.id == id }) {
            sectionSweepPlaneID = nil
        }
        controller.clipPlanes = clippingPlaneStorage.map { plane in
            let unitNormal = safeUnitNormal(plane.normal)
            let distance = Float(-simd_dot(unitNormal, plane.origin))
            return ClipPlane(
                normal: SIMD3<Float>(unitNormal), distance: distance, isEnabled: plane.isEnabled)
        }
        updateCapSurfaces()
    }

    /// A plane's normal normalized to unit length, falling back to a sensible default
    /// direction for a degenerate (zero-length) normal rather than propagating NaN through
    /// `simd_normalize`, which would otherwise make every bounds-center test in
    /// `cappedShape`/`isPointClipped` silently evaluate to false, treating the whole body as
    /// clipped away. Mirrors `sectionSweep`'s own guard on its `axis` parameter.
    private func safeUnitNormal(_ normal: SIMD3<Double>) -> SIMD3<Double> {
        simd_length(normal) > 0 ? simd_normalize(normal) : SIMD3<Double>(0, 0, 1)
    }

    /// What a single body's cap recomputation determined, from `cappedShape`.
    private enum CapOutcome {
        /// No cap-enabled plane actually intersects this body: leave `modelBodies`/
        /// `bodyShapes`/identity tables untouched entirely, rather than needlessly
        /// retessellating (and, via `replaceBody`'s fresh `BRepGraph`, invalidating every
        /// durable `GraphUID` this body's pristine geometry had ever minted) a body no
        /// enabled plane comes anywhere near.
        case unchanged
        case capped(OCCTSwift.Shape)
        case fullyClipped
    }

    /// Whether an active `ComparisonView`'s mode mutates bodies in a way `updateCapSurfaces`
    /// needs to undo-and-reapply around its own recompute. `.overlay`/`.sideBySide`/`.wipe`
    /// all mutate `modelBodies` directly; `.deviation` doesn't: it's a marker over a
    /// `ScalarField` the caller manages via `setScalarField(_:forBody:)`, independent of
    /// anything `updateCapSurfaces` touches. Treating `.deviation` as "nothing to preserve"
    /// (rather than routing it through the destructive `setScalarField(nil, forBody:)`
    /// "undo" of `undoComparison`, which has no corresponding restore in
    /// `applyComparison`) is what keeps an active deviation heatmap from being silently wiped
    /// by a clipping-plane change that has nothing to do with it; see the fix for #46.
    private func comparisonNeedsBodyPreservation(_ comparison: ComparisonView) -> Bool {
        switch comparison.mode {
        case .overlay, .sideBySide, .wipe: return true
        case .deviation: return false
        }
    }

    /// Rebuilds bodies actually intersected by the currently enabled `showCapSurface` planes,
    /// so a clipped solid shows real material at the cut instead of looking hollow.
    ///
    /// `OCCTSwiftViewport` has no shader-level capping (confirmed: no capping/stencil logic
    /// in its `Shaders.metal`, unlike the clip-plane discard it does have), so this is a
    /// genuine B-Rep split (`OCCTSwift.Shape.split(atPlane:normal:)`) and retessellation per
    /// affected body, not a cheap GPU trick. `showCapSurface: false` planes still clip (via
    /// `syncClippingPlanes`'s GPU path above) but stay hollow and don't hit this cost, and
    /// nor does a body no enabled cap plane actually touches, OR a body that's already
    /// showing exactly the cap outcome it should (see the `.capped` case below, #45's fix):
    /// only a body whose outcome ACTUALLY changes since the last call goes through
    /// `replaceBody` (a fresh `BRepGraph`/`generation`, and, per #43/#45, a durable
    /// `GraphUID` any caller was holding for it stops resolving). An earlier version
    /// unconditionally restored-then-recapped every body already in `clippingCapBackup` on
    /// every call, so an actively-capped body whose relationship to every plane hadn't
    /// changed at all still got two full retessellations (and a fresh, unresolvable
    /// `GraphUID`) every time ANY unrelated clipping-plane mutation happened anywhere in the
    /// scene.
    ///
    /// Considers the union of every body already tracked in `clippingCapBackup` (so one that
    /// no longer needs capping gets restored) and every currently loaded body (so a body
    /// that's newly in range of a plane, including one just loaded, per issue #44's fix in
    /// the loaders, gets capped for the first time), rather than the previous two-pass
    /// "restore everything, then re-cap everything" structure.
    ///
    /// Also undoes, then re-applies, an independently active BODY-MUTATING `comparison`
    /// (`comparisonNeedsBodyPreservation`) around its own restore/recompute. Without this, a
    /// `.overlay`/`.sideBySide`/`.wipe` mutation on a body this method also touches would be
    /// silently discarded (color/transform reset, or wipe-filtering undone) the moment an
    /// UNRELATED clipping-plane change ran, since this method's own backup only knows about
    /// capping, not about `comparisonBackup`. `setComparison`/`pruneComparison` clear
    /// `self.comparison` before calling this themselves specifically so this logic is a no-op
    /// when THEY are the ones driving the comparison change (avoiding a redundant
    /// undo/reapply of a comparison this method didn't initiate).
    private func updateCapSurfaces() {
        let activeComparison = comparison.flatMap { comparisonNeedsBodyPreservation($0) ? $0 : nil }
        if let activeComparison {
            undoComparison(activeComparison)
        }

        let capPlanes = clippingPlaneStorage.filter { $0.isEnabled && $0.showCapSurface }

        var bodyIDsToConsider = Set(clippingCapBackup.keys)
        bodyIDsToConsider.formUnion(modelBodies.map(\.id))

        for bodyID in bodyIDsToConsider {
            guard let index = modelBodies.firstIndex(where: { $0.id == bodyID }) else { continue }
            guard let sourceShape = clippingSourceShapes[bodyID] ?? bodyShapes[bodyID] else {
                continue
            }
            clippingSourceShapes[bodyID] = sourceShape

            let wasCapped = clippingCapBackup[bodyID] != nil
            let outcome: CapOutcome =
                capPlanes.isEmpty ? .unchanged : cappedShape(sourceShape, cutBy: capPlanes)

            switch outcome {
            case .unchanged:
                guard wasCapped, let original = clippingCapBackup[bodyID] else { continue }
                _ = replaceBody(bodyID: bodyID, withCappedShape: sourceShape, preserving: original)
                clippingCapBackup.removeValue(forKey: bodyID)

            case .fullyClipped:
                // Every cap plane's kept region excludes this body entirely.
                if !wasCapped {
                    clippingCapBackup[bodyID] = modelBodies[index]
                }
                modelBodies[index].isVisible = false

            case .capped(let capped):
                // Skip the retessellation entirely when this body is already showing exactly
                // this outcome, visibly (not left hidden by a since-reverted full clip,
                // which always needs a real transition back to visible regardless of bounds).
                if wasCapped, modelBodies[index].isVisible,
                    let currentlyDisplayed = bodyShapes[bodyID],
                    boundsPracticallyEqual(capped, currentlyDisplayed)
                {
                    continue
                }
                let original =
                    wasCapped
                    ? (clippingCapBackup[bodyID] ?? modelBodies[index]) : modelBodies[index]
                clippingCapBackup[bodyID] = original
                if !replaceBody(bodyID: bodyID, withCappedShape: capped, preserving: original) {
                    // Retessellation failed: leave the original in place rather than show nothing.
                    modelBodies[index] = original
                    clippingCapBackup.removeValue(forKey: bodyID)
                }
            }
        }

        if let activeComparison {
            backUpComparisonBodies(activeComparison)
            applyComparison(activeComparison)
        }
        rebuildBodies()
    }

    /// Sequentially splits `shape` at each plane in `planes`, keeping only the piece(s) on
    /// the side the plane's normal points toward each time.
    ///
    /// Which returned `split(atPlane:normal:)` piece is "kept" is determined by testing each
    /// piece's OWN bounds-center against the plane equation: `Shape.split` documents no
    /// return-order guarantee. This is a bounds-center heuristic, not an exact interior-point
    /// test: a piece whose true bulk sits on the kept side but whose bounding-box center
    /// happens to fall just past the plane (an unusual, non-convex shape) could be
    /// misclassified. Adequate for a review affordance; not a substitute for a real
    /// point-containment query if that ever proves necessary.
    ///
    /// Returns `.unchanged` (rather than `.capped(shape)`) when the result's bounds are
    /// practically identical to `shape`'s own, i.e. no plane in `planes` actually removed
    /// anything. Determined by comparing bounds rather than by whether `split` returned
    /// `nil`: empirically, `split(atPlane:normal:)` does NOT reliably return `nil` for a
    /// plane that doesn't intersect the shape; it can come back with a single-element
    /// array containing the shape geometrically unchanged, which a naive "any non-nil result
    /// means a real cut happened" check would misread as a cut. This inherits the same
    /// bounds-based approximation as the "kept piece" test above (a cut that removes material
    /// without changing the axis-aligned bounding box, e.g. a chunk that isn't at the
    /// shape's extremal point along any axis, would be missed and reported `.unchanged`);
    /// accepted for the same reason.
    private func cappedShape(_ shape: OCCTSwift.Shape, cutBy planes: [ClippingPlane]) -> CapOutcome
    {
        var current = shape
        for plane in planes {
            let unitNormal = safeUnitNormal(plane.normal)
            func isKept(_ candidate: OCCTSwift.Shape) -> Bool {
                // A piece with no bounding box has no geometry to sit on either side of the
                // plane, so it is not kept; the callers below then route it through the same
                // `.fullyClipped` path an out-of-scope piece already takes.
                guard let b = candidate.bounds else { return false }
                let center = SIMD3<Double>(
                    (b.min.x + b.max.x) / 2, (b.min.y + b.max.y) / 2, (b.min.z + b.max.z) / 2)
                return simd_dot(unitNormal, center - plane.origin) >= 0
            }
            guard let pieces = current.split(atPlane: plane.origin, normal: unitNormal) else {
                guard isKept(current) else { return .fullyClipped }
                continue
            }
            let kept = pieces.filter(isKept)
            guard !kept.isEmpty else { return .fullyClipped }
            current = kept.count == 1 ? kept[0] : (OCCTSwift.Shape.fuseAll(kept) ?? kept[0])
        }
        return boundsPracticallyEqual(shape, current) ? .unchanged : .capped(current)
    }

    /// Two shapes with no bounding box at all are equal (nothing to tell apart); one of each
    /// is not (the split changed something).
    private func boundsPracticallyEqual(_ a: OCCTSwift.Shape, _ b: OCCTSwift.Shape) -> Bool {
        switch (a.bounds, b.bounds) {
        case (nil, nil):
            return true
        case (let ab?, let bb?):
            let epsilon = 1e-6
            return simd_length(ab.min - bb.min) < epsilon && simd_length(ab.max - bb.max) < epsilon
        default:
            return false
        }
    }

    /// Re-tessellates `bodyID` from `shape` (a capped shape from `cappedShape`, or the
    /// pristine `clippingSourceShapes` entry when `updateCapSurfaces` is restoring).
    ///
    /// Preserves the caller-configurable state of `original` (visibility, pickability,
    /// material, transform) that `CADFileLoader.shapeToBodyAndMetadata` would
    /// otherwise reset to its own defaults, and updates identity tables to match the new
    /// geometry (so picking the surviving faces, and the new cut face, resolves correctly,
    /// per the same identity contract `load(_:id:transform:)` maintains). Returns `false`
    /// (leaving `modelBodies` untouched) if retessellation fails.
    ///
    /// Also clears any `ScalarField` set on this body: a cut (in either direction, capping
    /// or restoring to pristine) inserts/removes faces and renumbers the rest, so the OLD
    /// field's values have no defined correspondence to the NEW tessellation's face/triangle
    /// ordinals. Leaving it in place would silently paint (or report via
    /// `scalarValue(forBody:faceIndex:triangleIndex:)`) values against geometry they were
    /// never computed for: the same failure mode `removeBodies`/`resetAllModelState` already
    /// guard against for a removed body.
    private func replaceBody(
        bodyID: String, withCappedShape shape: OCCTSwift.Shape, preserving original: _ViewportBody
    ) -> Bool {
        guard let index = modelBodies.firstIndex(where: { $0.id == bodyID }) else { return false }
        let (freshBody, meta) = CADFileLoader.shapeToBodyAndMetadata(
            shape, id: bodyID, color: original.color
        )
        guard var body = freshBody else { return false }
        body.isVisible = original.isVisible
        body.isPickable = original.isPickable
        body.roughness = original.roughness
        body.metallic = original.metallic
        body.material = original.material
        body.renderLayer = original.renderLayer
        body.pickLayer = original.pickLayer
        body.transform = original.transform

        modelBodies[index] = body
        if let meta { metadata[bodyID] = meta } else { metadata.removeValue(forKey: bodyID) }
        let identity = ShapeIdentity(shape: shape)
        installIdentity([bodyID: identity])
        // `installIdentity` merges, and a cap replaces this body's geometry outright: if the graph
        // failed to build for the NEW shape, the OLD one must go rather than linger naming
        // pre-cap topology. The tables above are unconditional, so only the graph needs this.
        if identity.graph == nil { bodyGraphs.removeValue(forKey: bodyID) }
        scalarFields.removeValue(forKey: bodyID)
        dropLastScalarFieldBodyID(ifCurrently: bodyID)
        return true
    }

    // MARK: - Clip-aware picking

    /// Whether `worldPoint` is hidden by an active clipping plane.
    ///
    /// The dedicated GPU pick shaders (`pick_fragment`/`pick_line_fragment`/
    /// `pick_arc_fragment`/point-pick) don't discard against `clipPlanes` the way the main
    /// shaded pass does (confirmed via `Shaders.metal` in `OCCTSwiftViewport`: the clip-plane
    /// discard loop only appears in the shaded fragment function), so a raw GPU pick can hit
    /// geometry that's invisible on screen. Resolvers test the picked primitive's own
    /// position against this rather than trusting the pick pass to have already excluded it.
    ///
    /// Limited to the first 4 *enabled* planes, matching `ViewportRenderer`'s own
    /// `Array(controller.clipPlanes.filter { $0.isEnabled }.prefix(4))`: with more than 4
    /// enabled hollow-clip planes, a 5th+ plane isn't actually applied by the renderer, so
    /// testing against it here would reject a pick the geometry is still visibly showing.
    /// (A body already geometrically truncated by capping has no such limit, see
    /// `cappedShape`, since that path doesn't go through the GPU clip-plane uniform at all.)
    private func isPointClipped(_ worldPoint: SIMD3<Float>) -> Bool {
        guard !clippingPlaneStorage.isEmpty else { return false }
        for plane in clippingPlaneStorage.filter({ $0.isEnabled }).prefix(4) {
            let unitNormal = SIMD3<Float>(safeUnitNormal(plane.normal))
            let distance = Float(-simd_dot(safeUnitNormal(plane.normal), plane.origin))
            if simd_dot(unitNormal, worldPoint) + distance < 0 {
                return true
            }
        }
        return false
    }

    /// World-space centroid of a picked triangle (interleaved or direct-mesh body), for
    /// `isPointClipped`. `nil` on any out-of-bounds index rather than guessing; callers
    /// treat that as "couldn't determine, don't filter" rather than "clipped".
    private func triangleWorldCentroid(bodyID: String, triangleIndex: Int) -> SIMD3<Float>? {
        guard let body = modelBodies.first(where: { $0.id == bodyID }),
            triangleIndex >= 0, triangleIndex * 3 + 2 < body.indices.count
        else { return nil }
        let i0 = Int(body.indices[triangleIndex * 3])
        let i1 = Int(body.indices[triangleIndex * 3 + 1])
        let i2 = Int(body.indices[triangleIndex * 3 + 2])
        let local: SIMD3<Float>
        if body.usesDirectMesh {
            guard i0 * 3 + 2 < body.meshPositions.count, i1 * 3 + 2 < body.meshPositions.count,
                i2 * 3 + 2 < body.meshPositions.count
            else { return nil }
            let p0 = SIMD3<Float>(
                body.meshPositions[i0 * 3], body.meshPositions[i0 * 3 + 1],
                body.meshPositions[i0 * 3 + 2])
            let p1 = SIMD3<Float>(
                body.meshPositions[i1 * 3], body.meshPositions[i1 * 3 + 1],
                body.meshPositions[i1 * 3 + 2])
            let p2 = SIMD3<Float>(
                body.meshPositions[i2 * 3], body.meshPositions[i2 * 3 + 1],
                body.meshPositions[i2 * 3 + 2])
            local = (p0 + p1 + p2) / 3
        } else {
            guard i0 * 6 + 2 < body.vertexData.count, i1 * 6 + 2 < body.vertexData.count,
                i2 * 6 + 2 < body.vertexData.count
            else { return nil }
            let p0 = SIMD3<Float>(
                body.vertexData[i0 * 6], body.vertexData[i0 * 6 + 1], body.vertexData[i0 * 6 + 2])
            let p1 = SIMD3<Float>(
                body.vertexData[i1 * 6], body.vertexData[i1 * 6 + 1], body.vertexData[i1 * 6 + 2])
            let p2 = SIMD3<Float>(
                body.vertexData[i2 * 6], body.vertexData[i2 * 6 + 1], body.vertexData[i2 * 6 + 2])
            local = (p0 + p1 + p2) / 3
        }
        let world = body.transform * SIMD4<Float>(local, 1)
        return SIMD3<Float>(world.x, world.y, world.z)
    }

    /// World-space midpoint of a picked edge segment, for `isPointClipped`.
    ///
    /// `segmentIndex` walks the polylines of `body.edges` in the same flattened order
    /// `edgeIndices` documents.
    private func edgeSegmentWorldMidpoint(bodyID: String, segmentIndex: Int) -> SIMD3<Float>? {
        guard let body = modelBodies.first(where: { $0.id == bodyID }), segmentIndex >= 0 else {
            return nil
        }
        var remaining = segmentIndex
        for polyline in body.edges {
            let segmentCount = max(0, polyline.count - 1)
            if remaining < segmentCount {
                let local = (polyline[remaining] + polyline[remaining + 1]) / 2
                let world = body.transform * SIMD4<Float>(local, 1)
                return SIMD3<Float>(world.x, world.y, world.z)
            }
            remaining -= segmentCount
        }
        return nil
    }

    /// World-space position of a picked vertex, for `isPointClipped`.
    private func vertexWorldPosition(bodyID: String, pointIndex: Int) -> SIMD3<Float>? {
        guard let body = modelBodies.first(where: { $0.id == bodyID }),
            pointIndex >= 0, pointIndex < body.vertices.count
        else { return nil }
        let world = body.transform * SIMD4<Float>(body.vertices[pointIndex], 1)
        return SIMD3<Float>(world.x, world.y, world.z)
    }

    /// No-op if nothing is loaded, or if the loaded shape has no bounding box: leaving the
    /// camera where it is beats aiming it at the world origin.
    private func focusOnLoadedShape() {
        guard let shape = currentSingleShape, let b = shape.bounds else { return }
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

    /// `nil` when nothing is loaded, or when the loaded shape has no bounding box.
    public var shapeBounds: ShapeBounds? {
        guard let shape = currentSingleShape, let b = shape.bounds else { return nil }
        return ShapeBounds(
            minX: b.min.x, minY: b.min.y, minZ: b.min.z,
            maxX: b.max.x, maxY: b.max.y, maxZ: b.max.z
        )
    }

    // MARK: - Overlay Layers

    /// Add or replace a named overlay layer.
    ///
    /// The bodies are composited with the model + selection highlight on every viewport
    /// rebuild. Use this for stock boxes, toolpath polylines, flat-pattern outlines, bend
    /// strips, custom annotations: anything that isn't part of the imported model.
    public func setOverlay(id: String, bodies: [_ViewportBody]) {
        overlays[id] = bodies
        rebuildBodies()
    }

    /// Remove a named overlay layer.
    public func clearOverlay(id: String) {
        overlays.removeValue(forKey: id)
        rebuildBodies()
    }

    /// Remove every overlay layer.
    ///
    /// Model bodies and selection are unaffected.
    public func clearAllOverlays() {
        overlays.removeAll()
        rebuildBodies()
    }

    /// Sorted list of overlay layer ids currently in the viewport.
    public var overlayIDs: [String] { overlays.keys.sorted() }

    // MARK: - Selection

    /// Clear the current selection (and any highlight bodies).
    ///
    /// Clears the interactive context's selection, which is the one selection there is, so
    /// this also drops any whole-body or AIS-side entries, not just this service's sub-shape
    /// projection.
    public func clearSelection() {
        interactiveContext.clearSelection()
        // Emptying `selection` itself is the `$selection` sink's job, and it has already run
        // (synchronously) if anything changed. What is left here is the part this method has
        // always done unconditionally, including when the selection was already empty: drop
        // the highlight bodies and rebuild the viewport.
        selectionBodies = []
        rebuildBodies()
    }

    /// Adds, removes, or replaces `entity` in the selection per `scheme`.
    ///
    /// Delegates to `interactiveContext.select(_:scheme:)`, which holds the selection.
    /// `SelectionScheme`'s semantics are the interactive context's own, the same ones
    /// `selectRectangle`/`selectPolygon` area selection uses: `.replace` assigns, `.add`
    /// inserts if absent, `.remove` drops it, `.xor` toggles it.
    ///
    /// Membership is `SubShapeRef`'s rule (the durable `uid` when both sides have one, else
    /// the render-path ordinal), which is what `PickedEntity`'s own `Equatable` has always
    /// mirrored, so the same durable face/edge/vertex is recognized as already-selected
    /// regardless of which ephemeral ordinal it was picked at.
    ///
    /// An entity naming a body this service has not loaded still selects: it gets its own
    /// `InteractiveObject` like any other body id, so a caller staging a pick by hand
    /// (an escalation request, a test) behaves the same as a real one.
    public func select(_ entity: PickedEntity, scheme: SelectionScheme = .replace) {
        let subShape = subShape(for: entity)
        // Before delegating, so the `$selection` sink finds the enrichment already cached and
        // does not have to rebuild it from the bare ref.
        selectionInfo[subShape] = entity
        interactiveContext.select(subShape, scheme: scheme)
    }

    /// The interactive context's name for `entity`: its `SubShapeRef` plus the
    /// `InteractiveObject` standing for the body it was picked on.
    private func subShape(for entity: PickedEntity) -> SubShape {
        let object = object(forBody: entity.bodyID, fallbackShape: entity.ref.shape)
        switch entity {
        case .face(let info): return .face(object, ref: info.ref)
        case .edge(let info): return .edge(object, ref: info.ref)
        case .vertex(let info): return .vertex(object, ref: info.ref)
        }
    }

    /// The `InteractiveObject` standing for `bodyID`, minted on first use and stable
    /// thereafter.
    ///
    /// `fallbackShape` is only used for a body id this service has never loaded, where there
    /// is no body shape to point at. It never affects identity: `InteractiveObject` compares
    /// and hashes by `id` alone.
    private func object(forBody bodyID: String, fallbackShape: OCCTSwift.Shape)
        -> InteractiveObject
    {
        let id: UUID
        if let existing = bodyObjectIDs[bodyID] {
            id = existing
        } else {
            id = UUID()
            bodyObjectIDs[bodyID] = id
            objectBodyIDs[id] = bodyID
        }
        return InteractiveObject(id: id, shape: bodyShapes[bodyID] ?? fallbackShape)
    }

    /// Re-projects the interactive context's selection into `selection` and rebuilds the
    /// highlight bodies.
    ///
    /// Takes the new selection as an argument rather than reading `interactiveContext`,
    /// because the `$selection` sink that drives it fires during `willSet`, when the context
    /// still reports the previous value.
    private func syncSelection(with newSelection: Selection) {
        let subShapes = newSelection.subshapes
        let projected =
            subShapes
            .compactMap { pickedEntity(for: $0) }
            .sorted(by: Self.selectionOrder)
        selectionInfo = selectionInfo.filter { subShapes.contains($0.key) }
        guard projected != selection else { return }
        selection = projected
        rebuildSelectionHighlights()  // also calls rebuildBodies()
    }

    /// Deterministic ordering for `selection`: body id, then kind, then render-path ordinal.
    ///
    /// The underlying state is a `Set<SubShape>`, so there is no insertion order left to
    /// preserve; an unordered projection would make `selection` differ run to run.
    private static func selectionOrder(_ lhs: PickedEntity, _ rhs: PickedEntity) -> Bool {
        func rank(_ entity: PickedEntity) -> Int {
            switch entity {
            case .face: return 0
            case .edge: return 1
            case .vertex: return 2
            }
        }
        return (lhs.bodyID, rank(lhs), lhs.ref.ordinal)
            < (rhs.bodyID, rank(rhs), rhs.ref.ordinal)
    }

    /// The enrichment for one selected sub-shape: the value cached when this service resolved
    /// or was handed the pick, else built on demand.
    ///
    /// `nil` for a `.body` sub-shape (no whole-body `PickedEntity` case), for a body this
    /// service does not have geometry for, and for anything whose enrichment fails.
    private func pickedEntity(for subShape: SubShape) -> PickedEntity? {
        if let cached = selectionInfo[subShape] { return cached }
        guard let bodyID = objectBodyIDs[subShape.object.id] else { return nil }
        switch subShape {
        case .body:
            return nil
        case .face(_, let ref):
            return enrichFace(ref: ref, bodyID: bodyID, triangleIndex: nil).map(PickedEntity.face)
        case .edge(_, let ref):
            return enrichEdge(ref: ref, bodyID: bodyID).map(PickedEntity.edge)
        case .vertex(_, let ref):
            return enrichVertex(ref: ref, bodyID: bodyID, renderPosition: nil).map(
                PickedEntity.vertex)
        }
    }

    /// Renamed to `selectionMeasurements` in OCCTSwiftInteraction#3, with the type it returns.
    @available(*, deprecated, renamed: "selectionMeasurements")
    public var selectionSummary: SelectionMeasurements? { selectionMeasurements }

    /// Aggregate measures over `selection`: count by kind, total face area, total edge
    /// length, and combined bounds.
    ///
    /// `nil` when nothing is selected. Whole-body selections do not contribute, for the same
    /// reason they do not appear in `selection`.
    public var selectionMeasurements: SelectionMeasurements? {
        guard !selection.isEmpty else { return nil }

        var faceCount = 0
        var edgeCount = 0
        var vertexCount = 0
        var totalArea = 0.0
        var totalLength = 0.0
        var minPt = SIMD3<Double>(repeating: .infinity)
        var maxPt = SIMD3<Double>(repeating: -.infinity)

        func absorb(_ bounds: (min: SIMD3<Double>, max: SIMD3<Double>)) {
            minPt = SIMD3(
                min(minPt.x, bounds.min.x), min(minPt.y, bounds.min.y), min(minPt.z, bounds.min.z))
            maxPt = SIMD3(
                max(maxPt.x, bounds.max.x), max(maxPt.y, bounds.max.y), max(maxPt.z, bounds.max.z))
        }

        for entity in selection {
            switch entity {
            case .face(let info):
                faceCount += 1
                totalArea += info.area
                // Re-derives the face's own 3D bounding box rather than reading `info.bounds`,
                // which is deliberate and not a missed reuse: `FaceBounds` is XY only and
                // `Float`, while this aggregate is 3D and `Double`. The edge and vertex
                // branches below read their cached values because those already are 3D.
                if let face = Face(info.shape), let faceBounds = face.bounds {
                    absorb(faceBounds)
                }
            case .edge(let info):
                edgeCount += 1
                totalLength += info.length
                // Uses the endpoints already captured on PickedEdgeInfo at pick time,
                // rather than re-deriving via Edge(info.shape): cheaper, and immune to
                // that conversion failing for a straight line (bounds is exact either way;
                // a curved edge's true bounds can bow slightly outside its endpoints, but
                // this is a selection-level aggregate, not a precision measurement).
                absorb(
                    (
                        min: SIMD3(
                            min(info.startPoint.x, info.endPoint.x),
                            min(info.startPoint.y, info.endPoint.y),
                            min(info.startPoint.z, info.endPoint.z)),
                        max: SIMD3(
                            max(info.startPoint.x, info.endPoint.x),
                            max(info.startPoint.y, info.endPoint.y),
                            max(info.startPoint.z, info.endPoint.z))
                    ))
            case .vertex(let info):
                vertexCount += 1
                absorb((min: info.position, max: info.position))
            }
        }

        let bounds: ShapeBounds? =
            minPt.x.isFinite
            ? ShapeBounds(
                minX: minPt.x, minY: minPt.y, minZ: minPt.z,
                maxX: maxPt.x, maxY: maxPt.y, maxZ: maxPt.z
            ) : nil

        return SelectionMeasurements(
            faceCount: faceCount,
            edgeCount: edgeCount,
            vertexCount: vertexCount,
            totalArea: totalArea,
            totalLength: totalLength,
            bounds: bounds
        )
    }

    /// `internal` rather than `private`, for the same reason as `resolveFacePick` and its
    /// siblings: so a test can drive the whole pick path (mode gate, ownership check,
    /// resolution, selection) with a synthesised `PickResult` instead of only its middle.
    /// `controller.onPick` is the only production caller.
    func handlePick(_ result: _PickResult?) {
        guard let result else {
            // Empty space deselects, which is this service's contract and now applies to the
            // whole shared selection, including anything held for an object displayed
            // directly into the interactive context.
            clearSelection()
            return
        }

        // A pick on a body the interactive context displays itself belongs to that context,
        // which resolves it through its own `handlePick` into the same selection this service
        // now reads. Returning here rather than falling through to `clearSelection()` is what
        // stops this service from wiping a selection it never owned; before
        // OCCTSwiftInteraction#3 the two selections were independent and the question could
        // not arise.
        guard !interactiveContext.displaysBody(withID: result.bodyID) else { return }

        guard let entity = resolveEntityPick(result) else {
            clearSelection()
            return
        }

        // A real viewport pick always replaces, matching OCCTSwiftAIS's own point-pick
        // behavior. `select(_:scheme:)` is how a caller builds a multi-selection
        // programmatically (there's no modifier-key state in a GPU pick result to infer a
        // scheme from).
        select(entity, scheme: .replace)
    }

    /// Dispatches a GPU pick to the resolver for its kind, gated by `selectionModes`.
    private func resolveEntityPick(_ result: _PickResult) -> PickedEntity? {
        switch result.kind {
        case .face:
            return resolveFacePick(bodyID: result.bodyID, triangleIndex: result.triangleIndex).map(
                PickedEntity.face)
        case .edge:
            return resolveEdgePick(bodyID: result.bodyID, segmentIndex: result.triangleIndex).map(
                PickedEntity.edge)
        case .vertex:
            return resolveVertexPick(bodyID: result.bodyID, pointIndex: result.triangleIndex).map(
                PickedEntity.vertex)
        }
    }

    /// Resolves a triangle-level GPU pick to durable face identity via the picked body's
    /// `FaceIdentityTable`. `internal` rather than `private` so it can be exercised
    /// directly in tests without round-tripping through the viewport's async pick
    /// callback; `handlePick` is the only production caller.
    ///
    /// Identity resolution itself is `OCCTSwiftTools.SubShapePickResolver`'s, shared with
    /// `OCCTSwiftAIS` since OCCTSwiftInteraction#2. What stays here is what the resolver
    /// deliberately does not own: the mode gate, the clip-plane pre-filter (clip planes are this
    /// service's state, not the bridge layer's), and the geometry enrichment below, which is
    /// presentation.
    func resolveFacePick(bodyID: String, triangleIndex: Int) -> PickedFaceInfo? {
        guard selectionModes.contains(.face) else { return nil }
        if let centroid = triangleWorldCentroid(bodyID: bodyID, triangleIndex: triangleIndex),
            isPointClipped(centroid)
        {
            return nil
        }
        guard let meta = metadata[bodyID],
            let ref = SubShapePickResolver.resolveFace(
                triangleIndex: triangleIndex,
                faceIndices: meta.faceIndices,
                identity: faceIdentity[bodyID],
                shape: bodyShapes[bodyID])
        else {
            return nil
        }
        return enrichFace(ref: ref, bodyID: bodyID, triangleIndex: triangleIndex)
    }

    /// The presentation half of a face pick: everything `PickedFaceInfo` carries beyond the
    /// identity in `ref`.
    ///
    /// Split out of `resolveFacePick` so a sub-shape that reached the selection some other way
    /// (through `interactiveContext` directly, or by area selection) is enriched by the same
    /// code rather than a second copy of it. `triangleIndex` is `nil` for those, which only
    /// affects a `.perTriangle` scalar field: there is no triangle to sample.
    private func enrichFace(ref: SubShapeRef, bodyID: String, triangleIndex: Int?)
        -> PickedFaceInfo?
    {
        guard let face = Face(ref.shape) else { return nil }

        let isHoriz = face.isHorizontal()
        let isVert = face.isVertical()
        // A face with no bounding box cannot have produced the rendered triangle this pick
        // came from, so the resolution went wrong somewhere: report no pick rather than
        // mint a `PickedFaceInfo` whose `bounds` and `description` are invented.
        guard let faceBounds = face.bounds else { return nil }
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
            ref: ref,
            bodyID: bodyID,
            isHorizontal: isHoriz,
            isVertical: isVert,
            bounds: bounds,
            zLevel: zLevel,
            area: faceArea,
            description: desc,
            scalarValue: scalarValue(
                forBody: bodyID, faceIndex: ref.ordinal, triangleIndex: triangleIndex)
        )
    }

    /// Resolves a line-segment-level GPU pick to durable edge identity via the picked
    /// body's `EdgeIdentityTable`.
    ///
    /// Reads `edgeIndices` off the `_ViewportBody` itself (unlike faces, `CADBodyMetadata`
    /// carries edge data as per-polyline groups, not a flat per-segment array); a body with
    /// no `edgeIndices` populated (not edge-pickable, per the documentation on
    /// `ViewportBody` itself) degrades to `nil` here rather than mis-picking. `internal` for
    /// the same testability reason as `resolveFacePick`, and split the same way against
    /// `SubShapePickResolver`.
    func resolveEdgePick(bodyID: String, segmentIndex: Int) -> PickedEdgeInfo? {
        guard selectionModes.contains(.edge) else { return nil }
        if let midpoint = edgeSegmentWorldMidpoint(bodyID: bodyID, segmentIndex: segmentIndex),
            isPointClipped(midpoint)
        {
            return nil
        }
        guard let body = modelBodies.first(where: { $0.id == bodyID }),
            let ref = SubShapePickResolver.resolveEdge(
                segmentIndex: segmentIndex,
                edgeIndices: body.edgeIndices,
                identity: edgeIdentity[bodyID],
                shape: bodyShapes[bodyID])
        else {
            return nil
        }
        return enrichEdge(ref: ref, bodyID: bodyID)
    }

    /// The presentation half of an edge pick.
    ///
    /// See `enrichFace(ref:bodyID:triangleIndex:)`.
    private func enrichEdge(ref: SubShapeRef, bodyID: String) -> PickedEdgeInfo? {
        guard let edge = Edge(ref.shape) else { return nil }

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
            ref: ref,
            bodyID: bodyID,
            curveType: edge.curveType,
            length: edge.length,
            startPoint: endpoints.start,
            endPoint: endpoints.end,
            description: desc
        )
    }

    /// Resolves a point-sprite-level GPU pick to durable vertex identity via the picked
    /// body's `VertexIdentityTable`.
    ///
    /// A body with no `vertices` populated (not vertex-pickable) degrades to `nil` here
    /// rather than mis-picking. `internal` for the same testability reason as
    /// `resolveFacePick`.
    ///
    /// The empty-`vertexIndices` identity mapping this copy used to implement alone is now
    /// `SubShapePickResolver.resolveVertex`'s, so `OCCTSwiftAIS` gets it too: that divergence
    /// (documented here as "deliberately more complete than OCCTSwiftAIS's own") is what
    /// OCCTSwiftInteraction#2 consolidated.
    func resolveVertexPick(bodyID: String, pointIndex: Int) -> PickedVertexInfo? {
        guard selectionModes.contains(.vertex) else { return nil }
        if let position = vertexWorldPosition(bodyID: bodyID, pointIndex: pointIndex),
            isPointClipped(position)
        {
            return nil
        }
        guard let body = modelBodies.first(where: { $0.id == bodyID }),
            let ref = SubShapePickResolver.resolveVertex(
                pointIndex: pointIndex,
                pointCount: body.vertices.count,
                vertexIndices: body.vertexIndices,
                identity: vertexIdentity[bodyID],
                shape: bodyShapes[bodyID])
        else {
            return nil
        }
        // In range whenever the resolver returned a ref: it bounds `pointIndex` by the
        // `pointCount` passed above, which is this array's own count.
        return enrichVertex(ref: ref, bodyID: bodyID, renderPosition: body.vertices[pointIndex])
    }

    /// The presentation half of a vertex pick.
    ///
    /// See `enrichFace(ref:bodyID:triangleIndex:)`.
    ///
    /// `renderPosition` is the rendered point the pick landed on, used only when the resolved
    /// `Shape` yields no vertex of its own; `nil` for a vertex that did not come from a pick,
    /// which then simply has no fallback.
    private func enrichVertex(ref: SubShapeRef, bodyID: String, renderPosition: SIMD3<Float>?)
        -> PickedVertexInfo?
    {
        let fallback = renderPosition.map {
            SIMD3<Double>(Double($0.x), Double($0.y), Double($0.z))
        }
        guard let position = ref.shape.vertices().first ?? fallback else { return nil }
        let desc = String(
            format: "Vertex at (%.1f, %.1f, %.1f)mm", position.x, position.y, position.z)

        return PickedVertexInfo(
            ref: ref,
            bodyID: bodyID,
            position: position,
            description: desc
        )
    }

    /// Rebuilds the highlight bodies from the whole `selection` (not just the latest
    /// pick), grouped by kind: up to three bodies, a translucent yellow triangle patch
    /// aggregating every selected face's own triangles, a bright cyan polyline aggregating
    /// every selected edge's own segments, and a bright magenta point sprite body for every
    /// selected vertex's own position.
    ///
    /// Bodies loaded via `load(_:id:transform:)` are always in world-space already (the
    /// transform is baked into the shape before tessellation, not applied as a separate
    /// `_ViewportBody.transform`), so combining geometry gathered from different source
    /// bodies into one aggregate highlight body is safe.
    private func rebuildSelectionHighlights() {
        let stride = 6  // interleaved [px,py,pz,nx,ny,nz]
        var faceVerts: [Float] = []
        var faceIndices: [UInt32] = []
        var faceVertCount: UInt32 = 0
        var edgeSegments: [[SIMD3<Float>]] = []
        var vertexPoints: [SIMD3<Float>] = []

        for entity in selection {
            switch entity {
            case .face(let info):
                guard let body = modelBodies.first(where: { $0.id == info.bodyID }),
                    let meta = metadata[info.bodyID]
                else { continue }
                let faceIndex = Int32(info.faceIndex)
                let triCount = body.indices.count / 3
                for tri in 0..<triCount {
                    guard tri < meta.faceIndices.count, meta.faceIndices[tri] == faceIndex else {
                        continue
                    }
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
                guard let body = modelBodies.first(where: { $0.id == info.bodyID }) else {
                    continue
                }
                let edgeIndex = Int32(info.edgeIndex)
                var segmentCursor = 0
                for polyline in body.edges {
                    let segmentCount = max(polyline.count - 1, 0)
                    guard segmentCount > 0 else { continue }
                    for s in 0..<segmentCount {
                        defer { segmentCursor += 1 }
                        guard segmentCursor < body.edgeIndices.count,
                            body.edgeIndices[segmentCursor] == edgeIndex
                        else { continue }
                        edgeSegments.append([polyline[s], polyline[s + 1]])
                    }
                }

            case .vertex(let info):
                vertexPoints.append(
                    SIMD3<Float>(
                        Float(info.position.x), Float(info.position.y), Float(info.position.z)
                    ))
            }
        }

        var bodies: [_ViewportBody] = []
        if !faceIndices.isEmpty {
            bodies.append(
                _ViewportBody(
                    id: "selection_highlight_face",
                    vertexData: faceVerts,
                    indices: faceIndices,
                    edges: [],
                    color: SIMD4<Float>(1.0, 0.9, 0.0, 0.5)
                ))
        }
        if !edgeSegments.isEmpty {
            bodies.append(
                _ViewportBody(
                    id: "selection_highlight_edge",
                    vertexData: [],
                    indices: [],
                    edges: edgeSegments,
                    color: SIMD4<Float>(0.1, 0.9, 1.0, 1.0)
                ))
        }
        if !vertexPoints.isEmpty {
            bodies.append(
                _ViewportBody(
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

    // MARK: - Escalation

    /// The escalation currently awaiting a response, or `nil`.
    ///
    /// Set by `present(_:)`, cleared by `respond(_:)` (or auto-resolved via
    /// `pruneEscalation`/`resetAllModelState` if the geometry it's about disappears first).
    public private(set) var pendingEscalation: EscalationRequest?

    private var escalationContinuation: CheckedContinuation<EscalationResponse, Never>?

    /// Presents a bounded question about specific geometry and suspends until it's answered.
    ///
    /// Highlights `request.entities` (replacing the current `selection`, exactly like a real
    /// pick would) so the question is grounded in visible geometry, and makes any supplied
    /// `EscalationCandidate.previewBodyID` visible. If a PREVIOUS escalation is still pending,
    /// it's resolved `.deferred` first, mirroring the "undo the previous one before applying
    /// the new one" pattern of `setComparison`, so a continuation never leaks.
    ///
    /// The caller answers via `respond(_:)` (typically from a SwiftUI action, see
    /// `EscalationCardView`) or `respondWithCurrentSelection()` for "the human picked
    /// something instead of choosing a candidate." If the calling `Task` is cancelled while
    /// this is suspended (a SwiftUI `.task` whose view disappears, an agent racing this
    /// against its own timeout), resolves `.deferred` on its own rather than leaving
    /// `pendingEscalation`/the continuation stuck forever with nothing left to cancel it.
    /// The `onCancel` of `withTaskCancellationHandler` isn't guaranteed to run on
    /// `MainActor`, so it hops via an unstructured `Task` into
    /// `respondIfStillPending(_:with:)`, which is safe to call from there even if that
    /// happens before `escalationContinuation` is set (it just no-ops): `@MainActor`'s
    /// cooperative, non-preemptive scheduling means that hop can't actually run until this
    /// method's own synchronous continuation-setup completes, so the ordering that matters
    /// (`escalationContinuation` set before any cancellation response can fire) always holds
    /// in practice.
    ///
    /// The `onCancel` hop captures `request.id`, not just "resolve whatever's pending",
    /// otherwise a STALE cancellation (this exact request already superseded by a newer
    /// `present(_:)` call before the hop got a chance to run) would wrongly resolve the NEWER,
    /// still-legitimately-pending request instead of being a no-op. Concretely: task A is
    /// cancelled, its `onCancel` hop is merely enqueued (not yet run); before it runs, a
    /// caller legitimately calls `present(requestB)`, which itself supersedes A (correctly,
    /// via the `respond(.deferred)` above) and installs B's own continuation; THEN A's queued
    /// hop finally executes: without the id check, it would silently resolve B as `.deferred`
    /// even though nothing about B was ever cancelled.
    @discardableResult
    public func present(_ request: EscalationRequest) async -> EscalationResponse {
        if pendingEscalation != nil {
            respond(.deferred)
        }
        pendingEscalation = request

        if let first = request.entities.first {
            select(first, scheme: .replace)
            for entity in request.entities.dropFirst() {
                select(entity, scheme: .add)
            }
        } else {
            clearSelection()
        }

        for candidate in request.candidates {
            if let bodyID = candidate.previewBodyID {
                setBodyVisible(true, bodyID: bodyID)
            }
        }

        let requestID = request.id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                escalationContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor in
                self.respondIfStillPending(requestID, with: .deferred)
            }
        }
    }

    /// Resolves the pending escalation (no-op if none is pending), resuming whichever
    /// `present(_:)` call is awaiting it.
    public func respond(_ response: EscalationResponse) {
        guard let continuation = escalationContinuation else { return }
        escalationContinuation = nil
        pendingEscalation = nil
        continuation.resume(returning: response)
    }

    /// Resolves the pending escalation only if it's still the one named by `requestID`.
    ///
    /// Guards against a STALE resolution (from the `onCancel` hop of `present(_:)`, which
    /// captures a request id rather than running synchronously at the moment of cancellation)
    /// wrongly terminating a newer, still-legitimately-pending escalation that has already
    /// superseded the one actually being cancelled. Direct callers of `respond(_:)` (a
    /// SwiftUI action, an agent) don't need this: they're always resolving whatever
    /// `pendingEscalation` currently is, which is exactly what's on screen.
    ///
    /// `internal` rather than `private`, like `resolveFacePick`/`resolveEdgePick`/
    /// `resolveVertexPick`, so a test can exercise the exact stale-hop scenario directly
    /// (call this with a superseded id and assert it's a no-op) rather than only through the
    /// real `Task` cancellation of `present(_:)`, whose `onCancel` hop and a superseding
    /// `present(_:)` call both racing on the SAME `@MainActor` serial executor don't actually
    /// force the "hop resolves after supersession" ordering this guards against. Confirmed
    /// empirically (a temporary probe) that a scheduling-only test of this passes identically
    /// with or without the guard, since the hop always finishes before a newly-spawned
    /// superseding `Task` gets a turn.
    func respondIfStillPending(_ requestID: String, with response: EscalationResponse) {
        guard pendingEscalation?.id == requestID else { return }
        respond(response)
    }

    /// Convenience for "the human answered by picking geometry": resolves with the CURRENT
    /// `selection` rather than requiring the caller to read and wrap it themselves.
    public func respondWithCurrentSelection() {
        respond(.picked(selection))
    }

    /// Auto-resolves the pending escalation as `.rejected` if it referenced any of the
    /// just-removed bodies, rather than leaving a `present(_:)` call suspended forever over
    /// geometry that no longer exists.
    private func pruneEscalation(removingBodyIDs bodyIDs: [String]) {
        guard let request = pendingEscalation else { return }
        let removed = Set(bodyIDs)
        guard request.entities.contains(where: { removed.contains($0.bodyID) }) else { return }
        respond(.rejected(reason: "referenced geometry was removed"))
    }

    /// Sets a body's visibility by id, searching model bodies then every overlay layer:
    /// `EscalationCandidate.previewBodyID` isn't scoped to either, so `present(_:)` doesn't
    /// know in advance which one a given candidate's preview lives in.
    private func setBodyVisible(_ isVisible: Bool, bodyID: String) {
        if let index = modelBodies.firstIndex(where: { $0.id == bodyID }) {
            modelBodies[index].isVisible = isVisible
            rebuildBodies()
            return
        }
        for (overlayID, bodies) in overlays {
            if let index = bodies.firstIndex(where: { $0.id == bodyID }) {
                var updated = bodies
                updated[index].isVisible = isVisible
                overlays[overlayID] = updated
                rebuildBodies()
                return
            }
        }
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
