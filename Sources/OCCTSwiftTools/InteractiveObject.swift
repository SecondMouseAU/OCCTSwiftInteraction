// InteractiveObject.swift
// OCCTSwiftTools
//
// Split out of the file that became SubShape.swift when both moved down from the OCCTSwiftAIS
// target (OCCTSwiftInteraction#2). `SubShape` names a sub-shape *of* one of these, so the two
// have to live in the same target.

import Foundation
import OCCTSwift

/// Erased reference to something currently displayed in an `OCCTSwiftAIS.InteractiveContext`.
///
/// Equality and hashing are by `id` only. Two `InteractiveObject`s with the same
/// id refer to the same logical scene entry even if their `Shape` was rebuilt.
public struct InteractiveObject: Hashable, Sendable {
    public let id: UUID
    public let shape: Shape

    public init(id: UUID = UUID(), shape: Shape) {
        self.id = id
        self.shape = shape
    }

    public static func == (lhs: InteractiveObject, rhs: InteractiveObject) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
