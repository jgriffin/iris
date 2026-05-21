/// A stable handle for a playback asset, used in `SourceKind.playback(_:)`.
///
/// Kept as a thin wrapper around `String` (rather than a bare typealias) so
/// callers can't accidentally swap it with `CameraDevice.ID` at the type level.
public struct AssetID: Sendable, Hashable {
    public let raw: String

    public init(raw: String) {
        self.raw = raw
    }
}
