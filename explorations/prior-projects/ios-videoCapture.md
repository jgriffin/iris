# ios-videoCapture — prior-art read

**Path:** `~/dev/PR/ios-videoCapture`
**Read date:** 2026-05-20
**Priority lens:** module boundaries (modular SPM mirror)

## At a glance

A 2020–2021-era iOS app library extracted into an SPM package for Pocket Radar:
camera capture, AVPlayer-based playback with synchronized overlays, metadata
sidecar, and an export pipeline that bakes overlays into rendered video. It is
the closest published-shape mirror to Iris but a half-generation behind: Swift
`5.3.2` (`.swift-version:1`), `iOS .v14 / macOS .v11`, Combine-first,
delegate-and-closure callbacks, no detection module. Ten library products in
`Package.swift:9-50`: `CameraController`, `VideoPlayback`, `VideoOverlay`,
`VideoEditing`, `VideoLibrary`, `ExportManager`, `PRMetadata`, `VideoUtils`,
`VisionMath`, `Utilities`. There is no `Vision`/`CoreML` import anywhere in
`Sources/` — `VisionMath` is geometry/ballistics math, not Apple Vision.

## Capture entrypoint

`CameraController` (`Sources/CameraController/controller/CameraController.swift:16`)
is a single `public class … NSObject` that owns one optional `AVCaptureSession`
(line 80), two serial `DispatchQueue`s (`sessionQueue`, `bufferDelegateQueue`,
lines 92–93), and a `AVCaptureDevice.DiscoverySession` (line 94). It is the
god-object: session lifecycle, device selection, format/zoom/focus, recording,
notifications — all split across `CameraController+*.swift` extensions.

Isolation is **pre-concurrency**: a `sessionQueue` enforced with
`dispatchPrecondition(condition: .onQueue(sessionQueue))`
(`+inputsAndOutputs.swift:14`, `+movieFileOutput.swift:19`). All `setRunning`,
`addInput`, `addOutput`, format/zoom calls hop onto that queue. UI-side state
is mirrored into `CurrentValueSubject`s and pushed back to `main` via
`receive(on: RunLoop.main)` before being assigned to subjects
(`CameraController.swift:407–498`). No `actor`, no `@MainActor`, no `Sendable`.

SwiftUI bridging is **three layers deep**: `CapturePreviewHost`
(`UIViewControllerRepresentable`, `Preview/CapturePreviewHost.swift:12`) →
`CapturePreviewUIVC` (`UIViewController`, full lifecycle/gestures) →
`CapturePreviewLayerUIView` (`UIView` that hosts `AVCaptureVideoPreviewLayer`
plus a sibling `abovePreviewLayer`, `CapturePreviewLayerUIView.swift:12`). The
controller hands the layer to the host via
`ensureVideoPreviewLayer(host: UIView) -> AVCaptureVideoPreviewLayer`
(`CameraController.swift:208`). Session start/stop is implicit, driven by a
`Publishers.CombineLatest(isPreviewShowing, isRecordingSubject)` sink
(`CameraController.swift:359`) — the view setting `isPreviewShowing = true`
causes the session to spin up.

## Frame plumbing

There is **no shared `Frame` type for capture**. `addAVDataOutputs(delegate:)`
(`+inputsAndOutputs.swift:55`) wires an `AVCaptureVideoDataOutput` +
`AVCaptureAudioDataOutput` to a caller-supplied
`AVCaptureVideoDataOutputSampleBufferDelegate & AVCaptureAudioDataOutputSampleBufferDelegate`,
on `bufferDelegateQueue`. The Pocket Radar app, not the library, owns the
delegate that converts `CMSampleBuffer`s into something useful. Recording is a
file-output story: `AVCaptureMovieFileOutput` writes to a temp `.mov`
(`+movieFileOutput.swift:92-95`), and the result surfaces through a callback
`OnCameraCaptureResult = (CameraCaptureResult) -> Void`
(`CameraControlling.swift:78`, set on `init`).

