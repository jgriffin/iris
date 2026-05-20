# Apple AVCam (SwiftUI sample) — prior-art read

**Source:** developer.apple.com/documentation/avfoundation/avcam-building-a-camera-app
(zip: `docs-assets.developer.apple.com/published/e69fb44a209f/AVCamBuildingACameraApp.zip`, 19 MB, iOS/iPadOS/Mac Catalyst 26.0)
**Read date:** 2026-05-20
**Priority lens:** canonical `CaptureService` actor architecture

## At a glance

Apple's reference architecture for an iOS camera app post-WWDC24. Three layers:

1. **`actor CaptureService`** (595 LOC, `AVCam/CaptureService.swift`) — owns the `AVCaptureSession`, inputs, outputs, controls, rotation, notifications.
2. **`@MainActor @Observable final class CameraModel: Camera`** (236 LOC, `AVCam/CameraModel.swift`) — SwiftUI-bindable view-model. Holds a `CaptureService`. Bridges actor-published values into `@Observable` properties using `for await … in actor.$prop.values`.
3. **SwiftUI `App` → `CameraView(camera:)`** (42 LOC `AVCamApp.swift`) — passes the model in, calls `await camera.start()` from `.task`.

Photo + video capture only. **No video-data output, no per-frame `AsyncStream`, no Vision, no overlay-coordinate math.**

## Capture entrypoint

`CaptureService.swift:14` — quoting the key declaration (this is the load-bearing one):

```swift
actor CaptureService {
    nonisolated let previewSource: PreviewSource
    private let captureSession = AVCaptureSession()
    …
    private let sessionQueue = DispatchSerialQueue(label: "…AVCam.sessionQueue")
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        sessionQueue.asUnownedSerialExecutor()
    }
```

Notable choices:

- **Custom serial executor** (`sessionQueue`, lines 68–73). The actor runs on a `DispatchSerialQueue` rather than the default cooperative pool — guarantees AVFoundation's main-thread-avoiding requirement and gives a stable queue handle to pass to `setControlsDelegate(_:queue:)` and `AVCaptureSlider.setActionQueue`.
- **`@preconcurrency import AVFoundation`** (line 9, also in `CameraPreview.swift:9`). Apple themselves use the escape hatch — the framework is not yet `Sendable`-clean.
- **`nonisolated let previewSource`** (line 28) is the only opening in the actor wall. UI gets a `PreviewSource`, never the session. The actor never publishes the session.
- **`@Published` on actor properties** (`captureActivity`, `captureCapabilities`, `isInterrupted`, line 17–25). Combine + actor coexist. The MainActor model consumes them via `await captureService.$captureActivity.values` (a `Publisher.values` `AsyncSequence`, `CameraModel.swift:205–234`).
- **Nested private delegate classes**: `PhotoCaptureDelegate` is a `private class` inside `PhotoCapture.swift:142`; the bare `CaptureControlsDelegate` is file-scope but only referenced inside `CaptureService`. Each delegate owns an `AsyncStream.Continuation` to bubble events out without exposing AVFoundation types.
- **SwiftUI bridging** (`Views/CameraPreview.swift:11`): `CameraPreview: UIViewRepresentable` wraps a `class PreviewView: UIView` whose `layerClass = AVCaptureVideoPreviewLayer.self`. Two app-defined protocols, `PreviewSource: Sendable` and `PreviewTarget`, decouple the service from the view — the service hands the UI a `PreviewSource`, the view conforms to `PreviewTarget`, `connect(to:)` does the wiring. `setSession` is `nonisolated` and hops to `@MainActor` to assign `previewLayer.session`.
- **LockedCameraCapture is wired in** (`Model/Intent/AVCamCaptureIntent.swift`, `AVCamCaptureExtension/AVCamCaptureExtension.swift`). The extension is a separate target with its own `@main struct: LockedCameraCaptureExtension` that instantiates the *same* `CameraModel` and renders the *same* `CameraView`. Persistent state shared via `CameraState`.

## Frame plumbing

**There is none.** AVCam uses `AVCapturePhotoOutput` and `AVCaptureMovieFileOutput`; neither exposes per-frame buffers. The `CaptureService` defines an `outputServices` collection over an `OutputService` protocol (`DataTypes.swift:152`):

```swift
protocol OutputService {
    associatedtype Output: AVCaptureOutput
    var output: Output { get }
    var captureActivity: CaptureActivity { get }
    var capabilities: CaptureCapabilities { get }
    func updateConfiguration(for device: AVCaptureDevice)
    func setVideoRotationAngle(_ angle: CGFloat)
}
```

For Iris, this is the natural extension point: a third conformer `FrameStreamCapture: OutputService { var output: AVCaptureVideoDataOutput { get } … }` that owns an `AsyncStream<Frame>.Continuation` in its sample-buffer delegate. The architecture allows it cleanly; Apple just didn't ship it because the sample is photo/video-file centric.

`AsyncStream` is used widely but only for *event* streams: `SPCObserver.changes` (device changes), `PhotoCaptureDelegate.activityStream` (capture lifecycle), `MediaLibrary.thumbnails`. All built via `AsyncStream.makeStream(of:)`. Every delegate produces a stream; the actor consumes it; the actor re-publishes via `@Published`; the MainActor model re-consumes via `.values`. Three layers — over-engineered for a frame pipeline, but a clear pattern for *events*.

## Detection path

Not present. No `Vision`, no `VNImageRequestHandler`, no `MLModel`. The OutputService protocol is the slot — a `Detector` would attach as a fourth conformer that owns an `AVCaptureVideoDataOutput` and runs Vision on the delegate queue.

