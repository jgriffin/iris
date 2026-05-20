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
- 2026-05-20 — five per-project notes written to `notes/prior-projects/<slug>.md` (parallel deep-reads); `SYNTHESIS.md` written addressing the six M1 open questions in `BRIEF.md` plus ten findings not currently on the M1 list
- 2026-05-20 — `RECOMMENDATIONS.md` written as the action-oriented distillation: principles, patterns with code pointers, M1-scope additions, interesting tangents, anti-patterns. Block closed.

### Outcome

Deliverables under [`notes/prior-projects/`](../../notes/prior-projects/):

- [`ios-videoCapture.md`](../../notes/prior-projects/ios-videoCapture.md) — modular SPM mirror; module-boundary lens.
- [`PRVisionSpike.md`](../../notes/prior-projects/PRVisionSpike.md) — actor-based detection + Vision→overlay seam.
- [`yolo-ios-app.md`](../../notes/prior-projects/yolo-ios-app.md) — public Swift package craft.
- [`sportvision.md`](../../notes/prior-projects/sportvision.md) — Swift 6 strict concurrency + iOS/macOS dual target.
- [`action-and-vision.md`](../../notes/prior-projects/action-and-vision.md) — Apple-canonical pattern check.
- [`SYNTHESIS.md`](../../notes/prior-projects/SYNTHESIS.md) — verdicts on the six M1 open questions, plus carry-forward patterns, anti-patterns to avoid, and new findings to add to M1 scope.

**Verdicts on the six M1 open questions in `BRIEF.md`** (full evidence in `SYNTHESIS.md`):

1. **Async model** — `AsyncStream<Frame>` as the concrete return type, exposed through an `AsyncSequence` protocol. `bufferingPolicy: .bufferingNewest(1)` from day one. *(Medium signal.)*
2. **`@CaptureActor`** — Yes, build it for the capture pipeline; do not extend to `Detector`. *(Strong signal.)*
3. **COCO sidecar** — Unresolved by prior art; decide on domain merits. Centralize format logic as derived properties on `Detection` regardless. *(Weak signal.)*
4. **Hot-swap Core ML** — Swap the instance, never mutate in place. `Detector: Sendable` protocol allows both struct (stateless) and `actor` (stateful, e.g. trajectory) conformers. Cache `VNCoreMLModel` outside the detector. *(Strong on swap-instance; medium on mixed value/reference.)*
5. **macOS overlay parity** — Solved: pure SwiftUI `Canvas` + one centralized Y-flip + a `NormalizedGeometryConverting` protocol with per-source backends. Forbid `UIDevice.current.orientation`, `UIBezierPath`, `NSBezierPath` in overlay code. *(Strong signal — sportvision is a working proof.)*
6. **Foundation Models** — No direct signal. Recommendation: two protocols (`Detector` for spatial, `Captioner` for text), with `Detector` output associated-type-generic so it can't be hard-coded to `[Detection]`. *(Weak signal.)*

**Ten findings not on the current M1 list** (additions to consider before M1 plans lock — full detail in `SYNTHESIS.md`):

- `Detector.warmup()` on the protocol to prevent first-frame stalls.
- Letterbox/pillarbox alignment between view bounds and video rect.
- Back-pressure policy as part of the public `Frame` stream contract.
- Stateful-detector accommodation (`VNDetectTrajectoriesRequest` needs cross-frame memory).
- `Frame` naming hazard if `IrisDataset` later persists frame records.
- `MLFeatureProvider`-as-tuning-handle pattern for live threshold updates.
- Two-actor split (inference vs result storage) for playback scrubbing.
- `Detection` should carry both `xywh` and `xywhn`.
- `Frame.timestamp` as a first-class field, not extracted from `CMSampleBuffer` per-use.
- Distinguish "no detector ran" from "detector ran, found nothing."

**`BRIEF.md` updates worth proposing** at close: surface the verdicts for Q1, Q2, Q4, Q5; replace the six "open questions" with the four that remain genuinely open (Q3 format choice, Q6 Foundation Models scope, `IrisCapture`/`IrisPlayback` source protocol, `DetectorCache` ownership, cancellation policy).
