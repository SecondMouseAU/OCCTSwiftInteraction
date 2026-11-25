// UncutBody.swift
// OCCTSwiftCADKit
//
// OCCTSwiftInteraction#86: a model body as it was before a cap first cut or hid it, mesh and
// tables together, so a failed re-mesh can put the whole body back rather than its mesh alone.

import OCCTSwift
import OCCTSwiftTools
import OCCTSwiftViewport

/// A model body as it was before `updateCapSurfaces()` first cut or hid it: the mesh, and what a
/// pick on that mesh resolves through.
///
/// What the restore from a cap starts from, and all of what a failed re-mesh puts back: the mesh
/// drawn and the tables a pick reads have to be one body's, so neither goes back without the other.
/// Holding the tables keeps the uncut body's `BRepGraph` alive for as long as the body is capped.
struct UncutBody {
    /// The mesh, as drawn.
    ///
    /// Its `isVisible` is the caller's last visibility write, kept by
    /// `recordCallerVisibility(_:forBody:)`, and its other caller-set state (pickability, material,
    /// transform, layers) is what a cut or restored body inherits.
    var body: _ViewportBody
    let metadata: CADBodyMetadata?
    let faces: FaceIdentityTable?
    let edges: EdgeIdentityTable?
    let vertices: VertexIdentityTable?
    let graph: BRepGraph?
}
