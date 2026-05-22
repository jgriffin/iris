/// A producer of `Frame`s — camera capture, file playback, or a test mock.
///
/// `Source` is the single ingestion abstraction in Iris: detectors, overlays,
/// and dataset capture all read `Frame`s off `frames` without caring where
/// they came from.
public protocol Source: AnyObject, Sendable {
    /// Frame stream. **Single-consumer.** Buffering policy is
    /// `.bufferingNewest(1)` — late frames are dropped before they enter the
    /// stream rather than queueing up. **Non-throwing** — session-level errors
    /// surface via `state`, not through this stream.
    var frames: AsyncStream<Frame> { get }

    /// Lifecycle / permission / error state. Observable for SwiftUI.
    ///
    /// `async` so actor-backed conformers (`CaptureSession`) can satisfy
    /// the requirement without `@preconcurrency` on the conformance — the
    /// caller crosses the actor boundary at the read site.
    var state: SourceState { get async }

    /// Start producing frames. May request permissions on first call.
    /// Idempotent: a second call on an already-running source is a no-op.
    func start() async throws

    /// Stop producing frames. The `frames` stream remains alive but quiet.
    /// A subsequent `start()` resumes; idempotent on an already-stopped source.
    func stop() async

    /// Finish the `frames` stream and tear down the source. Iteration of
    /// `frames` completes. The `Source` instance should not be reused.
    func invalidate() async
}
