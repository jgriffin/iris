# Synthesis: converting external PyTorch detectors to Core ML for Iris

## Context

Iris runs models through Core ML / Vision (the new value-type Vision API on
iOS/macOS 26); it does **not** run PyTorch. Every external model must be
converted to an `.mlpackage` offline. A future `CoreMLDetector` will conform to
the existing [`Detector`](../../Sources/Iris/Detection/Detector.swift) protocol
(`detect(in:) async throws -> [Detection]`, plus `availability`,
`modelIdentifier`, `prewarm()`) and, when tunable, to
[`TunableDetector`](../../Sources/Iris/Tuning/TunableDetector.swift) with a
[`DetectorCapabilities`](../../Sources/Iris/Detection/DetectorCapabilities.swift)
descriptor.

The decisive fork is **how the converted model's output is decoded** — see
[QUESTIONS.md](./QUESTIONS.md). This document records the per-model findings and
the tradeoffs; [RECOMMENDATIONS.md](./RECOMMENDATIONS.md) says what to do.

All facts below are checked against live docs as of **2026-05-25**; sources are
cited inline and collected at the bottom. Items I could not confirm against a
live primary source are marked 👀.

> ⚠️ **This was a doc-only pass; some predictions were wrong.** See the
> empirical-recheck section immediately below for the corrections (chiefly:
> **YOLO26 is path B, not path A**, and RF-DETR's real route is a direct
> PyTorch→Core ML patched fork, not ONNX→coremltools). The per-model findings
> further down are preserved as the original record — read them through the
> corrections.

---

## Update — 2026-05-25 (empirical recheck)

The original sections below were **doc-only**. An actual export run (**ultralytics
8.4.54, coremltools 9.0, Apple M1 Max**) corrected three things. The original text
is kept verbatim as a record of what doc-only research suggested; this section is
authoritative where they conflict.

**1. YOLO26 is PATH B, not PATH A — `nms` is forced off for end2end models.**
The doc-only pass predicted `nms=True` would wrap YOLO26 in an NMS pipeline like
v12 and land it on path A. It does **not**. ultralytics **refuses NMS on any
`end2end` model**: `nms=True` warns *"'nms=True' is not available for end2end
models"* and exports with `nms=False` anyway. YOLO26 therefore always comes out as
a **raw `[1,300,6]` mlProgram** (PATH B). The upside: **decode is trivial and needs
NO NMS** — the one-to-one head self-dedupes, so you just threshold and scale the
(up to) 300 rows `[x, y, w, h, conf, class]`. Labels live in **`userDefined`
metadata `names`**, not in an NMS stage.

**2. YOLOv12 is the true zero-decode PATH A.** Confirmed: classic Detect models
exported with **`nms=True`** produce a top-level **`pipeline`** ending in
`nonMaximumSuppression`, outputs **`coordinates` + `confidence`**, with **80 COCO
labels baked into the NMS stage** (`stringClassLabels`). Vision auto-decodes — no
Swift decoder. **`nms` defaults to `false`**, so a bare `format=coreml` gives PATH
B (raw `[1,84,8400]`); you must pass `nms=True`.

**3. Label location is path-dependent.** PATH A → NMS stage `stringClassLabels`;
PATH B → `userDefined` metadata `names`. (The original prose said
`userDefinedMetadata` for both — the coremltools-9 attribute is `userDefined`, and
path-A labels aren't there at all.)

**4. RF-DETR — real route corrected.** Not "ONNX→coremltools (unproven)". The
`rfdetr` package's `export()` does **ONLY onnx/tflite** (hard-raises otherwise);
Roboflow **won't** add Core ML (issue #318 **closed** — it's behind their hosted
platform + `roboflow-swift`). The proven OSS route is a **direct PyTorch→Core ML**
conversion via patched forks: [`landchenxuan/rf-detr-to-coreml`][rfdetr-coreml-fork]
(v1.5.1 detect+seg, runtime monkey-patches), building on
[`timnielen/rf-detr`][rfdetr-timnielen] (deformable-attention rank-5 fix),
**FP32-only** (FP16 fails to compile). Still **off the critical path**, still PATH
B needing a Swift DETR set-prediction decoder.

