import OCCTSwift
import OCCTSwiftViewport
import Testing
import simd

@testable import OCCTSwiftCADKit

/// Regression coverage for OCCTSwiftInteraction#49: a scalar field set or cleared while an
/// `.overlay`, `.sideBySide` or `.wipe` comparison is active must survive `undoComparison`, which
/// restores whole bodies from the snapshot taken when the comparison began, and a `.perTriangle`
/// field set during a `.wipe` must be indexed by the body's own triangles, not the wiped subset.
///
/// Paint is read back triangle by triangle. Each field's value is the key it is indexed by (a face
/// ordinal or a triangle index), `keyMap` paints a key as a red level that decodes exactly, and a
/// live triangle's expected key comes from matching its vertex indices against the body as it was
/// before the comparison. A triangle carrying another triangle's value fails, not only a missing
/// paint.
///
/// Every test but the two marked "guard" fails without the fix.
@Suite("Scalar field set during a comparison")
struct ComparisonScalarFieldTests {
    // MARK: - Dimensions

    typealias Mode = ComparisonVisibilityTests.Mode
    typealias Target = ComparisonVisibilityTests.Target
    typealias Trigger = ComparisonVisibilityTests.Trigger
    typealias SetupOrder = ComparisonVisibilityTests.SetupOrder

    /// What the field is indexed by.
    enum Domain: CaseIterable, Sendable, CustomTestStringConvertible {
        case perFace
        case perTriangle

        var testDescription: String {
            switch self {
            case .perFace: "per face"
            case .perTriangle: "per triangle"
            }
        }

        var fieldDomain: ScalarField.Domain {
            switch self {
            case .perFace: .perFace
            case .perTriangle: .perTriangle
            }
        }
    }

    struct SingleCase: Sendable, CustomTestStringConvertible {
        var mode: Mode
        var target: Target
        var domain: Domain

        var testDescription: String {
            "\(domain.testDescription) on \(target.testDescription), \(mode.testDescription)"
        }

        static let all = Mode.allCases.flatMap { mode in
            Target.allCases.flatMap { target in
                Domain.allCases.map { SingleCase(mode: mode, target: target, domain: $0) }
            }
        }
    }

    struct SwitchCase: Sendable, CustomTestStringConvertible {
        var from: Mode
        var to: Mode
        var domain: Domain

        var testDescription: String {
            "\(domain.testDescription) in \(from.testDescription), switch to \(to.testDescription)"
        }

        static let all = Mode.allCases.flatMap { from in
            Mode.allCases.flatMap { to in
                Domain.allCases.map { SwitchCase(from: from, to: to, domain: $0) }
            }
        }
    }

    struct TriggerCase: Sendable, CustomTestStringConvertible {
        var mode: Mode
        var trigger: Trigger
        var domain: Domain

        var testDescription: String {
            "\(domain.testDescription), \(mode.testDescription), then \(trigger.testDescription)"
        }

        static let all = Mode.allCases.flatMap { mode in
            Trigger.allCases.flatMap { trigger in
                Domain.allCases.map { TriggerCase(mode: mode, trigger: trigger, domain: $0) }
            }
        }
    }

    struct CapCase: Sendable, CustomTestStringConvertible {
        var mode: Mode
        var setup: SetupOrder
        var domain: Domain

        var testDescription: String {
            "\(domain.testDescription), \(mode.testDescription), \(setup.testDescription)"
        }

        static let all = Mode.allCases.flatMap { mode in
            SetupOrder.allCases.flatMap { setup in
                Domain.allCases.map { CapCase(mode: mode, setup: setup, domain: $0) }
            }
        }
    }

    // MARK: - Painting a key and reading it back

    /// The highest key a field here carries: a 4x4x4 box meshes to 12 triangles on 6 faces.
    static let maxKey = 11

    /// Paints key `k` as an opaque red level of `k / maxKey`, which `key(paintedOn:)` reads back.
    static let keyMap = ColorMap.custom([
        (0, SIMD4<Float>(0, 0, 0, 1)),
        (Double(maxKey), SIMD4<Float>(1, 0, 0, 1)),
    ])

    /// A field whose value for each key, a face ordinal or a triangle index, is the key itself.
    private func keyField(_ domain: Domain) -> ScalarField {
        ScalarField(
            domain: domain.fieldDomain, values: (0...Self.maxKey).map(Double.init),
            colorMap: Self.keyMap, label: "key")
    }

    /// The key a style was painted from, or `nil` for an unpainted triangle.
    private func key(paintedOn style: TriangleStyle) -> Int? {
        guard style.color.w == 1 else { return nil }
        return Int((Double(style.color.x) * Double(Self.maxKey)).rounded())
    }

