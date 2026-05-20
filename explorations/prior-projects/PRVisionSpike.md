# PRVisionSpike — prior-art read

**Path:** `~/dev/PR/PRVisionSpike`
**Read date:** 2026-05-20
**Priority lens:** detection actor pattern + Vision-to-overlay seam

## At a glance

An iOS-only spike (deployment iOS 14+) for evaluating Vision pipelines on
recorded video. Single-app SwiftPM workspace with one external dep
(`ios-videoCapture` at `~/dev/PR/ios-videoCapture`) supplying `VideoPlayback`
and `VisionMath`. No camera capture in this app — playback only. Pipeline:
file picker → `AVPlayer` + `AVAssetReader` → `VisionDetector` actor that runs
**four** Vision requests against each `CMSampleBuffer` (objects via YOLOv3 or
YOLOv5m, human body pose, contours, trajectories) plus a parallel MOG
background-subtraction path for ball candidates. Results land in a second
actor and are projected to `VisionResult` for SwiftUI `Canvas` rendering.
Settings live in an `ObservableObject` with Combine plumbing.

Tech stack: Swift 5.x, Combine + early-async/await mix (pre-Swift-6, no
strict concurrency), `actor` keyword used in two places, YOLO models bundled
as `.mlmodel` in `MLModels/`.

## Capture entrypoint

**Not applicable in this app.** PRVisionSpike does playback only. The
`ios-videoCapture` package it consumes does have a `CameraController`
library, but the app doesn't link it. `AppRootView` goes straight to
`VideoPlayerPage` which owns a `PlayerObserverAndVisionDetector` (the
playback-equivalent of a capture coordinator). Carry-forward implication:
the `Frame`-style abstraction here was *designed for playback first and
camera retrofit was never tried* — Iris should not assume this codebase has
already proved capture/playback fungibility.

## Frame plumbing

The shared frame type is `SampleBufferAndOrientation` from
`VideoPlayback/playerUtils/SampleBufferAndOrientation.swift:8`:

```swift
public struct SampleBufferAndOrientation {
    public let sampleBuffer: CMSampleBuffer
    public let orientation: CGImagePropertyOrientation
}
```

It's a public struct. Not annotated `Sendable`, but in practice it's
sample-buffer + orientation enum, both of which can cross actor boundaries.
It carries no timestamp field — `presentationTimeStamp` is pulled off the
`CMSampleBuffer` at use sites (e.g.
`VisionDetector+processSampleBuffer.swift:18`:
`sample.sampleBuffer.presentationTimeStamp.visionTimestamp`).

Two production paths build it:

1. **Playback path** — `AVPlayerObserver+updateSampleBuffer.swift:14` reads
   from `AVPlayerItemVideoOutput.copyPixelBuffer(forItemTime:)`, wraps in a
   `CMSampleBuffer` via the `init?(pixelBuffer:orientation:duration:itemTime:)`
   convenience, then calls `onNewSampleBuffer` (a callback closure typealias)
   inside a `Task`.
2. **Asset-reader path** — `AssetSampleBufferReader.readSampleBuffers()`
   exposes an `AsyncStream<SampleBufferAndOrientation>` driven by
   `AVAssetReaderTrackOutput.copyNextSampleBuffer()`. This is the
   faster-than-real-time path used to pre-populate observations for the whole
   asset before playback.

So there are **two distribution mechanisms in one app**: a callback
(`onNewSampleBuffer: (SampleBufferAndOrientation) async -> Void`) for
display-link-driven extraction, and an `AsyncStream` for asset reading. Same
frame type either way. The pixel format is forced to
`420YpCbCr8BiPlanarFullRange` in both readers (`AssetPlayerInfo.swift:23`,
`AVPlayerObserver+videoOutput.swift:26`).

## Detection path (priority lens for this project)

The pattern is **one big actor with multiple Vision requests**, not a
protocol-per-detector. `VisionDetector.swift:14`:

```swift
actor VisionDetector {
    var detectObjectsRequest: VNCoreMLRequest?
    var detectHumanBodyPoseRequest: VNDetectHumanBodyPoseRequest?
    var detectContoursRequest: VNDetectContoursRequest?
    var detectTrajectoryRequest: VNDetectTrajectoriesRequest?
}
```

The requests are **long-lived, owned by the actor, mutated through reset
methods** (`resetObjectDetector()`, `resetTrajectoryDetector()`, etc.). The
YOLO `VNCoreMLModel`s are `static let` constants on the type
(`VisionDetector.swift:51-61`) — meaning the heavy model load happens once
per process and every detector instance shares it. Model swap between YOLOv3
and YOLOv5m is **request-level**: call `makeYOLORequest(settings)` again,
keep the cached `VNCoreMLModel`.

Per-frame flow (`VisionDetector+processSampleBuffer.swift`):

1. Build a fresh `VNImageRequestHandler(cmSampleBuffer:orientation:options:)`
   per frame.