**5. CLI ≡ Python API.** `yolo export model=X format=coreml` is the *same code
path* as `YOLO(X).export(format='coreml')` (the CLI is just an arg-parser). There
is **no `yolo download`** command (it errors); `yolo export`/`predict`
auto-download weights on first use.

Net effect on the recommendation: **start with YOLOv12 (true zero-decode path A),
not YOLO26.** See [RECOMMENDATIONS.md](./RECOMMENDATIONS.md) §"Update".

---

## The decode fork (the thing everything hinges on)

Vision decides what kind of observation to return from a Core ML model based on
**the model's output spec**, not on a request flag:

| Converted model's output spec | Vision returns | Who decodes boxes |
| --- | --- | --- |
| A **pipeline** ending in Core ML's built-in `NonMaximumSuppression` model, with two named outputs `coordinates` (boxes) + `confidence` (per-class scores) | `RecognizedObjectObservation` (legacy `VNRecognizedObjectObservation`) — box + labels + confidence, normalized `[0,1]`, **bottom-left origin** | **Vision / Core ML** (free) — **path (A)** |
| A plain tensor output (e.g. `MLMultiArray` of shape `(1, 84, 8400)`) | `CoreMLFeatureValueObservation` (legacy `VNCoreMLFeatureValueObservation`) — the raw tensor | **Iris, in Swift** — **path (B)** |

This is the long-standing Turi Create / Create ML object-detector contract: an
object detector is a **two-stage pipeline** whose final stage is the
`NonMaximumSuppression` spec, and only then does Vision auto-decode it
([Apple Turi export-to-Core ML][turi]; [Apple `VNRecognizedObjectObservation`][vnobj]).
A model lacking that NMS stage "will instead return
`VNCoreMLFeatureValueObservation` objects" ([ultralytics/yolov5#1575][yolov5-1575]).

**New iOS/macOS 26 Swift API.** The value-type replacement for
`VNCoreMLRequest` is [`CoreMLRequest`][coremlrequest] (Vision); its raw-tensor
observation is [`CoreMLFeatureValueObservation`][cmlfvo]. The *decision rule is
the same* — it's a property of the compiled model's output spec, not the request
type. 👀 The exact name of the auto-decoded observation in the pure-Swift value
API (whether `RecognizedObjectObservation` exists as a value type, or whether the
auto-decode path still vends the `VN`-prefixed class) should be confirmed against
the installed iOS/macOS 26 SDK at implementation time; the legacy
`VNRecognizedObjectObservation` is documented and available either way.

**Why this matters for Iris.** Path (A) makes `CoreMLDetector` a thin adapter:
read `boundingBox` + top label + `confidence` off each observation, flip Y to
Vision-native bottom-left (already Iris's convention — see
[`Detection`](../../Sources/Iris/Detection/Detection.swift)), done. Path (B)
forces Iris to ship a per-architecture decoder (threshold, box-format conversion,
NMS, sigmoid/softmax). The conversion choices below determine which path each
model lands on.

---

## Per-model findings

### Summary table

