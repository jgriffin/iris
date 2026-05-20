# Prior-art synthesis — Iris M1 open questions

**Read date:** 2026-05-20
**Sources:**
- [`ios-videoCapture.md`](./ios-videoCapture.md) — modular SPM mirror, Combine-era, no detection.
- [`PRVisionSpike.md`](./PRVisionSpike.md) — playback + actor-based detection spike.
- [`yolo-ios-app.md`](./yolo-ios-app.md) — Ultralytics' shipping SPM package, iOS-only.
- [`sportvision.md`](./sportvision.md) — Swift 6 / iOS 26 / macOS 26 dual-target app, playback only.
- [`action-and-vision.md`](./action-and-vision.md) — Apple's WWDC20 sample, UIKit-era.

Each project was read against the four lenses (capture entrypoint, Frame plumbing, detection async, overlay coords) plus a per-project priority lens. This file rolls the per-question signal into verdicts for `BRIEF.md` §"Open questions to resolve before coding," surfaces findings that **aren't** on the M1 list yet, and inventories the carry-forward patterns and anti-patterns the reads turned up.

---

## TL;DR — verdicts on the 6 M1 questions

| # | Question | Verdict | Strength |
| --- | --- | --- | --- |
| 1 | `AsyncStream<Frame>` vs `AsyncSequence` protocol | **`AsyncStream<Frame>` as the concrete return type, exposed through an `AsyncSequence` protocol so callers bind to the protocol.** Set `bufferingPolicy: .bufferingNewest(1)` from day one. | Medium — converges across 4 of 5. |
| 2 | Explicit `@CaptureActor` global actor in public API | **Yes — build `@CaptureActor` for the capture pipeline.** Don't extend it to `Detector`. | Strong — 3 of 5 strongly pro, 1 weak negative based on a small spike. |
| 3 | COCO JSON as canonical sidecar | **Unresolved — no prior art bears.** Pick on domain merits; centralize format logic as derived properties on `Detection` regardless. | Weak. |
| 4 | Hot-swap Core ML: tear down vs swap instance; value vs reference `Detector` | **Swap the instance, never mutate in place. `Detector` is a `Sendable` protocol; stateful conformers use `actor`, stateless can be `struct`. Cache `VNCoreMLModel` *outside* the detector so swap is cheap.** | Strong on swap-instance; medium on mixed value/reference. |
| 5 | macOS overlay parity | **Solved already by prior art: pure SwiftUI `Canvas` + one centralized Y-flip + a `NormalizedGeometryConverting`-style protocol with per-source backends.** Forbid `UIDevice.current.orientation` and any `UIBezierPath`/`NSBezierPath` in overlay code. | Strong — sportvision is a working proof. |
| 6 | Foundation Models: `Detector` backend, separate `Captioner`, or both | **No direct signal. Recommendation: both — `Detector` for spatial outputs, separate `Captioner` for text. Keep `Detector`'s output associated-type-generic so it can't be hard-coded to `[Detection]`.** | Weak — recommendation from one project's hard-coded-output anti-pattern. |

---

## Verdicts in detail

### Q1 — `AsyncStream<Frame>` vs `AsyncSequence` protocol

The strongest evidence is **shape**, not type:

- **ActionAndVision** doesn't have async at all, but its delegate contract — *one consumer protocol, two producers (camera + file) behind it* — is exactly what `AsyncSequence` formalizes. `GameViewController` and `SetupViewController` literally don't care which producer is wired in.
- **PRVisionSpike** has *both* shapes in one app: an `AsyncStream<SampleBufferAndOrientation>` for the asset-reader path and a callback typealias (`onNewSampleBuffer: (...) async -> Void`) for the display-link path. The `AsyncStream` side is the cleaner of the two; the callback wart exists only because display-link integration predated async/await.
- **sportvision** picks concrete `AsyncStream<CVPixelBuffer>` and exposes it as a stored property on the service. Works fine for one producer, one consumer — never tested the multi-source case.
- **ios-videoCapture** has the same callback-shape that PRVisionSpike's display-link path has, and the same flaw: zero backpressure, `Task { … }` spawned per frame.
- **yolo-ios-app** has no stream at all — pull-driven delegate callback. No useful signal.

**Synthesis:** every project that exposed *only* `AsyncStream` (sportvision) or *only* a callback (ios-videoCapture, yolo-ios-app) ended up bound to that concrete shape; the one project with both (PRVisionSpike) showed `AsyncStream` is the cleaner of the two. **Return `AsyncStream<Frame>` but vend it through an `AsyncSequence` protocol** so a future `IrisPlayback` adapter — or a test fixture, or a Foundation Models stream — can substitute. Crucially, set `bufferingPolicy: .bufferingNewest(1)` from day one: three of the five projects have zero back-pressure, and the Task pileup is a real bug surface (see "Findings not on M1 list" below).

