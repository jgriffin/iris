#if os(iOS)

/// A camera device discovered on the host.
///
/// `id` is the underlying `AVCaptureDevice.uniqueID` and is the durable
/// identifier used to look the device back up. Pure value type — no
/// AVFoundation import here.
public struct CameraDevice: Sendable, Hashable {

    /// Stable identifier; matches `AVCaptureDevice.uniqueID`.
    public typealias ID = String

    public let id: ID
    public let position: Position
    public let kind: Kind

    public init(id: ID, position: Position, kind: Kind) {
        self.id = id
        self.position = position
        self.kind = kind
    }

    /// Physical placement of the camera on the device.
    public enum Position: Sendable, Hashable {
        case front
        case back
        case external
    }

    /// Optical configuration of the camera.
    public enum Kind: Sendable, Hashable {
        case wide
        case ultraWide
        case telephoto
        case trueDepth
        case external
    }
}

#endif
