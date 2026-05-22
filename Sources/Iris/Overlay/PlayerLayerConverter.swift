@preconcurrency import AVFoundation
import CoreGraphics

/// `NormalizedGeometryConverting` backend for the playback display path.
///
/// Holds a weak reference to an `AVPlayerLayer`; on each call, reads
/// `playerLayer.videoRect` (the on-screen rect the video occupies after
/// `videoGravity = .resizeAspect` letterbox/pillarbox) and applies
/// aspect-fit math against the caller-supplied `videoRect` argument. The
/// Y-flip lives here: `1 - y - h` on the rect path, `1 - y` on the point
/// path.
///
/// **Why explicit math, not AVF delegation?** Unlike
/// `AVCaptureVideoPreviewLayer`, `AVPlayerLayer` does not vend a
/// "convert metadata rect to layer rect" helper. The aspect-fit
/// transformation must be derived from `videoRect` directly.
///
/// **`videoRect` semantics.** The `in videoRect:` argument is authoritative
/// — callers pass `playerLayer.videoRect` (M3 wires this through
/// `PlaybackSession.videoRect: AsyncStream<CGRect>`). The held
/// `AVPlayerLayer` is retained for symmetry with `PreviewLayerConverter`
/// and for future use (e.g. mirroring or rotation reads) but not consulted
/// inside the pure-math conversion path. This keeps the converter
/// trivially unit-testable via the static `convert(...)` helper.
///
/// **`@unchecked Sendable` invariant.** The `AVPlayerLayer` reference is
/// captured once at `init` and never mutated through this struct. The
/// pure-math instance methods do not read mutable state on the layer; the
/// layer is held only so the converter composes with future
/// layer-querying enhancements without an API break. CALayer's internal
/// threading is AVF-managed; this wrapper only holds the reference.
public struct PlayerLayerConverter: NormalizedGeometryConverting, @unchecked Sendable {

    private weak var playerLayer: AVPlayerLayer?

    /// Construct a converter bound to a specific `AVPlayerLayer`. Pass
    /// `nil` (the default) for unit tests that exercise the pure-math
    /// path via the static helper without an AVF layer.
    public init(playerLayer: AVPlayerLayer? = nil) {
        self.playerLayer = playerLayer
    }

    public func viewRect(forNormalized rect: CGRect, in videoRect: CGRect) -> CGRect {
        Self.convert(normalizedRect: rect, videoRect: videoRect)
    }

    public func viewPoint(forNormalized point: CGPoint, in videoRect: CGRect) -> CGPoint {
        Self.convert(normalizedPoint: point, videoRect: videoRect)
    }

    // MARK: - Pure-math helpers

    /// Aspect-fit conversion: Vision-normalized rect → view-space rect.
    ///
    /// `videoRect` is the on-screen rect the video pixels occupy after
    /// letterbox/pillarbox; the output rect is offset by `videoRect.origin`
    /// so it sits inside the video area regardless of where in the host
    /// view the video happens to be positioned.
    ///
    /// The Y-flip (`1 - y - h`) converts Vision's bottom-left origin to the
    /// view's top-left origin. The width and height scale linearly with
    /// `videoRect`'s dimensions — no Y-flip is needed on the dimensions
    /// themselves, only on the origin.
    ///
    /// Internal so tests can call it without constructing an
    /// `AVPlayerLayer`. Pure value-type math; no AVF dependency.
    static func convert(normalizedRect rect: CGRect, videoRect: CGRect) -> CGRect {
        CGRect(
            x: videoRect.origin.x + rect.origin.x * videoRect.width,
            y: videoRect.origin.y + (1 - rect.origin.y - rect.height) * videoRect.height,
            width: rect.width * videoRect.width,
            height: rect.height * videoRect.height
        )
    }

    /// Aspect-fit conversion: Vision-normalized point → view-space point.
    /// Same Y-flip rationale as `convert(normalizedRect:videoRect:)`; on
    /// the point path the flip is `1 - y` (no height term).
    static func convert(normalizedPoint point: CGPoint, videoRect: CGRect) -> CGPoint {
        CGPoint(
            x: videoRect.origin.x + point.x * videoRect.width,
            y: videoRect.origin.y + (1 - point.y) * videoRect.height
        )
    }
}