| Model | Variants / sizes | Default input | Native NMS-free? | Export path | Output type as exported | Decode needed in Swift | Vision path | Feasibility |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **Ultralytics YOLOv12** | n / s / m / l / x | 640×640 | No (attention head + NMS) | `model.export(format="coreml", nms=True)` — native | Pipeline → `NonMaximumSuppression` | **None** (Vision decodes) | **(A)** | **Clean** |
| **Ultralytics YOLO26** | n / s / m / l / x | 640×640 | **Yes** (one-to-one head, `(N,300,6)`) | `model.export(format="coreml", nms=True)` — native | Pipeline → `NonMaximumSuppression` | **None** (Vision decodes) | **(A)** | **Clean** |
| YOLO (either) **without** `nms` | — | 640×640 | — | `model.export(format="coreml")` | Raw `MLMultiArray` | threshold → cxcywh→xyxy → NMS (v12) / dedup (26) | (B) | Works, more Swift |
| **RF-DETR** (N/S/M/L) | Nano 384, Small 512, Medium 576, Large 704 | per-variant | **Yes** (DETR set-prediction) | PyTorch → **ONNX** (native) → coremltools (manual, unproven) | Raw tensors `dets`+`labels` (if conversion succeeds) | sigmoid → flatten top-k → cxcywh→xyxy; **no NMS** | (B) | **Needs-work / blocked-unknown** |
| RF-DETR XL / 2XL | XL 700, 2XL 880 | per-variant | Yes | same, + **PML-1.0 license** | same | same | (B) | Same + license gate |

---

### 1. Ultralytics YOLOv12

- **Real, current.** Five sizes `yolo12{n,s,m,l,x}.pt`, all at **640×640** input
  ([Ultralytics YOLO12 docs][yolo12]).
- **Architecture: attention-centric, NOT NMS-free.** YOLOv12 uses Area Attention
  (A2) + FlashAttention + a standard decoupled head and **requires NMS
  post-processing** — unlike YOLOv10's dual-label-assignment NMS-free head
  ([YOLOv12 paper][yolov12-paper]; [Roboflow model survey][roboflow-survey]).
- **Core ML export — native and first-class.** `pip`/`uv`-installed `ultralytics`
  exports directly:
  ```python
  from ultralytics import YOLO
  YOLO("yolo12s.pt").export(format="coreml", nms=True, imgsz=640, half=True)
  ```
  Verified against the exporter source ([Ultralytics `engine/exporter`][exporter]
  via context7) and the Core ML integration page ([Ultralytics CoreML][coreml-int]).
- **`nms=True` is the path-(A) switch.** In the exporter, when `task == "detect"`
  and `nms=True`, the model is wrapped in `IOSDetectModel` and then passed through
  `pipeline_coreml(...)` — which appends the Apple **`NonMaximumSuppression`**
  stage and writes `iou` / `conf` / `agnostic_nms` into it. The result is the
  two-output (`coordinates` + `confidence`) pipeline Vision auto-decodes into
  recognized-object observations ([exporter source][exporter]). **Without `nms`,
  you get a raw tensor** (path B) — the standard YOLO `(1, 84, 8400)`-style head.
- **Export args** ([CoreML integration][coreml-int], confirmed in source):
  `format`, `imgsz` (default `640`), `dynamic` (bool), `half` (FP16), `int8`,
  `nms`, `batch`, `device`. Constraints from source: `dynamic=True` **cannot** be
  combined with `nms=True`; `batch>1` requires `dynamic=True`; `coremltools>=9.0`
  and `numpy<=2.3.5` (numpy 2.4.0rc1 breaks export).
- **Input image type & scaling.** The non-dynamic export declares an
  `ct.ImageType("image", scale=1/255, bias=[0,0,0])` — so the model takes an
  **image input** at a **fixed** `imgsz` and does the `/255` normalization
  internally ([exporter source][exporter]). Because the input is fixed-size,
  **letterboxing is the caller's job**: Vision's image-crop-and-scale option
  decides how the incoming frame is fit to the model's square input. A
  **center-crop or stretch that doesn't match how the model was trained corrupts
  box coordinates** — boxes come back offset/scaled. The safe option that matches
  YOLO's letterbox training is "scale-to-fit with aspect preserved"; a plain
  stretch ("scaleFill") distorts. This is the classic Vision↔YOLO box-misalignment
  trap ([machinethink bounding-boxes][machinethink]).
