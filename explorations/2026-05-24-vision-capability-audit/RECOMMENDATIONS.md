# Recommendations: Vision capability audit

Feeds a [`plans/DECISIONS.md`](../../plans/DECISIONS.md) entry and the P2 capability
model. Source matrix: [`SYNTHESIS.md`](./SYNTHESIS.md). Milestone:
[`plans/features/M5-honest-detectors.md`](../../plans/features/M5-honest-detectors.md).

## Recommendation

### 1. Capability axes for the P2 model

Model `DetectorCapabilities` around the dimensions that **actually vary** across
the built-in matrix — no more, no fewer. The matrix supports exactly these axes:

1. **Geometry kind** — an enum, modeled as a *set* per detector (face landmarks
   = box **and** keypoints; barcodes = quad **and** payload). Cases the matrix
   exercises: `box`, `quad`, `keypoints(skeleton)`, `contour`, `mask`, `heatmap`,
   `labelOnly`, `scalar`. **Wire payloads now only for `box`/`quad` + `keypoints`**
   (the two exemplars); keep the other cases in the enum but payload-deferred so
   P3/P4 fail honestly ("not yet rendered") rather than faking.
2. **Confidence semantics** — a three-case enum, the spine of the whole milestone:
   - `probabilistic` (whole-observation 0–1) — classify, human/face rect, animals,
     barcodes, document segmentation, trajectories.
   - `perElement` (per keypoint / per candidate) — pose family, text.
   - `none` — rectangles (constant 1.0), contours, horizon, saliency, masks.
   - Plus a **`derivedScalar(label:)`** case for the traps — face capture quality,
     aesthetics — so a quality metric can be displayed *as a labeled scalar*, never
     laundered into `Detection.confidence`. This directly answers the milestone
     open "are we quietly reintroducing confidence as a quality ratio?": yes it can
     be shown, but only behind an explicit `derivedScalar` label.
3. **Tunable knob set** — already expressed by the existing `SettingSchema` /
   `Knob` / `SettingKind` machinery; capabilities just reference it. Two gaps the
   matrix surfaced: add `SettingKind.string` and `SettingKind.enum`/`oneOf` (text
   recognition needs them; already a TODO in `VisionRectanglesSettings`). `revision`
   is **not** a tuning knob — model it as detector-construction config.
4. **Introspectable field set** — the structured, per-detection field list that is
   the single source of truth for both the derived filter UI (P2) and the raw-data
   inspector (P4). This is the axis that forces the model to be data-driven rather
   than a fixed `box/keypoint/mask` triple: it must enumerate the extra payloads
   (barcode string, text candidates, face pose angles, labels) so P4 can render
   "what really comes back" generically and P2 can project filter controls only
   over fields that exist.
5. **Renderability vs. inspectability** — a derived split, not a stored axis:
   geometry kind drives what P3 *draws*; the field set drives what P4 *lists*. Keep
   them as two projections of the same capability value so they can't drift (the
   milestone's "data-truth complement to spatial-truth" framing).

Deliberately **excluded** (no built-in detector justifies them): a "general
object box + arbitrary class" capability (that's M6 Core ML), and statefulness as
a *capability* flag — trajectories/tracking are real but out of the single-frame
`detect(in: Frame)` scope; defer rather than model now.

### 2. Exemplar verdict — confirmed: rectangles (rework) + human body pose

**Keep both.** They are the maximally-instructive pair:

| Axis | Rectangles (reworked) | Human body pose |
|---|---|---|
| Geometry | quad (4 corners) + box | keypoints (skeleton) |
| Confidence | **none** (constant 1.0 — the bug) | **per-element** (real per-joint) |
| Tunable | several real knobs (aspect/size/observations) + the fake `minimumConfidence` to drop | essentially none beyond `detectsHands` |
| Filter story | `quadratureToleranceDegrees` → post-hoc corner-angle filter | per-joint confidence threshold (honest, real) |

