# Runtime-pipeline architecture — locked decisions for M1

**Read date:** 2026-05-20
**Source:** distilled from [`SYNTHESIS.md`](./SYNTHESIS.md). Cites the M0 rollup at [`../RECOMMENDATIONS-PRIOR-ART.md`](../RECOMMENDATIONS-PRIOR-ART.md) and the two prior-art arcs in [`../prior-projects/RECOMMENDATIONS.md`](../prior-projects/RECOMMENDATIONS.md) and [`../swift-ecosystem/RECOMMENDATIONS.md`](../swift-ecosystem/RECOMMENDATIONS.md). Mirror those files' tone — these are *locked decisions* on the source side of Iris (Capture + Playback → `Frame`), to be folded into M1's plan without further debate.

---

## Locked decisions

1. **`Source` protocol vends concrete `AsyncStream<Frame>`, not `some AsyncSequence`.**
   *Rationale:* PFM's `LanguageModelBackend` precedent — concrete `AsyncStream` dodges the existential/opaque-type dance and `for await frame in source.frames { … }` works without ceremony. The "protocol on top, concrete stream return" recipe from M0 lands here.
   *M1 must:* declare `protocol Source: AnyObject, Sendable { var frames: AsyncStream<Frame> { get }; var state: SourceState { get }; func start() async throws; func stop() async; func invalidate() async }` and have both `CaptureSession` and `PlaybackSession` conform.

2. **`bufferingPolicy: .bufferingNewest(1)` is the contract, not an internal optimization.**
   *Rationale:* Three of five in-house projects and two of five external packages shipped without back-pressure and paid for it. TN2445's "buffer queue size of 1" rule maps directly. Frames drop *before* entering Vision, never *during*.
   *M1 must:* every `AsyncStream<Frame>` Iris creates uses `AsyncStream.makeStream(of: Frame.self, bufferingPolicy: .bufferingNewest(1))`. Document the policy on `Source.frames`'s doc-comment.

3. **The `AsyncStream<Frame>` is non-throwing. Errors live on `state`.**
   *Rationale:* A 30/60 Hz stream cannot meaningfully recover from per-frame errors; session-level failures are session-level state. Splitting "data flow" from "lifecycle/error state" matches the M0 verdict and avoids forcing consumers to write `try` in the hot path.
   *M1 must:* `var frames: AsyncStream<Frame>` (not `AsyncThrowingStream`). `SourceState` enum carries `.failed(SourceError)` for session errors. `state` is `@Observable`-friendly.

4. **`CaptureSession` is an `actor` *instance* with a custom `DispatchSerialQueue` serial executor — not a `@globalActor`.**
   *Rationale:* M0 said "yes to `@CaptureActor`"; the Apple AVCam blueprint says "yes, but as an actor instance with `nonisolated unownedExecutor`, not a global actor." Global actors leak through the whole module and pin every nominal type to the capture-pipeline isolation. Instance actor + custom executor gives the same compile-time guarantees with none of the spill.
   *M1 must:* `public actor CaptureSession: Source` with `private let captureQueue = DispatchSerialQueue(label: "iris.capture.session")` and `public nonisolated var unownedExecutor: UnownedSerialExecutor { captureQueue.asUnownedSerialExecutor() }`. **Do not declare `@CaptureActor` as a global actor anywhere.**

5. **The delegate queue IS the actor's executor.**
   *Rationale:* `AVCaptureVideoDataOutput.setSampleBufferDelegate(_, queue:)` accepts a `DispatchQueue`. If that queue is the same one the `CaptureSession` actor uses as its serial executor, the delegate callback runs already-in-isolation. No `Task { @CaptureSession in … }` per frame, no actor hop, no scheduling cost.
   *M1 must:* `videoOutput.setSampleBufferDelegate(router, queue: captureQueue)`. The router is a separate `final class @unchecked Sendable` NSObject (see decision 10).

6. **`PlaybackSession` is an `actor` on the cooperative pool — no custom executor.**
   *Rationale:* `AVAssetReader` has no AVF-style threading requirement; the actor's sole-ownership of the reader provides serialization automatically. Custom executors are reserved for AVF-delegate paths.
   *M1 must:* `public actor PlaybackSession: Source` with no `unownedExecutor` override. A child `Task` owns the read loop.

