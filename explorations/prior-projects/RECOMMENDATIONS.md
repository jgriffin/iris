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

# Recommendations from external Swift packages (added 2026-05-20)

Source: deep reads of 5 shortlisted external packages — full notes under [`explorations/swift-ecosystem/`](../swift-ecosystem/). Headline scan and per-package verdicts in [`SHORTLIST.md`](../swift-ecosystem/SHORTLIST.md). This section folds the actionable findings into recommendations, including resolutions for several items previously in "Still open."

## Per-package verdicts

| Package | Notes | Verdict | One sentence |
|---|---|---|---|
| Apple AVCam SwiftUI sample | [apple-avcam.md](../swift-ecosystem/apple-avcam.md) | **Borrow** | Mirror `CaptureService` line-for-line for session lifecycle, custom serial executor, `PreviewSource` indirection, `OutputService` extensibility — diverge to add `AsyncStream<Frame>` and drop Combine. |
| NextLevel | [nextlevel.md](../swift-ecosystem/nextlevel.md) | **Study then diverge** | Lift `SendablePixelBuffer` shape + `recording-session actor / capture-class queue` split; reject the singleton + delegate-only API. |
| MijickCamera | [mijick-camera.md](../swift-ecosystem/mijick-camera.md) | **Study then diverge** | Borrow `UIViewRepresentable` + `@MainActor` Observable manager + baked-in permissions; drop the `MCamera` app-shell + `.startSession()` sentinel + buried preview. |
| Kadr | [kadr.md](../swift-ecosystem/kadr.md) | **Borrow structurally** | Companion-package split (separate repos), `@unchecked Sendable + NSLock` invariant pattern, surface-then-engine tier rollout transfer; DSL shape and coordinate vocabulary don't. |
| PrivateFoundationModels | [private-foundation-models.md](../swift-ecosystem/private-foundation-models.md) | **Study then diverge** | Direct pattern transfer to `Detector`/`Captioner` shape (concrete `AsyncThrowingStream`, additive default-impl multimodal, separate-protocol-per-IO-shape, `prewarm`/`availability`/`modelIdentifier`); don't take as a runtime dep. |

## Headline updates to the BRIEF.md plan

1. **Package-layout fork.** Current BRIEF.md models the six Iris modules as targets within a single `iris` package. **Kadr's lived experience says core single-target + adapter packages as separate repos is the better unit.** Iris's `IrisOverlay`, `IrisDataset`, `IrisTuning` could each be their own Swift package (`iris-overlay`, `iris-dataset`, `iris-tuning`) depending on a core `iris` (holding `IrisCapture` + `IrisPlayback` + `IrisDetection` + the `Frame` / `Detection` / `Detector` types). Benefits: per-package platform requirements (capture stays iOS-only without polluting core), independent semver, third-party deps confined to adapter that needs them. **This is an architectural decision worth making before M1 plans lock.** Marked as a new open question below.
2. **Q6 resolved: two protocols, not one.** PFM's `EmbeddingBackend` / `LanguageModelBackend` split codifies the principle: separate protocols when I/O shapes don't overlap. Detection (`image → [Detection]`) and captioning (`image → text`) have non-overlapping outputs. **Iris ships `Detector` and `Captioner` as separate protocols**; VLM backends conform to both.
3. **`@CaptureActor` shape is concrete.** Apple AVCam's `CaptureService` uses `nonisolated unownedExecutor: UnownedSerialExecutor` bound to a `DispatchSerialQueue`, with `nonisolated let previewSource` as the only opening in the actor wall. This is *the* working blueprint — Iris's `IrisCapture` actor should mirror it.
4. **`@preconcurrency import AVFoundation` is acceptable.** Apple's own AVCam uses it. So does NextLevel. Kadr documents `@unchecked Sendable + NSLock + load-bearing invariant doc-comment` as the canonical pattern for AVFoundation/Vision/CoreML types that aren't Sendable-clean. The realistic Swift 6 strict-concurrency story is not "all reference types become actors" — it's "use the escape hatches deliberately, document the invariants."

## New principles (add to project-wide list)

