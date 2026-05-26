# Questions driving this exploration

Pre-M6 verification of the path that turns an external PyTorch object detector
into a Core ML `.mlpackage` that Iris can run through `Detector`. Feeds a future
`CoreMLDetector` design and the reusable
[`tools/model-export/RUNBOOK.md`](../../tools/model-export/RUNBOOK.md).

This is **verification + documentation** work — no weights were downloaded, no
conversion was run. Claims are checked against live official docs (cited in
[`SYNTHESIS.md`](./SYNTHESIS.md)); anything unverifiable is flagged 👀.

## Primary question

- For each model the user wants to hook up — **Roboflow RF-DETR**, **Ultralytics
  YOLOv12**, and **"YOLO26"** — what is the concrete path from PyTorch weights to
  an `.mlpackage`, and what does the converted model's **output** look like?
  Specifically, the decisive design fork:
  - **(A)** Does the export embed NMS / box-decode so Apple **Vision auto-decodes**
    the model and hands us `RecognizedObjectObservation`s (boxes + labels +
    confidence, free), or
  - **(B)** does the model emit a **raw `MLMultiArray`** tensor that Iris must
    decode in Swift (threshold → box-format convert → NMS for YOLO; sigmoid →
    top-k → cxcywh→xyxy, NMS-free for DETR)?

## Sub-questions

- **What triggers Vision's auto-decode?** What model metadata / output spec makes
  Vision return `RecognizedObjectObservation` vs. `CoreMLFeatureValueObservation`?
  Does the new iOS/macOS 26 `CoreMLRequest` Swift API behave the same as the
  legacy `VNCoreMLRequest` here?
- **Ultralytics YOLO → Core ML.** Exact `model.export(...)` command and the
  meaning of `nms`, `imgsz`, `half`, `int8`, `dynamic`. Does `nms=True` produce a
  Vision-auto-decodable detector or still a raw tensor? Default input size and
  letterboxing behavior — how does a size mismatch corrupt boxes? Available
  YOLOv12 sizes + resolutions. Where do class labels live? ANE / compute-unit
  notes.
- **Is "YOLO26" real?** As of mid-2025 / early-2026, is there an actual YOLO26
  release, or is this a typo for YOLO11 / the current flagship? If real: its
  export path, sizes, and how it differs from v12. *(Flagged-uncertainty item.)*
- **RF-DETR → Core ML — the high-risk one.** License, variants/sizes, input
  resolution. Native export? Is Core ML a direct target or only via
  PyTorch→ONNX→coremltools? Known conversion pain (transformer/attention ops,
  bicubic upsampling, dynamic shapes, NMS-free set-prediction decode). Raw output
  tensor shape and the exact Swift decode needed. Honest verdict: clean /
  needs-work / blocked-unknown.
- **Inspection without inference.** How to confirm a converted `.mlpackage`'s
  input shape, output type, and labels offline (`ct.models.MLModel(path).get_spec()`,
  Netron).
- **What `CoreMLDetector` shape does this imply?** One decoder or a pluggable
  `OutputDecoder` seam? Which model is the right *first* one to wire?
