# NextLevel — prior-art read

**Path:** github.com/NextLevel/NextLevel · 2,306★ · iOS 16+, Swift 6 strict concurrency
**Read date:** 2026-05-20
**Priority lens:** Swift 6 migration scars + per-frame imageBuffer hook + Sendable boundaries on `CMSampleBuffer`

## At a glance

`Package.swift` is concise and instructive (`Package.swift:28-47`):

```swift
platforms: [.iOS(.v16)]
swiftSettings: [
    .enableUpcomingFeature("StrictConcurrency"),
    .enableUpcomingFeature("ExistentialAny")
]
swiftLanguageModes: [.version("6")]
```

One product, one target, `path: "Sources"`. No macOS. No tests target in `Package.swift`. ~6,900 LoC total, 3,718 of which live in a single god-file `NextLevel.swift`. Two recent commits do the heavy lifting for our lens: `07b8679` (2026‑01‑13, "Modernize to Swift 6 with async/await and structured logging") and `6f97e60` (2026‑01‑20, the Sendable wrapper commit that flipped the actor + wrappers in).

## Capture entrypoint

Singleton-anchored UIKit shape. `public class NextLevel: NSObject, @unchecked Sendable` (`NextLevel.swift:321`) holds **9 weak delegate sockets**, an `AVCaptureVideoPreviewLayer` exposed as `public var previewLayer` (`:340`), and `public static let shared = NextLevel()` (`:567`). README's "setup the preview" idiom is bare CALayer plumbing: `previewView.layer.addSublayer(NextLevel.shared.previewLayer)` (`README.md:131`). No `UIViewRepresentable`, no `CameraPreview` SwiftUI view, no actor on the session entrypoint.

Session-queue discipline survives: a single serial `DispatchQueue(label: …, qos: .userInteractive, target: .global())` is created in `init` (`:575`) with a `setSpecific` key so re-entrant calls can be detected. Mutations to capture state are funneled through `executeClosureAsyncOnSessionQueueIfNecessary { … }` (5+ call sites in property `didSet`s like `captureMode` `:379` and `videoStabilizationMode` `:430`). The Swift 6 conversion did **not** replace this queue with an actor — `NextLevel` stayed `@unchecked Sendable` and the queue stayed; only `NextLevelSession` (the recording-clip aggregator, not the capture root) became an `actor` (`NextLevelSession.swift:72`).

That split is the load-bearing decision: the capture root is reference-typed and Objective-C-delegate-shaped because it has to be `AVCaptureVideoDataOutputSampleBufferDelegate` (`NextLevel.swift:3011`); the *recording session* is an actor because it owns mutable per-clip state. For Iris this argues for the same split — `IrisCapture.Session` as an actor, but a separate adapter that conforms to the AVFoundation delegate protocol on the session queue.

## Frame plumbing (priority lens for this project)

**Per-frame entry is delegate-callback-on-`_sessionQueue`** (`:3013-3041`):

```swift
public func captureOutput(_ captureOutput: AVCaptureOutput,
                          didOutput sampleBuffer: CMSampleBuffer,
                          from connection: AVCaptureConnection) {
    …
    self.videoDelegate?.nextLevel(self, willProcessRawVideoSampleBuffer: sampleBuffer, onQueue: self._sessionQueue)
    self._lastVideoFrame = sampleBuffer
    if let session = self._recordingSession {
        self.handleVideoOutput(sampleBuffer: sampleBuffer, session: session)
    }
}
```

The raw-frame consumer hook is the synchronous protocol method `nextLevel(_:willProcessRawVideoSampleBuffer:onQueue:)` (`NextLevelProtocols.swift:152`). It is contracted to *run on the session queue* (the protocol doc says: "All methods are called on the main queue with the exception of …renderToCustomContextWithSampleBuffer:onQueue" — `:145`). That's the equivalent of Iris's `Frame` callback — and it is **purely a delegate, never an `AsyncStream`**. The new `videoEvents: AsyncStream<VideoEvent>` (`:3636`) only emits lifecycle markers like `frameWillProcess(timestamp:)`/`frameDidProcess(timestamp:)` — *not the pixels*. A consumer that wants the buffer must still implement the delegate.

The Sendable workarounds in `handleVideoOutput` (`:2731-2818`) are the most instructive code in the repo for Iris. The capture queue spawns a `Task { … }` per frame — and to cross the actor boundary into `NextLevelSession`, the code hand-rolls two `@unchecked Sendable` wrappers (`:38-64`):

```swift
@available(iOS 16.0, *)
private struct SendablePixelBuffer: @unchecked Sendable {
    let buffer: CVPixelBuffer?
}
@available(iOS 16.0, *)
private struct UnsafeSendableDictionary: @unchecked Sendable {
    let value: [String: Any]
}
```