- **Companion-package split.** Core single-target package + adapter packages as separate repos with one-way `from: "x.y.z"` deps on core (Kadr's pattern, per-adapter platform floors allowed).
- **Drop-in source compat with Apple types where possible.** PFM re-exports nested namespaces (`LanguageModelSession.Response` typealiases) so the same code compiles against either `import PrivateFoundationModels` or `import FoundationModels`. For Iris: if a `Detector.detect(in:)` shape can match Apple's `*Request` calling convention, do so.
- **Additive protocol methods with default impls instead of versioned protocols.** PFM grows `LanguageModelBackend` over time by adding methods with sensible defaults so existing conformers keep compiling. Iris should follow the same pattern for `Detector` capability growth (stateful, multimodal, batch).

## New patterns to lift (with pointers)

### Async + concurrency
- **`actor CaptureService` + custom `DispatchSerialQueue` serial executor** — `nonisolated var unownedExecutor: UnownedSerialExecutor { sessionQueue.asUnownedSerialExecutor() }`. [Apple AVCam `CaptureService.swift:14`](../swift-ecosystem/apple-avcam.md).
- **`@preconcurrency import AVFoundation`** as the Apple-blessed escape hatch when AVFoundation isn't Sendable-clean.
- **`@unchecked Sendable + NSLock + documented invariant`** for `AVCaptureSession`/`AVAssetExportSession`/`VNRequest`/`MLModel` on macOS. [Kadr `CancellationToken.swift` pattern](../swift-ecosystem/kadr.md).
- **`SendablePixelBuffer` / `UnsafeSendableDictionary` immutable wrappers** for crossing actor boundaries with framework types. [NextLevel `NextLevel.swift:38-64`](../swift-ecosystem/nextlevel.md). Iris's `Frame` envelope mirrors exactly this shape — internal `@unchecked Sendable` with explicit doc-comment reasoning, not `@preconcurrency` leaking through the public surface.
- **`SendableMetatype` on a `@MainActor` protocol** so the metatype can cross isolation. [Apple AVCam `Model/Camera.swift`](../swift-ecosystem/apple-avcam.md). Swift 6.2 idiom worth lifting.
- **Recording-session as `actor`, capture-root as queue-backed class.** The capture root must be `AVCaptureVideoDataOutputSampleBufferDelegate` (NSObject lineage) — it stays class-typed with serial-queue discipline. The mutable per-session state (clips, transcript, dataset capture buffer) goes in an `actor`. [NextLevel's load-bearing split](../swift-ecosystem/nextlevel.md). Maps to Iris: `IrisCapture.Session` as queue-backed class; `IrisDataset` writer as `actor`.

### Public-API & extensibility
- **`PreviewSource: Sendable` / `PreviewTarget` indirection.** Don't expose `AVCaptureSession` to SwiftUI — give consumers a `Sendable` source that connects to a private target. [Apple AVCam `Views/CameraPreview.swift:11`](../swift-ecosystem/apple-avcam.md). The cleanest UIKit-bridge boundary in the prior art.
- **`OutputService` protocol as extensibility seam.** Iris's `FrameStreamCapture` and a `Detector`-fronted `VisionCapture` both become `OutputService` conformers managed by the capture actor. [Apple AVCam `DataTypes.swift:152`](../swift-ecosystem/apple-avcam.md).
- **`Camera` view-model protocol** — `public protocol Camera: AnyObject, SendableMetatype, @MainActor` with all `async` methods + getters, no AVFoundation in the surface. [Apple AVCam `Model/Camera.swift`](../swift-ecosystem/apple-avcam.md). Almost exactly the shape Iris's `IrisCapture.Source` should expose to apps.
- **`UIViewRepresentable` with `static func == { true }`** to suppress accidental rebuilds. [MijickCamera `CameraView+Bridge.swift:41`](../swift-ecosystem/mijick-camera.md). Cheap trick, prevents real bugs.
- **Permissions baked into `session.start() async throws`** with typed errors surfaced as session state. [MijickCamera `CameraManager+PermissionsManager`](../swift-ecosystem/mijick-camera.md). Adopt as `IrisCapture.SessionState.{idle, requestingPermission, permissionDenied(MediaType), running, failed(Error)}`.

### Detection
- **`Detector` protocol shape derived from PFM's `LanguageModelBackend`:**
  - `var availability: Detector.Availability { get }` — enum with `.deviceNotEligible / .modelNotReady / .custom`
  - `var modelIdentifier: String { get }` — for telemetry and dataset sidecar
  - `func prewarm() async`
  - `func detect(in frame: Frame) async throws -> [Detection]`
  - `func detectStream(in frame: Frame) -> AsyncThrowingStream<DetectionDelta, Error>` — for trajectory/temporal/streaming detectors
  - **Multimodal/captioning bolted on later via additive default-impl methods**, so a `Captioner`-style method (or separate protocol) doesn't require a protocol version bump
- **Concrete `AsyncThrowingStream`, not `some AsyncSequence`.** PFM dodges the existential/opaque-type dance. [PFM `LanguageModelBackend.swift:12-86`](../swift-ecosystem/private-foundation-models.md).
- **Stateful detector state lives inside the conformer** (probably as an `actor` instance var for trajectory). The `Detector` protocol stays stateless-looking. [PFM pattern](../swift-ecosystem/private-foundation-models.md).

### Rotation & coordinate handling
- **`AVCaptureDevice.RotationCoordinator`** — both preview connection and capture connections get the same observed angle. [Apple AVCam `CaptureService.swift:366`](../swift-ecosystem/apple-avcam.md). Iris should adopt this rather than rolling its own orientation handling.

## New additions to M1 scope (beyond the 7 from in-house reads)

1. **`prewarm() async` on `Detector`** — beyond just `warmup()`; PFM's name + shape.
2. **`availability: Detector.Availability` and `modelIdentifier: String`** on the `Detector` protocol from day one.
3. **`AVCaptureDevice.RotationCoordinator`-based rotation handling** in `IrisCapture` and `IrisOverlay` — don't roll your own.
4. **Interruption recovery pre-empted in `IrisCapture`** — pause on `wasInterrupted`, resume on `interruptionEnded` with ~100ms `AVAudioSession` settle delay. [NextLevel scar #281](../swift-ecosystem/nextlevel.md).
5. **Multi-subscriber `AsyncStream` broadcast** — `[UUID: Continuation]` shape. [NextLevel cautionary tale](../swift-ecosystem/nextlevel.md): they stored continuations as single `Any?` and the second subscriber silently overwrote the first.
6. **Photo-output dictionary key validation** — never set both `kCVPixelBufferPixelFormatTypeKey` and `AVVideoCodecKey` (AVFoundation crashes). [NextLevel issue #286](../swift-ecosystem/nextlevel.md).
7. **Per-frame back-pressure: `AsyncStream.makeStream(of: Frame.self, bufferingPolicy: .bufferingNewest(1))`** as the contract. **Do NOT spawn a `Task { ... }` per frame inside the framework** — leave task management to the consumer of `for await frame in capture.frames`. [NextLevel anti-pattern: `_activeTasks: [Task<Void, Never>]` + NSLock to chase per-frame leaks](../swift-ecosystem/nextlevel.md).
8. **`MockDetector` / `MockCaptureSource` / `MockFrameSource` conformers** for SwiftUI previews and tests without permissions/models/files. [MijickCamera mocks-via-protocols pattern + ios-videoCapture `DummyCameraController` precedent.]

## New anti-patterns (beyond the in-house list)

- **Singleton `.shared` + N delegate sockets + delegate-only per-frame hook** (NextLevel `NextLevel.shared` + 9 delegates).
- **`.startSession()` modifier sentinel** that activates an otherwise-empty view (MijickCamera).
- **Per-frame `Task { ... }` spawning inside the framework** (NextLevel — schedules unboundedly at 30/60 fps, requires hand-rolled `_activeTasks` + `NSLock` accounting).
- **`AsyncStream` continuations stored as single `Any?`** (NextLevel — silent overwrite of second subscriber).
- **Result-builder DSL for non-tree pipelines** (would be wrong for Iris — Kadr's contrast).
- **Bridging actor state to MainActor via Combine `@Published` + `Publisher.values` re-subscription** (Apple AVCam retrofit — Iris is greenfield, skip Combine entirely).
- **Burying the preview view behind a turnkey screen protocol** (MijickCamera's `MCameraScreen.createCameraOutputView()` forces every consumer into the full-screen app shell). Iris's `CameraPreview(session:)` must be standalone.
- **`nonisolated(unsafe) var`** on actor mutable state (NextLevel `NextLevelSession.swift:634`) — same smell as `@unchecked Sendable` without the locking discipline.

## What this resolves from the prior "Still open" list

- **Q6 Foundation Models scope** — **RESOLVED.** Two protocols: `Detector` and `Captioner`. VLM backends conform to both. (PFM `EmbeddingBackend`/`LanguageModelBackend` precedent.)
- **`Source`-protocol unification upstream of `IrisCapture`/`IrisPlayback`** — **RESOLVED, do it.** Apple AVCam's `OutputService` and `PreviewSource` patterns plus NextLevel's negative example (delegate-only frames lock consumers to AVCaptureSession semantics, including the `onQueue:` parameter leaking into the protocol).
- **`DetectorCache` ownership** — **RESOLVED-leaning.** Injectable instance per pipeline/session (PFM's snapshot-at-construction model + Apple AVCam's `DeviceLookup` as `private let` precedent). Not a singleton.
- **Cancellation policy** — **RESOLVED.** `AsyncStream` with `bufferingPolicy: .bufferingNewest(1)` + consumer-owned task lifetime + structured `Task` parent/child cancellation through the `for await`. The framework does NOT spawn per-frame tasks.

## What stays open

- **Q3 sidecar format** (COCO vs YOLO vs Create ML JSON). No new signal from external packages. Decide on domain merits.
- **NEW: Package layout — single-package multi-target vs core-package + adapter-repos.** Kadr's lived experience says split into adapter repos; the current BRIEF.md plan is single-package multi-target. Real architectural fork before M1 plans lock. Recommend deciding before writing any `Package.swift`.
- Whether `Detector` should *require* an `actor` for stateful conformers, or whether `Sendable` + conformer's choice of `actor`-vs-class is sufficient. PFM votes for the latter (protocol-level `Sendable`, conformer holds the actor internally). Tentative call: protocol stays `Sendable`-only, stateful conformers use `actor` internally.
