import Foundation
import simd

/// A scalar value per face or per triangle, painted over a body via
/// `CADViewportService.setScalarField(_:forBody:)`. Generalises deviation heatmaps to any
/// per-surface quantity — curvature, wall thickness, draft angle, confidence — since the
/// rendering mechanism (a per-triangle GPU style buffer) doesn't care what the numbers mean.
public struct ScalarField: Sendable {
    /// What `values` is indexed by.
    public enum Domain: Sendable, Equatable {
        /// `values[ordinal]` is indexed the same way `PickedFaceInfo.faceIndex` is — the
        /// picked body's face-ordinal (`CADBodyMetadata.faceIndices`/`ViewportBody.faceIndices`).
        case perFace
        /// `values[triangleIndex]` is indexed directly by triangle — one value per mesh
        /// triangle, for fields that vary within a face (e.g. per-vertex-averaged deviation
        /// baked to per-triangle at mesh time).
        case perTriangle
    }

    public let domain: Domain

    /// One value per face ordinal (`domain == .perFace`) or per triangle (`.perTriangle`).
    /// A missing/out-of-range index for a given triangle simply isn't painted (its
    /// `TriangleStyle` stays `.none`) rather than crashing or wrapping.
    public let values: [Double]

    /// The value range the color map spans. `nil` auto-ranges to `values`' own min/max
    /// (ignoring any `.nan` entries).
    public let range: ClosedRange<Double>?

    public let colorMap: ColorMap

    /// e.g. "deviation", "wall thickness".
    public let label: String

    /// e.g. "mm". `nil` if the quantity is dimensionless (e.g. a 0-1 confidence score).
    public let unit: String?

    public init(
        domain: Domain,
        values: [Double],
        range: ClosedRange<Double>? = nil,
        colorMap: ColorMap,
        label: String,
        unit: String? = nil
    ) {
        self.domain = domain
        self.values = values
        self.range = range
        self.colorMap = colorMap
        self.label = label
        self.unit = unit
    }

    /// `range`, or `values`' own min/max when `range` is `nil`. `nil` only if `values` is
    /// empty or every entry is `.nan`.
    public var effectiveRange: ClosedRange<Double>? {
        if let range { return range }
        let finite = values.filter { !$0.isNaN }
        guard let lo = finite.min(), let hi = finite.max() else { return nil }
        return lo <= hi ? lo...hi : hi...hi
    }
}

/// How a scalar value maps to a color. Every case samples deterministically from a
/// `ClosedRange<Double>` (see `ScalarField.effectiveRange`), so the same value always
/// paints the same color regardless of which triangle carries it.
public enum ColorMap: Sendable, Equatable {
    /// Perceptually-uniform sequential ramps (dark→light), good defaults for an
    /// unsigned magnitude (curvature, thickness, confidence). Approximate reproductions
    /// of the published matplotlib/Google colormaps of the same name — close enough for
    /// review purposes, not colorimetrically exact.
    case viridis, magma, turbo

    /// A two-sided ramp about `center` — blue (below) through white (at `center`) to red
    /// (above). Use for signed deviation: material outside the source and material
    /// missing from it are different failures, and a one-ended ramp hides which is which.
    case diverging(center: Double)

    /// Discrete bands: `levels` are the boundaries between them (e.g. `[0.5, 1.0]` for
    /// pass/warn/fail), sorted ascending. Colors cycle through a small built-in
    /// pass→fail palette (green, yellow, orange, red, purple, repeating if there are more
    /// bands than colors).
    case threshold(levels: [Double])

    /// Explicit (value, color) stops, linearly interpolated between the two bracketing
    /// stops for a value between them; clamped to the nearest stop's color outside their
    /// span. `value`s need not be sorted going in.
    case custom([(Double, SIMD4<Float>)])

    public static func == (lhs: ColorMap, rhs: ColorMap) -> Bool {
        switch (lhs, rhs) {
        case (.viridis, .viridis), (.magma, .magma), (.turbo, .turbo):
            return true
        case (.diverging(let l), .diverging(let r)):
            return l == r
        case (.threshold(let l), .threshold(let r)):
            return l == r
        case (.custom(let l), .custom(let r)):
            return l.count == r.count && zip(l, r).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default:
            return false
        }
    }