- **Class labels** live in the model's **metadata** (`names` map). The exporter
  threads `self.metadata` into `pipeline_coreml`, so the COCO (or custom) class
  names ship inside the `.mlpackage` and Vision surfaces them as the observation
  labels ([exporter source][exporter]).
- **Compute units / ANE.** Core ML runs on CPU+GPU+ANE; the unit is chosen at
  load via `MLModelConfiguration.computeUnits` (Swift) / `compute_units` (coremltools).
  `half=True` (FP16) is the ANE-friendly precision. 👀 No model-specific ANE
  residency guarantee is documented; treat ANE placement as best-effort and
  measure.

### 2. "YOLO26" / YOLOv26 — **it is real**

The flagged-uncertainty item resolves **affirmatively**:

- **YOLO26 is a genuine Ultralytics release.** Announced at YOLO Vision 2025
  (London), with model weights downloadable; it is the current edge-first
  flagship ([Ultralytics YOLO26 docs][yolo26]; [Ultralytics YOLO26 blog][yolo26-blog]).
  There is also an arXiv writeup ([YOLO26 arXiv 2509.25164][yolo26-arxiv]).
- **Five sizes** `yolo26{n,s,m,l,x}.pt`, **640×640** input, same task family as
  prior YOLOs (detect/seg/pose/obb/cls) ([YOLO26 docs][yolo26]).
- **Key difference from v12: it is NATIVELY NMS-free / end-to-end.** "YOLO26 is a
  native end-to-end model, producing predictions directly without … NMS." The
  default one-to-one head outputs **`(N, 300, 6)`** — up to 300 detections, each
  `[x, y, w, h, conf, class]`-style ([YOLO26 docs][yolo26]).
- **Core ML export — same command, and `nms=True` still applies.** The exporter
  treats YOLO26 like any Detect model: `nms=True` wraps it in `IOSDetectModel` +
  `pipeline_coreml`, so it **still lands on path (A)** (Vision auto-decode). The
  exporter source even uses `'yolo26n.pt'` as its example filename in the
  `nms`-only-for-Detect warning ([exporter source][exporter]). 👀 *Nuance:*
  YOLO26's native head is already NMS-free `(N,300,6)`, so `nms=True` mostly adds
  the Vision-compatible **output-formatting** stage (the `coordinates`/`confidence`
  split + a light/agnostic NMS) rather than meaningful duplicate-suppression. The
  practical guidance is unchanged: **export with `nms=True` to get path (A)**;
  whether the appended NMS stage is a strict no-op for the one-to-one head is a
  detail to confirm by inspecting the exported spec, not a blocker.
- **Why prefer 26 over 12 for Iris:** NMS-free means fewer post-processing knobs
  and lower/decode-cheaper inference; ~43% faster CPU than YOLO11 for nano per
  Ultralytics ([YOLO26 blog][yolo26-blog]). Same Iris-side code either way (both
  are path A).

### 3. RF-DETR (Roboflow) — the high-risk one

- **Repo & license.** `roboflow/rf-detr`, ICLR 2026, DINOv2-backbone real-time
  detection transformer ([RF-DETR GitHub][rfdetr-gh]). **Split license:** the
  `rfdetr` package + the **Nano / Small / Medium / Large** detection weights and
  all **segmentation** weights are **Apache-2.0**; **XL / 2XL** ("Plus") weights
  are **PML-1.0** ([RF-DETR GitHub][rfdetr-gh]). For Iris, prefer the Apache-2.0
  variants.
- **Variants / input resolution** ([RF-DETR GitHub][rfdetr-gh]): Nano 384², Small
  512², Medium 576², Large 704², XL 700², 2XL 880². Resolution is **per-variant**
  and (unlike YOLO) **not 640** — the `CoreMLDetector` must carry the model's
  own input size.
