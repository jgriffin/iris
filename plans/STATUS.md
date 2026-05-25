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
   ├─ ✅ P4 — detector selection in the player   👀 needs player smoke-test
   └─ 📋 P5 — detection inspector (raw-data panel)

penciled in — not yet defined (ideas, traceable to you)
   ✏️ M6 — Custom models + captioning (BRIEF §7)
   ✏️ M7 — Dataset (BRIEF §6)

👉 next — smoke-test P4 in the player (open the dancer clip, pick **Body Pose**, confirm the skeleton draws), then start M5·P5: detection inspector

❓ open → [QUESTIONS.md](./QUESTIONS.md)
- ⚖️ Multi-detector pipelines under `TuningModel` (multi-active selection defers here)
- ⚖️ "What if?" mode (BRIEF §5)
- 🗓 Revisit bumped SwiftLint thresholds once detector churn settles

📌 recent → [DECISIONS.md](./DECISIONS.md)
- Self-describing detections (skeleton + readout on `Detection`) (2026-05-25)
- Detector capability model (2026-05-24)
- Best-effort temporal match in `ResultStore.lookup` (2026-05-22)