    /// Samples the color for `value` within `range`. `value` outside `range` clamps to
    /// the nearest end (except `.threshold`, which only cares which side of each level
    /// `value` falls on).
    public func color(for value: Double, in range: ClosedRange<Double>) -> SIMD4<Float> {
        guard !value.isNaN else { return SIMD4(0, 0, 0, 0) } // unpainted, matches TriangleStyle.none
        switch self {
        case .viridis:
            return Self.rgb(Self.sampleGradient(Self.viridisStops, at: Self.normalize(value, range)))
        case .magma:
            return Self.rgb(Self.sampleGradient(Self.magmaStops, at: Self.normalize(value, range)))
        case .turbo:
            return Self.rgb(Self.turboColor(Self.normalize(value, range)))
        case .diverging(let center):
            return Self.rgb(Self.divergingColor(value: value, center: center, range: range))
        case .threshold(let levels):
            return Self.thresholdPalette[Self.band(for: value, levels: levels) % Self.thresholdPalette.count]
        case .custom(let stops):
            return Self.rgb(Self.sampleCustomStops(stops, at: value))
        }
    }

    // MARK: - Normalization

    private static func normalize(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    private static func rgb(_ c: SIMD3<Double>) -> SIMD4<Float> {
        SIMD4<Float>(Float(c.x), Float(c.y), Float(c.z), 1.0)
    }

    // MARK: - Sequential gradients (anchor-color interpolation)

    /// Anchor colors sampled from matplotlib's published viridis LUT at t = 0, 0.25, 0.5,
    /// 0.75, 1.0 (dark purple → blue → teal → green → yellow).
    private static let viridisStops: [(Double, SIMD3<Double>)] = [
        (0.00, SIMD3(0.267, 0.005, 0.329)),
        (0.25, SIMD3(0.231, 0.322, 0.545)),
        (0.50, SIMD3(0.129, 0.567, 0.549)),
        (0.75, SIMD3(0.369, 0.788, 0.384)),
        (1.00, SIMD3(0.992, 0.906, 0.145)),
    ]

    /// Anchor colors sampled from matplotlib's published magma LUT at t = 0, 0.25, 0.5,
    /// 0.75, 1.0 (near-black → purple → magenta-red → orange → pale yellow).
    private static let magmaStops: [(Double, SIMD3<Double>)] = [
        (0.00, SIMD3(0.001, 0.000, 0.016)),
        (0.25, SIMD3(0.317, 0.071, 0.486)),
        (0.50, SIMD3(0.716, 0.215, 0.475)),
        (0.75, SIMD3(0.987, 0.535, 0.380)),
        (1.00, SIMD3(0.987, 0.991, 0.749)),
    ]

    private static func sampleGradient(_ stops: [(Double, SIMD3<Double>)], at t: Double) -> SIMD3<Double> {
        guard let first = stops.first else { return SIMD3(0, 0, 0) }
        guard t > first.0 else { return first.1 }
        for i in 1..<stops.count {
            let (t1, c1) = stops[i]
            if t <= t1 {
                let (t0, c0) = stops[i - 1]
                let localT = (t1 - t0) > 0 ? (t - t0) / (t1 - t0) : 0
                return mix(c0, c1, t: localT)
            }
        }
        return stops.last!.1
    }

    private static func mix(_ a: SIMD3<Double>, _ b: SIMD3<Double>, t: Double) -> SIMD3<Double> {
        a + (b - a) * t
    }

    // MARK: - Turbo (polynomial approximation)

    /// Google's published polynomial approximation of the Turbo colormap (Anton Mikhailov,
    /// 2019, public domain) — a compact fit rather than a 256-entry LUT.
    private static func turboColor(_ t: Double) -> SIMD3<Double> {
        let x = min(max(t, 0), 1)
        let x2 = x * x
        let x3 = x2 * x
        let x4 = x3 * x
        let x5 = x4 * x

        let r = 0.13572138 + 4.61539260 * x - 42.66032258 * x2 + 132.13108234 * x3
            - 152.94239396 * x4 + 59.28637943 * x5
        let g = 0.09140261 + 2.19418839 * x + 4.84296658 * x2 - 14.18503333 * x3
            + 4.27729857 * x4 + 2.82956604 * x5
        let b = 0.10667330 + 12.64194608 * x - 60.58204836 * x2 + 110.36276771 * x3
            - 89.90310912 * x4 + 27.34824973 * x5

        return SIMD3(min(max(r, 0), 1), min(max(g, 0), 1), min(max(b, 0), 1))
    }

    // MARK: - Diverging

    private static func divergingColor(value: Double, center: Double, range: ClosedRange<Double>) -> SIMD3<Double> {
        let maxDeviation = max(abs(range.upperBound - center), abs(range.lowerBound - center))
        guard maxDeviation > 0 else { return SIMD3(1, 1, 1) }
        let t = min(max((value - center) / maxDeviation, -1), 1)
        let white = SIMD3<Double>(0.98, 0.98, 0.98)
        if t >= 0 {
            let red = SIMD3<Double>(0.70, 0.06, 0.06)
            return mix(white, red, t: t)
        } else {
            let blue = SIMD3<Double>(0.05, 0.20, 0.70)
            return mix(blue, white, t: t + 1)
        }
    }

    // MARK: - Threshold

    static let thresholdPalette: [SIMD4<Float>] = [
        SIMD4(0.15, 0.75, 0.25, 1), // pass — green
        SIMD4(0.95, 0.85, 0.15, 1), // warn — yellow
        SIMD4(0.90, 0.45, 0.10, 1), // caution — orange
        SIMD4(0.85, 0.15, 0.15, 1), // fail — red
        SIMD4(0.55, 0.15, 0.65, 1), // purple, repeats from here for extra bands
    ]

    private static func band(for value: Double, levels: [Double]) -> Int {
        let sorted = levels.sorted()
        return sorted.filter { value >= $0 }.count
    }

    // MARK: - Custom stops

    private static func sampleCustomStops(_ stops: [(Double, SIMD4<Float>)], at value: Double) -> SIMD3<Double> {
        guard !stops.isEmpty else { return SIMD3(0, 0, 0) }
        let sorted = stops.sorted { $0.0 < $1.0 }
        guard value > sorted.first!.0 else {
            let c = sorted.first!.1
            return SIMD3(Double(c.x), Double(c.y), Double(c.z))
        }
        for i in 1..<sorted.count {
            let (v1, c1) = sorted[i]
            if value <= v1 {
                let (v0, c0) = sorted[i - 1]
                let localT = (v1 - v0) > 0 ? (value - v0) / (v1 - v0) : 0
                let c0d = SIMD3<Double>(Double(c0.x), Double(c0.y), Double(c0.z))
                let c1d = SIMD3<Double>(Double(c1.x), Double(c1.y), Double(c1.z))
                return mix(c0d, c1d, t: localT)
            }
        }
        let c = sorted.last!.1
        return SIMD3(Double(c.x), Double(c.y), Double(c.z))
    }
}

/// A single labeled point on a rendered legend — see `ScalarFieldLegend.stops`.
public struct LegendStop: Sendable, Equatable {
    public let value: Double
    public let color: SIMD4<Float>

    public init(value: Double, color: SIMD4<Float>) {
        self.value = value
        self.color = color
    }
}

/// Everything a UI needs to render a scalar field's legend: the label, unit, range, and a
/// sampled gradient (or discrete swatches, for `.threshold`) a caller can lay out as a
/// color bar with tick labels. Returned by `CADViewportService.scalarFieldLegend`.
public struct ScalarFieldLegend: Sendable, Equatable {
    public let label: String
    public let unit: String?
    public let range: ClosedRange<Double>

    /// Evenly-spaced (value, color) samples across `range`, low to high.
    public let stops: [LegendStop]

    public init(label: String, unit: String?, range: ClosedRange<Double>, stops: [LegendStop]) {
        self.label = label
        self.unit = unit
        self.range = range
        self.stops = stops
    }
}
