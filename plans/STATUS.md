<!-- Hand-maintained snapshot, rewritten each block. Links to the source of truth
     for every line — points, never copies. One 👉 next only. -->

# Iris — Status
_Snapshot · 2026-05-24_

## Milestones
- ✅ **M1 — Capture core** · `IrisCapture` + `CameraPreview` SwiftUI view + frame stream; iOS only. → [`BRIEF.md`](./BRIEF.md)
- ✅ **M2 — Detection + overlay** · `IrisDetection` Vision adapter + `IrisOverlay` boxes; end-to-end live iOS demo. → [`features/M2.md`](./features/M2.md)
- ✅ **M3 — Playback** · `IrisPlayback` with the same `Frame` stream; first macOS target. → [`features/M3.md`](./features/M3.md)
- ✅ **M4 — Tuning** · `IrisTuning` — confidence/class/NMS controls via `@Observable`; three-tier change taxonomy. → [`features/M4.md`](./features/M4.md)
  - ✅ Phase 1 — Types + `VisionRectanglesSettings` + `TunableDetector`
  - ✅ Phase 2 — `TuningModel<Settings>` + pipeline tier routing
  - ✅ Phase 3 — Built-in UI + demo wiring
  - 🚫 Phase 4 — Cache-fingerprint upgrade (cancelled — per-entry was wrong shape; global `invalidateAll()` already correct)
- 📋 **M5 — Dataset** · `IrisDataset` — one-tap frame + COCO-JSON sidecar from live + playback. → [`BRIEF.md`](./BRIEF.md)   ← cursor (next up)
- 📋 **M6 — Custom models + captioning** · Core ML YOLO decoder + model-swap UI + Foundation Models captioning. → [`BRIEF.md`](./BRIEF.md)

## 👉 Next
Open M5 — `IrisDataset` (`BRIEF.md` §6): `DatasetSink` protocol, one-tap frame + COCO sidecar, "this was wrong" / "near-miss" affordances. Likely opens with a `features/M5.md` brief over a discuss-phase. → [`LOG.md`](./LOG.md)

## ❓ Open  →  [QUESTIONS.md](./QUESTIONS.md)
- ⚖️ Multi-detector pipelines under `TuningModel` — per-detector model vs. composite (resolve when a real multi-detector pipeline lands)
- ⚖️ "What if?" mode (BRIEF §5) — show would-pass-at-lower-threshold detections in a distinct style; deferred to a follow-up feature
- 🗓 M4 polish backlog — Vision confidence always `1.0`; `quadratureToleranceDegrees` filter-arm TODO; "double detections" re-smoke

## 📌 Recent  →  [DECISIONS.md](./DECISIONS.md)
- Best-effort temporal match in `ResultStore.lookup` via timestamp-keyed cache (2026-05-22)
- Single SwiftPM target, folder-organized internally (2026-05-20)
- Runtime frame pipeline — `Source<Frame>` + `.bufferingNewest(1)` (2026-05-20)
