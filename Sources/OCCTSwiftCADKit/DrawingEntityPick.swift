// DrawingEntityPick.swift
// OCCTSwiftCADKit
//
// OCCTSwiftInteraction#45: a pick on a 2D drawing entity, as a host hands it to the selection
// bridge. Published by `CADViewportService+DrawingSelection.swift`.
//
// macOS-only, matching the sidecar it publishes through.

#if os(macOS)

    import Foundation

    /// A pick on one entity of a 2D drawing, published to an agent through `selection.json`.
    public struct DrawingEntityPick: Sendable, Hashable {
        /// The drawing case the entity belongs to, written as the entry's `bodyId`.
        ///
        /// Names a folder the host holds, not a scene body.
        public var drawing: String

        /// SwiftDXF's `Identity.id` as one string: the handle where the file has one, else the
        /// section and position, after the block references an expanded entity came through.
        ///
        /// Opaque here: compared as a string, never parsed.
        public var entity: String

        /// The DXF record type (`DIMENSION`, `LINE`), advisory.
        public var entityType: String?

        /// Creates a pick of `entity` on the drawing case `drawing`.
        public init(drawing: String, entity: String, entityType: String? = nil) {
            self.drawing = drawing
            self.entity = entity
            self.entityType = entityType
        }
    }

    extension DrawingEntityPick {
        /// `picks` with the ones that name nothing dropped, and a repeated (drawing, entity) pair
        /// kept once, the first.
        ///
        /// An empty `drawing` or `entity` would write an entry no reader can resolve.
        static func normalized(_ picks: [DrawingEntityPick]) -> [DrawingEntityPick] {
            var seen = Set<Identity>()
            return picks.filter { pick in
                guard !pick.drawing.isEmpty, !pick.entity.isEmpty else { return false }
                return seen.insert(Identity(drawing: pick.drawing, entity: pick.entity)).inserted
            }
        }

        /// What makes two picks the same entity; `entityType` is advisory and not part of it.
        private struct Identity: Hashable {
            let drawing: String
            let entity: String
        }
    }

#endif
