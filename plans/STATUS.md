<!-- Snapshot, rewritten each block. Tree = defined work; penciled-in = ideas. One 👉 next. Best viewed monospace. -->

# Iris — Status
_Snapshot · 2026-05-28_

├─ ✅ M1 — Capture core
├─ ✅ M2 — Detection + overlay
├─ ✅ M3 — Playback
├─ ✅ M4 — Tuning            (P1–P3 ✅ · P4 🚫)
├─ ✅ M5 — Honest detectors  (P1–P6 ✅)
├─ ✅ M6 — Custom models     (P1–P3 ✅ · P4 🚫)
├─ ✅ PlaybackDetectionCoordinator  (P1–P3 ✅ · P4 🗓 · smoked + merged to `main`) → [features/playback-detection-coordinator.md](./features/playback-detection-coordinator.md)
│  ├─ ✅ P1 — coordinator in `Playback/` + swap regression test  (`51743c7`)
│  ├─ ✅ P2 — rewire macOS demo (−94 lines, xcodebuild green)     (`1ea2cd1`)
│  ├─ ✅ P3 — rewire iOS demo (−102 lines, xcodebuild green)      (`ad7428d`)
│  └─ 🗓 P4 — external-controls polish + source-agnostic `DetectionRunner` (deferred)
├─ ✅ Demo simulator-runnable  (P1–P4 ✅ · merged to `main` ff `40cf0de` · smoke ✅) → [features/demo-sim-runnable.md](./features/demo-sim-runnable.md)
│  ├─ ✅ P1 — Playback-first sidebar-adaptable TabView (iOS demo)  (`3a1388b`)
│  ├─ ✅ P2 — Camera fallback page when no camera (sim / Mac Designed-for-iPad)  (`1319501`)
│  ├─ ✅ P3 — file sharing: expose Documents in Files.app  (`8a9e9c1`)
│  └─ ✅ P4 — `just sim-add-video` helper  (`213e149`)
└─ ✅ M7 — Dataset  (P1–P4 ✅ · branch `m7-dataset`, unmerged) → [features/M7.md](./features/M7.md)
   ├─ ✅ P1 — `FrameRef`+`AssetFingerprint`+`FlagStore`+`Detection` Codable + tests  (225 green · `e685f09`)
   ├─ ✅ P2 — Flagging UI: on-frame bookmark (primary) + aligned timeline markers + flagged panel + jump-to-flag  (230 green · `4a10fb8`)
   ├─ ✅ P3 — `DatasetSink`+`FolderDatasetSink`+headless `DatasetBuilder`+`PixelBufferPNGEncoder`; suffix-dedup ledger, no sidecar  (237 green · `e3ce965`)
   └─ ✅ P4 — Frame export sweep: library `FrameExporter` (resumable/interruptible, drives P3 `DatasetBuilder` over `RecentVideos` URLs) + `FrameExportCoordinator` triggers (`scenePhase` background + "Export now"; **launch trigger dropped** — contends with playback) + `export-status.json`  (244 green; `DatasetExporter` format conversion still deferred)

penciled in — not yet defined (ideas, traceable to you)
   ✏️ Detector selection MRU / remember-last-selected (not default-to-rectangle) — demo-side (user, 2026-05-28)
   ✏️ Source orientation correctness — playback preferredTransform + capture front-mirror (M5·P6)
   ✏️ Offline file-reader pre-pass → pre-computed detection tracks for smooth playback (backlog)

👉 next — **merge `m7-dataset` → `main`** (M7 complete, P1–P4 ✅, 244 green, both demo schemes build, models bundled). M7 ships the full flag→extract loop: flag frames while scrubbing (on-frame bookmark primary, persisted reload-stably) → frames write themselves to `<Documents>/iris-dataset/frames/<sourceNameHash>_<fingerprintID>_<ptsMillis>.png` (**no sidecar**; the dataset's own filenames are the suffix-dedup ledger). P4's `FrameExporter` sweep (resumable + interruptible) is driven by `FrameExportCoordinator` in both demos: triggers on **`scenePhase`→background** (cancelled on foreground) + manual **"Export now"** button — the **launch trigger was dropped** (contended with playback). `export-status.json` records last-run counts + unreachable sources. Parked ideas (not wanted now): a **delayed-after-launch** sweep; loading `export-status.json` into the footer so automatic runs are visible in-UI; the unbounded "flagged sources" ledger (MRU-cap-10 follow-up); the real `DatasetExporter` (training-FORMAT conversion). Possible pre-merge: hands-on demo run (flag → background → confirm `frames/` fills) — manual-button path already user-verified. → [LOG.md](./LOG.md)

❓ open → [QUESTIONS.md](./QUESTIONS.md)
- ⚖️ Source-agnostic decomposition — lift loop+cache+metrics into a `Detection/`-side `DetectionRunner` (coordinator P4); don't pre-split until a capture-side consumer lands
- ⚖️ Multi-detector pipelines under `TuningModel` (multi-active selection defers here)
- ⚖️ "What if?" mode (BRIEF §5)
- 🗓 RF-DETR Core ML spike — off the M6 critical path (direct PyTorch→Core ML fork, FP32, needs `DETRSetPredictionDecoder`)
- 🗓 Playback portrait `preferredTransform` + capture front-mirror (`isVideoMirrored`) — M5·P6 carryover
- 🗓 Offline file-reader pre-pass → pre-computed detection tracks for smooth playback (backlog)
- ✅ `Apps/project.yml` ↔ `.pbxproj` drift — RESOLVED (M7·P4): models declared explicitly in `project.yml`, regen verified to bundle both `.mlmodelc`; **`project.yml` canonical, regenerate freely, never hand-edit `.pbxproj`** → [QUESTIONS.md](./QUESTIONS.md)
- 🗓 Path-B file-picking — file-picked models accept Path-A only; a Path-B picked model needs a label-supply UI + output-spec auto-detect (M6·P3)
- ✅ Detector-swap regression test — landed in coordinator [P1](./features/playback-detection-coordinator.md) (commit `51743c7`); building P1 also corrected the root cause (the 2026-05-26 `f4a6284` cancel→drain→respawn is a no-op) → now answered in [QUESTIONS.md](./QUESTIONS.md)
- 🗓 Revisit bumped SwiftLint thresholds once detector churn settles
- ℹ️ Pre-existing DetectionInspector Swift 6 warning in both demos (M5·P6)

📌 recent → [DECISIONS.md](./DECISIONS.md)
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
