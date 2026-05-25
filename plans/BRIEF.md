# Iris — Project Brief

A Swift package for building camera + ML vision apps on Apple platforms. Handles
the recurring plumbing — capture, playback, ML inference, overlays, dataset
capture — so individual projects can focus on their specific detection problem.

## Why

Every new vision project repeats the same scaffolding: AVFoundation capture,
preview layers, frame extraction, Vision/Core ML inference, drawing bounding
boxes, swapping models, tuning thresholds. Iris is the shared foundation so new
projects start with the boring parts done.

## Platforms & baseline

- **iOS 26 / iPadOS 26** — full feature set (capture + playback + inference + dataset).
- **macOS 26** — playback, inference, overlay, dataset capture. **No camera capture
  on macOS** (different AVFoundation surface, lower priority for personal use).
  Treating macOS primarily as a *model evaluation and dataset curation* target.
- **Swift 6 language mode on**, strict concurrency from day one. Easier to get
  capture → inference → render handoffs right with the checker helping than
  fighting data races after the fact.
- **SwiftUI-first.** UIKit / AVFoundation lives behind `UIViewRepresentable` and
  protocol boundaries.

### Why iOS 26 / macOS 26 specifically

- **New Vision Swift API** (iOS 18+, matured in 26): native `async/await`,
  Sendable, no more `VN`-prefixed Obj-C bridge. Maps directly onto an
  `AsyncStream<Frame>` pipeline. This alone justifies the floor.
- **Foundation Models framework** (iOS 26): on-device LLM access. Enables scene
  captioning and VLM-style detection alongside classical object detection.
- **`@Observable` everywhere** (iOS 17+, UIKit parity in 26): clean reactive
  bindings for tuning state with no `ObservableObject` boilerplate.
- **Swift 6.2 concurrency defaults**: optional per-module default actor isolation.
- **Improved Vision hand pose model** (iOS 26): better accuracy, lower latency,
  less memory.

## Core use cases

1. **Live capture with real-time overlays** — point the camera, run a model, see
   detections drawn on top.
2. **Recorded playback with the same overlays** — scrub through captured video,
   run inference per frame, see results. Works on Mac too.
3. **Dataset capture loop** — when the model gets something wrong (false
   positive, missed detection, weak confidence), grab that frame and route it to
   a labeled dataset folder for retraining.
4. **Live experimentation** — change confidence thresholds, toggle class
   filters, switch models on the fly, see the effect immediately.
5. **Model swapping** — start with Apple's built-in detectors (Vision: object,
   body, hand, face), graduate to custom Core ML models, A/B compare.
6. **VLM-style captioning** (stretch) — use Foundation Models to caption a frame
   or describe what's in a detection box.

## Design principles

- **SwiftUI-native API surface.** UIKit / AVFoundation behind boundaries.
- **Same overlay pipeline for live and playback.** A `Frame` is a `Frame` — the
  source (camera vs. AVPlayer / AVAssetReader) shouldn't matter to the model or
  the renderer.
- **Models are pluggable.** A `Detector` protocol with a uniform `Detection`
  output type. Apple Vision, Core ML, and Foundation Models all implement it.
- **Tuning is first-class.** Confidence thresholds, class filters, NMS settings
  are runtime-adjustable with `@Observable` bindings.
- **Dataset capture is one tap.** Any frame in any view can be sent to a labeled
  folder with a single call.
- **`async/await` end to end.** No completion handlers, no Combine unless
  there's a concrete reason.

## High-level components

Iris ships as a **single SwiftPM target** (`Iris`) with one umbrella library
product. The components below are folders under `Sources/Iris/` — conceptual
responsibilities, not separate modules. They share `Frame`, `Detector`, and
coordinate-space conventions and co-evolve through M1–M3. `Tuning` (M4) and
`Dataset` (M5) are scaffolded only when the work begins.

### 1. `IrisCapture` — camera session *(iOS only)*

- AVCaptureSession wrapper; device, format, orientation handling.
- `CameraPreview: View` (SwiftUI).
- Publishes `AsyncStream<Frame>` of CVPixelBuffers + timestamps + metadata.
- Recording to disk (mov/mp4) with optional sidecar metadata.

### 2. `IrisPlayback` — recorded video as a frame source *(iOS + macOS)*

