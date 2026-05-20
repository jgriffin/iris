# sportvision — prior-art read

**Path:** `~/dev/ml/sportvision`
**Read date:** 2026-05-20
**Priority lens:** Swift 6 strict concurrency + iOS/macOS dual target

## At a glance

SportVision is an **app**, not a library — Tuist-generated Xcode project with
two app targets (`SportVision` for iOS, `SportVisionMac` for macOS) and a
**single shared source tree** (`SportVision/**/*.swift`, see
`apple/Project.swift:57,78`). Stack: Swift 6.2 / iOS 26 / macOS 26, SwiftUI,
`@Observable`, AVFoundation playback, Vision + Core ML for YOLOv8.

**Important caveat for Iris's lens:** despite having `liveCamera` in a
`FrameSource` enum and a camera entitlement, **there is no AVCaptureSession code
in the repo.** The camera tab is a `ContentUnavailableView` placeholder
(`MainTabView.swift:59`). The whole working pipeline is *playback only* —
basically Iris's M3, not M1. So this project is excellent prior art for
**playback + detection + overlay + dual-target shape**, and silent on capture.

## Capture entrypoint

Not implemented. Spec `003-live-camera/spec.md` exists but is in Draft. The
`CameraPlaceholderView` even hard-codes "Live camera inference coming soon."
The only acknowledgement of the iOS/macOS asymmetry is in the spec text:
*"What happens when the device has no camera (macOS without webcam)? ...
suggests using video file inference instead."* That matches Iris's stance —
macOS is a no-capture target — but they never had to commit to the boundary.

**Carry-forward / non-finding:** sportvision deferred the hard problem (camera
+ macOS divergence) rather than solving it. Iris will not have that luxury at
M1.

## Frame plumbing

There is *no* domain `Frame` type for the live pipeline. The pipeline carries
**raw `CVPixelBuffer`** end-to-end:

- `VideoPlaybackService.frameStream: AsyncStream<CVPixelBuffer>`
  (`VideoPlaybackService.swift:58`)
- `InferenceService.processFrame(_ pixelBuffer: CVPixelBuffer) async throws -> [Detection]`
  (`InferenceService.swift:46`)
- Producer/consumer wiring lives in the view:
  ```swift
  for await frame in playbackService.frameStream {
      await processFrame(frame)
  }
  ```
  (`VideoInferenceView.swift:267`)

`Frame.swift` *exists* (`Models/Frame.swift`) but is a **persisted dataset
record** — `id`, `sessionId`, `imageURL`, `detections`, `modelId`, etc. — for
the (unbuilt) gallery feature. It conflates "captured-and-saved frame
+ sidecar" into one type, which is the opposite of Iris's source-agnostic
transient `Frame`.

