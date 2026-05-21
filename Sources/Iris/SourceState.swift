/// Observable lifecycle / permission / error state for a `Source`.
///
/// The frame stream is non-throwing; this enum is where session-level
/// errors surface for UI to react to.
public enum SourceState: Sendable, Equatable {
    case idle
    case requestingPermission
    case permissionDenied(MediaType)
    case running
    case paused
    case failed(SourceError)
    case stopped
}
