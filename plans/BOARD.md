<!-- The board: where work stands (Status), the path (Milestones), what's deferred (Backlog).
     Status rewritten each block; Milestones/Backlog edited as they change. Best viewed monospace. -->

# Iris — Board
_Snapshot · 2026-05-29_

## Status

done (all ✅) — M1 Capture · M2 Detection+overlay · M3 Playback · M4 Tuning (P4 🚫) · M5 Honest detectors · M6 Custom models (P4 🚫) · PlaybackDetectionCoordinator (P1–P3 ✅ · P4 🗓) · Demo simulator-runnable · M7 Dataset (P1–P4 ✅)

🌱 **M8 — Image** (static-image detection; the source-agnostic decomposition's second consumer) → [features/M8.md](./features/M8.md)
├─ ✅ P1 — `DetectionRunner` (loop-free core: cache+metrics+session-swap+per-frame `run`) in `Detection/`; playback coordinator composes it  (244 green · demos build · branch `m8-p1-detection-runner`)
├─ ✅ P2 — image → upright `Frame`: `ImageFrameDecoder` (`Sources/Iris/Image/`, `SourceKind.image`, EXIF baked in via CoreImage `.oriented`)  (250 green · +6 tests)
├─ 🗓 P3 — `ImageDetectionCoordinator` (one-shot detect; model-swap re-runs once; composes `DetectionRunner`)  ← here
├─ 🗓 P4 — demo Image page (iOS+macOS): image picker + `RecentImages` MRU + detector picker + tuning sheet, no scrubber
├─ 🗓 P5 — freeze-from-live: "Inspect frame" from playback/capture → Image page
└─ 🗓 P6 — dataset tie-in: image-shaped `AssetFingerprint` (no `durationSeconds`) + PTS/seek-free `FlaggingSource` + flag→PNG export

👉 next — **M8·P3 — `ImageDetectionCoordinator`.** A `@MainActor @Observable` library type (`Sources/Iris/Image/`) holding the decoded image's `Frame` + a `DetectionRunner`; one-shot detect on load; a model-swap re-runs detection once (the runner's `onTierChange` re-detects the held frame, the image analogue of playback's seek). Composes P1's runner. → [features/M8.md](./features/M8.md) · [LOG.md](./LOG.md)

❓ open → [QUESTIONS.md](./QUESTIONS.md)
- ⚖️ Multi-detector pipelines under `TuningModel` (multi-active selection defers here)
- ⚖️ "What if?" mode (BRIEF §5)

📌 recent → [DECISIONS.md](./DECISIONS.md)
- M8 defined ([features/M8.md](./features/M8.md)): run detectors on a single static image, swap/compare models in that one world. Pipeline+overlay already source-agnostic (`Frame`/`DetectorPipeline`/`VideoGeometry`/`ResultStore` have no video coupling); only `PlaybackDetectionCoordinator`+`Scrubber`+`FlaggingSource` are PTS-coupled. 5 settled forks: image detection is **one-shot** (reuse `DetectorPipeline` w/ frozen timestamp, **no** 1-frame stream); **P1 = full `DetectionRunner` extraction** (resolves the source-agnostic-decomposition question — the image inspector is the second consumer); new `Sources/Iris/Image/` folder; freeze-from-live in scope; dataset tie-in in scope (image-shaped `AssetFingerprint` minus `durationSeconds` + PTS/seek-free `FlaggingSource`). → [DECISIONS.md](./DECISIONS.md) (2026-05-29)
- M7·P4 redefined (user — **refines**, doesn't contradict, the same-day "seam only"): P4 now ships a concrete **`FrameExporter` frame-export sweep** (resumable/interruptible; drives P3's `DatasetBuilder` over `RecentVideos`-resolved URLs; app-side launch/`scenePhase`-background/"Export now" triggers; `export-status.json` operational telemetry incl. unreachable sources). `DatasetExporter` training-FORMAT conversion stays deferred. `RecentVideos` MRU-10 caveat noted (ledger approach (b) = follow-up). (2026-05-28)
- M7 sidecar reframe (user — supersedes the COCO call): **no per-image sidecar, no COCO, no exporter in M7** (a flag = "look again," not an annotation; multiple models tried ⇒ a per-image verdict is false precision). `AssetFingerprint` now **name-independent** (`byteSize`+`durationSeconds`+mandatory head-hash; filename display-only) → rename-stable + edit-sensitive. Provenance rides the export filename (`<sourceNameHash>_<fingerprintID>_<ptsMillis>.png`); **dedup keys on the suffix** — the dataset's own filenames are the ledger (lives WITH the data, can't go stale). P4 → `DatasetExporter` **seam only**, first exporter deferred to when a training pipeline names its format. (2026-05-28)
- M7·P2 UI call (user): the **primary flag affordance lives ON the frame image** (top-right bookmark puck via `VideoRectAligned`/`VideoGeometry`), not a control-row button; **timeline markers are a coarse secondary overview**, never the source of truth (a thin strip can't resolve adjacent frames; ticks inset by thumb radius to align). (2026-05-28)
- M7 defined ([features/M7.md](./features/M7.md)): frame address = `(AssetFingerprint, PTS)`; content fingerprint not URL; cheap flagging / deferred headless extraction; deterministic-naming dedup; output under `<Documents>/iris-dataset/`. Scope = **playback**; live-capture flagging is a follow-on (can't re-seek). *(Sidecar/COCO half superseded by the reframe above.)* (2026-05-28)
- `demo-sim-runnable` fast-forwarded to `main` (`40cf0de`); hands-on smoke skipped (owed) (2026-05-28)
- Swap root-cause corrected: the `f4a6284` cancel→drain→respawn fix proved a **no-op** (`PlaybackSource` exposes a single stored `AsyncStream` that dies permanently on consumer cancel — respawned `for await` gets zero frames); coordinator uses **one loop + in-place router swap** instead. P2/P3 fix the demo swap bug for the first time (2026-05-27)
- PlaybackDetectionCoordinator defined: `@MainActor @Observable` library type in `Playback/`; 4 phases (P1 build+test, P2/P3 rewire demos, P4 deferred) (2026-05-27)
- Playback session orchestration → a library `PlaybackDetectionCoordinator` in `Playback/`; demos keep only file/scope/catalog/layout; source-agnostic core not pre-split (2026-05-27)
- M6 merged to `main` (fast-forward); playback detector-swap fix + this analysis on branch `fix-playback-detector-swap` (2026-05-27)
- M6 closed: P1–P3 ✅; captioning (P4) dropped — Foundation Models is text-only, on-device captioning needs a VLM (2026-05-26)
- M6·P3 closed: model loading (prewarm, bundled-at-launch, file-picked Path-A) shipped (2026-05-26)
- M6·P3: path-B YOLOEnd2EndDecoder + runtime confidence knob (conditional TunableDetector) shipped (2026-05-26)
- M6·P2: Path-A CoreMLDetector shipped; runtime thresholds deferred to P3 (2026-05-26)
- Core ML detector: start with YOLOv12 (Path A), pluggable `OutputDecoder` seam (2026-05-25)
- VideoGeometry = single coordinate-mapping authority; orientation/mirroring upstream (2026-05-25)
- Self-describing detections (skeleton + readout on `Detection`) (2026-05-25)

## Milestones

The roadmap legend — one line per milestone, what it delivers. State lives in §Status above; this section answers "what is M5 again?".

- **M1 — Capture core** — `IrisCapture` + `CameraPreview` SwiftUI view + `AsyncStream<Frame>`; iOS only.
- **M2 — Detection + overlay** — `IrisDetection` Vision adapter + `IrisOverlay` box drawing; end-to-end live iOS demo. → [features/M2.md](./features/M2.md)
- **M3 — Playback** — `IrisPlayback` with the same `Frame` stream; same overlay on recorded video; first macOS target. → [features/M3.md](./features/M3.md)
- **M4 — Tuning** — `IrisTuning` confidence/class/NMS controls via `@Observable`; three-tier change taxonomy. → [features/M4.md](./features/M4.md)
- **M5 — Honest detectors** — per-detector capability model driving derived tuning UI + capability-honest overlays + a raw-data inspector. → [features/M5-honest-detectors.md](./features/M5-honest-detectors.md)
- **M6 — Custom models** — Core ML adapter with a pluggable YOLO-style `OutputDecoder`; model-swap UI. (Captioning dropped — Foundation Models is text-only.) → [features/M6.md](./features/M6.md)
- **M7 — Dataset** — `IrisDataset`: flag frames during playback → extract as provenance-bearing images (filenames are the dedup ledger; no sidecar); training-format export deferred. → [features/M7.md](./features/M7.md)
- **M8 — Image** — run detectors on a single static image (captured/playback frame, screenshot, any still) + swap/compare models on that one image; `Sources/Iris/Image/` + a demo Image page; triggers the source-agnostic `DetectionRunner` extraction. → [features/M8.md](./features/M8.md)

## Backlog

<!-- Stub = one line (`🗓 headline — hook`). Add a ≤4-line indented body only when needed.
     Link out (→ features/ or exploration) when the item has a real home. -->

- 🗓 Per-category tuning — per-class confidence thresholds + per-class hide/show, independent of the global confidence knob.
      e.g. turn `person` off entirely while tuning `sports ball` confidence on its own. Bigger effort: extends `IrisTuning`'s settings from a single global confidence to a per-label map; needs the derived-tuning UI (M4 surface) to expose per-class rows + the overlay/filter to honor per-class threshold **and** visibility. Likely an M4-family follow-on / candidate milestone. → [features/M4.md](./features/M4.md) (user, 2026-05-29)
- 🗓 Offline file-reader pre-pass — pre-computed detection tracks for smooth playback; an `AVAssetReader`-backed offline pass that decodes a file frame-by-frame, runs the detector over every frame, and caches the full `[Detection]` track.
      The natural shape for the Mac eval/curation target (the live pipeline stays best-effort + strobes on purpose). Opens when it lands: reuse `ResultStore` or a dedicated dense track? progress/cancel UI? sibling `Frame` source vs. pre-fill step. Likely M6/M7-adjacent. (user, 2026-05-25)
- 🗓 Revisit bumped SwiftLint thresholds — `file_length`(→1000), `type_body_length`(→600), `nesting`(→2), `cyclomatic_complexity`(→15) were raised in block 8 to silence warnings during detector churn.
      Real length debt: `DetectionLayer.swift`(482), `VisionRectanglesDetector.swift`(734), `PlaybackSource.swift`(523) want splitting. Once churn settles, split the long files and ratchet thresholds back down. See `.swiftlint.yml` dated comment + [LOG.md](./LOG.md) block 8.
- 🗓 RF-DETR Core ML spike — off the M6 critical path; direct PyTorch→Core ML via patched forks, FP32-only, needs a Swift `DETRSetPredictionDecoder` (path B, no NMS). → [`explorations/2026-05-25-coreml-model-conversion/RECOMMENDATIONS.md`](../explorations/2026-05-25-coreml-model-conversion/RECOMMENDATIONS.md)
- 🗓 Path-B file-picking — file-picked models accept Path-A only; a Path-B picked model would need a label-supply UI + output-spec auto-detect to pick the right `OutputDecoder`. Bundled Path-B (yolo26n) ships fine (decoder + labels wired in code). (M6·P3) → [features/M6.md](./features/M6.md)
- 🗓 Playback portrait `preferredTransform` — `PlaybackSource` stamps `Frame.orientation = .up` unconditionally; a portrait clip is delivered sideways but labeled upright, so Vision returns sideways-normalized coords. Fix upstream: derive `CGImagePropertyOrientation` + upright dims from `preferredTransform`. (M5·P6)
- 🗓 Capture front-camera mirroring — the preview connection's `isVideoMirrored` is never set to `(position == .front)`; front-camera overlays will be unmirrored vs. the displayed selfie. Locked in `explorations/display-pipeline-architecture/RECOMMENDATIONS.md`, omitted in code. (M5·P6)
- 🗓 DetectionInspector Swift 6 warning — pre-existing strict-concurrency warning in both demos: `displayTimeSource: { controller.currentTime }` (macOS `ContentView.swift:149`, iOS `:310`). Clears with `MainActor.assumeIsolated`. Minor. (M5·P6)
- 🗓 M7 export follow-ups — deferred polish on the dataset export loop, behind the existing seams. A **delayed-after-launch** sweep; surface `export-status.json` in the demo footer (automatic-run visibility); MRU-cap-10 the unbounded "flagged sources" ledger; the real `DatasetExporter` (training-format conversion). → [features/M7.md](./features/M7.md)
