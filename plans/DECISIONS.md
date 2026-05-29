# Decisions

<!-- Newest at top. Each entry: short title with date, a paragraph that captures
     the decision clearly enough to act on without opening the reference, then a
     link to the exploration that justifies it. Leave a blank line between entries.
     The linked RECOMMENDATIONS.md carries the deep case — don't restate it here. -->

### 2026-05-28 — M7 sidecar reframe: no COCO, name-independent fingerprint, the dataset's filenames are the ledger

**Supersedes the per-image-COCO-sidecar + merge-`COCOExporter` clause in the 2026-05-28 M7 entry below** (the rest of that entry — frame address, two-clock split, injected `baseDir`, output under `<Documents>/iris-dataset/` — still stands). On review the COCO call was rejected: it was inherited from BRIEF §6 without ever being discussed. **(1) No per-image sidecar, and no COCO / no exporter in M7.** A flag means "this frame deserves a second look," NOT a ground-truth label — and since multiple models will be tried, recording one model's verdict (`modelID`/score/"was wrong") as if it were annotation is false precision. Real annotation happens later in an external tool, in whatever format the eventual training pipeline names; **we do not commit to a training format now.** P4 therefore collapses to: leave a `DatasetExporter` protocol **seam** only; build the first concrete exporter when a training pipeline exists and names its consumer. **(2) `AssetFingerprint` becomes name-INDEPENDENT.** `id` = hash of `byteSize` + `durationSeconds` + `headHash` (head-hash is now **mandatory**, not optional). Filename is dropped from the identity (kept only as a display field). This makes the fingerprint **rename-stable** (a renamed source still re-finds its flags) *and* **edit-sensitive** (clipping from the middle shifts duration or head-hash → a genuinely different asset). This corrects the prior claim that the old filename-inclusive fingerprint "survived renames" — it didn't; only this one does. **(3) Provenance lives in the export filename; the dataset's own filenames are the dedup ledger.** Export filename = `<sourceNameHash>_<fingerprintID>_<ptsMillis>.png`, where `sourceNameHash` is a short hash of the source filename — a cosmetic, collision-tolerant grouping prefix (human-visible if not readable, recomputable from a directory listing). **Dedup keys on the `_<fingerprintID>_<ptsMillis>` suffix, not the full name**, so a renamed source still counts as already-exported. The architectural principle: *the "already-exported?" answer must live WITH the dataset (in its filenames), because the dataset can be lost or moved independently of the app's `FlagStore`* — a sidecar or app-side manifest can go stale relative to the data; filenames cannot. Two questions, two homes: "what did I flag?" → `FlagStore` (app-side); "what's already in the dataset?" → the dataset's filenames (data-side).

→ [`features/M7.md`](./features/M7.md)

### 2026-05-28 — M7 — Dataset: canonical frame address is `(content-fingerprint, PTS)`; cheap flag now / deferred extract later; playback-scoped

> ⚠️ **Partially superseded** by the 2026-05-28 sidecar-reframe entry above: the **per-image COCO-shaped sidecar + merge-`COCOExporter`** clause and the **`filename`-inclusive / "survives renames"** fingerprint composition are obsolete. The rest below — frame address, two-clock split, injected `baseDir`, output location — stands.

M7 is a **playback-context** dataset-curation loop (defined in [`features/M7.md`](./features/M7.md)), and these calls constrain how it's built. **Frame address = `FrameRef = (AssetFingerprint, pts)`.** The presentation timestamp is the address, stored as an exact `CMTime` `{value, timescale}` (rational — no float drift); `seek(to:)` `.zero`-tolerance round-trips it to the exact frame. Frame-*index* is rejected (variable frame rate breaks it). **Asset identity is a content fingerprint** (composition now name-independent — see reframe above) — **not** `url.absoluteString`, so reloading a moved/renamed video re-finds its flags; full-file SHA is rejected as too slow on large video. **Two separated clocks:** flagging records metadata only (instant, while scrubbing); extraction is a **deferred headless batch** (`PlaybackSource` default `TaskTickDriver`) that re-seeks each PTS and decodes on demand — pixels never touch the hot loop. **Persistence:** `FlagStore` is library-side (Iris's first on-disk persistence) but takes an **injected `baseDir`** — it does not hardcode the app sandbox. **Output:** under app-managed `<Documents>/iris-dataset/`; `DatasetSink` protocol leaves iCloud/S3 room. (The per-image-sidecar half of this is superseded above — extraction writes provenance-bearing PNGs, no sidecar.) **Dedup** keys on the deterministic filename suffix (see reframe above), making extraction resumable. **Scope is playback only** — live-capture flagging can't re-seek, so it'd need an immediate pixel-buffer snapshot (a different path) and is a follow-on, not v1, despite BRIEF §6's "both contexts".

