# yolo-ios-app — prior-art read

**Path:** `~/dev/ml/yolo-ios-app`
**Read date:** 2026-05-20
**Priority lens:** public Swift package craft

## At a glance

Ultralytics' official iOS package + demo app. Single SwiftPM target `YOLO` (`Package.swift:14-26`), `swift-tools-version: 5.10`, platform `.iOS(.v16)`. One external dep: `ZIPFoundation` (for downloading and unzipping `.mlpackage.zip` from GitHub Releases). 6,051 LOC across 19 files in `Sources/YOLO/`. The README and inline marketing claim iOS+iPadOS+macOS+tvOS+watchOS, but every source file `import UIKit` and there are *zero* `#if os(...)` guards — this is an iOS-only package with aspirational copy. No `@frozen`, no `@_spi`, no availability gates beyond `@available(iOS 16.0, *)` in two spots. The package ships the entire pipeline (capture → infer → overlay → controls) as a single `UIView` (`YOLOView`) and a thin SwiftUI wrapper (`YOLOCamera`). Public surface is large and class-heavy.

## Capture entrypoint

Two public entrypoints, one wraps the other:

- `YOLOCamera` (`YOLOCamera.swift:18`) — SwiftUI `View`; internally a `UIViewRepresentable` (`YOLOViewRepresentable`, `:66`) over `YOLOView`.
- `YOLOView` (`YOLOView.swift:30`) — `@MainActor public class YOLOView: UIView`, the real component. It *owns* a `VideoCapture` (`VideoCapture.swift:44`), a `Predictor`, the preview layer, the bounding-box layers, three `UISlider`s (conf, IoU, numItems), a toolbar with play/pause/switch-camera/share buttons, pinch-zoom, and photo-snapshot capture. All in one type.

`VideoCapture` is `public class VideoCapture: NSObject, @unchecked Sendable` with a public `captureSession: AVCaptureSession`, public `previewLayer: AVCaptureVideoPreviewLayer?`, and a `@MainActor`-isolated `VideoCaptureDelegate` (`VideoCapture.swift:20-24`). Setup is callback-based (`setUp(sessionPreset:position:orientation:completion:)`, `:70`) — kicked off on a private `cameraQueue` and `DispatchQueue.main.async`'d back. No `async/await`. There's no separation between "session" and "view"; ownership is "view owns session and predictor."

## Frame plumbing

**There is no public `Frame` type.** `CMSampleBuffer` arrives at `VideoCapture.captureOutput(...)` (`VideoCapture.swift:270`), is handed (still as a `CMSampleBuffer`) to `predictor.predict(sampleBuffer:onResultsListener:onInferenceTime:)` (`Predictor.swift:58`), which extracts a `CVPixelBuffer` and passes it directly to `VNImageRequestHandler`. The pixel buffer never escapes the predictor. There is one self-imposed back-pressure mechanism: `currentBuffer` (`BasePredictor.swift:43`, `VideoCapture.swift:68`) — if a frame is already being processed, the next sample is dropped. `videoOutput.alwaysDiscardsLateVideoFrames = true` (`VideoCapture.swift:140`). So Iris's notion of a source-agnostic `Frame` does not exist here: the source (camera) and the consumer (predictor) are wired directly through `CMSampleBuffer`, and the only "Sendable" thing crossing module boundaries is `YOLOResult` (`@unchecked Sendable`, `YOLOResult.swift:30`).

## Detection path

`Predictor` (`Predictor.swift:51`) is **non-Sendable, callback-based, reference-typed**:

```swift
public protocol Predictor {
  func predict(sampleBuffer: CMSampleBuffer,
               onResultsListener: ResultsListener?,
               onInferenceTime: InferenceTimeListener?)
  func predictOnImage(image: CIImage) -> YOLOResult
  var labels: [String] { get set }
  var isUpdating: Bool { get set }
}
```

