# Recommendations: external PyTorch detectors → Core ML for Iris

Feeds a future [`plans/DECISIONS.md`](../../plans/DECISIONS.md) entry and the M6
Core ML detector work. Findings & sources:
[`SYNTHESIS.md`](./SYNTHESIS.md). Reusable procedure:
[`tools/model-export/RUNBOOK.md`](../../tools/model-export/RUNBOOK.md).

> ⚠️ **The original headline below ("start with YOLO26") was corrected by an
> empirical run.** Read the Update section first — it is authoritative; the
> original recommendation is preserved as the doc-only record.

## Update — 2026-05-25 (empirical recheck)

An actual export (**ultralytics 8.4.54, coremltools 9.0, Apple M1 Max**) corrected
the doc-only findings (full detail in [SYNTHESIS §"Update"](./SYNTHESIS.md)). The
headline recommendation changes accordingly.

**Corrected recommendation — start with YOLOv12, not YOLO26:**

- **Start with Ultralytics YOLOv12** (and other classic Detect models) — it is the
  **true zero-decode PATH A**: `yolo export … nms=True` yields a `pipeline` ending
  in `nonMaximumSuppression`, outputs `coordinates`+`confidence`, COCO labels in
  the NMS stage. Vision auto-decodes; `CoreMLDetector` is a thin adapter using
  `VisionObjectDecoder`. (`nms` defaults to **false** — a bare export is PATH B.)
- **YOLO26 is NOT path A.** ultralytics **forces `nms=False` on end2end models**
  (warns *"'nms=True' is not available for end2end models"*), so YOLO26 always
  exports as a raw **`[1,300,6]`** tensor (PATH B). It needs a **trivial
  end2end decoder** — threshold + scale the ≤300 rows, **no NMS** (the one-to-one
  head self-dedupes). Labels in `userDefined` `names`.
- **Therefore `CoreMLDetector` wants a pluggable `OutputDecoder`** =
  **`VisionObjectDecoder`** (PATH A, YOLOv12 + any `nms=True` Detect export) **+ a
  small YOLO-end2end decoder** (PATH B, YOLO26 `[1,300,6]`, no NMS). The
  `DETRSetPredictionDecoder` (RF-DETR) remains a later additive plug-in. The seam
  in §2 below already accommodates all three — only the *first* decoder to ship
  changes (still `VisionObjectDecoder` for the YOLOv12 path).
