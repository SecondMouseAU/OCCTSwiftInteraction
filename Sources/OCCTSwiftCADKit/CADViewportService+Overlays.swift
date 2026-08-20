// CADViewportService+Overlays.swift
// OCCTSwiftCADKit
//
// Split out of CADViewportService.swift for OCCTSwiftInteraction#13 (code-structure policy).
// The service's stored state stays in the core file; this is the overlay layer surface of the same
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
}
