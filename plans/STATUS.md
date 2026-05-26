<!-- Snapshot, rewritten each block. Tree = defined work; penciled-in = ideas. One 👉 next. Best viewed monospace. -->

# Iris — Status
_Snapshot · 2026-05-25_

├─ ✅ M1 — Capture core
├─ ✅ M2 — Detection + overlay
├─ ✅ M3 — Playback
├─ ✅ M4 — Tuning            (P1–P3 ✅ · P4 🚫)
├─ ✅ M5 — Honest detectors  (P1–P6 ✅)
└─ 🌱 M6 — Custom models + captioning
   ├─ ✅ P1 — Core ML conversion pipeline (tooling + runbook + verified YOLO paths)
   ├─ 📋 P2 — CoreMLDetector + VisionObjectDecoder, YOLOv12 path-A end-to-end   ← here
   ├─ 📋 P3 — YOLOEnd2End decoder (OutputDecoder seam) + model-swap catalog/loading
   └─ 📋 P4 — captioning (Captioner + Foundation Models) — stretch

penciled in — not yet defined (ideas, traceable to you)
   ✏️ Source orientation correctness — playback preferredTransform + capture front-mirror (M5·P6 block)
   ✏️ M7 — Dataset (BRIEF §6)

👉 next — start **M6·P2**: build `CoreMLDetector` + `VisionObjectDecoder` and prove YOLOv12 (path A) end-to-end in a demo. Plan: [features/M6.md](./features/M6.md). → [LOG.md](./LOG.md)

❓ open → [QUESTIONS.md](./QUESTIONS.md)
- ⚖️ Runtime-tunable Core ML thresholds — Path A bakes IoU/conf at export; runtime tuning forces Path B or re-export (M6·P2)
- ⚖️ Multi-detector pipelines under `TuningModel` (multi-active selection defers here)
- ⚖️ "What if?" mode (BRIEF §5)
- 🗓 RF-DETR Core ML spike — off the M6 critical path (direct PyTorch→Core ML fork, FP32, needs `DETRSetPredictionDecoder`)
- 🗓 Playback portrait `preferredTransform` + capture front-mirror (`isVideoMirrored`) — M5·P6 carryover
- 🗓 Offline file-reader pre-pass → pre-computed detection tracks for smooth playback (backlog)
- 🗓 Revisit bumped SwiftLint thresholds once detector churn settles
- ℹ️ Pre-existing DetectionInspector Swift 6 warning in both demos (M5·P6)

📌 recent → [DECISIONS.md](./DECISIONS.md)
- Core ML detector: start with YOLOv12 (Path A), pluggable `OutputDecoder` seam (2026-05-25)
- VideoGeometry = single coordinate-mapping authority; orientation/mirroring upstream (2026-05-25)
- Self-describing detections (skeleton + readout on `Detection`) (2026-05-25)
- Detector capability model (2026-05-24)
