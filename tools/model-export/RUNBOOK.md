# Model Export Runbook — external PyTorch detector → Core ML → Iris

The durable, reusable procedure for converting **any** external object-detection
model into a Core ML `.mlpackage` and bringing it into Iris as a `CoreMLDetector`.
Background, per-model feasibility, and sources:
[`explorations/2026-05-25-coreml-model-conversion/SYNTHESIS.md`](../../explorations/2026-05-25-coreml-model-conversion/SYNTHESIS.md).
Design rationale (decode paths, detector shape):
[`.../RECOMMENDATIONS.md`](../../explorations/2026-05-25-coreml-model-conversion/RECOMMENDATIONS.md).

> **Verified.** The YOLO recipe here was **run in this repo** (ultralytics
> 8.4.54, coremltools 9.0, Apple M1 Max). `yolo export model=… format=coreml`
> is the same code path as `YOLO(…).export(format='coreml')` — the CLI is just an
> arg-parser. The RF-DETR recipe (§c2) is a **spike, not a one-liner**: `rfdetr`
> exports ONNX/TFLite only (no native Core ML); the proven Core ML route is a
> community **direct PyTorch→Core ML** patched fork (FP32-only), off the critical
> path. Treat every export as "run once, then verify the artifact" — never assume
> the output type, **check it** (step 3, `inspect_model.py`).

> **The decode fork — the one thing to internalize.** Apple Vision auto-decodes a
> Core ML model into ready-made `RecognizedObjectObservation`s **only** when the
> exported model is a pipeline ending in a `NonMaximumSuppression` stage with
> `coordinates` + `confidence` outputs ("**path A**"). Anything else comes back as
> a raw `MLMultiArray` you decode in Swift ("**path B**"). The export choices
> below decide which path you get; step 3 confirms it.

---

## (a) Environment — CLI-first, ephemeral by default

Conversion tooling is **Python, separate from the Swift package** — it never
becomes a SwiftPM dependency. It is **CLI-first**: `yolo export …` is the verb,
and `yolo export`/`yolo predict` **auto-download** the `*.pt` weights on first
use. (There is **no `yolo download` command** — it errors.)

### Blessed default — pinned ephemeral (no persistent project)

Run the whole export with one `uv run --with …` invocation — nothing is
installed into a project:

```bash
uv run --python 3.12 --with ultralytics --with "coremltools>=9.0" --with "numpy<=2.3.5" \
  yolo export model=yolo11n.pt format=coreml nms=True imgsz=640 half=True
```

**The two pins are load-bearing — do not drop them:**
- `--python 3.12` — a naive `uv run --with ultralytics …` resolves **Python
  3.14**, which pulls a numpy that **crashes coremltools**.
- `--with "numpy<=2.3.5"` — `coremltools>=9.0` needs numpy `<=2.3.5`; the
  unpinned resolution lands on a numpy that breaks export.