The **playback** side does have a shared per-frame type:
`SampleBufferAndOrientation` (`playerUtils/SampleBufferAndOrientation.swift:8`)
— a value struct wrapping `CMSampleBuffer` + `CGImagePropertyOrientation`,
constructed from a `CVPixelBuffer` plus `duration`/`itemTime`. It is **not**
`Sendable` (Swift 5.3 era), but it is a struct and used as one. Distribution
is via an `async` closure:
`public var onNewSampleBuffer: ((SampleBufferAndOrientation) async -> Void)?`
(`AVPlayerObserver.swift:136-137`). Inside `updateSampleBuffer(itemTime:)` a
fresh `Task { await onNewSampleBuffer(sampleBuffer) }` is spawned per frame
(`AVPlayerObserver+updateSampleBuffer.swift:37`). No backpressure, no
`AsyncStream`, no actor. Timestamps live in the `CMSampleBuffer` itself
(`itemTime` becomes the PTS/DTS).

## Detection path

**Absent.** Zero references to `import Vision`, `VNRequest`, `CoreML`, or
`MLModel` under `Sources/`. The closest thing is `VisionMath` — a numerical
geometry/equations-of-motion target. There is no opinion to inherit on detector
architecture; Iris is greenfield on this axis.

## Overlay coordinate-space handling

The pattern is **"render at video-natural size, scale into video rect via a
single `CATransform3D`"** and is the strongest design idea in the repo. It
lives in `OverlayContext` (`Sources/VideoOverlay/overlay/manager/OverlayContext.swift:28-67`)
and `OverlayHostLayer` (`hostLayer/OverlayHostLayer.swift:16`).

- `OverlayContext` holds `videoNaturalSize` (raw pixel size of the asset/feed)
  and `videoRect` (where the video actually renders on screen, supplied by
  `AVPlayerLayer.videoRect` via KVO in `AVPlayerLayerView+UIView.swift:52-58`).
- `OverlayContext.scaleTransform3D` (line 70) returns a single
  `CATransform3DMakeScale(videoRect.w/natural.w, videoRect.h/natural.h, 1)`.
- `OverlayHostLayer.ensureTransformAndFrame` (`OverlayHostLayer.swift:104`)
  sets `self.transform` to that scale and `self.frame` to `videoRect`. All
  child overlay layers then lay out **in natural pixel space** and inherit the
  transform — the long-form comment at `OverlayHostLayer.swift:65-82` makes this
  contract explicit and recommends callers not touch `frame` directly.