→ [`features/M7.md`](./features/M7.md)

### 2026-05-27 — Detector swap is a single-loop in-place router swap; the `f4a6284` cancel→drain→respawn "fix" was a no-op

Building `PlaybackDetectionCoordinator` P1 (commit `51743c7`) corrected a misdiagnosis baked into the 2026-05-26 bugfix and the placement entry below. **`PlaybackSource` exposes a single *stored* `AsyncStream` (`_frames` + one `continuation`); cancelling its consuming task terminates the stream permanently**, so a respawned `for await source.frames` receives **zero** frames and every later `yield` returns `.terminated` (verified by an isolated repro). There is **no race** — the "two overlapping `for await` loops" model in the 2026-05-26 LOG is wrong, and the drain serializes nothing load-bearing. The reported "swap does nothing until reload" symptom was therefore **never actually fixed** by `f4a6284` (reload only masks it by building a fresh source → fresh stream). The coordinator instead runs **one detect loop per source** (never respawned) and swaps the detector **in place** by replacing `session.router`; the loop reads the live router on every frame, so `selectDetector` deterministically routes the next frame through the new detector. Teardown keeps cancel→drain→`invalidate()` — there the drain *is* correct (the loop is being killed for good, and the awaited `invalidate()` is the sandbox-scope-release ordering point). **Consequence: the demos still carry the non-functional respawn glue; P2/P3 rewiring them onto the coordinator fixes the demo swap bug for the first time.** This supersedes the "(incl. the cancel→drain→respawn lifecycle)" clause in the placement entry below.

→ [`features/playback-detection-coordinator.md`](./features/playback-detection-coordinator.md) (P1 · Finding 2026-05-27)

### 2026-05-27 — Playback detection orchestration → a library `PlaybackDetectionCoordinator` in `Playback/`

The session-orchestration logic currently duplicated across both demos' `ContentView` — build/teardown the detection task (incl. the cancel→drain→respawn lifecycle), own the `ResultStore` cache + `DetectionMetrics`, build the `ActiveDetectorSession` via `entry.makeSession(cache)`, wire the `onDetectorTierChange → seek` pause-emit hook, and sequence detector/video swaps — will be extracted into one `@MainActor @Observable` **`PlaybackDetectionCoordinator`**. **Placement decided: `Sources/Iris/Playback/`** (it's playback-coupled — needs `PlaybackController` + `seek` for the pause-emit hook). Intents: `setSource(_ source:detector:)` (the demo builds the `PlaybackSource` itself because it holds the security-scoped bookmark, and passes the *source*, not a URL) and `selectDetector(_ entry:)`. The demo keeps only app-specific concerns: file picking + sandbox scope, MRU, the detector catalog + custom-model UI, layout, and binding library views to the coordinator's outputs (`controller`, `resultStore`, `session`, `metrics`). The source-agnostic loop/cache/metrics core is **deliberately not pre-split** — lift it into a `Detection/`-side runner only if/when a capture-side detection consumer lands (splitting later is non-breaking per the single-target doctrine). This also closes the accepted "swap path ships untested" gap: the coordinator is a library type testable with `MockSource`/`ManualTickDriver` + two fixture detectors. The feature plan is **not yet drafted** (next step); the API shape + phasing live in the exploration RECOMMENDATIONS.

→ [`explorations/2026-05-27-demo-library-boundary/RECOMMENDATIONS.md`](../explorations/2026-05-27-demo-library-boundary/RECOMMENDATIONS.md)