These wrappers — plus four `@preconcurrency import` statements (`AVFoundation`, `CoreImage`, `CoreVideo`, `CoreMedia` at `:28-31`) — are the actual cost of "Swift 6 strict concurrency + AVFoundation, today." `CMSampleBuffer` itself is *not* wrapped (it conforms to `Sendable` already in iOS 16+ headers, which is why the four `@preconcurrency` imports exist — to suppress diagnostics from the still-not-quite-Sendable transitive types). One smell: `nonisolated(unsafe) var failedBuffers: [CMSampleBuffer] = []` inside the actor (`NextLevelSession.swift:634`) to allow a closure capture inside `forEach`.

**Spawning a `Task {}` per video frame is the design** here (`:2732`, `:2822`, also inside audio handler). At 30/60 fps this is a non-trivial scheduling load and a hard-to-cancel mess; the file maintains `_activeTasks: [Task<Void, Never>]` + `_tasksLock = NSLock()` (`:511-513`) and a `cancelAllTasks()` in `deinit` (`:594`) to chase the leaks. For Iris this argues hard for **`AsyncStream.makeStream(of: Frame.self, bufferingPolicy: .bufferingNewest(1))` produced from the delegate callback**, with downstream consumers doing their own task management — *do not spawn a Task per frame inside the framework*.

## Detection path

