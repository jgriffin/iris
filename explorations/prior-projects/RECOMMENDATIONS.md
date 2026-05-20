# Recommendations from prior art

**Read date:** 2026-05-20
**Source:** distilled from the five per-project notes in this folder. Full evidence chain lives in [`SYNTHESIS.md`](./SYNTHESIS.md); this file is the action-oriented short version, organized by *patterns to use* and *pointers to specific code* worth opening before writing Iris's equivalent.

---

## Principles to adopt (project-wide)

1. **macOS parity is a *principle*, not a target.** Every file in `IrisDetection`, `IrisOverlay`, `IrisPlayback`, `IrisTuning`, `IrisDataset` should compile *and render correctly* on iOS and macOS from the moment it's written. Don't add macOS later. Two prior projects (ios-videoCapture's `VideoOverlay`, yolo-ios-app's package metadata) declare cross-platform support but ship UIKit-only implementations — those targets exist only because metadata says so. The cost of fixing this retroactively is much higher than the cost of doing it right; sportvision proves with a 170-line `Canvas` overlay that cross-platform is essentially free if you stay in SwiftUI.

2. **Swap the instance, never mutate in place.** Hot-swapping a Core ML model, a detector, a capture device — always construct a fresh instance and replace the reference, never reach into an existing instance to mutate it. Strongest evidence: yolo-ios-app's `YOLOView.setModel(...)` (just builds a new `BasePredictor` and assigns it). Counter-example: sportvision's `InferenceService.setModel(...)` mutates stored properties, which works only because there's exactly one service — won't scale to Iris's multi-detector future.

3. **`@CaptureActor` global actor in `IrisCapture`'s public API.** Working blueprint exists in ios-videoCapture: every capture-mutating call site already uses `dispatchPrecondition(condition: .onQueue(sessionQueue))`. That maps 1:1 onto `@CaptureActor`. The negative cases (sportvision's `@unchecked Sendable` everywhere, yolo-ios-app's three isolation domains with manual hops, ActionAndVision's four hand-managed queues) all produced exactly the "which queue am I on?" bug surface that strict concurrency exists to prevent. Do not extend `@CaptureActor` to `Detector` — that has its own actor story.

4. **Strict concurrency without escape hatches.** Forbid `@unchecked Sendable`, `@preconcurrency import`, `withCheckedThrowingContinuation` bridges over the Obj-C Vision API, and KVC hacks like `config.setValue(1, forKey: "experimentalMLE5EngineUsage")`. Iris's iOS 26 floor + the new Swift Vision API means none of these workarounds should be needed. When a Sendable issue surfaces, fix the design.

5. **Public API vends Iris-owned value types — no AVFoundation/UIKit leak.** ios-videoCapture's `CameraControlling` exposes `AVCaptureDevice`, `AVCaptureVideoPreviewLayer`, `AVCaptureVideoOrientation`, `UIPinchGestureRecognizer`, and `AnyPublisher` in its public protocols. Consumers cannot use it without importing the whole stack, and macOS builds are mechanically impossible. Iris's public surface should be `Iris.Camera`, `Iris.Orientation`, etc. — AVKit lives behind seams.

---

## Patterns to lift (with pointers)

### Async + concurrency

- **`AsyncStream<Frame>` exposed via an `AsyncSequence` protocol.** Return the concrete stream from `IrisCapture.frames` / `IrisPlayback.frames`, but type both publicly as `some AsyncSequence<Frame>` so a future test fixture or Foundation Models source can substitute. Working `AsyncStream` use: [PRVisionSpike `AssetSampleBufferReader.readSampleBuffers()`](../../../../PR/PRVisionSpike) and [sportvision `VideoPlaybackService.frameStream`](../../../sportvision/apple/SportVision/Services/VideoPlaybackService.swift) (line 58). **Set `bufferingPolicy: .bufferingNewest(1)`** as part of the contract — three of five projects have zero back-pressure and silently grow unbounded Task queues when inference lags.

- **`@CaptureActor` blueprint.** Look at ios-videoCapture `CameraController+inputsAndOutputs.swift:14` and `+movieFileOutput.swift:19` — every mutation site already declares its serial-queue invariant via `dispatchPrecondition`. Convert each `dispatchPrecondition(.onQueue(sessionQueue))` into a `@CaptureActor` annotation; that's the migration.

