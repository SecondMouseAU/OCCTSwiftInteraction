// SurfaceConverter.swift
// OCCTSwiftTools
//
// Converts OCCTSwift Surface objects to ViewportBody grid visualizations.

import OCCTSwift
import OCCTSwiftViewport
import simd

/// Converts OCCTSwift Surface objects to UV isoparametric grid ViewportBody values.
public enum SurfaceConverter {

    /// Converts a Surface to a pair of edge-only ViewportBody values showing U and V isoparametric lines.
    /// - Parameters:
    ///   - surface: The surface to visualize.
    ///   - idPrefix: Prefix for body IDs (produces "\(idPrefix)-u" and "\(idPrefix)-v").
    ///   - offset: 3D offset applied to all grid points.
    ///   - uColor: Color for U-direction isoparametric lines.
    ///   - vColor: Color for V-direction isoparametric lines.
    ///   - uLines: Number of U-direction lines (default 10).
    ///   - vLines: Number of V-direction lines (default 10).
    /// - Returns: Up to two edge-only bodies, one per direction with at least one 2-point
    ///   polyline; a direction with no such polyline is omitted.
    public static func surfaceToGridBodies(
        _ surface: Surface,
        idPrefix: String,
        offset: SIMD3<Double> = .zero,
        uColor: SIMD4<Float>,
        vColor: SIMD4<Float>,
        uLines: Int = 10,
        vLines: Int = 10
    ) -> [ViewportBody] {
        let gridPolylines = surface.drawGrid(
            uLineCount: uLines, vLineCount: vLines, pointsPerLine: 50
        )

        let totalLines = uLines + vLines
        var uEdges: [[SIMD3<Float>]] = []
        var vEdges: [[SIMD3<Float>]] = []

        for (i, polyline) in gridPolylines.enumerated() {
            let floatPolyline: [SIMD3<Float>] = polyline.map {
                SIMD3<Float>(
                    Float($0.x + offset.x),
                    Float($0.y + offset.y),
                    Float($0.z + offset.z)
                )
            }
            guard floatPolyline.count >= 2 else { continue }

            if i < uLines {
                uEdges.append(floatPolyline)
            } else if i < totalLines {
                vEdges.append(floatPolyline)
            } else {
                uEdges.append(floatPolyline)
            }
        }

        var bodies: [ViewportBody] = []

        if !uEdges.isEmpty {
            bodies.append(
                ViewportBody(
                    id: "\(idPrefix)-u", vertexData: [], indices: [],
                    edges: uEdges, color: uColor
                ))
        }

        if !vEdges.isEmpty {
            bodies.append(
                ViewportBody(
                    id: "\(idPrefix)-v", vertexData: [], indices: [],
                    edges: vEdges, color: vColor
                ))
        }

        return bodies
    }
}