### 2026-05-26 — M6 closed (P1–P3); captioning (P4) dropped — Foundation Models is text-only

M6 delivered the Core ML detector end-to-end: the conversion pipeline (P1) → the path-A `VisionObjectDecoder` (P2, Vision auto-decodes an NMS pipeline, zero Swift decode) → the path-B `YOLOEnd2EndDecoder` (P3, raw `[1,300,6]` tensor with a runtime confidence knob via a conditional `TunableDetector` conformance) → bundled + file-picked Path-A model loading (P3, real prewarm, launch-prewarmed bundled models, `.modelNotReady`-aware picker). **P4 (captioning) is dropped, not deferred.** Verified against the MacOSX26.5 SDK: `FoundationModels` is **text-only** — `LanguageModelSession.respond(to:)` takes a `Prompt`/`String` and returns `Response<String>` (or a structured `Generable`); `Prompt` is built purely from text, with **no `CGImage`/`CVPixelBuffer`/`CIImage` image-input path** (the only image-ish symbol, `logFeedbackAttachment`, is unrelated). Vision has **no caption request** (its catalog is detection/classification/saliency/text-recognition; the closest, `ClassifyImageRequest`, returns labels, not a caption). So on-device image→text captioning needs a **vision-language model (VLM) converted to Core ML** — an off-plan lift — which corrects the original "Foundation Models backend" assumption in [`BRIEF.md`](./BRIEF.md) §3 and [`features/M6.md`](./features/M6.md). The user also deprioritized captioning. A future captioning milestone would start from a Core ML VLM, not Foundation Models.

### 2026-05-26 — M6·P3 model loading: real prewarm, bundled-at-launch, file-picked Path-A only

`CoreMLDetector.prewarm()` is now a **real** warmup (it was a no-op in P2): it allocates a synthetic black 640×640 BGRA pixel buffer and runs one `CoreMLRequest.perform` to force Core ML to compile/load its compute path before the first real frame — fully best-effort (failures OSLog-logged + swallowed). Unlike the Vision built-ins (whose `prewarm()` stays an honest no-op — no first-inference cost to hide), Core ML's first-inference cost is genuine. **Bundled models** (yolo12n/yolo26n) load + prewarm **off-main at launch** via a `@MainActor @Observable DemoModelStore` and are cached for the session (non-blocking; degrades gracefully if a model isn't in Resources). **File-picked models reuse the existing session-rebuild swap** and accept **Path-A only** — self-describing NMS pipelines that need zero label config (the `VisionObjectDecoder` path); Path-B file-picking is deferred (it would need a label-supply UI + output-spec auto-detect). `DetectorAvailability` gets its **first UI use**: the picker dims/annotates `.modelNotReady` rows ("— not loaded" until a model loads). File-picking + model UI stay **in the demo** — Iris owns the loading primitive + the detector + availability — per the consumer-owns-UI doctrine. This closes M6·P3 (both halves shipped today).

→ [`features/M6.md`](./features/M6.md)

### 2026-05-26 — M6·P3: path-B decoder + tunability via conditional conformance

The `OutputDecoder` seam from the 2026-05-25 decision carries a **raw-tensor decoder with no `CoreMLDetector` reshape**: a raw-tensor model comes back as a `CoreMLFeatureValueObservation`, and on the MacOSX26.5 SDK the **Sendable** `MLSendableFeatureValue` exposes the tensor via `shapedArrayValue(of: Float.self)` (there is **no `multiArrayValue`** on the sendable wrapper). `YOLOEnd2EndDecoder` decodes the single `[1,300,6]` output — rows `[x1,y1,x2,y2,confidence,classIndex]` = **xyxy in 640-pixel space** (NOT xywh, NOT normalized) — with **no NMS** (the one-to-one head self-dedupes), and **inverts the `.scaleToFit` letterbox + flips Y itself** (path B owns the inverse-mapping Vision does for free on path A, and the YOLO top-left → Vision lower-left flip — this is the box-misalignment risk, verified correct on the dancer clip). **Labels are supplied externally** (`YOLOEnd2EndDecoder(labels:)` + a canonical COCO-80 constant) because the converted `yolo26n` embeds none (empty metadata — disproving the P1 plan's `userDefined`/`names` assumption; the artifact corrected the doc). **Runtime confidence tuning rides a `TunableOutputDecoder: OutputDecoder` sub-protocol + `extension CoreMLDetector: TunableDetector where Decoder: TunableOutputDecoder`** — a conditional conformance, so path A (`VisionObjectDecoder`) stays honestly non-tunable (baked thresholds) while path B gains the knob. `apply` tiering: no-op → `.view`; **raise threshold → `.filter`** (higher-conf rows are a strict subset of the cache — a pure post-hoc predicate, no re-inference); **lower → `.detector(rebuilt:)`** (previously-dropped rows aren't cached — rebuilds the detector around the SAME compiled container, no model recompile; hot-swap-by-rebuild per the M4 doctrine).