Distribution mechanism is a single-consumer `AsyncStream` produced by a
`CADisplayLink` (iOS) / `Timer` (macOS) inside the service
(`VideoPlaybackService.swift:249-283`). The continuation is held as a stored
property and `finish()`'d on `unload()`. No back-pressure handling — frames
just drop on the floor if the consumer is slow (the `for await` loop's natural
back-pressure, since `AsyncStream` defaults to `.unbounded` but only the
*latest* yielded value matters here; producer doesn't await).

## Detection path

- **Old Vision API.** `VNCoreMLRequest` + `VNImageRequestHandler` wrapped in a
  `withCheckedThrowingContinuation` to bridge to async
  (`InferenceService.swift:58-86`). **Not** the new Swift `CoreMLRequest` /
  `ImageRequestHandler` async API that Iris's BRIEF explicitly cites as a
  reason for the iOS 26 floor. Direct anti-pattern for Iris.
- **Sendable: punted.** `InferenceService` is `@Observable final class … : @unchecked Sendable`
  (`InferenceService.swift:8`). Same pattern on `VideoPlaybackService`,
  `ModelManager`, `StorageService`, `VisualizationSettings`. Every service is
  `@unchecked Sendable` — this is the project's way of getting past strict
  concurrency without doing the design work.
- **No actor isolation on inference.** Inference runs wherever it's called.
  `latestDetections` and FPS counters are mutated from `@MainActor` via
  `await MainActor.run { ... }` (`InferenceService.swift:109-113`,
  `VideoInferenceView.swift:283`). MainActor hops happen per-frame, in the
  view's `processFrame` *and* in the service's `processFrameStream` — both
  pathways exist, fighting each other.
- **Model hot-swap = mutate in place.** `InferenceService.setModel(...)` stops
  the loop and replaces `visionModel` and `classLabels` stored properties
  (`InferenceService.swift:37-42`). Single long-lived reference-type service;
  no detector tear-down.

## Overlay coordinate-space handling (macOS parity focus)

This is the strongest part of the project for Iris and **all of it is shared
code, no platform forks**.

`DetectionOverlayView` (`Overlays/DetectionOverlayView.swift`) is a pure
SwiftUI `Canvas`:

- Computes a `displayRect` accounting for letterbox/pillarbox by comparing
  video aspect vs view aspect (`:56-82`).
- Converts Vision normalized bottom-left → SwiftUI top-left in one place:
  ```swift
  let y = displayRect.origin.y + (1 - box.origin.y - box.height) * displayRect.height
  ```
  (`:90`). The Y-flip is centralized; no caller does it.
- `.drawingGroup()` + `.allowsHitTesting(false)` for Metal-backed perf.
- Same code paints on iOS and macOS because SwiftUI's `Canvas` and `Color`
  abstract over it. **No `#if os` in this file.**

Where the platforms *do* diverge:

- **AVPlayerLayer wrapper** is forked: `UIViewRepresentable` (iOS) vs
  `NSViewRepresentable` (macOS) in `VideoPlayerView.swift:8-87`, same `struct
  VideoPlayerView` name, two definitions in a single `#if`/`#elseif` file.
  Twin implementations are 25 lines each.
- **Control overlay layout** is platform-specific (`VideoControlsOverlay.swift`
  has separate `iOSBottomControls` / `macOSBottomControls` view-builders).
  Acceptable — different idioms, not different logic.
- **CodableColor** has a `#if os(macOS)` for `NSColor` vs `UIColor` extraction
  (`CodableColor.swift:20-37`). Unavoidable.
- **VideoPlaybackService** swaps `CADisplayLink` (iOS) for a 60Hz `Timer`
  (macOS) for frame extraction (`VideoPlaybackService.swift:249-283`). This is
  internal — public API is identical.

**Takeaway for Iris's overlay-parity question:** if the overlay stays in pure
SwiftUI `Canvas` (no `UIBezierPath`/`NSBezierPath`), parity is essentially
free. The flip lives in one converter function; the renderer doesn't care.

## Dual-target shape & Swift 6 concurrency (priority lens for this project)

**Module shape.** No SwiftPM modules. Tuist defines six targets (iOS app +
macOS app + iOS tests + macOS tests + iOS UI tests + macOS UI tests), all
pointing at the *same* `SportVision/**/*.swift` source glob
(`Project.swift:57,78`). The macOS target sets `PRODUCT_MODULE_NAME=SportVision`
so generated headers match (`Project.swift:83`). One module, two apps. This is
the simplest possible answer to dual-target — and it's what lets the overlay
"just work" cross-platform.

For Iris this won't translate directly (Iris is a multi-module SwiftPM
package), but the *principle* — share source by default, fork only where the
platform forces you — is right.

**Concurrency.** No `@globalActor`. Public-API-facing isolation strategy is:

1. `AppState` is `@MainActor @Observable` (`AppState.swift:6`).
2. Services are `@Observable final class … : @unchecked Sendable`.
3. Per-frame results land on MainActor via `await MainActor.run`.

`@unchecked Sendable` is doing all the work the type system isn't. There's no
capture actor, no inference actor, no render actor. Compiles, but doesn't
*prove* anything. Iris's BRIEF question 2 (explicit `@CaptureActor` etc.) is
unresolved here by avoidance.

**Tuist insight for Iris:** the resources block
(`Project.swift:28-32`) globs `*.mlpackage` and `*.mp4` per-target, which
duplicates them into both bundles. For Iris's SwiftPM resources, the
`IrisDetection` and `IrisPlayback` test targets will want fixture resources
the same way — worth keeping shared fixtures alongside the target rather than
in a root `TestFixtures/`.

## Carry forward into Iris (2–3)

1. **SwiftUI `Canvas` overlay with a single Y-flip converter and a `displayRect`
   that accounts for aspect-fit letterboxing.** SportVision's
   `DetectionOverlayView` is ~170 lines, runs on both platforms unchanged, and
   the letterbox math (`calculateDisplayRect`) is exactly what Iris needs in
   `IrisOverlay`. Worth lifting near-verbatim, just generalized to accept any
   `[Detection]` not the project's specific `Detection`. **Add `.drawingGroup()`.**
2. **Shared `AsyncStream<Frame>` produced by playback service, consumed by a
   `for await` in the view.** Pattern is clean and minimal
   (`VideoPlaybackService.frameStream` → `VideoInferenceView.startInference`).
   For Iris, swap `CVPixelBuffer` for `Frame` and the same shape works.
3. **`#if os(iOS)` only inside implementation files for `CADisplayLink` vs
   `Timer`** — never in public API. Sportvision's `VideoPlaybackService` does
   this well: callers never see the platform fork.

