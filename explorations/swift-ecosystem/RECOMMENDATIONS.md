# Recommendations from the Swift package ecosystem scan

**Read date:** 2026-05-20
**Source:** deep reads of 5 shortlisted external packages — full notes in this folder. Headline scan and per-package verdicts in [`SHORTLIST.md`](./SHORTLIST.md).

This file is scoped to recommendations from the external Swift package ecosystem deep-read. Recommendations from the in-house prior-art reads (5 projects in `~/dev/`) live in [`../prior-projects/RECOMMENDATIONS.md`](../prior-projects/RECOMMENDATIONS.md). The cross-cutting rollup that synthesizes both is at [`../RECOMMENDATIONS-PRIOR-ART.md`](../RECOMMENDATIONS-PRIOR-ART.md).

---

## Per-package verdicts

| Package | Notes | Verdict | One sentence |
|---|---|---|---|
| Apple AVCam SwiftUI sample | [apple-avcam.md](./apple-avcam.md) | **Borrow** | Mirror `CaptureService` line-for-line for session lifecycle, custom serial executor, `PreviewSource` indirection, `OutputService` extensibility — diverge to add `AsyncStream<Frame>` and drop Combine. |
| NextLevel | [nextlevel.md](./nextlevel.md) | **Study then diverge** | Lift `SendablePixelBuffer` shape + `recording-session actor / capture-class queue` split; reject the singleton + delegate-only API. |
| MijickCamera | [mijick-camera.md](./mijick-camera.md) | **Study then diverge** | Borrow `UIViewRepresentable` + `@MainActor` Observable manager + baked-in permissions; drop the `MCamera` app-shell + `.startSession()` sentinel + buried preview. |
| Kadr | [kadr.md](./kadr.md) | **Borrow structurally** | Companion-package split (separate repos), `@unchecked Sendable + NSLock` invariant pattern, surface-then-engine tier rollout transfer; DSL shape and coordinate vocabulary don't. |
| PrivateFoundationModels | [private-foundation-models.md](./private-foundation-models.md) | **Study then diverge** | Direct pattern transfer to `Detector`/`Captioner` shape (concrete `AsyncThrowingStream`, additive default-impl multimodal, separate-protocol-per-IO-shape, `prewarm`/`availability`/`modelIdentifier`); don't take as a runtime dep. |

## Headline updates these reads suggest for BRIEF.md

1. **Package-layout fork.** Current BRIEF.md models the six Iris modules as targets within a single `iris` package. **Kadr's lived experience says core single-target + adapter packages as separate repos is the better unit.** Iris's `IrisOverlay`, `IrisDataset`, `IrisTuning` could each be their own Swift package (`iris-overlay`, `iris-dataset`, `iris-tuning`) depending on a core `iris` (holding `IrisCapture` + `IrisPlayback` + `IrisDetection` + the `Frame` / `Detection` / `Detector` types). Benefits: per-package platform requirements (capture stays iOS-only without polluting core), independent semver, third-party deps confined to adapter that needs them. **Architectural decision worth making before M1 plans lock.** Surfaced as a new open question below.
2. **Q6 (Foundation Models scope) resolved: two protocols, not one.** PFM's `EmbeddingBackend` / `LanguageModelBackend` split codifies the principle: separate protocols when I/O shapes don't overlap. Detection (`image → [Detection]`) and captioning (`image → text`) have non-overlapping outputs. **Iris ships `Detector` and `Captioner` as separate protocols**; VLM backends conform to both.
3. **`@CaptureActor` shape is concrete.** Apple AVCam's `CaptureService` uses `nonisolated unownedExecutor: UnownedSerialExecutor` bound to a `DispatchSerialQueue`, with `nonisolated let previewSource` as the only opening in the actor wall. This is *the* working blueprint — Iris's `IrisCapture` actor should mirror it.
4. **`@preconcurrency import AVFoundation` is acceptable.** Apple's own AVCam uses it. So does NextLevel. Kadr documents `@unchecked Sendable + NSLock + load-bearing invariant doc-comment` as the canonical pattern for AVFoundation/Vision/CoreML types that aren't Sendable-clean. The realistic Swift 6 strict-concurrency story is not "all reference types become actors" — it's "use the escape hatches deliberately, document the invariants."

## New principles (add to project-wide list)