    /// Each triangle of `body` matched by its vertex indices, which a wipe copies unchanged, to
    /// its index in `baseline`.
    private func baselineTriangles(of body: _ViewportBody, in baseline: _ViewportBody) -> [Int?] {
        func vertexIndices(_ b: _ViewportBody, _ triangle: Int) -> [UInt32] {
            Array(b.indices[(triangle * 3)..<(triangle * 3 + 3)])
        }
        var indexOf: [[UInt32]: Int] = [:]
        for triangle in 0..<(baseline.indices.count / 3) {
            indexOf[vertexIndices(baseline, triangle)] = triangle
        }
        return (0..<(body.indices.count / 3)).map { indexOf[vertexIndices(body, $0)] }
    }

    /// Expects every triangle of the body `id` to be painted with the key its own triangle in
    /// `baseline` has, and the rendered body to carry the same paint.
    @MainActor
    private func expectKeyed(
        _ service: CADViewportService, _ id: String, _ domain: Domain, baseline: _ViewportBody,
        _ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let live = body(service, id) else {
            Issue.record("no model body \(id)", sourceLocation: sourceLocation)
            return
        }
        let expected: [Int?] = baselineTriangles(of: live, in: baseline).map { index in
            guard let index else { return nil }
            switch domain {
            case .perFace: return Int(baseline.faceIndices[index])
            case .perTriangle: return index
            }
        }
        #expect(
            !expected.isEmpty && !expected.contains(nil),
            "sanity check: every triangle is one of the baseline's", sourceLocation: sourceLocation)
        #expect(
            live.triangleStyles.map { key(paintedOn: $0) } == expected, comment,
            sourceLocation: sourceLocation)
        #expect(
            rendered(service, id)?.triangleStyles == live.triangleStyles,
            "and the rendered body carries the same paint", sourceLocation: sourceLocation)
    }

    /// Expects the body `id`, and its rendered copy, to carry no paint at all.
    @MainActor
    private func expectUnpainted(
        _ service: CADViewportService, _ id: String, _ comment: Comment,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            body(service, id)?.triangleStyles.isEmpty == true, comment,
            sourceLocation: sourceLocation)
        #expect(
            rendered(service, id)?.triangleStyles.isEmpty == true,
            "and the rendered body carries none", sourceLocation: sourceLocation)
    }

    /// Whether the body `id` kept exactly the first triangles of `baseline`, which would make a
    /// field indexed by wiped position indistinguishable from one indexed by the body's own.
    @MainActor
    private func keepsLeadingTriangles(
        _ service: CADViewportService, _ id: String, baseline: _ViewportBody
    ) -> Bool {
        guard let live = body(service, id) else { return true }
        let kept = baselineTriangles(of: live, in: baseline)
        return kept == (0..<kept.count).map { Int?($0) }
    }

    // MARK: - Helpers

    /// What a comparison changes on a body: its colour, its transform and how many triangles it
    /// keeps.
    struct ComparedState: Equatable {
        var color: SIMD4<Float>
        var transform: simd_float4x4
        var triangleCount: Int
    }

    /// Both sides' `ComparedState`, reference first.
    @MainActor
    private func comparedState(_ service: CADViewportService) -> [ComparedState?] {
        ["ref", "cand"].map { id in
            body(service, id).map {
                ComparedState(
                    color: $0.color, transform: $0.transform, triangleCount: $0.indices.count / 3)
            }
        }
    }

    @MainActor
    private func view(_ mode: Mode) -> ComparisonView {
        ComparisonView(referenceID: "ref", candidateID: "cand", mode: mode.comparisonMode)
    }

    @MainActor
    private func wipe(at position: Double) -> ComparisonView {
        ComparisonView(
            referenceID: "ref", candidateID: "cand", mode: .wipe(axis: .x, position: position))
    }

    @MainActor
    private func body(_ service: CADViewportService, _ id: String) -> _ViewportBody? {
        service.modelBodies.first { $0.id == id }
    }

    @MainActor
    private func rendered(_ service: CADViewportService, _ id: String) -> _ViewportBody? {
        service.interactiveContext.bodies.first { $0.id == id }
    }

    @MainActor
    private func fire(_ trigger: Trigger, on service: CADViewportService) {
        switch trigger {
        case .resetClippingPlanes:
            service.clippingPlanes = service.clippingPlanes
        case .loadUnrelatedEntity:
            service.loadUnrelatedEntity()
        case .addUnrelatedHollowPlane:
            service.addUnrelatedHollowPlane()
        }
    }

    // MARK: - Clearing or switching the comparison

    @MainActor
    @Test("A scalar field set during a comparison survives clearing it", arguments: SingleCase.all)
    func fieldSurvivesClear(_ testCase: SingleCase) {
        guard let service = CADViewportService.withBoxes(ids: ["ref", "cand"]) else { return }
        let id = testCase.target.id
        guard let baseline = body(service, id) else {
            Issue.record("no model body \(id)")
            return
        }
        let uncompared = comparedState(service)

        service.setComparison(view(testCase.mode))
        let compared = comparedState(service)
        #expect(compared != uncompared, "sanity check: the comparison applied")

        service.setScalarField(keyField(testCase.domain), forBody: id)
        #expect(comparedState(service) == compared, "setting the field leaves the comparison be")
        expectKeyed(
            service, id, testCase.domain, baseline: baseline,
            "the field paints the compared body by its own triangles")

        service.setComparison(nil)
        #expect(comparedState(service) == uncompared, "the clear still undid the comparison")
        #expect(service.scalarField(forBody: id) != nil)
        expectKeyed(
            service, id, testCase.domain, baseline: baseline, "the field must survive the clear")
        expectUnpainted(service, testCase.target.other, "the other side was never painted")
    }

    @MainActor
    @Test(
        "A scalar field set during a comparison survives switching its mode",
        arguments: SwitchCase.all)
    func fieldSurvivesModeSwitch(_ testCase: SwitchCase) {
        guard let service = CADViewportService.withBoxes(ids: ["ref", "cand"]),
            let baseline = body(service, "cand")
        else { return }
        let uncompared = comparedState(service)

        service.setComparison(view(testCase.from))
        service.setScalarField(keyField(testCase.domain), forBody: "cand")
        service.setComparison(view(testCase.to))

        #expect(comparedState(service) != uncompared, "sanity check: the new mode applied")
        expectKeyed(
            service, "cand", testCase.domain, baseline: baseline,
            "the switch must keep the field, on the candidate's own triangles")

        service.setComparison(nil)
        expectKeyed(
            service, "cand", testCase.domain, baseline: baseline,
            "and so must the clear that follows")
    }

    @MainActor
    @Test(
        "A scalar field set during a comparison survives an unrelated cap recompute",
        arguments: TriggerCase.all)
    func fieldSurvivesUnrelatedRecompute(_ testCase: TriggerCase) {
        guard let service = CADViewportService.withBoxes(ids: ["ref", "cand"]),
            let baseline = body(service, "cand")
        else { return }

        service.setComparison(view(testCase.mode))
        let compared = comparedState(service)
        service.setScalarField(keyField(testCase.domain), forBody: "cand")
        fire(testCase.trigger, on: service)

        #expect(service.comparison != nil, "sanity check: the comparison is still active")
        #expect(
            comparedState(service) == compared, "sanity check: the recompute reapplied it")
        #expect(service.scalarField(forBody: "cand") != nil)
        expectKeyed(
            service, "cand", testCase.domain, baseline: baseline,
            "undoing and reapplying the comparison around the recompute must keep the field")

        service.setComparison(nil)
        expectKeyed(
            service, "cand", testCase.domain, baseline: baseline,
            "and so must the clear that follows")
    }

    // MARK: - Indexing under a wipe

    /// The wipe positions used here keep, on both sides, triangles that are not the mesh's first
    /// ones, so a field indexed by wiped position paints other triangles' values; the sanity
    /// checks fail if a change to the tessellation order ever stops that being true.
    @MainActor
    @Test(
        "A per-triangle field set during a wipe paints each triangle with its own value",
        arguments: Target.allCases)
    func perTriangleFieldDuringWipeIsKeyedByOwnTriangle(_ target: Target) {
        guard let service = CADViewportService.withBoxes(ids: ["ref", "cand"]),
            let baseline = body(service, target.id)
        else { return }
        let id = target.id

        service.setComparison(wipe(at: 1))
        #expect(
            !keepsLeadingTriangles(service, id, baseline: baseline),
            "sanity check: the wipe keeps triangles other than the first ones")
        service.setScalarField(keyField(.perTriangle), forBody: id)
        expectKeyed(
            service, id, .perTriangle, baseline: baseline,
            "each kept triangle carries its own value, not the one at its wiped position")

        service.setComparison(wipe(at: 0))
        #expect(
            !keepsLeadingTriangles(service, id, baseline: baseline),
            "sanity check: the moved wipe keeps triangles other than the first ones")
        expectKeyed(
            service, id, .perTriangle, baseline: baseline,
            "moving the wipe filters the field again from the whole mesh")

        service.setComparison(nil)
        #expect(body(service, id)?.indices == baseline.indices, "sanity check: the wipe is gone")
        expectKeyed(
            service, id, .perTriangle, baseline: baseline,
            "and the clear gives every triangle back its own value")
    }

    // MARK: - Clearing the field

    @MainActor
    @Test(
        "A scalar field cleared during a comparison stays cleared after it",
        arguments: SingleCase.all)
    func fieldClearedDuringComparisonStaysCleared(_ testCase: SingleCase) {
        guard let service = CADViewportService.withBoxes(ids: ["ref", "cand"]) else { return }
        let id = testCase.target.id
        service.setScalarField(keyField(testCase.domain), forBody: id)

        service.setComparison(view(testCase.mode))
        service.setScalarField(nil, forBody: id)
        expectUnpainted(service, id, "the clear removes the paint during the comparison")

        service.setComparison(nil)
        #expect(service.scalarField(forBody: id) == nil)
        #expect(service.scalarFieldLegend == nil)
        expectUnpainted(service, id, "ending the comparison must not bring the paint back")
    }

    // MARK: - A body that is both capped and in a comparison

    @MainActor
    @Test(
        "A scalar field set during a comparison on a capped body survives clearing the comparison",
        arguments: CapCase.all)
    func fieldOnCappedBodySurvivesClear(_ testCase: CapCase) {
        guard let service = CADViewportService.withBoxes(ids: ["ref", "cand"]) else { return }

        var planeID = ""
        switch testCase.setup {
        case .capThenComparison:
            planeID = service.addHalfCap()
            service.setComparison(view(testCase.mode))
        case .comparisonThenCap:
            service.setComparison(view(testCase.mode))
            planeID = service.addHalfCap()
        }
        #expect((service.entityMinX("ref") ?? -2) > -0.5, "sanity check: the body is capped")
        service.setScalarField(keyField(testCase.domain), forBody: "ref")

        service.setComparison(nil)
        #expect((service.entityMinX("ref") ?? -2) > -0.5, "sanity check: it is still capped")
        #expect(service.scalarField(forBody: "ref") != nil)
        // With the comparison gone the body is the capped mesh again, so its own triangles are
        // the baseline.
        if let capped = body(service, "ref") {
            expectKeyed(
                service, "ref", testCase.domain, baseline: capped,
                "clearing the comparison on a capped body must keep the field")
        }

        service.removeClippingPlane(id: planeID)
        #expect(
            service.scalarField(forBody: "ref") == nil,
            "removing the cap retessellates, which clears the field as it always has")
        expectUnpainted(service, "ref", "and its paint")
    }

    // MARK: - Neighbours

    /// Guard: passes without the fix, since a field set before the comparison is in its snapshot.
    @MainActor
    @Test("A scalar field set before a comparison survives it", arguments: SingleCase.all)
    func fieldSetBeforeComparisonSurvives(_ testCase: SingleCase) {
        guard let service = CADViewportService.withBoxes(ids: ["ref", "cand"]) else { return }
        let id = testCase.target.id
        guard let baseline = body(service, id) else {
            Issue.record("no model body \(id)")
            return
        }
        service.setScalarField(keyField(testCase.domain), forBody: id)

        service.setComparison(view(testCase.mode))
        expectKeyed(
            service, id, testCase.domain, baseline: baseline,
            "the comparison carries the field over")

        service.setComparison(nil)
        expectKeyed(service, id, testCase.domain, baseline: baseline, "and so does the clear")
    }

    /// Guard: passes without the fix. `.deviation` keeps no snapshot, so a field set during it is
    /// written straight to the body, and clearing it still clears the candidate's field.
    @MainActor
    @Test("Clearing a deviation comparison still clears the candidate's field")
    func deviationClearStillClearsTheField() {
        guard let service = CADViewportService.withBoxes(ids: ["ref", "cand"]),
            let baseline = body(service, "cand")
        else { return }

        service.setComparison(
            ComparisonView(referenceID: "ref", candidateID: "cand", mode: .deviation))
        service.setScalarField(keyField(.perFace), forBody: "cand")
        expectKeyed(
            service, "cand", .perFace, baseline: baseline, "the field paints the candidate")

        service.setComparison(nil)
        #expect(service.scalarField(forBody: "cand") == nil)
        expectUnpainted(service, "cand", "clearing a deviation comparison clears its field")
    }
}