7. **`Frame` is `struct @unchecked Sendable` with documented invariants — not an actor.**
   *Rationale:* The whole pipeline depends on `Frame` crossing actor boundaries cheaply. A buffer-owning actor would force every Vision call to await. NextLevel's `SendablePixelBuffer` and Kadr's `CancellationToken` are the canonical precedent. The invariants (1) buffer is immutable post-construction, (2) buffer is IOSurface-backed, (3) ARC handles lifetime — together justify `@unchecked Sendable` without a lock.
   *M1 must:* `public struct Frame: @unchecked Sendable { let pixelBuffer: CVPixelBuffer; let timestamp: CMTime; let orientation: CGImagePropertyOrientation; let source: SourceKind; let format: PixelFormat; let dimensions: CGSize }` — *with* a doc-comment naming the invariants on the type.

8. **Default pixel format is `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange` on both capture and playback.**
   *Rationale:* Vision-native, IOSurface-backed, ~12 MB per 4K frame (vs 31 MB for BGRA). Matches PRVisionSpike's `AssetPlayerInfo.swift:23` and is the published recommendation from the Vision-pipeline community. BGRA stays available as opt-in via `PixelFormat.bgra8`.
   *M1 must:* `videoOutput.videoSettings` (capture) and `AVAssetReaderTrackOutput.outputSettings` (playback) both set `kCVPixelBufferPixelFormatTypeKey` to `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange` by default. Playback also sets `kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary` to opt into IOSurface backing.

9. **`Frame.timestamp` is `CMTime`, not `TimeInterval`.**
   *Rationale:* PRVisionSpike's `.visionTimestamp` extraction-at-every-use-site was a symptom of an under-typed `Frame`; making PTS first-class on the struct fixes that. `CMTime` (not `TimeInterval`) preserves rational precision for playback math.
   *M1 must:* `Frame.timestamp: CMTime`. Convenience `var seconds: Double { CMTimeGetSeconds(timestamp) }` is fine; the storage stays rational.

10. **The sample-buffer delegate is a separate `final class @unchecked Sendable`, not the actor itself.**
    *Rationale:* The actor cannot conform to `AVCaptureVideoDataOutputSampleBufferDelegate` (NSObject lineage required by ObjC runtime). NextLevel's split — capture root as queue-backed class, recording session as actor — is the right pattern, with the twist that *here* the router has no mutable state, so `@unchecked Sendable` is justified by queue-isolation alone (no lock needed).
    *M1 must:* `final class SampleBufferRouter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable` holding only the `AsyncStream<Frame>.Continuation` and a `@Sendable () async -> CGFloat` rotation accessor. No mutable storage.

11. **`alwaysDiscardsLateVideoFrames = true` always.**
    *Rationale:* TN2445 is explicit. We are not in the "recording faster than real-time" exception case.
    *M1 must:* Set it during output configuration; do not expose a toggle.

12. **`AVAssetReader` is forward-only; seek recreates the reader.**
    *Rationale:* `supportsRandomAccess` + `reset(forReadingTimeRanges:)` is a multi-pass affordance, not a general scrubber. Cancel + rebuild is cheap on modern decoders (<100ms on iPhone 15-class hardware in iOS 26) and avoids the configuration-frozen-after-startReading pitfall.
    *M1 must:* `PlaybackSession.seek(to:)` cancels the reader task, calls `reader.cancelReading()`, builds a fresh `AVAssetReader` with `timeRange: CMTimeRange(start: time, duration: .positiveInfinity)`, and restarts the read loop if `state == .playing`. No `supportsRandomAccess`.

13. **Playback cadence is pull-driven; the consumer paces.**
    *Rationale:* Display is `AVPlayer`-backed (separate channel); the `Frame` stream is for analysis. Decoupling lets the detector run faster (pre-pass) or slower (heavy model on light hardware) than real-time without forcing pacing logic into the source.
    *M1 must:* `PlaybackSession`'s read loop yields as fast as the consumer reads. No `Task.sleep` for PTS pacing. The `.bufferingNewest(1)` buffer is the back-pressure.