## Overlay coordinate-space handling

Not directly. The only coord conversion is `videoPreviewLayer.captureDevicePointConverted(fromLayerPoint:)` in `focusAndExpose` (`CaptureService.swift:423`) — view-coords → AVFoundation device-coords for AF/AE. Done by the `AVCaptureVideoPreviewLayer` itself, not hand-rolled. **Rotation** is centralized via `AVCaptureDevice.RotationCoordinator` (line 366); both preview connection and capture connections get the same observed angle. Iris should adopt `RotationCoordinator` for parity rather than rolling its own orientation handling.

`StatusOverlayView`, `LiveBadge`, `RecordingTimeView` are SwiftUI overlays on the camera preview, not detection overlays — no normalized-coord work.

## Public API shape

Nothing is `public`. AVCam is an app, not a library — all types are internal-by-default. But if you were extracting "the AVCam pattern" as a library facade, it would look like this:

- `public protocol PreviewSource: Sendable` + `public struct CameraPreview: UIViewRepresentable` — the only UI-facing types.
- `public protocol Camera: AnyObject, SendableMetatype, @MainActor` (the existing `Model/Camera.swift` — already a clean view-model protocol, 76 LOC, all `async` methods + getters, no AVFoundation leaked).
- `public actor CaptureService` — but most consumers would talk to it via `Camera`, not directly.
- Value types: `Photo`, `Movie`, `CaptureMode`, `CaptureActivity`, `CameraStatus`, `CaptureCapabilities`, `QualityPrioritization` — all `Sendable` enums/structs.

The `Camera` protocol is the most copyable artifact for Iris — it's almost exactly the shape `IrisCapture.CameraController` or `IrisCapture.Source` should expose to apps.

## Carry forward into Iris (2–3)

1. **`actor CaptureService` with custom serial executor.** Copy the pattern verbatim: `nonisolated let previewSource`, `nonisolated unownedExecutor` bound to a `DispatchSerialQueue`, all session mutation actor-isolated. This is the Dec-2025 forum consensus and Apple's official architecture converged. `@preconcurrency import AVFoundation` is acceptable.
2. **`OutputService` protocol as the extensibility seam.** Iris's `FrameStreamCapture` and a `Detector`-fronted `VisionCapture` both become `OutputService` conformers managed by `IrisCapture`'s actor. Same pattern, one more conformer.
3. **`PreviewSource` / `PreviewTarget` indirection.** Don't expose `AVCaptureSession` to SwiftUI — give consumers a `Sendable` source that connects to a private target. This is the cleanest UIKit-bridge boundary in the sample.

## Don't repeat (1–2)

1. **Combine `@Published` on actor properties bridged via `.values`.** AVCam mixes Combine and Swift Concurrency because it was retrofitted. Iris is greenfield Swift 6: expose `AsyncStream`/`AsyncSequence` directly from the actor. Skip the `@Published`-and-`.values` re-publishing entirely.
2. **The nested `private class …Delegate` pattern** is fine but verbose — Iris can collapse it where the delegate is one-shot (use `AsyncStream` continuations captured in a local closure-delegate via the `NSObject` continuation-helper pattern from `SPCObserver.swift:18`).

## Opinions on Iris's still-open questions

- **`Source` protocol upstream of `IrisCapture`/`IrisPlayback`** — *Yes, do it.* AVCam's `OutputService` and `PreviewSource` protocols prove Apple's preferred shape: small protocols that decouple producers from consumers. Iris's `Source: AsyncSequence<Frame>` is the moral equivalent — same idea, frame-level.
- **DetectorCache ownership** — AVCam has no analog (no detectors), but `DeviceLookup` (`Capture/DeviceLookup.swift`) is a `private let` instance owned by `CaptureService`. Pattern: **injectable instance, not singleton**, owned by the orchestrating actor.
- **Cancellation policy** — AVCam uses ad-hoc `Task?` properties (`subjectAreaChangeTask`, `CaptureService.swift:444`) and cancels them by reassignment. This is fine for the actor's internal observation tasks. For Iris's pipeline (Source → Detector → Overlay), upstream cancellation should propagate via `AsyncStream` termination + structured `Task` parent/child, not manual `Task?` juggling.
- **Q3 sidecar format** — no signal; AVCam doesn't do datasets.
- **Q6 Foundation Models** — no signal.

## Verdict

**Borrow from it.** Iris's `IrisCapture` actor should mirror `CaptureService` almost line-for-line for session lifecycle, custom serial executor, `PreviewSource` indirection, and `OutputService` extensibility — diverging only to expose frames as an `AsyncStream<Frame>` and to drop the Combine bridging.

## Notes & loose ends

- The forums thread (Jan 2026) flags AVCam as "still not using Swift 6.2 or strict concurrency checking." Confirmed: the sample uses `@preconcurrency import AVFoundation` and Combine `@Published`, and ships under Swift 5/6 language mode (not 6.2 strict). Iris should validate the pattern compiles under Swift 6 strict before committing to it — likely needs `@preconcurrency` retained and `@Published` removed.
- AVCam includes a **Control Center extension** (`AVCamControlCenterExtension/`) — out of scope for Iris but a pointer that the same `CaptureService` shape supports extension targets.
- `Camera` protocol's `SendableMetatype` conformance (line 15) is the Swift 6.2 trick to make a `@MainActor` protocol's metatype crossing isolation boundaries OK. Worth copying.
- macOS parity: AVCam is **iOS-only** (no Mac Catalyst camera in the sample target — even though the platform list says Catalyst 26 is supported, capture requires device hardware). No signal on Iris's macOS playback parity question.
