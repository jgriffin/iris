# M5 — Honest detectors

<!-- Working plan. Lifetime ~ this milestone; LOG.md keeps the trail. Status vocab per WORKFLOW.md §"Status trees". -->
_Defined · 2026-05-24_

## Thesis

A detector should expose only the settings it actually has, and the overlay should
render only what the model actually knows. Rectangles shipped a confidence slider
that does nothing and a "100%" readout that's a geometric artifact, not a
probability. The fix isn't a one-off patch — it's a **capability model** every
built-in Vision detector declares, which drives (a) which tuning controls appear and
(b) what the overlay draws. Direct evolution of the M4 decision (generic per-detector
settings, thin built-in UI derived per detector).

## Scope (this milestone)

**Framework + 2 exemplars:**
- Build the capability model, capability-derived settings/filter UI, and
  capability-honest overlays, **and a raw-data inspector panel**.
- Prove it on **rectangles (reworked)** + a **human body-pose skeleton** (new).
- Audit + catalog the rest of the built-in Vision surface (P1); implement later.

**Ratios decision — capability-honest:** each detector shows a ratio meaningful to
it; no confidence readout when the model has none; real confidence renders as a
ratio, not a percentage.

## Phases

### P1 — Vision capability audit  📋

Inventory the built-in Vision request surface (the new Swift Vision value-type API:
`DetectHumanBodyPoseRequest`, face rectangles/landmarks, `DetectHumanHandPoseRequest`,
`RecognizeAnimalsRequest`, `DetectRectanglesRequest`, `DetectBarcodesRequest`,
`RecognizeTextRequest`, saliency, `ClassifyImageRequest`). For each, record: output
geometry (box / keypoints / mask / label-only), whether it carries *real* confidence,
and its genuinely tunable parameters. Output: a capability matrix (likely an
exploration that feeds a DECISIONS entry). Resolves "if there's no confidence, why
expose it." **Note:** built-in Vision has no general object-box detector — that's Core
ML/YOLO (M6). The matrix makes that boundary explicit.

### P2 — Capability model → derived settings + filter UI  📋

- Each detector declares capabilities (a `DetectorCapabilities` value, or extend
  `TunableDetector`).
- The capability/data model must be **introspectable** — a structured representation
  of each detection's fields that is the single source of truth for both the derived
  filter UI *and* the P4 raw-data inspector. No hand-maintained per-detector field
  lists.
- Settings schema + filter UI derive from capabilities: no confidence capability →
  no confidence slider, none in the filter projection.
- **Rectangles rework:**
  - Drop (or relabel as synthetic) the confidence knob — Vision rectangles have no
    probabilistic confidence.
  - Reclassify `quadratureToleranceDegrees` to a **pure post-hoc filter** computed
    from the corner keypoints Vision already returns. Symmetric + instant in both
    directions — fixes the current asymmetry (stricter = no-op pass-through; more
    permissive = cache-dump that blanks the overlay while paused).

### P3 — Capability-honest overlays + ratio display  ✅

_Shipped 2026-05-25 (`e0700a7` quad · `8ba40e6` skeleton + `VisionBodyPoseDetector` · `1ef2f3e` readouts). Geometry/topology/numeric all ride on the self-describing `Detection`; see [`DECISIONS.md`](../DECISIONS.md) 2026-05-25._


- Overlay renders per capability: keypoint skeletons for pose, boxes where boxes
  exist, no confidence chip where there's no real confidence.
- **Render rectangles as their detected quad** — connect the four corner keypoints
  (`topLeft→topRight→bottomRight→bottomLeft`), not the axis-aligned `boundingBox`.
  Today `DetectionLayer` strokes `Path(rect)` from the bbox (`DetectionLayer.swift:163-167`),
  so a rotated/perspective rectangle renders upright — the overlay misrepresents the
  shape (spatial dishonesty, the exact twin of fake confidence). The corners and the
  per-point converter already exist; this is small, and a second proof (with the pose
  skeleton) that the overlay draws real geometry.
- Numeric display: ratios, not percentages; per-detector meaningful ratio (rectangle
  aspect ratio / quadrature deviation; pose: joint count or none).
- Land the body-pose skeleton viz as the proof the overlay generalizes past boxes.

### P4 — Detector selection in the player  ✅

_Shipped 2026-05-25 (`4443d7f`) — `DetectorCatalog` + type-erased `ActiveDetectorSession`
in Iris, a detector picker in both demo players, capability-derived settings with no
per-detector demo code; `TuningRouter` gained `onDetectorTierChange` for the erased
re-emit hook. **Pending the user's visual smoke-test in the player.**_

