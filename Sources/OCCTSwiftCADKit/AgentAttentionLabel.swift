// AgentAttentionLabel.swift
// OCCTSwiftCADKit
//
// The bound and blank rule `CADViewportService.setAgentAttention(_:label:)` applies to an attention
// label, so a host calling it directly and a `highlight_requests` payload get the same answer
// (OCCTSwiftInteraction#54). Rationale: `docs/reference/CADViewportService.md`.

/// What `CADViewportService.agentAttentionLabel` holds for a label as sent.
enum AgentAttentionLabel {
    /// The most `Character`s a held label has: OCCTMCP's `SelectionBridgeTools.maxLabelLength`,
    /// counted the same way (`String.count`, extended grapheme clusters).
    static let maxLength = 80

    /// The most UTF-8 bytes a held label has, its ellipsis included.
    ///
    /// `maxLength` alone does not bound a label's size, because one `Character` can carry any
    /// number of combining scalars, and OCCTMCP accepts such a label. This does bound it. No label
    /// of ordinary characters within `maxLength` comes near it (80 of the longest emoji ZWJ
    /// sequences are about 2,800 bytes), so it cuts only a label built to be large.
    static let maxUTF8Length = 4096

    /// The last character of a cut label.
    static let ellipsis: Character = "\u{2026}"

    /// `label` as held.
    ///
    /// - nil when it is nil or blank (`isBlank(_:)`).
    /// - Unchanged when it has at most `maxLength` characters and `maxUTF8Length` bytes.
    /// - Otherwise its longest prefix of whole characters that fits both bounds with `ellipsis`
    ///   after it, less trailing characters that are blank or that `ellipsis` would join, plus
    ///   `ellipsis`; or nil when nothing visible is left in front of the cut.
    static func normalized(_ label: String?) -> String? {
        guard let label, !isBlank(label) else { return nil }
        guard exceedsBounds(label) else { return label }
        let budget = maxUTF8Length - String(ellipsis).utf8.count
        var end = label.startIndex
        var characters = 0
        var bytes = 0
        while end != label.endIndex, characters < maxLength - 1 {
            let next = label.index(after: end)
            let size = label.utf8.distance(from: end, to: next)
            guard bytes + size <= budget else { break }
            (end, characters, bytes) = (next, characters + 1, bytes + size)
        }
        var kept = label[..<end]
        // A Prepend character (U+0600 ARABIC NUMBER SIGN) would absorb the ellipsis into itself.
        while let last = kept.last,
            isBlank(String(last)) || (String(last) + String(ellipsis)).count == 1
        {
            kept = kept.dropLast()
        }
        // An ellipsis alone tells a reader nothing and keeps a host from falling back to its own
        // caption, so a cut that leaves nothing visible is no label, as a blank one is.
        guard !kept.isEmpty else { return nil }
        return String(kept) + String(ellipsis)
    }

    /// Whether `label` has more than `maxLength` characters or `maxUTF8Length` bytes.
    static func exceedsBounds(_ label: String) -> Bool {
        if label.utf8.count > maxUTF8Length { return true }
        // Within the byte bound, so this reads at most `maxUTF8Length` bytes.
        guard
            let bound = label.index(
                label.startIndex, offsetBy: maxLength, limitedBy: label.endIndex)
        else { return false }
        return bound != label.endIndex
    }

    /// Whether `label` draws nothing: every scalar is whitespace (`White_Space`), a control
    /// character (general category Cc), a `Default_Ignorable_Code_Point`, or in `namedBlanks`.
    static func isBlank(_ label: String) -> Bool {
        label.unicodeScalars.allSatisfy { scalar in
            let properties = scalar.properties
            return properties.isWhitespace || properties.generalCategory == .control
                || properties.isDefaultIgnorableCodePoint || namedBlanks.contains(scalar)
        }
    }

    /// Characters outside those classes that exist to draw nothing.
    static let namedBlanks: Set<Unicode.Scalar> = [
        "\u{2800}",  // BRAILLE PATTERN BLANK
        "\u{FFF9}", "\u{FFFA}", "\u{FFFB}",  // INTERLINEAR ANNOTATION ANCHOR, SEPARATOR, TERMINATOR
        "\u{FFFC}",  // OBJECT REPLACEMENT CHARACTER
        "\u{16FE4}",  // KHITAN SMALL SCRIPT FILLER
        "\u{1D159}",  // MUSICAL SYMBOL NULL NOTEHEAD
    ]
}
