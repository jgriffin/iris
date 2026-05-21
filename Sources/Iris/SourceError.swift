import Foundation

/// Session-level failures surfaced via `Source.state` (and thrown from
/// `Source.start()` where the caller can act on them — e.g. prompt-and-retry
/// on permission denial).
public enum SourceError: Error, Sendable, Equatable {
    case permissionDenied(MediaType)
    case noDeviceAvailable
    case assetLoadFailed(URL)
    case configurationFailed(String)
    case interrupted
}