No Vision-normalized [0,1] space conversion exists (there's no detector), but
the `CGRect.Location` / `LocationAtLocation` helper in
`VideoUtils/utils/CGRect+location.swift:23-131` is a tidy
anchor-ratio-plus-offset primitive with a `flipY` for switching UIKit-top-left
vs CoreAnimation-bottom-left coords — Iris can reuse the shape directly.

**Rotation/mirroring** is split: capture-side videoOrientation is plumbed
through `desiredVideoOrientation` (`CameraController.swift:45`) and pushed onto
`videoPreviewLayer.connection?.videoOrientation`; playback-side rotation is
captured at `setupVideoOutputFor` (`AVPlayerObserver+videoOutput.swift:41`) via
`videoTrack.imageOrientation()` and rides on `SampleBufferAndOrientation`. Two
different idioms for the same concept across capture vs. playback — exactly
what Iris's source-agnostic `Frame` is meant to unify.

## Module boundaries (priority lens for this project)

Surface per module is **wide**: `CameraController` re-exports
`AVCaptureDevice`, `AVCaptureVideoPreviewLayer`, `AVCaptureVideoOrientation`,
`UIPinchGestureRecognizer`, and `Combine.Future`/`AnyPublisher` directly in its
public API (`CameraControlling.swift:7-89`). A consumer cannot use
`CameraController` without `import AVFoundation`, `import Combine`, and
`import UIKit` — the exact opposite of Iris's "SwiftUI-shaped public API"
principle.

The protocol decomposition is good though: `CameraControlling` is a composition
of five sub-protocols (`CameraSessionControlling`, `CameraPreviewControlling`,
`CameraDeviceControlling`, `CameraRecordingController`,
`CameraCaptureResultControlling`) plus an optional
`CameraMetadataControlling`. A `DummyCameraController`
(`controller/DummyCameraController.swift:14`) provides a no-op conformance for
SwiftUI previews — Iris should keep this discipline (a `MockDetector`,
`MockCaptureSource`, etc.).

Cross-module shared types: `PRMetadata` is the canonical sidecar/captured-tag
type and is depended on by `CameraController`, `VideoOverlay`, `VideoEditing`.
`VideoUtils` is the "junk drawer" leaf — `CALayerView`, permissions,
`CGRect+location`, etc. The dep graph is acyclic but `VideoOverlay` depends on
`PRMetadata` (line 102), which leaks the radar-speed domain into the otherwise-
generic overlay module. Painful: `OverlayType` (`overlay/OverlayType.swift:12`)
is hard-coded to `.speedBox` / `.speed(Measurement<UnitSpeed>)` — overlays are
not generic over what they draw.

## Carry forward into Iris (2–3)

- **C1 — `videoNaturalSize` + `videoRect` + single transform.** The
  `OverlayContext` / `OverlayHostLayer` pattern (everything lays out in source
  pixel space, one `CATransform3D` scales to the on-screen rect) is the
  cleanest answer to "where does the coordinate conversion live?" Apply in
  `IrisOverlay` as the canonical conversion site — Vision returns normalized
  [0,1], multiply by `naturalSize` once, render in natural space, let one
  transform handle the scale into `videoRect`. Detectors and overlay-content
  authors stay blissfully unaware of `AVPlayerLayer.videoRect` plumbing.

- **C2 — Capture/preview/UIVC three-tier bridge with `Dummy*` for previews.**
  `UIViewControllerRepresentable` → `UIViewController` → custom `UIView` keeps
  AVKit confined to the bottom tier; the `DummyCameraController` lets SwiftUI
  previews of the *whole stack* render without permission prompts. Iris's
  `CameraPreview` should mirror this, with a `Mock`/`Dummy` `Detector` and
  `Frame` source so visual previews of overlay code work without a camera.

- **C3 — `CGRect.Location` / `LocationAtLocation` anchor-ratio primitive.**
  Tiny value type for "anchor at ratio + offset" with a built-in `flipY` for
  UIKit/CoreAnimation coord-system disagreements
  (`VideoUtils/utils/CGRect+location.swift:28-66`). Drop into `IrisOverlay`
  verbatim — overlays positioning detection bounding boxes inside the video
  rect need this kind of helper and rolling it ad-hoc will produce off-by-one
  bugs.

## Don't repeat (1–2)

- **A1 — Combine-`Subject`-everywhere god-controller.** `CameraController` has
  ~15 `CurrentValueSubject`/`PassthroughSubject` properties, sub-protocols that
  re-export `AnyPublisher<…>`, and `Future`-returning APIs
  (`CameraControlling.swift:24-76`). This will not survive contact with Swift 6
  strict concurrency or `async/await`-end-to-end. Iris should use
  `@Observable` state on the public API and `AsyncStream<Frame>` for the data
  path; reserve Combine for nothing.

- **A2 — Public API leaking AVFoundation/UIKit.** `ensureVideoPreviewLayer(host: UIView) -> AVCaptureVideoPreviewLayer`,
  `selectCameraDevice(AVCaptureDevice)`, `availableCameraDevices: AnyPublisher<[AVCaptureDevice], Never>`,
  and the `videoOrientation: AVCaptureVideoOrientation` plumbing all leak
  AVKit types into the surface. Consumers can't write a unit test or a macOS
  build without dragging the whole stack in. Iris's `CameraSession`/`Camera`
  API should expose Iris-owned value types (`Iris.Camera`, `Iris.Orientation`,
  etc.) and keep AVFoundation behind the seam.

## Opinions on Iris's M1 open questions

1. **`AsyncStream<Frame>` vs `AsyncSequence` protocol.** Weak signal pro-stream.
   The closest analog — `onNewSampleBuffer: (…) async -> Void` plus
   per-frame `Task { … }` (`updateSampleBuffer.swift:37`) — is essentially a
   degenerate `AsyncStream` written by hand and has the obvious flaw of zero
   backpressure. The lesson: if Iris uses `AsyncStream`, set an explicit
   `bufferingPolicy: .bufferingNewest(1)` from day one.

2. **Explicit actor isolation in public API.** Strong signal that a single
   serial queue (`sessionQueue` + `dispatchPrecondition`) is enough discipline.
   That maps cleanly to a `@CaptureActor` global actor in Swift 6 — every place
   that today says `dispatchPrecondition(.onQueue(sessionQueue))` becomes a
   `@CaptureActor` annotation. Worth doing in Iris's public API for the
   `CameraSession` only; do not extend it to `Detector` (per Q4 below).

3. **COCO JSON sidecar.** No signal — `PRMetadata` is a domain-specific
   captured-speed format, not a detection annotation format.

4. **Hot-swap Core ML: tear-down vs swap detector instance.** No detection
   exists, but the broader pattern in this repo argues for **reference type +
   swap-in-place** by analogy: `CameraController` is one long-lived `class`
   with mutable `session: AVCaptureSession?` that gets reconfigured rather than
   recreated (`CameraController.swift:511-541` rebuilds the session inline).
   The discomfort that pattern generated (subtle ordering bugs around
   `beginConfiguration`/`commitConfiguration`) argues the *other* way for
   Iris: prefer value-type `Detector` + replace-the-instance.

5. **macOS overlay parity.** Soft signal pro-parity: `VideoOverlay` is
   declared cross-platform in `Package.swift` but the implementation imports
   `UIKit` throughout (e.g. `OverlayHostLayer.swift:12`,
   `CALayerView.swift`). It builds on macOS only because the Package metadata
   says so — there's no real Mac story. Iris must do better; pick `CALayer`-
   neutral or `SwiftUI.Canvas`-based rendering from the start.

6. **Foundation Models: `Detector` backend, separate `Captioner`, or both.**
   No signal.

## Notes & loose ends

- Swift `5.3.2` (`.swift-version:1`), `swift-tools-version:5.3`,
  `iOS .v14 / macOS .v11`. Deps: only `swift-log` and `swift-algorithms`. No
  Apple Vision, no Core ML.
- `AVSynchronizedLayer` is used as the overlay host
  (`SyncedOverlayHost.swift:10`) — clever trick to keep overlay animations in
  sync with `AVPlayerItem.currentTime()` without polling. Worth knowing for
  `IrisOverlay`'s playback path even though Iris will likely drive animation
  off `Frame` PTS directly.
- The export-vs-playback fork in `OverlayHostLayer` (`hostLayer/OverlayHostLayer.swift:42-48`)
  — playback updates overlays on `main`, export updates on the *current*
  thread or layers render blank — is a real-world gotcha for any "render
  overlays into baked video" feature Iris adds later.
- `CALayerPreView+overlayLayers.swift:13-43` is a `PreviewProvider` rendering
  CALayer-based overlays in isolation at fixed sizes — same spirit as the
  user's "low-level visual previews" pattern, expressed in pre-`#Preview`
  SwiftUI. Iris should adopt the modern `#Preview` equivalent for every
  detection-overlay view.
- Tests are sparse and mostly absent for the camera/playback paths
  (`CameraControllerTests.swift` is a one-line stub). The good tests live in
  `VisionMath` (Solver, equations-of-motion) and `VideoEditing` — domains
  where the math is decoupled from AVKit. Lesson for Iris: keep `IrisDetection`
  and `IrisOverlay` math/coords decoupled so they're testable without a video
  file.