→ [`features/M6.md`](./features/M6.md)

### 2026-05-26 — M6·P2: ship Path-A `CoreMLDetector` with baked thresholds; defer runtime tuning to P3

The one-detector + pluggable `OutputDecoder` seam from the 2026-05-25 decision is now realized in code (`Sources/Iris/Detection/CoreML/`): `CoreMLDetector<Decoder: OutputDecoder>` (a `Sendable final class` wrapping a `CoreMLModelContainer`, running `CoreMLRequest.perform(on:orientation:)` with `cropAndScaleAction = .scaleToFit`) + the `OutputDecoder` protocol + `VisionObjectDecoder`. **P2 ships `VisionObjectDecoder` (Path A) only and conforms `CoreMLDetector` to `Detector`, not `TunableDetector`** — Path-A NMS pipelines bake the IoU/confidence thresholds at export time, so there are no runtime threshold knobs to expose; adding them is the P3 question (it forces a path-B raw-tensor decoder + Swift NMS, decided alongside `YOLOEnd2EndDecoder`). Empirical SDK confirmations baked into the design: `CoreMLRequest.Result == [any VisionObservation]`, and an NMS object-detection pipeline yields concrete `RecognizedObjectObservation` (probed at runtime) carrying `boundingBox: NormalizedRect` (normalized lower-left, matches `Detection.boundingBox` — no flip, no letterbox-inverse) + best-first `labels` + `confidence`; `cropAndScaleAction = .scaleToFit` is aspect-preserving letterbox **and** Vision applies the inverse transform to the returned boxes, so "never hardcode 640" is satisfied for free (Vision reads the model's input size). Catalog integration is an additive non-tunable `DetectorCatalogEntry.make(id:displayName:detector:)` overload for plain `Detector`s + a `PassthroughRouter` — no fake `TunableDetector` conformance; a `DemoCatalog` composes `builtInVision + YOLOv12n` for both demo apps.

→ [`features/M6.md`](./features/M6.md); [`explorations/2026-05-25-coreml-model-conversion/RECOMMENDATIONS.md`](../explorations/2026-05-25-coreml-model-conversion/RECOMMENDATIONS.md)

### 2026-05-25 — Core ML detector: start with YOLOv12 (Path A), pluggable `OutputDecoder` seam

The PyTorch→Core ML toolchain is verified empirically (ultralytics 8.4.54, coremltools 9.0, M1 Max) and M6 wires it into Iris through **one `CoreMLDetector` with a swappable `OutputDecoder`**, not two detectors. **Start with YOLOv12** — it is the **true zero-decode Path A**: `yolo export … nms=True` yields an Apple `NonMaximumSuppression` pipeline with `coordinates`+`confidence` outputs and 80 COCO labels baked into the NMS stage, so Vision auto-decodes and `CoreMLDetector` + `VisionObjectDecoder` is a thin adapter with no Swift box-decode. (`nms` defaults to **false** — a bare export is Path B.) **YOLO26 is Path B, not A:** ultralytics *forces* `nms=False` on end2end models (warns *"'nms=True' is not available for end2end models"*), so it always exports as a raw `[1,300,6]` tensor needing a **trivial** `YOLOEnd2EndDecoder` — threshold + scale the ≤300 rows, **NO NMS** (the one-to-one head self-dedupes), labels from `userDefined` `names`. RF-DETR's `DETRSetPredictionDecoder` is a later additive plug-in through the same seam (off the critical path — see [`QUESTIONS.md`](./QUESTIONS.md)). Always verify the decode path against the exported artifact (`inspect_model.py`) before writing Swift — a doc-only pass got YOLO26's path wrong; the empirical re-run corrected it. Pin each model's fixed input size + aspect-preserving scale-to-fit (never hardcode 640). Caveat folded into M6's opens: `nms=True` bakes IoU/conf thresholds at export, so runtime-tunable thresholds would force Path B or a re-export.

→ [`explorations/2026-05-25-coreml-model-conversion/RECOMMENDATIONS.md`](../explorations/2026-05-25-coreml-model-conversion/RECOMMENDATIONS.md); plan in [`features/M6.md`](./features/M6.md)

### 2026-05-25 — VideoGeometry is the single coordinate-mapping authority

`VideoGeometry` (a pure `Sendable` value type: `contentSize` + `containerSize` + `contentMode` → `displayRect` + Y-flip) is now the one place normalized detection coordinates are mapped into view space, replacing the scattered `videoRect` math. It deliberately does **not** handle rotation or mirroring. By the time anything reaches the overlay, frames and detections are already **upright**: capture rotates the buffer on the `AVCaptureConnection` and stamps `.up`; Vision is given `frame.orientation` so its normalized coords are already in upright space; the player displays upright. So the overlay's only job is to place upright-normalized "truth" into the displayed (letterboxed / scaled / cropped) video "box" and flip Y — rotation and mirroring are source-level concerns. This reverses an earlier same-day exploratory direction that built rotation + mirror into the geometry; the static preview gallery surfaced that as the wrong layer (an architecture catch, not a pixel one). `DetectionLayer` now takes a size-keyed `makeConverter: (CGSize) -> any NormalizedGeometryConverting` with a single `GeometryReader` as the measurement point; `PlayerLayerConverter` is retired (its math folded into `VideoGeometry`); iOS live capture keeps delegating to `AVCaptureVideoPreviewLayer` via `PreviewLayerConverter`. The macOS overlay blank was caused by feeding `AVPlayerLayer.videoRect` (an AppKit bottom-left value) into top-left Canvas math; the fix computes `displayRect` in pure SwiftUI space from `AVPlayerItem.presentationSize`.

### 2026-05-25 — Self-describing detections (geometry + readout ride on `Detection`)

M5·P3 needed the generic overlay to draw skeletons and honest numerics without learning per-detector domain knowledge. Decision: that knowledge rides **on the `Detection` value**, not in the overlay and not (for rendering) in `DetectorCapabilities`. Vision returns only a flat `[JointName: Joint]` dictionary with no edges, so the producing detector stamps the **skeleton edge topology** (`Detection.skeleton: Skeleton?` — name-keyed `Skeleton.Edge`s; the generic `Skeleton` type lives in the Detection domain, the canonical `humanBodyPose` instance lives *with* the detector that produces it) and a **meaningful numeric readout** (`Detection.readout: Readout?` — rectangle aspect ratio, pose joint count; never a fabricated `%`). `DetectionLayer` then dispatches **skeleton → quad → box** and renders whatever each detection carries (every point through the centralized `converter`, no re-derived Y-flip); the default `OverlayStyle.labelFormat` surfaces `readout` and never emits confidence. Capabilities stays the source of truth for *tuning UI + the P4 inspector*; *rendering* is driven by the self-describing detection — the two are complementary projections, not competitors. Rationale: keeps the overlay decoupled (CLAUDE.md invariant) with no `sourceModelID → capabilities` registry plumbed into the view; the cost (type-level topology riding on instances) is absorbed by copy-on-write shared storage. Rejected: topology on capabilities (needs that plumbing) and overlay-hardcoded body-pose adjacency (couples the generic overlay to one detector's domain).

→ commits `e0700a7` (quad), `8ba40e6` (skeleton), `1ef2f3e` (readouts); plan in [`features/M5-honest-detectors.md`](./features/M5-honest-detectors.md)

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