- AVAssetReader-backed, exposes the same `AsyncStream<Frame>` API as capture.
- Frame-accurate seeking, scrubber view, play/pause/step-frame controls.
- This is the primary entry point on macOS.

### 3. `IrisDetection` — model abstraction *(iOS + macOS)*

```swift
protocol Detector: Sendable {
    func detect(_ frame: Frame) async throws -> [Detection]
}
```

- `Detection`: bounding box, label, confidence, optional keypoints/mask, source
  model ID.
- Built-in adapters:
  - Vision (new Swift API): `DetectHumanBodyPoseRequest`,
    `RecognizeObjectsRequest`, etc.
  - Core ML: generic `MLModel` wrapper with pluggable output decoders
    (YOLO-style, classification, segmentation).
  - Foundation Models (iOS/macOS 26): scene/region captioning as a `Detector` or
    a related `Captioner` protocol.
- `DetectorPipeline` — chain and/or parallelize multiple detectors per frame.

### 4. `IrisOverlay` — rendering *(iOS + macOS)*

- SwiftUI views that take `[Detection]` and draw boxes, labels, keypoints, masks.
- Coordinate-space conversion (Vision normalized → view coords, accounting for
  rotation and mirroring) handled once, correctly.
- Customizable styling: per-class colors, label format, stroke width.

### 5. `IrisTuning` — live filter / threshold controls *(iOS + macOS)*

- `DetectionFilter`: confidence threshold, class allowlist / blocklist, NMS,
  min box size.
- `@Observable` so SwiftUI controls bind directly.
- Snapshot / restore presets.
- "What if?" mode: show detections that *would* pass at a lower threshold, in a
  different style — useful for finding near-misses worth retraining on.

### 6. `IrisDataset` — capture frames for retraining *(iOS + macOS)*

- `DatasetSink` protocol: folder on disk, iCloud, S3, etc.
- `capture(frame:detections:label:reason:)` — saves image + JSON sidecar
  (detections, threshold at time of capture, model ID, timestamp, user notes).
- Built-in "this was wrong" and "this was a near-miss" affordances.
- Folder layout compatible with common training formats — COCO-style JSON as
  canonical, exporters convert to YOLO / Pascal VOC.

## Architecture

Locked architectural verdicts — package shape, frame pipeline, display pipeline,
isolation model, protocol shapes — live in [`DECISIONS.md`](./DECISIONS.md) with
one-line entries pointing at the exploration that produced each. Prior-art reads
in two arcs informed those decisions:
[`../explorations/prior-projects/`](../explorations/prior-projects/) (in-house)
and [`../explorations/swift-ecosystem/`](../explorations/swift-ecosystem/)
(external Swift packages). Open questions live in
[`QUESTIONS.md`](./QUESTIONS.md).

## Milestone path

- **M1 — Capture core.** `IrisCapture` + `CameraPreview` SwiftUI view + frame
  stream. Smoke test: render preview, log frame timestamps. iOS only.
- **M2 — Detection + overlay.** `IrisDetection` with a Vision adapter (body
  pose or object detection). `IrisOverlay` drawing boxes. End-to-end live demo
  on iOS.
- **M3 — Playback.** `IrisPlayback` with the same `Frame` stream interface. Same
  overlay code works on recorded video. **First macOS target lands here** —
  playback + detection + overlay on Mac.
- **M4 — Tuning.** `IrisTuning` — confidence slider, class filter, NMS controls
  bound via `@Observable`. "What if" mode for near-misses.
- **M5 — Honest detectors.** Capability model every built-in Vision detector
  declares, driving derived per-detector tuning UI and capability-honest overlays —
  render only what the model knows; ratios not percentages. Audits the built-in
  Vision request surface; proves the model on reworked rectangles + a human
  body-pose skeleton. Adds a raw-data inspector panel exposing the literal fields
  each detection returns. See [`features/M5-honest-detectors.md`](./features/M5-honest-detectors.md).
- **M6 — Custom models + captioning.** Core ML adapter with YOLO-style output
  decoder. Model swap UI. Foundation Models captioning integration.
- **M7 — Dataset.** `IrisDataset` — one-tap capture of frame + metadata to disk,
  COCO sidecar. Works from both live and playback contexts.
