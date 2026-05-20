# Runtime-pipeline architecture — synthesis

**Read date:** 2026-05-20
**Scope:** source side of Iris — `AVCaptureSession` (iOS), `AVAssetReader` (iOS+macOS), the `Frame` boundary, the delegate→`AsyncStream` bridge, the `@CaptureActor`/`Source` isolation model. Detector internals, overlay, dataset sinks, and sidecar formats are explicitly out.

**Inputs:** the M0 verdicts in [`../prior-projects/SYNTHESIS.md`](../prior-projects/SYNTHESIS.md), [`../prior-projects/RECOMMENDATIONS.md`](../prior-projects/RECOMMENDATIONS.md), [`../swift-ecosystem/RECOMMENDATIONS.md`](../swift-ecosystem/RECOMMENDATIONS.md), [`../RECOMMENDATIONS-PRIOR-ART.md`](../RECOMMENDATIONS-PRIOR-ART.md). Targeted Apple-docs lookups for `AVCaptureVideoDataOutput` / `alwaysDiscardsLateVideoFrames` / TN2445, `AVAssetReader` semantics, `AVCaptureDevice.RotationCoordinator`, and Swift Forums' Dec-2025 consensus on actor + `DispatchSerialQueue` for capture.

---

## 1. Context

M0 closed five of six BRIEF open questions (Q1/Q2/Q4/Q5/Q6 + the new `Source`/`DetectorCache`/cancellation rolls). What it did **not** close was the source-side concrete shape: how a frame physically gets out of `AVCaptureSession` and `AVAssetReader`, through what isolation domains, into what boundary type, with what back-pressure and pixel-format guarantees. This document locks that shape so M1 can plan against a single picture instead of relitigating it.

