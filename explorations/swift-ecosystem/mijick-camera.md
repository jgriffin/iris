# MijickCamera — prior-art read

**Path:** github.com/Mijick/Camera · 622★ · iOS 14+ · v3.0.3 (2025-09-30)
**Read date:** 2026-05-20
**Priority lens:** SwiftUI public-API shape — where's the boundary Iris should keep vs drop

## At a glance

Swift 6 strict, iOS-only, ~4,000 LOC across 60 files. **One product, one umbrella view: `MCamera`.** Internally split into `Internal/` (manager, gesture bridge, Metal preview, default screens) and `Public/` (the four protocols + modifier methods + enums). Single dependency: `MijickTimer` (recording-duration ticker). Mac is not a target.

The package is *opinionated*: `MCamera()` is a turnkey camera **app shell** — error screen, capture screen, captured-media review screen, with a fluent builder API for swapping each. Frame plumbing is internal and not exposed.

## Capture entrypoint

`MCamera` is `public struct MCamera: View` (`MCamera.swift:93`). Its only stored state is `@ObservedObject var manager: CameraManager` plus a private `Config`. The public init takes nothing — it constructs `CameraManager(captureSession: AVCaptureSession(), captureDeviceInputType: AVCaptureDeviceInput.self)` (`Public+CameraSettings+MCamera.swift:16-21`). Note the indirection: `CaptureSession` and `CaptureDeviceInput` are internal protocols with both `AVCaptureSession` and `MockCaptureSession` conformances — entirely for testability, not for caller substitution.

`CameraManager` is `@MainActor public class CameraManager: NSObject, ObservableObject` (`CameraManager.swift:15`). It's `public` only so that the user's custom `MCameraScreen` can receive it as `@ObservedObject` — but it has **no public init** and no public mutable surface (all `func setX(...)` are package-internal). Callers manipulate it through `MCameraScreen` protocol methods or `MCamera` modifier chain.

Preview rendering is a two-layer stack inside one `UIView`:
1. `AVCaptureVideoPreviewLayer` (set up in `setupCameraLayer`, made `isHidden = true`).
2. `CameraMetalView: MTKView` rendered on top, driven by `AVCaptureVideoDataOutputSampleBufferDelegate` so CIFilters can be applied live.

The `UIView` is bridged into SwiftUI via `CameraBridgeView: UIViewRepresentable` (`CameraView+Bridge.swift:14`), with `UITapGestureRecognizer` (focus) and `UIPinchGestureRecognizer` (zoom) added in `makeUIView`. The Representable is `Equatable` with `static func == { true }` to prevent SwiftUI rebuilds.

Permissions: `CameraManagerPermissionsManager.requestAccess(parent:)` is called inside `manager.setup()`, throwing `MCameraError.cameraPermissionsNotGranted` or `.microphonePermissionsNotGranted`. The error surfaces by mutating `manager.attributes.error`, which `MCamera.body` reads to swap to the error screen. **Fully built-in** — caller never asks for permission themselves.

## Frame plumbing

**No public frame hook.** `CameraMetalView.captureOutput(_:didOutput:from:)` (`CameraView+Metal.swift:179`) receives every `CMSampleBuffer`, converts to `CIImage`, applies CIFilters, and re-renders via Metal. The frame never leaves the class. There is no `AsyncStream`, no closure, no delegate — the architecture treats frames as a private rendering implementation detail.

Public output is files only: `onImageCaptured((UIImage, Controller) -> ())` and `onVideoCaptured((URL, Controller) -> ())`. Photo capture goes through `AVCapturePhotoOutput`; video through `AVCaptureMovieFileOutput` with optional offline re-encode through `AVVideoComposition` to bake in filters (`CameraManager+VideoOutput.swift:117`).

To add a frame stream you'd modify `setupFrameRecorder` (`CameraManager.swift:87-92`) to install a *second* `AVCaptureVideoDataOutput` (or split the existing one's delegate fan-out), then expose an `AsyncStream<CMSampleBuffer>` on `CameraManager`. The architecture doesn't preclude this — but the package is intentionally a media-capture app, not an analysis pipeline.

## Detection path

No detection slot. `CameraManager` knows about `CameraOutputType.photo` and `.video` only. There's no extension point for "do something else with each frame." Building detection on top would require holding a reference to `CameraManager`, accessing the (currently private) `CameraMetalView.currentFrame: CIImage?` via polling, and re-implementing the sample-buffer fan-out — fighting the design.

## Overlay coordinate-space handling

