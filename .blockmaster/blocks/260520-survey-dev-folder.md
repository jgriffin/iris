# survey-dev-folder — Survey ~/dev/ for camera / capture / detection prior art

parent: [m0-explorations](.blockmaster/blocks/260520-m0-explorations.md)
created: 2026-05-20 10:00
modified: 2026-05-20 (survey done; shortlist accepted)
context: .blockmaster/blocks/260520-survey-dev-folder.md
kind: research
goal: Produce a shortlist of projects in `~/dev/` that contain camera-capture, Vision / Core ML, or detection-pipeline code worth deep-reading for Iris.

### Context

Good prior art is spread across `~/dev/`. Before M1 code starts we want a fast, complete sweep that filters dozens of project folders down to a handful worth deep-reading. Output is a markdown shortlist in this block's Outcome that `review-prior-projects` consumes next.

### Approach

1. **Topology pass.** `tree -L 2 -d ~/dev/` (or `fd --max-depth 3 --type d . ~/dev/`) to see the project landscape. No exclusions agreed — full sweep.
2. **Signal greps per candidate top-level project.** Look for:
   - **Capture:** `AVCaptureSession`, `AVCaptureVideoDataOutput`, `CMSampleBuffer`, `AVCaptureDevice`
   - **Vision:** `Vision`, `VNDetect`, `VNCoreMLRequest`, `VNRecognizedObjectObservation`, `VNImageRequestHandler`
   - **Core ML:** `MLModel`, `import CoreML`, `.mlmodel`, `.mlmodelc`
   - **Playback / decode:** `AVAssetReader`, `AVPlayerItemVideoOutput`, `CVPixelBuffer`
   - **SwiftUI camera bridging:** `UIViewRepresentable.*Camera`, `CameraPreview`
3. **Filter.** Count hits per project; surface top candidates as a shortlist with: project path, primary signal, one-line "why this matters for Iris."

### Assets

- Shortlist lands in the **Outcome** section at close (small enough to live in this file).

### Pick-up-here

Run the tree walk + signal greps across `~/dev/`. Produce a shortlist in this file's Outcome — each entry: `path` · `signal hits` · `one-line read on relevance to Iris`. Done when shortlist is in Outcome and user has accepted or pruned it.

### Progress

- 2026-05-20 10:00 — created and opened
- 2026-05-20 — full sweep of `~/dev/` (24 top-level folders, 5 category folders recursed); 9 projects with signal hits; shortlist trimmed to top 5 high-value candidates

### Outcome

Deep-read shortlist for `review-prior-projects`, ordered by relevance (not raw hit count):

1. **`~/dev/PR/ios-videoCapture`** · cap:90 vis:2 play:25 · Modular SPM (CameraController / VideoPlayback / VideoOverlay / VideoEditing) — closest architectural mirror to Iris's package layout. **Highest priority** — pull patterns for module boundaries.
2. **`~/dev/PR/PRVisionSpike`** · cap:2 vis:52 ml:8 play:15 · End-to-end Vision pipeline (object / pose / contour / trajectory) + playback + overlay, actor-based async detection, YOLOv5 bundled. **Pipeline reference** — closest to the IrisDetection → IrisOverlay seam.
3. **`~/dev/ml/yolo-ios-app`** · cap:32 vis:43 ml:40 play:7 · Public Swift package, real-time Vision + CoreML, SwiftUI examples, model download/management. **Public-package craft reference** — how to expose Vision+CoreML cleanly through SwiftPM.
4. **`~/dev/ml/sportvision`** · vis:15 ml:14 play:22 · Modern stack (Swift 6, Tuist, iOS + macOS dual-target), playback + Vision on real content, YOLOv8 `.mlpackage`. **Swift 6 + macOS-parity reference** — concurrency patterns and dual-target shape.
5. **`~/dev/pocketRadar/BuildingAFeatureRichAppForSportsAnalysis`** · cap:21 vis:31 ml:4 play:4 · Apple reference sample, compact capture + Vision + Core ML. **Canonical-pattern check** — short read to spot anywhere we've drifted from Apple-blessed shape.

Dropped from shortlist (signal present but low value): `misc/BallDetector` (2019 minimal spike), `AR/HopAR` (RealityKit-focused, not capture pipeline), `PR/VideoCaptureSpike` (early prototype, capture-only), `misc/apple-ios-samples/AVReaderWriter` (offline A/V archive, not real-time).

Estimated deep-read time across top 3: 2–3 hours.