- **Two-actor split for playback scrubbing.** Inference and result storage on *different* actors so the UI's read path doesn't queue behind a 30ms inference call. The rationale is unusually well-written in the code itself — [PRVisionSpike `VisionTimestampedObservationsHolder.swift:10-14`](../../../../PR/PRVisionSpike/PRVisionSpike/VisionTimestampedObservationsHolder.swift) has the design comment. Applies at M3, not M1, but the seam should be in `IrisDetection`'s API from day one.

### Overlay & coordinate math

- **SwiftUI `Canvas` overlay with one centralized Y-flip.** Cross-platform for free. Lift sportvision's [`DetectionOverlayView.swift`](../../../sportvision/apple/SportVision/Views/Overlays/DetectionOverlayView.swift) near-verbatim into `IrisOverlay`. The flip is one line (~:90); the letterbox/pillarbox math is `calculateDisplayRect` (~:56-82); `.drawingGroup()` is the Metal-backed-perf trick. Zero `#if os` in the file. ~170 lines total.

- **`NormalizedGeometryConverting` protocol with per-source backends.** ActionAndVision's `Views/VideoOutputViews.swift` declares a converter protocol implemented two ways: one delegates to `AVCaptureVideoPreviewLayer.layerRectConverted(...)` (preview-layer-backed), the other does aspect-fit math against `AVPlayerLayer.videoRect` (video-rect-backed). `IrisOverlay` should own a public converter API of the same shape; callers should never touch a flip transform.

- **`videoNaturalSize + videoRect + single CATransform3D` for any CALayer fallback.** ios-videoCapture's [`OverlayContext.swift:28-90`](../../../../PR/ios-videoCapture/Sources/VideoOverlay/overlay/manager/OverlayContext.swift) and [`OverlayHostLayer.swift:65-122`](../../../../PR/ios-videoCapture/Sources/VideoOverlay/overlay/hostLayer/OverlayHostLayer.swift) — all overlay children lay out in source-pixel space; one transform scales into the on-screen rect. Useful backup if `Canvas` ever isn't enough.

- **`CGRect.Location` / `LocationAtLocation` anchor-ratio primitive** for "anchor at ratio + offset" with a `flipY` knob: [ios-videoCapture `VideoUtils/utils/CGRect+location.swift:23-131`](../../../../PR/ios-videoCapture/Sources/VideoUtils/utils/CGRect+location.swift). Drop in verbatim.

### Detection & model lifecycle

- **`Detector: Sendable` protocol, mixed conformers.** Stateless detectors are `struct`. Stateful ones (anything reusing a request across frames — `VNDetectTrajectoriesRequest` is the canonical example, [PRVisionSpike `VisionDetector.swift:14`](../../../../PR/PRVisionSpike/PRVisionSpike/VisionDetector.swift)) are `actor`. The protocol shape must not force value semantics or trajectory detection breaks.

- **Cache `VNCoreMLModel` outside the detector.** PRVisionSpike's [`VisionDetector.swift:51-61`](../../../../PR/PRVisionSpike/PRVisionSpike/VisionDetector.swift) holds models as `static let` so detector tear-down only rebuilds the lightweight `VNCoreMLRequest`, not the model. Iris should formalize this as a `DetectorCache` (instance, not singleton — yolo-ios-app's singleton cache is flagged as a collision risk).

- **URL → SHA-key cache → compile → load.** [yolo-ios-app `YOLOModelCache` + `YOLOModelDownloader`](../../../yolo-ios-app/Sources/YOLO/) is genuinely well-shaped: SHA256 of `(url, task)` as cache key, `Documents/<package>/`, `.mlpackage` validation via `Manifest.json`, lazy compile via `MLModel.compileModel`. The shape transfers to M6.

- **`Detector.warmup()` on the protocol.** [ActionAndVision `Common.swift:175`](../../../../pocketRadar/BuildingAFeatureRichAppForSportsAnalysis/ActionAndVision/Common.swift) — `warmUpVisionPipeline()` runs every Vision request once against a bundled image at startup to dodge first-frame stalls. 12 lines, prevents a real production wart. Add to `Detector`.

