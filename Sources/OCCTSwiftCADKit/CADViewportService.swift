import Combine
import Foundation
import OCCTSwift
import OCCTSwiftAIS
import OCCTSwiftTools
import OCCTSwiftViewport
import SwiftUI
import simd

#if os(macOS)
    import OCCTSwiftIO
#endif

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

    /// The loaded shape, when exactly one entity is loaded. `nil` if nothing is loaded, or
    /// if more than one is.
    ///
    /// Backs `shapeBounds`, which is the single-entity convenience that survived 2.0.0. Until
    /// then this also had to consult a `legacyLoadedShape` stored separately by the deprecated
    /// single-shape loaders; with those gone there is one source of truth, so a shape reported
    /// here is always an entity that `entities` actually lists.
    private var currentSingleShape: OCCTSwift.Shape? {
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
    public internal(set) var selection: [PickedEntity] = []

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

    /// Internal rather than private so tests can seed it directly, e.g. a synthetic body
    /// with empty `edgeIndices`/`vertices` to exercise the "not edge/vertex-pickable"
    /// degrade-gracefully path without a real non-pickable file on disk.
    var modelBodies: [_ViewportBody] = []
    /// Internal rather than private so tests can seed it directly when exercising
    /// `rebuildIdentity`/`resolveFacePick` against a synthetic multi-body scenario without
    /// a real multi-body file on disk.
    var metadata: [String: CADBodyMetadata] = [:]
    var overlays: [String: [_ViewportBody]] = [:]
    /// Up to three highlight bodies, one per kind present in `selection`, since each
    /// kind renders with a different primitive (translucent triangle patch / polyline /
    /// point sprite) that can't share one `_ViewportBody`.
    var selectionBodies: [_ViewportBody] = []
    private var ownedBodyIDs: Set<String> = []
    private var bodiesSubscription: AnyCancellable?
    private var selectionSubscription: AnyCancellable?

    /// Entries in `selection` most recently added via the agent-highlight-request path.
    ///
    /// Set by `startSelectionSidecar(directory:)`'s request handling
    /// (`CADViewportService+AgentBridge.swift`, OCCTSwiftInteraction#16), rather than an
    /// ordinary pick or a caller's own `select(_:scheme:)` call. A subset of `selection`,
    /// pruned to intersect it on every `syncSelection` the same way `selectionInfo` is.
    /// `rebuildSelectionHighlights` renders these with `PresentationStyle.agentHighlight`'s
    /// distinct treatment instead of the ordinary selection color, so a viewer can tell "the
    /// agent is pointing at this" from "I selected this" at a glance. Empty (and inert) unless
    /// the agent-bridge sidecar is running.
    var agentHighlightedEntities: [PickedEntity] = []

    #if os(macOS)
        // MARK: - Agent selection sidecar (OCCTSwiftInteraction#16)
        //
        // State for `startSelectionSidecar(directory:)`/`stopSelectionSidecar()`
        // (`CADViewportService+AgentBridge.swift`). macOS-only, matching
        // `OCCTSwiftIO.DirectoryWatcher`'s own platform gate (kqueue is a Darwin primitive).

        /// The directory `startSelectionSidecar(directory:)` was last started against, or `nil`
        /// if it has never been started (or has since been stopped).
        var sidecarDirectory: URL?

        /// Holds `host.lock` for as long as the sidecar is running.
        var sidecarHostLock: HostLock?

        /// Sink on `interactiveContext.$selection` that keeps `selection.json` current.
        ///
        /// Separate from `selectionSubscription` above (this service's own projection sink),
        /// so starting or stopping the sidecar never disturbs that one.
        var sidecarSelectionSubscription: AnyCancellable?

        /// Watches `<directory>/highlight_requests/` for a new request file.
        var sidecarWatcher: DirectoryWatcher?

        /// Monotonic counter bumped by exactly 1 on every `selection.json` write, per the ADR.
        var sidecarRevision = 0
    #endif

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
    var bodyObjectIDs: [String: UUID] = [:]

    /// Reverse of `bodyObjectIDs`, for projecting a `SubShape` back to the body it names.
    var objectBodyIDs: [UUID: String] = [:]

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
    var selectionInfo: [OCCTSwiftTools.SubShape: PickedEntity] = [:]

    // MARK: - Durable identity (per loaded body)

    /// The raw shape each model body was tessellated from, keyed by body id.
    var bodyShapes: [String: OCCTSwift.Shape] = [:]

    /// One `BRepGraph` per loaded body, retained for its shape's lifetime: this is what
    /// makes `PickedFaceInfo.uid` populatable, and what a later absorb-history mechanic
    /// (mirroring `InteractiveContext.update(_:to:absorbing:operationName:)`) would need.
    ///
    /// Absent for a body whose graph failed to construct (a pathological shape); such a
    /// body's picks mint `uid == nil`.
    var bodyGraphs: [String: BRepGraph] = [:]

    /// Maps each face ordinal to (`Shape`, `GraphUID`?), keyed by body id.
    var faceIdentity: [String: FaceIdentityTable] = [:]

    /// Maps each edge ordinal to (`Shape`, `GraphUID`?), keyed by body id.
    var edgeIdentity: [String: EdgeIdentityTable] = [:]

    /// Maps each vertex ordinal to (`Shape`, `GraphUID`?), keyed by body id.
    var vertexIdentity: [String: VertexIdentityTable] = [:]

    // MARK: - Scalar fields

    /// The scalar field currently painted on each body, keyed by body id.
    var scalarFields: [String: ScalarField] = [:]

    /// The body id `scalarFieldLegend` reports on: the most recent `setScalarField(_:forBody:)`
    /// call that set a non-nil field.
    ///
    /// When THAT body's field is cleared or removed, falls back to another still-active entry
    /// in `scalarFields` (via `dropLastScalarFieldBodyID`) rather than going `nil` outright;
    /// `nil` only once `scalarFields` is entirely empty.
    var lastScalarFieldBodyID: String?

    /// Clears `lastScalarFieldBodyID` if it currently points at `bodyID`, falling back to
    /// another remaining entry in `scalarFields` (an arbitrary choice among ties: dictionary
    /// order isn't meaningful) rather than unconditionally going `nil`.
    ///
    /// Callers must remove `bodyID` from `scalarFields` BEFORE calling this, so a fallback
    /// never re-selects the very body whose field is being cleared.
    func dropLastScalarFieldBodyID(ifCurrently bodyID: String) {
        guard lastScalarFieldBodyID == bodyID else { return }
        lastScalarFieldBodyID = scalarFields.keys.first
    }

    // MARK: - Comparison

    /// The comparison most recently set via `setComparison(_:)`, or `nil`.
    public internal(set) var comparison: ComparisonView?

    /// Bodies as they were immediately before the active comparison's `.overlay`/`.sideBySide`/
    /// `.wipe` mutated them, keyed by body id: lets `setComparison` restore geometry exactly on
    /// clear or mode switch without reloading.
    ///
    /// `.deviation` doesn't use this; it's undone via `setScalarField`'s own clear path instead.
    var comparisonBackup: [String: _ViewportBody] = [:]

    // MARK: - Clipping

    /// Every currently configured clipping plane.
    ///
    /// Backing for the public `clippingPlanes` property.
    var clippingPlaneStorage: [ClippingPlane] = []

    /// The plane id `sectionSweep(axis:position:)` owns, so repeated calls move the same
    /// plane rather than accumulating a new one each time. `nil` until the first call.
    var sectionSweepPlaneID: String?

    /// Each body's ORIGINAL shape (before any cap-plane split), keyed by body id: populated
    /// lazily from `bodyShapes` the first time `updateCapSurfaces()` sees a body, and then
    /// always read from here afterward instead of `bodyShapes` (which `updateCapSurfaces`
    /// itself overwrites with the CAPPED shape, so capping stays correct/non-compounding
    /// across repeated calls, e.g. a scrubbed `sectionSweep`, rather than re-cutting an
    /// already-cut shape).
    var clippingSourceShapes: [String: OCCTSwift.Shape] = [:]

    /// Bodies as they were immediately before `updateCapSurfaces()` last replaced them with a
    /// capped (or hidden) version, keyed by body id.
    ///
    /// Restored at the START of every `updateCapSurfaces()` call before recomputing, mirroring
    /// `comparisonBackup`'s pattern.
    var clippingCapBackup: [String: _ViewportBody] = [:]

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

    // MARK: - Escalation state
    //
    // Stored, so it stays in the core file: an extension cannot hold stored properties. Its
    // behaviour lives in CADViewportService+Escalation.swift.

    /// The escalation currently awaiting a response, or `nil`.
    ///
    /// Set by `present(_:)`, cleared by `respond(_:)` (or auto-resolved via
    /// `pruneEscalation`/`resetAllModelState` if the geometry it's about disappears first).
    public internal(set) var pendingEscalation: EscalationRequest?

    var escalationContinuation: CheckedContinuation<EscalationResponse, Never>?

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

    // MARK: - Private

    func rebuildBodies() {
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
