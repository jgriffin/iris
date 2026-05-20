# ActionAndVision (Apple sample) — prior-art read

**Path:** `~/dev/pocketRadar/BuildingAFeatureRichAppForSportsAnalysis`
**Read date:** 2026-05-20
**Priority lens:** Apple-canonical pattern check

## At a glance

WWDC20 sample for sports activity analysis (bean-bag toss). iOS 14, UIKit + xibs, completion-handler-era Vision. Six source files do the heavy lifting: `CameraViewController.swift` (capture + playback unified), `SetupViewController.swift` (board detection + scene stability), `GameViewController.swift` (live pose + trajectory + scoring), `Common.swift` (state + helpers), `RootViewController.swift` (container), `GameManager.swift` (`GKStateMachine` singleton). Two bundled `.mlmodel`s. ~17k LOC of Swift across the targets.

The notable design move — and the one most relevant to Iris — is that `CameraViewController` unifies live camera and pre-recorded video behind a single delegate callback that emits `(CMSampleBuffer, CGImagePropertyOrientation)`. Downstream code is genuinely source-agnostic. This is the same instinct Iris is encoding with `Frame` + `IrisCapture` / `IrisPlayback` as twin producers.

## Capture entrypoint

`CameraViewController` (UIKit `UIViewController` loaded from a xib) owns:

- `AVCaptureSession` (`cameraFeedSession`, optional — nil when playing a file)
- A custom `CameraFeedView: UIView` whose `layerClass` is `AVCaptureVideoPreviewLayer` (`Views/VideoOutputViews.swift:25`)
- A dedicated `DispatchQueue(label: "CameraFeedDataOutput", qos: .userInitiated, autoreleaseFrequency: .workItem)` for the `AVCaptureVideoDataOutput` delegate
- A second `DispatchQueue(label: "VideoFileReading", qos: .userInteractive)` plus `CADisplayLink` for file playback

Session setup (`setupAVSession`, lines 46–107) is by-the-book: `AVCaptureDevice.DiscoverySession` → `AVCaptureDeviceInput` → `session.beginConfiguration()` → `.hd1920x1080` preset → `AVCaptureVideoDataOutput` with `alwaysDiscardsLateVideoFrames = true` and `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange` → `session.commitConfiguration()` → `session.startRunning()`. `RootViewController` hosts it as a child VC and adds an overlay `UIView` on top — overlay VCs become its `outputDelegate`.

Lifecycle is `viewDidDisappear` → `stopRunning()` + `displayLink.invalidate()`. No background-state handling, no permissions UI in this sample.

## Frame plumbing

There is **no app-level frame type**. The contract is literally:

```swift
protocol CameraViewControllerOutputDelegate: class {
    func cameraViewController(_ controller: CameraViewController,
                              didReceiveBuffer buffer: CMSampleBuffer,
                              orientation: CGImagePropertyOrientation)
}
```

`CMSampleBuffer` flows directly into `VNImageRequestHandler(cmSampleBuffer:orientation:options:)` in each consumer (`GameViewController.swift:327`, `SetupViewController.swift:249`). Orientation is the only sideband metadata — for file playback they derive it from `track.preferredTransform` (lines 188–203), for live capture they pin it to `.up` (line 269).

Threading: capture queue → Vision runs *inline on the capture queue* for body pose, but trajectory detection is dispatched off to a third queue (`com.ActionAndVision.trajectory`, `userInteractive`) because trajectory is stateful and would block frame intake. UI mutations are hopped to `DispatchQueue.main.async` ad hoc inside the delegate. Pre-recorded path adds a fourth queue plus a `CADisplayLink` on the main run loop driving `AVPlayerItemVideoOutput.copyPixelBuffer(forItemTime:)`. So: four queues, hand-managed, no actors.

Pixel buffer reuse: they synthesize a `CMSampleBuffer` from `AVPlayerItemVideoOutput` per display-link tick (lines 222–236) — same pattern Iris's `IrisPlayback` will need.

## Detection path

Pre-async-Vision throughout. Three patterns coexist:

1. **One-shot request per frame, performed inline.** `let visionHandler = VNImageRequestHandler(cmSampleBuffer:…); try visionHandler.perform([detectPlayerRequest])` — the handler is created per frame, the request object is reused (`detectPlayerRequest = VNDetectHumanBodyPoseRequest()` held on the VC). No completion handler — they read `request.results` synchronously after `perform`. (`GameViewController.swift:354`)
2. **Stateful sequence request.** `VNDetectTrajectoriesRequest` is created lazily as a stored property and reused across frames; trajectory state lives inside the request itself. Sent through `VNSequenceRequestHandler()` for `VNTranslationalImageRegistrationRequest` scene-stability (`SetupViewController.swift:43`).
3. **CoreML through Vision.** `VNCoreMLModel(for: GameBoardDetector(configuration: MLModelConfiguration()).model)` wrapped in `VNCoreMLRequest`, configured with `imageCropAndScaleOption = .scaleFit`. Model is loaded in `viewDidAppear`; never swapped at runtime.

