// AgentAttentionLabelTests.swift
// OCCTSwiftCADKitTests
//
// Coverage for OCCTSwiftInteraction#54: an attention label is held at most 80 characters and 4096
// UTF-8 bytes, and a label that draws nothing is no label, whether it arrives through
// `setAgentAttention(_:label:)` or a `highlight_requests/<id>.json` payload. Every test runs once
// per entry point.

import Foundation
import OCCTSwift
import Testing

@testable import OCCTSwiftCADKit

/// The two ways a label reaches `agentAttentionLabel`.
enum AttentionLabelEntryPoint: String, CaseIterable, Sendable {
    /// A host calling `setAgentAttention(_:label:)` itself.
    case direct
    #if os(macOS)
        /// A client writing `highlight_requests/<id>.json` for the sidecar.
        case sidecar
    #endif
}

/// What a label came out as, after one trip through a `AttentionLabelEntryPoint`.
private struct HeldLabel {
    var label: String?
    var markerLanded: Bool
    /// The handled file's `reason`, sidecar only.
    var reason: String?
}

/// One blank-rendering label, named so a failing case reads in the test log.
struct BlankAttentionLabel: Sendable, CustomTestStringConvertible {
    var name: String
    var label: String
    var testDescription: String { name }
}

/// Sends `label` to a fresh service's attention marker through `entry`.
///
/// `scheme` is the request's, so it applies to `.sidecar` only: `.direct` always sets the marker.
@MainActor
private func sendLabel(
    _ label: String?, via entry: AttentionLabelEntryPoint, scheme: String = "replace"
) throws -> HeldLabel {
    let box = try #require(Shape.box(width: 10, height: 8, depth: 6))
    let service = CADViewportService()
    service.load(box, id: "box")
    let pick = try #require(service.resolveFacePick(bodyID: "box", triangleIndex: 0))

    switch entry {
    case .direct:
        service.setAgentAttention(.face(pick), label: label)
        return HeldLabel(
            label: service.agentAttentionLabel,
            markerLanded: service.agentAttention == .face(pick), reason: nil)

    #if os(macOS)
        case .sidecar:
            let dir = try startSidecar(on: service)
            defer { stopSidecar(on: service, in: dir) }
            let outcome = try post(
                HighlightRequestPayload(
                    id: "label", bodyId: "box", kind: "face", index: pick.faceIndex,
                    scheme: scheme, question: nil, label: label),
                to: service, in: dir)
            #expect(outcome.outcome == "applied")
            #expect(outcome.target == "attention")
            return HeldLabel(
                label: service.agentAttentionLabel,
                markerLanded: service.agentAttention == .face(pick), reason: outcome.reason)
    #endif
    }
}

#if os(macOS)
    /// Starts the sidecar of `service` in a fresh temporary directory and returns that directory.
    @MainActor
    private func startSidecar(on service: CADViewportService) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "occt-attention-label-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try service.startSelectionSidecar(directory: dir)
        return dir
    }

    @MainActor
    private func stopSidecar(on service: CADViewportService, in dir: URL) {
        service.stopSelectionSidecar()
        try? FileManager.default.removeItem(at: dir)
    }

    /// Writes `request` as a client would, has `service` process it, and returns the outcome.
    @MainActor
    private func post(
        _ request: HighlightRequestPayload, to service: CADViewportService, in dir: URL
    ) throws -> HandledOutcome {
        let name = "\(request.id).json"
        let requestURL = CADViewportService.highlightRequestsDirectory(in: dir)
            .appendingPathComponent(name)
        try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)
        service.processHighlightRequests()
        let handledURL = CADViewportService.handledDirectory(in: dir).appendingPathComponent(name)
        let data = try #require(FileManager.default.contents(atPath: handledURL.path))
        return try JSONDecoder().decode(HandledOutcome.self, from: data)
    }
#endif

private let ellipsis = "\u{2026}"
/// Four people joined by three ZWJs: one `Character`, seven scalars.
private let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
/// A thumbs up with a skin-tone modifier: one `Character`, two scalars.
private let thumbsUp = "\u{1F44D}\u{1F3FD}"

private func letters(_ count: Int, _ letter: Character = "a") -> String {
    String(repeating: letter, count: count)
}

/// One `Character` of `1 + 2 * marks` UTF-8 bytes: an "a" carrying `marks` combining acutes.
private func heavyCharacter(marks: Int) -> String {
    "a" + String(repeating: "\u{0301}", count: marks)
}

/// The reason for a label that is not blank but has nothing visible in front of the cut.
private let nothingVisibleFits =
    "label dropped: no visible character fits within 80 characters and 4096 bytes"

