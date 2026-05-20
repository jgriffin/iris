# survey-dev-folder — Survey ~/dev/ for camera / capture / detection prior art

parent: [m0-explorations](.blockmaster/blocks/260520-m0-explorations.md)
created: 2026-05-20 10:00
modified: 2026-05-20 10:00
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