No `async`. Results come back through *two weak delegate protocols*: `ResultsListener` and `InferenceTimeListener`. `BasePredictor` (`BasePredictor.swift:29`) is `@unchecked Sendable` and holds a `VNCoreMLModel`, a `VNCoreMLRequest` with a `[weak predictor]` completion handler (`:172`), and dispatches `processObservations` from Vision's callback. Loading is via a static factory `create(unwrappedModelURL:isRealTime:completion:)` (`:102`) that runs `MLModel.compileModel` + `MLModel(contentsOf:configuration:)` off `DispatchQueue.global(qos: .userInitiated)` and calls back on `.main`. `MLModelConfiguration` is built fresh with one undocumented hack: `config.setValue(1, forKey: "experimentalMLE5EngineUsage")` (`:118`) — a workaround for a macOS 15 CoreML bug, set via KVC. **No `MLComputeUnits`/compute-unit selection is exposed.**

Hot-swap (Iris open question #4) — see `YOLOView.setModel(modelPathOrName:task:completion:)` (`:189`): the existing `YOLOView` stays put, a new `BasePredictor` subclass is constructed via `Classifier.create` / `Segmenter.create` / `ObjectDetector.create` / etc., and on success the new instance is *assigned* to `self.videoCapture.predictor` (`:244`). The previous predictor's `deinit` cancels its `visionRequest`. So this codebase votes firmly for **reference-typed, tear-down-and-replace**: a new predictor instance per swap, swapped under `@MainActor`, no shared mutable detector state. The `Detector` protocol type is `Predictor` (single instance, not a registry); concurrent multi-detector pipelines are not supported.

Real-time vs single-image is *internal* state on the predictor (`isRealTime` argument to `create`, `:104`), used only to suppress the Vision completion-handler path for one-shot calls. The single-image API (`YOLO("name", task: .detect)(uiImage)`, `YOLO.swift:155`) uses `callAsFunction` — a Python-flavored ergonomic that's actively highlighted in the README ("Python-like code syntax in Swift").

## Overlay coordinate-space handling

Coordinate conversion lives **inside `YOLOView`** (`YOLOView.swift:538-689`), not in a dedicated overlay module. `showBoxes(predictions:)` branches on `UIDevice.current.orientation`, computes an aspect ratio from `sessionPreset` (`.photo` → 4:3, otherwise → 16:9), inverts Vision's bottom-origin Y to UIKit top-origin (`y: 1 - prediction.xywhn.maxY`), applies a `CGAffineTransform(scaleX: 1, y: -1)` plus a center-aware offset, then calls `VNImageRectForNormalizedRect` to denormalize. Front-camera mirroring is handled at the capture layer (`connection.isVideoMirrored = true`, `VideoCapture.swift:167`), not in overlay code. Different orientations also feed into the photo-capture path (`YOLOView.swift:1300-1315`).

This code is the clearest "don't repeat this" example in the package: ~150 lines of orientation-aware arithmetic, deeply entangled with `UIDevice.current.orientation` (not the view's geometry), with separate code paths for portrait vs landscape. Iris's plan to centralize this in `IrisOverlay` and present it as a coordinate-space type is the right call.

`Detection`'s analog is `Box` (`YOLOResult.swift:73`) — `@unchecked Sendable`, carries both `xywh` (image-space `CGRect`) and `xywhn` (normalized `CGRect`), plus `index: Int`, `cls: String`, `conf: Float`. Both spaces precomputed at detection time. That's a useful shape — overlays don't have to know the input size.

## Public package craft (priority lens for this project)

- **Single product, single target.** `Package.swift` ships one library `YOLO`. No sub-libraries (no `YOLOCore`, `YOLOUI`, etc.). Everything ships together.
- **Public surface is wide and class-heavy.** ~35 `public` declarations across 19 files (counted via `grep "^public"`). Almost every class is `public` (`YOLOView`, `VideoCapture`, `BasePredictor`, `ObjectDetector`, `Classifier`, `Segmenter`, `PoseEstimator`, `ObbDetector`, `ThresholdProvider`, `BoundingBoxView`, `YOLOModelCache`, `YOLOModelDownloader`, `YOLO`, plus `YOLOCamera`). Consumers can poke at `videoCapture.captureSession.inputs` directly — extension points, but also a huge API contract.
- **No `@frozen`, no `@_spi`, no `@available` gates beyond two iOS-16 spots.** No API stability discipline.
- **Concurrency markers are inconsistent.** `@MainActor` on `YOLOView`, `BoundingBoxView`, `VideoCaptureDelegate`. `@unchecked Sendable` on most predictors, `YOLO`, `VideoCapture`, `YOLOResult`. `@preconcurrency import CoreML` in `Segmenter.swift:16`. `nonisolated` on the `AVCapturePhotoCaptureDelegate` callback (`YOLOView.swift:1285`). This is what "Swift 6 strict concurrency, fix the design instead of relaxing the checker" warns against — Iris should not copy this pattern.
- **Model management is genuinely good.** `YOLOModelDownloader` + `YOLOModelCache` (singleton, SHA256-keyed under `Documents/YOLOModels/`, `mlmodelc`/`mlpackage`/`mlmodel` resolution order, `Manifest.json` validation for `.mlpackage`s, `URLSessionDownloadDelegate` with progress, ZIPFoundation extraction with `__MACOSX` filtering, `MLModel.compileModel` after extraction). The model-loading public API accepts: a bundle resource name, an absolute file path, *or* a remote `URL` that auto-downloads and caches. Lazy, on-demand. No bundled models — the demo app reads them from `DetectModels/`, `SegmentModels/`, etc., folders the user populates.
- **Example apps as docs.** Four `ExampleApps/` Xcode projects (real-time × SwiftUI/UIKit and single-image × SwiftUI/UIKit), each ~30 LOC of actual usage. They consume the package via a local SwiftPM dependency. The `YOLOiOSApp/` itself is a richer demo with model-picker, segmented controls per task, external-display support. README's `YOLOCamera(modelPathOrName:task:cameraPosition:)` snippet is precisely the surface the example uses.
- **Tests use real fixtures.** `Tests/YOLOTests/` has `Resources` processed at build time and a `SKIP_MODEL_TESTS = true` toggle so CI can run without the unredistributable `.mlpackage` files. Aligns with Iris's "real fixtures over mocks" rule.
- **`ThresholdProvider: MLFeatureProvider`** (`ThresholdProvider.swift:16`) is a small clean idea — IoU + confidence get pushed into the model's feature dict, so re-thresholding doesn't tear down the predictor. Worth borrowing for `IrisTuning`.

## Carry forward into Iris (2–3)

1. **The `MLFeatureProvider`-as-tuning-handle pattern.** `ThresholdProvider` lets `IrisTuning` adjust runtime knobs (conf, IoU, NMS) by swapping a tiny feature dict on the live `VNCoreMLModel`, no reload. Cheap, clean, hot-path-safe. Iris's "tuning" milestone should consider this for any threshold that the *model* consumes vs the *post-processor* consumes.
2. **Model lifecycle: URL → download → SHA-key cache → compile → load.** `YOLOModelCache` + `YOLOModelDownloader` is well-shaped: SHA256 of `(url, task)` as cache key, `Documents/<package>/` directory, `.mlpackage` validation via `Manifest.json` check, lazy compile via `MLModel.compileModel`. Iris's "M6 custom models + captioning" milestone should adopt this directory shape rather than re-inventing it. Note: cache singleton is `public` — Iris should make it an instance with an injected directory instead, so two consumers don't collide.
3. **Box carries both `xywh` and `xywhn`.** Pre-computing image-space *and* normalized rects at detection time means overlay code can pick whichever fits its current geometry without needing the input frame size. Iris's `Detection` should do the same.

## Don't repeat (1–2)

1. **God-view `YOLOView`.** 1,412 LOC of camera + predictor ownership + slider UI + toolbar + bounding-box rendering + segmentation/pose/OBB layers + zoom + photo capture + delegate forwarding, with `@MainActor`-vs-`nonisolated` patched in after the fact. This is exactly what Iris's six-module split is designed to prevent: capture, tuning controls, overlay, and dataset capture are conflated into one type that can't be reused independently. Keep `IrisCapture`, `IrisOverlay`, `IrisTuning` as separate targets and let the demo app compose them.
2. **Callback-based async everywhere.** Every loading path is `completion: (Result<X, Error>) -> Void`. No `async`. The package was written to a Swift 5.5-era idiom and is paying for it now (`@unchecked Sendable` on almost every class, `@preconcurrency import CoreML`, KVC hack via `config.setValue` for an undocumented CoreML key). Iris's "no completion handlers" rule is correct; don't compromise.

## Opinions on Iris's M1 open questions

- **#1 `AsyncStream<Frame>` vs `AsyncSequence` protocol** — *No signal.* This codebase doesn't have a frame stream at all; it's a pull-driven delegate callback. No useful prior art here, so Iris can decide on its own merits. The one carry-forward: a single-frame back-pressure handle (`isUpdating`/`currentBuffer` here) is needed somewhere — `AsyncStream`'s buffering policy gives you that for free.
- **#2 Explicit actor isolation (e.g. `@CaptureActor`)** — *Weak negative on the precedent.* yolo-ios-app uses `@MainActor` (for the view), a private serial `cameraQueue: DispatchQueue` (for AVCapture), and `DispatchQueue.global(qos: .userInitiated)` (for model load) — three different isolation domains with manual hops between them. A unified `@CaptureActor` would be strictly cleaner than what this package does. Iris should introduce one.
- **#3 COCO JSON sidecar** — *No signal.* No dataset capture in this package.
- **#4 Hot-swap: tear-down vs swap-instance, value vs reference type** — *Strong opinion: swap a new reference-type instance.* `Predictor` here is a protocol implemented by reference-typed `BasePredictor` subclasses. Swap is done by constructing a new instance via the static `create(...)` factory and assigning it onto `videoCapture.predictor`, while the old one's `deinit` cancels its in-flight `VNCoreMLRequest`. Value-typed detectors would force you to put `VNCoreMLModel` and the `VNCoreMLRequest` cycle inside an unhappy struct. Iris should make `Detector` a `Sendable` reference type (an `actor` would be ideal under Swift 6) and hot-swap by replacing the instance, not mutating it.
- **#5 macOS overlay parity** — *Anti-pattern to study.* The orientation logic in `YOLOView.showBoxes` is built on `UIDevice.current.orientation` (iOS-only) rather than the view's geometry, which is why this package can never become a real macOS package without rewriting `IrisOverlay`'s analog. Iris's coordinate-space module should take *view bounds and a known transform* as inputs, never a global device orientation.
- **#6 Foundation Models: `Detector` backend vs `Captioner` vs both** — *No signal.* No FM integration here. Worth noting the existing `Predictor` protocol couldn't easily accommodate a captioner: its output type is hard-coded to `YOLOResult` (a struct full of box/mask/keypoint/OBB optionals). Iris should keep the `Detector` output associated-type-generic or via a sum-type from the start so a `Captioner` doesn't require a parallel protocol.

## Notes & loose ends

- README claims iOS 13 / macOS 10.15 / tvOS 13 / watchOS 6. `Package.swift` declares only `.iOS(.v16)`. Reality: iOS 16+ only, and only because of `ImageRenderer` and `maxPhotoDimensions`. The macOS/tvOS/watchOS columns in the README are aspirational.
- `Package.swift` line 2 carries the comment `// WARNING: <=5.10 requires for GitHub Actions CI`. The package is *technically* stuck on Swift 5.10 tools for CI reasons; if Iris wants to depend on it, it can't tighten that requirement.
- Single odd KVC hack: `config.setValue(1, forKey: "experimentalMLE5EngineUsage")` in `BasePredictor.swift:118` — undocumented, works around an MLE5 engine bug on macOS 15. Iris should not adopt this blindly; check whether the bug still reproduces on iOS 26 / macOS 26.
- Lots of `print(error)` instead of a proper logging surface. Iris should expose a `Logger` (or `os.Logger`) seam from day one.
- The package has *no* macOS code despite the README copy. Iris's plan to make `IrisDetection`/`IrisOverlay`/`IrisDataset` iOS+macOS from day one is a clear differentiation.