/// Labels that draw nothing, one per rule `AgentAttentionLabel.isBlank(_:)` names.
private let blankLabels: [BlankAttentionLabel] = [
    BlankAttentionLabel(name: "empty", label: ""),
    BlankAttentionLabel(name: "spaces", label: "   "),
    BlankAttentionLabel(name: "tabs and newlines", label: "\t\n\r\n"),
    BlankAttentionLabel(name: "no-break space", label: "\u{00A0}"),
    BlankAttentionLabel(name: "ideographic space", label: "\u{3000}"),
    BlankAttentionLabel(name: "line separator", label: "\u{2028}"),
    BlankAttentionLabel(name: "bell", label: "\u{0007}"),
    BlankAttentionLabel(name: "zero-width space", label: "\u{200B}"),
    BlankAttentionLabel(name: "zero-width joiner", label: "\u{200D}"),
    BlankAttentionLabel(name: "byte order mark", label: "\u{FEFF}"),
    BlankAttentionLabel(name: "right-to-left override", label: "\u{202E}"),
    BlankAttentionLabel(name: "soft hyphen", label: "\u{00AD}"),
    BlankAttentionLabel(name: "variation selector 16", label: "\u{FE0F}"),
    BlankAttentionLabel(name: "Hangul filler", label: "\u{3164}"),
    BlankAttentionLabel(name: "Hangul choseong filler", label: "\u{115F}"),
    BlankAttentionLabel(name: "Hangul jungseong filler", label: "\u{1160}"),
    BlankAttentionLabel(name: "halfwidth Hangul filler", label: "\u{FFA0}"),
    BlankAttentionLabel(name: "braille blank", label: "\u{2800}"),
    BlankAttentionLabel(name: "interlinear annotation controls", label: "\u{FFF9}\u{FFFA}\u{FFFB}"),
    BlankAttentionLabel(name: "object replacement character", label: "\u{FFFC}"),
    BlankAttentionLabel(name: "Khitan small script filler", label: "\u{16FE4}"),
    BlankAttentionLabel(name: "musical null notehead", label: "\u{1D159}"),
    BlankAttentionLabel(name: "word joiner and non-joiner", label: "\u{2060}\u{200C}"),
    BlankAttentionLabel(
        name: "a mix of them", label: " \u{200B}\u{3164}\n\u{2800}\u{FEFF}\u{115F}"),
    BlankAttentionLabel(
        name: "blank and over the bound",
        label: String(repeating: "\u{200B}\u{2800}", count: 100)),
]

@Suite("Agent attention label bounds")
struct AgentAttentionLabelTests {

    @MainActor
    @Test(
        "A label over 80 characters is cut to 79 and an ellipsis",
        arguments: AttentionLabelEntryPoint.allCases)
    func overLongLabelIsCut(entry: AttentionLabelEntryPoint) throws {
        let justOver = try sendLabel(letters(81), via: entry)
        #expect(justOver.label == letters(79) + ellipsis)
        #expect(justOver.label?.count == 80)
        #expect(justOver.markerLanded)
        if entry != .direct {
            #expect(justOver.reason == "label cut from 81 to 80 characters")
        }

        let huge = try sendLabel(letters(100_000, "z"), via: entry)
        #expect(huge.label == letters(79, "z") + ellipsis)

        // Character 79, the last kept, draws nothing: dropped, so the ellipsis follows a letter,
        // and the reason gives the length actually held.
        let spaceAtCut = try sendLabel(letters(78) + " " + letters(4, "b"), via: entry)
        #expect(spaceAtCut.label == letters(78) + ellipsis)
        if entry != .direct {
            #expect(spaceAtCut.reason == "label cut from 83 to 79 characters")
        }
        let invisibleAtCut = try sendLabel(letters(78) + "\u{200B}" + letters(4, "b"), via: entry)
        #expect(invisibleAtCut.label == letters(78) + ellipsis)

        // Every blank character before the cut goes, not only the last: a label padded past the
        // bound keeps its words, and one blank up to the cut is no label, not an ellipsis alone,
        // so a host falls back to its own caption.
        let padded = try sendLabel("the datum face" + letters(70, " "), via: entry)
        #expect(padded.label == "the datum face" + ellipsis)
        if entry != .direct {
            #expect(padded.reason == "label cut from 84 to 15 characters")
        }
        let blankUpToCut = try sendLabel(
            letters(40, " ") + letters(39, "\u{3164}") + "xy", via: entry)
        #expect(blankUpToCut.label == nil)
        #expect(blankUpToCut.markerLanded)
        if entry != .direct {
            #expect(blankUpToCut.reason == nothingVisibleFits)
        }

        // U+0600 is a Prepend character, a character of its own here only because the tab after
        // it ends the cluster. As character 79 it would take the ellipsis into itself, so it goes.
        let prependAtCut = try sendLabel(
            letters(78) + "\u{0600}" + "\t" + letters(4, "b"), via: entry)
        #expect(prependAtCut.label == letters(78) + ellipsis)
        #expect(prependAtCut.label?.last == AgentAttentionLabel.ellipsis)

        if entry != .direct {
            // xor sets the marker when it is not already set, and cuts its label the same way.
            let toggledOn = try sendLabel(letters(81), via: entry, scheme: "xor")
            #expect(toggledOn.label == letters(79) + ellipsis)
            #expect(toggledOn.reason == "label cut from 81 to 80 characters")
        }
    }