Cost: **~83 s cold** (downloads the wheels into uv's cache), then **cache-warm**
on subsequent runs. **No persistent footprint** — nothing under
`tools/model-export/` grows.

### Repeat-exports option — persistent `.venv`

A pinned project venv already lives at `tools/model-export/.venv` (**984 MB**,
torch is already CPU-only). It exports in **~2 s warm**, no resolution step:

```bash
# from tools/model-export/
uv run yolo export model=yolo11n.pt format=coreml nms=True imgsz=640 half=True
```

**Tradeoff:** ephemeral = zero footprint, ~80 s cold / cache-warm after; venv =
984 MB on disk, ~2 s/export warm. If you don't expect repeat exports, go
pure-ephemeral: `rm -rf tools/model-export/.venv` and use the one-liner above.

Notes:
- **macOS or x86 Linux only** for Core ML export (not Windows) — Apple-Silicon
  Mac is fine and is this project's baseline. Verified on M1 Max.
- `coremltools>=9.0` + `numpy<=2.3.5` is the Ultralytics-pinned combination;
  mismatched numpy is the most common export breakage (it's what the two pins
  above guard against).
- **Artifacts live in [`data/models/`](../../data/models/)** — `weights/` for the
  `*.pt`, `coreml/` for the `*.mlpackage`. Both are gitignored (regenerable);
  the `data/models/README.md` is tracked. ultralytics writes the `.mlpackage`
  next to the source weights / in the CWD, so step (b)2 / §c1 move the outputs
  into place. Git LFS is configured **only for `Tests/IrisTests/Fixtures/`**
  (`.gitattributes`) — a `.mlpackage` that ships in the app bundle is committed
  under the app target, and the LFS attributes are extended to that path when the
  first real model lands (not done speculatively).

---

## (b) Generic step-by-step (any model)

### 1. Obtain weights
You usually **don't** fetch weights as a separate step — `yolo export`/`yolo
predict` **auto-download** `yolo*.pt` on first use (there is no `yolo download`
command). For non-ultralytics models, grab the checkpoint from its official
source (RF-DETR takes a `.pth`). Do **not** commit weights — they land in
`data/models/weights/`.

### 2. Export to Core ML — then move into `data/models/`
- If the framework has a **native Core ML exporter** (Ultralytics does), use the
  CLI with `nms=True` to get **path A** (§c1). ultralytics writes the
  `.mlpackage` next to the source weights / in the CWD.
- If not (RF-DETR), there is **no native Core ML export** — the proven route is a
  community **direct PyTorch→Core ML** patched fork, FP32-only and off the
  critical path (§c2). This is a spike, not a one-liner.
- Either way, **move the outputs into `data/models/`** so the CWD/tooling dir
  stays clean: the `*.pt` → `data/models/weights/`, the `*.mlpackage` →
  `data/models/coreml/`. §c1 gives the exact `mv` steps.

### 3. Inspect & verify the artifact — **mandatory, before any Swift**
Confirm the decode path, input shape, and labels offline. This turns "which path
is this?" into a checked fact and catches bad exports before they become
misaligned-box bugs. A corrected, working script already exists — **use it,
don't hand-roll**:

```bash
# ephemeral:
uv run --python 3.12 --with "coremltools>=9.0" --with "numpy<=2.3.5" \
  python inspect_model.py ../../data/models/coreml/yolo11n.mlpackage
# or, with the persistent venv:  uv run python inspect_model.py <path>
```

`inspect_model.py` prints inputs (image W×H vs multiArray shape), outputs,
top-level type, pipeline stages (including NMS `coordinatesOutputFeatureName` /
`confidenceOutputFeatureName` and `stringClassLabels`), and `userDefined`
metadata (`names`, `imgsz`, …). The **coremltools-9 API names** it uses (and that
prose elsewhere historically got wrong):
- load with `ct.models.MLModel(path, skip_model_load=True)` — `skip_model_load`
  avoids compiling the model just to read its spec.
- metadata map is `spec.description.metadata.userDefined` (**not**
  `userDefinedMetadata`).
- NMS output fields are `coordinatesOutputFeatureName` /
  `confidenceOutputFeatureName` (**not** `…OutputName`).

Decision:
- Outputs named **`coordinates` + `confidence`** and a top-level **`pipeline`**
  ending in `nonMaximumSuppression` ⇒ **path A** — Vision auto-decodes; use
  `VisionObjectDecoder`. (This is what a YOLO `nms=True` export yields — the
  expected PATH-A spec.) Labels live in the **NMS stage** `stringClassLabels`.
- A raw **`multiArrayType`** output (e.g. `[1,84,8400]` for raw YOLO, `[1,300,6]`
  for a YOLO26/end2end head) ⇒ **path B** — write/choose a Swift decoder. Labels
  live in **`userDefined` `names`**.
- Alternatively drag the `.mlpackage` into **Netron** (<https://netron.app>) to
  read the graph, input/output shapes, and pipeline stages visually.

### 4. Choose the decode path in Iris
- **Path A** → reuse `VisionObjectDecoder` (no per-model code). Done.
- **Path B** → pick/implement an `OutputDecoder` for the architecture (YOLO-raw:
  threshold → cxcywh→xyxy → NMS; DETR: sigmoid → top-k → cxcywh→xyxy, no NMS).
  See the decoder sketch in
  [RECOMMENDATIONS §2](../../explorations/2026-05-25-coreml-model-conversion/RECOMMENDATIONS.md).

### 5. Bring the `.mlpackage` into the app
- **Small** model → add to the app target's bundle; extend Git LFS to its path.
  Core ML compiles `.mlpackage` → `.mlmodelc` at build/first-load (`.mlmodelc` is
  gitignored).
- **Large / optional / user-supplied** → ship out-of-bundle and load on demand;
  the detector reports `availability == .modelNotReady` until the file is present.

### 6. Add a `DetectorCatalog` entry
Register the model exactly like the built-in Vision detectors in
[`DetectorCatalog.builtInVision`](../../Sources/Iris/Tuning/DetectorCatalog.swift) —
one `DetectorCatalogEntry` whose factory builds the `CoreMLDetector` (model URL +
decoder + the model's `modelIdentifier`).

### 7. Set input size + crop/scale option
Pin the model's **fixed input resolution** (from step 3) and an
**aspect-preserving scale-to-fit** (letterbox) crop/scale option on the detector
config. **Never hardcode 640** — RF-DETR variants are 384–880. A crop/scale that
doesn't match how the model was trained silently corrupts box coordinates.

---

## (c) Model-specific recipes

### c1. Ultralytics YOLO (v12 and other classic Detect models) — path A, **clean**

One CLI command. **`nms` defaults to `false`** — a bare `format=coreml` yields
**PATH B** (raw `[1,84,8400]` mlProgram, no NMS, Vision will **not** auto-decode).
You **must** pass `nms=True` to get the Vision-auto-decodable pipeline (PATH A).
Flag syntax is **space-separated `arg=value`** (no dashes, no commas):

```bash
# ephemeral (blessed default) — auto-downloads yolo11n.pt on first use:
uv run --python 3.12 --with ultralytics --with "coremltools>=9.0" --with "numpy<=2.3.5" \
  yolo export model=yolo11n.pt format=coreml nms=True imgsz=640 half=True

# or, with the persistent venv (from tools/model-export/):
uv run yolo export model=yolo11n.pt format=coreml nms=True imgsz=640 half=True
```

`yolo export model=X format=coreml` is the same code path as
`YOLO(X).export(format='coreml')` — the CLI is just an arg-parser. Swap the model
name for any size/version: `yolo12{n,s,m,l,x}.pt`, `yolo11{n,s,m,l,x}.pt`, etc.
(all 640×640). Key args:

| Arg | Default | Effect |
| --- | --- | --- |
| `nms` | **`False`** | **`True` ⇒ PATH A** (appends Apple `NonMaximumSuppression` pipeline → Vision auto-decode, `coordinates`+`confidence` outputs, 80 COCO labels in the NMS stage). Bare/`False` ⇒ raw `[1,84,8400]` tensor (PATH B). |
| `imgsz` | `640` | Fixed input size baked into the model. Must match the detector's crop/scale (step 7). |
| `half` | `False` | FP16 — smaller, ANE-friendly. Recommended for on-device. |
| `int8` | `False` | INT8 quantization (needs calibration data). |
| `dynamic` | `False` | Dynamic input size. **Cannot combine with `nms=True`**; `batch>1` requires it. |
| `batch` | `1` | >1 needs `dynamic=True`. Iris runs per-frame, so leave at 1. |

What you get with `nms=True` (verify in step 3): a top-level **`pipeline`** whose
final stage is `nonMaximumSuppression`, outputs `coordinates` (boxes) +
`confidence` (per-class), and **80 COCO labels baked into the NMS stage**
(`stringClassLabels`). Vision returns recognized-object observations directly —
**no Swift decode**. The IoU/confidence thresholds are **baked at export**
(`iou`/`conf` args); to change them at runtime you must re-export or drop to path B.

> **YOLO26 / any `end2end` model — `nms` is FORCED off ⇒ always PATH B.**
> ultralytics refuses NMS on end2end heads: passing `nms=True` warns *"'nms=True'
> is not available for end2end models"* and exports anyway with `nms=False`. You
> always get a raw **`[1,300,6]`** tensor. **Decode is trivial and needs NO NMS** —
> the one-to-one head self-dedupes; just threshold and scale the (up to) 300 rows
> `[x, y, w, h, conf, class]`. Labels live in **`userDefined` `names`**, not in an
> NMS stage. So a small YOLO-end2end decoder, not `VisionObjectDecoder`.

**Label location differs by path:** PATH A → NMS stage `stringClassLabels`;
PATH B → `userDefined` metadata `names`. Confirm in step 3.

Letterbox warning: the export declares a **fixed-size image input** with internal
`/255` scaling. Iris must feed it with **aspect-preserving scale-to-fit** (matching
YOLO's letterbox training); a plain stretch ("scaleFill") distorts boxes.

**Move outputs into `data/models/`.** ultralytics auto-downloads the weights and
writes the `.mlpackage` into the CWD (or next to the source weights). From wherever
you ran the command:

```bash
# from the repo root (adjust the source dir if you ran elsewhere):
mv yolo11n.pt        data/models/weights/
mv yolo11n.mlpackage data/models/coreml/
```

Both destinations are gitignored; the `.pt` is the regenerable source weight and
the `.mlpackage` is the Iris-ready model.

### c2. RF-DETR (Roboflow) — path B, **a spike, not a one-liner**

There is **no native Core ML path**, and the framing is *not* "ONNX→coremltools":

- The `rfdetr` package's `export()` does **ONLY `onnx` / `tflite`** — it
  **hard-raises** for anything else, including Core ML.
- Roboflow **won't add** Core ML: issue [roboflow/rf-detr#318][rfdetr-318] is
  **closed** — Core ML lives behind their hosted platform + `roboflow-swift`, not
  the OSS package.
- The **proven OSS route is a DIRECT PyTorch→Core ML** conversion via patched
  forks (runtime monkey-patches), **not** the ONNX intermediary:
  - [`landchenxuan/rf-detr-to-coreml`][rfdetr-coreml-fork] — RF-DETR v1.5.1
    detect + seg, runtime monkey-patches; builds on
  - [`timnielen/rf-detr`][rfdetr-timnielen] — deformable-attention rank-5 fix.
  - **FP32-only** — FP16 fails to compile.

This is **off the critical path** and is a **spike**, not a one-liner: clone the
fork, run its conversion against the **Nano (384²)** Apache-2.0 variant, then
inspect the artifact. Prefer the **Apache-2.0** variants (Nano 384² / Small 512² /
Medium 576² / Large 704² + all seg). **XL/2XL are PML-1.0** — licensing gate
before shipping.

Step 1 — get the patched fork and convert (direct PyTorch→Core ML, FP32):
follow the fork's README — it monkey-patches RF-DETR's forward pass at runtime and
calls `coremltools` on the traced torch model. Use the Nano checkpoint and keep
precision **FP32** (FP16 won't compile). Land the `.mlpackage` in
`data/models/coreml/`.

Step 2 — inspect (generic step 3). RF-DETR is **path B**: expect two
`multiArrayType` outputs — **`dets`** (`1 × Q × 4`, boxes) and **`labels`**
(`1 × Q × C`, per-class logits), with **Q ≈ 300** queries.

Step 3 — Swift decode (`DETRSetPredictionDecoder`, **no NMS** — set prediction):
1. `probs = sigmoid(labels)` (sigmoid, **not** softmax; suppress background class
   index 0),
2. flatten to `Q*C`, take top-k scores (`query = i // C`, `class = i % C`),
3. convert selected boxes **cxcywh → xyxy**, normalized `[0,1]`, then un-normalize
   against `frame.dimensions`.

👀 Confirm the exact box normalization (already `[0,1]` cxcywh vs. pixel) and the
ImageNet mean/std preprocessing off the fork / `rfdetr` source during the spike —
primary docs don't state them plainly.

[rfdetr-318]: https://github.com/roboflow/rf-detr/issues/318
[rfdetr-coreml-fork]: https://github.com/landchenxuan/rf-detr-to-coreml
[rfdetr-timnielen]: https://github.com/timnielen/rf-detr

---

## (d) "Adding the next model" checklist

Every future detector follows the same path. Tick these:

- [ ] **License OK** for the intended distribution (Apache-2.0 etc.; RF-DETR
      XL/2XL are PML-1.0).
- [ ] **Weights** — for ultralytics, none to fetch (`yolo export` auto-downloads
      on first use); otherwise grabbed from the official source. Not committed.
- [ ] **Exported via the CLI** to `.mlpackage` — `yolo export … nms=True` for
      classic Detect models (PATH A); for YOLO26/end2end, `nms` is forced off →
      PATH B `[1,300,6]`; for RF-DETR, the patched-fork direct PyTorch→Core ML
      spike (PATH B, FP32-only). Recorded the exact command. **Moved the `.pt` →
      `data/models/weights/`, the `.mlpackage` → `data/models/coreml/`.**
- [ ] **`inspect_model.py`-verified** (generic step 3): noted output type
      (`coordinates`+`confidence` pipeline ⇒ A; a `multiArrayType` ⇒ B), the
      **fixed input W×H**, and where the class **labels** are (PATH A → NMS stage
      `stringClassLabels`; PATH B → `userDefined` `names`).
- [ ] **Decode path chosen:** path A → `VisionObjectDecoder` (reuse); path B →
      the matching `OutputDecoder` (YOLO-raw / DETR / new), implemented + unit
      tested against a fixture per repo convention.
- [ ] **Input size + crop/scale** pinned on the detector config (no hardcoded
      640; aspect-preserving scale-to-fit).
- [ ] **`.mlpackage` placed** (bundled + LFS path extended, or file-picked with
      `.modelNotReady` gating).
- [ ] **`DetectorCatalog` entry** added with a stable `modelIdentifier`.
- [ ] **Fixture-based test** added in the same commit (untested adapters defeat
      the point of Iris — `CLAUDE.md` working norms).