### Q2 — Explicit `@CaptureActor` in public API

- **ios-videoCapture** has a working blueprint: a `sessionQueue` enforced with `dispatchPrecondition(condition: .onQueue(sessionQueue))` at every mutation site. That maps one-to-one onto a `@CaptureActor` annotation in Swift 6.
- **ActionAndVision** has four hand-managed queues (capture / trajectory / video-file / main) and its bug surface is *almost entirely* "which queue am I on." Those queue boundaries are exactly where a `@CaptureActor` plus `@MainActor` overlay state would sit.
- **sportvision** is the negative example: no global actor at all, every service marked `@Observable final class … : @unchecked Sendable`, per-frame `await MainActor.run` hops sprinkled in both the view and the service. That's silencing Swift 6, not satisfying it. Strong evidence in favor of *introducing* explicit actor isolation.
- **yolo-ios-app** does the same dance differently: `@MainActor` for the view, private serial `cameraQueue: DispatchQueue` for AVCapture, `DispatchQueue.global(qos: .userInitiated)` for model load. Three isolation domains with manual hops. A unified `@CaptureActor` would be strictly cleaner.
- **PRVisionSpike** is the lone weak-negative: instance-actors (`VisionDetector`, `VisionTimestampedObservationsHolder`) were sufficient at its scale. But this was a single-app spike with no shared cross-instance state — not evidence that the larger Iris surface should follow.

**Synthesis:** introduce `@CaptureActor` for the `IrisCapture` public API. Keep it scoped to the capture pipeline; do **not** extend it to `Detector` (which has its own isolation story per Q4) or to overlay state (`@MainActor`). PRVisionSpike's split — separate `inference` actor from `result storage` actor — is the right precedent for `IrisDetection` if and when timeline storage lands (probably M3 with playback scrubbing).

### Q3 — COCO JSON as canonical sidecar

Only one project ships dataset sidecars (sportvision), and it picked YOLO. Two patterns transfer regardless:

1. **Format logic as derived properties on the canonical type.** sportvision's `Detection.yoloAnnotationLine` and `Frame.yoloAnnotationContent` keep format-specific serialization off the consumer. Iris should mirror this: `Detection.cocoEntry`, `Detection.yoloLine`, etc., as computed properties.
2. **The `ios-videoCapture` warning:** `PRMetadata` couples a domain-specific sidecar format into `VideoOverlay`. The overlay module imports `PRMetadata` and `OverlayType` hard-codes `.speedBox` / `.speed(Measurement<UnitSpeed>)`. Iris's `IrisDataset` must own dataset types; `IrisOverlay` must not depend on it.

**Synthesis:** pick COCO or YOLO based on the milestones Iris is targeting (not prior art). Whichever is canonical, ship the others as derived properties on `Detection`/`Frame`, and keep `IrisDataset` as a leaf module so the rest of the stack doesn't depend on the dataset shape.

### Q4 — Hot-swap Core ML: tear down vs swap; value vs reference `Detector`

**On hot-swap mechanics, four of five projects converge: swap the whole instance, don't mutate in place.**

- **yolo-ios-app** is the strongest evidence: `YOLOView.setModel(...)` constructs a fresh `BasePredictor` subclass via the static `create(...)` factory, assigns it to `videoCapture.predictor`, and the previous predictor's `deinit` cancels its in-flight `VNCoreMLRequest`. Zero shared mutable state across model swaps.
- **PRVisionSpike** does the same shape via a manual "Reset Detector" button that tears down and rebuilds `VisionDetectorInfo`. Crucially, the heavyweight `VNCoreMLModel` is cached as a `static let` on the type, so "tear-down" only rebuilds the lightweight `VNCoreMLRequest`.
- **ActionAndVision** punts entirely: model loaded in `viewDidAppear`, never swapped. Apple's sample has no in-place mutation pattern to copy.
- **ios-videoCapture** has no detection, but its analogous pattern — long-lived `CameraController` class with mutable `session: AVCaptureSession?` reconfigured rather than recreated — produced subtle ordering bugs around `beginConfiguration`/`commitConfiguration`. Argues *against* the in-place mutation shape.
- **sportvision** is the lone in-place mutator (`setModel(_:info:)` replaces `visionModel` and `classLabels` stored properties). Works because it has exactly one service and one model — but the pattern won't scale to Iris's multi-detector future (Vision + Core ML + Foundation Models all conforming to `Detector`).