- **`MLFeatureProvider` as live tuning handle.** [yolo-ios-app `ThresholdProvider.swift`](../../../yolo-ios-app/Sources/YOLO/ThresholdProvider.swift) — push conf/IoU/NMS into a *running* `VNCoreMLModel` via a tiny feature dict; no detector teardown, no model reload. Relevant for M4 (`IrisTuning`) but design `IrisDetection`'s API now so it isn't precluded.

### Frame & detection types

- **`Frame` carries timestamp as a first-class field**, not extracted from `CMSampleBuffer.presentationTimeStamp` per use site. PRVisionSpike duplicates the `.visionTimestamp` extraction at every use site; symptom of an under-typed `Frame`.

- **`Detection` carries both `xywh` and `xywhn`** (image-space and normalized rects) pre-computed at detection time. [yolo-ios-app `YOLOResult.swift:73`](../../../yolo-ios-app/Sources/YOLO/YOLOResult.swift) does this; means overlay code picks whichever fits its current geometry without knowing input frame size.

- **Per-detection-type wrappers store normalized values, denormalize in render.** PRVisionSpike stores normalized coords in `RecognizedObjectRectangle` / `HumanBodyPoints` / `TrajectoryPoints` and denormalizes inside the SwiftUI `Canvas` body. Resize and scrub cost zero re-inference.

- **Distinguish "no detector ran" from "detector ran, found nothing."** PRVisionSpike's `nilIfEmpty` conflates them. The empty `[Detection]` should be a real value.

### Testability

- **`Dummy`/`Mock` conformers for every protocol.** [ios-videoCapture `DummyCameraController.swift:14`](../../../../PR/ios-videoCapture/Sources/CameraController/controller/DummyCameraController.swift) provides a no-op `CameraControlling` so SwiftUI previews of the whole stack render without permission prompts. Apply to every Iris protocol — `MockDetector`, `MockCaptureSource`, `MockFrameSource` — so visual previews work without cameras, files, or models.

- **Real fixtures over mocks, with a `SKIP_MODEL_TESTS` toggle.** [yolo-ios-app `Tests/YOLOTests/`](../../../yolo-ios-app/Tests/YOLOTests/) has fixture resources processed at build time and a `SKIP_MODEL_TESTS = true` flag so CI runs without unredistributable `.mlpackage`s. Matches Iris's CLAUDE.md rule on real fixtures.

---

## Things to add to M1 scope (not in `BRIEF.md` today)

Worth proposing as updates before M1 plans lock:

