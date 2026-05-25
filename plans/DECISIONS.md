# Decisions

<!-- Newest at top. Each entry: short title with date, a paragraph that captures
     the decision clearly enough to act on without opening the reference, then a
     link to the exploration that justifies it. Leave a blank line between entries.
     The linked RECOMMENDATIONS.md carries the deep case — don't restate it here. -->

### 2026-05-24 — Detector capability model (M5)

Built-in Vision detectors differ along axes a flat `[Detection]` can't express, so each detector declares a **capability descriptor** — the single source of truth for tuning UI, overlay rendering, and the raw-data inspector. Axes: **(1) geometry kind** (a *set*: box / quad / keypoints / contour / mask / heatmap / labelOnly / scalar); **(2) confidence semantics** — `probabilistic` / `perElement` / `none` / `derivedScalar(label:)`, never a bare `confidence: Float` that fabricates certainty; **(3) tunable-knob set** (reuses `SettingSchema`); **(4) introspectable field set**. Renderability (P3) and inspectability (P4) are two *projections* of the same descriptor, so they can't drift. `derivedScalar(label:)` is how geometric detectors surface a labeled quality ratio (rectangle quadrature deviation / aspect) without it masquerading as confidence. Proven on rectangles (confidence `none`) + 2D human body pose (confidence `perElement`); requires `SettingKind.string` + `.enum` additions for text/symbology knobs.

→ [`explorations/2026-05-24-vision-capability-audit/RECOMMENDATIONS.md`](../explorations/2026-05-24-vision-capability-audit/RECOMMENDATIONS.md)

### 2026-05-22 — Best-effort temporal match in `ResultStore.lookup` via timestamp-keyed cache

`ResultStore` is a `[CMTime: TimestampedDetections]` dictionary keyed on *quantized* asset-time buckets (default: one 30fps frame); `lookup(at:)` is nearest-neighbor within `min(2 × quantization, stale:)`. `DetectorPipeline.detect(in:cache:)` consults the cache via a `DetectionCache` protocol (in `Sources/Iris/Detection/`) before dispatching detectors — re-visiting an already-detected timestamp returns the cached detections without re-running inference. `PlaybackSource` uses `.bufferingNewest(3)` (not `(1)`) so seek-emitted and frame-step frames survive detector congestion; the original 2026-05-20 "Runtime frame pipeline" `.bufferingNewest(1)` contract is preserved for `CaptureSession`. No eviction policy in v1 — revisit when M5's dataset workflows want long-form footage handling.

→ [`features/playback-detection-cache.md`](./features/playback-detection-cache.md) (commits `c6c250f`, `75a9b88`, `3f748d4`, `aa068ee`)

### 2026-05-20 — Single SwiftPM target, folder-organized internally

Iris ships as one Swift package target with a single umbrella library product.
Components (`Capture`, `Playback`, `Detection`, `Overlay`, `Tuning`, `Dataset`)
are folders under `Sources/Iris/` that share `Frame`, `Detector`, and
coordinate-space conventions — not separate targets, not separate packages.
Splitting later (into separate SwiftPM targets, or into adapter repos as
companion packages) is a non-breaking change if module boundaries start
mattering.

→ [`explorations/project-shape-and-tooling/RECOMMENDATIONS.md`](../explorations/project-shape-and-tooling/RECOMMENDATIONS.md)

### 2026-05-20 — Runtime frame pipeline

A `Source<Frame>` protocol sits upstream of `IrisCapture` and `IrisPlayback` so
both feed the same downstream pipeline. Detector and overlay code never branch
on where a frame came from. The contract is `AsyncStream<Frame>` with
`.bufferingNewest(1)` back-pressure, exposed publicly through an `AsyncSequence`
protocol so consumers don't depend on the concrete type. The framework does
**not** spawn per-frame `Task`s — the consumer owns task lifetime through
`for await`, and structured-task cancellation flows through naturally.

→ [`explorations/runtime-pipeline-architecture/RECOMMENDATIONS.md`](../explorations/runtime-pipeline-architecture/RECOMMENDATIONS.md)

### 2026-05-20 — Display pipeline