There's also a `warmUpVisionPipeline()` helper (`Common.swift:175`) that runs every request type once against a bundled image at startup — preloads models + JIT-compiles request graphs to dodge first-frame stalls. Concrete carry-forward.

State machine is `GKStateMachine` (GameplayKit), nine states, broadcast via `NSNotification`. Heavy for what it does; an `@Observable` enum would replace it cleanly today.

## Overlay coordinate-space handling (canonical math)

This is the most useful chunk of the sample for Iris. The pattern:

1. **Vision returns normalized bottom-left-origin rects/points.**
2. **`CameraViewController` exposes two converters that hide the source:** `viewRectForVisionRect(_:)` and `viewPointForVisionPoint(_:)` (`CameraViewController.swift:117, 136`). Each:
   - Applies `CGAffineTransform.verticalFlip` (`= CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -1)`, `Common.swift:242`)
   - Delegates to the active output view via a `NormalizedGeometryConverting` protocol
3. **The protocol has two implementations**, one per source:
   - `CameraFeedView` defers to Apple's own `AVCaptureVideoPreviewLayer.layerRectConverted(fromMetadataOutputRect:)` / `layerPointConverted(fromCaptureDevicePoint:)` — i.e., it leans on AVFoundation rather than re-deriving aspect-fit math.
   - `VideoRenderView` uses `AVPlayerLayer.videoRect` and does the aspect-fit math inline (lines 80–95).

The math itself is centralized, the per-source quirks are isolated behind the protocol, and consumers always go through `controller.viewRectForVisionRect`. That's exactly the contract Iris wants for `IrisOverlay` — and the `NormalizedGeometryConverting` protocol is the architectural seam Iris should copy almost verbatim, but make it own the public coordinate-conversion surface rather than burying it on a UIView.

Rotation/mirroring is handled by setting `previewLayer.connection?.videoOrientation` once at session setup, derived from `view.window?.windowScene?.interfaceOrientation` (lines 95–101). No dynamic rotation observer in the sample.

## Apple-canonical shape vs Iris's plan

| Iris divergence | What canonical sample does | Defensible? |
| --- | --- | --- |
| **`Frame` value type vs raw `CMSampleBuffer`** | Sample passes `CMSampleBuffer` + `CGImagePropertyOrientation` straight through. No wrapper. | **Yes.** Sample's contract is already a 2-tuple — Iris formalizing that into `Frame { pixelBuffer, orientation, timestamp, … }` is the obvious next step. Caveat: don't over-stuff `Frame`; the sample shows `CMSampleBuffer + orientation` is enough. |
| **SwiftUI-first public API** | Pure UIKit, xibs, `UIViewController` containment. `RootViewController` does manual `addChild`/`didMove`. | **Yes.** Nothing in the architecture *requires* UIKit; the seams (delegate protocol, `NormalizedGeometryConverting`) translate cleanly to `UIViewRepresentable` + a `@Observable` capture model. Worth checking: how the `additionalSafeAreaInsets` dance (`RootViewController.swift:104–116`) maps to SwiftUI safe-area APIs — the sample uses it to align overlays with the actual video rect, not the view bounds. Iris will need an equivalent. |
| **`async/await` end to end** | Four hand-managed `DispatchQueue`s, completion via direct delegate call + `DispatchQueue.main.async` hops. | **Yes, straight upgrade.** The sample is *exactly* the kind of code that motivated structured concurrency. The trajectory queue exists solely to avoid blocking the capture queue — that's what actor isolation gives you for free. |
| **`Detector: Sendable` protocol** | No abstraction — Vision requests are stored properties on the VC, model swap means tearing down the VC. | **Yes.** Sample punts on hot-swap entirely. See M1 Q4 below. |
| **Source-agnostic `Frame`** | Already true here via delegate + protocol. Capture and playback feed identical downstream code. | **Yes — and the sample is the proof.** This is a known-good pattern, not novel. |
| **macOS support** | iOS-only. UIKit-dependent. | Sample says nothing useful here. |
| **COCO JSON dataset format** | No dataset capture at all. | Out of scope for the sample. |

The only place the sample suggests Iris should *reconsider*: the warmup helper. None of the Iris modules currently plan one. A `Detector.warmup()` requirement would prevent first-frame jank.

## Carry forward into Iris (2–3)

