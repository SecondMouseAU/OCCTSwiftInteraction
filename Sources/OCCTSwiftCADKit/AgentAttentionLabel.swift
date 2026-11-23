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

    /// The last character of a label cut to `maxLength`.
    static let ellipsis: Character = "\u{2026}"

    /// `label` as held: nil when it is nil or blank (`isBlank(_:)`); when it has more than
    /// `maxLength` characters, its first `maxLength - 1`, less trailing ones that are blank or
    /// that `ellipsis` would join, plus `ellipsis`; else `label` unchanged.
    static func normalized(_ label: String?) -> String? {
        guard let label, !isBlank(label) else { return nil }
        // This check reads at most `maxLength` characters, where `label.count` reads them all.
        guard
            let bound = label.index(
                label.startIndex, offsetBy: maxLength, limitedBy: label.endIndex),
            bound != label.endIndex
        else { return label }
        var kept = label.prefix(maxLength - 1)
        // A Prepend character (U+0600 ARABIC NUMBER SIGN) would absorb the ellipsis into itself.
        while let last = kept.last,
            isBlank(String(last)) || (String(last) + String(ellipsis)).count == 1
        {
            kept = kept.dropLast()
        }
        return String(kept) + String(ellipsis)
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