1. `Detector.warmup()` on the protocol.
2. Letterbox/pillarbox alignment between view bounds and video rect, owned by `IrisOverlay`.
3. Back-pressure (`.bufferingNewest(1)` or equivalent) as part of the public `Frame` stream contract.
4. Stateful-detector accommodation (cross-frame memory; trajectory detection is the canonical case).
5. `Frame.timestamp` as a first-class field on the struct.
6. Distinguish "no detector ran" from "ran and found nothing" — empty result is a real value, not nil-coalesced.
7. Rename rule: if `IrisDataset` later persists frames, the saved-record type is `DatasetFrame` / `LabeledFrame` / `CapturedSample` — *never* `Frame`. (sportvision's `Frame.swift` is a persisted dataset record and collides with the transient pipeline `Frame` concept.)

---

## Interesting tangents worth peeking at

Code that didn't land in the carry-forward list but is genuinely interesting:

- **`AVSynchronizedLayer` for overlay-playback sync.** [ios-videoCapture `SyncedOverlayHost.swift:10`](../../../../PR/ios-videoCapture/Sources/VideoOverlay/overlay/hostLayer/SyncedOverlayHost.swift) — keeps overlay animations in sync with `AVPlayerItem.currentTime()` without polling. Iris will likely drive animation off `Frame` PTS directly, but this is worth knowing exists if PTS-driven animation gets fiddly.

- **`AVPlayerLayer.videoRect` via KVO + Combine `@Published`.** [ios-videoCapture `AVPlayerLayerView+UIView.swift:52-58`](../../../../PR/ios-videoCapture/Sources/VideoOverlay/overlay/playerLayerView/AVPlayerLayerView+UIView.swift) — the trick for getting the actual on-screen video rect (after aspect-fit) reactively. Iris will need an equivalent in SwiftUI (probably via `GeometryReader` + `.onChange(of: videoSize)`).

- **`callAsFunction` Python-style detector ergonomic.** [yolo-ios-app `YOLO.swift:155`](../../../yolo-ios-app/Sources/YOLO/YOLO.swift) — `YOLO("name", task: .detect)(uiImage)` works because `YOLO` has `callAsFunction`. Genuinely nice for single-shot inference; worth considering for Iris's `Detector` one-shot API alongside the streaming one.

- **Sorted-array timeline with binary-search upserts.** PRVisionSpike's `VisionTimestampedObservations` stores all observations in a sorted array with `binarySearchInsertionIndex` for inserts — implies the holder is sized for an entire asset's observations in memory for scrubbing. Iris's M3 playback-side observation cache needs to decide on an upper bound; this is the reference.

- **`additionalSafeAreaInsets` for overlay-to-video-rect alignment.** [ActionAndVision `RootViewController.swift:104-116`](../../../../pocketRadar/BuildingAFeatureRichAppForSportsAnalysis/ActionAndVision/RootViewController.swift) — pads the overlay VC so its safe area matches the video rect, not the screen. Iris's SwiftUI equivalent is `.safeAreaInset(edge:)` or a custom layout; either way, the concern is real.

- **Tuning-vs-detector setting split.** PRVisionSpike routes "what's detected" (requires detector reset) and "what's rendered" (free) through one `ObservableObject` but applies them at *different* downstream stages. Worth making this distinction load-bearing in `IrisTuning`'s public API.

- **Shared-source-tree dual-target.** [sportvision `apple/Project.swift:57,78`](../../../sportvision/apple/Project.swift) — both iOS and macOS targets glob `SportVision/**/*.swift`; macOS target sets `PRODUCT_MODULE_NAME=SportVision`. Doesn't translate to SwiftPM directly, but the principle "share by default, fork only where the platform forces you" is the right default.

---

## Anti-patterns (short list — full discussion in `SYNTHESIS.md`)

Symptoms that should immediately raise a red flag in Iris PRs:

- God-class views/controllers (ios-videoCapture `CameraController`, yolo-ios-app's 1,412-LOC `YOLOView`).
- `@unchecked Sendable` on a service (sportvision pattern — *silencing* strict concurrency, not satisfying it).
- AVFoundation/UIKit types in public API (ios-videoCapture).
- Hand-managed `DispatchQueue`s + ad-hoc `DispatchQueue.main.async` hops inside delegates (ActionAndVision, yolo-ios-app).
- `UIDevice.current.orientation` anywhere in overlay math (yolo-ios-app — guarantees macOS won't work).
- Combine `Subject`/`Publisher` in public API (ios-videoCapture — won't survive Swift 6 cleanly).
- `print(error)` instead of an `os.Logger` seam (yolo-ios-app, PRVisionSpike).
- Cross-platform claim in `Package.swift` / README without `#if os` guards in implementation (yolo-ios-app — iOS 16 only despite "iOS+iPadOS+macOS+tvOS+watchOS" copy).
- `GKStateMachine` singleton + `NSNotification` broadcast for app state (ActionAndVision).
- Monolithic "god detector" with hard-coded sub-request properties (PRVisionSpike's `VisionDetector`).

---

## Still open

Not resolved by prior art; needs decision before locking M1 plans:

- COCO vs YOLO vs Pascal VOC as canonical sidecar.
- Foundation Models scope (recommendation: two protocols, `Detector` + `Captioner`).
- Whether `IrisCapture` and `IrisPlayback` literally share a `Source` protocol upstream, or just feed the same `Frame` downstream.
- `DetectorCache` ownership (injectable instance, definitely; lifecycle TBD).
- Cancellation policy across the pipeline (cancel-by-`for await`-task vs flag vs `deinit`). Pick one and spec it.

---

*This file is scoped to recommendations from the in-house prior-art reads. Recommendations from the external Swift package ecosystem live in [`../swift-ecosystem/RECOMMENDATIONS.md`](../swift-ecosystem/RECOMMENDATIONS.md). The cross-cutting rollup that synthesizes both is at [`../RECOMMENDATIONS-PRIOR-ART.md`](../RECOMMENDATIONS-PRIOR-ART.md).*

