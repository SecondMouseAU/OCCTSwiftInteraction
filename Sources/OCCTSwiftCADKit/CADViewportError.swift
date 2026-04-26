import Foundation

public enum CADViewportError: Error, LocalizedError {
    case unsupportedFormat(String)
    case emptyFile
    case loadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext): return "Unsupported file format: .\(ext)"
        case .emptyFile: return "File contains no geometry"
        case .loadFailed(let msg): return "Load failed: \(msg)"
        }
    }
}
