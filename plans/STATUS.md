<!-- Snapshot, rewritten each block. Tree = defined work; penciled-in = ideas. One 👉 next. Best viewed monospace. -->

# Iris — Status
_Snapshot · 2026-05-25_

├─ ✅ M1 — Capture core
├─ ✅ M2 — Detection + overlay
├─ ✅ M3 — Playback
├─ ✅ M4 — Tuning            (P1–P3 ✅ · P4 🚫)
└─ ✅ M5 — Honest detectors
   ├─ ✅ P1 — Vision capability audit
   ├─ ✅ P2 — capability model → derived settings + filter UI
   ├─ ✅ P3 — honest overlays + ratio display
   ├─ ✅ P4 — detector selection in the player
   ├─ ✅ P5 — detection inspector + richer metrics
   └─ ✅ P6 — VideoGeometry consolidation + macOS overlay fix   (blocker resolved)

penciled in — not yet defined (ideas, traceable to you)
   ✏️ Source orientation correctness — playback preferredTransform + capture front-mirror (M5·P6 block)   ← likely next
   ✏️ M6 — Custom models + captioning (BRIEF §7)
   ✏️ M7 — Dataset (BRIEF §6)

👉 next — pick up **source-orientation correctness**: `PlaybackSource` `preferredTransform` so portrait clips feed upright detections, + set capture preview `isVideoMirrored` for the front camera. Both scoped in [QUESTIONS.md](./QUESTIONS.md). Or define M6/M7.

❓ open → [QUESTIONS.md](./QUESTIONS.md)
- ⚖️ Playback portrait clips: `PlaybackSource` stamps `.up` without applying `preferredTransform` → sideways detections (M5·P6)
- ⚖️ Capture front-camera preview mirroring (`isVideoMirrored`) — locked decision unimplemented (M5·P6)
- ⚖️ Multi-detector pipelines under `TuningModel` (multi-active selection defers here)
- ⚖️ "What if?" mode (BRIEF §5)
- 🗓 Offline file-reader pre-pass → pre-computed detection tracks for smooth playback (backlog)
- 🗓 Revisit bumped SwiftLint thresholds once detector churn settles
- ℹ️ Pre-existing DetectionInspector Swift 6 warning in both demos (M5·P6)

📌 recent → [DECISIONS.md](./DECISIONS.md)
- VideoGeometry = single coordinate-mapping authority; orientation/mirroring upstream (2026-05-25)
- Self-describing detections (skeleton + readout on `Detection`) (2026-05-25)
- Detector capability model (2026-05-24)
- Best-effort temporal match in `ResultStore.lookup` (2026-05-22)