14. **One stream, one consumer. No multi-subscriber broadcast in v0.**
    *Rationale:* NextLevel's single-`Any?` continuation overwrite bug (`swift-ecosystem/RECOMMENDATIONS.md` §"New anti-patterns") is the cautionary tale, but the correct `[UUID: Continuation]` fan-out is M3 work — not M1. M1's `for await frame in source.frames { … }` consumer fans out to detector/overlay/dataset on its own.
    *M1 must:* Single `AsyncStream<Frame>.Continuation` stored on the actor. Document "one consumer" on `Source.frames`. Add `[UUID: Continuation]` to M3 if/when a second listener arrives.

15. **`PreviewSource` is the only nonisolated opening in the capture actor wall.**
    *Rationale:* AVCam pattern; `nonisolated let previewSource: PreviewSource` exposes a `Sendable` source the SwiftUI `CameraPreview` can `connect(to:)` on `@MainActor`. The `AVCaptureSession` itself never leaves the actor.
    *M1 must:* `public nonisolated let previewSource: PreviewSource` on `CaptureSession`. A separate `PreviewTarget` `@MainActor` protocol is the bridge layer. `CameraPreview: UIViewRepresentable` is the public SwiftUI view that consumes them.

16. **Permissions live inside `start()`; surface as `state`, not as a thrown specialised error type leaked through `frames`.**
    *Rationale:* MijickCamera's baked-in permissions pattern is the right consumer ergonomic. The `frames` stream stays clean (non-throwing); `start()` throws on permission denied so the caller can prompt-and-retry; meanwhile `state == .permissionDenied(.video)` is observable for UI.
    *M1 must:* `CaptureSession.start()` calls `AVCaptureDevice.requestAccess(for:)`, sets `state = .permissionDenied(.video)` and throws `SourceError.permissionDenied(.video)` on refusal.

17. **Rotation handled via `AVCaptureDevice.RotationCoordinator`.**
    *Rationale:* AVCam's pattern, replacing the deprecated `AVCaptureVideoOrientation` and the `UIDevice.current.orientation` anti-pattern from yolo-ios-app. Both the preview connection and the data-output connection observe the same angle.
    *M1 must:* `private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?` on `CaptureSession`, set up in `start()`. The `Frame.orientation` field reflects the current observed angle at the moment the buffer is wrapped.