Nothing transferable. The Metal view does `CIImage.oriented(parent.attributes.frameOrientation)` and the focus gesture does its own ad-hoc conversion in `CameraManager.convertTouchPointToFocusPoint` (`CameraManager.swift:219-222`) with a hardcoded `(y/h, 1 - x/w)` for portrait — not a reusable coordinate-space utility. Front-camera mirroring lives on the `AVCaptureConnection` for the *recording* path (`configureOutput` in `CameraManager+VideoOutput.swift:68-73`), separately from the preview rendering. Iris cannot borrow anything here.

## Public API shape (priority lens for this project)

The public surface is **four protocols + one View + builder DSL**:

```swift
public struct MCamera: View                                       // the entrypoint
public protocol MCameraScreen: View                               // user replaces this
public protocol MCapturedMediaScreen: View                        // optional review screen
public protocol MCameraErrorScreen: View                          // permission-denied UI
@MainActor public class CameraManager: NSObject, ObservableObject // injected into MCameraScreen
```

Plus three `@MainActor`-isolated typealiases that define the slot shape (`Typealiases.swift:14-16`):

```swift
public typealias CameraScreenBuilder = @MainActor (CameraManager, Namespace.ID, _ closeMCameraAction: @escaping () -> ()) -> any MCameraScreen
```

The fluent DSL lives in one giant file (`Public+CameraSettings+MCamera.swift`, 396 lines) — every modifier returns `Self`:

```swift
func setCameraScreen(_ builder: @escaping CameraScreenBuilder) -> Self
func setCameraOutputType(_ cameraOutputType: CameraOutputType) -> Self
func onImageCaptured(_ action: @escaping (UIImage, MCamera.Controller) -> ()) -> Self
func onVideoCaptured(_ action: @escaping (URL, MCamera.Controller) -> ()) -> Self
func startSession() -> some View   // terminal — flips `config.isCameraConfigured`
```

The `.startSession()` terminator is the *only* thing that flips `Config.isCameraConfigured = true`; until then `MCamera.body` returns an empty view. This is the SwiftPM equivalent of "must call `.resume()` on a `URLSessionDataTask`" — unusual for a SwiftUI view, and a smell.

**Composability is one-way:** the user can swap any of the three screens (camera / captured-media / error) by providing a builder, and `DefaultCameraScreen` exposes per-button feature flags (`captureButtonAllowed(false)`, etc.). But the preview view (`CameraBridgeView`) is reachable **only** through `MCameraScreen.createCameraOutputView()` — a default-implemented method on the protocol. You cannot render the preview outside an `MCamera`-managed `MCameraScreen`. The session lifecycle is glued to `onCameraAppear` / `onCameraDisappear` (`MCamera.swift:158-166`).

Size: ~4,032 LOC, 60 files, single library product. Surgical-ish for what it does (full camera app) — but every line is in service of the turnkey shell. Strip out `DefaultCameraScreen`, `DefaultCapturedMediaScreen`, focus indicator, blur-flip animations, the orientation lock, and the `MTimer` recording counter, and ~70% of it is gone.

## Where Iris should draw the line