- **Export: ONNX is native; Core ML is NOT.** `model.export()` supports **ONNX**
  (default, `opset_version=17`), **TFLite**, and **TensorRT** — **CoreML is not a
  documented `format`** ([RF-DETR export docs][rfdetr-export]). The route to Iris
  is therefore **PyTorch → ONNX → coremltools** (or PyTorch→`ct.convert(torch...)`
  directly), both manual.
  ```python
  from rfdetr import RFDETRMedium
  RFDETRMedium(pretrain_weights="checkpoint.pth").export()  # -> inference_model.onnx
  ```
- **Conversion pain — real and unresolved.** The dedicated tracking issue
  ([rf-detr#318 "Explicit CoreML Conversion Pipeline"][rfdetr-318]) is **open**:
  both direct-from-PyTorch and ONNX-intermediary attempts failed, the primary
  blocker being **bicubic upsampling having no direct PyTorch→Core ML
  conversion**, plus "a number of other incompatibilities." Roboflow apparently
  runs a working conversion internally but has **not published it**. Related
  threads ([rf-detr#473][rfdetr-473], [#376][rfdetr-376]) cover ONNX dynamic
  batching, not Core ML. There is a community ONNX project
  ([PierreMarieCurie/rf-detr-onnx][rfdetr-onnx]) and C++ ONNX-Runtime inference
  ([olibartfast][rfdetr-cpp]), but **no published, working `.mlpackage` path.**
- **Raw output tensors & decode (path B, NMS-free).** The ONNX export emits two
  tensors: **`dets`** shape `1 × Q × 4` (boxes) and **`labels`** shape
  `1 × Q × C` (per-class logits), with **Q ≈ 300** queries
  ([opendetect RF-DETR notes][opendetect]; [rf-detr-cpp][rfdetr-cpp]). Decode is
  the standard DETR set-prediction pipeline — **no NMS**:
  1. `probs = sigmoid(labels)` (sigmoid, **not** softmax — and the index-0
     background class is suppressed),
  2. flatten to `Q*C` and take the top-`k` scores (`argpartition`/top-k), where
     `query = i // C`, `class = i % C`,
  3. convert the selected boxes **cxcywh → xyxy**, normalized `[0,1]`.
  ([opendetect][opendetect]; the same flatten-top-k logic appears across DETR
  ports.) 👀 The exact box normalization convention (already `[0,1]` cxcywh vs.
  pixel) and ImageNet mean/std preprocessing should be read off the ONNX graph /
  `rfdetr` source at implementation time — primary docs don't state them plainly.
- **Verdict: needs-work, leaning blocked-unknown for a *clean* path.** ONNX
  export is reliable; the **ONNX→Core ML leg is the risk** (unsupported ops,
  transformer/attention patterns, dynamic shapes). Feasible outcomes, in
  likelihood order: (i) fix/replace the bicubic upsample op (swap to a
  Core ML-expressible resize, or register a coremltools composite op) and convert
  with `minimum_deployment_target=ct.target.iOS18`+; (ii) accept a raw-tensor
  Core ML model (path B) and decode in Swift; (iii) blocked until Roboflow
  publishes their pipeline. **Always lands on path (B)** regardless — RF-DETR has
  no Vision-auto-decode story.

---

## Inspecting a converted `.mlpackage` without running inference

Confirm the decode path *before* writing any Swift, using coremltools offline
([coremltools MLModel utilities][ct-utils]):

```python
import coremltools as ct
spec = ct.models.MLModel("yolo12s.mlpackage").get_spec()
for o in spec.description.output:
    print(o.name, o.type.WhichOneof("Type"))   # 'coordinates'/'confidence' ⇒ path A; a multiArrayType ⇒ path B
for i in spec.description.input:
    print(i.name, i.type)                       # imageType (fixed W×H) vs multiArrayType
print(dict(spec.description.metadata.userDefinedMetadata))  # class names, imgsz, task
```

- **Path-A tell:** two outputs named `coordinates` + `confidence` and a
  `pipeline`/NMS stage ⇒ Vision auto-decodes.
- **Path-B tell:** a single `multiArrayType` output ⇒ Swift decoder required.
- **Labels:** Ultralytics writes the `names` map into `userDefinedMetadata`;
  Create ML-style classifiers expose `spec.description.metadata` /
  `classLabels`. **Netron** ([netron.app]) gives the same picture visually — drag
  in the `.mlpackage`/`.mlmodel` and read input/output shapes and the pipeline
  graph.

---

## Key tradeoffs

- **NMS-in-model vs. NMS-in-Swift.** In-model (YOLO `nms=True`) = zero Swift
  decode, Vision returns finished detections, but the IoU/confidence thresholds
  are **baked at export time** (re-export to change them). In-Swift = full
  runtime control over thresholds (good for a `TunableDetector`'s knobs) but you
  own the NMS/box-decode code and its correctness. For Iris's tuning story,
  baked-in thresholds are a real constraint to weigh.
- **Vision-auto-decode (A) vs. custom decoder (B).** (A) is dramatically less
  code and less risk, and reuses Vision's coordinate handling that Iris already
  trusts. (B) is unavoidable for RF-DETR and for any YOLO exported without `nms`;
  it's also the only path that exposes raw scores for custom thresholding. The
  architecture should make (A) the easy default and (B) a pluggable seam, not a
  fork of the whole detector.
- **Bundled vs. file-picker model loading.** Small models (YOLO26n/s ≈ a few MB
  FP16) bundle into the app and ship via Git LFS (`.gitignore` already excludes
  compiled `.mlmodelc`; LFS already tracks `*.mlpackage`/`*.mlmodel` per
  `CLAUDE.md`). Large ones (RF-DETR L, YOLO*x*) or user-supplied models argue for
  a **file-picker / on-demand** load with `availability == .modelNotReady` until
  present — which the `Detector` protocol already models.
- **Fixed input size is a coordinate-correctness hazard.** Every one of these
  models has a **fixed** input resolution (YOLO 640; RF-DETR per-variant). The
  detector must pin the matching Vision crop-and-scale option, or boxes drift.
  This belongs in the catalog entry / detector config, not hardcoded.

## Open threads

- 👀 Exact Swift value-type observation name for auto-decoded detection under the
  iOS/macOS 26 `CoreMLRequest` API (vs. legacy `VNRecognizedObjectObservation`).
- 👀 Whether YOLO26's `nms=True` export appends a real NMS stage or just the
  output-formatting split for its already-NMS-free one-to-one head — confirm by
  inspecting the exported spec.
- 👀 RF-DETR's exact box normalization + preprocessing constants, and whether the
  bicubic-upsample op can be made Core ML-expressible without retraining.
- Whether to expose model thresholds as `TunableDetector` knobs (forces path B or
  re-export) — a `CoreMLDetector` design question for RECOMMENDATIONS / a future
  DECISIONS entry.

---

## Sources (accessed 2026-05-25)

- Ultralytics YOLO12 docs — [docs.ultralytics.com/models/yolo12][yolo12]
- Ultralytics YOLO26 docs — [docs.ultralytics.com/models/yolo26][yolo26]
- Ultralytics YOLO26 blog — [ultralytics.com/blog/...yolo26...][yolo26-blog]
- YOLO26 arXiv 2509.25164 — [arxiv.org/abs/2509.25164][yolo26-arxiv]
- Ultralytics Core ML integration — [docs.ultralytics.com/integrations/coreml][coreml-int]
- Ultralytics exporter source (via context7) — [docs.ultralytics.com/reference/engine/exporter][exporter]
- YOLOv12 paper — [arxiv.org/html/2502.12524v1][yolov12-paper]
- Roboflow best-models survey — [blog.roboflow.com/best-object-detection-models][roboflow-survey]
- RF-DETR GitHub (license, variants) — [github.com/roboflow/rf-detr][rfdetr-gh]
- RF-DETR export docs — [rfdetr.roboflow.com/latest/learn/export][rfdetr-export]
- RF-DETR Core ML issue #318 — [github.com/roboflow/rf-detr/issues/318][rfdetr-318]
- RF-DETR ONNX export issues #473 / #376 — [#473][rfdetr-473] · [#376][rfdetr-376]
- Community RF-DETR ONNX — [github.com/PierreMarieCurie/rf-detr-onnx][rfdetr-onnx]
- RF-DETR C++ ONNX inference (output tensors) — [github.com/olibartfast/rf-detr-cpp-inference][rfdetr-cpp]
- RF-DETR decode notes — [deepwiki opendetect 5.2-rf-detr][opendetect]
- Apple `VNRecognizedObjectObservation` — [developer.apple.com/.../vnrecognizedobjectobservation][vnobj]
- Apple `CoreMLRequest` (Vision, iOS/macOS 26) — [developer.apple.com/.../coremlrequest][coremlrequest]
- Apple `CoreMLFeatureValueObservation` — [developer.apple.com/.../coremlfeaturevalueobservation][cmlfvo]
- Apple Turi Create → Core ML (NMS pipeline contract) — [apple.github.io/turicreate/...export-coreml][turi]
- ultralytics/yolov5#1575 (feature-value vs recognized-object) — [github.com/ultralytics/yolov5/issues/1575][yolov5-1575]
- machinethink "How to display Vision bounding boxes" (letterbox trap) — [machinethink.net/blog/bounding-boxes][machinethink]
- coremltools MLModel utilities — [apple.github.io/coremltools/...mlmodel-utilities][ct-utils]
- Netron — [netron.app]

[yolo12]: https://docs.ultralytics.com/models/yolo12/
[yolo26]: https://docs.ultralytics.com/models/yolo26/
[yolo26-blog]: https://www.ultralytics.com/blog/ultralytics-yolo26-the-new-standard-for-edge-first-vision-ai
[yolo26-arxiv]: https://arxiv.org/abs/2509.25164
[coreml-int]: https://docs.ultralytics.com/integrations/coreml/
[exporter]: https://docs.ultralytics.com/reference/engine/exporter/
[yolov12-paper]: https://arxiv.org/html/2502.12524v1
[roboflow-survey]: https://blog.roboflow.com/best-object-detection-models/
[rfdetr-gh]: https://github.com/roboflow/rf-detr
[rfdetr-export]: https://rfdetr.roboflow.com/latest/learn/export/
[rfdetr-318]: https://github.com/roboflow/rf-detr/issues/318
[rfdetr-coreml-fork]: https://github.com/landchenxuan/rf-detr-to-coreml
[rfdetr-timnielen]: https://github.com/timnielen/rf-detr
[rfdetr-473]: https://github.com/roboflow/rf-detr/issues/473
[rfdetr-376]: https://github.com/roboflow/rf-detr/issues/376
[rfdetr-onnx]: https://github.com/PierreMarieCurie/rf-detr-onnx
[rfdetr-cpp]: https://github.com/olibartfast/rf-detr-cpp-inference
[opendetect]: https://deepwiki.com/saifkhichi96/opendetect/5.2-rf-detr
[vnobj]: https://developer.apple.com/documentation/vision/vnrecognizedobjectobservation
[coremlrequest]: https://developer.apple.com/documentation/vision/coremlrequest
[cmlfvo]: https://developer.apple.com/documentation/vision/coremlfeaturevalueobservation
[turi]: https://apple.github.io/turicreate/docs/userguide/object_detection/export-coreml.html
[yolov5-1575]: https://github.com/ultralytics/yolov5/issues/1575
[machinethink]: https://machinethink.net/blog/bounding-boxes/
[ct-utils]: https://apple.github.io/coremltools/docs-guides/source/mlmodel-utilities.html
[netron.app]: https://netron.app/
