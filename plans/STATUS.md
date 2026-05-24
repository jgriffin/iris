<!-- Snapshot, rewritten each block. Tree = defined work; penciled-in = ideas. One 👉 next. Best viewed monospace. -->

# Iris — Status
_Snapshot · 2026-05-24_

├─ ✅ M1 — Capture core
├─ ✅ M2 — Detection + overlay
├─ ✅ M3 — Playback
└─ ✅ M4 — Tuning            (P1–P3 ✅ · P4 🚫)

penciled in — not yet defined (ideas, traceable to you)
   ✏️ M5 — Dataset (BRIEF)               ← likely next
   ✏️ M6 — Custom models + captioning (BRIEF)

👉 next — define M5: draft `features/M5.md` via discuss-phase

❓ open → [QUESTIONS.md](./QUESTIONS.md)
- ⚖️ Multi-detector pipelines under `TuningModel`
- ⚖️ "What if?" mode (BRIEF §5)
- 🗓 M4 polish backlog — Vision conf=1.0 · quadrature TODO · double-detections re-smoke

📌 recent → [DECISIONS.md](./DECISIONS.md)
- Best-effort temporal match in `ResultStore.lookup` (2026-05-22)
- Single SwiftPM target, folder-organized (2026-05-20)
- Runtime frame pipeline — `Source<Frame>` + `.bufferingNewest(1)` (2026-05-20)