What this **resolves**:
- The exact `AsyncSequence` protocol shape on top of the concrete `AsyncStream<Frame>` (Q1, full lock).
- The `@CaptureActor` decision: actor *instance* + custom serial executor, **no global actor** (Q2, full lock; diverges from M0's working-language "global actor").
- The `Frame` value type — fields, ownership, sendability strategy, pixel format default.
- The delegate→stream bridge: who holds the continuation, where it terminates, how `CMSampleBuffer`/`CVPixelBuffer` crosses the isolation boundary.
- `AVAssetReader` cadence: pull-driven, recreate-on-seek, identical public surface on iOS and macOS (Q5 for playback only).

What this does **not** resolve: detector hot-swap mechanics (Q4 — closed), overlay coordinate math (Q5 — closed), sidecar format (Q3 — orthogonal), package layout (separate open block), Foundation Models scope (Q6 — closed).

---

## 2. The data path, end to end

```
                            ─── iOS only ───
                                    │
   ┌────────────────────────────────▼────────────────────────────────┐
   │                       AVCaptureSession                          │
   │   AVCaptureDeviceInput   ───►   AVCaptureVideoDataOutput        │
   │                                       │                         │
   │   alwaysDiscardsLateVideoFrames=true  │   delegate fires on…    │
   └───────────────────────────────────────┼─────────────────────────┘
                                           │
            CMSampleBuffer + CMTime PTS   ▼
   ┌─────────────────────────────────────────────────────────────────┐
   │   captureQueue: DispatchSerialQueue   (the actor's executor)    │
   │   ── this queue IS the CaptureSession actor's serial executor ──│
   │                                                                 │
   │   class SampleBufferRouter : NSObject,                          │
   │           AVCaptureVideoDataOutputSampleBufferDelegate {        │
   │     unowned let continuation: AsyncStream<Frame>.Continuation   │
   │     func captureOutput(_:didOutput:from:) { … yield(frame) }    │
   │   }                                                             │
   │                                                                 │
   │   The router is the only AVF-touching NSObject in the design.   │
   │   It runs ON the captureQueue (set as its delegate queue),      │
   │   which == the actor's executor — so yield(...) is in-isolation.│
   └─────────────────────────────────┬───────────────────────────────┘
                                     │
                  AsyncStream<Frame> │ bufferingPolicy: .bufferingNewest(1)
                                     │
                                     ▼
                  ─── shared with playback below ───

                            ─── iOS + macOS ───
                                    │
   ┌────────────────────────────────▼────────────────────────────────┐
   │                       AVAssetReader                             │
   │   AVAssetReaderTrackOutput  (forward-only, pull-driven)         │
   │                                       │                         │
   │   pixel format = 420YpCbCr8BiPlanarFullRange (Vision-native)    │
   └───────────────────────────────────────┼─────────────────────────┘
                                           │
            CMSampleBuffer + CMTime PTS   ▼
   ┌─────────────────────────────────────────────────────────────────┐
   │   readerTask: Task on the PlaybackSession actor                 │
   │     while let buf = output.copyNextSampleBuffer() {             │
   │       continuation.yield( Frame(buf, source: .playback, …) )    │
   │     }                                                           │
   │                                                                 │
   │   Seek = cancel readerTask, build a fresh AVAssetReader at the  │
   │           new time range, restart yields. No backward reading.  │
   └─────────────────────────────────┬───────────────────────────────┘
                                     │
                  AsyncStream<Frame> │ bufferingPolicy: .bufferingNewest(1)
                                     ▼

      ─────────────── consumer side (out of scope, sketched) ──────────────
                                     │
        for await frame in source.frames {                  ← consumer's Task
            // hop to detector actor:  await detector.detect(frame)
            // hop to overlay @MainActor: bind result for redraw
            // hop to dataset actor:    if flagged, await sink.save(frame, …)
        }
```

**Isolation domains in this diagram:**

- The **`CaptureSession` actor** runs on `captureQueue` (a `DispatchSerialQueue` set as both the actor's `unownedExecutor` AND the video-data-output's delegate queue — they are literally the same queue).
- The **`PlaybackSession` actor** runs on the cooperative pool; its `readerTask` is a child task that owns the `AVAssetReader` end-to-end. (Asset reading is not delegate-driven, so no custom executor is needed.)
- The **consumer's `Task`** lives wherever the consumer puts it — typically a child of a SwiftUI `.task { }` modifier, inheriting `@MainActor` isolation but freely awaiting into the detector actor.
- The downstream detector / overlay / dataset isolation is **not** our concern; we only guarantee that `Frame` is sendable so they may pick.

---

## 3. `AVCaptureSession` setup

The blueprint is Apple AVCam's `CaptureService` (`apple-avcam.md`), tightened with NextLevel's interruption fix (`nextlevel.md` carry-forward #3), tightened again with the `RotationCoordinator` adoption flagged in `swift-ecosystem/RECOMMENDATIONS.md` §"New additions to M1 scope" #3.

```swift
import AVFoundation
@preconcurrency import AVFoundation   // Apple's own AVCam does this; legitimate.

public actor CaptureSession: Source {

    // ── Executor ────────────────────────────────────────────────────────────
    // The session's serial queue IS the actor's executor AND the
    // sample-buffer delegate's queue. One queue, three jobs.
    private let captureQueue = DispatchSerialQueue(label: "iris.capture.session")
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        captureQueue.asUnownedSerialExecutor()
    }

    // ── AVF state (actor-isolated) ──────────────────────────────────────────
    private let session = AVCaptureSession()
    private var input: AVCaptureDeviceInput?
    private let videoOutput = AVCaptureVideoDataOutput()
    private var router: SampleBufferRouter?   // declared in §4
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?

    // ── Public, Sendable openings in the actor wall ─────────────────────────
    public nonisolated let previewSource: PreviewSource          // AVCam pattern
    public let frames: AsyncStream<Frame>                        // see §4
    public private(set) var state: SessionState = .idle          // @Observable lift

    // ── Lifecycle ───────────────────────────────────────────────────────────
    public init() async { … }                                    // wires PreviewSource
    public func start() async throws                             // permissions + startRunning
    public func stop() async                                     // pause; consumer Task may keep AsyncStream
    public func invalidate() async                               // full teardown; finishes the AsyncStream

    // ── Device + format selection ───────────────────────────────────────────
    public func select(device: CameraDevice) async throws
    public func setPreferredFormat(_ format: CaptureFormat) async throws
}
```

Concrete shapes for the moving parts:

### Device discovery

```swift
public struct CameraDevice: Sendable, Hashable {
    public let id: AVCaptureDevice.UniqueID   // String typealias; Sendable
    public let position: Position             // Iris enum: .front / .back / .external
    public let deviceType: DeviceKind         // .wide / .ultrawide / .tele / .trueDepth …
}

extension CaptureSession {
    public static func discoverDevices() async -> [CameraDevice]
}
```

Internally backed by `AVCaptureDevice.DiscoverySession(deviceTypes:mediaType:position:)`. Never exposes `AVCaptureDevice` to callers — Iris owns the value type, AVF is behind the seam (cross-cutting principle, `RECOMMENDATIONS-PRIOR-ART.md` §"Cross-cutting principles").

### Format / pixel-format choice

```swift
public struct CaptureFormat: Sendable, Hashable {
    public let dimensions: CMVideoDimensions
    public let minFrameRate: Double
    public let maxFrameRate: Double
    public let pixelFormat: PixelFormat   // see §6
}
```

Default pixel-format setting on `AVCaptureVideoDataOutput.videoSettings`:

```swift
videoOutput.videoSettings = [
    kCVPixelBufferPixelFormatTypeKey as String:
        Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
]
```

This is the format Vision consumes most efficiently (matches PRVisionSpike's `AssetPlayerInfo.swift:23` choice and react-native-vision-camera's published guidance: YUV is ~12 MB per 4K frame vs ~31 MB for BGRA, *and* Vision avoids an internal conversion when fed YUV directly). BGRA32 stays available as `PixelFormat.bgra8` for callers who explicitly opt in (e.g. for Metal compositing).

### Configuration commit

```swift
private func reconfigure(_ block: () throws -> Void) rethrows {
    session.beginConfiguration()
    defer { session.commitConfiguration() }
    try block()
}
```

Every input/output/format mutation funnels through this. Because we're inside an actor with a serial executor, two `reconfigure` calls cannot interleave — which is the exact invariant `dispatchPrecondition(.onQueue(sessionQueue))` enforced manually in ios-videoCapture (`+inputsAndOutputs.swift:14`).

### Delegate registration

```swift
private func wireVideoOutput(into continuation: AsyncStream<Frame>.Continuation) {
    videoOutput.alwaysDiscardsLateVideoFrames = true     // TN2445: ALWAYS true for our use case
    videoOutput.automaticallyConfiguresOutputBufferDimensions = true
    let router = SampleBufferRouter(continuation: continuation,
                                    rotation: { [weak self] in
                                        await self?.currentRotationAngle ?? 0
                                    })
    self.router = router
    videoOutput.setSampleBufferDelegate(router, queue: captureQueue)  // ← same queue
}
```

Crucial: the delegate queue **is** the actor's executor. This is what makes the `yield(frame)` call inside the delegate already-in-isolation — no actor hop, no `Task { @CaptureSession in … }` round-trip per frame. See §4 for why.

### Start

```swift
public func start() async throws {
    try await ensurePermission(for: .video)
    guard !session.isRunning else { return }
    session.startRunning()         // blocking, but we're already on captureQueue
    state = .running
}
```

`startRunning()` is documented as blocking; calling it on the actor's serial queue (rather than the cooperative pool) honors AVFoundation's threading expectations without a manual `Task.detached { … }` shuffle.

### Interruption recovery

Per NextLevel's #281 scar:

```swift
@objc private func handleInterruption(_ note: Notification) { /* set state, pause */ }
@objc private func handleInterruptionEnded(_ note: Notification) {
    // settle delay; AVAudioSession needs ~100ms even when we're video-only
    Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(100))
        await self?.resume()
    }
}
```

---

## 4. Delegate → `AsyncStream` bridge

This is the load-bearing detail of the whole design. Five things have to be true at once:

1. The delegate is an `NSObject` subclass (AVFoundation requirement).
2. It runs on the capture queue.
3. The capture queue is also the `CaptureSession` actor's serial executor.
4. The `AsyncStream<Frame>.Continuation` must be `Sendable` (it is — Swift stdlib guarantees that).
5. The `CMSampleBuffer` extraction must produce a `Frame` that is **`Sendable`** (it isn't naturally — see §6).

### The router class

```swift
final class SampleBufferRouter: NSObject,
                                AVCaptureVideoDataOutputSampleBufferDelegate,
                                @unchecked Sendable {

    // Continuation is Sendable; we capture it once at construction.
    private let continuation: AsyncStream<Frame>.Continuation
    private let rotationAngleProvider: @Sendable () async -> CGFloat

    init(continuation: AsyncStream<Frame>.Continuation,
         rotation: @escaping @Sendable () async -> CGFloat) {
        self.continuation = continuation
        self.rotationAngleProvider = rotation
        super.init()
    }

    // INVARIANT: this method only ever runs on the CaptureSession actor's
    // executor (we set the delegate queue to that executor's queue). The
    // @unchecked Sendable above is load-bearing on this single invariant.
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let frame = Frame(pixelBuffer: pixelBuffer,
                          timestamp: pts,
                          orientation: .up,                // RotationCoordinator delta applied downstream
                          source: .camera(.init()),
                          format: .yuv420BiPlanarFull)
        switch continuation.yield(frame) {
        case .enqueued, .dropped:
            break       // .dropped is *expected* with bufferingNewest(1); not a failure
        case .terminated:
            // Consumer cancelled; we'll be removed as delegate shortly.
            break
        @unknown default:
            break
        }
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didDrop sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        // TN2445: kCMSampleBufferAttachmentKey_DroppedFrameReason can surface here
        // for logging. Do NOT propagate as a Frame; downstream sees an unbroken stream.
    }
}
```

The `@unchecked Sendable` on `SampleBufferRouter` is the **canonical** Kadr-style invariant pattern (`swift-ecosystem/RECOMMENDATIONS.md` §"`@unchecked Sendable + NSLock + documented invariant`"). Here there's no lock because the invariant is queue-isolation, not field-protection: the class has no mutable state after `init`. The doc-comment names the invariant explicitly.

### Continuation lifetime

```swift
extension CaptureSession {
    private func makeFrameStream() -> AsyncStream<Frame> {
        let (stream, cont) = AsyncStream<Frame>.makeStream(
            of: Frame.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.continuation = cont          // stored on the actor
        return stream
    }
}
```

The continuation is stored as `private var continuation: AsyncStream<Frame>.Continuation?` on the actor. Three termination paths:

| Trigger                                  | Action                              |
| ---------------------------------------- | ----------------------------------- |
| `invalidate()` called by app             | `continuation?.finish()`            |
| Consumer's `Task` cancelled              | Next `yield` returns `.terminated`; we observe and call `videoOutput.setSampleBufferDelegate(nil, queue: nil)` |
| Session error (`AVCaptureSession` failure notification) | `continuation?.finish()` |

No error path on the stream itself — the `AsyncStream<Frame>` (not `AsyncThrowingStream`) is intentional. Session errors are surfaced through `state: SessionState` (an `@Observable`-readable enum with `.failed(Error)`), **not** by throwing through the frame loop. Rationale: the M0 verdict ([`prior-projects/RECOMMENDATIONS.md`](../prior-projects/RECOMMENDATIONS.md) §"Async + concurrency") favors splitting "data flow" (stream) from "lifecycle/error state" (observable). Throwing a stream forces the consumer to handle errors per-frame, which is wrong for a 30/60 Hz feed where a single error means the whole pipeline is down.

### Multi-subscriber

We deliberately do **not** ship a multi-subscriber broadcast in v0. NextLevel's `_sessionEventContinuation: Any?` is the canonical anti-pattern (`swift-ecosystem/RECOMMENDATIONS.md` §"New anti-patterns"); the right answer is a `[UUID: Continuation]` fan-out, which is a known follow-on but not needed before M2 (where one consumer = one detector + one overlay + an optional dataset listener, all reading from the same `for await`).

The contract: **one `AsyncStream<Frame>`, one consumer.** The consumer fans out to detector/overlay/dataset on its own. M0's "two-actor split" (`prior-projects/SYNTHESIS.md` §Q2) lives downstream of the stream, not upstream.

---

## 5. `AVAssetReader`-backed playback

Playback is structurally simpler than capture: no delegates, no AVF threading hazards, pure pull-driven async loop.

```swift
public actor PlaybackSession: Source {

    // No custom executor: asset reading doesn't have AVF's threading constraints.
    // We're on the cooperative pool. The serial work is naturally serialized
    // by the actor being the sole owner of the AVAssetReader instance.

    private var asset: AVAsset
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var readerTask: Task<Void, Never>?
    private var continuation: AsyncStream<Frame>.Continuation?

    public let frames: AsyncStream<Frame>
    public private(set) var state: PlaybackState = .stopped
    public var duration: CMTime { /* await asset.load(.duration) */ }

    public init(url: URL) async throws { … }

    public func play() async                            // start readerTask
    public func pause() async                           // cancel readerTask, keep reader alive? No — see below
    public func seek(to time: CMTime) async             // recreate reader; restart yields
    public func step(by frames: Int) async              // forward-only frame-step
    public func stop() async                            // finish continuation
}
```

### Setup + pixel-format match

```swift
private func makeReader(timeRange: CMTimeRange) async throws {
    let videoTrack = try await asset.loadTracks(withMediaType: .video).first!
    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = timeRange
    let output = AVAssetReaderTrackOutput(
        track: videoTrack,
        outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String:
                Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary
        ]
    )
    output.alwaysCopiesSampleData = false   // zero-copy; we don't mutate
    reader.add(output)
    reader.startReading()
    self.reader = reader
    self.output = output
}
```

The pixel-format key is **identical** to capture's choice — this is what makes `Frame` source-agnostic downstream. The `kCVPixelBufferIOSurfacePropertiesKey` request asks Core Video to back the buffer with an IOSurface so Vision and Metal both get zero-copy access.

### Pull-driven cadence

```swift
private func startReaderLoop() {
    readerTask = Task { [weak self] in
        while !Task.isCancelled, let buf = await self?.copyNext() {
            await self?.yield(buf)
            // No real-time pacing here. The downstream consumer's
            // `for await` is the pacing mechanism; if it lags, our
            // .bufferingNewest(1) policy drops the older frame.
        }
        await self?.finish()
    }
}

private func copyNext() -> CMSampleBuffer? { output?.copyNextSampleBuffer() }

private func yield(_ buf: CMSampleBuffer) {
    guard let img = CMSampleBufferGetImageBuffer(buf) else { return }
    let pts = CMSampleBufferGetPresentationTimeStamp(buf)
    let frame = Frame(pixelBuffer: img,
                      timestamp: pts,
                      orientation: .up,
                      source: .playback(asset.id),
                      format: .yuv420BiPlanarFull)
    continuation?.yield(frame)
}
```

**Cadence model:** *pull-driven, no real-time pacing*. Playback yields frames as fast as the consumer reads them. The consumer (typically a detector loop) sets the pace; the `.bufferingNewest(1)` buffer drops anything the consumer can't keep up with.

This is a deliberate choice. The alternative — pace yields to real-time using PTS deltas + `Task.sleep` — only makes sense if the playback is *also* driving display. In Iris the display is driven by `AVPlayerLayer` (still TBD for the macOS playback view, but it'll be `AVPlayer`-backed there too), and Iris's `Frame` stream is a *separate analysis channel*. Decoupling the two means the detector can run faster than real-time (e.g. M3 "scrub through and pre-populate detections") or slower (a 100ms model is fine on a 30Hz video — frames just drop).

PRVisionSpike has both modes — display-link-driven (paced, callback) for the live overlay and asset-reader-driven (un-paced, `AsyncStream`) for the pre-pass — and the `AsyncStream` side is unambiguously cleaner. Iris ships only the `AsyncStream` shape.

### Seek via reader-recreate

`AVAssetReader` is forward-only. Per Apple docs and the StackOverflow/Apple-forums consensus surfaced in research, the only reliable seek is:

```swift
public func seek(to time: CMTime) async throws {
    readerTask?.cancel()
    reader?.cancelReading()
    try await makeReader(timeRange: CMTimeRange(start: time, duration: .positiveInfinity))
    if state == .playing { startReaderLoop() }
}
```

`supportsRandomAccess` + `reset(forReadingTimeRanges:)` exists but only works if `supportsRandomAccess` was set to `true` *before* `startReading` and configuration was finalized — it's a multi-pass affordance, not a general scrubber. For frame-accurate scrubbing in M3, recreate is simpler and the cost (decoder warmup) is sub-100ms on iPhone-class hardware in iOS 26.

### Frame-step

```swift
public func step(by count: Int) async throws -> Frame? {
    precondition(count >= 0, "step is forward-only")
    var result: Frame?
    for _ in 0..<count {
        guard let buf = output?.copyNextSampleBuffer() else { return nil }
        result = makeFrame(buf)
    }
    return result
}
```

Forward-step only; backward step is a `seek(to: time - oneFrame)` call.

### macOS parity

`AVAssetReader` is identical on iOS 26 and macOS 26 — same APIs, same pixel formats, same semantics. `PlaybackSession` has **zero `#if os`** in its file. The platform fork lives one level up in the (future) `IrisPlayback.VideoPlayerView`: `UIViewRepresentable<AVPlayerView>` (iOS) vs `NSViewRepresentable<AVPlayerView>` (macOS), per sportvision's `VideoPlayerView.swift:8-87` pattern. That's a 25-line-per-platform fork in the *view layer*, not the source layer.

This closes the touch on Q5 for playback: shape matches iOS exactly, no compromise.

---

## 6. The `Frame` type

```swift
/// A single frame from any source. Sendable across actors because the
/// underlying CVPixelBuffer is treated as immutable from the moment it's
/// wrapped here — callers must not mutate the buffer in place. Buffer
/// retention/release is handled by ARC on the CVPixelBuffer reference; the
/// buffer's IOSurface keeps it alive across actor hops with zero copies.
public struct Frame: @unchecked Sendable {
    /// The pixel data. Either YUV 4:2:0 bi-planar full range (default;
    /// Vision-native) or BGRA8 (when explicitly requested). IOSurface-backed
    /// by construction — both AVCaptureVideoDataOutput and AVAssetReaderTrackOutput
    /// produce IOSurface buffers when configured per §3/§5.
    public let pixelBuffer: CVPixelBuffer

    /// Presentation time. CMTime, not TimeInterval — playback math needs
    /// rationals to avoid float drift.
    public let timestamp: CMTime

    /// Vision-native orientation (CGImagePropertyOrientation values). The
    /// RotationCoordinator delta is applied to this enum, not to the buffer.
    public let orientation: CGImagePropertyOrientation

    /// Where the frame came from. Detectors and overlays should not branch
    /// on this; it's for dataset/logging only.
    public let source: SourceKind

    /// Native pixel format of `pixelBuffer`. Detectors that need a specific
    /// format use this to decide whether to convert.
    public let format: PixelFormat

    /// Display size in pixels (taken from CVPixelBufferGet{Width,Height}
    /// at construction, cached so consumers don't pay the syscall per use).
    public let dimensions: CGSize
}

public enum SourceKind: Sendable, Hashable {
    case camera(CameraDevice.ID)
    case playback(AssetID)
    case mock(String)            // for previews and tests
}

public enum PixelFormat: Sendable, Hashable {
    case yuv420BiPlanarFull      // kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    case bgra8                   // kCVPixelFormatType_32BGRA
}
```

### Sendability — the justification

`CVPixelBuffer` is a `CFType` and is *not* `Sendable` in Swift 6. The Swift Forums Dec-2025 consensus (`AVCaptureSession and concurrency` thread) and NextLevel's shipped pattern (`NextLevel.swift:38-64`) both endorse the same workaround: wrap in a struct that's `@unchecked Sendable` with a documented invariant. The invariant for Iris's `Frame`:

1. **The pixel buffer is not mutated after construction.** The producers (capture delegate, playback reader) both create the buffer once and immediately wrap. Consumers may read the buffer (lock for reading, copy out CIImage, hand to Vision) but never write.
2. **The pixel buffer is IOSurface-backed.** Both producers request IOSurface (capture via `AVCaptureVideoDataOutput`'s default behavior with `automaticallyConfiguresOutputBufferDimensions`; playback explicitly via `kCVPixelBufferIOSurfacePropertiesKey`). IOSurface gives Core Video the thread-safe cross-process/cross-framework guarantees that bare `CVPixelBuffer` lacks.
3. **Buffer lifetime is ARC-managed.** Wrapping the `CVPixelBuffer` in the struct retains it; dropping all `Frame` copies releases it. The pool that allocated the buffer (capture's `AVCaptureVideoDataOutput` internal `CVPixelBufferPool`, or playback's reader-allocated buffer) is free to reuse the underlying memory only after all `Frame`s referencing it are gone.

This is exactly the pattern Apple's own NextLevel-flavored AVF code uses, and Kadr's `CancellationToken` pattern generalized: `@unchecked Sendable` + invariant-document-comment, no `NSLock` needed because the invariant is "buffer is immutable" not "field is protected" (`swift-ecosystem/RECOMMENDATIONS.md`).

### Why not an actor

An actor wrapping the pixel buffer would force every read to await — fatal for Vision, which wants the buffer synchronously. The actor route was considered and rejected for the same reason Kadr's `Clip` is `Sendable` value-typed (`swift-ecosystem/kadr.md` §"Async / concurrency story"): per-frame async hops in hot paths are scheduling overhead Iris cannot pay at 30/60 fps.

### Naming hazard locked

Per `prior-projects/RECOMMENDATIONS.md` §"Things to add to M1 scope" #7: **`Frame` is the transient pipeline value type and nothing else.** If `IrisDataset` later persists frames, the saved-record type is `DatasetFrame` / `CapturedSample` / `LabeledFrame`. Sportvision's collision is the cautionary tale.

---

## 7. Source-agnostic boundary — the `Source` protocol

M0 verdict (Q1, RECOMMENDATIONS-PRIOR-ART) is "concrete `AsyncStream<Frame>` return type, exposed through an `AsyncSequence` protocol so callers bind to the protocol." This locks the exact shape:

```swift
/// A producer of frames. Capture and playback both conform; detector mocks
/// for tests and previews conform; an Foundation Models or RTSP source can
/// conform later. The contract is intentionally narrow: yield Frames,
/// surface lifecycle/error via state, support graceful cancellation.
public protocol Source<Failure>: AnyObject, Sendable {
    /// The frame stream. Concrete conformers return a concrete
    /// AsyncStream<Frame>; the protocol declares it as the existential
    /// AsyncStream<Frame> directly (not `some AsyncSequence`) per the
    /// PFM precedent — see swift-ecosystem/RECOMMENDATIONS.md §"Detection".
    var frames: AsyncStream<Frame> { get }

    /// Observable lifecycle state. SwiftUI binds to this via @Observable
    /// on the conformer (CaptureSession + PlaybackSession both adopt it).
    var state: SourceState { get }

    /// Start producing frames. Idempotent.
    func start() async throws

    /// Stop producing frames; the AsyncStream remains alive but quiet.
    /// Resumed by a subsequent start().
    func stop() async

    /// Finish the AsyncStream and tear down. After this, `frames`'s
    /// iteration loop completes; the Source instance is dead.
    func invalidate() async
}

public enum SourceState: Sendable {
    case idle
    case requestingPermission
    case permissionDenied(MediaType)
    case running
    case paused
    case failed(SourceError)
    case stopped
}
```

Design notes:

- **Concrete `AsyncStream<Frame>` in the protocol, not `some AsyncSequence`.** This follows PFM's `LanguageModelBackend.swift:12-86` precedent (`swift-ecosystem/private-foundation-models.md`) and dodges the existential/opaque-type dance entirely. Callers write `for await frame in source.frames { … }`; there's no type-erasure ceremony, no generic constraint propagation up the call stack.
- **`AnyObject` constraint.** `CaptureSession` and `PlaybackSession` are both actors (reference types); requiring `AnyObject` lets the protocol hold weak references where needed and disambiguates from value-type "sources" that don't exist in this design.
- **`Sendable` on the protocol.** Both conformers are actors, which give `Sendable` for free. The protocol's `Sendable` constraint lets consumers freely pass a `Source` across actor boundaries — important when a SwiftUI view (MainActor) holds a `Source` and hands it to a detector loop on a child task.
- **No `associatedtype Failure`.** The `AsyncStream<Frame>` is non-throwing by design (§4 rationale). Errors live on `state`, not on the stream.
- **Lifecycle methods are `async`.** Not `async throws` for the basics — `stop()` and `invalidate()` shouldn't fail in any way callers can recover from. `start()` is `async throws` because permissions are the realistic failure mode.

### What both conformers satisfy

| Surface          | `CaptureSession`                       | `PlaybackSession`                  |
| ---------------- | -------------------------------------- | ---------------------------------- |
| `frames`         | AVF-delegate-driven, .bufferingNewest(1) | AVAssetReader-driven, .bufferingNewest(1) |
| `state`          | `@Observable`, drives UI permission flows | `@Observable`, drives scrubber UI |
| `start()`        | Permissions → `startRunning()`          | Open asset → start reader task     |
| `stop()`         | `stopRunning()`, keep continuation alive | Cancel reader task, keep continuation alive |
| `invalidate()`   | Tear down session, finish continuation  | Cancel reader, finish continuation |

The downstream consumer cannot distinguish capture from playback by looking at `frames` — that's the point.

---

## 8. Isolation map

Single table, exhaustive for the source side:

| Type                          | Isolation                                        | Why                                                                                        |
| ----------------------------- | ------------------------------------------------ | ------------------------------------------------------------------------------------------ |
| `CaptureSession`              | `actor` with custom serial executor (`captureQueue`) | AVF threading; same queue as delegate; one-queue-three-jobs principle from AVCam.       |
| `PlaybackSession`             | `actor` with default cooperative executor         | No AVF threading constraints; reader is single-owned by the actor.                       |
| `SampleBufferRouter`          | `final class @unchecked Sendable`                | Must be NSObject for AVF delegate; only ever runs on captureQueue → invariant satisfied. |
| `Frame`                       | `struct @unchecked Sendable`                     | CVPixelBuffer-immutable-by-convention; IOSurface-backed → cross-actor safe.              |
| `PreviewSource`               | `protocol Sendable` (AVCam pattern)              | Nonisolated opening in actor wall; UIKit-bridge layer connects on `@MainActor`.          |
| `PreviewTarget`               | `@MainActor protocol`                            | Wraps `AVCaptureVideoPreviewLayer` which is a UIView/NSView layer.                       |
| `CameraPreview` (SwiftUI view) | `@MainActor` (SwiftUI implicit)                  | UI lives on MainActor.                                                                    |
| `SourceState`                 | `enum Sendable`                                  | Plain value type; lives wherever the holding `@Observable` lives.                        |
| consumer's `for await` loop   | wherever the consumer puts it                    | Typically inherits MainActor from a `.task { }`, then awaits into the detector actor.    |

**Where hops happen:**

```
Capture delegate callback (on captureQueue == CaptureSession executor)
    │  zero hops — already in isolation
    ▼
continuation.yield(frame)
    │  zero hops — Continuation is Sendable, takes the value synchronously
    ▼
consumer's Task (often MainActor or a detached child of one)
    │  one hop on the `for await` resumption
    ▼
await detector.detect(frame)  ← detector hop (downstream, out of scope here)
```

That's *one* actor hop in the hot path (capture queue → consumer's actor), versus PRVisionSpike's "spawn a Task per frame to await into a slow actor" pattern (`prior-projects/PRVisionSpike.md` §Frame plumbing) which pays unbounded hops and unbounded queue.

### Strict-concurrency footguns this design avoids

| Footgun                                                            | How the design dodges it                                                                 |
| ------------------------------------------------------------------ | ---------------------------------------------------------------------------------------- |
| `CVPixelBuffer` not Sendable                                       | Wrapped in `Frame @unchecked Sendable` with immutability invariant; IOSurface guarantees safe cross-actor read. |
| `AVCaptureSession.startRunning()` blocks the calling thread        | Called on the actor's serial queue, which *is* a background queue; never on cooperative pool. |
| Delegate callback ambiguity (which queue?)                          | Delegate queue IS the actor's executor; ambiguity eliminated by construction.            |
| Continuation captured in a `@Sendable` closure with mutable state   | Continuation is `Sendable` by stdlib guarantee; we store it on the actor and reference it from the router which is `@unchecked Sendable` with a queue-isolation invariant. |
| `@unchecked Sendable` proliferation as silencer                     | Used exactly twice (`Frame`, `SampleBufferRouter`), each with explicit invariant doc-comment. Banned everywhere else (cross-cutting principle). |
| Per-frame `Task { }` spawning inside the framework                  | Forbidden. `yield(frame)` is synchronous from inside the actor's executor; no task spawn. |
| `@preconcurrency import AVFoundation` as a global blanket           | Used at the file scope of `CaptureSession.swift` and `PlaybackSession.swift` only. Not in the `Source`/`Frame` public-API files. |
| Combine `@Published` + `.values` bridge from actor to MainActor     | Banned. Iris uses `@Observable` directly on the actor state, lifted via `Source.state`. No Combine. |

---

## 9. Performance

### Pool reuse and IOSurface

Capture: `AVCaptureVideoDataOutput` manages a `CVPixelBufferPool` internally. We do not touch it. As long as we don't retain `Frame` (and through it the `CVPixelBuffer`) longer than the consumer's per-frame work, the pool recycles. Net per-frame allocation: zero new pixel buffers, one new `Frame` struct (24-32 bytes), one IOSurface refcount bump.

Playback: `AVAssetReaderTrackOutput` allocates buffers from its own pool. Same lifecycle: hold the `Frame` for the duration of one detector call, drop, pool recycles.

**IOSurface backing** is the critical performance guarantee. Without it, every actor hop or framework hop costs a CPU memcpy. With it (which both producers give us by default — capture inherits IOSurface from `AVCaptureVideoDataOutput`'s pool, playback opts in via `kCVPixelBufferIOSurfacePropertiesKey: [:]`), Vision's `ImageRequestHandler` and Core Image / Metal all consume the same memory by reference. Zero copies from camera to model.

### Back-pressure

`.bufferingNewest(1)` is the contract. If the detector lags, frames drop *before* they enter Vision — never *during*. This is exactly the back-pressure semantics that three of five prior projects shipped without (PRVisionSpike, sportvision, ios-videoCapture; see `prior-projects/SYNTHESIS.md` §"Findings not on M1 list" #3).

Apple's TN2445 backs this up: "Always set `alwaysDiscardsLateVideoFrames = true`. … Enforces a buffer queue size of 1." The AVF side already drops late frames; we layer `.bufferingNewest(1)` on top so the Swift-side stream doesn't queue them either. Belt + suspenders.

### Numeric targets

- **iOS 26 / iPhone 15 Pro class**: 30 fps capture at 1920×1080 yuv420 is well within budget for the bridge itself (sub-ms per frame for the actor hop + `yield`); the bottleneck is always the detector.
- **Latency**: ~16-33ms camera-to-Frame (one frame's worth of pipeline). Iris adds no extra latency on top — the actor-executor-as-delegate-queue pattern avoids the "deliver to one queue, hop to another" overhead.
- **macOS 26 playback at 4K30**: `AVAssetReader` decodes at well above real-time on Apple Silicon. The consumer's detector pace is the constraint.

### Drop policy

- Capture: `alwaysDiscardsLateVideoFrames = true` + `bufferingPolicy: .bufferingNewest(1)`. Frames drop silently. The `didDrop` callback is logged via `os.Logger` (cross-cutting principle from `prior-projects/RECOMMENDATIONS.md`) but does **not** propagate to the stream.
- Playback: `bufferingPolicy: .bufferingNewest(1)`. Pull-driven, so drops happen if the consumer's `for await` doesn't yield promptly.

---

## 10. Open questions remaining

These were exposed by the synthesis but are intentionally out of scope for this block:

1. **Where does `PreviewSource` live structurally?** AVCam puts it on the `CaptureService` as `nonisolated let`. Iris does the same, but the iOS-only `CameraPreview` SwiftUI view that consumes it is a public API surface — does it ship in core `iris` or in an `iris-capture` subpackage? Answered by the package-layout block, not this one.
2. **Multi-subscriber broadcast.** The contract is "one stream, one consumer" in v0. M3+ may need a fan-out (e.g. a UI tap on a frame for dataset capture, *parallel to* the detector consuming the same frame). The right shape is `[UUID: Continuation]` per NextLevel's note; design left to M3.
3. **`Frame.dimensions` redundancy.** `CVPixelBufferGetWidth/Height` is two syscalls per frame; we cache them in `Frame`. If profiling shows the cache costs more than the syscalls (unlikely but worth checking), drop the field.
4. **Rotation handoff.** `RotationCoordinator` is centralized in capture, but its observed angle has to reach the `Frame.orientation` field. Current design: `CaptureSession.currentRotationAngle` is actor-isolated, the router reads it via the `@Sendable () async -> CGFloat` closure passed at init. That's a hop per frame, which may not be ideal — consider snapshotting the angle into the router on rotation changes only.
5. **Cancellation symmetry.** `Source.stop()` keeps the continuation alive (transient pause), `Source.invalidate()` finishes it (permanent teardown). MijickCamera's `stopRunningAndReturnNewInstance()` model (rebuild every cycle) is rejected, but the *consumer's* expectation when they cancel their `Task` mid-`for await` should be clear: it terminates the stream (back to `invalidate()` semantics) or leaves the source alive for a future re-iterate? Lean: stream termination by consumer = stream is done, but the `Source` survives for a fresh `.frames` read after a new `start()`. Worth a doc note in M1.
6. **Audio.** Out of scope here. If/when Iris adds audio capture (for video recording with audio, M5+), it gets its own `AsyncStream<AudioFrame>` and lives in `CaptureSession` as a sibling output. The `Source` protocol stays video-only.

---

## Sources cited

- **Prior art (in-house):**
  - [`../prior-projects/SYNTHESIS.md`](../prior-projects/SYNTHESIS.md) — verdicts on M1 Q1/Q2/Q4/Q5 and the additions list.
  - [`../prior-projects/RECOMMENDATIONS.md`](../prior-projects/RECOMMENDATIONS.md) — action-oriented patterns.
  - [`../prior-projects/sportvision.md`](../prior-projects/sportvision.md) — dual-target Swift 6 / iOS 26 / macOS 26 playback shape.
  - [`../prior-projects/PRVisionSpike.md`](../prior-projects/PRVisionSpike.md) — `AsyncStream` and two-actor split, `SampleBufferAndOrientation` shape.
  - [`../prior-projects/ios-videoCapture.md`](../prior-projects/ios-videoCapture.md) — `dispatchPrecondition(.onQueue(sessionQueue))` blueprint; AVF leak anti-pattern.
- **Swift ecosystem (external):**
  - [`../swift-ecosystem/apple-avcam.md`](../swift-ecosystem/apple-avcam.md) — `actor CaptureService` + `unownedExecutor` + `PreviewSource` blueprint.
  - [`../swift-ecosystem/nextlevel.md`](../swift-ecosystem/nextlevel.md) — `SendablePixelBuffer` / `UnsafeSendableDictionary` cost-of-Swift-6 reference; interruption fix.
  - [`../swift-ecosystem/mijick-camera.md`](../swift-ecosystem/mijick-camera.md) — `UIViewRepresentable` + permissions-in-`setup()` patterns; `.startSession()` anti-pattern.
  - [`../swift-ecosystem/kadr.md`](../swift-ecosystem/kadr.md) — `@unchecked Sendable + NSLock + documented invariant` template.
  - [`../swift-ecosystem/private-foundation-models.md`](../swift-ecosystem/private-foundation-models.md) — concrete `AsyncThrowingStream` (and by analogy `AsyncStream`) over `some AsyncSequence`.
  - [`../RECOMMENDATIONS-PRIOR-ART.md`](../RECOMMENDATIONS-PRIOR-ART.md) — rolled-up decision matrix.
- **Apple docs / forums / technotes (targeted lookups, 2026-05-20):**
  - [Technical Note TN2445: Handling Frame Drops with `AVCaptureVideoDataOutput`](https://developer.apple.com/library/archive/technotes/tn2445/_index.html) — "always set `alwaysDiscardsLateVideoFrames` to YES" + delegate efficiency rules.
  - [`AVCaptureVideoDataOutput` reference](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput) — delegate contract.
  - [Swift Forums: AVCaptureSession and concurrency (Dec 2025 thread)](https://forums.swift.org/t/avcapturesession-and-concurrency/72681) — community + Apple-engineer-adjacent consensus on actor + serial executor.
  - [`AVAssetReaderTrackOutput` reference](https://developer.apple.com/documentation/avfoundation/avassetreadertrackoutput) — forward-only `copyNextSampleBuffer`, `supportsRandomAccess` constraints.
  - [`AVCaptureDevice.RotationCoordinator`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/rotationcoordinator) — replacement for deprecated `AVCaptureVideoOrientation` flow.
  - [`AsyncStream.makeStream(of:bufferingPolicy:)`](https://developer.apple.com/documentation/swift/asyncstream/makestream(of:bufferingpolicy:)) — continuation lifecycle and `bufferingNewest` semantics.
  - [`AsyncStream.Continuation.BufferingPolicy`](https://developer.apple.com/documentation/swift/asyncstream/continuation/bufferingpolicy) — `bufferingNewest(1)` drops oldest, keeps newest.
  - [Apple Q&A QA1781: Creating IOSurface-backed `CVPixelBuffer`s](https://developer.apple.com/library/archive/qa/qa1781/_index.html) — IOSurface guarantees.
  - [react-native-vision-camera: Pixel Formats](https://react-native-vision-camera.com/docs/guides/pixel-formats) — YUV vs BGRA performance comparison (4K YUV ~12 MB vs BGRA ~31 MB).