Together they exercise **every value** of the confidence axis that matters
(`none` vs `perElement`), the two geometry kinds the exemplars must render
(quad+box vs. skeleton), and both ends of the tunable spectrum (rich-but-partly-fake
vs. nearly-empty). Body pose is the right second exemplar precisely because its
per-joint confidence is the honest mirror image of rectangles' fake one — proving
the overlay generalizes past boxes and the capability model handles "real
confidence, but located per-keypoint."

**Considered and rejected as the second exemplar:**
- *Text recognition* — richest tunable surface, but heaviest to wire (needs new
  `SettingKind` variants) and its confidence is per-candidate, a third shape that
  over-extends the first proof. Better as a P2-follow-on once the model exists.
- *Animals / human rectangles* — real probabilistic confidence, but geometry is
  just a box; too close to "rectangles but honest," doesn't prove the
  keypoint/overlay generalization that's the milestone's stated risk.
- *Document segmentation* — a sharp teaching case (same `RectangleObservation`
  type as rectangles, but **real** confidence). Worth citing in the DECISIONS
  note as the proof that confidence semantics are per-detector, not per-observation-type;
  not needed as a built exemplar.

### 3. Traps to avoid (don't pick these as exemplars / wire carefully)

- **`DetectHumanBodyPose3DRequest`** — works monocularly but **metric scale needs
  LiDAR/depth hardware** (iPhone 12 Pro+). Fine as a future detector; a poor
  *first* skeleton exemplar because device variance muddies the proof. Use the 2D
  `DetectHumanBodyPoseRequest` for the exemplar.
- **`DetectFaceCaptureQualityRequest` / `CalculateImageAestheticsScoresRequest`**
  — their scores look like confidence and are not. They are the canonical
  "honest UI" trap; model as `derivedScalar(label:)`, never `Detection.confidence`.
- **`DetectRectanglesRequest.minimumConfidence`** — a real request property that is
  meaningless given the constant-1.0 observation confidence. Drop it from the
  reworked rectangles schema (or relabel as synthetic) — it's the exact knob the
  milestone exists to delete.
- **`DetectTrajectoriesRequest` + the `Track*` requests** — **stateful/multi-frame**;
  they don't fit `detect(in: Frame)` without an `actor`-backed stateful conformer.
  Out of M5 scope.
- **Legacy `VN…` API confusion** — write the model against the new value-type
  observation names (`HumanBodyPoseObservation`, `RectangleObservation`, …), not the
  legacy `VN`/`RecognizedPointsObservation` umbrella that several web writeups use.
- **`revision`** — present on nearly everything; tempting to expose as a knob, but
  it's a correctness/versioning lever, not user tuning. Keep it out of the tuning
  schema.

## Why

The matrix shows the design is right: confidence is **not** one thing across Vision
(probabilistic / per-element / none / derived-scalar), geometry is genuinely plural,
and tunable surfaces range from empty to rich. A flat `Detection.confidence: Float`
and a fixed box/keypoint/mask shape can't tell the truth about all of these — which
is the bug M5 is fixing. Deriving the axes from observed variance (rather than an
invented taxonomy) keeps the model as small as the two exemplars demand while still
covering every distinction the inspector and overlay must honor. The rectangles +
body-pose pair is the smallest set that lights up both ends of the two axes that
matter most (confidence semantics, geometry kind).

## Caveats

- **Don't over-model deferred geometries.** Contour/heatmap/scalar/mask payloads
  have no built exemplar; model the enum case, defer the payload. If P2 starts
  building mask/heatmap rendering "while we're here," that's the over-design risk
  the plan warns about — push back.
- **Mask payload shape** (`Detection.Mask`) stays an open TODO; the first real
  consumer (instance masks / saliency) will pin it, not M5.
- **`SettingKind` gaps** (`.string`, `.enum`) are only needed if a text-style
  detector lands; the two exemplars don't require them. Add when the third
  detector forces it, consistent with the existing "revisit at the third settings
  type" note.
- **API drift** — names verified against WWDC24 "Discover Swift enhancements in the
  Vision framework," WWDC25 document-reading session, and current Vision docs via
  context7. Re-verify exact observation property spellings at P2 implementation
  time against the installed iOS/macOS 26 SDK before committing code.