Overlay rendering is a SwiftUI `Canvas` with one centralized Y-flip. Coordinate
math lives behind a `NormalizedGeometryConverting` protocol with per-source
backends: preview-layer-backed for live capture (delegating to
`AVCaptureVideoPreviewLayer.layerRectConverted`), video-rect-backed for playback
(aspect-fit math against the player's video rect). Callers feed `[Detection]`
and never touch a flip transform or re-derive aspect-fit math.

→ [`explorations/display-pipeline-architecture/RECOMMENDATIONS.md`](../explorations/display-pipeline-architecture/RECOMMENDATIONS.md)

### 2026-05-20 — Foundation Models scope: two protocols, not one

`Detector` (`image → [Detection]`) and `Captioner` (`image → text`) are separate
protocols. VLM backends conform to both rather than collapsing into a merged
super-protocol. Rationale: detection output (bounding boxes) and captioning
output (text) have non-overlapping shapes; forcing every detector to know about
text would break the protocol's single responsibility.

→ [`explorations/swift-ecosystem/RECOMMENDATIONS.md`](../explorations/swift-ecosystem/RECOMMENDATIONS.md)

### 2026-05-20 — `@CaptureActor` in `IrisCapture`'s public API

`IrisCapture` is an `actor` with `nonisolated unownedExecutor` bound to a
`DispatchSerialQueue` (the working blueprint is Apple AVCam's `CaptureService`).
The only nonisolated opening is `nonisolated let previewSource` — everything
else crosses the actor boundary as `async`. This isolation does **not** extend
to `Detector`: detectors have their own concurrency story (`Sendable` protocol;
stateful conformers wrap state in an internal `actor`).

→ [`explorations/swift-ecosystem/RECOMMENDATIONS.md`](../explorations/swift-ecosystem/RECOMMENDATIONS.md) (Apple AVCam blueprint)

### 2026-05-20 — Hot-swap by replacing the instance

To swap a model or detector mid-session, construct a fresh instance and replace
the reference — never reach into a running detector to mutate its model.
`Detector: Sendable`; stateless conformers are `struct`, stateful (e.g.
trajectory detection that needs cross-frame memory) are `actor`. `VNCoreMLModel`
is cached *outside* the detector so teardown only rebuilds the lightweight
request, not the model itself.

→ [`explorations/prior-projects/RECOMMENDATIONS.md`](../explorations/prior-projects/RECOMMENDATIONS.md)

### 2026-05-20 — `DetectorCache` is an injectable instance

`DetectorCache` lives as a `private let` on whatever owns the pipeline or
session, not as a global singleton. Singleton caches cross-contaminate when
multiple detectors run concurrently and break test isolation. Each pipeline
gets its own cache; the cost is negligible because models hash to the same
keys.

→ [`explorations/swift-ecosystem/RECOMMENDATIONS.md`](../explorations/swift-ecosystem/RECOMMENDATIONS.md)

### 2026-05-20 — Strict-concurrency escape hatches

`@preconcurrency import AVFoundation` and `@unchecked Sendable + NSLock +
documented invariant` are the legitimate escape hatches for AVFoundation,
Vision, and CoreML types that aren't Sendable-clean. Forbid plain
`@unchecked Sendable` without a documented locking invariant — that's silencing
the checker, not satisfying it. No Combine in public API: Iris is greenfield,
so there's no retrofit cost to skipping it.

→ [`explorations/swift-ecosystem/RECOMMENDATIONS.md`](../explorations/swift-ecosystem/RECOMMENDATIONS.md)

### 2026-05-20 — macOS parity is a *principle*, not a target

Files compile and render correctly on both iOS and macOS from the moment
they're written. `#if os(iOS)` is reserved for whole-subsystem platform gates
(the entire `Sources/Iris/Capture/` folder is iOS-only); it is never used to
fork the API shape of a single type that exists on both platforms.
Retrofitting macOS later is dramatically more expensive than doing it right
the first time — sportvision proves a 170-line SwiftUI overlay works unchanged
on both; counter-examples in the prior art show what happens when you don't.

→ [`explorations/prior-projects/RECOMMENDATIONS.md`](../explorations/prior-projects/RECOMMENDATIONS.md) and [`explorations/swift-ecosystem/RECOMMENDATIONS.md`](../explorations/swift-ecosystem/RECOMMENDATIONS.md)

### iOS 26 / iPadOS 26 / macOS 26 floor with Swift 6 strict concurrency

The platform floor is driven by four concrete capabilities only available at
this version: the new Vision Swift API (native async/await, Sendable, no Obj-C
bridge); the Foundation Models framework (on-device LLM access); `@Observable`
parity across iOS/macOS; and Swift 6.2 concurrency defaults. Dropping the floor
means losing one of these and rebuilding it by hand. Rationale lives in the
brief.

→ [`BRIEF.md`](./BRIEF.md) ("Why iOS 26 / macOS 26 specifically")
