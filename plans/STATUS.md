<!-- Snapshot, rewritten each block. Tree = defined work; penciled-in = ideas. One 👉 next. Best viewed monospace. -->

# Iris — Status
_Snapshot · 2026-05-27_

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
├─ 📋 Demo simulator-runnable  (P1–P4 planned · branch `demo-sim-runnable`) → [features/demo-sim-runnable.md](./features/demo-sim-runnable.md)
│  ├─ 📋 P1 — Playback-first sidebar-adaptable TabView (iOS demo)
│  ├─ 📋 P2 — Camera fallback page when no camera (sim / Mac Designed-for-iPad)
│  ├─ 📋 P3 — file sharing: expose Documents in Files.app
│  └─ 📋 P4 — `just sim-add-video` helper + verify on sim + Mac
└─ ✏️ M7 — Dataset  (BRIEF §6)   ← milestone-path next, not yet defined

penciled in — not yet defined (ideas, traceable to you)
   ✏️ Source orientation correctness — playback preferredTransform + capture front-mirror (M5·P6)
   ✏️ Offline file-reader pre-pass → pre-computed detection tracks for smooth playback (backlog)

👉 next — **Demo simulator-runnable, P1 (Playback-first sidebar layout).** New feature branch `demo-sim-runnable`: make the iOS demo pleasant to run with no camera (iOS Simulator + Mac Designed-for-iPad) — Playback default, camera-tab fallback page, Documents reachable in Files.app, a `just sim-add-video` helper. Plan defined ([features/demo-sim-runnable.md](./features/demo-sim-runnable.md)); **awaiting go-ahead to build P1**. Demo ergonomics, no `Sources/Iris/` changes — **M7 — Dataset stays the milestone-path next** behind it. → [LOG.md](./LOG.md)

❓ open → [QUESTIONS.md](./QUESTIONS.md)
- ⚖️ Source-agnostic decomposition — lift loop+cache+metrics into a `Detection/`-side `DetectionRunner` (coordinator P4); don't pre-split until a capture-side consumer lands
- ⚖️ Multi-detector pipelines under `TuningModel` (multi-active selection defers here)
- ⚖️ "What if?" mode (BRIEF §5)
- 🗓 RF-DETR Core ML spike — off the M6 critical path (direct PyTorch→Core ML fork, FP32, needs `DETRSetPredictionDecoder`)
- 🗓 Playback portrait `preferredTransform` + capture front-mirror (`isVideoMirrored`) — M5·P6 carryover
- 🗓 Offline file-reader pre-pass → pre-computed detection tracks for smooth playback (backlog)
- 🗓 `Apps/project.yml` ↔ `.pbxproj` drift — an xcodegen regen would drop the bundled `.mlpackage` Resources entries; the hand-edited `.pbxproj` is authoritative (M6·P3)
- 🗓 Path-B file-picking — file-picked models accept Path-A only; a Path-B picked model needs a label-supply UI + output-spec auto-detect (M6·P3)
- ✅ Detector-swap regression test — landed in coordinator [P1](./features/playback-detection-coordinator.md) (commit `51743c7`); building P1 also corrected the root cause (the 2026-05-26 `f4a6284` cancel→drain→respawn is a no-op) → now answered in [QUESTIONS.md](./QUESTIONS.md)
- 🗓 Revisit bumped SwiftLint thresholds once detector churn settles
- ℹ️ Pre-existing DetectionInspector Swift 6 warning in both demos (M5·P6)

📌 recent → [DECISIONS.md](./DECISIONS.md)
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
