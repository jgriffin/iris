# review-prior-projects — Deep-read shortlisted prior projects

parent: [m0-explorations](.blockmaster/blocks/260520-m0-explorations.md)
created: 2026-05-20 10:00
modified: 2026-05-20 (opened with concrete scope from survey shortlist)
context: .blockmaster/blocks/260520-review-prior-projects.md
kind: research
goal: For each project shortlisted by `survey-dev-folder`, extract reusable patterns, design choices, and gotchas that should inform Iris's M1 capture pipeline.

### Context

Consumes the shortlist produced by [survey-dev-folder](.blockmaster/blocks/260520-survey-dev-folder.md). Stays 📋 until that block closes — its scope depends on the shortlist contents.

### Approach (sketch — refine at open)

For each shortlisted project:

1. Read the capture entry point — how is `AVCaptureSession` set up, configured, started/stopped?
2. Read frame plumbing — `CMSampleBuffer` → app-level type (struct / class / `inout`)? Is there a shared `Frame` shape?
3. Read detection path — Vision request wiring, model load, async pattern (`Task`, completion handler, `AsyncStream`)?
4. Read overlay (if present) — coordinate-space conversion, rotation/mirroring handling?
5. Note 2–3 things worth carrying forward; note 1–2 things worth NOT repeating.

### Output

Per-project notes (likely under `notes/prior-projects/<slug>.md`, or inlined here if short), plus a synthesis section in the Outcome that answers M1 open design questions where the prior art has opinion to offer.

### Scope (from survey shortlist, priority order)

1. **`~/dev/PR/ios-videoCapture`** — modular SPM mirror; highest priority for module-boundary patterns.
2. **`~/dev/PR/PRVisionSpike`** — end-to-end Vision pipeline with actor-based async detection.
3. **`~/dev/ml/yolo-ios-app`** — public Swift package; Vision+CoreML through SwiftPM cleanly.
4. **`~/dev/ml/sportvision`** — Swift 6 + iOS/macOS dual-target reference.
5. **`~/dev/pocketRadar/BuildingAFeatureRichAppForSportsAnalysis`** — Apple-blessed compact reference.

### Pick-up-here

Walk the 5 shortlisted projects in priority order. Per project: capture-entrypoint shape, Frame plumbing (struct/class/`inout`, shared shape?), detection-path async pattern, overlay coord-space handling. Land 2–3 carry-forwards + 1–2 anti-patterns per project (likely under `notes/prior-projects/<slug>.md`). Synthesis section addresses M1 open design questions where prior art has opinion.

### Progress

- 2026-05-20 10:00 — created and queued
- 2026-05-20 — opened with concrete 5-project scope after `survey-dev-folder` closed