No detection in NextLevel. The closest hooks are `metadataObjectsDelegate` (faces/barcodes, `:335`) and the `willProcessRawVideoSampleBuffer` callback that a consumer could route into Vision. The frame-plumbing shape makes a `Detector` *possible* (you'd implement `NextLevelVideoDelegate`, do Vision work on `_sessionQueue`, retain the result, and overlay separately) but *not ergonomic*: the delegate is the only way in, you can't have multiple subscribers, and there's no typed `Frame` envelope — you get the raw `CMSampleBuffer` plus a `DispatchQueue` reference. Iris's planned `Source: Sendable` protocol that yields `AsyncStream<Frame>` is a strict upgrade for this use case.

## Overlay coordinate-space handling

None. Confirmed — `grep -n "Vision\|normalized\|coordinate\|metadataOutputRectConverted" /tmp/nextlevel/Sources/*.swift` returns only one hit, `previewLayer.transformedMetadataObject(for:)` at `:3183` (AVCapture's own face/barcode rect conversion). Nothing for Vision normalized coords, nothing for rotation, nothing for mirroring on overlays. This is purely a capture/record library.

## Public API shape

Quantified workaround density across `Sources/*.swift`:

| Pattern | Count |
|---|---|
| `@preconcurrency import` | 4 (all in `NextLevel.swift`) |
| `@unchecked Sendable` on public types | 7 (`NextLevel`, `NextLevelGIFCreator`, `NextLevelClip`, plus 4 `NextLevel*Configuration`) |
| `nonisolated(unsafe)` mutable var | 1 (`NextLevelSession.swift:634`) |
| `@MainActor` annotations | 0 |
| Public `actor` types | 1 (`NextLevelSession`) |
| Public `class` types | 7 |
| Public delegate protocols | 9 |
| `public static let shared` | 1 |
| KVO `.observe(\.keyPath)` blocks | ~20 in `addCaptureDeviceObservers` (`:3460-3498`) |
| `DispatchQueue.main.async` per-frame call sites | 4 (in `handleVideoOutput` paths) |

Zero `@MainActor` is striking — the package leans entirely on its serial queue + the new `NextLevelSession` actor + `@unchecked Sendable` to satisfy Swift 6, rather than embracing actor isolation as the primary tool. The "modernization" is *additive* (Sendable enums, an `AsyncStream` events facade) layered over a UIKit/delegate core that wasn't redesigned.

## Swift 6 migration history (from git log, since there's no CHANGELOG.md)

Three commits tell the whole story:

- **`07b8679` "Modernize to Swift 6 with async/await and structured logging"** (2026-01-13):
  > "Add Sendable conformance to all public enums … Add AsyncStream event types for modern reactive patterns … Integrate OSLog structured logging … Fix critical AudioChannelLayout crash (#286, #271): Validate channel layout matches declared channel count … Gracefully omit incompatible layouts to prevent crashes."

- **`7a91f5e` "Fix critical issues #286, #271, #280, #281, #278"** (2026-01-13, two hours later):
  > "Fix AudioChannelLayout crash by validating channel counts … Fix photo crash from mutually exclusive dictionary keys [`kCVPixelBufferPixelFormatTypeKey` and `AVVideoCodecKey`] … Fix missing audio after interruptions with proper pause/resume … Fix video time skips from cumulative timestamp offset accumulation."

  Concretely (`NextLevelConfiguration.swift` diff): the previous code unconditionally seeded `[AVVideoCodecKey: codec]` and then added the pixel-format key when `generateThumbnail` was set — and AVFoundation crashes when both are present. The new code branches.

- **`6f97e60` "Version Updates"** (2026-01-20):
  > "Actor Initialization (NextLevelSession.swift:266) — Removed convenience keyword from actor initializer and properly initialized all properties … CVPixelBuffer/CVImageBuffer Sendable Issues — Created SendablePixelBuffer wrapper struct to safely capture pixel buffers in @Sendable closures … Dictionary Sendable Issues — Created UnsafeSendableDictionary wrapper to safely pass [String: Any] dictionaries across actor boundaries."

The interruption-loses-audio bug (#281) is the one Iris is **most likely to inherit**: the fix is to set `_pausedDueToInterruption = true`, call `pause()` synchronously in the interruption handler, then on `interruptionEnded` resume with `DispatchQueue.main.asyncAfter(deadline: .now() + 0.1)` to let the audio session stabilize. The 100 ms sleep is a tell — even shipped code can't avoid magic delays around `AVAudioSession` interruption.

## Carry forward into Iris (2–3)

1. **Sendable wrappers belong in `IrisCapture` from day one, with this exact shape.** `SendablePixelBuffer` and `UnsafeSendableDictionary` are tiny private structs that earn their `@unchecked` because the values are immutable, freshly created, never aliased. Iris's `Frame` envelope should do the same — internal `@unchecked Sendable` with explicit reasoning in a doc comment, *not* `@preconcurrency import AVFoundation` leaking through the public surface.
2. **Recording-clip aggregator as an `actor`, capture session as a queue-backed class.** NextLevel discovered the split the hard way: `NextLevelSession` is `public actor`, `NextLevel` stays `@unchecked Sendable` + serial queue because it has to be an `AVCaptureVideoDataOutputSampleBufferDelegate`. Iris's `IrisDataset` writer (multi-clip, mutable per-session state) is the equivalent of `NextLevelSession` and should be `actor`-typed.
3. **Pre-empt the interruption bug.** Pause on `wasInterrupted`, resume on `interruptionEnded`, accept that `AVAudioSession` needs ~100 ms to settle. Wire it into `IrisCapture` before milestone close, not as a follow-up.

## Don't repeat (1–2)

1. **Singleton `.shared` + 9 delegate sockets + delegate-only per-frame hook.** This is the core API anti-pattern. Iris's `Source` protocol yielding `AsyncStream<Frame>` is right; do not regress to a delegate for the buffer hop.
2. **`AsyncStream` continuations stored as a single `Any?`.** `_sessionEventContinuation: Any?` (`:517`) and the `AsyncStream { continuation in self._sessionEventContinuation = continuation }` getter (`:3608-3614`) mean **the second subscriber overwrites the first** and the first stream silently goes dead. The author even left a 30-line comment block (`:3699-3717`) sketching the correct `[UUID: Continuation]` multi-subscriber implementation and didn't write it. Iris should ship multi-subscriber stream broadcast from v0.

## Opinions on Iris's still-open questions

- **Source-protocol unification:** NextLevel actively avoids it (delegate-only frames). Iris's plan to unify capture + playback behind one `Source` protocol producing `AsyncStream<Frame>` is the right call — NextLevel demonstrates the cost of *not* having that abstraction (every frame consumer is locked to AVCaptureSession delegate semantics, including the `onQueue:` parameter leaking into the protocol).
- **Cancellation policy:** NextLevel uses `_activeTasks: [Task<Void, Never>]` + an `NSLock` + per-frame `Task {}` spawning + `cancelAllTasks()` in `deinit`. This is exactly the pattern Iris should avoid by using `AsyncStream` with `bufferingPolicy: .bufferingNewest(1)` — backpressure handled by the stream, cancellation handled by the consumer's `Task` lifetime, no per-frame task accounting in the framework.
- **DetectorCache ownership:** No signal from NextLevel (no detection).
- **Q3 (sidecar format), Q6 (Foundation Models scope):** No signal from NextLevel.

## Verdict

**Study then diverge.** NextLevel paid the Swift 6 + AVFoundation migration tax in public — read `NextLevel.swift:38-64`, `:2725-2820`, and `NextLevelSession.swift:72-300` as a "what does it actually cost" reference, then build Iris's `IrisCapture` against the SwiftUI/`AsyncStream` plan rather than borrowing API shape. The frame-plumbing internals and Sendable wrappers are worth lifting; the public surface is the negative example Iris is defined against.

## Notes & loose ends

- No CHANGELOG.md in the repo — migration history is git-log-only. README has a Swift 6 section but it's marketing, not detail.
- The `videoEvents` AsyncStream emits `frameWillProcess(timestamp:)` / `frameDidProcess(timestamp:)` (`:3575-3576`) but the `publishVideoEvent(.frameWillProcess(…))` call is *not wired in* anywhere in the source (grep finds zero call sites). Dead API.
- `NextLevelBufferRenderer` (275 LoC) is a SceneKit-frame-to-`CVPixelBuffer` adapter behind `#if USE_ARKIT` — irrelevant to Iris.
- `Tests/` directory does not exist in the package; `Package.swift` declares no test target. For a 2.3k-star library this is striking.
- Recent issue numbers referenced in commits (#271, #278, #280, #281, #286) all cluster around interruption + audio + photo-config crashes — i.e. AVFoundation's sharp edges, not Swift 6's. The Swift 6 migration itself was surprisingly clean; what bit them is the *underlying AVFoundation contract* that Swift 6 strict concurrency forced them to make explicit.
