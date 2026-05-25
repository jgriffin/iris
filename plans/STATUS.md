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
   ├─ ✅ P4 — detector selection in the player
   ├─ ✅ P5 — detection inspector + richer metrics   (it cracked the render bug below)
   └─ 🚩 BLOCKER — macOS overlay render bug (detections correct, not drawn)

penciled in — not yet defined (ideas, traceable to you)
   ✏️ M6 — Custom models + captioning (BRIEF §7)
   ✏️ M7 — Dataset (BRIEF §6)

👉 next (fresh session) — fix the **macOS overlay render bug**. Inspector confirmed it: detections are correct (19 joints, sane coords) but the overlay draws nothing — blank on landscape clips too, so it's a macOS placement bug, not orientation. Converter math is tested-correct → fault is the `videoRect` input (`playerLayer.videoRect`, an AppKit bottom-left value vs the top-left SwiftUI Canvas). **Durable approach (not another patch):** derive videoRect in pure SwiftUI space (GeometryReader + known video pixel dims → aspect-fit), and add **letterboxed `DetectionLayer` static previews** (offset videoRect, wide+tall) that reproduce + verify the fix without running the app. Details: [LOG.md](./LOG.md) block 11.

❓ open → [QUESTIONS.md](./QUESTIONS.md)
- ⚖️ Multi-detector pipelines under `TuningModel` (multi-active selection defers here)
- ⚖️ "What if?" mode (BRIEF §5)
- 🗓 Offline file-reader pre-pass → pre-computed detection tracks for smooth playback (backlog)
- 🗓 Revisit bumped SwiftLint thresholds once detector churn settles

📌 recent → [DECISIONS.md](./DECISIONS.md)
- Self-describing detections (skeleton + readout on `Detection`) (2026-05-25)
- Detector capability model (2026-05-24)
- Best-effort temporal match in `ResultStore.lookup` (2026-05-22)