| MijickCamera piece | Iris counterpart | Decision |
|---|---|---|
| `CameraBridgeView: UIViewRepresentable` (preview as SwiftUI view) | `IrisCapture.CameraPreview` | **Keep the shape** — `UIViewRepresentable` wrapping a `UIView` that hosts `AVCaptureVideoPreviewLayer`. Skip the Metal `MTKView` overlay unless Iris ships its own filter pipeline (it shouldn't — `IrisOverlay` does drawing in SwiftUI). |
| `CameraManager: @MainActor ObservableObject` | `IrisCapture.CaptureSession` | **Borrow the @MainActor-isolated Observable pattern**, but Iris should use `@Observable` (the macro) not `ObservableObject`, and the type should be `public` *with* a public init — Iris is a library, not an app. |
| `CameraManagerPermissionsManager` baked into `setup()` | Iris permissions | **Keep the convenience**: a `CaptureSession.start() async throws` that requests AVCaptureDevice authorization internally and throws a typed error. Don't force callers to wire it themselves. |
| `MCamera` view (full app shell) | — | **Drop.** Iris has no equivalent. `IrisCapture.CameraPreview` is a leaf view; the app composes it with overlays/controls itself. |
| `DefaultCameraScreen`, `DefaultCapturedMediaScreen`, error screen | — | **Drop.** No built-in UI shell. Iris ships no capture button, no review screen, no controls. |
| `.startSession()` terminator | — | **Drop.** Lifecycle ties to `.task { try await session.start() }` on the SwiftUI view, not a modifier sentinel. |
| File-output callbacks (`onImageCaptured`, `onVideoCaptured`) | `IrisDataset` (separate module) | **Move.** Capture only emits frames; one-tap photo/video saving is `IrisDataset`'s job. |
| **No `AsyncStream<Frame>`** | `IrisCapture` core deliverable | **Add what they didn't.** Install `AVCaptureVideoDataOutput`, expose `AsyncStream<Frame>` alongside the preview view as a sibling, not a child of any UI. |

## Carry forward into Iris (2–3)

1. **`UIViewRepresentable` + an internal `UIView` host + `static func == { true }` on the Representable to suppress rebuilds** (`CameraBridgeView` line 41). This is the textbook way and worth copying verbatim — the Equatable trick alone prevents accidental `makeUIView` thrash when parent SwiftUI state changes.
2. **`@MainActor` on the manager, `nonisolated` only on the precise hop that calls `captureSession.startRunning()`** (`CameraManager.swift:112`). Swift 6 strict-concurrency-clean pattern: state on main, the blocking AVFoundation hop is `nonisolated async`. Iris's `CaptureSession.start()` should do the same.
3. **Permissions handled inside `setup()`, errors surface via published state** (`CameraManager+PermissionsManager.swift`). Lets the caller render different views based on `session.state` without writing permission boilerplate. Adopt as `IrisCapture.SessionState.{idle, requestingPermission, permissionDenied(MediaType), running, failed(Error)}`.

## Don't repeat (1–2)

1. **The `.startSession()` modifier sentinel.** `MCamera` returns an empty view until you call `.startSession()` — a footgun documented as `// MUST BE CALLED!` in every code sample. SwiftUI views shouldn't have hidden activation steps; use `.task { ... }` lifecycle on the host view.
2. **Burying `CameraBridgeView` behind `MCameraScreen.createCameraOutputView()`.** This forces every consumer to wrap their preview in an opinionated full-screen container. Iris's `CameraPreview` must be a public, standalone view: `CameraPreview(session: session)` should work in any SwiftUI layout, including a small inset view, side-by-side comparisons, or none at all.

## Opinions on Iris's still-open questions

- **Source-protocol unification (capture + playback).** MijickCamera doesn't address this — it's iOS-only and file-output-only. The fact that frames never escape `CameraMetalView` to a Sendable boundary is a *cautionary tale*: design the `Frame` value type and `AsyncStream<Frame>` exit point on day one, before any rendering plumbing is built. If Iris does this from the start, capture and playback unify naturally.
- **DetectorCache ownership.** MijickCamera owns the AVCaptureSession in `@MainActor CameraManager`. The Metal view holds the GPU resources (`CIContext`, `MTLCommandQueue`). The split is reasonable: session state on main, GPU resources on the rendering object. By analogy, `IrisDetection.DetectorCache` should live wherever the inference call site is (probably an actor or `@MainActor` Observable) — not on `IrisCapture.CaptureSession`. Keep capture ignorant of detection.
- **Cancellation policy.** `MCamera.onDisappear → manager.cancel() → captureSession.stopRunningAndReturnNewInstance()` rebuilds the session each cycle (`CameraManager.swift:130`). That's *one* policy — tears down completely. The alternative (pause-and-resume) isn't offered. Iris should support both: `session.stop()` for transient pause, `session.invalidate()` for permanent teardown. Map the `Task` cancellation of the consumer of `AsyncStream<Frame>` to `session.stop()`.
- **Q3 sidecar format / Q6 Foundation Models** — MijickCamera offers no signal. Out of scope for this package.

## Verdict

**Study then diverge.** The `UIViewRepresentable` preview shape, the `@MainActor` session manager pattern, and the baked-in permissions flow are worth adopting verbatim. Everything else — the `MCamera` shell, the screen-builder DSL, the `.startSession()` terminator, the absence of a frame hook — is the *opposite* of what Iris needs.

## Notes & loose ends

- `CameraManager.Controller` is a one-field struct (`let mCamera: MCamera`) with methods like `reopenCameraScreen()` in `Public+CameraSettings+MCameraController.swift`. It's a flow-control handle passed to `onImageCaptured`/`onVideoCaptured`. Iris doesn't need this — `AsyncStream` cancellation handles it.
- The `MCameraMedia: Sendable` value type (`Internal/Models/MCameraMedia.swift`) is the only `Sendable` type that crosses isolation boundaries publicly. Iris's `Frame` should aspire to the same: a single value type that flows across actors without ceremony.
- Tests: `Tests/MijickCameraTests/` exists and uses the mock `CaptureSession`/`CaptureDeviceInput` injected at `CameraManager.init`. The mocks-via-protocols pattern is mature; Iris should adopt the same for `Detector` (mock detector returning fixture detections) and `Frame.Source` (mock source playing back a fixed buffer sequence).
- iOS 14 minimum constrains them off `@Observable`. Iris targets iOS 26, so `@Observable` is the correct choice over `ObservableObject`.