18. **`@preconcurrency import AVFoundation` is allowed in `CaptureSession.swift` and `PlaybackSession.swift` only.**
    *Rationale:* Apple's own AVCam uses it; Kadr does too. Allowing it in *implementation* files keeps `Source.swift`, `Frame.swift`, and other public-API files clean. Banning it everywhere would force absurd workarounds.
    *M1 must:* Use `@preconcurrency import AVFoundation` only in the two AVF-touching files. `Source` / `Frame` / `SourceState` / `CameraDevice` are public-API files and import `AVFoundation` without `@preconcurrency` (they don't touch the non-Sendable AVF surface).

19. **No Combine. No `@Published` bridge.**
    *Rationale:* AVCam mixes Combine + Concurrency because it was retrofitted; Iris is greenfield Swift 6.2. `@Observable` on the conformer (actor's stored state observed via `state` accessor) replaces every `@Published`-and-`.values` re-publishing.
    *M1 must:* Zero `import Combine` in `IrisCapture` / `IrisPlayback`. State changes propagate via `@Observable` annotations on the conforming actor's stored properties.

20. **No per-frame `Task { … }` spawn inside the framework.**
    *Rationale:* NextLevel's `_activeTasks: [Task<Void, Never>]` + `NSLock` chase-the-leaks pattern is the negative example. `yield(frame)` is synchronous; the consumer owns the Task.
    *M1 must:* Code-review rule. Any new `Task { … }` inside `IrisCapture` or `IrisPlayback` needs explicit justification in the PR description.

---

## Type sketches

The final, locked Swift signatures. M1 lands these (or close cousins; field-by-field changes welcome, structural changes need a new block).

### `Frame`

```swift
import CoreMedia
import CoreVideo
import ImageIO   // CGImagePropertyOrientation

/// A single frame from any source. Sendable across actors because the
/// underlying CVPixelBuffer is treated as immutable from the moment it's
/// wrapped here — producers must not mutate the buffer in place after
/// constructing a Frame, and consumers must not mutate it ever. Buffer
/// retention/release is handled by ARC on the CVPixelBuffer reference; the
/// buffer's IOSurface keeps it alive across actor hops with zero copies.
///
/// Invariants justifying @unchecked Sendable:
///   1. `pixelBuffer` is immutable after Frame construction.
///   2. `pixelBuffer` is IOSurface-backed (both producers guarantee this).
///   3. All other fields are value types or enums that are themselves Sendable.
public struct Frame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let timestamp: CMTime
    public let orientation: CGImagePropertyOrientation
    public let source: SourceKind
    public let format: PixelFormat
    public let dimensions: CGSize     // CVPixelBufferGetWidth/Height, cached
}

public enum SourceKind: Sendable, Hashable {
    case camera(CameraDevice.ID)
    case playback(AssetID)
    case mock(String)
}

public enum PixelFormat: Sendable, Hashable {
    case yuv420BiPlanarFull   // kCVPixelFormatType_420YpCbCr8BiPlanarFullRange (default)
    case bgra8                // kCVPixelFormatType_32BGRA (opt-in)
}

public struct AssetID: Sendable, Hashable {
    public let raw: String
}
```

### `Source`

```swift
public protocol Source: AnyObject, Sendable {
    /// Frame stream. Single-consumer. .bufferingNewest(1). Non-throwing —
    /// session errors surface via `state`, not through this stream.
    var frames: AsyncStream<Frame> { get }

    /// Lifecycle / permission / error state. Observable for SwiftUI.
    var state: SourceState { get }

    /// Start producing frames. May request permissions on first call.
    /// Idempotent: a second call on an already-running source is a no-op.
    func start() async throws

    /// Stop producing frames. The `frames` stream remains alive but quiet.
    /// A subsequent start() resumes; idempotent on an already-stopped source.
    func stop() async

    /// Finish the `frames` stream and tear down the source. Iteration of
    /// `frames` completes. The Source instance should not be reused.
    func invalidate() async
}

public enum SourceState: Sendable, Equatable {
    case idle
    case requestingPermission
    case permissionDenied(MediaType)
    case running
    case paused
    case failed(SourceError)
    case stopped
}

public enum MediaType: Sendable, Equatable { case video, audio }

public enum SourceError: Error, Sendable, Equatable {
    case permissionDenied(MediaType)
    case noDeviceAvailable
    case assetLoadFailed(URL)
    case configurationFailed(String)
    case interrupted
}
```

### `CaptureSession`

```swift
@preconcurrency import AVFoundation

public actor CaptureSession: Source {

    // ── Executor ────────────────────────────────────────────────────────────
    private let captureQueue = DispatchSerialQueue(label: "iris.capture.session")
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        captureQueue.asUnownedSerialExecutor()
    }

    // ── Public surface ──────────────────────────────────────────────────────
    public nonisolated let previewSource: PreviewSource
    public let frames: AsyncStream<Frame>
    public private(set) var state: SourceState = .idle

    // ── Init ────────────────────────────────────────────────────────────────
    public init() async {
        let (stream, cont) = AsyncStream<Frame>.makeStream(
            of: Frame.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.frames = stream
        self.continuation = cont
        self.previewSource = AVCapturePreviewSource()
    }

    // ── Source protocol ─────────────────────────────────────────────────────
    public func start() async throws { … }
    public func stop() async { … }
    public func invalidate() async { … }

    // ── Device + format ─────────────────────────────────────────────────────
    public static func discoverDevices() async -> [CameraDevice]
    public func select(device: CameraDevice) async throws
    public func setPreferredFormat(_ format: CaptureFormat) async throws

    // ── Private storage ─────────────────────────────────────────────────────
    private let session = AVCaptureSession()
    private var input: AVCaptureDeviceInput?
    private let videoOutput = AVCaptureVideoDataOutput()
    private var router: SampleBufferRouter?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var continuation: AsyncStream<Frame>.Continuation
}

public struct CameraDevice: Sendable, Hashable {
    public typealias ID = String   // AVCaptureDevice.UniqueID is a String
    public let id: ID
    public let position: Position
    public let kind: Kind

    public enum Position: Sendable { case front, back, external }
    public enum Kind: Sendable { case wide, ultraWide, telephoto, trueDepth, external }
}

public struct CaptureFormat: Sendable, Hashable {
    public let dimensions: CMVideoDimensions
    public let minFrameRate: Double
    public let maxFrameRate: Double
    public let pixelFormat: PixelFormat
}

public protocol PreviewSource: Sendable {
    func connect(to target: PreviewTarget)
}

@MainActor public protocol PreviewTarget {
    func setSession(_ session: AVCaptureSession)
}
```

### `PlaybackSession`

```swift
@preconcurrency import AVFoundation

public actor PlaybackSession: Source {

    public let frames: AsyncStream<Frame>
    public private(set) var state: SourceState = .idle
    public var duration: CMTime { get async }

    public init(url: URL) async throws

    public func start() async throws          // play()
    public func stop() async                  // pause()
    public func invalidate() async

    public func seek(to time: CMTime) async throws
    @discardableResult
    public func step(by frames: Int) async throws -> Frame?

    // ── Private storage ─────────────────────────────────────────────────────
    private let asset: AVAsset
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var readerTask: Task<Void, Never>?
    private var continuation: AsyncStream<Frame>.Continuation
}
```

### `SampleBufferRouter`

```swift
@preconcurrency import AVFoundation

/// AVF sample-buffer delegate. Bridges captureOutput(_:didOutput:from:)
/// into the AsyncStream<Frame> continuation.
///
/// Invariant justifying @unchecked Sendable: every method on this class
/// only ever runs on the CaptureSession actor's executor (we set the
/// delegate queue to that executor's queue). The class has no mutable
/// stored state after init.
final class SampleBufferRouter:
    NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    @unchecked Sendable {

    private let continuation: AsyncStream<Frame>.Continuation
    private let rotationProvider: @Sendable () async -> CGFloat
    private let cameraID: CameraDevice.ID

    init(continuation: AsyncStream<Frame>.Continuation,
         cameraID: CameraDevice.ID,
         rotation: @escaping @Sendable () async -> CGFloat) { … }

    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) { … }

    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didDrop sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) { … }
}
```

### `@CaptureActor` — **deliberately absent**

There is no `@globalActor public actor CaptureActor`. Decision 4 above: the working blueprint is an actor *instance* with a custom executor, not a global actor that pins the whole module. The M0 working language "build `@CaptureActor`" resolves here to "build `actor CaptureSession`."

---

## M1 scope additions

Concrete bullets to fold into M1's plan, beyond what's already in `BRIEF.md`:

1. **Ship `Source` protocol + `Frame` type + `CaptureSession` actor + `SampleBufferRouter` + `PreviewSource`/`PreviewTarget` together as the M1 deliverable.** None of these are useful alone; they're load-bearing on each other.
2. **`AVCaptureDevice.RotationCoordinator` wired into `CaptureSession`** from day one. Don't ship a rotation-less M1; the retrofit later is more work than getting it right now.
3. **Interruption recovery** (`wasInterrupted` / `interruptionEnded` with ~100ms `AVAudioSession` settle delay) in `CaptureSession`. Per NextLevel scar #281.
4. **`PixelFormat.yuv420BiPlanarFull` default** wired into both `AVCaptureVideoDataOutput.videoSettings` and `AVAssetReaderTrackOutput.outputSettings`. `BGRA8` available but not default.
5. **`alwaysDiscardsLateVideoFrames = true`** hardcoded; not a configurable knob.
6. **IOSurface property requested explicitly for playback** (`kCVPixelBufferIOSurfacePropertiesKey: [:]`). Capture inherits IOSurface from AVF's internal pool.
7. **`didDrop` callback wired to `os.Logger`**, not to the `Frame` stream. `kCMSampleBufferAttachmentKey_DroppedFrameReason` extraction for diagnostics.
8. **`MockSource` conformer** for SwiftUI previews and tests — yields a fixed sequence of bundled test `Frame`s without any AVF. Lives in `IrisCapture` (or a sub-target) so `IrisOverlay` / `IrisDetection` previews don't need a camera.
9. **`#Preview` for `CameraPreview` using a `MockSource`** in M1, even if it just shows a static gradient `Frame` — establishes the visual-preview discipline early.
10. **One end-to-end smoke test per source**: `CaptureSession` (iOS only — gated test), `PlaybackSession` (iOS + macOS) reading from a bundled `.mov` fixture, asserting the first `Frame` arrives within N seconds with the expected `format`/`dimensions`. No mocks for these; real fixtures per CLAUDE.md.
11. **Doc-comment the `@unchecked Sendable` invariant on `Frame` and `SampleBufferRouter`.** Code review enforces this.

---

## Anti-patterns M1 must avoid

Pulled forward from `prior-projects/RECOMMENDATIONS.md` and `swift-ecosystem/RECOMMENDATIONS.md`, sharpened to the source side:

- **`@unchecked Sendable` *without* a documented invariant.** Allowed only on `Frame` and `SampleBufferRouter`, each with an invariant doc-comment. Anywhere else is a code-review block.
- **Spawning a `Task { … }` per frame inside `IrisCapture` or `IrisPlayback`.** NextLevel's `_activeTasks` + `NSLock` is the cost. `yield(frame)` is synchronous from inside the actor's executor.
- **Storing the `AsyncStream<Frame>.Continuation` in an `Any?` field.** NextLevel's `_sessionEventContinuation: Any?` silently overwrites the second subscriber. We store it typed (`AsyncStream<Frame>.Continuation`) on the actor; one continuation, one consumer.
- **Publishing `CVPixelBuffer` across actor boundaries without `Frame`.** The `Frame` envelope is mandatory. No `AsyncStream<CVPixelBuffer>` shortcuts (sportvision's `frameStream: AsyncStream<CVPixelBuffer>` is the cautionary tale).
- **Treating `AVCaptureSession.startRunning()` as synchronous on an arbitrary thread.** It must be called on the actor's serial queue (which is a background queue), not on the cooperative pool, not on `MainActor`.
- **Setting a delegate queue that isn't the actor's executor.** Defeats the whole point — re-introduces an actor hop per frame and forces a `@Sendable` closure dance to yield the continuation.
- **`AVCaptureVideoOrientation` anywhere in source code.** Deprecated; use `RotationCoordinator`. Banned in code review.
- **`UIDevice.current.orientation` anywhere.** Same ban; works only on iOS, kills macOS parity. (Cross-cutting principle from `RECOMMENDATIONS-PRIOR-ART.md`.)
- **Combine in the source side.** Zero `import Combine` in `IrisCapture` or `IrisPlayback`. `@Observable` replaces every use.
- **Throwing `frames` (i.e. `AsyncThrowingStream`).** Errors live on `state`.
- **Reconfiguring the `AVCaptureSession` outside a `beginConfiguration`/`commitConfiguration` block.** Use a `reconfigure { … }` helper; raw mutations are a code-review block.
- **`AVPlayerItemVideoOutput`-based playback path.** PRVisionSpike has it; it's a display-link-coupled second mode that we explicitly do not ship. `AVAssetReader` is the only playback path in `PlaybackSession`. (M3+ may add an `AVPlayer`-attached preview *view*, but the frame-extraction channel stays asset-reader-driven.)

---

## Open items deferred

Not locked here; need follow-on decisions before they become relevant:

- **Multi-subscriber broadcast** (`[UUID: Continuation]` fan-out). Deferred to M3 when a second listener (dataset capture button) joins detector + overlay on the same stream.
- **`PreviewSource` ownership across the package boundary.** If `iris-capture` becomes a separate package (per the open package-layout block), `PreviewSource`/`PreviewTarget` need to live in the core, not in `iris-capture` — same way Kadr's `Caption` lives in core, not in `kadr-captions`. Settle in the package-layout block.
- **Rotation snapshot vs. per-frame query.** The router calls `await rotationProvider()` per frame to read the current angle from the actor. Profiling may show this is enough overhead to warrant snapshotting on `RotationCoordinator` change events into the router directly. Decide if profiling flags it.
- **Audio capture.** Out of scope. When added (M5+ for full video recording), it gets its own `AsyncStream<AudioFrame>` as a sibling on `CaptureSession`; `Source` protocol stays video.
- **`Frame.dimensions` field.** Cached because `CVPixelBufferGetWidth/Height` are two CF calls per access. Profile in M2 to confirm the cache earns its 16 bytes.
- **Consumer-cancellation semantics on `Source`.** If a consumer's `Task` is cancelled mid-`for await`, the stream terminates locally — but does the underlying `Source` keep producing (a future re-iterate yields)? Or is consumer-cancel equivalent to `invalidate()`? Lean: source stays alive; re-iteration spawns a fresh stream. Doc-note this in M1.

---

*This file is scoped to runtime-pipeline architecture decisions for the source side of Iris. Detector internals, overlay, dataset, and sidecar choices have their own decision surfaces — see `BRIEF.md` and the other exploration recommendations.*