## Don't repeat (1–2)

1. **`@unchecked Sendable` on every service.** SportVision marks
   `InferenceService`, `VideoPlaybackService`, `ModelManager`, `StorageService`,
   and `VisualizationSettings` all `@unchecked Sendable`. That's not Swift 6
   strict concurrency — that's silencing it. Iris's BRIEF says "if it doesn't
   compile, the design is the bug." Inference should sit on an actor (or a
   `nonisolated` value type around a `Sendable` model handle), not be a
   reference type the compiler can't reason about.
2. **The old `VNCoreMLRequest` / `VNImageRequestHandler` + continuation
   bridge.** SportVision uses `withCheckedThrowingContinuation` to bridge the
   Obj-C Vision API to async (`InferenceService.swift:58-86`). Iris's whole
   reason for the iOS 26 floor is the new Swift Vision API (`async`,
   `Sendable`, no `VN`-prefix). Don't import this pattern — use
   `ImageRequestHandler` / `CoreMLRequest` directly.

## Opinions on Iris's M1 open questions

1. **`AsyncStream<Frame>` vs `AsyncSequence` protocol** — sportvision picks
   concrete `AsyncStream<CVPixelBuffer>` and exposes it as a stored property on
   the service. It works fine for one consumer, one producer. **Weak vote for
   `AsyncStream<Frame>` directly** unless Iris foresees multiple frame-source
   adapters needing different bounded/unbounded policies — then a protocol pays
   off. SportVision never tested the multi-source case.
2. **`@CaptureActor` global actor in public API** — sportvision has *no*
   global actors and the result is `@unchecked Sendable` everywhere. **Strong
   evidence in favor of explicit actor isolation.** A `@CaptureActor` and
   `@InferenceActor` in the public API would have prevented the `await
   MainActor.run` sprinkles and the unchecked-sendable workaround.
3. **COCO JSON sidecar** — sportvision picks **YOLO** annotation format
   (`Detection.yoloAnnotationLine`, `Frame.yoloAnnotationContent`). Choice is
   explicit and per-frame, no class-mapping file written. No opinion on COCO
   vs YOLO transfers — the *signal* is that they centralized format logic on
   the `Detection` type as a derived property, which is the right shape
   regardless of format.
4. **Hot-swap: tear down vs swap instance** — sportvision **mutates in place**
   on a long-lived reference-type service (`setModel(_:info:)` on
   `InferenceService`). Works because there's exactly one service and one
   model. For Iris's multi-detector future (Vision + Core ML + Foundation
   Models implementing `Detector`), this won't scale — too easy to leak the
   wrong model into the wrong request. **Vote: value-type `Detector` per
   instance, swap the instance, no in-place mutation.**
5. **macOS overlay parity** — *solved* by sportvision: pure SwiftUI `Canvas`
   with one Y-flip converter is enough. Gestures and scrubbing diverge by
   layout (HStack vs separate transport bar), not by coordinate math. **Iris
   can adopt the same approach with confidence.**
6. **Foundation Models** — not used. No prior art either way.

## Notes & loose ends

- Tuist project layout (`apple/Project.swift` as the only Project.swift)
  separates Apple sources from Python tooling at the repo root cleanly. Iris's
  SwiftPM layout is more conventional but the precedent of an `apple/` folder
  for Apple-only sources alongside `scripts/` (Python YOLO conversion) is
  reasonable to mirror if Iris ever ships training tooling.
- `ModelManager.loadModel(_:)` compiles `.mlpackage` via
  `MLModel.compileModel(at:)` on demand and returns a `VNCoreMLModel`
  (`ModelManager.swift:184-201`). Iris will need the same flow, but on the new
  API: `MLModel(contentsOf:)` then wrap in the new `CoreMLRequest`.
- `AppState.startSettingsObservation` uses `withObservationTracking` in a
  `while let self` loop with a 100ms sleep to debounce persistence
  (`AppState.swift:85-104`). Clever but feels brittle. If Iris's `IrisTuning`
  needs persistence, prefer a dedicated `@Observable` observer that re-arms
  itself in `onChange` rather than polling.
- Cancellation: `InferenceService.stop()` cancels `processingTask` and flips
  an `isRunning` flag the `for await` loop checks. Reasonable; Iris should
  rely on Swift task cancellation through the `for await` directly rather
  than the flag.
- The `Frame` type collision (sportvision's `Frame` = persisted dataset
  record; Iris's `Frame` = transient pipeline frame) is a naming hazard. If
  Iris later adds dataset persistence in `IrisDataset`, call the saved record
  something else (`DatasetFrame`, `CapturedSample`, `LabeledFrame`).
