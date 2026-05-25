# Synthesis: Vision capability audit

## Context

M5 ("honest detectors") rests on one observation: a detector should expose only
the settings it actually has, and the overlay should render only what the model
actually knows. The motivating bug — `VisionRectanglesDetector` shipped a
confidence slider that does nothing and a "100%" readout that is a geometric
artifact, not a probability (`RectangleObservation.confidence` is always `1.0`).

This audit inventories Apple's **built-in Vision** detector surface so P2 can
derive a capability model from *what actually varies* across detectors, and
P3/P4 can render/inspect only what's real. See the plan:
[`plans/features/M5-honest-detectors.md`](../../plans/features/M5-honest-detectors.md).

### Scope and API generation

- **In scope:** the **new Swift value-type Vision API** (`DetectRectanglesRequest`
  → `RectangleObservation`, `request.perform(on:orientation:)` returning typed
  observations). This is the generation the codebase already targets — see
  [`VisionRectanglesDetector.swift`](../../Sources/Iris/Detection/Vision/VisionRectanglesDetector.swift)
  ("API choice" doc comment). Verified: the detector builds a `var request =
  DetectRectanglesRequest()`, sets `var Float` knobs, and `await`s
  `request.perform(...)`. That is the value-type generation, confirmed.
- **Out of scope:** the legacy `VN…Request` / `VNObservation` ObjC class API
  (still callable, but Iris doesn't use it), and Core ML / Foundation-Models
  backends (separate `Detector` conformers, later milestones).
- **Platform floor:** iOS / macOS 26, Swift 6 strict concurrency. The new API's
  observations are `Sendable` value types, which is why the pipeline crosses
  actor boundaries cleanly (per `Detector` doctrine).

### Naming note (matters for P2/P4 code)

Two parallel type families exist. Legacy: `VNHumanBodyPoseObservation`,
`VNRecognizedPointsObservation`, `VNRectangleObservation`, …. New value-type:
`HumanBodyPoseObservation`, `RectangleObservation`, `RecognizedTextObservation`,
`ClassificationObservation`, etc. **This audit and the matrix use the new-API
spellings.** Some third-party writeups conflate the two (e.g. mapping pose to
`RecognizedPointsObservation` — that's the legacy umbrella type). In the new
API, pose joints are reached via `observation.allJoints()` →
`[JointName: Joint]`, where each `Joint` carries `confidence: Float`,
`jointName`, and `location: NormalizedPoint`.

### How this maps onto Iris's `Detection`

[`Detection`](../../Sources/Iris/Detection/Detection.swift) today is box-centric:
`boundingBox: CGRect` (always present), `label`, `confidence: Float` (doc says
"`1.0` for detectors that don't emit confidences"), optional `keypoints:
[Keypoint]?`, optional `mask: Mask?`. The flat `confidence: Float` is exactly the
field that lies for rectangles. The matrix below is what tells P2 which
detectors need that field to be **absent**, **per-element**, or **scalar/derived**
rather than a single fake number.

---

## The capability matrix

One row per built-in detector. Columns:

- **Request → Observation** — new-API struct names.
- **Geometry** — box / quad / keypoints(skeleton) / mask / heatmap / contour /
  label-only / scalar.
- **Real confidence?** — **yes** (probabilistic, 0–1), **per-element** (per
  joint/candidate), or **none** (geometric / derived / constant). The "none"
  rows are the design justification.
- **Tunable params** — genuinely settable request properties (new-API), or
  "none".
- **Notes** — anything affecting how it's modeled / rendered / tuned.

### Body / hand / pose

| Request → Observation | Geometry | Real confidence? | Tunable params | Notes |
|---|---|---|---|---|
| `DetectHumanBodyPoseRequest` → `HumanBodyPoseObservation` | keypoints (skeleton, 2D normalized) | **per-element** — each `Joint.confidence: Float` | `detectsHands: Bool` (folds hand joints into `.leftHand` / `.rightHand`); `revision` | The strong contrast to rectangles: rich keypoints + **real per-joint confidence**. No probabilistic *whole-observation* confidence; meaning lives at the joint. `allJoints()` → `[JointName: Joint]`. Joints below a confidence threshold are commonly filtered by the consumer (a genuine, model-honest filter). |
| `DetectHumanBodyPose3DRequest` → `HumanBodyPose3DObservation` | keypoints (skeleton, 3D camera-relative) | **per-element** (per recognized point) | `revision` | 3D positions in meters via `cameraRelativePosition(_:)`. Works monocularly but **metric scale needs a LiDAR/depth device** (iPhone 12 Pro+). A *partial trap* for a cross-device exemplar — see RECOMMENDATIONS "traps". |
| `DetectHumanHandPoseRequest` → `HumanHandPoseObservation` | keypoints (21-joint hand skeleton) | **per-element** (per joint) | `maximumHandCount: Int`; `revision` | Same shape as body pose; `maximumHandCount` is a genuine model knob (how many hands to return). |
| `DetectAnimalBodyPoseRequest` → `AnimalBodyPoseObservation` | keypoints (animal skeleton) | **per-element** (per joint) | `revision` | Skeleton topology differs by species; same per-joint-confidence shape as human pose. |

### People / face

| Request → Observation | Geometry | Real confidence? | Tunable params | Notes |
|---|---|---|---|---|
| `DetectHumanRectanglesRequest` → `HumanObservation` | box | **yes** (detection confidence) | `upperBodyOnly: Bool`; `revision` | A real probabilistic detector — but only of *people*, not general objects. `upperBodyOnly` switches the box semantics (full body vs. torso-up). |
| `DetectFaceRectanglesRequest` → `FaceObservation` | box (+ roll/yaw/pitch pose angles) | **yes** (face-detection confidence) | `revision` | Box plus head-pose scalars. The pose angles are extra **scalar** fields the inspector (P4) can surface. |
| `DetectFaceLandmarksRequest` → `FaceObservation` | box + keypoints (landmark constellation) | **yes** (observation) + landmark-region geometry | `revision` | Superset of face rectangles: adds `landmarks` (eyes, nose, mouth, contour as point regions). Landmarks have their own per-region geometry. |
| `DetectFaceCaptureQualityRequest` → `FaceObservation` | box + **scalar** (`faceCaptureQuality`) | **none, but a derived scalar** | `revision` | Subtle: `faceCaptureQuality` is a 0–1 *quality* metric, **not** a detection probability. Exactly the "is this a confidence?" trap M5 warns about — model it as a labeled derived scalar, never as `Detection.confidence`. |

### Objects / labels

| Request → Observation | Geometry | Real confidence? | Tunable params | Notes |
|---|---|---|---|---|
| `RecognizeAnimalsRequest` → `RecognizedObjectObservation` | box + label(s) | **yes** — `labels: [(identifier, confidence)]` per box, **per-element** across labels | `revision` | Closest thing to an object detector in built-in Vision, but **closed-class**: only cats & dogs. Each box carries a ranked label list with real confidences. Not a general object-box detector. |
| `ClassifyImageRequest` → `ClassificationObservation` | **label-only** (whole-image, no geometry) | **yes** — `confidence: Float` 0–1 per class | `revision`; consumer-side `hasMinimumRecall(_:forPrecision:)` / `hasMinimumPrecision(_:forRecall:)` thresholding | No bounding box at all — returns a ranked list of class labels for the entire image. The canonical **label-only** geometry case. Thresholding is via precision/recall helpers, not a single slider. |

### Geometry

| Request → Observation | Geometry | Real confidence? | Tunable params | Notes |
|---|---|---|---|---|
| `DetectRectanglesRequest` → `RectangleObservation` | quad (4 corners) + axis-aligned box | **none** — `confidence` is constant `1.0` (geometric) | `minimumAspectRatio`, `maximumAspectRatio`, `minimumSize`, `maximumObservations`, `quadratureToleranceDegrees`, `minimumConfidence` | **The motivating example.** `confidence` is not probabilistic; `minimumConfidence` is a request-level gate that does nothing meaningful given constant 1.0. The four corners (`topLeft`…`bottomLeft`) are the real signal — already captured as `Detection.keypoints`. `quadratureToleranceDegrees` is reclassifiable as a post-hoc corner-angle filter (P2). |
| `DetectContoursRequest` → `ContoursObservation` | contour (nested polyline paths) | **none** (geometric) | `contrastAdjustment: Float`, `detectsDarkOnLight: Bool`, `maximumImageDimension: Int` (+ `contrastPivot` on newer revisions) | Returns a tree of contour paths, not boxes. Geometry kind unique to this detector — a `contour`/path payload `Detection` doesn't model yet. |
| `DetectHorizonRequest` → `HorizonObservation` | **scalar** (`angle`) + transform | **none** (geometric) | `revision` | No box, no keypoints — just a horizon tilt angle and an affine transform. Pure scalar output; nothing to draw as a box. |
| `DetectDocumentSegmentationRequest` → `RectangleObservation` | quad (4 corners) | **yes** — has a meaningful `confidence` (ML-backed document detector, unlike geometric rectangles) | `revision` | Same observation *type* as rectangles but different confidence semantics: this one is ML-backed, so its confidence is real. A clean example of "two detectors, same geometry type, different confidence truth." |
| `DetectBarcodesRequest` → `BarcodeObservation` | box/quad + **payload** (decoded string) | **yes** (per barcode) | `symbologies: [VNBarcodeSymbology]`; `revision` | Carries decoded `payloadString` + `symbology` — rich non-geometric fields the inspector should surface. `symbologies` is a genuine multi-select knob (which code types to detect). |

### Text

| Request → Observation | Geometry | Real confidence? | Tunable params | Notes |
|---|---|---|---|---|
| `RecognizeTextRequest` → `RecognizedTextObservation` | box/quad + **text candidates** | **per-element** — `topCandidates(_:)` each `RecognizedText.confidence` | `recognitionLevel` (`.fast`/`.accurate`), `recognitionLanguages: [Locale.Language]`, `usesLanguageCorrection: Bool`, `automaticallyDetectsLanguage: Bool`, `customWords: [String]`, `minimumTextHeightFraction: Float`; `revision` | The **richest tunable surface** of any built-in detector — enum, multi-select (languages), toggles, float, string-list. Confidence is per text candidate, not per box. Good stress test for the settings schema, but heavy as an *exemplar*. |

### Saliency

| Request → Observation | Geometry | Real confidence? | Tunable params | Notes |
|---|---|---|---|---|
| `GenerateAttentionBasedSaliencyImageRequest` → `SaliencyImageObservation` | **heatmap** (pixel buffer) + salient-object bounding boxes | **none** (saliency values, not probabilities) | `revision` | Returns a low-res saliency `pixelBuffer` plus `salientObjects` boxes. Heatmap geometry — distinct rendering path. |
| `GenerateObjectnessBasedSaliencyImageRequest` → `SaliencyImageObservation` | **heatmap** + objectness boxes | **none** (objectness, not probability) | `revision` | Same observation type, "objectness" rather than "attention" model. Pairs with attention-based as a two-flavor case. |

### Masks

| Request → Observation | Geometry | Real confidence? | Tunable params | Notes |
|---|---|---|---|---|
| `GenerateForegroundInstanceMaskRequest` → `InstanceMaskObservation` | **mask** (per-instance pixel mask) | **none** (mask, no detection score) | `revision` | Per-instance foreground masks; `instances` index set + mask generation. The first real consumer of `Detection.mask` (whose payload shape is still a TODO). |
| `GeneratePersonInstanceMaskRequest` → `InstanceMaskObservation` | **mask** (person instances) | **none** | `revision` | Person-specialized variant of the above. |
| `GeneratePersonSegmentationRequest` → (segmentation mask buffer) | **mask** (binary/alpha) | **none** | `qualityLevel` (`.accurate`/`.balanced`/`.fast`); `revision` | `qualityLevel` is a genuine knob. Whole-frame person matte rather than per-instance. |

### Trajectories

| Request → Observation | Geometry | Real confidence? | Tunable params | Notes |
|---|---|---|---|---|
| `DetectTrajectoriesRequest` → `TrajectoryObservation` | keypoints/path (parabolic) over time | **yes** (`confidence`) | `frameAnalysisSpacing: CMTime`, `objectMinimumNormalizedRadius: Float`, `objectMaximumNormalizedRadius: Float`; `revision` | **Stateful / multi-frame** — needs a sequence of frames, not a single `Frame`. Doesn't fit the current `detect(in: Frame)` one-shot signature without an `actor`-backed stateful conformer (allowed by `Detector` doctrine, but a build cost). |

### Also present (catalog completeness)

- `CalculateImageAestheticsScoresRequest` → `ImageAestheticsScoresObservation` —
  **scalar** (`overallScore` −1…1) + `isUtility: Bool`. Not a detection; a
  whole-image quality score. Another "scalar, not confidence" case.
- `TrackObjectRequest` / `TrackRectangleRequest` / `TrackHomographicImageRegionRequest`
  → tracking observations — **stateful sequence** requests (like trajectories);
  out of scope for single-frame `detect(in:)`.
- `GenerateImageFeaturePrintRequest` → `FeaturePrintObservation` — an embedding
  vector for similarity, **no geometry, no confidence**; relevant to M6 (dataset
  similarity) more than M5.

---

## The boundary: no general object-box detector

**Built-in Vision has no general-purpose object detector** (the "box + arbitrary
class label + real confidence" detector people expect from YOLO/SSD). The closest
built-ins are all **specialized**:

- People (`DetectHumanRectanglesRequest`) — boxes, but only of humans.
- Animals (`RecognizeAnimalsRequest`) — boxes + labels, but a **closed two-class**
  set (cat / dog).
- Faces, barcodes, rectangles, documents, text — each a single domain.

General multi-class object boxes require a Core ML model (YOLO and friends) — that
is **M6**, a separate `Detector` conformer. The matrix makes this boundary
explicit so P2 doesn't model a "general object box" capability that no built-in
detector exercises (a noted over-design risk in the milestone plan).

---

## What varies across the matrix (the raw material for P2's axes)

Reading down the columns, these are the dimensions that *actually differ*:

1. **Geometry kind** — and it's genuinely plural: box, quad, keypoints(skeleton),
   contour(path), mask, heatmap, label-only, scalar. `Detection` today models box
   + optional keypoints + optional mask; it has **no** native contour, heatmap, or
   scalar-only representation. P2 must decide which to model now (the two exemplars
   need box/quad + keypoints) vs. defer.
2. **Confidence semantics** — three distinct truths: **probabilistic**
   (classify, human/face rect, animals, barcodes, document seg, trajectories),
   **per-element** (pose joints, text candidates), and **none/derived**
   (rectangles=constant 1.0, contours, horizon, saliency, masks; plus the
   *trap* derived scalars: face capture quality, aesthetics). The flat
   `Detection.confidence: Float` cannot express this — it's the field that lies.
3. **Where confidence lives** — whole-observation vs. per-keypoint vs.
   per-candidate-label. Rendering and inspection differ accordingly.
4. **Tunable-param set** — ranges from **none** (horizon, the pose family beyond
   `revision`) through a single knob (`qualityLevel`, `maximumHandCount`,
   `upperBodyOnly`) to the **rich** text surface (enum + multi-select + toggles +
   float + string-list). The settings schema (`SettingKind`) already covers
   float/int/toggle/multiSelect; text would need a `.string` / `.enum` variant
   (already flagged as a TODO in `VisionRectanglesSettings`).
5. **Extra structured fields** — payloads beyond geometry+confidence: barcode
   payload string, text candidate strings, face pose angles, document/animal
   labels. These are exactly what the P4 inspector exists to surface, and why P2's
   model must be **introspectable** rather than a fixed box/keypoint/mask triple.
6. **Statefulness** — single-frame (almost all) vs. multi-frame sequence
   (trajectories, tracking). Affects whether a detector fits `detect(in: Frame)`
   directly.
7. **Availability / hardware** — most are universal on iOS/macOS 26; 3D body pose
   needs depth hardware for metric scale; capture session features are iOS-only
   (but these are all image-request detectors, so they run on macOS too).

## Open threads

- **Mask payload shape** is still a TODO on `Detection.Mask`. Saliency
  (heatmap) and instance masks would force a decision; neither is an M5 exemplar,
  so this can stay deferred — but P2 should *model the capability* (geometry =
  mask/heatmap) even if the payload stays a placeholder.
- **Contour / scalar / heatmap geometries** have no `Detection` representation.
  The two exemplars don't need them, so the recommendation is to model the
  capability *enum* with these cases present but only wire payloads for box/quad
  + keypoints now. Confirm in P2 against the over-design risk.
- **`revision`** appears on nearly every request. It's a correctness/versioning
  knob, not a user-facing tuning knob — should be modeled as detector-construction
  config, not a `Knob` in the tuning schema.
- **Text recognition** is the most tempting "show off the schema" detector but
  the heaviest to wire as an exemplar (and needs new `SettingKind` variants).
  Body pose is the leaner second exemplar — see RECOMMENDATIONS.
