import Foundation

public enum CADViewportError: Error, LocalizedError {
    case unsupportedFormat(String)
    case emptyFile
    case loadFailed(String)

    /// `startSelectionSidecar(directory:)` could not take the exclusive `host.lock` in
    /// `directory`, per the agent-viewport selection bridge ADR
    /// (OCCTSwiftInteraction#17/#16): another process already holds it.
    case sidecarHostAlreadyRunning

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext): return "Unsupported file format: .\(ext)"
        case .emptyFile: return "File contains no geometry"
        case .loadFailed(let msg): return "Load failed: \(msg)"
        case .sidecarHostAlreadyRunning:
            return "Another host already holds the selection sidecar's host.lock"
        }
    }
}