- **RF-DETR verdict updated:** the proven route is the community **direct
  PyTorch→Core ML** patched forks ([`landchenxuan/rf-detr-to-coreml`][rfdetr-coreml-fork]
  on [`timnielen/rf-detr`][rfdetr-timnielen]), **FP32-only**, **not**
  ONNX→coremltools. `rfdetr` exports ONNX/TFLite only; Roboflow won't add Core ML
  (issue #318 closed). Still **off the M6 critical path**; still PATH B needing a
  Swift DETR set-prediction decoder.

What follows is the original doc-only recommendation, kept as the record. Where it
says "start with YOLO26" / "both via path A" / "YOLO26 nms=True nuance", read the
correction above.

## Recommendation (original — doc-only, superseded by the Update above)

### 1. Start with **Ultralytics YOLO26** (then YOLOv12) — both via path (A)

Wire `CoreMLDetector` against **YOLO26** first. It is a real, current Ultralytics
release (verified — see SYNTHESIS §2), exports to Core ML with a **one-line
command**, and with `nms=True` produces a Vision-auto-decodable object-detector
pipeline:

```python
from ultralytics import YOLO
YOLO("yolo26s.pt").export(format="coreml", nms=True, imgsz=640, half=True)
```

This means **zero custom decode in Swift** — Vision returns
`RecognizedObjectObservation`s (box + label + confidence, normalized, bottom-left
origin, which is already Iris's convention) — so the *first* `CoreMLDetector` is a
thin adapter and the milestone proves end-to-end Core ML in Iris with minimal
risk. **YOLOv12** is the same code path (also path A via `nms=True`); ship it as
the second variant to demonstrate multiple sizes/models through one detector.
Differences that matter to Iris are nil at the Swift layer — both yield the same
observation type. (v12 needs NMS internally, 26 is natively NMS-free; the export
flag normalizes both to path A.)

**Why not RF-DETR first:** it's path (B) *and* has an unverified Core ML
conversion (see §3). Leading with it would couple "does Iris's Core ML detector
work at all?" to "can we even convert this transformer?" — two risks in one. Land
the clean YOLO path first; it de-risks the whole `CoreMLDetector` surface.

### 2. `CoreMLDetector` shape: one detector, a pluggable `OutputDecoder` seam

Model the two decode paths as one detector with a swappable decoder, not two
detectors:

```swift
// Sketch — not final. Lives in Sources/Iris/Detection/CoreML/ (M6).
public protocol OutputDecoder: Sendable {
    /// Decode Vision's observations for one frame into Iris detections.
    /// `frameSize` lets a raw-tensor decoder un-normalize / letterbox-correct.
    func decode(_ observations: [any VisionObservation],
                frameSize: CGSize,
                modelID: String) throws -> [Detection]
}

public struct CoreMLDetector<Decoder: OutputDecoder>: Detector {
    let model: MLModel              // compiled .mlmodelc, loaded with MLModelConfiguration.computeUnits
    let inputSize: CGSize           // model-fixed (YOLO 640²; RF-DETR per-variant) — pins crop/scale
    let cropAndScale: ...           // aspect-preserving scale-to-fit to match training (letterbox)
    let decoder: Decoder
    public var availability: DetectorAvailability   // .modelNotReady until the .mlmodelc is present
    public let modelIdentifier: String
    func detect(in frame: Frame) async throws -> [Detection] { /* CoreMLRequest → decoder.decode(...) */ }
}
```

Two concrete decoders cover everything found:

- **`VisionObjectDecoder`** — path (A). Reads `boundingBox` + best label +
  `confidence` off each `RecognizedObjectObservation`. **One implementation reused
  by every `nms=True` YOLO export**, any size, any class set. This is the
  default and the only decoder M6 needs to ship to light up YOLO26 + YOLOv12.
- **`DETRSetPredictionDecoder`** — path (B), deferred until RF-DETR is unblocked.
  Reads the raw `dets` (`1×Q×4`) + `labels` (`1×Q×C`) `MLMultiArray`s from
  `CoreMLFeatureValueObservation`, applies **sigmoid → flatten top-k →
  cxcywh→xyxy** (no NMS), un-normalizes against `frameSize`. A second
  path-(B) decoder for *raw YOLO* (`nms=False`) — threshold → cxcywh→xyxy → NMS —
  is straightforward to add later if runtime-tunable thresholds are wanted, but
  is **not** needed while we use `nms=True`.

The seam keeps (A) the trivial default and (B) an additive plug-in, so RF-DETR
(or a custom raw model) slots in without reshaping the detector or touching the
YOLO path.

### 3. RF-DETR: **needs-work, treat as blocked-unknown for a clean `.mlpackage`**

Honest verdict (SYNTHESIS §3): ONNX export is reliable, but the **ONNX→Core ML
leg is unproven in public** — the official "Explicit CoreML Conversion Pipeline"
issue is **open**, blocked on **bicubic upsampling** (no direct PyTorch→Core ML
op) plus other transformer-op incompatibilities, and Roboflow has not published
their internal converter. **Do not commit RF-DETR to an M6 milestone scope as if
it's a known quantity.** Instead:

1. Spike it in isolation under [`tools/model-export/`](../../tools/model-export/)
   following the RUNBOOK RF-DETR recipe — export ONNX, attempt `ct.convert`, and
   see exactly which ops fail on the **Nano (384²)** Apache-2.0 variant.
2. If conversion succeeds (op fixed/replaced) → it's a **path-(B)** model;
   implement `DETRSetPredictionDecoder` against the inspected output spec.
3. If it stays blocked → log it, ship YOLO, revisit when Roboflow publishes or
   coremltools gains the op. Iris loses nothing; the seam is already there.

Prefer the **Apache-2.0** variants (Nano/Small/Medium/Large + all seg); XL/2XL
are **PML-1.0** — a licensing gate before any app ships them.

### 4. Verify every model offline before writing Swift

Make `ct.models.MLModel(path).get_spec()` (or Netron) a **required RUNBOOK step**:
confirm output names (`coordinates`+`confidence` ⇒ path A; a `multiArrayType` ⇒
path B), the fixed input W×H, and that class labels are in `userDefinedMetadata`.
This pins the decode path as a *fact about the artifact*, not an assumption, and
is what catches a bad export before it becomes a misaligned-box bug at runtime.

### 5. Pin input size + crop/scale per model; bundle small, file-pick large

- Carry each model's **fixed input resolution** and an **aspect-preserving
  scale-to-fit** crop option in the catalog/detector config — never hardcode 640
  (RF-DETR isn't 640). A mismatched crop/scale silently corrupts boxes.
- Bundle small FP16 models (YOLO26 n/s) via Git LFS (already tracks
  `*.mlpackage`/`*.mlmodel`); load via Core ML at launch and `prewarm()`. Gate
  large/optional models behind `.modelNotReady` + a file picker.
- Add models through `DetectorCatalog` exactly like the built-in Vision entries
  ([`DetectorCatalog.builtInVision`](../../Sources/Iris/Tuning/DetectorCatalog.swift)) —
  one `DetectorCatalogEntry` per model, factory builds the `CoreMLDetector`.

## Why

The decode fork (SYNTHESIS) is the whole game, and it's decided by the *exported
artifact*, not by Swift. YOLO's `nms=True` lands the artifact on the cheap,
low-risk Vision-auto-decode path — so the right first move is the one that makes
`CoreMLDetector` a thin adapter and proves Core ML works in Iris before taking on
any transformer-conversion risk. The `OutputDecoder` seam costs almost nothing
now and is exactly the boundary that lets RF-DETR (the genuinely hard, path-B,
maybe-blocked model) arrive later without reshaping anything. Verifying with
`get_spec()`/Netron turns "which path is this?" from a guess into a checked fact,
heading off the misaligned-box class of bugs that dogs every YOLO↔Vision
integration.

## Caveats

- **`nms=True` bakes IoU/conf thresholds at export time.** If Iris wants
  *runtime-tunable* detection thresholds for a Core ML `TunableDetector`, that
  forces path (B) (raw tensor + Swift NMS) or a re-export per threshold set.
  Decide this when designing `CoreMLDetector`'s capabilities — it changes which
  decoder the YOLO entries use.
- 👀 **iOS/macOS 26 Swift Vision API:** the exact value-type observation name for
  auto-decoded detection (vs. legacy `VNRecognizedObjectObservation`) needs
  confirming against the installed 26 SDK at implementation time. The auto-decode
  *rule* (model output spec, not request type) is solid.
- 👀 **YOLO26 `nms=True` nuance:** for its already-NMS-free one-to-one head, the
  appended stage may be output-formatting more than suppression — confirm by
  inspecting the exported spec; not a blocker for path (A).
- 👀 **RF-DETR specifics** (box normalization, ImageNet preprocessing constants,
  whether bicubic-upsample is fixable without retraining) are unverified against
  primary docs — read them off the ONNX graph / `rfdetr` source during the spike.
- **Conversion tooling is Python and lives outside the Swift package**
  (`tools/model-export/`, `uv`-managed). It never becomes a SwiftPM dependency.

[rfdetr-coreml-fork]: https://github.com/landchenxuan/rf-detr-to-coreml
[rfdetr-timnielen]: https://github.com/timnielen/rf-detr