1. **`NormalizedGeometryConverting`-style protocol owned by `IrisOverlay`.** Two implementations (preview-layer-backed, video-rect-backed), one public converter. The sample's separation between "delegate to Apple's `layerRectConverted` when you can, derive math when you can't" is the right pragma. `IrisOverlay` should not require callers to ever touch a flip transform.
2. **`Detector.warmup()` on the protocol.** Run every request type once against a fixture image at app launch / detector init. The sample's `warmUpVisionPipeline()` (`Common.swift:175`) is 12 lines and prevents a real production wart.
3. **Unified capture/playback delegate as the architectural sketch.** Even though Iris will replace `CameraViewControllerOutputDelegate` with `AsyncStream<Frame>`, the *shape* — one consumer-facing contract, two producers behind it — is validated by Apple. Iris's `IrisCapture` and `IrisPlayback` should expose identical-shaped streams.

## Don't repeat (1–2)

1. **Four hand-managed `DispatchQueue`s + ad-hoc `DispatchQueue.main.async`** sprinkled inside the capture delegate. This is the central anti-pattern; `@CaptureActor` + `AsyncStream<Frame>` + `@MainActor` overlay state collapses three of the four queues and makes the hops compiler-checked. The trajectory-queue split (stateful detector on its own queue to not block capture) becomes "the stateful detector is its own actor" — same idea, expressed in the type system.
2. **`GKStateMachine` singleton + `NSNotification` broadcast** for app state. `GameManager.shared` plus `GameStateChangeNotification` is 160 lines that an `@Observable` enum + a couple of bindings would replace. Iris should not invent its own state machine framework; let SwiftUI's data flow be the state machine.

## Opinions on Iris's M1 open questions

- **Q1 (`AsyncStream<Frame>` vs `AsyncSequence` protocol):** Sample doesn't bear directly — it predates both. But the *consumer pattern* (capture and playback are both producers feeding an identical downstream) is exactly the use case for an `AsyncSequence`-shaped abstraction. The downstream code in `GameViewController` and `SetupViewController` literally doesn't care which producer it's wired to. Suggests: expose an `AsyncSequence` protocol so playback and capture conform to the same thing, even if the concrete return type happens to be `AsyncStream<Frame>`.
- **Q2 (explicit actor isolation / `@CaptureActor`):** **Strong signal that yes, you want one.** The sample's bug surface is almost entirely "which queue am I on" — and the queue boundaries are exactly where a `@CaptureActor` global actor would sit. Frame producers + the Vision call site = `@CaptureActor`; overlay state = `@MainActor`; the boundary is the `AsyncStream` await point.
- **Q3 (COCO JSON):** Sample is silent. No carry-forward.
- **Q4 (hot-swap Core ML model: tear down vs swap):** Sample takes the simplest path — model is loaded in `viewDidAppear`, the request is a stored property, swap means rebuild the VC. This is the *value-type-of-detector* world. Given how trivially cheap it is to construct a new `VNCoreMLRequest` once the model is loaded, **lean toward value-type `Detector` + "swap the whole detector instance"** rather than mutating an existing reference. The sample's complete absence of in-place model mutation is itself a vote — Apple didn't bother.
- **Q5 (macOS overlay parity):** Sample has nothing. But the `NormalizedGeometryConverting` protocol is the right seam: on macOS the implementing view backs `AVCaptureVideoPreviewLayer` (when available — playback only on Mac per Iris's plan) or `AVPlayerLayer`. The math doesn't change, only the host view.
- **Q6 (Foundation Models as `Detector` vs `Captioner`):** Sample uses `MLMultiArray` features fed to a Create ML action classifier (`Common.swift:192`) — closer to a detector than a captioner. Doesn't speak to language-model captioning. No signal.

## Notes & loose ends

- Models are bundled `.mlmodel`s in the app target — `GameBoardDetector.mlmodel` (12 MB) and `PlayerActionClassifier.mlmodel` (4 MB). Iris's `.gitignore` excludes `.mlmodelc/`; worth being explicit about whether downstream apps bundle source `.mlmodel`s or compiled `.mlmodelc` bundles.
- `additionalSafeAreaInsets` trick in `RootViewController.swift:104–116` — pad the overlay VC so its safe area matches the video rect rather than the screen. Iris's SwiftUI equivalent is `.safeAreaInset(edge:)` or a custom layout; either way, this is a real concern that wasn't on Iris's M1 list. **Add to the list:** "overlay coordinate space must account for letterbox/pillarbox between view bounds and video rect."
- `VNDetectTrajectoriesRequest` is *stateful and reused* across frames — confirms that Iris's `Detector` protocol needs to handle stateful detectors without forcing callers to manage lifecycle. A class-based detector with internal state is fine; a struct-only protocol would push state out and recreate it on every frame, which is exactly what trajectory detection cannot tolerate. (Reinforces Q4 answer: the protocol shouldn't *require* value semantics, but per-frame swap should be cheap.)
- `class:` (pre-Swift 5.1) protocol constraint and `weak var outputDelegate` — the sample is genuinely old enough that idioms are dated even before the async-Vision rewrite. Don't read too much into specific syntax choices.