**On value vs reference, the evidence is mixed but tilts toward "let the protocol allow both, with `actor` as the safe default."**
- **yolo-ios-app** argues hard for *reference* (`Predictor` is a protocol implemented by reference-typed `BasePredictor` subclasses holding `VNCoreMLRequest` with `[weak predictor]` completion handlers).
- **ActionAndVision** and **ios-videoCapture** lean toward *value* (no shared state needed in-flight; swap is trivial; ActionAndVision's complete absence of in-place mutation is itself a vote).
- **PRVisionSpike** surfaces the hard constraint: `VNDetectTrajectoriesRequest` is *stateful across frames* — re-using one instance is how it builds trajectories. A struct-only `Detector` protocol would force callers to thread that state externally, which is exactly what trajectory detection cannot tolerate.

**Synthesis:**
- `Detector: Sendable` is a protocol. Stateless conformers (a one-shot YOLO classifier) can be `struct`. Stateful conformers (`TrajectoryDetector`) are `actor`s.
- Hot-swap = construct a new instance and replace the reference. Never mutate in place.
- The heavyweight `VNCoreMLModel` (and its `MLModel` underlying it) is cached **outside** the detector — likely a `DetectorCache` keyed by URL+task — so a swap costs one `VNCoreMLRequest` allocation, not a model compile. yolo-ios-app's `YOLOModelCache` + `YOLOModelDownloader` is a strong reference shape (SHA256 cache key, `Documents/<package>/` directory, `.mlpackage` validation, lazy compile).

### Q5 — macOS overlay parity

**Solved by sportvision.** `DetectionOverlayView` (~170 lines, pure SwiftUI `Canvas`) runs on iOS *and* macOS unchanged with zero `#if os` in the file. The recipe:

1. Compute a `displayRect` accounting for letterbox/pillarbox by comparing video aspect to view aspect.
2. Convert Vision normalized bottom-left → SwiftUI top-left in *one place*: `let y = displayRect.origin.y + (1 - box.origin.y - box.height) * displayRect.height`. No caller does the flip.
3. `.drawingGroup()` for Metal-backed perf, `.allowsHitTesting(false)` so the overlay doesn't intercept gestures.

Augment that with **ActionAndVision's `NormalizedGeometryConverting` protocol** — two implementations, one delegating to `AVCaptureVideoPreviewLayer.layerRectConverted(...)`, the other doing the math against `AVPlayerLayer.videoRect`. Same converter API, source-aware backend.

**Forbidden:** `UIDevice.current.orientation`-based math (yolo-ios-app's anti-pattern — `~150 lines of orientation-aware arithmetic, separate code paths for portrait vs landscape`, will never port to macOS). The coordinate-space module takes view bounds + a known transform; it does *not* take a global device orientation. Also forbidden in overlay: `UIBezierPath`, `NSBezierPath`, `CALayer.frame` math. SwiftUI `Canvas` and `Path` cover everything Iris needs.

ios-videoCapture's `VideoOverlay` is a soft caution: the module declares macOS support in `Package.swift` but imports `UIKit` throughout. *Declaring* support without implementing it produces a target that builds only because metadata says so. Iris's `IrisOverlay` should compile and **render correctly** on both platforms from M3 day one — verify with a `#Preview` on each.

### Q6 — Foundation Models scope

No project uses Foundation Models. The closest signal is negative: **yolo-ios-app's `Predictor` protocol hard-codes `YOLOResult` (a struct full of box/mask/keypoint/OBB optionals) as the output type**, which means a `Captioner` couldn't conform without a parallel protocol or a `text` optional bolted on.

**Recommendation:**
- Two protocols: `Detector` (spatial output — `Detection` with bbox/keypoints/mask) and `Captioner` (text output — caption string + region of interest + confidence). They share a `Frame` input and a common lifecycle.
- Keep `Detector`'s output associated-type-generic (`associatedtype Output` constrained to a `DetectionOutput` protocol) so a future fused detector-captioner backend can return a sum type without rewriting the protocol.

---

## Findings not on the M1 list (additions to BRIEF / M1 scope)

These came out of the reads and aren't currently in `BRIEF.md`'s open-questions list. Worth adding before M1 plans lock.

1. **`Detector.warmup()` on the protocol.** ActionAndVision's `warmUpVisionPipeline()` (`Common.swift:175`, ~12 lines) runs every Vision request once against a bundled image at startup to dodge first-frame stalls. Real production wart; cheap to prevent. Add to `Detector`.
2. **Letterbox / pillarbox alignment between view bounds and video rect.** Both ActionAndVision (`additionalSafeAreaInsets` dance, `RootViewController.swift:104-116`) and sportvision (`displayRect`) handle this. The naive overlay-on-view-bounds approach mis-aligns boxes any time the video isn't aspect-filling. Add to `IrisOverlay` scope.
3. **Back-pressure policy on `AsyncStream<Frame>`.** Three of five projects (PRVisionSpike, sportvision, ios-videoCapture) ship with zero back-pressure → Tasks pile up in the actor mailbox unboundedly when inference is slower than the frame rate. Set `.bufferingNewest(1)` (or equivalent) from day one and ship the policy as part of the `Frame` stream contract, not as an internal optimization.
4. **Stateful detector accommodation.** `VNDetectTrajectoriesRequest` is stateful across frames — re-using the same request instance is *how* it builds trajectories. The `Detector` protocol shape must allow cross-frame memory. (Drives the `actor`-or-`struct` decision in Q4.)
5. **`Frame` naming hazard.** sportvision's `Frame` is a *persisted dataset record* (`id`, `sessionId`, `imageURL`, `detections`). If `IrisDataset` later persists frames, the saved-record type should be named distinctly — `DatasetFrame`, `LabeledFrame`, `CapturedSample` — to keep the transient pipeline `Frame` clean.
6. **`MLFeatureProvider`-as-tuning-handle.** yolo-ios-app's `ThresholdProvider: MLFeatureProvider` (`ThresholdProvider.swift`) lets `IrisTuning` push live conf/IoU/NMS knobs into a *running* `VNCoreMLModel` via a tiny feature dict. No detector teardown, no model reload. Relevant for the M4 tuning milestone, but worth flagging now so `IrisDetection`'s API doesn't preclude it.
7. **Two-actor split: inference vs result storage.** PRVisionSpike's `VisionDetector` actor + `VisionTimestampedObservationsHolder` actor split is the model for "scrubber needs to read the timeline without queuing behind a 30ms inference call." Becomes load-bearing at M3 when `IrisPlayback` lands a scrubber.
8. **Pre-compute both `xywh` and `xywhn` on `Detection`.** yolo-ios-app's `Box` carries both image-space and normalized rects. Overlay code picks whichever fits without needing the input frame size. Iris's `Detection` should follow suit.
9. **Frame timestamp as a first-class field, not extracted from `CMSampleBuffer`.** PRVisionSpike duplicates the `.visionTimestamp` extraction at every use site. Iris's `Frame { pixelBuffer, orientation, timestamp, … }` should make timestamp explicit on the struct.
10. **Distinguish "no detector ran" from "detector ran, found nothing."** PRVisionSpike's `nilIfEmpty` conflates them. Iris should make the empty `[Detection]` a real value, not nil-coalesced away.

---

## Carry-forward patterns (rolled up)

Patterns explicitly worth lifting into Iris with their source notes:

- **SwiftUI `Canvas` overlay with centralized Y-flip + `displayRect`** — sportvision `DetectionOverlayView.swift`. Adopt near-verbatim in `IrisOverlay`.
- **`NormalizedGeometryConverting` protocol with per-source backends** — ActionAndVision. `IrisOverlay` owns this seam publicly.
- **Two-actor split: inference vs result storage** — PRVisionSpike. Apply when `IrisPlayback` scrubbing arrives.
- **Static `VNCoreMLModel` cache outside the detector** — PRVisionSpike + yolo-ios-app's `YOLOModelCache`. Iris's `DetectorCache`.
- **`MLFeatureProvider` as live tuning handle** — yolo-ios-app `ThresholdProvider`. For `IrisTuning`.
- **URL → SHA-key cache → compile → load model lifecycle** — yolo-ios-app `YOLOModelDownloader`. For M6.
- **`Dummy`/`Mock` conformers for SwiftUI previews** — ios-videoCapture `DummyCameraController`. Apply to every Iris protocol so visual previews don't need permissions/models/files.
- **`videoNaturalSize` + `videoRect` + single `CATransform3D` for CALayer-based overlays** — ios-videoCapture `OverlayContext`/`OverlayHostLayer`. Backup for any case where SwiftUI Canvas isn't enough.
- **`CGRect.Location` / `LocationAtLocation` anchor-ratio primitive** — ios-videoCapture `VideoUtils`. Drop into `IrisOverlay`.
- **Unified capture/playback contract** — ActionAndVision's source-agnostic delegate. Validates Iris's `Frame` plan.
- **Warmup pass at startup** — ActionAndVision `warmUpVisionPipeline()`. Add `Detector.warmup()`.
- **Real-fixture tests with a `SKIP_MODEL_TESTS` toggle** — yolo-ios-app. Aligns with Iris's CLAUDE.md rule on real fixtures.

---

## Anti-patterns to avoid (rolled up)

- **God-class views/controllers** — `CameraController` (ios-videoCapture, ~15 Combine subjects + raw AVKit/UIKit in public protocols), `YOLOView` (yolo-ios-app, 1,412 LOC conflating capture/predictor/sliders/toolbar/box-rendering/zoom/photo). Iris's 6-target split exists to prevent this.
- **`@unchecked Sendable` as the strict-concurrency workaround** — sportvision (every service), yolo-ios-app (most predictors). Silencing the checker, not satisfying it.
- **Public API leaking AVFoundation/UIKit types** — ios-videoCapture exposes `AVCaptureDevice`, `AVCaptureVideoPreviewLayer`, `AVCaptureVideoOrientation`, `UIPinchGestureRecognizer`, `AnyPublisher`. Consumers can't write a unit test or a macOS build without dragging the whole stack in. Iris must vend Iris-owned value types and keep AVKit behind the seam.
- **Hand-managed `DispatchQueue`s with ad-hoc `DispatchQueue.main.async` hops in capture delegates** — ActionAndVision (4 queues), yolo-ios-app (3 isolation domains). `@CaptureActor` + `@MainActor` + `AsyncStream` collapses this into compiler-checked boundaries.
- **`UIDevice.current.orientation` in overlay math** — yolo-ios-app. Overlay code must take view geometry, never a global device state.
- **No back-pressure on the frame stream** — PRVisionSpike, sportvision, ios-videoCapture. Tasks pile unboundedly.
- **Monolithic "god detector" with hard-coded sub-requests** — PRVisionSpike `VisionDetector` (one actor with one property per detection kind, mutated through reset methods). Adding a fifth detector means editing the actor.
- **Callback-based async + KVC hacks + `@preconcurrency` imports** — yolo-ios-app. Symptoms of being stuck on a Swift 5.5-era idiom under Swift 6.
- **`GKStateMachine` singleton + `NSNotification` broadcast for app state** — ActionAndVision. `@Observable` enum + SwiftUI bindings replaces 160 LOC.
- **Bundling overlay-only sidecar formats into shared modules** — ios-videoCapture's `VideoOverlay` depending on `PRMetadata` and `OverlayType` hard-coding `.speedBox`. Keep `IrisDataset` as a leaf module.
- **Aspirational cross-platform support without implementation** — yolo-ios-app's README claims iOS/iPadOS/macOS/tvOS/watchOS, reality is iOS 16-only with zero `#if os` guards. ios-videoCapture's `VideoOverlay` is iOS-only but declares cross-platform. Iris's macOS targets must actually run on macOS from M3.
- **Old `VNCoreMLRequest` + `withCheckedThrowingContinuation` bridge** — sportvision. The whole reason for Iris's iOS 26 floor is the new Swift Vision API; use it directly.
- **`print(error)` instead of a `Logger` seam** — yolo-ios-app, PRVisionSpike. Expose `os.Logger` from day one.

---

## Still open after this read

These M1 questions weren't resolved by prior art and need to be decided on Iris's own merits:

- **Q3 — COCO vs YOLO vs Pascal VOC** as the canonical sidecar. Pick based on what training pipelines Iris targets; pattern-wise, derived properties on `Detection` give optionality regardless.
- **Q6 — Foundation Models scope and shape.** Recommendation above (both protocols), but no implementation reference to model against. Will need a spike in M6.
- **Whether `IrisCapture` and `IrisPlayback` should literally share a `Source` protocol** or stay as two modules with parallel public surface. Prior art validates source-agnostic *downstream* (`Detector`/`IrisOverlay` see only `Frame`), but doesn't decide whether the *upstream* shares a protocol.
- **`DetectorCache` ownership.** yolo-ios-app's singleton cache is `public` — the note flagged it as a collision risk for multiple consumers. Iris's cache should be an injectable instance; revisit at M6.
- **Cancellation policy across the pipeline.** Each project handles cancellation differently (or not at all). Pick one: cancel-by-`for await`-task vs cancel-by-flag vs cancel-by-deinit. Spec it before M1 capture lands.
