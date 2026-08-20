// CADViewportService+Loading.swift
// OCCTSwiftCADKit
//
// Split out of CADViewportService.swift for OCCTSwiftInteraction#13 (code-structure policy).
// The service's stored state stays in the core file; this is the file import and multi-entity loading surface of the same
// type. A move, not a rewrite: the bodies below are unchanged.

import Combine
import Foundation
import OCCTSwift
import OCCTSwiftAIS
import OCCTSwiftTools
import OCCTSwiftViewport
import SwiftUI
import simd

@MainActor
extension CADViewportService {

    // MARK: - File Import

    /// Full clean slate for every collection a load populates, including `entities`.
    ///
    /// Used by `removeAll()`. It is one method rather than an inline sweep because the failure
    /// mode it prevents is a collection someone forgot: before it existed, `modelBodies` was
    /// cleared while `metadata`/`bodyShapes` kept entries for bodies that no longer rendered,
    /// so `loadedShapes` and `entityID(forBodyID:)` still reported a body that could not be
    /// picked. Adding a collection to this type means adding it here too.
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

    /// Loads file `Data` rather than a URL, for `.fileImporter` results and drag-and-drop.
    ///
    /// See `loadFile(from:id:progress:)`.
    ///
    /// `id` is required rather than defaulted. It had to be, while a deprecated 3-argument
    /// overload existed that a defaulted `id` would have made ambiguous with. That overload is
    /// gone as of 2.0.0, so the requirement is now a deliberate choice rather than a forced
    /// one: an entity id is what every other multi-entity call takes, and defaulting it is how
    /// callers end up with several loads silently sharing one id.
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
    /// `shapeBounds` follows automatically, because it reads through `entities` rather than
    /// through a separately stored shape. Before 2.0.0 removed the deprecated single-shape
    /// loaders, this method also had to invalidate their `legacyLoadedShape` by hand, or
    /// `loadedShape`/`shapeBounds` kept reporting a shape whose entity had just been removed.
    public func remove(id: String) {
        guard let entity = entities.removeValue(forKey: id) else { return }
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
        guard let box = combinedBounds(ofEntities: ids) else { return }
        frameCamera(on: box)
    }

    /// The union of every body's bounding box across the named entities, or `nil` if none of
    /// them is loaded or none has bounds.
    ///
    /// **Unions over `Entity.bodyIDs`, not `shape(id:)`.** `shape(id:)` returns only an
    /// entity's *first* body, and a multibody file loaded through
    /// `loadFile(from:id:progress:)` is one entity owning N bodies. Framing off `shape(id:)`
    /// therefore zoomed to body 0 and left the rest of the assembly off screen, which is
    /// OCCTSwiftUX#12 / OCCTSwiftCADKit#19, the camera half of the OCCTSwift#302 multibody
    /// ripple. Before OCCTSwift v1.11.3 a multibody file came back as one lumped shape, so
    /// "the first shape" genuinely was the whole model and this read correctly.
    ///
    /// The same first-body-only assumption was already fixed once in `applySideBySide`, whose
    /// regression test records it as "fine for the roughly-frame-the-camera use in
    /// `focus(on:)`". It was not fine; that is what this method exists to correct.
    ///
    /// Internal so tests can assert the union directly. The camera itself animates toward the
    /// framing over 0.3s, so `cameraState` right after a `focus(on:)` is mid-interpolation and
    /// cannot answer what was framed.
    func combinedBounds(ofEntities ids: [String])
        -> (min: SIMD3<Double>, max: SIMD3<Double>)?
    {
        var minPt = SIMD3<Double>(repeating: .infinity)
        var maxPt = SIMD3<Double>(repeating: -.infinity)
        for id in ids {
            guard let entity = entities[id] else { continue }
            for bodyID in entity.bodyIDs {
                guard let b = bodyShapes[bodyID]?.bounds else { continue }
                minPt = SIMD3(min(minPt.x, b.min.x), min(minPt.y, b.min.y), min(minPt.z, b.min.z))
                maxPt = SIMD3(max(maxPt.x, b.max.x), max(maxPt.y, b.max.y), max(maxPt.z, b.max.z))
            }
        }
        guard minPt.x.isFinite else { return nil }
        return (minPt, maxPt)
    }

    /// Points the camera at the centre of `box`, far enough back to hold its largest dimension.
    ///
    /// The one place that turns a bounding box into a camera move.
    private func frameCamera(on box: (min: SIMD3<Double>, max: SIMD3<Double>)) {
        let center = SIMD3<Float>(
            Float((box.min.x + box.max.x) / 2),
            Float((box.min.y + box.max.y) / 2),
            Float((box.min.z + box.max.z) / 2)
        )
        let maxDim = Float(
            max(box.max.x - box.min.x, max(box.max.y - box.min.y, box.max.z - box.min.z)))
        controller.focusOn(point: center, distance: maxDim * 2.5)
    }
}