- **Companion-package split.** Core single-target package + adapter packages as separate repos with one-way `from: "x.y.z"` deps on core (Kadr's pattern, per-adapter platform floors allowed).
- **Drop-in source compat with Apple types where possible.** PFM re-exports nested namespaces (`LanguageModelSession.Response` typealiases) so the same code compiles against either `import PrivateFoundationModels` or `import FoundationModels`. For Iris: if a `Detector.detect(in:)` shape can match Apple's `*Request` calling convention, do so.
- **Additive protocol methods with default impls instead of versioned protocols.** PFM grows `LanguageModelBackend` over time by adding methods with sensible defaults so existing conformers keep compiling. Iris should follow the same pattern for `Detector` capability growth (stateful, multimodal, batch).

## New patterns to lift (with pointers)

### Async + concurrency
- **`actor CaptureService` + custom `DispatchSerialQueue` serial executor** — `nonisolated var unownedExecutor: UnownedSerialExecutor { sessionQueue.asUnownedSerialExecutor() }`. [Apple AVCam `CaptureService.swift:14`](./apple-avcam.md).
- **`@preconcurrency import AVFoundation`** as the Apple-blessed escape hatch when AVFoundation isn't Sendable-clean.
- **`@unchecked Sendable + NSLock + documented invariant`** for `AVCaptureSession`/`AVAssetExportSession`/`VNRequest`/`MLModel` on macOS. [Kadr `CancellationToken.swift` pattern](./kadr.md).
- **`SendablePixelBuffer` / `UnsafeSendableDictionary` immutable wrappers** for crossing actor boundaries with framework types. [NextLevel `NextLevel.swift:38-64`](./nextlevel.md). Iris's `Frame` envelope mirrors exactly this shape — internal `@unchecked Sendable` with explicit doc-comment reasoning, not `@preconcurrency` leaking through the public surface.
- **`SendableMetatype` on a `@MainActor` protocol** so the metatype can cross isolation. [Apple AVCam `Model/Camera.swift`](./apple-avcam.md). Swift 6.2 idiom worth lifting.
- **Recording-session as `actor`, capture-root as queue-backed class.** The capture root must be `AVCaptureVideoDataOutputSampleBufferDelegate` (NSObject lineage) — it stays class-typed with serial-queue discipline. The mutable per-session state (clips, transcript, dataset capture buffer) goes in an `actor`. [NextLevel's load-bearing split](./nextlevel.md). Maps to Iris: `IrisCapture.Session` as queue-backed class; `IrisDataset` writer as `actor`.

### Public-API & extensibility
- **`PreviewSource: Sendable` / `PreviewTarget` indirection.** Don't expose `AVCaptureSession` to SwiftUI — give consumers a `Sendable` source that connects to a private target. [Apple AVCam `Views/CameraPreview.swift:11`](./apple-avcam.md). The cleanest UIKit-bridge boundary in the prior art.
- **`OutputService` protocol as extensibility seam.** Iris's `FrameStreamCapture` and a `Detector`-fronted `VisionCapture` both become `OutputService` conformers managed by the capture actor. [Apple AVCam `DataTypes.swift:152`](./apple-avcam.md).
- **`Camera` view-model protocol** — `public protocol Camera: AnyObject, SendableMetatype, @MainActor` with all `async` methods + getters, no AVFoundation in the surface. [Apple AVCam `Model/Camera.swift`](./apple-avcam.md). Almost exactly the shape Iris's `IrisCapture.Source` should expose to apps.
- **`UIViewRepresentable` with `static func == { true }`** to suppress accidental rebuilds. [MijickCamera `CameraView+Bridge.swift:41`](./mijick-camera.md). Cheap trick, prevents real bugs.
- **Permissions baked into `session.start() async throws`** with typed errors surfaced as session state. [MijickCamera `CameraManager+PermissionsManager`](./mijick-camera.md). Adopt as `IrisCapture.SessionState.{idle, requestingPermission, permissionDenied(MediaType), running, failed(Error)}`.

### Detection
- **`Detector` protocol shape derived from PFM's `LanguageModelBackend`:**
  - `var availability: Detector.Availability { get }` — enum with `.deviceNotEligible / .modelNotReady / .custom`
  - `var modelIdentifier: String { get }` — for telemetry and dataset sidecar
  - `func prewarm() async`
  - `func detect(in frame: Frame) async throws -> [Detection]`
  - `func detectStream(in frame: Frame) -> AsyncThrowingStream<DetectionDelta, Error>` — for trajectory/temporal/streaming detectors
  - **Multimodal/captioning bolted on later via additive default-impl methods**, so a `Captioner`-style method (or separate protocol) doesn't require a protocol version bump
- **Concrete `AsyncThrowingStream`, not `some AsyncSequence`.** PFM dodges the existential/opaque-type dance. [PFM `LanguageModelBackend.swift:12-86`](./private-foundation-models.md).
- **Stateful detector state lives inside the conformer** (probably as an `actor` instance var for trajectory). The `Detector` protocol stays stateless-looking. [PFM pattern](./private-foundation-models.md).

### Rotation & coordinate handling
- **`AVCaptureDevice.RotationCoordinator`** — both preview connection and capture connections get the same observed angle. [Apple AVCam `CaptureService.swift:366`](./apple-avcam.md). Iris should adopt this rather than rolling its own orientation handling.

## New additions to M1 scope (beyond the 7 from in-house reads)

1. **`prewarm() async` on `Detector`** — beyond just `warmup()`; PFM's name + shape.
2. **`availability: Detector.Availability` and `modelIdentifier: String`** on the `Detector` protocol from day one.
3. **`AVCaptureDevice.RotationCoordinator`-based rotation handling** in `IrisCapture` and `IrisOverlay` — don't roll your own.
4. **Interruption recovery pre-empted in `IrisCapture`** — pause on `wasInterrupted`, resume on `interruptionEnded` with ~100ms `AVAudioSession` settle delay. [NextLevel scar #281](./nextlevel.md).
5. **Multi-subscriber `AsyncStream` broadcast** — `[UUID: Continuation]` shape. [NextLevel cautionary tale](./nextlevel.md): they stored continuations as single `Any?` and the second subscriber silently overwrote the first.
6. **Photo-output dictionary key validation** — never set both `kCVPixelBufferPixelFormatTypeKey` and `AVVideoCodecKey` (AVFoundation crashes). [NextLevel issue #286](./nextlevel.md).
7. **Per-frame back-pressure: `AsyncStream.makeStream(of: Frame.self, bufferingPolicy: .bufferingNewest(1))`** as the contract. **Do NOT spawn a `Task { ... }` per frame inside the framework** — leave task management to the consumer of `for await frame in capture.frames`. [NextLevel anti-pattern: `_activeTasks: [Task<Void, Never>]` + NSLock to chase per-frame leaks](./nextlevel.md).
8. **`MockDetector` / `MockCaptureSource` / `MockFrameSource` conformers** for SwiftUI previews and tests without permissions/models/files. [MijickCamera mocks-via-protocols pattern + ios-videoCapture `DummyCameraController` precedent.]

## New anti-patterns (from external reads)

- **Singleton `.shared` + N delegate sockets + delegate-only per-frame hook** (NextLevel `NextLevel.shared` + 9 delegates).
- **`.startSession()` modifier sentinel** that activates an otherwise-empty view (MijickCamera).
- **Per-frame `Task { ... }` spawning inside the framework** (NextLevel — schedules unboundedly at 30/60 fps, requires hand-rolled `_activeTasks` + `NSLock` accounting).
- **`AsyncStream` continuations stored as single `Any?`** (NextLevel — silent overwrite of second subscriber).
- **Result-builder DSL for non-tree pipelines** (would be wrong for Iris — Kadr's contrast).
- **Bridging actor state to MainActor via Combine `@Published` + `Publisher.values` re-subscription** (Apple AVCam retrofit — Iris is greenfield, skip Combine entirely).
- **Burying the preview view behind a turnkey screen protocol** (MijickCamera's `MCameraScreen.createCameraOutputView()` forces every consumer into the full-screen app shell). Iris's `CameraPreview(session:)` must be standalone.
- **`nonisolated(unsafe) var`** on actor mutable state (NextLevel `NextLevelSession.swift:634`) — same smell as `@unchecked Sendable` without the locking discipline.

## Resolutions surfaced by the ecosystem scan

(Cross-referenced against questions raised in [`../prior-projects/RECOMMENDATIONS.md`](../prior-projects/RECOMMENDATIONS.md)'s "Still open" section; the rollup at [`../RECOMMENDATIONS-PRIOR-ART.md`](../RECOMMENDATIONS-PRIOR-ART.md) consolidates.)

- **Q6 Foundation Models scope** — **RESOLVED.** Two protocols: `Detector` and `Captioner`. VLM backends conform to both. (PFM `EmbeddingBackend`/`LanguageModelBackend` precedent.)
- **`Source`-protocol unification upstream of `IrisCapture`/`IrisPlayback`** — **RESOLVED, do it.** Apple AVCam's `OutputService` and `PreviewSource` patterns plus NextLevel's negative example (delegate-only frames lock consumers to AVCaptureSession semantics, including the `onQueue:` parameter leaking into the protocol).
- **`DetectorCache` ownership** — **RESOLVED-leaning.** Injectable instance per pipeline/session (PFM's snapshot-at-construction model + Apple AVCam's `DeviceLookup` as `private let` precedent). Not a singleton.
- **Cancellation policy** — **RESOLVED.** `AsyncStream` with `bufferingPolicy: .bufferingNewest(1)` + consumer-owned task lifetime + structured `Task` parent/child cancellation through the `for await`. The framework does NOT spawn per-frame tasks.

## What stays open after this scan

- **Q3 sidecar format** (COCO vs YOLO vs Create ML JSON). No new signal from external packages. Decide on domain merits.
- **NEW: Package layout — single-package multi-target vs core-package + adapter-repos.** Kadr's lived experience says split into adapter repos; the current BRIEF.md plan is single-package multi-target. Real architectural fork before M1 plans lock. Recommend deciding before writing any `Package.swift`.
- Whether `Detector` should *require* an `actor` for stateful conformers, or whether `Sendable` + conformer's choice of `actor`-vs-class is sufficient. PFM votes for the latter (protocol-level `Sendable`, conformer holds the actor internally). Tentative call: protocol stays `Sendable`-only, stateful conformers use `actor` internally.