_Added 2026-05-25. The honest detectors are unreachable from the demo: it hardcodes
`VisionRectanglesDetector` (iOS `ContentView.swift:500`, macOS `:365`) and never
instantiates `VisionBodyPoseDetector`, so playing a video never shows the skeleton.
This phase makes the player **select which detector is active** and tune it —
generally, because every new detector (M6 custom models included) needs the same
affordance. Resolves [`BRIEF.md`](../BRIEF.md) §5's "serial / parallel /
selector-gated" as **selector-gated, one active at a time**; multi-active parallel
stays deferred under the open "[multi-detector pipelines under `TuningModel`]"
question in [`QUESTIONS.md`](../QUESTIONS.md)._

All the machinery already exists — `DetectorPipeline` runs N detectors, `TuningModel`
and `CapabilityTuningView` are generic over any `TunableDetector`, and hot-swap is
wired (the pipeline reads `tuning.currentDetector` through the `TuningRouter` seam).
The gap is a selection layer:

- **`DetectorCatalog`** (Iris) — the list of available detectors: per entry a display
  name + a factory. The built-in Vision detectors ship as default entries; downstream
  apps register their own. Iris-level so M6 and every consumer reuse it.
- **Type-erased active session** — bundles the running detector's `TuningModel`
  (behind the existing type-erased `TuningRouter` seam the pipeline already reads) +
  an `AnyView` capability-derived settings panel, built by the entry's factory (which
  captures the concrete `TunableDetector` type in a closure). Lets the player hold
  "current detector + its panel" without compile-time knowing the type — no general
  `AnyTuningModel` needed.
- **Player picker** — iOS playback control bar + macOS sidebar/inspector. On change:
  build the detector, swap the tuning + pipeline, `invalidateAll()` the cache, re-emit
  the paused frame.

Proof: pick body pose in the player → skeleton on the dancer clip; pick rectangles →
honest quads — each with its own capability-derived settings, no per-detector demo code.

### P5 — Detection inspector (raw-data panel)  📋

A panel showing the *literal* structured data each detection carries — the
data-truth complement to P3's spatial-truth overlay. Together: "this is what
really comes back." It's also a forcing function: rendering fields generically
requires the detection model to be introspectable, so the panel can only display
fields that genuinely exist (you can't show a confidence that isn't there). The
capability matrix (P1) made live, and the validation surface for the whole
capability model.

- One shared `DetectionInspector` SwiftUI view, presented per platform: macOS via
  `.inspector()` side panel (Mac is the eval/curation target — natural home), iOS
  via a sheet / tap-a-detection popover.
- Per detection: geometry (box coords / keypoint positions / mask dims), confidence
  or `—` when the model has none, label, detector identity, the settings snapshot
  at capture, frame timestamp. Toggle: pretty-rendered vs. raw literal dump.
- Ships as a **debug mode** first; promotable to a first-class affordance later.
- Reads the same introspectable model P2 produces — no hand-maintained per-detector
  field lists (that's the robustness payoff).

## Opens (resolve during the milestone)

- Exact `DetectorCapabilities` shape — enum of geometry kinds + bool flags, or a
  richer descriptor? Decide in P2 against the P1 matrix.
- Synthetic confidence for geometric detectors: capability-honest says "show none."
  Confirm we're not quietly reintroducing it as a "quality" ratio unless it's
  labeled as derived.
- Body-pose coordinate handling must reuse the Vision-normalized ↔ view-space
  conversion centralized in `IrisOverlay` (CLAUDE.md invariant) — verify the skeleton
  path doesn't re-derive it.
- Does quadrature-as-keypoint-filter generalize to "shape knobs are filter-tier by
  construction" (the deferred maximal-output idea)? Scope-check in P2; don't let it
  balloon the milestone.

## Risks

- Vision 26 request catalog drift — verify value-type request/observation shapes
  against the current SDK during P1; don't trust memory.
- Overlay generalization: the skeleton is the first non-box viz; coordinate-space
  bugs surface here. Lean on static visual previews (CLAUDE.md "favorite pattern").
- Capability-model over-design — keep it as small as the 2 exemplars demand; resist
  modeling capabilities no shipped detector uses.

## Folds in (from M4 close)

- Vision confidence always 1.0 (the motivating example).
- `quadratureToleranceDegrees` filter-arm pass-through.

Both were the M4 "revisit on return" polish items; they're now P2 outcomes.