2. Compact-map the four request optionals into one array and call
   `try visionHandler.perform(requests)` — synchronous, blocking the actor.
3. Pull `.results` off each request property after the call (this is
   stateful — works because `perform` populates `request.results` on the
   same request instances the actor holds).
4. Run a *second* async pipeline (`foregroundVisionResultsForSampleBuffer`)
   that does MOG background subtraction + contour extraction for ball
   candidates — pure CIImage path, no Vision involvement.
5. Bundle everything into a `VisionTimestampedObservations` struct and
   `await observations.upsert(...)` into a **second actor**
   `VisionTimestampedObservationsHolder`.

Two actors, deliberately. The header on `VisionTimestampedObservationsHolder.swift:10-14`:

> We commonly want to access the timestampedObservations each video frame
> while the VisionDetector may be adding them. In order to reduce contention
> on the VisionDetector actor, we hold the observations is a separate actor

That's the clearest design rationale in the codebase: **split inference and
result storage onto different actors so the UI's read path doesn't queue
behind a slow inference call.**

**Back-pressure / cancellation:** none. The display-link path
(`onDisplayLink+`) fires `updateSampleBuffer(itemTime:)` which spawns a
`Task` and `await`s into the detector actor. If inference is slower than the
display link, Tasks pile up behind the actor's mailbox — there's no drop or
coalesce. The asset-reader path is bounded by `copyNextSampleBuffer()`
returning nil. Only the asset-read `Task` has cancellation
(`VisionDetectorInfo.deinit` cancels it).

**No `Detector` protocol exists.** It's a single concrete actor with hard-coded
sub-request types. Adding a fifth detection kind means adding a fifth
property and a fifth `make…Request` factory.

## Overlay coordinate-space handling

Centralized in `Utils/CVNomalized.swift` — an `enum CVNomalized` (note the
typo) of `static` methods. Single source of truth for Vision-normalized
(bottom-left-origin, 0..1) → SwiftUI top-left-origin pixel coords. Handles
`CGPoint`, `CGRect`, `CGSize`, and `CGPath` (via affine transform composing
scale + vertical flip — `CVNomalized.swift:68-79`).

Per-detection-type wrappers (`RecognizedObjectRectangle`, `HumanBodyPoints`,
`TrajectoryPoints`) store **normalized** values plus an
`init(_ observation: VNRecognizedObjectObservation)` and a
`denormalizedRect(into size: CGSize)` helper. So conversion happens in the
render loop, inside SwiftUI `Canvas` body — not when observations land in
the holder. This means scrubbing or resizing the view auto-redraws at the
right coords without re-running inference.

Rotation/mirroring: the orientation is carried *into* Vision (passed to
`VNImageRequestHandler.init(...orientation:)` once) and never to the
overlay. Vision is told what's "up"; the resulting normalized boxes are
already in the right frame; the overlay just denormalizes into the
`videoRect` from `AVPlayerObserver.$videoRect` (which itself comes from
`AVPlayerLayer.videoRect` and gets published — `AVPlayerObserver.swift:117`).
No `UIViewRepresentable`-level coordinate math in the overlay path.

**There is no shared `Detection` type for the overlay.** Each Vision request
gets its own dedicated wrapper struct, and `VisionResult` is a struct of
five arrays of those wrappers (`VisionResult.swift:10-18`). The renderer
(`VisionResultView+render.swift`) has a separate `renderXxx` static method
per type. No polymorphism; pure switch-on-fields.

## Pipeline composition / multi-detector patterns

**No composition primitive.** All four Vision requests are passed in one
batch to a single `VNImageRequestHandler.perform([…])`, which lets Vision
itself parallelize them on a single image. The background-subtraction +
ball-candidate path runs *sequentially after* the Vision batch, in the same
`processSampleBuffer` call.

If Iris wants a `DetectorPipeline` that chains/parallelizes heterogeneous
detectors, **this codebase is not a model for it** — it relies on Vision's
batch-perform as the only "pipeline" and bolts a second pipeline (CIImage →
contours) on with hand-written sequencing.

Tuning pattern: `VisionSettings: ObservableObject` (Combine-era, not
`@Observable`) holds nested settings structs for detector, background, ball
contour, overlay. The detector is constructed eagerly from a snapshot of
those settings; **changing settings doesn't update the live detector** — a
`resetDetector = PassthroughSubject<Void, Never>()` lets the user manually
press a "Reset Detector" button (`VisionSettingsView.swift:165`) which tears
down and rebuilds `VisionDetectorInfo`. This is a deliberate hot-swap by
**tear-down**, not in-place mutation.

Display visualization toggles (`showRecognizedObjects`, etc.) flow
separately: they're applied at the `VisionResult.init(observations:settings:)`
stage (`VisionResult.swift:20-55`), so they re-filter cached observations
without re-running inference. This separation — "what to detect" requires
reset; "what to show" is free — is a clean pattern.

## Carry forward into Iris (2–3)

