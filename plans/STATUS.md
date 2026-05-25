<!-- Snapshot, rewritten each block. Tree = defined work; penciled-in = ideas. One 👉 next. Best viewed monospace. -->

# Iris — Status
_Snapshot · 2026-05-24_

├─ ✅ M1 — Capture core
├─ ✅ M2 — Detection + overlay
├─ ✅ M3 — Playback
├─ ✅ M4 — Tuning            (P1–P3 ✅ · P4 🚫)
└─ 🌱 M5 — Honest detectors
   ├─ ✅ P1 — Vision capability audit
   ├─ 📋 P2 — capability model → derived settings + filter UI
   ├─ 📋 P3 — honest overlays + ratio display
   └─ 📋 P4 — detection inspector (raw-data panel)

penciled in — not yet defined (ideas, traceable to you)
   ✏️ M6 — Custom models + captioning (BRIEF §7)
   ✏️ M7 — Dataset (BRIEF §6)

👉 next — land the capability-model decision from the [P1 audit](../explorations/2026-05-24-vision-capability-audit/RECOMMENDATIONS.md), then M5·P2 (capability model → derived filter UI)

❓ open → [QUESTIONS.md](./QUESTIONS.md)
- ⚖️ Capability-model shape — decision-ready from P1 → [audit RECs](../explorations/2026-05-24-vision-capability-audit/RECOMMENDATIONS.md)
- ⚖️ Multi-detector pipelines under `TuningModel`
- ⚖️ "What if?" mode (BRIEF §5)
- 📌 M4 polish (Vision conf=1.0 · quadrature) — folded into M5

📌 recent → [DECISIONS.md](./DECISIONS.md)
- Best-effort temporal match in `ResultStore.lookup` (2026-05-22)
- Single SwiftPM target, folder-organized (2026-05-20)
- Runtime frame pipeline — `Source<Frame>` + `.bufferingNewest(1)` (2026-05-20)
