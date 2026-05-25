<!-- Snapshot, rewritten each block. Tree = defined work; penciled-in = ideas. One 👉 next. Best viewed monospace. -->

# Iris — Status
_Snapshot · 2026-05-25_

├─ ✅ M1 — Capture core
├─ ✅ M2 — Detection + overlay
├─ ✅ M3 — Playback
├─ ✅ M4 — Tuning            (P1–P3 ✅ · P4 🚫)
└─ 🌱 M5 — Honest detectors
   ├─ ✅ P1 — Vision capability audit
   ├─ ✅ P2 — capability model → derived settings + filter UI
   ├─ ✅ P3 — honest overlays + ratio display
   └─ 📋 P4 — detection inspector (raw-data panel)

penciled in — not yet defined (ideas, traceable to you)
   ✏️ M6 — Custom models + captioning (BRIEF §7)
   ✏️ M7 — Dataset (BRIEF §6)

👉 next — start M5·P4: shared `DetectionInspector` (macOS `.inspector()` + iOS sheet) showing each detection's literal fields from the introspectable model; debug-mode first

❓ open → [QUESTIONS.md](./QUESTIONS.md)
- ⚖️ Multi-detector pipelines under `TuningModel`
- ⚖️ "What if?" mode (BRIEF §5)
- 🗓 Hygiene: `file_length` advisories (DetectionLayer 482 · VisionRectangles 734 · PlaybackSource 523 · others) — `swiftlint --strict` already red

📌 recent → [DECISIONS.md](./DECISIONS.md)
- Self-describing detections (skeleton + readout on `Detection`) (2026-05-25)
- Detector capability model (2026-05-24)
- Best-effort temporal match in `ResultStore.lookup` (2026-05-22)