1. **Two actors, not one: split inference from result storage.** The
   `VisionDetector` actor + `VisionTimestampedObservationsHolder` actor
   split is the single best idea here. The UI scrubber needs to read the
   observation timeline every frame; if it queued behind 30ms of inference,
   the scrubber would jank. Iris's equivalent: a `Detector` actor for
   inference and a separate observation/timeline store (relevant once
   `IrisPlayback` lands a scrubber that reads past inference results).
2. **Conversion in the render closure, not in the data model.** Storing
   normalized coords in `Detection` and denormalizing inside the SwiftUI
   `Canvas` body means resize/scrub costs zero re-inference. `CVNomalized`
   as a single `enum`-of-statics is a clean shape for Iris's `IrisOverlay`
   coordinate utility.
3. **Tuning-vs-detector setting split.** "What's detected" (requires
   tearing down a Vision request) and "what's rendered" (free) should be
   two distinct concerns in `IrisTuning`. PRVisionSpike has them in one
   `ObservableObject` but routes them differently downstream; Iris could
   make this distinction load-bearing in the API.

## Don't repeat (1–2)

1. **The monolithic-actor anti-pattern.** `VisionDetector` is one actor
   with one request property per detection kind, mutated through reset
   methods. Adding a new detector means editing the actor's interface. This
   is exactly the shape Iris's `Detector: Sendable` protocol is rebelling
   against. Avoid the "god detector" — keep `Detector` a protocol with
   per-backend conforming actors (or value types holding actor-isolated
   state) and let `DetectorPipeline` compose them.
2. **No back-pressure on the display-link path.** Spawning a `Task` per
   frame that `await`s into a slow actor will silently grow an unbounded
   queue when inference is slower than the camera/playback rate. Iris's
   `AsyncStream<Frame>` needs an explicit drop/coalesce policy (or buffer-1
   continuation) before it ships, not after.

## Opinions on Iris's M1 open questions

1. **`AsyncStream<Frame>` vs `AsyncSequence` protocol** — weak vote for
   `AsyncStream`. PRVisionSpike's asset-reader path uses `AsyncStream` and
   its playback path uses a callback typealias; the `AsyncStream` side is
   the cleaner of the two, and the callback wart only exists because
   display-link integration predates async/await. Pick `AsyncStream`,
   wrap the display-link as a stream too.
2. **Explicit actor isolation in the public API (e.g. `@CaptureActor`)** —
   weak preference for *no* global actor. Here, `VisionDetector` and
   `VisionTimestampedObservationsHolder` are each their own actor instance
   and that's enough. A `@CaptureActor` global isolating all capture state
   would have been overkill here, and Iris has no evidence yet that
   cross-instance shared state needs to be serialized.
3. **COCO JSON sidecar** — no evidence from this project. PRVisionSpike has
   no dataset-export functionality.
4. **Hot-swapping a Core ML model: tear down vs swap.** Evidence here for
   **tear down**. The reset button rebuilds the detector. Crucially,
   though, `VNCoreMLModel` is cached as `static let` on the type, so the
   "tear-down" only rebuilds the `VNCoreMLRequest`, not the model — that's
   cheap. Iris implication: if `Detector` is a reference type (`actor`),
   tear-down/replace is fine when model load is cached separately;
   detector identity needn't be stable. Lean toward **reference type with
   tear-and-replace** rather than in-place mutation API.
5. **macOS overlay parity** — no signal; iOS-only project. Notable that
   `AVPlayerLayerView` and `DisplayLinkHelper` are UIKit-only, so the
   playback path here would *not* port to macOS without changes. Iris's
   `IrisPlayback` for macOS will need to invent its own equivalent.
6. **Foundation Models** — no signal; predates Foundation Models.

## Notes & loose ends

- `VisionTimestampedObservationsHolder.timestampedObservations` is a sorted
  array with `binarySearchInsertionIndex` upserts. Implies the holder is
  expected to accumulate *all* of an asset's observations in memory for
  scrubbing. Iris equivalent would be the playback-side observation cache —
  worth deciding whether to upper-bound this.
- `Frame` in Iris should consider carrying its own timestamp explicitly
  rather than peeling it off a wrapped `CMSampleBuffer`; the `.visionTimestamp`
  extraction here is duplicated at every use site.
- `nilIfEmpty` normalization (`VisionTimestampedObservations.swift:35-38`)
  conflates "no detector ran" with "detector ran and found nothing." Iris
  should distinguish these — the empty `[Detection]` should be a real value,
  not nil-coalesced away.
- `VNDetectTrajectoriesRequest` has a subtle stateful API — re-using one
  request across many frames is how it builds trajectories. The detector
  here holds the same instance across calls, which is correct. Iris's
  `Detector.detect(_ frame:)` shape might not fit this naturally if
  `Detector` is intended to be stateless; trajectory detection needs an
  actor with cross-frame memory.
- `processSampleBuffer` swallows errors with a `print` (line 46). Production
  code in Iris should at minimum surface a typed error to the consumer.