    @MainActor
    @Test(
        "A label of exactly 80 characters is held unchanged, counted in Characters",
        arguments: AttentionLabelEntryPoint.allCases)
    func labelAtTheBoundIsUnchanged(entry: AttentionLabelEntryPoint) throws {
        let ascii = try sendLabel(letters(80), via: entry)
        #expect(ascii.label == letters(80))
        if entry != .direct { #expect(ascii.reason == nil) }

        // 80 Characters, but 86 scalars and 90 UTF-16 units: OCCTMCP's `String.count` accepts
        // it, so it must not be cut here.
        let clustered = letters(79) + family
        #expect(clustered.unicodeScalars.count == 86)
        let held = try sendLabel(clustered, via: entry)
        #expect(held.label?.unicodeScalars.elementsEqual(clustered.unicodeScalars) == true)
        if entry != .direct { #expect(held.reason == nil) }
    }

    @MainActor
    @Test(
        "A multi-scalar character at the bound is kept whole or dropped whole",
        arguments: AttentionLabelEntryPoint.allCases)
    func clusterAtTheBoundIsNotSplit(entry: AttentionLabelEntryPoint) throws {
        // Character 79, the last kept: kept with all of its scalars.
        let familyKept = try sendLabel(letters(78) + family + "bb", via: entry)
        #expect(familyKept.label == letters(78) + family + ellipsis)
        #expect(familyKept.label?.count == 80)
        if entry != .direct {
            // 87 scalars in, 86 out: the reason counts Characters, as OCCTMCP's bound does.
            #expect(familyKept.reason == "label cut from 81 to 80 characters")
        }
        if let label = familyKept.label {
            #expect(
                Array(label.unicodeScalars.suffix(8)) == Array((family + ellipsis).unicodeScalars))
        }

        let thumbKept = try sendLabel(letters(78) + thumbsUp + "bb", via: entry)
        #expect(thumbKept.label == letters(78) + thumbsUp + ellipsis)

        // Character 80, the first cut: no scalar of it survives.
        let familyCut = try sendLabel(letters(79) + family + "b", via: entry)
        #expect(familyCut.label == letters(79) + ellipsis)
        if let label = familyCut.label {
            #expect(!label.unicodeScalars.contains("\u{200D}"))
            #expect(!label.unicodeScalars.contains("\u{1F468}"))
        }

        let thumbCut = try sendLabel(letters(79) + thumbsUp + "b", via: entry)
        #expect(thumbCut.label == letters(79) + ellipsis)
        if let label = thumbCut.label {
            #expect(!label.unicodeScalars.contains("\u{1F3FD}"))
        }
    }

    @MainActor
    @Test(
        "A label over 4096 UTF-8 bytes is cut to the whole characters that fit",
        arguments: AttentionLabelEntryPoint.allCases)
    func heavyLabelIsCutByBytes(entry: AttentionLabelEntryPoint) throws {
        // Exactly at the bound: 1 + 4095 bytes in two characters. Held as sent.
        let atBound = "b" + heavyCharacter(marks: 2047)
        #expect(atBound.utf8.count == 4096)
        let atBoundHeld = try sendLabel(atBound, via: entry)
        #expect(atBoundHeld.label?.unicodeScalars.elementsEqual(atBound.unicodeScalars) == true)
        if entry != .direct { #expect(atBoundHeld.reason == nil) }

        // One byte over: the heavy character no longer fits in front of the ellipsis, and is
        // dropped whole rather than split between its scalars.
        let overBound = try sendLabel("bc" + heavyCharacter(marks: 2047), via: entry)
        #expect(overBound.label == "bc" + ellipsis)
        if entry != .direct {
            #expect(overBound.reason == "label cut from 4097 to 5 bytes")
        }

        // 40 characters of 119 bytes each: within OCCTMCP's 80, but 4,760 bytes. 34 fit with the
        // ellipsis (34 * 119 + 3 = 4,049; 35 would be 4,168).
        let heavy = String(repeating: heavyCharacter(marks: 59), count: 40)
        let heavyHeld = try sendLabel(heavy, via: entry)
        let heavyKept = String(repeating: heavyCharacter(marks: 59), count: 34) + ellipsis
        #expect(heavyHeld.label?.unicodeScalars.elementsEqual(heavyKept.unicodeScalars) == true)
        #expect(heavyHeld.label?.count == 35)
        if entry != .direct {
            #expect(heavyHeld.reason == "label cut from 4760 to 4049 bytes")
        }

        // One character of 200,001 bytes, which OCCTMCP's count takes as one: nothing visible
        // fits, so no label, and the marker still lands.
        let single = try sendLabel(heavyCharacter(marks: 100_000), via: entry)
        #expect(single.label == nil)
        #expect(single.markerLanded)
        if entry != .direct { #expect(single.reason == nothingVisibleFits) }

        // Visible text after it does not help, since the cut keeps a prefix.
        let leading = try sendLabel(heavyCharacter(marks: 100_000) + "the datum face", via: entry)
        #expect(leading.label == nil)
        if entry != .direct { #expect(leading.reason == nothingVisibleFits) }

        // Visible text in front of it is kept.
        let trailing = try sendLabel("the datum face" + heavyCharacter(marks: 100_000), via: entry)
        #expect(trailing.label == "the datum face" + ellipsis)
        if entry != .direct {
            #expect(trailing.reason == "label cut from 200015 to 17 bytes")
        }
    }

    @MainActor
    @Test(
        "A label that draws nothing is no label, and the marker still lands",
        arguments: AttentionLabelEntryPoint.allCases, blankLabels)
    func blankLabelIsNoLabel(entry: AttentionLabelEntryPoint, blank: BlankAttentionLabel) throws {
        let held = try sendLabel(blank.label, via: entry)
        #expect(held.label == nil)
        #expect(held.markerLanded)
        if entry != .direct {
            // An empty label was always ignored without comment; a non-empty one is reported.
            #expect(
                held.reason
                    == (blank.label.isEmpty ? nil : "label dropped: it has no visible character"))
        }
    }

    @MainActor
    @Test(
        "A label with a visible character is held exactly as sent",
        arguments: AttentionLabelEntryPoint.allCases)
    func visibleLabelIsUnchanged(entry: AttentionLabelEntryPoint) throws {
        let labels = [
            "the datum face",
            "  padded, as OCCTMCP writes it  ",
            "zero\u{200B}width inside",
            "\u{2800}x",
            // Format characters that are not default-ignorable draw a mark.
            "\u{06DD}",
            "\u{0600}",
            "\u{200B}" + letters(79),
            "e\u{0301}paule",
            "\u{9762}\u{53D6}\u{308A}",
            thumbsUp + " this one",
        ]
        for label in labels {
            let held = try sendLabel(label, via: entry)
            // Scalars, not `String ==`, which would also accept a normalised form.
            #expect(held.label?.unicodeScalars.elementsEqual(label.unicodeScalars) == true)
            if entry != .direct { #expect(held.reason == nil) }
        }
        let absent = try sendLabel(nil, via: entry)
        #expect(absent.label == nil)
        #expect(absent.markerLanded)
        if entry != .direct { #expect(absent.reason == nil) }
    }

    #if os(macOS)
        @MainActor
        @Test("A request that does not set the marker says nothing about its label")
        func labelReasonOnlyWhenTheMarkerIsSet() throws {
            let box = try #require(Shape.box(width: 10, height: 8, depth: 6))
            let service = CADViewportService()
            service.load(box, id: "box")
            let pick = try #require(service.resolveFacePick(bodyID: "box", triangleIndex: 0))
            let dir = try startSidecar(on: service)
            defer { stopSidecar(on: service, in: dir) }

            // Every request carries a label that would be cut, and so reported, if it were held.
            func send(_ id: String, scheme: String, target: String? = nil) throws -> HandledOutcome
            {
                try post(
                    HighlightRequestPayload(
                        id: id, bodyId: "box", kind: "face", index: pick.faceIndex,
                        scheme: scheme, question: nil, target: target, label: letters(81)),
                    to: service, in: dir)
            }

            service.setAgentAttention(.face(pick), label: "the datum face")
            let removed = try send("remove", scheme: "remove")
            #expect(service.agentAttention == nil)
            #expect(removed.reason == nil)

            let toggledOn = try send("xor-on", scheme: "xor")
            #expect(toggledOn.reason == "label cut from 81 to 80 characters")
            let toggledOff = try send("xor-off", scheme: "xor")
            #expect(service.agentAttention == nil)
            #expect(toggledOff.reason == nil)

            let selected = try send("selection", scheme: "replace", target: "selection")
            #expect(selected.target == "selection")
            #expect(selected.reason == nil)
        }
    #endif
}
