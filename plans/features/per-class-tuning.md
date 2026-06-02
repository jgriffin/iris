# M10 — Per-class tuning

_Defined 2026-06-01. The backlog's "Per-category tuning" item, now scoped._

## Goal

Generalize M9·P3's **global** render-time confidence floor into **per-class**
controls — a per-label confidence floor + per-label hide/show — and surface them
in a **unified model-settings panel** alongside the detector's own knobs.

> Turn `person` off entirely while tuning `sports ball` confidence on its own;
> pin the basketball so it always draws even before the video reaches it.

## Design intent (settled — see [`DECISIONS.md`](../DECISIONS.md) 2026-06-01)

- **One panel, two delineated groups.** From the user's view they're "adjusting
  the model." Internally we keep the honest split locked on 2026-05-30 —
  **detector-input** settings (M5 capability-honest knobs, e.g. YOLO decode
  threshold) vs. **render-time output filter** (what to *draw* from what the
  detector emitted). The panel co-presents both, visually grouped (a **Detector**
  group + a **Display/filter** group); it does **not** merge their data classes.
  The north-star "one shared settings *class*" stays deferred — co-presentation
  doesn't require it.
- **Per-class tuning is render-side data.** Per-label floors + visibility key on
  `Detection.label` *after* the detector emits, exactly like the global floor —
  uniform across every detector, no detector rebuild. (Class-agnostic detectors
  like Vision rectangles expose no label set → no per-class section, same
  graceful gating `CapabilityTuningView` already does for `.confidence == .none`.)
- **State home: app-side**, alongside the global floor (which lives in
  `ModelSelection`, not the library tuning model). Library gets only the
  generalized filter + a label-enumeration capability.
- **UI home: the sidebar MODEL section**, expanded — "part of picking the model
  is picking settings for it." Not a separate sheet.
- **Precedence:** *hidden* wins outright; else *per-class floor if set, otherwise
  the global floor*.
- **Labels shown:** present-only (labels currently in the detections) + a
  "show all" expander to the full class set. Snapshot/accumulate present-labels
  so rows don't flicker frame-to-frame.

## Seams (from the 2026-06-01 code map)

| Piece | Where | Change |
| --- | --- | --- |
| Render filter | `Sources/Iris/Overlay/DetectionConfidenceFilter.swift` (`[Detection].filtered(minConfidence:)`, applied by `DetectionLayer.swift:133`, bypassed by the raw inspector) | Generalize: scalar floor → per-label floors + visibility set, global as fallback; keep scalar form working |
| Label set | `Sources/Iris/Detection/DetectorCapabilities.swift` | **New axis** `availableLabels: [String]?` — YOLO → decoder `labels`/`COCOLabels.coco80`; Vision rects → `nil` |
| Filter state | `Apps/Shared/State/ModelSelection.swift` (holds global `minConfidence`) | Per-label floor map + hidden-label set + persistence |
| Filter wiring | `Apps/Shared/Details/{Playback,Image}DetailView.swift`, `Shell/IrisShell+Capture.swift` | Pass the per-class filter into `DetectionLayer` on all three modes |
| Settings UI | `Apps/Shared/Shell/Sidebar/ModelSection.swift` (+ unwired `Sources/Iris/Tuning/UI/CapabilityTuningView.swift`) | Expand MODEL section into the unified panel; surface detector knobs + per-class rows |

## Phases

- **P1 — Library: generalized filter + label enumeration.** Generalize
  `filtered(minConfidence:)` into per-label floors + visibility (global fallback,
  scalar form preserved); add `DetectorCapabilities.availableLabels`. Fixture
  tests. *The one library-touching phase* (mirrors M9·P3's single library seam).
- **P2 — App state + wiring.** Extend the app-side settings with the per-label
  floor map + hidden set + persistence; snapshot present-labels from current
  detections; wire the generalized filter into `DetectionLayer` across
  Playback/Image/Capture.
- **P3 — Unified model-settings panel.** Expand the sidebar MODEL section: detector
  picker + global floor (existing) + a **Detector** group (surface the unwired
  `CapabilityTuningView` knobs for the active detector) + a **Display/filter**
  group (per-class rows: visibility toggle + optional floor slider, present-only +
  "show all"). Two delineated groups, one panel.
- **P4 — Polish + static preview.** Reset-to-global per row; agnostic-detector
  empty state; static preview gallery (favorite pattern) for the panel; both
  demo schemes green.

## Opens / risks

- ❓ **Does P3's Detector group need live `TuningModel` in the shell?** M9 was
  demo-wiring; the detector-intrinsic knobs (`CapabilityTuningView`) were never
  surfaced, so a `TuningModel`/capabilities instance may not be live in
  `IrisShell` today. This is the integration-heavy part. **Fallback:** if it
  balloons, P3 ships the Display/filter (per-class) half and defers surfacing the
  detector-input knobs to a follow-on — the per-class win lands either way.
- ⚠️ **Present-only flicker.** Recomputing the label set every frame would make
  rows appear/disappear. Snapshot on panel-open or accumulate the session union.
- ⚖️ **State home shape.** Extend `ModelSelection` vs. a sibling `OverlayFilter`
  model. Lean sibling to keep `ModelSelection` from bloating; settle in P2.

## Out of scope → [`BOARD.md`](../BOARD.md) §Backlog (deferred 2026-06-01)

- **Favorites** — pin classes (basketball, soccer ball) to always show even before
  they appear on screen, independent of the present-only default.
- **Config profiles** — saved settings bundles so per-class setups don't get
  re-typed each session.
